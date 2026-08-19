#!/usr/bin/env python3
"""Deterministic CPU reference for Phase 3 spatial screen-probe ReSTIR.

This suite deliberately builds on :mod:`phase2_reference` so the spatial
contract uses the exact same explicit IEEE-754 binary32 arithmetic, hash
stream, sample representation, and weighted-reservoir update as Phase 2.

The reference covers one spatial round over a fixed center reservoir and a
uniform, without-replacement neighbor proposal.  A mapped neighbor is treated
as a compressed stream with mass::

    p_hat_center * J_center_over_source * visibility * neighbor.W
        * min(neighbor.M, spatial_M_cap)

Invalid mappings contribute neither mass nor M.  A valid mapping with zero
visibility or zero current target contributes zero mass but retains its capped
represented M.  This is a CPU contract only; it does not claim that the Phase
3 GPU pass, descriptor ABI, denoiser, or image-quality gates already exist.
"""

from __future__ import annotations

import argparse
import itertools
import json
import math
import os
import sys
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Callable

import phase2_reference as p2


SCHEMA_VERSION = "3.0.0"
PHASE3_ALGORITHM_VERSION = 3
DEFAULT_TRIALS = 65_536
MIN_DIAGNOSTIC_TRIALS = 4_096
DEFAULT_STRESS_FRAMES = 1_000

SPATIAL_ACCEPTED = "accepted"
SPATIAL_VISIBILITY_ZERO = "visibility_zero"
SPATIAL_ZERO_TARGET = "zero_target"
SPATIAL_REJECT_NO_RESERVOIR = "no_reservoir"
SPATIAL_REJECT_ALGORITHM = "algorithm_version"
SPATIAL_REJECT_GENERATION = "generation"
SPATIAL_REJECT_SOURCE_IDENTITY = "source_identity"
SPATIAL_REJECT_ENDPOINT_IDENTITY = "endpoint_identity"
SPATIAL_REJECT_EDGE = "edge_rejection"
SPATIAL_REJECT_TARGET = "target"
SPATIAL_REJECT_JACOBIAN = "jacobian"
SPATIAL_REJECT_M_CAP = "m_cap"

Vec3 = p2.Vec3


@dataclass(frozen=True)
class SpatialContext:
    """Current-center interpretation of one neighbor reservoir stream."""

    center_identity: p2.SurfaceIdentity
    expected_source_identity: p2.SurfaceIdentity
    generation: int
    algorithm_version: int
    endpoint_geometry_id: int
    endpoint_geometry_version: int
    content_version: int
    source_receiver_position: Vec3
    center_receiver_position: Vec3
    current_contribution: Vec3
    current_target: float
    visibility: bool
    m_cap: int
    edge_valid: bool = True


@dataclass(frozen=True)
class SpatialDecision:
    mapping_valid: bool
    reason: str
    jacobian: float = 0.0
    effective_M: int = 0
    merge_mass: float = 0.0
    cap_applied: bool = False
    reconnected_sample: p2.ScreenProbeSample | None = None


@dataclass
class CaseResult:
    name: str
    status: str
    metrics: dict[str, object]
    error: str = ""


def _gray(value: float) -> Vec3:
    value = p2.f32(value)
    return value, value, value


def _make_stream(
    sample_id: int,
    *,
    receiver_identity: p2.SurfaceIdentity,
    source_receiver_position: Vec3,
    target: float,
    W: float,
    M: int,
    generation: int = 9,
    algorithm_version: int = PHASE3_ALGORITHM_VERSION,
    domain: int = p2.DOMAIN_HIT,
    endpoint_position: Vec3 = (0.0, 0.0, 2.0),
    endpoint_normal: Vec3 = (0.0, 0.0, -1.0),
    geometry_id: int = 101,
    geometry_version: int = 7,
    content_version: int = 5,
    age: int = 0,
) -> p2.ScreenProbeReservoir:
    """Create an already-normalized compressed stream using P2 float32 math."""

    if M <= 0 or not p2.finite_positive(target) or not p2.finite_positive(W):
        raise ValueError("a source stream requires positive target, W, and integer M")
    if domain == p2.DOMAIN_HIT:
        connection = p2.subtract(endpoint_position, source_receiver_position)
        direction = p2.normalize(connection)
        distance = p2.length(connection)
    elif domain == p2.DOMAIN_SKY:
        direction = p2.normalize((0.2, -0.1, 1.0))
        endpoint_position = (0.0, 0.0, 0.0)
        endpoint_normal = (0.0, 0.0, 1.0)
        distance = 0.0
        geometry_id = 0
        geometry_version = 0
    else:
        raise ValueError("unsupported sample domain")

    sample = p2.ScreenProbeSample(
        sample_id=p2.u32(sample_id),
        domain=domain,
        direction=p2.f32_vec(direction),
        endpoint_position=p2.f32_vec(endpoint_position),
        endpoint_normal=p2.f32_vec(endpoint_normal),
        contribution=_gray(target),
        distance=p2.f32(distance),
        proposal_pdf=p2.f32(1.0),
        geometry_id=p2.u32(geometry_id),
        geometry_version=p2.u32(geometry_version),
        content_version=p2.u32(content_version),
        generation=p2.u32(generation),
    )
    target = p2.f32(target)
    W = p2.f32(W)
    weight_sum = p2.fmul(p2.fmul(target, W), float(M))
    reservoir = p2.ScreenProbeReservoir(
        selected=sample,
        target_selected=target,
        weight_sum=weight_sum,
        W=W,
        M=M,
        age=age,
        generation=generation,
        algorithm_version=algorithm_version,
        receiver_identity=receiver_identity,
    )
    if not reservoir.is_valid():
        raise ValueError("constructed compressed stream is invalid")
    return reservoir


def uniform_neighbor_offsets(
    radius: int,
    candidate_count: int,
    trial: int,
    seed: int = 0x6D2B79F5,
) -> list[tuple[int, int]]:
    """Uniform discrete offsets without replacement via partial Fisher-Yates."""

    if radius <= 0:
        raise ValueError("neighbor radius must be positive")
    pool = [
        (x, y)
        for y in range(-radius, radius + 1)
        for x in range(-radius, radius + 1)
        if x != 0 or y != 0
    ]
    if candidate_count < 0 or candidate_count > len(pool):
        raise ValueError("candidate count exceeds the unique neighbor domain")
    for selection in range(candidate_count):
        remaining = len(pool) - selection
        random_value = p2.hash_float(
            (p2.u32(trial), p2.u32(selection), p2.u32(seed))
        )
        relative_index = min(int(random_value * remaining), remaining - 1)
        swap_index = selection + relative_index
        pool[selection], pool[swap_index] = pool[swap_index], pool[selection]
    return pool[:candidate_count]


def _reconnect_sample(
    sample: p2.ScreenProbeSample,
    context: SpatialContext,
) -> p2.ScreenProbeSample | None:
    if sample.domain == p2.DOMAIN_HIT:
        connection = p2.subtract(sample.endpoint_position, context.center_receiver_position)
        if not p2.finite_positive(p2.length(connection)):
            return None
        direction = p2.normalize(connection)
        distance = p2.length(connection)
    elif sample.domain == p2.DOMAIN_SKY:
        direction = sample.direction
        distance = 0.0
    else:
        return None
    return replace(
        sample,
        direction=p2.f32_vec(direction),
        contribution=p2.f32_vec(context.current_contribution),
        distance=p2.f32(distance),
        content_version=p2.u32(context.content_version),
        generation=p2.u32(context.generation),
    )


def evaluate_spatial_candidate(
    neighbor: p2.ScreenProbeReservoir | None,
    context: SpatialContext,
) -> SpatialDecision:
    """Validate/reconnect one neighbor without mutating the center stream."""

    if neighbor is None or not neighbor.is_valid() or neighbor.selected is None:
        return SpatialDecision(False, SPATIAL_REJECT_NO_RESERVOIR)
    sample = neighbor.selected
    if (
        neighbor.algorithm_version != context.algorithm_version
        or context.algorithm_version != PHASE3_ALGORITHM_VERSION
    ):
        return SpatialDecision(False, SPATIAL_REJECT_ALGORITHM)
    if neighbor.generation != context.generation or sample.generation != context.generation:
        return SpatialDecision(False, SPATIAL_REJECT_GENERATION)
    if neighbor.receiver_identity != context.expected_source_identity:
        return SpatialDecision(False, SPATIAL_REJECT_SOURCE_IDENTITY)
    if not context.edge_valid:
        return SpatialDecision(False, SPATIAL_REJECT_EDGE)
    if sample.domain == p2.DOMAIN_HIT and (
        sample.geometry_id != context.endpoint_geometry_id
        or sample.geometry_version != context.endpoint_geometry_version
    ):
        return SpatialDecision(False, SPATIAL_REJECT_ENDPOINT_IDENTITY)
    if (
        not math.isfinite(context.current_target)
        or context.current_target < 0.0
        or any(not math.isfinite(component) for component in context.current_contribution)
    ):
        return SpatialDecision(False, SPATIAL_REJECT_TARGET)

    effective_M = min(neighbor.M, max(context.m_cap, 0))
    if effective_M <= 0:
        return SpatialDecision(False, SPATIAL_REJECT_M_CAP)
    cap_applied = effective_M < neighbor.M

    if sample.domain == p2.DOMAIN_HIT:
        jacobian = p2.hit_reconnection_jacobian(
            context.source_receiver_position,
            context.center_receiver_position,
            sample.endpoint_position,
            sample.endpoint_normal,
        )
        if not p2.finite_positive(jacobian):
            return SpatialDecision(False, SPATIAL_REJECT_JACOBIAN)
    elif sample.domain == p2.DOMAIN_SKY:
        jacobian = 1.0
    else:
        return SpatialDecision(False, SPATIAL_REJECT_ENDPOINT_IDENTITY)

    reconnected_sample = _reconnect_sample(sample, context)
    if reconnected_sample is None or not reconnected_sample.is_valid():
        return SpatialDecision(False, SPATIAL_REJECT_JACOBIAN)
    jacobian = p2.f32(jacobian)
    if not context.visibility:
        return SpatialDecision(
            True,
            SPATIAL_VISIBILITY_ZERO,
            jacobian=jacobian,
            effective_M=effective_M,
            merge_mass=0.0,
            cap_applied=cap_applied,
            reconnected_sample=replace(reconnected_sample, contribution=(0.0, 0.0, 0.0)),
        )
    if context.current_target == 0.0:
        return SpatialDecision(
            True,
            SPATIAL_ZERO_TARGET,
            jacobian=jacobian,
            effective_M=effective_M,
            merge_mass=0.0,
            cap_applied=cap_applied,
            reconnected_sample=replace(reconnected_sample, contribution=(0.0, 0.0, 0.0)),
        )

    merge_mass = p2.fmul(
        p2.fmul(p2.fmul(context.current_target, jacobian), neighbor.W),
        float(effective_M),
    )
    if not math.isfinite(merge_mass) or merge_mass < 0.0:
        return SpatialDecision(False, SPATIAL_REJECT_TARGET)
    return SpatialDecision(
        True,
        SPATIAL_ACCEPTED,
        jacobian=jacobian,
        effective_M=effective_M,
        merge_mass=merge_mass,
        cap_applied=cap_applied,
        reconnected_sample=reconnected_sample,
    )


def spatial_merge(
    center: p2.ScreenProbeReservoir,
    neighbors: list[p2.ScreenProbeReservoir | None],
    contexts: list[SpatialContext],
    random_values: list[float],
) -> tuple[p2.ScreenProbeReservoir, list[SpatialDecision]]:
    """Merge one fixed neighbor set into a copy of the center reservoir."""

    if len(neighbors) != len(contexts) or len(neighbors) != len(random_values):
        raise ValueError("neighbor, context, and random streams must have equal length")
    if (
        not center.is_valid()
        or center.algorithm_version != PHASE3_ALGORITHM_VERSION
        or center.receiver_identity is None
    ):
        raise ValueError("the spatial center must be a valid Phase 3 reservoir")

    output = replace(center)
    decisions: list[SpatialDecision] = []
    for neighbor, context, random_value in zip(neighbors, contexts, random_values):
        if context.center_identity != center.receiver_identity:
            decision = SpatialDecision(False, SPATIAL_REJECT_SOURCE_IDENTITY)
        else:
            decision = evaluate_spatial_candidate(neighbor, context)
        decisions.append(decision)
        if not decision.mapping_valid:
            continue
        if decision.reconnected_sample is None or neighbor is None:
            raise AssertionError("valid spatial mapping has no reconnected sample")
        if not p2.reservoir_update(
            output,
            decision.reconnected_sample,
            context.current_target,
            decision.merge_mass,
            decision.effective_M,
            random_value,
            neighbor.age,
        ):
            raise AssertionError("valid spatial compressed stream failed to merge")
    if not output.finalize():
        raise AssertionError("spatial output did not finalize")
    return output, decisions


class ReferenceSuite:
    def __init__(self, trials: int, stress_frames: int) -> None:
        self.trials = trials
        self.stress_frames = stress_frames
        self.results: list[CaseResult] = []

    def run_case(self, name: str, function: Callable[[], dict[str, object]]) -> None:
        try:
            metrics = function()
        except Exception as exception:  # Keep every independent contract in JSON.
            self.results.append(CaseResult(name, "failed", {}, str(exception)))
        else:
            self.results.append(CaseResult(name, "passed", metrics))

    @staticmethod
    def _context(
        center: p2.ScreenProbeReservoir,
        neighbor: p2.ScreenProbeReservoir,
        *,
        source_position: Vec3,
        center_position: Vec3 = (0.0, 0.0, 0.0),
        current_target: float = 1.0,
        visibility: bool = True,
        m_cap: int = 4,
        edge_valid: bool = True,
        endpoint_geometry_id: int | None = None,
        endpoint_geometry_version: int | None = None,
    ) -> SpatialContext:
        if center.receiver_identity is None or neighbor.receiver_identity is None or neighbor.selected is None:
            raise ValueError("context requires complete center and neighbor reservoirs")
        sample = neighbor.selected
        return SpatialContext(
            center_identity=center.receiver_identity,
            expected_source_identity=neighbor.receiver_identity,
            generation=center.generation,
            algorithm_version=PHASE3_ALGORITHM_VERSION,
            endpoint_geometry_id=(
                sample.geometry_id if endpoint_geometry_id is None else endpoint_geometry_id
            ),
            endpoint_geometry_version=(
                sample.geometry_version
                if endpoint_geometry_version is None
                else endpoint_geometry_version
            ),
            content_version=sample.content_version + 1,
            source_receiver_position=source_position,
            center_receiver_position=center_position,
            current_contribution=_gray(current_target),
            current_target=p2.f32(current_target),
            visibility=visibility,
            m_cap=m_cap,
            edge_valid=edge_valid,
        )

    def test_fixed_center_uniform_unique_neighbors(self) -> dict[str, object]:
        center_identity = p2.SurfaceIdentity(1, 2, 3)
        center = _make_stream(
            100,
            receiver_identity=center_identity,
            source_receiver_position=(0.0, 0.0, 0.0),
            target=2.0,
            W=0.5,
            M=3,
        )
        offsets = uniform_neighbor_offsets(2, 4, 12_345)
        if len(offsets) != len(set(offsets)) or (0, 0) in offsets:
            raise AssertionError("fixed neighbor proposal contains a duplicate or center offset")

        neighbors: list[p2.ScreenProbeReservoir] = []
        contexts: list[SpatialContext] = []
        for index, offset in enumerate(offsets):
            source_position = (offset[0] * 0.2, offset[1] * 0.2, 0.0)
            identity = p2.SurfaceIdentity(10 + index, 20 + index, 30 + index)
            domain = p2.DOMAIN_SKY if index == len(offsets) - 1 else p2.DOMAIN_HIT
            neighbor = _make_stream(
                200 + index,
                receiver_identity=identity,
                source_receiver_position=source_position,
                target=1.0 + index,
                W=0.25 + index * 0.125,
                M=5 + index,
                domain=domain,
            )
            neighbors.append(neighbor)
            contexts.append(
                self._context(
                    center,
                    neighbor,
                    source_position=source_position,
                    current_target=1.0 + index * 0.5,
                    m_cap=4,
                )
            )

        random_values = [p2.hash_float((12_345, index, 0xA511E9B3)) for index in range(4)]
        output, decisions = spatial_merge(center, neighbors, contexts, random_values)
        expected_M = center.M
        expected_mass = center.weight_sum
        for decision in decisions:
            if not decision.mapping_valid or decision.reason != SPATIAL_ACCEPTED:
                raise AssertionError("fixed positive neighbor unexpectedly failed mapping")
            if not decision.cap_applied or decision.effective_M != 4:
                raise AssertionError("fixed neighbor did not exercise the spatial M cap")
            expected_M += decision.effective_M
            expected_mass = p2.fadd(expected_mass, decision.merge_mass)
        if output.M != expected_M or p2.f32_bits(output.weight_sum) != p2.f32_bits(expected_mass):
            raise AssertionError("fixed spatial stream changed total mass or represented M")
        reconstructed_mass = p2.fmul(
            p2.fmul(output.target_selected, output.W), float(output.M)
        )
        if abs(reconstructed_mass - output.weight_sum) > max(2e-6, abs(output.weight_sum) * 2e-6):
            raise AssertionError("fixed spatial output no longer satisfies target*W*M")
        return {
            "proposal": "uniform_without_replacement",
            "radius": 2,
            "neighbor_count": 4,
            "offsets": [list(offset) for offset in offsets],
            "center_M": center.M,
            "output_M": output.M,
            "output_mass_bits": f"0x{p2.f32_bits(output.weight_sum):08x}",
            "selected_sample_id": output.selected.sample_id if output.selected else None,
            "all_neighbors_capped": True,
        }

    def test_uniform_neighbor_proposal_trials(self) -> dict[str, object]:
        radius = 2
        candidate_count = 4
        domain = [
            (x, y)
            for y in range(-radius, radius + 1)
            for x in range(-radius, radius + 1)
            if x != 0 or y != 0
        ]
        counts = {offset: 0 for offset in domain}
        for trial in range(self.trials):
            offsets = uniform_neighbor_offsets(radius, candidate_count, trial)
            if len(offsets) != len(set(offsets)):
                raise AssertionError(f"trial {trial}: neighbor proposal repeated an offset")
            for offset in offsets:
                counts[offset] += 1
        expected_count = self.trials * candidate_count / float(len(domain))
        maximum_relative_error = max(
            abs(count - expected_count) / expected_count for count in counts.values()
        )
        tolerance = 0.05 * math.sqrt(DEFAULT_TRIALS / float(self.trials))
        if maximum_relative_error >= tolerance:
            raise AssertionError(
                f"uniform neighbor inclusion error {maximum_relative_error:.6g} >= {tolerance:.6g}"
            )
        return {
            "trials": self.trials,
            "radius": radius,
            "domain_size": len(domain),
            "candidate_count": candidate_count,
            "draw_probability": 1.0 / len(domain),
            "inclusion_probability": candidate_count / len(domain),
            "minimum_inclusion_count": min(counts.values()),
            "maximum_inclusion_count": max(counts.values()),
            "expected_inclusion_count": expected_count,
            "maximum_relative_error": maximum_relative_error,
            "acceptance_relative_error": tolerance,
            "duplicates": 0,
        }

    def test_spatial_m_cap_and_invalid_mapping(self) -> dict[str, object]:
        center_identity = p2.SurfaceIdentity(1, 2, 3)
        source_identity = p2.SurfaceIdentity(4, 5, 6)
        center = _make_stream(
            300,
            receiver_identity=center_identity,
            source_receiver_position=(0.0, 0.0, 0.0),
            target=1.0,
            W=1.0,
            M=2,
        )
        hit_neighbor = _make_stream(
            301,
            receiver_identity=source_identity,
            source_receiver_position=(0.0, 0.0, 0.0),
            target=1.0,
            W=0.5,
            M=100,
        )
        valid_context = self._context(
            center,
            hit_neighbor,
            source_position=(0.0, 0.0, 0.0),
            current_target=2.0,
            m_cap=7,
        )
        capped_output, capped_decisions = spatial_merge(
            center, [hit_neighbor], [valid_context], [0.0]
        )
        capped = capped_decisions[0]
        if not capped.mapping_valid or not capped.cap_applied or capped.effective_M != 7:
            raise AssertionError("valid neighbor did not cap M=100 to spatial M=7")
        if capped_output.M != center.M + 7:
            raise AssertionError("capped valid stream did not add exactly M_eff")

        invalid_neighbors_and_contexts = [
            (
                replace(hit_neighbor, algorithm_version=p2.PHASE2_ALGORITHM_VERSION),
                valid_context,
                SPATIAL_REJECT_ALGORITHM,
            ),
            (hit_neighbor, replace(valid_context, generation=valid_context.generation + 1), SPATIAL_REJECT_GENERATION),
            (
                hit_neighbor,
                replace(valid_context, expected_source_identity=p2.SurfaceIdentity(4, 5, 99)),
                SPATIAL_REJECT_SOURCE_IDENTITY,
            ),
            (
                hit_neighbor,
                replace(valid_context, endpoint_geometry_version=valid_context.endpoint_geometry_version + 1),
                SPATIAL_REJECT_ENDPOINT_IDENTITY,
            ),
            (hit_neighbor, replace(valid_context, edge_valid=False), SPATIAL_REJECT_EDGE),
            (hit_neighbor, replace(valid_context, current_target=math.nan), SPATIAL_REJECT_TARGET),
            (
                hit_neighbor,
                replace(valid_context, center_receiver_position=(0.0, 0.0, 3.0)),
                SPATIAL_REJECT_JACOBIAN,
            ),
        ]
        reasons: dict[str, int] = {}
        for neighbor, context, expected_reason in invalid_neighbors_and_contexts:
            output, decisions = spatial_merge(center, [neighbor], [context], [0.0])
            decision = decisions[0]
            if decision.mapping_valid or decision.reason != expected_reason:
                raise AssertionError(
                    f"invalid mapping expected {expected_reason}, got {decision.reason}"
                )
            if decision.effective_M != 0 or decision.merge_mass != 0.0:
                raise AssertionError("invalid mapping retained compressed mass or M")
            if (
                output.M != center.M
                or p2.f32_bits(output.weight_sum) != p2.f32_bits(center.weight_sum)
                or output.selected != center.selected
            ):
                raise AssertionError("invalid mapping mutated the center reservoir")
            reasons[decision.reason] = reasons.get(decision.reason, 0) + 1
        return {
            "input_M": hit_neighbor.M,
            "spatial_M_cap": valid_context.m_cap,
            "effective_M": capped.effective_M,
            "output_M": capped_output.M,
            "invalid_mapping_reasons": reasons,
            "invalid_mapping_added_mass": 0.0,
            "invalid_mapping_added_M": 0,
        }

    def test_visibility_and_zero_target_preserve_m(self) -> dict[str, object]:
        center_identity = p2.SurfaceIdentity(1, 2, 3)
        center = _make_stream(
            400,
            receiver_identity=center_identity,
            source_receiver_position=(0.0, 0.0, 0.0),
            target=2.0,
            W=0.5,
            M=3,
        )
        neighbors = [
            _make_stream(
                401 + index,
                receiver_identity=p2.SurfaceIdentity(10 + index, 20 + index, 30 + index),
                source_receiver_position=(index * 0.2, 0.0, 0.0),
                target=1.0,
                W=0.75,
                M=9,
            )
            for index in range(2)
        ]
        contexts = [
            self._context(
                center,
                neighbors[0],
                source_position=(0.0, 0.0, 0.0),
                current_target=2.0,
                visibility=False,
                m_cap=4,
            ),
            self._context(
                center,
                neighbors[1],
                source_position=(0.2, 0.0, 0.0),
                current_target=0.0,
                visibility=True,
                m_cap=4,
            ),
        ]
        output, decisions = spatial_merge(center, neighbors, contexts, [0.0, 0.0])
        if [decision.reason for decision in decisions] != [
            SPATIAL_VISIBILITY_ZERO,
            SPATIAL_ZERO_TARGET,
        ]:
            raise AssertionError("zero-mass spatial mappings changed classification")
        if any(decision.effective_M != 4 or decision.merge_mass != 0.0 for decision in decisions):
            raise AssertionError("zero visibility/target did not retain capped M with zero mass")
        if output.M != center.M + 8 or output.weight_sum != center.weight_sum:
            raise AssertionError("zero visibility/target changed mass or dropped represented M")
        if output.selected != center.selected:
            raise AssertionError("a zero-mass neighbor replaced the center sample")
        expected_W = p2.fdiv(
            output.weight_sum,
            p2.fmul(float(output.M), output.target_selected),
        )
        if p2.f32_bits(output.W) != p2.f32_bits(expected_W):
            raise AssertionError("zero-mass represented M did not renormalize output W")
        return {
            "center_M": center.M,
            "visibility_zero_effective_M": decisions[0].effective_M,
            "zero_target_effective_M": decisions[1].effective_M,
            "output_M": output.M,
            "mass_unchanged": True,
            "output_W_bits": f"0x{p2.f32_bits(output.W):08x}",
        }

    def test_hit_and_sky_jacobians(self) -> dict[str, object]:
        center_identity = p2.SurfaceIdentity(1, 2, 3)
        center = _make_stream(
            500,
            receiver_identity=center_identity,
            source_receiver_position=(0.5, 0.0, 0.0),
            target=1.0,
            W=1.0,
            M=1,
        )
        source_identity = p2.SurfaceIdentity(4, 5, 6)
        hit = _make_stream(
            501,
            receiver_identity=source_identity,
            source_receiver_position=(0.0, 0.0, 0.0),
            target=1.0,
            W=0.5,
            M=5,
        )
        hit_context = self._context(
            center,
            hit,
            source_position=(0.0, 0.0, 0.0),
            center_position=(0.5, 0.0, 0.0),
            current_target=2.0,
            m_cap=5,
        )
        hit_decision = evaluate_spatial_candidate(hit, hit_context)
        source_G = p2.geometry_term(
            hit_context.source_receiver_position,
            hit.selected.endpoint_position,  # type: ignore[union-attr]
            hit.selected.endpoint_normal,  # type: ignore[union-attr]
        )
        center_G = p2.geometry_term(
            hit_context.center_receiver_position,
            hit.selected.endpoint_position,  # type: ignore[union-attr]
            hit.selected.endpoint_normal,  # type: ignore[union-attr]
        )
        expected_hit_J = p2.f32(center_G / source_G)
        if not hit_decision.mapping_valid or p2.f32_bits(hit_decision.jacobian) != p2.f32_bits(expected_hit_J):
            raise AssertionError("hit Jacobian is not G_center/G_source")

        sky = _make_stream(
            502,
            receiver_identity=source_identity,
            source_receiver_position=(-100.0, 50.0, 3.0),
            target=1.0,
            W=0.5,
            M=5,
            domain=p2.DOMAIN_SKY,
        )
        sky_context = self._context(
            center,
            sky,
            source_position=(-100.0, 50.0, 3.0),
            center_position=(0.5, 0.0, 0.0),
            current_target=2.0,
            m_cap=5,
        )
        sky_decision = evaluate_spatial_candidate(sky, sky_context)
        if not sky_decision.mapping_valid or p2.f32_bits(sky_decision.jacobian) != p2.f32_bits(1.0):
            raise AssertionError("sky direction-domain Jacobian must remain one")

        backface_context = replace(hit_context, center_receiver_position=(0.0, 0.0, 3.0))
        backface_output, backface_decisions = spatial_merge(
            center, [hit], [backface_context], [0.0]
        )
        if (
            backface_decisions[0].reason != SPATIAL_REJECT_JACOBIAN
            or backface_output.M != center.M
            or backface_output.weight_sum != center.weight_sum
        ):
            raise AssertionError("single-sided backface Jacobian did not drop mass and M")
        return {
            "hit_source_G": source_G,
            "hit_center_G": center_G,
            "hit_J": hit_decision.jacobian,
            "hit_J_bits": f"0x{p2.f32_bits(hit_decision.jacobian):08x}",
            "sky_J": sky_decision.jacobian,
            "backface_mapping_rejected": True,
        }

    def test_stream_permutation_and_compression(self) -> dict[str, object]:
        center_identity = p2.SurfaceIdentity(1, 2, 3)
        center = _make_stream(
            600,
            receiver_identity=center_identity,
            source_receiver_position=(0.0, 0.0, 0.0),
            target=1.0,
            W=1.0,
            M=2,
            domain=p2.DOMAIN_SKY,
        )
        specifications = ((2, 0.5), (4, 0.5), (8, 0.625))
        neighbors: list[p2.ScreenProbeReservoir] = []
        contexts: list[SpatialContext] = []
        for index, (M, W) in enumerate(specifications):
            identity = p2.SurfaceIdentity(10 + index, 20 + index, 30 + index)
            neighbor = _make_stream(
                601 + index,
                receiver_identity=identity,
                source_receiver_position=(float(index), 0.0, 0.0),
                target=1.0,
                W=W,
                M=M,
                domain=p2.DOMAIN_SKY,
            )
            neighbors.append(neighbor)
            contexts.append(
                self._context(
                    center,
                    neighbor,
                    source_position=(float(index), 0.0, 0.0),
                    current_target=1.0,
                    m_cap=8,
                )
            )

        expected_probabilities = (0.2, 0.1, 0.2, 0.5)
        permutation_trials = min(self.trials, 16_384)
        probability_tolerance = 0.03 * math.sqrt(16_384 / float(permutation_trials))
        maximum_probability_error = 0.0
        permutation_metrics: dict[str, object] = {}
        for permutation_index, permutation in enumerate(itertools.permutations(range(3))):
            selected_counts = [0, 0, 0, 0]
            for trial in range(permutation_trials):
                ordered_neighbors = [neighbors[index] for index in permutation]
                ordered_contexts = [contexts[index] for index in permutation]
                random_values = [
                    p2.hash_float((trial, step, 0xC001CAFE ^ permutation_index))
                    for step in range(3)
                ]
                output, decisions = spatial_merge(
                    center, ordered_neighbors, ordered_contexts, random_values
                )
                if output.M != 16 or p2.f32_bits(output.weight_sum) != p2.f32_bits(10.0):
                    raise AssertionError("permutation changed spatial M or total mass")
                if any(not decision.mapping_valid for decision in decisions):
                    raise AssertionError("permutation rejected a valid spatial stream")
                if output.selected is None:
                    raise AssertionError("permuted spatial stream selected no sample")
                selected_counts[output.selected.sample_id - 600] += 1
            observed = tuple(count / float(permutation_trials) for count in selected_counts)
            probability_error = max(
                abs(observed[index] - expected_probabilities[index]) for index in range(4)
            )
            if probability_error >= probability_tolerance:
                raise AssertionError(
                    f"permutation {permutation} probability error {probability_error:.6g} "
                    f">= {probability_tolerance:.6g}"
                )
            maximum_probability_error = max(maximum_probability_error, probability_error)
            permutation_metrics["".join(str(index) for index in permutation)] = observed

        compression_neighbor = _make_stream(
            610,
            receiver_identity=p2.SurfaceIdentity(40, 50, 60),
            source_receiver_position=(1.0, 0.0, 0.0),
            target=1.0,
            W=0.5,
            M=4,
            domain=p2.DOMAIN_SKY,
        )
        compression_context = self._context(
            center,
            compression_neighbor,
            source_position=(1.0, 0.0, 0.0),
            current_target=3.0,
            m_cap=4,
        )
        compressed, compressed_decisions = spatial_merge(
            center, [compression_neighbor], [compression_context], [0.0]
        )
        decision = compressed_decisions[0]
        if not decision.mapping_valid or decision.reconnected_sample is None:
            raise AssertionError("compression fixture failed spatial mapping")
        expanded = replace(center)
        per_sample_mass = p2.fdiv(decision.merge_mass, float(decision.effective_M))
        for sample_index in range(decision.effective_M):
            if not p2.reservoir_update(
                expanded,
                decision.reconnected_sample,
                compression_context.current_target,
                per_sample_mass,
                1,
                0.0,
                compression_neighbor.age,
            ):
                raise AssertionError(f"expanded spatial sample {sample_index} failed")
        if not expanded.finalize():
            raise AssertionError("expanded spatial stream did not finalize")
        if (
            compressed.M != expanded.M
            or p2.f32_bits(compressed.weight_sum) != p2.f32_bits(expanded.weight_sum)
            or p2.f32_bits(compressed.W) != p2.f32_bits(expanded.W)
            or compressed.selected != expanded.selected
        ):
            raise AssertionError("compressed spatial stream differs from expanded samples")
        return {
            "permutation_trials": permutation_trials,
            "permutations": permutation_metrics,
            "expected_selection_probabilities": expected_probabilities,
            "maximum_selection_probability_error": maximum_probability_error,
            "acceptance_probability_error": probability_tolerance,
            "compressed_M": compressed.M,
            "expanded_M": expanded.M,
            "compressed_mass_bits": f"0x{p2.f32_bits(compressed.weight_sum):08x}",
            "expanded_mass_bits": f"0x{p2.f32_bits(expanded.weight_sum):08x}",
            "compressed_W_bits": f"0x{p2.f32_bits(compressed.W):08x}",
            "expanded_W_bits": f"0x{p2.f32_bits(expanded.W):08x}",
        }

    def test_thousand_frame_finite_stress(self) -> dict[str, object]:
        center_identity = p2.SurfaceIdentity(1, 2, 3)
        reason_counts: dict[str, int] = {}
        cap_count = 0
        accepted_streams = 0
        maximum_M = 0
        maximum_mass = 0.0
        maximum_output_component = 0.0

        for frame in range(self.stress_frames):
            center_position = (
                0.3 * math.sin(frame * 0.017),
                0.2 * math.cos(frame * 0.013),
                0.0,
            )
            center_target = 0.25 + 0.5 * p2.hash_float((frame, 0x10203040, 0))
            center = _make_stream(
                frame * 8,
                receiver_identity=center_identity,
                source_receiver_position=center_position,
                target=center_target,
                W=0.5 + 0.25 * p2.hash_float((frame, 0x50607080, 0)),
                M=2,
                generation=17,
                domain=p2.DOMAIN_SKY,
            )
            offsets = uniform_neighbor_offsets(2, 4, frame, 0xA17E5EED)
            neighbors: list[p2.ScreenProbeReservoir] = []
            contexts: list[SpatialContext] = []
            random_values: list[float] = []
            for index, offset in enumerate(offsets):
                source_position = (offset[0] * 0.2, offset[1] * 0.2, 0.0)
                identity = p2.SurfaceIdentity(100 + index, 200 + index, 300 + index)
                domain = p2.DOMAIN_SKY if index == 3 else p2.DOMAIN_HIT
                generation = 16 if index == 0 and frame % 37 == 0 else 17
                algorithm = (
                    p2.PHASE2_ALGORITHM_VERSION
                    if index == 1 and frame % 53 == 0
                    else PHASE3_ALGORITHM_VERSION
                )
                source_M = 1 + p2.hash_uvec3((frame, index, 0x31415926)) % 128
                source_target = 0.01 + 40.0 * p2.hash_float((frame, index, 0x27182818))
                source_W = 0.05 + 1.5 * p2.hash_float((index, frame, 0x9E3779B9))
                endpoint_position = (
                    source_position[0] * 0.25,
                    source_position[1] * 0.25,
                    2.0 + 0.1 * index,
                )
                neighbor = _make_stream(
                    frame * 8 + index + 1,
                    receiver_identity=identity,
                    source_receiver_position=source_position,
                    target=source_target,
                    W=source_W,
                    M=source_M,
                    generation=generation,
                    algorithm_version=algorithm,
                    domain=domain,
                    endpoint_position=endpoint_position,
                    geometry_id=101 + index,
                    geometry_version=7,
                    content_version=5 + frame // 97,
                    age=frame % 32,
                )
                current_target = (
                    0.0
                    if (frame + index * 11) % 31 == 0
                    else 0.01
                    + 500.0 * p2.hash_float((frame, index, 0xDEADBEEF))
                )
                context = self._context(
                    center,
                    neighbor,
                    source_position=source_position,
                    center_position=center_position,
                    current_target=current_target,
                    visibility=(frame + index * 7) % 29 != 0,
                    m_cap=16,
                    edge_valid=not (index == 3 and frame % 43 == 0),
                    endpoint_geometry_version=(
                        8 if index == 2 and frame % 41 == 0 else None
                    ),
                )
                neighbors.append(neighbor)
                contexts.append(context)
                random_values.append(p2.hash_float((frame, index, 0xC2B2AE35)))

            output, decisions = spatial_merge(center, neighbors, contexts, random_values)
            expected_M = center.M
            for decision in decisions:
                reason_counts[decision.reason] = reason_counts.get(decision.reason, 0) + 1
                cap_count += int(decision.cap_applied)
                accepted_streams += int(decision.mapping_valid)
                expected_M += decision.effective_M if decision.mapping_valid else 0
            if output.M != expected_M:
                raise AssertionError(
                    f"stress frame {frame}: invalid mapping changed represented M"
                )
            if output.M > center.M + 4 * 16:
                raise AssertionError(f"stress frame {frame}: spatial M cap was exceeded")
            if not output.is_valid() or not math.isfinite(output.weight_sum):
                raise AssertionError(f"stress frame {frame}: reservoir became non-finite")
            estimate = output.estimate()
            if any(not math.isfinite(component) or component < 0.0 for component in estimate):
                raise AssertionError(f"stress frame {frame}: output estimate became invalid")
            maximum_M = max(maximum_M, output.M)
            maximum_mass = max(maximum_mass, output.weight_sum)
            maximum_output_component = max(maximum_output_component, *estimate)

        required_reasons = {
            SPATIAL_ACCEPTED,
            SPATIAL_VISIBILITY_ZERO,
            SPATIAL_ZERO_TARGET,
            SPATIAL_REJECT_ALGORITHM,
            SPATIAL_REJECT_GENERATION,
            SPATIAL_REJECT_ENDPOINT_IDENTITY,
            SPATIAL_REJECT_EDGE,
        }
        missing_reasons = required_reasons - set(reason_counts)
        if missing_reasons:
            raise AssertionError(
                "stress sequence did not exercise: " + ", ".join(sorted(missing_reasons))
            )
        if cap_count == 0 or accepted_streams <= self.stress_frames * 2:
            raise AssertionError("stress sequence did not sustain capped spatial reuse")
        return {
            "frames": self.stress_frames,
            "neighbor_attempts": self.stress_frames * 4,
            "mapping_valid_streams": accepted_streams,
            "m_cap_applied_streams": cap_count,
            "reason_counts": reason_counts,
            "maximum_M": maximum_M,
            "maximum_mass": maximum_mass,
            "maximum_output_component": maximum_output_component,
            "all_outputs_finite": True,
        }

    def execute(self) -> dict[str, object]:
        cases: list[tuple[str, Callable[[], dict[str, object]]]] = [
            ("fixed_center_uniform_unique_neighbors", self.test_fixed_center_uniform_unique_neighbors),
            ("uniform_neighbor_proposal_trials", self.test_uniform_neighbor_proposal_trials),
            ("spatial_m_cap_and_invalid_mapping", self.test_spatial_m_cap_and_invalid_mapping),
            ("visibility_and_zero_target_preserve_m", self.test_visibility_and_zero_target_preserve_m),
            ("hit_and_sky_jacobians", self.test_hit_and_sky_jacobians),
            ("stream_permutation_and_compression", self.test_stream_permutation_and_compression),
            ("thousand_frame_finite_stress", self.test_thousand_frame_finite_stress),
        ]
        for name, function in cases:
            self.run_case(name, function)
        failures = [result for result in self.results if result.status != "passed"]
        formal_parameters = (
            self.trials >= DEFAULT_TRIALS
            and self.stress_frames >= DEFAULT_STRESS_FRAMES
        )
        return {
            "schema_version": SCHEMA_VERSION,
            "suite": "hddagi_screen_probe_phase3_cpu_reference",
            "status": "failed" if failures else "completed",
            "acceptance_ready": not failures and formal_parameters,
            "precision": "Phase 2 explicit IEEE-754 binary32 ABI arithmetic reused by import",
            "algorithm_version": PHASE3_ALGORITHM_VERSION,
            "phase2_reference_schema_dependency": "2.5.0-compatible primitives",
            "trials_per_uniform_neighbor_proposal": self.trials,
            "stress_frames": self.stress_frames,
            "formal_minimums": {
                "trials": DEFAULT_TRIALS,
                "stress_frames": DEFAULT_STRESS_FRAMES,
            },
            "neighbor_proposal_contract": {
                "domain": "integer offsets in [-radius,+radius]^2 excluding the center",
                "selection": "uniform discrete partial Fisher-Yates without replacement",
                "first_version": "one fixed-K spatial round",
            },
            "spatial_contract": {
                "effective_M": "min(neighbor.M, spatial_M_cap)",
                "merge_mass": "p_hat_center * J_center_over_source * V * neighbor.W * effective_M",
                "invalid_mapping": "adds neither mass nor M",
                "zero_visibility_or_target": "adds zero mass but retains effective_M after a valid mapping",
                "hit_jacobian": "G(center, endpoint) / G(source, endpoint), single sided",
                "sky_jacobian": "one in the world-direction domain",
                "output_W": "merged_mass / (merged_M * selected_target), with no positive floor",
            },
            "feedback_policy": "this reference validates one current-frame spatial round and does not feed spatial output into future temporal history",
            "gpu_scope": "not implemented or accepted by this CPU-only schema",
            "cases": [result.__dict__ for result in self.results],
            "failure_count": len(failures),
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Deterministic CPU reference for HDDAGI screen-probe Phase 3 spatial ReSTIR."
    )
    parser.add_argument("--trials", type=int, default=DEFAULT_TRIALS)
    parser.add_argument("--stress-frames", type=int, default=DEFAULT_STRESS_FRAMES)
    parser.add_argument("--json-output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.trials < MIN_DIAGNOSTIC_TRIALS:
        print(f"--trials must be at least {MIN_DIAGNOSTIC_TRIALS}", file=sys.stderr)
        return 2
    if args.stress_frames < DEFAULT_STRESS_FRAMES:
        print(f"--stress-frames must be at least {DEFAULT_STRESS_FRAMES}", file=sys.stderr)
        return 2

    result = ReferenceSuite(args.trials, args.stress_frames).execute()
    encoded = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        temporary = args.json_output.with_suffix(args.json_output.suffix + ".tmp")
        temporary.write_text(encoded, encoding="utf-8")
        os.replace(temporary, args.json_output)

    print(
        "HDDAGI_PHASE3_CPU_REFERENCE "
        + json.dumps(
            {
                "schema_version": result["schema_version"],
                "status": result["status"],
                "acceptance_ready": result["acceptance_ready"],
                "cases": len(result["cases"]),
                "failures": result["failure_count"],
                "trials": result["trials_per_uniform_neighbor_proposal"],
                "stress_frames": result["stress_frames"],
            },
            separators=(",", ":"),
        )
    )
    if result["status"] != "completed":
        for case in result["cases"]:
            if case["status"] != "passed":
                print(f"FAILED {case['name']}: {case['error']}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

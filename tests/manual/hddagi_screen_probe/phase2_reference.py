#!/usr/bin/env python3
"""Deterministic CPU reference for Phase 2 temporal screen-probe ReSTIR.

This module intentionally has no Godot or third-party dependency.  It defines
the first uncompressed Phase 2 reservoir contract in executable form:

* scalar-target, vector-valued fresh RIS;
* compressed temporal stream merge using ``p_current * J * W * M_eff`` after
  current visibility has accepted the reconnected endpoint;
* integer M caps, age, generation and endpoint-geometry rejection, with
  current-frame transport/content re-evaluation;
* single-sided hit-endpoint Jacobians and a separate sky-direction domain;
* an explicit float32/integer packing round trip; and
* a deterministic multi-frame finite-value stress test.

Python binary64 is used for analytic references.  Values crossing the proposed
GPU ABI are rounded explicitly to IEEE-754 binary32 after every arithmetic
operation where the shader contract requires it.
"""

from __future__ import annotations

import argparse
import itertools
import json
import math
import os
import struct
import sys
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Callable, Iterable


PI = math.pi
TAU = math.tau
UINT32_MAX = 0xFFFFFFFF
HASH_FLOAT_DENOMINATOR = float(0x01000000)
DEFAULT_TRIALS = 65_536
DEFAULT_STRESS_FRAMES = 1_000
PHASE2_ALGORITHM_VERSION = 2
PHASE2_GPU_GOLDEN_DIGEST_SCHEMA_VERSION = 3
# Updated below whenever the schema-3 zero-current-target compressed-stream
# fixture or the seven-atlas logical ABI intentionally changes.
PHASE2_GPU_GOLDEN_DIGEST = (1_732_415_082, 1_862_592_035, 4_118_877_682, 2_283_234_717)

DOMAIN_HIT = 1
DOMAIN_SKY = 2
SAMPLE_FLAG_VALID = 1 << 0

GPU_RESERVOIR_VALID = 1 << 0
GPU_RESERVOIR_HIT = 1 << 1
GPU_RESERVOIR_SKY = 1 << 2
GPU_RESERVOIR_SELECTED_HISTORY = 1 << 3
GPU_RESERVOIR_ROBUST_CLAMPED = 1 << 4
GPU_RESERVOIR_ENDPOINT_REUSABLE = 1 << 5

REJECT_NONE = "accepted"
REJECT_NO_HISTORY = "no_history"
REJECT_ALGORITHM_VERSION = "algorithm_version"
REJECT_GENERATION = "generation"
REJECT_RECEIVER_IDENTITY = "receiver_identity"
REJECT_ENDPOINT_IDENTITY = "endpoint_identity"
REJECT_AGE = "age"
REJECT_VISIBILITY = "visibility"
REJECT_JACOBIAN = "jacobian"
REJECT_TARGET = "target"
ACCEPT_VISIBILITY_ZERO = "visibility_zero"

Vec2 = tuple[float, float]
Vec3 = tuple[float, float, float]


def temporal_reproject_jitter_neutral_2d(
    current_grid_uv: Vec2, current_stable_uv: Vec2, previous_stable_uv: Vec2
) -> Vec2:
    """CPU form of current_grid_uv + (previous_stable_uv - current_stable_uv)."""

    return (
        current_grid_uv[0] + previous_stable_uv[0] - current_stable_uv[0],
        current_grid_uv[1] + previous_stable_uv[1] - current_stable_uv[1],
    )


def bilinear_history_footprint(texel: Vec2) -> list[tuple[tuple[int, int], float]]:
    """Return the unclamped 2x2 footprint used by P2 and P2A."""

    base = (math.floor(texel[0]), math.floor(texel[1]))
    fraction = (texel[0] - base[0], texel[1] - base[1])
    return [
        (
            (base[0] + x, base[1] + y),
            (1.0 - fraction[0] if x == 0 else fraction[0])
            * (1.0 - fraction[1] if y == 0 else fraction[1]),
        )
        for y in range(2)
        for x in range(2)
    ]


def probe_axis_history_texel(grid_uv: float, gi_extent: int, probe_extent: int) -> float:
    """Map grid UV through the real centers of a possibly clipped edge probe tile."""

    safe_probe_extent = max(probe_extent, 1)
    atlas_extent = max((gi_extent + safe_probe_extent - 1) // safe_probe_extent, 1)
    grid_pixel = grid_uv * gi_extent
    last_origin = (atlas_extent - 1) * safe_probe_extent
    last_center = (last_origin + gi_extent) * 0.5
    if atlas_extent <= 1:
        return (grid_pixel - last_center) / max(min(safe_probe_extent, gi_extent), 1)
    previous_center = (atlas_extent - 1.5) * safe_probe_extent
    previous_texel = atlas_extent - 2
    if grid_pixel >= previous_center:
        return previous_texel + (grid_pixel - previous_center) / max(
            last_center - previous_center, 1e-6
        )
    return grid_pixel / safe_probe_extent - 0.5


def u32(value: int) -> int:
    return value & UINT32_MAX


def f32(value: float) -> float:
    return struct.unpack("<f", struct.pack("<f", value))[0]


def f32_bits(value: float) -> int:
    return struct.unpack("<I", struct.pack("<f", f32(value)))[0]


def bits_f32(value: int) -> float:
    return struct.unpack("<f", struct.pack("<I", u32(value)))[0]


def fadd(first: float, second: float) -> float:
    return f32(f32(first) + f32(second))


def fmul(first: float, second: float) -> float:
    return f32(f32(first) * f32(second))


def fdiv(numerator: float, denominator: float) -> float:
    return f32(f32(numerator) / f32(denominator))


def finite_positive(value: float) -> bool:
    return math.isfinite(value) and value > 0.0


def hash_uvec3(value: tuple[int, int, int]) -> int:
    """Bit-exact scalar port of hddagi_screen_probe_phase1.glsl::hash_uvec3."""

    v = [u32(component * 1_664_525 + 1_013_904_223) for component in value]
    v[0] = u32(v[0] + u32(v[1] * v[2]))
    v[1] = u32(v[1] + u32(v[2] * v[0]))
    v[2] = u32(v[2] + u32(v[0] * v[1]))
    v = [u32(component ^ (component >> 16)) for component in v]
    v[0] = u32(v[0] + u32(v[1] * v[2]))
    return u32(v[0] ^ v[1] ^ v[2])


def hash_float(value: tuple[int, int, int]) -> float:
    return f32(float(hash_uvec3(value) & 0x00FFFFFF) / HASH_FLOAT_DENOMINATOR)


def phase2_random(
    probe_position: tuple[int, int], dimension: int, local_sequence: int, view_index: int
) -> float:
    stream = u32(u32(local_sequence * 0x9E3779B9) + u32(view_index * 0x85EBCA6B))
    return hash_float(
        (
            u32(probe_position[0]) ^ stream,
            u32(probe_position[1]) ^ (stream >> 16),
            u32(u32(dimension * 0xC2B2AE35) + stream),
        )
    )


def add(first: Vec3, second: Vec3) -> Vec3:
    return first[0] + second[0], first[1] + second[1], first[2] + second[2]


def subtract(first: Vec3, second: Vec3) -> Vec3:
    return first[0] - second[0], first[1] - second[1], first[2] - second[2]


def mul_scalar(value: Vec3, scalar: float) -> Vec3:
    return value[0] * scalar, value[1] * scalar, value[2] * scalar


def dot(first: Vec3, second: Vec3) -> float:
    return first[0] * second[0] + first[1] * second[1] + first[2] * second[2]


def length(value: Vec3) -> float:
    return math.sqrt(dot(value, value))


def normalize(value: Vec3) -> Vec3:
    vector_length = length(value)
    if not finite_positive(vector_length):
        raise ValueError("cannot normalize a zero or non-finite vector")
    return mul_scalar(value, 1.0 / vector_length)


def f32_vec(value: Vec3) -> Vec3:
    return f32(value[0]), f32(value[1]), f32(value[2])


def mean_vectors(values: Iterable[Vec3]) -> Vec3:
    total = (0.0, 0.0, 0.0)
    count = 0
    for value in values:
        total = add(total, value)
        count += 1
    return mul_scalar(total, 1.0 / max(float(count), 1.0))


def luminance(value: Vec3) -> float:
    return value[0] * 0.2126 + value[1] * 0.7152 + value[2] * 0.0722


def max_relative_error(actual: Vec3, expected: Vec3) -> float:
    return max(
        abs(actual[channel] - expected[channel]) / max(abs(expected[channel]), 1e-12)
        for channel in range(3)
    )


def assert_close(actual: float, expected: float, tolerance: float, label: str) -> None:
    if not math.isfinite(actual) or abs(actual - expected) > tolerance:
        raise AssertionError(
            f"{label}: expected {expected:.12g} +/- {tolerance:.3g}, got {actual:.12g}"
        )


def assert_f32_bits(actual: float, expected_bits: int, label: str) -> None:
    actual_bits = f32_bits(actual)
    if actual_bits != expected_bits:
        raise AssertionError(
            f"{label}: expected float32 bits 0x{expected_bits:08x}, got 0x{actual_bits:08x}"
        )


def cosine_sample_hemisphere(sample: tuple[float, float]) -> Vec3:
    radius = math.sqrt(max(sample[0], 0.0))
    phi = TAU * sample[1]
    return (
        radius * math.cos(phi),
        radius * math.sin(phi),
        math.sqrt(max(0.0, 1.0 - sample[0])),
    )


def cosine_pdf(direction: Vec3) -> float:
    return max(direction[2], 0.0) / PI


@dataclass(frozen=True)
class SurfaceIdentity:
    geometry_id: int
    geometry_version: int
    material_id: int


@dataclass(frozen=True)
class ScreenProbeSample:
    sample_id: int
    domain: int
    direction: Vec3
    endpoint_position: Vec3
    endpoint_normal: Vec3
    contribution: Vec3
    distance: float
    proposal_pdf: float
    geometry_id: int
    geometry_version: int
    content_version: int
    generation: int
    flags: int = SAMPLE_FLAG_VALID

    def is_valid(self) -> bool:
        scalar_values = (*self.direction, *self.endpoint_position, *self.endpoint_normal, *self.contribution, self.distance, self.proposal_pdf)
        return (
            self.domain in (DOMAIN_HIT, DOMAIN_SKY)
            and (self.flags & SAMPLE_FLAG_VALID) != 0
            and all(math.isfinite(value) for value in scalar_values)
            and finite_positive(length(self.direction))
            and finite_positive(self.proposal_pdf)
            and self.distance >= 0.0
            and 0 <= self.sample_id <= UINT32_MAX
            and 0 <= self.geometry_id <= UINT32_MAX
            and 0 <= self.geometry_version <= UINT32_MAX
            and 0 <= self.content_version <= UINT32_MAX
            and 0 <= self.generation <= UINT32_MAX
        )


@dataclass
class ScreenProbeReservoir:
    selected: ScreenProbeSample | None = None
    target_selected: float = 0.0
    weight_sum: float = 0.0
    W: float = 0.0
    M: int = 0
    age: int = 0
    generation: int = 0
    algorithm_version: int = PHASE2_ALGORITHM_VERSION
    receiver_identity: SurfaceIdentity | None = None

    def is_valid(self) -> bool:
        return (
            self.selected is not None
            and self.selected.is_valid()
            and 0 < self.M <= UINT32_MAX
            and 0 <= self.age <= UINT32_MAX
            and finite_positive(self.target_selected)
            and finite_positive(self.weight_sum)
            and finite_positive(self.W)
        )

    def finalize(self) -> bool:
        if (
            self.selected is None
            or self.M <= 0
            or not finite_positive(self.weight_sum)
            or not finite_positive(self.target_selected)
        ):
            self.W = 0.0
            return False
        denominator = fmul(float(self.M), self.target_selected)
        if not finite_positive(denominator):
            self.W = 0.0
            return False
        self.W = fdiv(self.weight_sum, denominator)
        if not finite_positive(self.W):
            self.W = 0.0
            return False
        return True

    def estimate(self) -> Vec3:
        if not self.is_valid() or self.selected is None:
            return 0.0, 0.0, 0.0
        return tuple(fmul(component, self.W) for component in self.selected.contribution)  # type: ignore[return-value]


@dataclass(frozen=True)
class GpuReservoirPayload:
    """Exact 26-word logical view of the seven uncompressed GPU atlases."""

    owner_position: Vec3
    W: float
    direction: Vec3
    proposal_pdf: float
    endpoint_position: Vec3
    endpoint_distance: float
    radiance: Vec3
    target: float
    absolute_geometry_cell: tuple[int, int, int]
    hit_cascade: int
    hit_face: tuple[int, int, int]
    region_version: int
    endpoint_normal: Vec3
    owner_normal: Vec3
    M: int
    age: int
    generation: int
    algorithm_version: int
    flags: int


def reservoir_update(
    reservoir: ScreenProbeReservoir,
    sample: ScreenProbeSample,
    target: float,
    mass: float,
    represented_count: int,
    random_value: float,
    selected_age: int,
) -> bool:
    """Perform one float32 weighted-reservoir update.

    M counts valid source samples even when their scalar mass is zero.  A zero
    mass cannot replace the selected item, and a non-finite mass invalidates the
    update rather than being silently clamped.
    """

    if not sample.is_valid() or represented_count <= 0:
        return False
    if represented_count > UINT32_MAX - reservoir.M:
        return False
    mass = f32(mass)
    target = f32(target)
    random_value = f32(random_value)
    if not math.isfinite(mass) or mass < 0.0 or not math.isfinite(target):
        return False
    if not math.isfinite(random_value) or not 0.0 <= random_value < 1.0:
        return False

    new_weight_sum = fadd(reservoir.weight_sum, mass)
    if not math.isfinite(new_weight_sum) or new_weight_sum < reservoir.weight_sum:
        return False
    replace_selected = False
    if mass > 0.0 and finite_positive(target):
        replace_selected = reservoir.selected is None or fmul(random_value, new_weight_sum) < mass

    reservoir.weight_sum = new_weight_sum
    reservoir.M += represented_count
    if replace_selected:
        reservoir.selected = sample
        reservoir.target_selected = target
        reservoir.age = selected_age
    return True


def fresh_reservoir(
    samples: list[ScreenProbeSample],
    random_values: list[float],
    receiver_identity: SurfaceIdentity,
    generation: int,
) -> ScreenProbeReservoir:
    if len(samples) != len(random_values):
        raise ValueError("fresh sample/random streams must have equal length")
    reservoir = ScreenProbeReservoir(
        generation=generation,
        algorithm_version=PHASE2_ALGORITHM_VERSION,
        receiver_identity=receiver_identity,
    )
    for sample, random_value in zip(samples, random_values):
        target = f32(luminance(sample.contribution))
        weight = fdiv(target, sample.proposal_pdf) if finite_positive(sample.proposal_pdf) else math.nan
        if not reservoir_update(reservoir, sample, target, weight, 1, random_value, 0):
            raise ValueError("invalid fresh reservoir input")
    reservoir.finalize()
    return reservoir


def geometry_term(receiver_position: Vec3, endpoint_position: Vec3, endpoint_normal: Vec3) -> float:
    """Single-sided endpoint geometry term.

    The endpoint normal faces the receiver only when ``dot(n_y, x-y) > 0``.
    Deliberately do not use abs(dot): a back-face reconnection must be rejected.
    """

    connection = subtract(receiver_position, endpoint_position)
    distance_squared = dot(connection, connection)
    if not math.isfinite(distance_squared) or distance_squared <= 1e-12:
        return 0.0
    direction_to_receiver = mul_scalar(connection, 1.0 / math.sqrt(distance_squared))
    endpoint_cosine = max(dot(endpoint_normal, direction_to_receiver), 0.0)
    if not finite_positive(endpoint_cosine):
        return 0.0
    return endpoint_cosine / distance_squared


def hit_reconnection_jacobian(
    history_receiver_position: Vec3,
    current_receiver_position: Vec3,
    endpoint_position: Vec3,
    endpoint_normal: Vec3,
) -> float:
    history_term = geometry_term(history_receiver_position, endpoint_position, endpoint_normal)
    current_term = geometry_term(current_receiver_position, endpoint_position, endpoint_normal)
    if not finite_positive(history_term) or not finite_positive(current_term):
        return 0.0
    jacobian = current_term / history_term
    return jacobian if finite_positive(jacobian) else 0.0


def apply_jacobian_policy(jacobian: float, jacobian_max: float, robust_mode: bool) -> tuple[float, bool]:
    """Mirror the shader's strict/robust Jacobian policy after validity checks."""

    if not finite_positive(jacobian) or not math.isfinite(jacobian_max) or jacobian_max < 1.0:
        raise ValueError("Jacobian policy requires J > 0 and Jmax >= 1")
    if not robust_mode:
        return f32(jacobian), False
    clamped = f32(max(1.0 / jacobian_max, min(jacobian, jacobian_max)))
    return clamped, clamped != f32(jacobian)


@dataclass(frozen=True)
class TemporalContext:
    receiver_identity: SurfaceIdentity
    generation: int
    algorithm_version: int
    endpoint_geometry_id: int
    endpoint_geometry_version: int
    content_version: int
    history_receiver_position: Vec3
    current_receiver_position: Vec3
    current_contribution: Vec3
    current_target: float
    visibility: bool
    m_cap: int
    max_age: int


@dataclass(frozen=True)
class TemporalDecision:
    accepted: bool
    reason: str
    jacobian: float = 0.0
    effective_M: int = 0
    merge_mass: float = 0.0
    cap_applied: bool = False
    reconnected_sample: ScreenProbeSample | None = None


def evaluate_temporal_candidate(
    history: ScreenProbeReservoir | None,
    context: TemporalContext,
) -> TemporalDecision:
    if history is None or not history.is_valid() or history.selected is None:
        return TemporalDecision(False, REJECT_NO_HISTORY)
    sample = history.selected
    if history.algorithm_version != context.algorithm_version:
        return TemporalDecision(False, REJECT_ALGORITHM_VERSION)
    if history.generation != context.generation or sample.generation != context.generation:
        return TemporalDecision(False, REJECT_GENERATION)
    if history.receiver_identity != context.receiver_identity:
        return TemporalDecision(False, REJECT_RECEIVER_IDENTITY)
    if history.age >= context.max_age:
        return TemporalDecision(False, REJECT_AGE)
    if sample.domain == DOMAIN_HIT and (
        sample.geometry_id != context.endpoint_geometry_id
        or sample.geometry_version != context.endpoint_geometry_version
    ):
        return TemporalDecision(False, REJECT_ENDPOINT_IDENTITY)

    effective_M = min(history.M, max(context.m_cap, 0))
    if effective_M <= 0:
        return TemporalDecision(False, REJECT_TARGET)
    cap_applied = history.M > effective_M
    if not context.visibility:
        # Endpoint mapping is valid, but the selected historical sample has
        # zero current visibility. Its compressed stream still contributes M;
        # only its current mass is zero.
        return TemporalDecision(
            True,
            ACCEPT_VISIBILITY_ZERO,
            effective_M=effective_M,
            merge_mass=0.0,
            cap_applied=cap_applied,
            reconnected_sample=replace(
                sample,
                contribution=(0.0, 0.0, 0.0),
                content_version=context.content_version,
                generation=context.generation,
            ),
        )
    if not math.isfinite(context.current_target) or context.current_target < 0.0 or any(
        not math.isfinite(component) for component in context.current_contribution
    ):
        return TemporalDecision(False, REJECT_TARGET)

    if sample.domain == DOMAIN_HIT:
        jacobian = hit_reconnection_jacobian(
            context.history_receiver_position,
            context.current_receiver_position,
            sample.endpoint_position,
            sample.endpoint_normal,
        )
        if not finite_positive(jacobian):
            return TemporalDecision(False, REJECT_JACOBIAN)
    elif sample.domain == DOMAIN_SKY:
        # A sky sample remains in the direction domain.  It is not assigned a
        # fabricated finite endpoint or surface geometry term.
        jacobian = 1.0
    else:
        return TemporalDecision(False, REJECT_ENDPOINT_IDENTITY)

    merge_mass = fmul(
        fmul(fmul(context.current_target, jacobian), history.W),
        float(effective_M),
    )
    if not math.isfinite(merge_mass) or merge_mass < 0.0:
        return TemporalDecision(False, REJECT_TARGET)
    reconnected_sample = replace(
        sample,
        contribution=f32_vec(context.current_contribution),
        content_version=context.content_version,
        generation=context.generation,
    )
    return TemporalDecision(
        True,
        REJECT_NONE,
        jacobian=f32(jacobian),
        effective_M=effective_M,
        merge_mass=merge_mass,
        cap_applied=cap_applied,
        reconnected_sample=reconnected_sample,
    )


def merge_temporal(
    current: ScreenProbeReservoir,
    history: ScreenProbeReservoir | None,
    context: TemporalContext,
    random_value: float,
) -> TemporalDecision:
    decision = evaluate_temporal_candidate(history, context)
    if not decision.accepted or decision.reconnected_sample is None or history is None:
        current.finalize()
        return decision
    if not reservoir_update(
        current,
        decision.reconnected_sample,
        context.current_target,
        decision.merge_mass,
        decision.effective_M,
        random_value,
        history.age + 1,
    ):
        current.finalize()
        return TemporalDecision(False, REJECT_TARGET)
    current.finalize()
    return decision


def _sign_not_zero(value: float) -> float:
    return -1.0 if value < 0.0 else 1.0


def oct_encode(direction: Vec3) -> tuple[float, float]:
    direction = normalize(direction)
    divisor = abs(direction[0]) + abs(direction[1]) + abs(direction[2])
    x = direction[0] / divisor
    y = direction[1] / divisor
    if direction[2] < 0.0:
        x, y = (
            (1.0 - abs(y)) * _sign_not_zero(x),
            (1.0 - abs(x)) * _sign_not_zero(y),
        )
    return x, y


def oct_decode(encoded: tuple[float, float]) -> Vec3:
    x, y = encoded
    result = [x, y, 1.0 - abs(x) - abs(y)]
    if result[2] < 0.0:
        old_x = result[0]
        result[0] = (1.0 - abs(result[1])) * _sign_not_zero(old_x)
        result[1] = (1.0 - abs(old_x)) * _sign_not_zero(result[1])
    return normalize((result[0], result[1], result[2]))


def _round_nearest_even(value: float) -> int:
    """Mirror GLSL roundEven for deterministic half-way packing cases."""

    return int(round(value))


def pack_snorm_2x16(value: tuple[float, float]) -> int:
    packed = []
    for component in value:
        if not math.isfinite(component):
            raise ValueError("cannot pack a non-finite snorm")
        integer = _round_nearest_even(max(-1.0, min(1.0, component)) * 32767.0)
        packed.append(integer & 0xFFFF)
    return packed[0] | (packed[1] << 16)


def unpack_snorm_2x16(value: int) -> tuple[float, float]:
    result = []
    for shift in (0, 16):
        component = (value >> shift) & 0xFFFF
        if component & 0x8000:
            component -= 0x10000
        result.append(max(float(component) / 32767.0, -1.0))
    return result[0], result[1]


def pack_surface_normal_gpu(normal: Vec3) -> int:
    normal_length_squared = dot(normal, normal)
    if not all(math.isfinite(component) for component in normal) or not normal_length_squared > 1e-10:
        normal = (0.0, 0.0, 1.0)
    else:
        normal = mul_scalar(normal, 1.0 / math.sqrt(normal_length_squared))
    oct_x, oct_y = oct_encode(normal)
    uv_x = max(0.0, min(1.0, oct_x * 0.5 + 0.5))
    uv_y = max(0.0, min(1.0, oct_y * 0.5 + 0.5))
    packed_x = _round_nearest_even(uv_x * 65_535.0)
    packed_y = _round_nearest_even(uv_y * 32_767.0)
    return u32(packed_x | (packed_y << 16))


def unpack_surface_normal_gpu(packed: int) -> Vec3:
    uv_x = float(packed & 0xFFFF) / 65_535.0
    uv_y = float((packed >> 16) & 0x7FFF) / 32_767.0
    return oct_decode((uv_x * 2.0 - 1.0, uv_y * 2.0 - 1.0))


def face_index_gpu(face: tuple[int, int, int]) -> int:
    return {
        (-1, 0, 0): 0,
        (1, 0, 0): 1,
        (0, -1, 0): 2,
        (0, 1, 0): 3,
        (0, 0, -1): 4,
        (0, 0, 1): 5,
    }.get(face, 7)


def face_from_index_gpu(face_index: int) -> tuple[int, int, int]:
    faces = (
        (-1, 0, 0),
        (1, 0, 0),
        (0, -1, 0),
        (0, 1, 0),
        (0, 0, -1),
        (0, 0, 1),
    )
    return faces[face_index] if 0 <= face_index < len(faces) else (0, 0, 0)


def signed_i32(value: int) -> int:
    value = u32(value)
    return value - 0x1_0000_0000 if value & 0x8000_0000 else value


def pack_gpu_reservoir(payload: GpuReservoirPayload) -> list[int]:
    scalar_floats = (
        *payload.owner_position,
        payload.W,
        *payload.direction,
        payload.proposal_pdf,
        *payload.endpoint_position,
        payload.endpoint_distance,
        *payload.radiance,
        payload.target,
        *payload.endpoint_normal,
        *payload.owner_normal,
    )
    if not all(math.isfinite(value) for value in scalar_floats):
        raise ValueError("cannot pack a non-finite GPU reservoir")
    if payload.flags & GPU_RESERVOIR_ENDPOINT_REUSABLE:
        if not 0 <= payload.hit_cascade < 256 or face_index_gpu(payload.hit_face) >= 6:
            raise ValueError("reusable endpoint has an invalid cascade or face")
        if (payload.flags & GPU_RESERVOIR_HIT) == 0:
            raise ValueError("only a hit reservoir may carry a reusable endpoint")
    if not 0 <= payload.region_version <= 0xFFFF:
        raise ValueError("region version exceeds the 16-bit GPU field")
    if not 0 <= payload.algorithm_version <= 0xFF or not 0 <= payload.flags <= 0xFF:
        raise ValueError("algorithm or flags exceed the 8-bit GPU fields")
    if not 0 <= payload.M <= UINT32_MAX or not 0 <= payload.age <= UINT32_MAX:
        raise ValueError("M or age exceeds uint32")

    packed_identity = (max(payload.hit_cascade, 0) & 0xFF) | ((face_index_gpu(payload.hit_face) & 0x7) << 8)
    packed_version = (
        (payload.algorithm_version & 0xFF)
        | ((payload.flags & 0xFF) << 8)
        | ((payload.region_version & 0xFFFF) << 16)
    )
    words = [
        *(f32_bits(value) for value in (*payload.owner_position, payload.W)),
        *(f32_bits(value) for value in (*payload.direction, payload.proposal_pdf)),
        *(f32_bits(value) for value in (*payload.endpoint_position, payload.endpoint_distance)),
        *(f32_bits(value) for value in (*payload.radiance, payload.target)),
        *(u32(value) for value in payload.absolute_geometry_cell),
        u32(packed_identity),
        u32(payload.M),
        u32(payload.age),
        pack_surface_normal_gpu(payload.endpoint_normal),
        pack_surface_normal_gpu(payload.owner_normal),
        u32(payload.generation),
        u32(packed_version),
    ]
    if len(words) != 26:
        raise AssertionError(f"GPU reservoir ABI must contain 26 words, got {len(words)}")
    return words


def digest_gpu_reservoir_words(words: list[int]) -> list[int]:
    """128-bit digest used by the real-shader Phase 2 conformance probe.

    The GPU writes only these four words into otherwise unused statistics
    slots. The complete 26-word CPU golden remains in the reference JSON, so a
    digest mismatch is diagnosable without expanding the production readback.
    """

    if len(words) != 26:
        raise ValueError(f"GPU reservoir ABI must contain 26 uint32 words, got {len(words)}")
    digest = [0x811C9DC5, 0x9E3779B9, 0x243F6A88, 0xB7E15162]
    primes = [0x01000193, 0x85EBCA6B, 0xC2B2AE35, 0x27D4EB2F]
    for index, word in enumerate(words):
        mixed_word = u32(word + u32(index * 0x9E3779B9))
        digest = [u32((lane ^ mixed_word) * prime) for lane, prime in zip(digest, primes)]
    digest = [u32(lane ^ (lane >> 16)) for lane in digest]
    digest = [u32(lane * 0x85EBCA6B) for lane in digest]
    digest = [u32(lane ^ (lane >> 13)) for lane in digest]
    digest = [u32(lane * 0xC2B2AE35) for lane in digest]
    return [u32(lane ^ (lane >> 16)) for lane in digest]


@dataclass(frozen=True)
class GpuCompressedStreamMerge:
    effective_history_M: int
    merged_M: int
    fresh_mass: float
    history_mass: float
    merged_mass: float
    output_W: float
    selected_history: bool
    cap_applied: bool
    mass_valid: bool
    output_valid: bool


def gpu_compressed_stream_mass(target: float, weight: float, represented_count: int) -> float:
    return fmul(fmul(target, weight), float(represented_count))


def gpu_merge_compressed_stream(
    fresh_target: float,
    fresh_weight: float,
    fresh_M: int,
    history_weight: float,
    history_M: int,
    history_M_cap: int,
    current_target: float,
    jacobian: float,
    visible: bool,
    selection_random: float,
) -> GpuCompressedStreamMerge:
    """Independent float32 port of the production compressed-stream helper."""

    effective_history_M = min(history_M, history_M_cap)
    fresh_mass = gpu_compressed_stream_mass(fresh_target, fresh_weight, fresh_M)
    history_mass = (
        gpu_compressed_stream_mass(fmul(current_target, jacobian), history_weight, effective_history_M)
        if visible
        else 0.0
    )
    merged_mass = fadd(fresh_mass, history_mass)
    mass_valid = (
        math.isfinite(fresh_mass)
        and fresh_mass >= 0.0
        and math.isfinite(history_mass)
        and history_mass >= 0.0
        and math.isfinite(merged_mass)
        and merged_mass >= fresh_mass
    )
    selected_history = (
        mass_valid
        and history_mass > 0.0
        and fmul(selection_random, merged_mass) < history_mass
    )
    selected_target = current_target if selected_history else fresh_target
    merged_M = fresh_M + effective_history_M
    output_valid = mass_valid and merged_mass > 0.0 and selected_target > 0.0 and merged_M > 0
    output_W = 0.0
    if output_valid:
        output_W = fdiv(merged_mass, fmul(float(merged_M), selected_target))
        output_valid = math.isfinite(output_W) and output_W >= 0.0
    return GpuCompressedStreamMerge(
        effective_history_M=effective_history_M,
        merged_M=merged_M,
        fresh_mass=fresh_mass,
        history_mass=history_mass,
        merged_mass=merged_mass,
        output_W=output_W,
        selected_history=selected_history,
        cap_applied=effective_history_M < history_M,
        mass_valid=mass_valid,
        output_valid=output_valid,
    )


def unpack_gpu_reservoir(words: list[int]) -> GpuReservoirPayload:
    if len(words) != 26:
        raise ValueError(f"GPU reservoir ABI must contain 26 uint32 words, got {len(words)}")
    identity = words[19]
    version = words[25]
    return GpuReservoirPayload(
        owner_position=tuple(bits_f32(words[index]) for index in range(3)),  # type: ignore[arg-type]
        W=bits_f32(words[3]),
        direction=tuple(bits_f32(words[index]) for index in range(4, 7)),  # type: ignore[arg-type]
        proposal_pdf=bits_f32(words[7]),
        endpoint_position=tuple(bits_f32(words[index]) for index in range(8, 11)),  # type: ignore[arg-type]
        endpoint_distance=bits_f32(words[11]),
        radiance=tuple(bits_f32(words[index]) for index in range(12, 15)),  # type: ignore[arg-type]
        target=bits_f32(words[15]),
        absolute_geometry_cell=tuple(signed_i32(words[index]) for index in range(16, 19)),  # type: ignore[arg-type]
        hit_cascade=identity & 0xFF,
        hit_face=face_from_index_gpu((identity >> 8) & 0x7),
        region_version=version >> 16,
        endpoint_normal=unpack_surface_normal_gpu(words[22]),
        owner_normal=unpack_surface_normal_gpu(words[23]),
        M=words[20],
        age=words[21],
        generation=words[24],
        algorithm_version=version & 0xFF,
        flags=(version >> 8) & 0xFF,
    )


@dataclass
class CaseResult:
    name: str
    status: str
    metrics: dict[str, object]
    error: str = ""


class ReferenceSuite:
    def __init__(self, trials: int, stress_frames: int) -> None:
        self.trials = trials
        self.stress_frames = stress_frames
        self.results: list[CaseResult] = []
        self.gpu_golden_vectors: dict[str, object] = {}

    def run_case(self, name: str, function: Callable[[], dict[str, object]]) -> None:
        try:
            metrics = function()
        except Exception as exception:  # Preserve every independent failure in JSON.
            self.results.append(CaseResult(name, "failed", {}, str(exception)))
        else:
            self.results.append(CaseResult(name, "passed", metrics))

    @staticmethod
    def _sample(
        sample_id: int,
        domain: int = DOMAIN_HIT,
        contribution: Vec3 = (0.8, 0.4, 0.2),
        proposal_pdf: float = 0.25,
        geometry_id: int = 101,
        geometry_version: int = 7,
        content_version: int = 5,
        generation: int = 9,
    ) -> ScreenProbeSample:
        return ScreenProbeSample(
            sample_id=sample_id,
            domain=domain,
            direction=normalize((0.2, -0.1, 1.0)),
            endpoint_position=(0.0, 0.0, 2.0),
            endpoint_normal=(0.0, 0.0, -1.0),
            contribution=f32_vec(contribution),
            distance=f32(2.0),
            proposal_pdf=f32(proposal_pdf),
            geometry_id=geometry_id,
            geometry_version=geometry_version,
            content_version=content_version,
            generation=generation,
        )

    def test_fixed_float32_stream(self) -> dict[str, object]:
        reservoir = ScreenProbeReservoir(
            generation=9,
            receiver_identity=SurfaceIdentity(1, 2, 3),
        )
        samples = [
            self._sample(10, contribution=(1.0, 1.0, 1.0), proposal_pdf=1.0),
            self._sample(11, contribution=(3.0, 3.0, 3.0), proposal_pdf=1.0),
            self._sample(12, contribution=(6.0, 6.0, 6.0), proposal_pdf=1.0),
        ]
        for sample, target, mass, random_value in zip(
            samples,
            (1.0, 3.0, 6.0),
            (1.0, 3.0, 6.0),
            (0.0, 0.2, 0.8),
        ):
            if not reservoir_update(reservoir, sample, target, mass, 1, random_value, 0):
                raise AssertionError("fixed weighted update unexpectedly failed")
        if not reservoir.finalize() or reservoir.selected is None:
            raise AssertionError("fixed reservoir did not finalize")
        if reservoir.selected.sample_id != 11 or reservoir.M != 3:
            raise AssertionError("fixed reservoir selected sample or M changed")
        assert_f32_bits(reservoir.weight_sum, 0x41200000, "fixed.weight_sum")
        assert_f32_bits(reservoir.W, 0x3F8E38E4, "fixed.W")

        hashes = [hash_uvec3((17, 29, index)) for index in range(4)]
        expected_hashes = [1_354_554_870, 856_290_719, 3_701_420_271, 10_428_931]
        if hashes != expected_hashes:
            raise AssertionError(f"fixed hash stream changed: {hashes}")
        phase2_random_bits = [
            f32_bits(phase2_random((17, 29), dimension, 12_345, 1))
            for dimension in range(6)
        ]
        expected_phase2_random_bits = [
            0x3F20BD1B,
            0x3E90CB52,
            0x3E2F8164,
            0x3F258845,
            0x3EC07BFE,
            0x3F144131,
        ]
        if phase2_random_bits != expected_phase2_random_bits:
            raise AssertionError(f"Phase 2 local random stream changed: {phase2_random_bits}")

        selected_sample_id = reservoir.selected.sample_id
        gpu_merge = gpu_merge_compressed_stream(
            fresh_target=reservoir.target_selected,
            fresh_weight=reservoir.W,
            fresh_M=reservoir.M,
            history_weight=0.5,
            history_M=9,
            history_M_cap=4,
            current_target=2.0,
            jacobian=1.5,
            visible=True,
            selection_random=0.25,
        )
        if not (
            gpu_merge.cap_applied
            and gpu_merge.mass_valid
            and gpu_merge.output_valid
            and gpu_merge.selected_history
            and gpu_merge.effective_history_M == 4
            and gpu_merge.merged_M == 7
        ):
            raise AssertionError("fixed GPU compressed temporal stream did not cap and select history")
        zero_target_gpu_merge = gpu_merge_compressed_stream(
            fresh_target=reservoir.target_selected,
            fresh_weight=reservoir.W,
            fresh_M=reservoir.M,
            history_weight=0.5,
            history_M=9,
            history_M_cap=4,
            current_target=0.0,
            jacobian=1.5,
            visible=True,
            selection_random=0.25,
        )
        if not (
            zero_target_gpu_merge.cap_applied
            and zero_target_gpu_merge.mass_valid
            and zero_target_gpu_merge.output_valid
            and not zero_target_gpu_merge.selected_history
            and zero_target_gpu_merge.history_mass == 0.0
            and zero_target_gpu_merge.effective_history_M == 4
            and zero_target_gpu_merge.merged_M == 7
        ):
            raise AssertionError(
                "fixed GPU zero-current-target stream did not preserve M with zero history mass"
            )
        golden_generation = u32(
            (
                0x00313233
                ^ f32_bits(zero_target_gpu_merge.output_W)
                ^ zero_target_gpu_merge.merged_M
            )
            & 0x00FFFFFF
        )
        gpu_payload = GpuReservoirPayload(
            owner_position=(1.0, 2.0, 3.0),
            W=gpu_merge.output_W,
            direction=(0.0, 0.0, 1.0),
            proposal_pdf=0.25,
            endpoint_position=(1.0, 2.0, 7.0),
            endpoint_distance=4.0,
            radiance=(2.0, 2.0, 2.0),
            target=2.0,
            absolute_geometry_cell=(-7, 8, 9),
            hit_cascade=3,
            hit_face=(0, 0, -1),
            region_version=0x1234,
            endpoint_normal=(0.0, 0.0, -1.0),
            owner_normal=(0.0, 0.0, 1.0),
            M=gpu_merge.merged_M,
            age=6,
            generation=golden_generation,
            algorithm_version=PHASE2_ALGORITHM_VERSION,
            flags=GPU_RESERVOIR_VALID | GPU_RESERVOIR_HIT | GPU_RESERVOIR_SELECTED_HISTORY | GPU_RESERVOIR_ENDPOINT_REUSABLE,
        )
        # Mirror current-atlas store/load: normals and packed metadata are
        # decoded by phase2_load_current before the logical ABI is repacked.
        gpu_words = pack_gpu_reservoir(unpack_gpu_reservoir(pack_gpu_reservoir(gpu_payload)))
        gpu_digest = digest_gpu_reservoir_words(gpu_words)
        if tuple(gpu_digest) != PHASE2_GPU_GOLDEN_DIGEST:
            raise AssertionError(
                f"GPU reservoir digest changed: expected {PHASE2_GPU_GOLDEN_DIGEST}, got {tuple(gpu_digest)}"
            )
        golden = {
            "selected_sample_id": reservoir.selected.sample_id,
            "M": reservoir.M,
            "weight_sum_bits": f"0x{f32_bits(reservoir.weight_sum):08x}",
            "target_selected_bits": f"0x{f32_bits(reservoir.target_selected):08x}",
            "W_bits": f"0x{f32_bits(reservoir.W):08x}",
            "phase2_random_bits": [f"0x{value:08x}" for value in phase2_random_bits],
            "compressed_temporal": {
                "history_W_bits": f"0x{f32_bits(0.5):08x}",
                "history_M": 9,
                "history_M_cap": 4,
                "effective_history_M": gpu_merge.effective_history_M,
                "current_target_bits": f"0x{f32_bits(2.0):08x}",
                "jacobian_bits": f"0x{f32_bits(1.5):08x}",
                "visibility": True,
                "selection_random_bits": f"0x{f32_bits(0.25):08x}",
                "fresh_mass_bits": f"0x{f32_bits(gpu_merge.fresh_mass):08x}",
                "history_mass_bits": f"0x{f32_bits(gpu_merge.history_mass):08x}",
                "merged_mass_bits": f"0x{f32_bits(gpu_merge.merged_mass):08x}",
                "merged_M": gpu_merge.merged_M,
                "selected_history": gpu_merge.selected_history,
                "output_W_bits": f"0x{f32_bits(gpu_merge.output_W):08x}",
            },
            "zero_current_target_compressed_temporal": {
                "history_W_bits": f"0x{f32_bits(0.5):08x}",
                "history_M": 9,
                "history_M_cap": 4,
                "effective_history_M": zero_target_gpu_merge.effective_history_M,
                "current_target_bits": f"0x{f32_bits(0.0):08x}",
                "history_mass_bits": f"0x{f32_bits(zero_target_gpu_merge.history_mass):08x}",
                "merged_mass_bits": f"0x{f32_bits(zero_target_gpu_merge.merged_mass):08x}",
                "merged_M": zero_target_gpu_merge.merged_M,
                "selected_history": zero_target_gpu_merge.selected_history,
                "output_W_bits": f"0x{f32_bits(zero_target_gpu_merge.output_W):08x}",
                "digest_generation": golden_generation,
            },
            "gpu_round_trip": "phase2_store_current -> memoryBarrierImage -> phase2_load_current -> repack current seven-atlas ABI",
            "previous_descriptor_bitwise_covered": False,
            "reservoir_abi_word_count": len(gpu_words),
            "reservoir_abi_words": [f"0x{word:08x}" for word in gpu_words],
            "reservoir_gpu_digest_schema_version": PHASE2_GPU_GOLDEN_DIGEST_SCHEMA_VERSION,
            "reservoir_gpu_digest": gpu_digest,
        }
        self.gpu_golden_vectors["fixed_weighted_update"] = golden
        return {"hashes": hashes, **golden}

    def test_packing_round_trip(self) -> dict[str, object]:
        payload = GpuReservoirPayload(
            owner_position=f32_vec((12_345.5, -0.03125, -987.0)),
            W=f32(0.625),
            direction=f32_vec(normalize((-0.31, 0.73, 0.61))),
            proposal_pdf=f32(0.1875),
            endpoint_position=f32_vec((1234.5, -0.03125, 65_504.0)),
            endpoint_distance=f32(321.125),
            radiance=f32_vec((0.0009765625, 17.25, 4096.0)),
            target=f32(1.75),
            absolute_geometry_cell=(-123_456, 0x1020304, -7),
            hit_cascade=5,
            hit_face=(0, -1, 0),
            region_version=0xBEEF,
            endpoint_normal=normalize((0.2, -0.9, -0.38)),
            owner_normal=normalize((-0.1, 0.97, 0.22)),
            M=60,
            age=17,
            generation=0x00313233,
            algorithm_version=PHASE2_ALGORITHM_VERSION,
            flags=GPU_RESERVOIR_VALID | GPU_RESERVOIR_HIT | GPU_RESERVOIR_SELECTED_HISTORY | GPU_RESERVOIR_ENDPOINT_REUSABLE,
        )
        packed = pack_gpu_reservoir(payload)
        unpacked = unpack_gpu_reservoir(packed)

        for original, restored, label in (
            (payload.owner_position, unpacked.owner_position, "owner_position"),
            (payload.direction, unpacked.direction, "direction"),
            (payload.endpoint_position, unpacked.endpoint_position, "endpoint_position"),
            (payload.radiance, unpacked.radiance, "radiance"),
        ):
            for channel in range(3):
                if f32_bits(original[channel]) != f32_bits(restored[channel]):
                    raise AssertionError(f"GPU packing changed {label}[{channel}] bits")
        for original, restored, label in (
            (payload.W, unpacked.W, "W"),
            (payload.proposal_pdf, unpacked.proposal_pdf, "proposal_pdf"),
            (payload.endpoint_distance, unpacked.endpoint_distance, "endpoint_distance"),
            (payload.target, unpacked.target, "target"),
        ):
            if f32_bits(original) != f32_bits(restored):
                raise AssertionError(f"GPU packing changed {label} bits")
        for field in (
            "absolute_geometry_cell",
            "hit_cascade",
            "hit_face",
            "region_version",
            "M",
            "age",
            "generation",
            "algorithm_version",
            "flags",
        ):
            if getattr(payload, field) != getattr(unpacked, field):
                raise AssertionError(f"GPU packing changed {field}")

        endpoint_normal_angle = math.acos(max(-1.0, min(1.0, dot(payload.endpoint_normal, unpacked.endpoint_normal))))
        owner_normal_angle = math.acos(max(-1.0, min(1.0, dot(payload.owner_normal, unpacked.owner_normal))))
        if endpoint_normal_angle > 0.0002 or owner_normal_angle > 0.0002:
            raise AssertionError("GPU surface-normal packing angular error exceeded 0.0002 rad")

        invalid_payload = replace(payload, radiance=(math.nan, 1.0, 1.0))
        try:
            pack_gpu_reservoir(invalid_payload)
        except ValueError:
            nonfinite_rejected = True
        else:
            nonfinite_rejected = False
        if not nonfinite_rejected:
            raise AssertionError("packing accepted a NaN contribution")

        maximum_f32 = bits_f32(0x7F7FFFFF)
        minimum_normal_f32 = bits_f32(0x00800000)
        boundary_payload = GpuReservoirPayload(
            owner_position=(maximum_f32, -maximum_f32, minimum_normal_f32),
            W=maximum_f32,
            direction=(0.0, 0.0, 1.0),
            proposal_pdf=minimum_normal_f32,
            endpoint_position=(0.0, 0.0, 0.0),
            endpoint_distance=0.0,
            radiance=(maximum_f32, minimum_normal_f32, 0.0),
            target=maximum_f32,
            absolute_geometry_cell=(-0x80000000, 0x7FFFFFFF, 0),
            hit_cascade=0,
            hit_face=(0, 0, 0),
            region_version=0xFFFF,
            endpoint_normal=(0.0, 0.0, 0.0),
            owner_normal=(0.0, 0.0, 1.0),
            M=UINT32_MAX,
            age=UINT32_MAX,
            generation=UINT32_MAX,
            algorithm_version=0xFF,
            flags=GPU_RESERVOIR_VALID | GPU_RESERVOIR_SKY | GPU_RESERVOIR_ROBUST_CLAMPED,
        )
        boundary_words = pack_gpu_reservoir(boundary_payload)
        boundary_unpacked = unpack_gpu_reservoir(boundary_words)
        if (
            f32_bits(boundary_unpacked.owner_position[0]) != 0x7F7FFFFF
            or f32_bits(boundary_unpacked.W) != 0x7F7FFFFF
            or boundary_unpacked.M != UINT32_MAX
            or boundary_unpacked.age != UINT32_MAX
            or boundary_unpacked.generation != UINT32_MAX
            or boundary_unpacked.region_version != 0xFFFF
            or dot(boundary_unpacked.endpoint_normal, (0.0, 0.0, 1.0)) < 0.99999999
        ):
            raise AssertionError("GPU boundary payload did not round-trip")
        if (_round_nearest_even(0.5), _round_nearest_even(1.5), _round_nearest_even(2.5)) != (0, 2, 2):
            raise AssertionError("roundEven half-way contract changed")

        infinite_payload = replace(payload, owner_position=(math.inf, 0.0, 0.0))
        try:
            pack_gpu_reservoir(infinite_payload)
        except ValueError:
            infinity_rejected = True
        else:
            infinity_rejected = False
        if not infinity_rejected:
            raise AssertionError("packing accepted an infinite payload")

        golden = {
            "word_count": len(packed),
            "words": [f"0x{word:08x}" for word in packed],
            "maximum_normal_angular_error_radians": max(endpoint_normal_angle, owner_normal_angle),
            "nonfinite_rejected": nonfinite_rejected,
            "infinity_rejected": infinity_rejected,
            "boundary_word_count": len(boundary_words),
            "boundary_max_M_age": UINT32_MAX,
            "rounding": "GLSL/Python roundEven",
            "atlas_layout": "owner4/sample4/endpoint4/radiance4/identity4/meta4/version2",
        }
        self.gpu_golden_vectors["packing_round_trip"] = golden
        return golden

    def test_stream_permutation_and_compression(self) -> dict[str, object]:
        samples = [
            self._sample(200 + index, contribution=(weight, weight, weight), proposal_pdf=1.0)
            for index, weight in enumerate((1.0, 2.0, 5.0))
        ]
        weights = (1.0, 2.0, 5.0)
        expected_probabilities = (0.125, 0.25, 0.625)
        permutation_trials = min(self.trials, 16_384)
        maximum_probability_error = 0.0
        permutation_metrics: dict[str, object] = {}
        for permutation_index, permutation in enumerate(itertools.permutations(range(3))):
            selected_counts = [0, 0, 0]
            for trial in range(permutation_trials):
                reservoir = ScreenProbeReservoir(generation=9)
                for step, sample_index in enumerate(permutation):
                    if not reservoir_update(
                        reservoir,
                        samples[sample_index],
                        weights[sample_index],
                        weights[sample_index],
                        1,
                        hash_float((trial, step, 0x6D2B79F5 ^ permutation_index)),
                        0,
                    ):
                        raise AssertionError("permuted stream update failed")
                if not reservoir.finalize() or reservoir.selected is None:
                    raise AssertionError("permuted stream did not finalize")
                if reservoir.M != 3 or f32_bits(reservoir.weight_sum) != f32_bits(8.0):
                    raise AssertionError("permutation changed represented M or total mass")
                selected_counts[reservoir.selected.sample_id - 200] += 1
            observed = tuple(count / float(permutation_trials) for count in selected_counts)
            probability_error = max(
                abs(observed[index] - expected_probabilities[index]) for index in range(3)
            )
            maximum_probability_error = max(maximum_probability_error, probability_error)
            if probability_error >= 0.04:
                raise AssertionError(
                    f"permutation {permutation} selection error {probability_error:.6g} exceeded 0.04"
                )
            permutation_metrics["".join(str(index) for index in permutation)] = observed

        history = self._history_reservoir()
        if history.selected is None:
            raise AssertionError("compression history is empty")
        current_target = f32(2.0)
        compressed_mass = fmul(fmul(current_target, history.W), float(history.M))
        compressed = ScreenProbeReservoir(generation=9)
        if not reservoir_update(
            compressed,
            history.selected,
            current_target,
            compressed_mass,
            history.M,
            0.0,
            history.age + 1,
        ) or not compressed.finalize():
            raise AssertionError("compressed stream merge failed")

        expanded = ScreenProbeReservoir(generation=9)
        per_sample_mass = fmul(current_target, history.W)
        for index in range(history.M):
            if not reservoir_update(
                expanded,
                history.selected,
                current_target,
                per_sample_mass,
                1,
                hash_float((index, 0xA17E5EED, 0)),
                history.age + 1,
            ):
                raise AssertionError("expanded stream merge failed")
        if not expanded.finalize():
            raise AssertionError("expanded stream did not finalize")
        if (
            compressed.M != expanded.M
            or f32_bits(compressed.weight_sum) != f32_bits(expanded.weight_sum)
            or f32_bits(compressed.W) != f32_bits(expanded.W)
        ):
            raise AssertionError("compressed stream differs from its expanded equivalent")

        packed_history = GpuReservoirPayload(
            owner_position=(0.0, 0.0, 0.0),
            W=history.W,
            direction=history.selected.direction,
            proposal_pdf=history.selected.proposal_pdf,
            endpoint_position=history.selected.endpoint_position,
            endpoint_distance=history.selected.distance,
            radiance=history.selected.contribution,
            target=history.target_selected,
            absolute_geometry_cell=(0, 0, 2),
            hit_cascade=0,
            hit_face=(0, 0, -1),
            region_version=history.selected.geometry_version,
            endpoint_normal=history.selected.endpoint_normal,
            owner_normal=(0.0, 0.0, 1.0),
            M=history.M,
            age=history.age,
            generation=history.generation,
            algorithm_version=history.algorithm_version,
            flags=GPU_RESERVOIR_VALID | GPU_RESERVOIR_HIT | GPU_RESERVOIR_ENDPOINT_REUSABLE,
        )
        unpacked_history = unpack_gpu_reservoir(pack_gpu_reservoir(packed_history))
        reconstructed_mass = fmul(
            fmul(unpacked_history.target, unpacked_history.W),
            float(unpacked_history.M),
        )
        if f32_bits(reconstructed_mass) != f32_bits(history.weight_sum):
            raise AssertionError("Fresh-atlas-Temporal target*W*M reconstruction changed")
        return {
            "permutation_trials": permutation_trials,
            "permutations": permutation_metrics,
            "maximum_selection_probability_error": maximum_probability_error,
            "compressed_mass_bits": f"0x{f32_bits(compressed.weight_sum):08x}",
            "expanded_mass_bits": f"0x{f32_bits(expanded.weight_sum):08x}",
            "atlas_reconstructed_mass_bits": f"0x{f32_bits(reconstructed_mass):08x}",
        }

    @staticmethod
    def _analytic_incident(direction: Vec3) -> Vec3:
        z = direction[2]
        return 0.25 + 0.75 * z, 0.4 + 0.5 * z * z, 0.1 + 0.6 * z * z * z

    def _analytic_fresh_sample(self, trial: int, candidate: int, candidate_count: int) -> ScreenProbeSample:
        sample = (
            hash_float((trial, candidate, 0x13579BDF)),
            hash_float((candidate, trial, 0x2468ACE0)),
        )
        direction = cosine_sample_hemisphere(sample)
        proposal_pdf = cosine_pdf(direction)
        incident = self._analytic_incident(direction)
        contribution = mul_scalar(incident, proposal_pdf)
        return ScreenProbeSample(
            sample_id=u32(trial * 8 + candidate),
            domain=DOMAIN_SKY,
            direction=f32_vec(direction),
            endpoint_position=(0.0, 0.0, 0.0),
            endpoint_normal=(0.0, 0.0, 1.0),
            contribution=f32_vec(contribution),
            distance=0.0,
            proposal_pdf=f32(proposal_pdf),
            geometry_id=0,
            geometry_version=0,
            content_version=1,
            generation=1,
            flags=SAMPLE_FLAG_VALID | (candidate_count << 8),
        )

    def test_fresh_vector_ris(self) -> dict[str, object]:
        expected = (
            0.25 + 0.75 * (2.0 / 3.0),
            0.4 + 0.5 * (2.0 / 4.0),
            0.1 + 0.6 * (2.0 / 5.0),
        )
        receiver = SurfaceIdentity(1, 1, 1)
        estimates: dict[str, Vec3] = {}
        errors: dict[str, float] = {}
        tolerance = max(0.005, 0.005 * math.sqrt(DEFAULT_TRIALS / float(self.trials)))
        for candidate_count in (1, 2, 4, 8):
            outputs: list[Vec3] = []
            for trial in range(self.trials):
                samples = [
                    self._analytic_fresh_sample(trial, candidate, candidate_count)
                    for candidate in range(candidate_count)
                ]
                random_values = [
                    hash_float((trial, candidate, 0xA511E9B3))
                    for candidate in range(candidate_count)
                ]
                reservoir = fresh_reservoir(samples, random_values, receiver, 1)
                if not reservoir.is_valid():
                    raise AssertionError("analytic fresh reservoir became invalid")
                outputs.append(reservoir.estimate())
            estimate = mean_vectors(outputs)
            error = max_relative_error(estimate, expected)
            if error >= tolerance:
                raise AssertionError(
                    f"candidate_count={candidate_count} fresh RIS error {error:.6g} >= {tolerance:.6g}"
                )
            estimates[str(candidate_count)] = estimate
            errors[str(candidate_count)] = error

        maximum_pairwise = max(
            max_relative_error(estimates[first], estimates[second])
            for first in estimates
            for second in estimates
            if first != second
        )
        if maximum_pairwise >= tolerance * 1.5:
            raise AssertionError("fresh RIS candidate-count means diverged")
        return {
            "trials_per_candidate_count": self.trials,
            "candidate_counts": [1, 2, 4, 8],
            "analytic_D": expected,
            "estimated_D": estimates,
            "relative_error": errors,
            "maximum_pairwise_relative_error": maximum_pairwise,
            "acceptance_relative_error": tolerance,
        }

    def _history_reservoir(self, domain: int = DOMAIN_HIT) -> ScreenProbeReservoir:
        sample = self._sample(
            77,
            domain=domain,
            contribution=(2.0, 2.0, 2.0),
            proposal_pdf=0.5,
        )
        return ScreenProbeReservoir(
            selected=sample,
            target_selected=f32(2.0),
            weight_sum=f32(20.0),
            W=f32(1.25),  # 20 / (8 * 2)
            M=8,
            age=3,
            generation=9,
            algorithm_version=PHASE2_ALGORITHM_VERSION,
            receiver_identity=SurfaceIdentity(11, 12, 13),
        )

    def _temporal_context(self, **changes: object) -> TemporalContext:
        context = TemporalContext(
            receiver_identity=SurfaceIdentity(11, 12, 13),
            generation=9,
            algorithm_version=PHASE2_ALGORITHM_VERSION,
            endpoint_geometry_id=101,
            endpoint_geometry_version=7,
            content_version=5,
            history_receiver_position=(0.0, 0.0, 0.0),
            current_receiver_position=(1.0, 0.0, 0.0),
            current_contribution=(3.0, 3.0, 3.0),
            current_target=3.0,
            visibility=True,
            m_cap=4,
            max_age=32,
        )
        return replace(context, **changes)

    def test_temporal_merge_and_m_cap(self) -> dict[str, object]:
        history = self._history_reservoir()
        context = self._temporal_context()
        decision = evaluate_temporal_candidate(history, context)
        if not decision.accepted or decision.effective_M != 4 or not decision.cap_applied:
            raise AssertionError("valid capped history stream was not accepted")
        expected_jacobian = hit_reconnection_jacobian(
            context.history_receiver_position,
            context.current_receiver_position,
            history.selected.endpoint_position,  # type: ignore[union-attr]
            history.selected.endpoint_normal,  # type: ignore[union-attr]
        )
        expected_mass = fmul(
            fmul(fmul(context.current_target, expected_jacobian), history.W),
            4.0,
        )
        assert_f32_bits(decision.jacobian, f32_bits(expected_jacobian), "temporal.jacobian")
        assert_f32_bits(decision.merge_mass, f32_bits(expected_mass), "temporal.merge_mass")

        # With no cap, identical domains and targets reconstruct the represented
        # history stream's complete W_sum exactly: p * W * M == W_sum.
        static_context = self._temporal_context(
            current_receiver_position=(0.0, 0.0, 0.0),
            current_contribution=(2.0, 2.0, 2.0),
            current_target=2.0,
            m_cap=8,
        )
        static_decision = evaluate_temporal_candidate(history, static_context)
        if not static_decision.accepted:
            raise AssertionError("static unbounded history stream was rejected")
        assert_f32_bits(static_decision.merge_mass, f32_bits(history.weight_sum), "temporal.WM_equivalence")

        current_sample = self._sample(88, contribution=(0.5, 0.5, 0.5), proposal_pdf=0.25)
        current = fresh_reservoir(
            [current_sample],
            [0.0],
            context.receiver_identity,
            context.generation,
        )
        original_M = current.M
        merged = merge_temporal(current, history, context, 0.0)
        if not merged.accepted or current.M != original_M + 4 or current.selected is None:
            raise AssertionError("temporal stream did not add capped M")
        if current.selected.sample_id != history.selected.sample_id or current.age != history.age + 1:  # type: ignore[union-attr]
            raise AssertionError("forced temporal selection did not propagate sample/age")
        if current.M > original_M + context.m_cap:
            raise AssertionError("temporal output exceeded M cap")

        golden = {
            "jacobian_bits": f"0x{f32_bits(decision.jacobian):08x}",
            "merge_mass_bits": f"0x{f32_bits(decision.merge_mass):08x}",
            "effective_M": decision.effective_M,
            "cap_applied": decision.cap_applied,
            "output_M": current.M,
            "output_age": current.age,
            "output_selected_sample_id": current.selected.sample_id,
            "output_weight_sum_bits": f"0x{f32_bits(current.weight_sum):08x}",
            "output_W_bits": f"0x{f32_bits(current.W):08x}",
        }
        self.gpu_golden_vectors["temporal_hit_merge"] = golden
        return golden

    def test_hit_and_sky_jacobians(self) -> dict[str, object]:
        endpoint = (0.0, 0.0, 2.0)
        endpoint_normal = (0.0, 0.0, -1.0)
        history_position = (0.0, 0.0, 0.0)
        current_position = (1.0, 0.0, 0.0)
        history_term = geometry_term(history_position, endpoint, endpoint_normal)
        current_term = geometry_term(current_position, endpoint, endpoint_normal)
        jacobian = hit_reconnection_jacobian(
            history_position,
            current_position,
            endpoint,
            endpoint_normal,
        )
        assert_close(history_term, 0.25, 1e-15, "history geometry term")
        expected_current = (2.0 / math.sqrt(5.0)) / 5.0
        assert_close(current_term, expected_current, 1e-15, "current geometry term")
        assert_close(jacobian, expected_current / 0.25, 1e-15, "hit Jacobian")

        backface_term = geometry_term(history_position, endpoint, (0.0, 0.0, 1.0))
        grazing_term = geometry_term((1.0, 0.0, 2.0), endpoint, endpoint_normal)
        if backface_term != 0.0 or grazing_term != 0.0:
            raise AssertionError("single-sided Jacobian accepted a backface or grazing endpoint")

        sky_history = self._history_reservoir(DOMAIN_SKY)
        sky_decision = evaluate_temporal_candidate(sky_history, self._temporal_context())
        if not sky_decision.accepted or sky_decision.jacobian != 1.0:
            raise AssertionError("sky direction domain did not use J=1")

        jacobian_max = 4.0
        high_jacobian = 32.0
        low_jacobian = 1.0 / 32.0
        strict_high, strict_high_clamped = apply_jacobian_policy(high_jacobian, jacobian_max, False)
        strict_low, strict_low_clamped = apply_jacobian_policy(low_jacobian, jacobian_max, False)
        robust_high, robust_high_clamped = apply_jacobian_policy(high_jacobian, jacobian_max, True)
        robust_low, robust_low_clamped = apply_jacobian_policy(low_jacobian, jacobian_max, True)
        if (
            strict_high != high_jacobian
            or strict_low != low_jacobian
            or strict_high_clamped
            or strict_low_clamped
            or robust_high != jacobian_max
            or robust_low != 1.0 / jacobian_max
            or not robust_high_clamped
            or not robust_low_clamped
        ):
            raise AssertionError("strict/robust Jacobian boundary policy diverged from the shader contract")
        return {
            "history_geometry_term": history_term,
            "current_geometry_term": current_term,
            "hit_jacobian": jacobian,
            "backface_geometry_term": backface_term,
            "grazing_geometry_term": grazing_term,
            "sky_jacobian": sky_decision.jacobian,
            "jacobian_policy": {
                "Jmax": jacobian_max,
                "strict_high": strict_high,
                "strict_low": strict_low,
                "robust_high": robust_high,
                "robust_low": robust_low,
                "robust_interval": [1.0 / jacobian_max, jacobian_max],
            },
            "contract": "hit G=max(dot(n_y,normalize(x-y)),0)/distance^2; sky direction-domain J=1",
        }

    def test_rejection_and_version_contract(self) -> dict[str, object]:
        history = self._history_reservoir()
        base = self._temporal_context()
        cases: list[tuple[str, ScreenProbeReservoir | None, TemporalContext]] = [
            (REJECT_NO_HISTORY, None, base),
            (REJECT_ALGORITHM_VERSION, replace(history, algorithm_version=99), base),
            (REJECT_GENERATION, replace(history, generation=8), base),
            (
                REJECT_RECEIVER_IDENTITY,
                replace(history, receiver_identity=SurfaceIdentity(999, 12, 13)),
                base,
            ),
            (REJECT_ENDPOINT_IDENTITY, history, replace(base, endpoint_geometry_version=8)),
            (REJECT_AGE, replace(history, age=32), base),
            (
                REJECT_JACOBIAN,
                replace(history, selected=replace(history.selected, endpoint_normal=(0.0, 0.0, 1.0))),  # type: ignore[arg-type]
                base,
            ),
            (REJECT_TARGET, history, replace(base, current_target=math.nan)),
        ]
        observed: dict[str, str] = {}
        for expected_reason, candidate, context in cases:
            decision = evaluate_temporal_candidate(candidate, context)
            key = f"{expected_reason}_{len(observed)}"
            observed[key] = decision.reason
            if decision.accepted or decision.reason != expected_reason:
                raise AssertionError(
                    f"expected temporal rejection {expected_reason}, got {decision.reason}"
                )

        accepted = evaluate_temporal_candidate(history, base)
        if not accepted.accepted or accepted.reason != REJECT_NONE:
            raise AssertionError("matching history identity/version was rejected")
        content_reweighted = evaluate_temporal_candidate(history, replace(base, content_version=6))
        if not content_reweighted.accepted or content_reweighted.reconnected_sample is None or content_reweighted.reconnected_sample.content_version != 6:
            raise AssertionError("current transport content was not re-evaluated into the reused sample")

        zero_target = evaluate_temporal_candidate(
            history,
            replace(base, current_target=0.0, current_contribution=(0.0, 0.0, 0.0)),
        )
        if not zero_target.accepted or zero_target.merge_mass != 0.0 or zero_target.effective_M <= 0:
            raise AssertionError("zero-current-target history did not preserve represented M with zero mass")

        # Visibility zero differs from an invalid endpoint mapping: it is an
        # accepted zero-mass stream and must still increase M_eff.
        occluded_current = fresh_reservoir(
            [self._sample(89, contribution=(0.5, 0.5, 0.5), proposal_pdf=0.25)],
            [0.0],
            base.receiver_identity,
            base.generation,
        )
        occluded_selected_id = occluded_current.selected.sample_id  # type: ignore[union-attr]
        occluded_mass_before = occluded_current.weight_sum
        occluded_M_before = occluded_current.M
        visibility_zero = merge_temporal(
            occluded_current,
            history,
            replace(base, visibility=False),
            0.0,
        )
        if (
            not visibility_zero.accepted
            or visibility_zero.reason != ACCEPT_VISIBILITY_ZERO
            or visibility_zero.merge_mass != 0.0
            or occluded_current.M != occluded_M_before + visibility_zero.effective_M
            or occluded_current.selected is None
            or occluded_current.selected.sample_id != occluded_selected_id
            or f32_bits(occluded_current.weight_sum) != f32_bits(occluded_mass_before)
        ):
            raise AssertionError("zero visibility did not preserve M with zero mass")
        return {
            "rejection_count": len(cases),
            "observed_reasons": observed,
            "matching_contract": accepted.reason,
            "content_reweighted": content_reweighted.accepted,
            "zero_target_preserves_M": zero_target.effective_M,
            "receiver_backface_zero_target_preserves_M": zero_target.effective_M,
            "zero_visibility_preserves_M": visibility_zero.effective_M,
            "ordering": [reason for reason, _history, _context in cases],
        }

    def _stress_fresh_samples(
        self,
        frame: int,
        generation: int,
        content_version: int,
        endpoint_version: int,
    ) -> tuple[list[ScreenProbeSample], list[float]]:
        samples: list[ScreenProbeSample] = []
        random_values: list[float] = []
        hdr_scale = 1.0 + float((frame * 37) % 997)
        for candidate in range(2):
            direction = cosine_sample_hemisphere(
                (
                    hash_float((frame, candidate, 0x0F0F0F0F)),
                    hash_float((candidate, frame, 0xF0F0F0F0)),
                )
            )
            proposal_pdf = max(cosine_pdf(direction), 1e-6)
            incident = (
                0.05 + hdr_scale * (0.001 + 0.002 * direction[2]),
                0.08 + hdr_scale * (0.0015 + 0.001 * direction[2] * direction[2]),
                0.03 + hdr_scale * (0.0005 + 0.0025 * direction[2] ** 3),
            )
            samples.append(
                ScreenProbeSample(
                    sample_id=u32(frame * 2 + candidate),
                    domain=DOMAIN_HIT,
                    direction=f32_vec(direction),
                    endpoint_position=(0.0, 0.0, 2.0),
                    endpoint_normal=(0.0, 0.0, -1.0),
                    contribution=f32_vec(mul_scalar(incident, proposal_pdf)),
                    distance=f32(2.0),
                    proposal_pdf=f32(proposal_pdf),
                    geometry_id=101,
                    geometry_version=endpoint_version,
                    content_version=content_version,
                    generation=generation,
                )
            )
            random_values.append(hash_float((frame, candidate, 0x5A17C0DE)))
        return samples, random_values

    def test_jitter_neutral_reprojection_and_history_footprint(self) -> dict[str, object]:
        stable_uv = (0.375, 0.625)
        jitter_uv_sequence = (
            (0.0, 0.0),
            (0.25 / 640.0, -0.375 / 360.0),
            (-0.4375 / 640.0, 0.125 / 360.0),
            (0.375 / 640.0, 0.4375 / 360.0),
        )
        maximum_static_error = 0.0
        maximum_direct_previous_uv_error = 0.0
        for jitter_uv in jitter_uv_sequence:
            current_grid_uv = (
                stable_uv[0] + jitter_uv[0],
                stable_uv[1] + jitter_uv[1],
            )
            previous_uv = temporal_reproject_jitter_neutral_2d(
                current_grid_uv, stable_uv, stable_uv
            )
            maximum_static_error = max(
                maximum_static_error,
                abs(previous_uv[0] - current_grid_uv[0]),
                abs(previous_uv[1] - current_grid_uv[1]),
            )
            maximum_direct_previous_uv_error = max(
                maximum_direct_previous_uv_error,
                abs(stable_uv[0] - current_grid_uv[0]),
                abs(stable_uv[1] - current_grid_uv[1]),
            )
        if maximum_static_error > 1e-15:
            raise AssertionError("static jitter-neutral reprojection moved history")
        if maximum_direct_previous_uv_error <= 0.0:
            raise AssertionError("fixture did not distinguish direct stable UV from grid-relative reprojection")

        current_grid_uv = (0.51, 0.42)
        current_stable_uv = (0.47, 0.41)
        previous_stable_uv = (0.44, 0.45)
        motion_uv = (
            previous_stable_uv[0] - current_stable_uv[0],
            previous_stable_uv[1] - current_stable_uv[1],
        )
        previous_uv = temporal_reproject_jitter_neutral_2d(
            current_grid_uv, current_stable_uv, previous_stable_uv
        )
        expected_previous_uv = (
            current_grid_uv[0] + motion_uv[0],
            current_grid_uv[1] + motion_uv[1],
        )
        motion_error = max(
            abs(previous_uv[0] - expected_previous_uv[0]),
            abs(previous_uv[1] - expected_previous_uv[1]),
        )
        if motion_error > 1e-15:
            raise AssertionError("camera-motion delta changed in grid-relative reprojection")
        probe_motion_current_grid = (12.0 / 24.0, 12.0 / 16.0)
        probe_motion_previous_uv = temporal_reproject_jitter_neutral_2d(
            probe_motion_current_grid,
            (0.3125, 0.6875),
            (0.375, 0.625),
        )
        probe_motion_texel = (
            probe_axis_history_texel(probe_motion_previous_uv[0], 24, 8),
            probe_axis_history_texel(probe_motion_previous_uv[1], 16, 8),
        )
        if any(
            not math.isclose(value, expected, rel_tol=0.0, abs_tol=1e-15)
            for value, expected in zip(probe_motion_texel, (1.1875, 0.875))
        ):
            raise AssertionError("probe history texel changed the TAA velocity sign or scale")


        maximum_weight_sum_error = 0.0
        for texel in ((12.25, 7.75), (-0.25, 2.5), (3.0, 4.0)):
            footprint = bilinear_history_footprint(texel)
            weights = [weight for _, weight in footprint]
            maximum_weight_sum_error = max(maximum_weight_sum_error, abs(sum(weights) - 1.0))
            if len({position for position, _ in footprint}) != 4:
                raise AssertionError("2x2 footprint did not produce four unique coordinates")
            if any(weight < 0.0 or weight > 1.0 for weight in weights):
                raise AssertionError("2x2 footprint produced an invalid bilinear weight")
        if maximum_weight_sum_error > 1e-15:
            raise AssertionError("2x2 footprint weights no longer sum to one")

        negative_footprint = bilinear_history_footprint((-0.25, 2.5))
        if negative_footprint[0][0] != (-1, 2):
            raise AssertionError("negative fractional coordinates must use floor, not truncation")
        in_bounds_coverage = sum(
            weight
            for (x, y), weight in negative_footprint
            if 0 <= x < 8 and 0 <= y < 8
        )
        if not math.isclose(in_bounds_coverage, 0.75, rel_tol=0.0, abs_tol=1e-15):
            raise AssertionError("out-of-bounds footprint taps were clamped instead of masked")

        gi_size = (13, 11)
        probe_size = 8
        probe_position = (1, 1)
        gi_origin = (probe_position[0] * probe_size, probe_position[1] * probe_size)
        gi_end = (
            min(gi_origin[0] + probe_size, gi_size[0]),
            min(gi_origin[1] + probe_size, gi_size[1]),
        )
        partial_tile_anchor = (
            (gi_origin[0] + gi_end[0]) * 0.5 / gi_size[0],
            (gi_origin[1] + gi_end[1]) * 0.5 / gi_size[1],
        )
        previous_partial_anchor = temporal_reproject_jitter_neutral_2d(
            partial_tile_anchor, stable_uv, stable_uv
        )
        previous_probe_texel = (
            probe_axis_history_texel(
                previous_partial_anchor[0],
                gi_size[0],
                probe_size,
            ),
            probe_axis_history_texel(
                previous_partial_anchor[1],
                gi_size[1],
                probe_size,
            ),
        )
        partial_tile_error = max(
            abs(previous_probe_texel[0] - probe_position[0]),
            abs(previous_probe_texel[1] - probe_position[1]),
        )
        if partial_tile_error > 1e-15:
            raise AssertionError("static partial edge tile did not map to its exact probe")
        previous_full_center = probe_size * 0.5
        partial_center = (gi_origin[0] + gi_end[0]) * 0.5
        edge_interval_midpoint_uv = (
            (previous_full_center + partial_center) * 0.5 / gi_size[0]
        )
        edge_interval_midpoint_texel = probe_axis_history_texel(
            edge_interval_midpoint_uv, gi_size[0], probe_size
        )
        if not math.isclose(
            edge_interval_midpoint_texel, 0.5, rel_tol=0.0, abs_tol=1e-15
        ):
            raise AssertionError("partial edge interval did not preserve fractional probe coordinates")
        clipped_gi_extent = 19
        clipped_centers = (4.0, 12.0, 17.5)
        clipped_center_error = max(
            abs(
                probe_axis_history_texel(
                    center / clipped_gi_extent, clipped_gi_extent, probe_size
                )
                - index
            )
            for index, center in enumerate(clipped_centers)
        )
        if clipped_center_error > 1e-15:
            raise AssertionError("actual clipped-tile centers did not map to integer probe texels")
        clipped_current_grid = clipped_centers[-1] / clipped_gi_extent
        clipped_previous_grid = temporal_reproject_jitter_neutral_2d(
            (clipped_current_grid, 0.5),
            (0.5, 0.5),
            (0.5 + (clipped_centers[1] - clipped_centers[2]) / clipped_gi_extent, 0.5),
        )[0]
        clipped_cross_tile_texel = probe_axis_history_texel(
            clipped_previous_grid, clipped_gi_extent, probe_size
        )
        old_uniform_cross_tile_texel = 2.0 + (
            clipped_previous_grid - clipped_current_grid
        ) * clipped_gi_extent / probe_size
        if not math.isclose(
            clipped_cross_tile_texel, 1.0, rel_tol=0.0, abs_tol=1e-15
        ):
            raise AssertionError("motion across a clipped edge interval missed the adjacent probe")
        if math.isclose(
            old_uniform_cross_tile_texel, 1.0, rel_tol=0.0, abs_tol=1e-15
        ):
            raise AssertionError("clipped-tile fixture did not distinguish the old uniform scale")



        association_footprint = bilinear_history_footprint((4.25, 8.75))
        geometry_scores = {
            (4, 8): 0.9,
            (5, 8): 0.3,
            (4, 9): 0.6,
            (5, 9): 0.4,
        }
        reservoir_M = {
            (4, 8): 3,
            (5, 8): 5,
            (4, 9): 7,
            (5, 9): 11,
        }
        selected_position, selected_association = max(
            (
                (position, footprint_weight * geometry_scores[position])
                for position, footprint_weight in association_footprint
            ),
            key=lambda item: (item[1], -item[0][1], -item[0][0]),
        )
        selected_M = reservoir_M[selected_position]
        if selected_position != (4, 9) or selected_M != 7:
            raise AssertionError("discrete reservoir association selected the wrong footprint tap")
        if selected_M == sum(reservoir_M.values()):
            raise AssertionError("reservoir footprint association merged multiple history streams")
        intrinsic_valid = {
            (4, 8): True,
            (5, 8): True,
            (4, 9): False,
            (5, 9): True,
        }
        valid_selected_position, _ = max(
            (
                (position, footprint_weight * geometry_scores[position])
                for position, footprint_weight in association_footprint
                if intrinsic_valid[position]
            ),
            key=lambda item: (item[1], -item[0][1], -item[0][0]),
        )
        if valid_selected_position != (4, 8):
            raise AssertionError("invalid high-score endpoint hid a usable reservoir candidate")

        tie_selected_position, _ = max(
            bilinear_history_footprint((6.5, 9.5)),
            key=lambda item: (item[1], -item[0][1], -item[0][0]),
        )
        if tie_selected_position != (6, 9):
            raise AssertionError("reservoir association tie-break is not minimum y then x")


        history_taps = {
            (4, 8): ((2.0, 0.0, 0.0), 8.0, 0.5),
            (4, 9): ((0.0, 2.0, 0.0), 4.0, 1.0),
        }
        valid_weight = 0.0
        weighted_rgb = [0.0, 0.0, 0.0]
        weighted_age = 0.0
        for position, footprint_weight in association_footprint:
            tap = history_taps.get(position)
            if tap is None:
                continue
            match_weight = footprint_weight * tap[2]
            valid_weight += match_weight
            for axis in range(3):
                weighted_rgb[axis] += tap[0][axis] * match_weight
            weighted_age += tap[1] * match_weight
        gathered_rgb = tuple(component / valid_weight for component in weighted_rgb)
        gathered_age = weighted_age / valid_weight * valid_weight
        if any(
            not math.isclose(value, expected, rel_tol=0.0, abs_tol=1e-15)
            for value, expected in zip(gathered_rgb, (2.0 / 7.0, 12.0 / 7.0, 0.0))
        ):
            raise AssertionError("masked history RGB was attenuated instead of normalized")
        if not math.isclose(valid_weight, 0.65625, rel_tol=0.0, abs_tol=1e-15):
            raise AssertionError("soft geometric coverage changed")
        if not math.isclose(gathered_age, 3.0, rel_tol=0.0, abs_tol=1e-15):
            raise AssertionError("history age did not retain effective match coverage")

        return {
            "static_jitter_phases": len(jitter_uv_sequence),
            "maximum_static_uv_error": maximum_static_error,
            "direct_previous_uv_fixture_error": maximum_direct_previous_uv_error,
            "motion_delta_uv": list(motion_uv),
            "motion_delta_error": motion_error,
            "probe_motion_history_texel": list(probe_motion_texel),
            "maximum_footprint_weight_sum_error": maximum_weight_sum_error,
            "masked_edge_coverage": in_bounds_coverage,
            "partial_tile_size": [gi_end[0] - gi_origin[0], gi_end[1] - gi_origin[1]],
            "partial_tile_static_probe_error": partial_tile_error,
            "clipped_center_maximum_error": clipped_center_error,
            "clipped_cross_tile_texel": clipped_cross_tile_texel,
            "old_uniform_cross_tile_texel": old_uniform_cross_tile_texel,
            "selected_reservoir_coordinate": list(selected_position),
            "partial_edge_interval_midpoint_texel": edge_interval_midpoint_texel,
            "selected_after_invalid_endpoint_filter": list(valid_selected_position),
            "tie_break_selected_coordinate": list(tie_selected_position),
            "selected_reservoir_association_score": selected_association,
            "selected_reservoir_M": selected_M,
            "sum_of_candidate_M_not_used": sum(reservoir_M.values()),
            "history_effective_coverage": valid_weight,
            "history_normalized_rgb": list(gathered_rgb),
            "history_coverage_scaled_age": gathered_age,
        }

    def test_thousand_frame_finite_stress(self) -> dict[str, object]:
        receiver = SurfaceIdentity(11, 12, 13)
        generation = 9
        content_version = 5
        endpoint_version = 7
        history: ScreenProbeReservoir | None = None
        previous_position = (0.0, 0.0, 0.0)
        reason_counts: dict[str, int] = {}
        accepted_count = 0
        cap_count = 0
        maximum_M = 0
        maximum_age = 0
        maximum_output = 0.0

        for frame in range(self.stress_frames):
            if frame == self.stress_frames // 3:
                generation += 1
            if frame == (self.stress_frames * 2) // 3:
                content_version += 1
            if frame == (self.stress_frames * 3) // 4:
                endpoint_version += 1

            current_position = (0.15 * math.sin(float(frame) * 0.017), 0.0, 0.0)
            samples, random_values = self._stress_fresh_samples(
                frame,
                generation,
                content_version,
                endpoint_version,
            )
            current = fresh_reservoir(samples, random_values, receiver, generation)

            if history is not None and history.selected is not None:
                selected = history.selected
                scale = 0.75 + 0.25 * math.cos(float(frame) * 0.013)
                current_contribution = f32_vec(
                    tuple(max(component * scale, 1e-8) for component in selected.contribution)  # type: ignore[arg-type]
                )
                current_target = f32(luminance(current_contribution))
                context = TemporalContext(
                    receiver_identity=receiver,
                    generation=generation,
                    algorithm_version=PHASE2_ALGORITHM_VERSION,
                    endpoint_geometry_id=101,
                    endpoint_geometry_version=endpoint_version,
                    content_version=content_version,
                    history_receiver_position=previous_position,
                    current_receiver_position=current_position,
                    current_contribution=current_contribution,
                    current_target=current_target,
                    visibility=frame != (self.stress_frames * 4) // 5,
                    m_cap=32,
                    max_age=32,
                )
                decision = merge_temporal(
                    current,
                    history,
                    context,
                    hash_float((frame, 0xC001CAFE, 0x12345678)),
                )
                reason_counts[decision.reason] = reason_counts.get(decision.reason, 0) + 1
                accepted_count += int(decision.accepted)
                cap_count += int(decision.cap_applied)

            if not current.is_valid():
                raise AssertionError(f"stress frame {frame}: reservoir became invalid")
            estimate = current.estimate()
            if any(not math.isfinite(component) or component < 0.0 for component in estimate):
                raise AssertionError(f"stress frame {frame}: estimate became non-finite or negative")
            if current.M > 34:
                raise AssertionError(f"stress frame {frame}: M={current.M} exceeded N + M_cap")
            if current.age > 32:
                raise AssertionError(f"stress frame {frame}: age={current.age} exceeded max age")
            maximum_M = max(maximum_M, current.M)
            maximum_age = max(maximum_age, current.age)
            maximum_output = max(maximum_output, *estimate)
            history = current
            previous_position = current_position

        required_rejections = {
            REJECT_GENERATION,
            REJECT_ENDPOINT_IDENTITY,
        }
        missing_rejections = required_rejections - set(reason_counts)
        if missing_rejections:
            raise AssertionError(
                "stress sequence did not exercise rejection(s): " + ", ".join(sorted(missing_rejections))
            )
        if reason_counts.get(ACCEPT_VISIBILITY_ZERO, 0) == 0:
            raise AssertionError("stress sequence did not exercise zero-visibility M preservation")
        if accepted_count <= self.stress_frames // 2 or cap_count == 0:
            raise AssertionError("stress sequence did not exercise sustained temporal reuse and M capping")
        return {
            "frames": self.stress_frames,
            "accepted_temporal_streams": accepted_count,
            "m_cap_applied_frames": cap_count,
            "reason_counts": reason_counts,
            "maximum_M": maximum_M,
            "maximum_age": maximum_age,
            "maximum_output_component": maximum_output,
            "all_outputs_finite": True,
        }

    def execute(self) -> dict[str, object]:
        cases: list[tuple[str, Callable[[], dict[str, object]]]] = [
            ("fixed_float32_stream", self.test_fixed_float32_stream),
            ("packing_round_trip", self.test_packing_round_trip),
            ("stream_permutation_and_compression", self.test_stream_permutation_and_compression),
            ("fresh_vector_ris", self.test_fresh_vector_ris),
            ("temporal_merge_and_m_cap", self.test_temporal_merge_and_m_cap),
            ("hit_and_sky_jacobians", self.test_hit_and_sky_jacobians),
            ("rejection_and_version_contract", self.test_rejection_and_version_contract),
            ("jitter_neutral_reprojection_and_history_footprint", self.test_jitter_neutral_reprojection_and_history_footprint),
            ("thousand_frame_finite_stress", self.test_thousand_frame_finite_stress),
        ]
        for name, function in cases:
            self.run_case(name, function)
        failures = [result for result in self.results if result.status != "passed"]
        return {
            "schema_version": "2.5.0",
            "suite": "hddagi_screen_probe_phase2_cpu_reference",
            "status": "failed" if failures else "completed",
            "precision": "Python binary64 analytic reference with explicit IEEE-754 binary32 ABI arithmetic",
            "algorithm_version": PHASE2_ALGORITHM_VERSION,
            "trials_per_fresh_candidate_count": self.trials,
            "stress_frames": self.stress_frames,
            "candidate_counts": [1, 2, 4, 8],
            "domains": {
                "hit": "single-sided endpoint G=max(dot(n_y,normalize(x-y)),0)/distance^2",
                "sky": "world-direction domain J=1 with current environment re-evaluation",
            },
            "temporal_contract": {
                "effective_M": "min(history.M, M_cap)",
                "merge_mass": "p_current * J * history.W * effective_M for visible history; zero when visibility is zero",
                "output_M": "fresh.M + effective_M after valid mapping, including zero visibility",
                "robust_clamp": "strict mode preserves every finite positive J; robust mode clamps hit J to [1/Jmax,Jmax] and reports whether clamping occurred",
            },
            "reprojection_contract": {
                "history_uv": "current_grid_uv + (previous_stable_uv - current_stable_uv)",
                "raster_reconstruction": "current and previous depth reconstruct with their jittered inverse projections",
                "probe_mapping": "fractional atlas texel through actual clipped-tile centers",
            },
            "history_footprint_contract": {
                "reservoir": "unclamped 2x2 association chooses exactly one intrinsically valid reservoir; never interpolates W/M/payload",
                "radiance": "positive masked 2x2 depth/normal gather normalizes RGB and preserves effective match coverage only in sample-count confidence",
            },
            "packing_contract": {
                "atlas_words": "owner4/sample4/endpoint4/radiance4/identity4/meta4/version2",
                "direction_and_float_payload": "IEEE-754 binary32 words",
                "endpoint_and_owner_normal": "octahedral unsigned 16+15 bit surface-normal packing",
                "identity_M_age_generation_version": "uint32 words with 8/8/16 algorithm/flags/region-version field",
                "nonfinite": "invalid; never clamped into a valid reservoir",
                "gpu_current_atlas_golden": "shared fresh/temporal compressed-stream math, then phase2_store_current/load_current round-trip of all seven current atlases before the 26-word digest",
                "previous_descriptor_scope": "previous sampled-image descriptors are exercised by scenario rendering but are not part of the bitwise golden readback",
            },
            "gpu_golden_vectors": self.gpu_golden_vectors,
            "cases": [result.__dict__ for result in self.results],
            "failure_count": len(failures),
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Deterministic CPU reference for HDDAGI screen-probe Phase 2 temporal ReSTIR."
    )
    parser.add_argument("--trials", type=int, default=DEFAULT_TRIALS)
    parser.add_argument("--stress-frames", type=int, default=DEFAULT_STRESS_FRAMES)
    parser.add_argument("--json-output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.trials < 4_096:
        print("--trials must be at least 4096", file=sys.stderr)
        return 2
    if args.stress_frames < DEFAULT_STRESS_FRAMES:
        print("--stress-frames must be at least 1000", file=sys.stderr)
        return 2

    result = ReferenceSuite(args.trials, args.stress_frames).execute()
    encoded = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        temporary = args.json_output.with_suffix(args.json_output.suffix + ".tmp")
        temporary.write_text(encoded, encoding="utf-8")
        os.replace(temporary, args.json_output)

    print(
        "HDDAGI_PHASE2_CPU_REFERENCE "
        + json.dumps(
            {
                "status": result["status"],
                "cases": len(result["cases"]),
                "failures": result["failure_count"],
                "trials": result["trials_per_fresh_candidate_count"],
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

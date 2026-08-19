#!/usr/bin/env python3
"""Deterministic CPU reference for the Phase 1 fresh-only screen-probe estimator.

This intentionally has no Godot or third-party dependency.  It mirrors the
integer hash, cosine warp and fresh estimator contract used by the GPU path,
while keeping the analytic integrals in double precision.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import struct
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable


PI = math.pi
TAU = math.tau
UINT32_MASK = 0xFFFFFFFF
HASH_FLOAT_DENOMINATOR = float(0x01000000)
DEFAULT_FRAMES = 65_536
ATLAS_COORD = (17, 29)


Vec3 = tuple[float, float, float]


def u32(value: int) -> int:
    return value & UINT32_MASK


def fract(value: float) -> float:
    return value - math.floor(value)


def f32(value: float) -> float:
    return struct.unpack("<f", struct.pack("<f", value))[0]


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
    return float(hash_uvec3(value) & 0x00FFFFFF) / HASH_FLOAT_DENOMINATOR


def phase1_jitter(atlas: tuple[int, int], frame: int, candidate: int) -> tuple[float, float]:
    """The fixed fresh-candidate stream with explicit GLSL float32 rounding."""

    frame16 = f32(float(frame & 0xFFFF))
    candidate_float = f32(float(candidate))
    x_step = f32(f32(0.7548776662466927) + f32(candidate_float * f32(0.1315423911)))
    y_step = f32(f32(0.5698402909980532) + f32(candidate_float * f32(0.1732050808)))
    x_value = f32(hash_float((atlas[0], atlas[1], candidate)) + f32(frame16 * x_step))
    y_value = f32(hash_float((atlas[1], atlas[0], candidate + 1)) + f32(frame16 * y_step))
    return (
        f32(fract(x_value)),
        f32(fract(y_value)),
    )


def cosine_sample_hemisphere(sample: tuple[float, float]) -> Vec3:
    radius = math.sqrt(sample[0])
    phi = TAU * sample[1]
    return (
        radius * math.cos(phi),
        radius * math.sin(phi),
        math.sqrt(max(0.0, 1.0 - sample[0])),
    )


def cosine_pdf(local_direction: Vec3) -> float:
    return max(local_direction[2], 0.0) / PI


def mul_scalar(value: Vec3, scalar: float) -> Vec3:
    return value[0] * scalar, value[1] * scalar, value[2] * scalar


def mul_components(first: Vec3, second: Vec3) -> Vec3:
    return first[0] * second[0], first[1] * second[1], first[2] * second[2]


def add(first: Vec3, second: Vec3) -> Vec3:
    return first[0] + second[0], first[1] + second[1], first[2] + second[2]


def fresh_estimator_sample(incident_radiance: Vec3, direction: Vec3, visibility: float = 1.0) -> Vec3:
    """Evaluate g/q, retaining the PDF explicitly to catch missing-pi/cosine errors."""

    cosine = max(direction[2], 0.0)
    proposal_pdf = cosine_pdf(direction)
    if proposal_pdf <= 0.0 or not math.isfinite(proposal_pdf):
        return 0.0, 0.0, 0.0
    integrand = mul_scalar(incident_radiance, visibility * cosine / PI)
    return mul_scalar(integrand, 1.0 / proposal_pdf)


def mean_vectors(values: Iterable[Vec3]) -> Vec3:
    total = (0.0, 0.0, 0.0)
    count = 0
    for value in values:
        total = add(total, value)
        count += 1
    if count == 0:
        return 0.0, 0.0, 0.0
    return mul_scalar(total, 1.0 / float(count))


def max_relative_error(actual: Vec3, expected: Vec3) -> float:
    return max(abs(actual[index] - expected[index]) / max(abs(expected[index]), 1e-12) for index in range(3))


def assert_close(actual: float, expected: float, tolerance: float, label: str) -> None:
    if not math.isfinite(actual) or abs(actual - expected) > tolerance:
        raise AssertionError(f"{label}: expected {expected:.12g} +/- {tolerance:.3g}, got {actual:.12g}")


def assert_vector_close(actual: Vec3, expected: Vec3, tolerance: float, label: str) -> None:
    for channel, channel_name in enumerate("rgb"):
        assert_close(actual[channel], expected[channel], tolerance, f"{label}.{channel_name}")


@dataclass
class CaseResult:
    name: str
    status: str
    metrics: dict[str, object]
    error: str = ""


class ReferenceSuite:
    def __init__(self, frames: int) -> None:
        self.frames = frames
        self.results: list[CaseResult] = []
        self.repo_root = Path(__file__).resolve().parents[3]
        self.shader_path = (
            self.repo_root
            / "servers/rendering/renderer_rd/shaders/environment/hddagi_screen_probe_phase1.glsl"
        )

    def run_case(self, name: str, function: Callable[[], dict[str, object]]) -> None:
        try:
            metrics = function()
        except Exception as exception:  # Keep every independent contract result in JSON.
            self.results.append(CaseResult(name, "failed", {}, str(exception)))
        else:
            self.results.append(CaseResult(name, "passed", metrics))

    def test_fixed_shader_random_stream(self) -> dict[str, object]:
        hashes = [hash_uvec3((17, 29, index)) for index in range(8)]
        expected_hashes = [
            1_354_554_870,
            856_290_719,
            3_701_420_271,
            10_428_931,
            3_719_426_555,
            4_271_126_127,
            1_124_962_279,
            3_912_160_744,
        ]
        if hashes != expected_hashes:
            raise AssertionError(f"hash stream changed: expected {expected_hashes}, got {hashes}")

        jitters = [phase1_jitter(ATLAS_COORD, frame, candidate) for frame, candidate in ((0, 0), (1, 0), (7, 1), (65_535, 7))]
        expected_jitters = [
            (0.7377618551254272, 0.7291646599769592),
            (0.49263954162597656, 0.29900503158569336),
            (0.24384450912475586, 0.41461706161499023),
            (0.5078125, 0.2734375),
        ]
        for index, (actual, expected) in enumerate(zip(jitters, expected_jitters)):
            assert_close(actual[0], expected[0], 1e-12, f"jitter[{index}].x")
            assert_close(actual[1], expected[1], 1e-12, f"jitter[{index}].y")
        return {"hashes": hashes, "jitters": jitters, "atlas_coord": list(ATLAS_COORD)}

    def test_shader_contract_alignment(self) -> dict[str, object]:
        if not self.shader_path.is_file():
            raise AssertionError(f"Phase 1 shader does not exist: {self.shader_path}")
        source = self.shader_path.read_text(encoding="utf-8")
        required_fragments = [
            "v = v * 1664525u + 1013904223u;",
            "float(hash_uvec3(v) & 0x00ffffffu) / float(0x01000000u)",
            "0.7548776662466927 + candidate_f * 0.1315423911",
            "0.5698402909980532 + candidate_f * 0.1732050808",
            "cosine_sample_hemisphere(jitter)",
            "radiance_sum += sample_radiance * hddagi.energy;",
            "radiance_sum / float(trace_count)",
            "sample_radiance = sample_environment(ray_dir);",
            "phase1_stats_add(PHASE1_STAT_FRESH_CANDIDATES, trace_count);",
        ]
        missing = [fragment for fragment in required_fragments if fragment not in source]
        if missing:
            raise AssertionError("Phase 1 shader diverged from CPU reference: " + "; ".join(missing))
        forbidden_fragments = [
            "screen_probe_reservoir_update",
            "request_hddagi_lightprobe_update",
            "radiance_sum += sample_radiance;",
            "sample_radiance = sample_environment(ray_dir) * hddagi.energy;",
        ]
        present_forbidden = [fragment for fragment in forbidden_fragments if fragment in source]
        if present_forbidden:
            raise AssertionError(
                "Phase 1 shader contains forbidden legacy transport path(s): "
                + ", ".join(present_forbidden)
            )
        return {
            "shader": str(self.shader_path.relative_to(self.repo_root)).replace("\\", "/"),
            "shader_sha256": hashlib.sha256(source.encode("utf-8")).hexdigest(),
            "required_fragment_count": len(required_fragments),
            "forbidden_fragment_count": len(forbidden_fragments),
            "energy_contract": "hit and miss Li are both scaled once at the common accumulation point",
        }

    def test_cosine_warp_and_pdf(self) -> dict[str, object]:
        z_values: list[float] = []
        z_squared_values: list[float] = []
        minimum_pdf = math.inf
        maximum_length_error = 0.0
        for frame in range(self.frames):
            direction = cosine_sample_hemisphere(phase1_jitter(ATLAS_COORD, frame, 0))
            length = math.sqrt(sum(component * component for component in direction))
            maximum_length_error = max(maximum_length_error, abs(length - 1.0))
            if direction[2] < 0.0:
                raise AssertionError("cosine warp emitted a direction below the hemisphere")
            minimum_pdf = min(minimum_pdf, cosine_pdf(direction))
            z_values.append(direction[2])
            z_squared_values.append(direction[2] * direction[2])

        mean_z = sum(z_values) / len(z_values)
        mean_z_squared = sum(z_squared_values) / len(z_squared_values)
        # Under p(omega)=cos(theta)/pi, E[z]=2/3 and E[z^2]=1/2.
        assert_close(mean_z, 2.0 / 3.0, 0.002, "E[cos(theta)]")
        assert_close(mean_z_squared, 0.5, 0.002, "E[cos(theta)^2]")
        if maximum_length_error > 2e-15 or minimum_pdf <= 0.0:
            raise AssertionError("cosine warp produced a non-unit direction or non-positive PDF")

        # Independent midpoint quadrature over dOmega = dphi dz.
        z_steps = 4096
        pdf_integral = sum((float(index) + 0.5) / float(z_steps) / PI for index in range(z_steps)) * TAU / float(z_steps)
        assert_close(pdf_integral, 1.0, 1e-12, "integral(q_cos)")
        return {
            "samples": self.frames,
            "mean_cosine": mean_z,
            "mean_cosine_squared": mean_z_squared,
            "pdf_integral_midpoint": pdf_integral,
            "maximum_direction_length_error": maximum_length_error,
            "minimum_pdf": minimum_pdf,
        }

    def test_constant_environment_and_radiometry(self) -> dict[str, object]:
        incident = (0.8, 0.5, 0.2)
        receiver_albedo = (0.25, 0.5, 0.75)
        secondary_albedo = (0.6, 0.4, 0.2)
        secondary_diffuse = (0.7, 0.3, 0.1)
        secondary_emission = (0.02, 0.03, 0.04)

        estimates = []
        maximum_sample_error = 0.0
        for frame in range(min(self.frames, 8192)):
            direction = cosine_sample_hemisphere(phase1_jitter(ATLAS_COORD, frame, 0))
            estimate = fresh_estimator_sample(incident, direction)
            estimates.append(estimate)
            maximum_sample_error = max(maximum_sample_error, max_relative_error(estimate, incident))
        diffuse_normalized = mean_vectors(estimates)
        assert_vector_close(diffuse_normalized, incident, 1e-12, "constant_environment_D")

        energy_scaled = {
            str(energy): mul_scalar(diffuse_normalized, energy) for energy in (0.0, 0.5, 2.0)
        }
        for energy, expected_energy_D in (
            (0.0, (0.0, 0.0, 0.0)),
            (0.5, (0.4, 0.25, 0.1)),
            (2.0, (1.6, 1.0, 0.4)),
        ):
            assert_vector_close(
                energy_scaled[str(energy)], expected_energy_D, 1e-12, f"dynamic_gi_energy_{energy:g}"
            )

        final_indirect = mul_components(receiver_albedo, diffuse_normalized)
        assert_vector_close(final_indirect, (0.2, 0.25, 0.15), 1e-12, "receiver_albedo_once")

        secondary_outgoing = add(mul_components(secondary_albedo, secondary_diffuse), secondary_emission)
        assert_vector_close(secondary_outgoing, (0.44, 0.15, 0.06), 1e-12, "secondary_Lo_contract")
        return {
            "constant_incident_radiance": incident,
            "estimated_D": diffuse_normalized,
            "dynamic_gi_energy_scaled_D": energy_scaled,
            "receiver_albedo": receiver_albedo,
            "final_indirect_diffuse": final_indirect,
            "secondary_D": secondary_diffuse,
            "secondary_albedo": secondary_albedo,
            "secondary_emission": secondary_emission,
            "secondary_Lo": secondary_outgoing,
            "maximum_sample_relative_error": maximum_sample_error,
            "contract": "screen probe stores D without receiver albedo; final shading multiplies receiver albedo exactly once",
        }

    @staticmethod
    def analytic_incident(direction: Vec3) -> Vec3:
        z = direction[2]
        return 0.25 + 0.75 * z, 0.4 + 0.5 * z * z, 0.1 + 0.6 * z * z * z

    def estimate_candidate_count(self, candidate_count: int) -> Vec3:
        frame_estimates: list[Vec3] = []
        for frame in range(self.frames):
            frame_estimates.append(
                mean_vectors(
                    fresh_estimator_sample(
                        self.analytic_incident(cosine_sample_hemisphere(phase1_jitter(ATLAS_COORD, frame, candidate))),
                        cosine_sample_hemisphere(phase1_jitter(ATLAS_COORD, frame, candidate)),
                    )
                    for candidate in range(candidate_count)
                )
            )
        return mean_vectors(frame_estimates)

    def test_nonconstant_integrand_and_candidate_invariance(self) -> dict[str, object]:
        # For cosine sampling, z has density 2z and E[z^k]=2/(k+2).
        expected = (
            0.25 + 0.75 * (2.0 / 3.0),
            0.4 + 0.5 * (2.0 / 4.0),
            0.1 + 0.6 * (2.0 / 5.0),
        )
        estimates = {candidate_count: self.estimate_candidate_count(candidate_count) for candidate_count in (1, 2, 4, 8)}
        errors = {candidate_count: max_relative_error(estimate, expected) for candidate_count, estimate in estimates.items()}
        for candidate_count, error in errors.items():
            if error >= 0.005:
                raise AssertionError(f"candidate_count={candidate_count} analytic relative error {error:.6g} >= 0.5%")
        pairwise_error = max(
            max_relative_error(estimates[first], estimates[second])
            for first in estimates
            for second in estimates
            if first != second
        )
        if pairwise_error >= 0.005:
            raise AssertionError(f"candidate-count pairwise mean error {pairwise_error:.6g} >= 0.5%")
        return {
            "frames_per_candidate_count": self.frames,
            "analytic_D": expected,
            "estimated_D": {str(key): value for key, value in estimates.items()},
            "relative_error_to_analytic": {str(key): value for key, value in errors.items()},
            "maximum_pairwise_relative_error": pairwise_error,
            "acceptance_relative_error": 0.005,
        }

    def test_visibility_and_miss_are_samples(self) -> dict[str, object]:
        incident = (0.6, 0.3, 0.1)
        cosine_threshold = 0.4
        estimates: list[Vec3] = []
        accepted = 0
        for frame in range(self.frames):
            direction = cosine_sample_hemisphere(phase1_jitter((43, 71), frame, 3))
            visibility = 1.0 if direction[2] > cosine_threshold else 0.0
            accepted += int(visibility)
            estimates.append(fresh_estimator_sample(incident, direction, visibility))
        estimate = mean_vectors(estimates)
        expected_visibility = 1.0 - cosine_threshold * cosine_threshold
        expected = mul_scalar(incident, expected_visibility)
        error = max_relative_error(estimate, expected)
        if error >= 0.005:
            raise AssertionError(f"visibility estimator relative error {error:.6g} >= 0.5%")

        # A sky/miss contribution remains a valid Li sample; it is not zeroed by a hit flag.
        miss_radiance = (0.12, 0.2, 0.35)
        miss_direction = cosine_sample_hemisphere((0.37, 0.91))
        assert_vector_close(
            fresh_estimator_sample(miss_radiance, miss_direction, 1.0),
            miss_radiance,
            1e-12,
            "sky_miss_contribution",
        )
        return {
            "samples": self.frames,
            "cosine_visibility_threshold": cosine_threshold,
            "observed_visibility_probability": float(accepted) / float(self.frames),
            "analytic_visibility_probability": expected_visibility,
            "estimated_D": estimate,
            "analytic_D": expected,
            "relative_error": error,
            "sky_miss_radiance": miss_radiance,
            "sky_miss_estimate": fresh_estimator_sample(miss_radiance, miss_direction, 1.0),
        }

    def execute(self) -> dict[str, object]:
        self.run_case("fixed_shader_random_stream", self.test_fixed_shader_random_stream)
        self.run_case("shader_contract_alignment", self.test_shader_contract_alignment)
        self.run_case("cosine_warp_and_pdf", self.test_cosine_warp_and_pdf)
        self.run_case("constant_environment_and_radiometry", self.test_constant_environment_and_radiometry)
        self.run_case(
            "nonconstant_integrand_and_candidate_invariance",
            self.test_nonconstant_integrand_and_candidate_invariance,
        )
        self.run_case("visibility_and_sky_miss", self.test_visibility_and_miss_are_samples)
        failed = [result for result in self.results if result.status != "passed"]
        return {
            "schema_version": "1.0.0",
            "suite": "hddagi_screen_probe_phase1_cpu_reference",
            "status": "failed" if failed else "completed",
            "precision": "Python binary64 estimator with explicit GLSL float32 random-stream rounding",
            "fixed_atlas_coord": list(ATLAS_COORD),
            "frames_per_monte_carlo_case": self.frames,
            "candidate_counts": [1, 2, 4, 8],
            "estimator_contract": {
                "proposal_pdf": "q_cos(omega)=max(dot(n,omega),0)/pi",
                "integrand": "g=Li*V*max(dot(n,omega),0)/pi",
                "single_sample": "D_hat=g/q=Li*V",
                "multi_sample": "arithmetic mean of N independent fresh samples",
                "output": "D=E/pi without receiver albedo",
            },
            "cases": [result.__dict__ for result in self.results],
            "failure_count": len(failed),
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames", type=int, default=DEFAULT_FRAMES)
    parser.add_argument("--json-output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.frames < 4096:
        print("--frames must be at least 4096 for the declared Monte Carlo tolerances", file=sys.stderr)
        return 2
    result = ReferenceSuite(args.frames).execute()
    encoded = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        temporary = args.json_output.with_suffix(args.json_output.suffix + ".tmp")
        temporary.write_text(encoded, encoding="utf-8")
        os.replace(temporary, args.json_output)
    print(
        "HDDAGI_PHASE1_CPU_REFERENCE "
        + json.dumps(
            {
                "status": result["status"],
                "cases": len(result["cases"]),
                "failures": result["failure_count"],
                "frames": result["frames_per_monte_carlo_case"],
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

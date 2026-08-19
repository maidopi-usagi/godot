#!/usr/bin/env python3
"""Post-exit validator for the HDDAGI screen-probe manual QA project."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;]*m")
GPU_HEADER = re.compile(r"^GPU PROFILE \(total ([0-9.eE+\-]+)ms\):")
GPU_TASK = re.compile(r"^\s*-(.+): ([0-9.eE+\-]+)ms\s*$")
COUNTER_MARKER = "HDDAGI_SCREEN_PROBE_COUNTERS "
SEGMENT_MARKER = "HDDAGI_QA_SEGMENT "
TAGGED_SEGMENT = re.compile(r"^tag=([0-9]+) name=(.+)$")
MEMORY_FIELDS = ("video_mem_used", "texture_mem_used", "buffer_mem_used")
PHASE1_REQUIRED_PROFILE_TASKS = (
    "HDDAGI Screen Probe Surface Select",
    "HDDAGI Screen Probe Fresh Trace",
    "HDDAGI Screen Probe Raw Resolve",
)
PHASE1_ALLOWED_PROFILE_TASKS = PHASE1_REQUIRED_PROFILE_TASKS + (
    "HDDAGI NRD Guide Preparation",
    "HDDAGI Screen Probe Apply",
)
PHASE2_REQUIRED_PROFILE_TASKS = (
    "HDDAGI Screen Probe Surface Select",
    "HDDAGI Screen Probe Phase 2 Fresh Reservoir",
    "HDDAGI Screen Probe Phase 2 Temporal Stream Merge",
    "HDDAGI Screen Probe Raw Resolve",
    "HDDAGI NRD Guide Preparation",
)
PHASE2_ALLOWED_PROFILE_TASKS = PHASE2_REQUIRED_PROFILE_TASKS + (
    "HDDAGI Screen Probe Apply",
)
PHASE1_RAW_FIXED_SCALE = 1024.0
PHASE1_RAW_LATTICE_STRIDE = 16
PHASE1_RAW_LATTICE_PERIOD = PHASE1_RAW_LATTICE_STRIDE * PHASE1_RAW_LATTICE_STRIDE
PHASE1_RAW_WINDOW_FRAMES = 60
PHASE2_COMPARISON_MIN_FRAMES = 64
PHASE2_ALGORITHM_MODE = 3
PHASE2_ALGORITHM_NAME = "phase2_temporal_restir"
PHASE2_GPU_GOLDEN_DIGEST_SCHEMA_VERSION = 3
RESULT_SCHEMA_VERSION = "1.0.0"
PHASE2_MANIFEST_SCHEMA_VERSION = "2.0.0"
PHASE2_SUITE_NAME = "hddagi_screen_probe_phase2_temporal_restir"
PHASE2_COUNTER_FIELDS = (
    "reservoir_valid_surfaces",
    "reservoir_fresh_valid",
    "reservoir_fresh_invalid",
    "reservoir_temporal_attempts",
    "reservoir_temporal_accepted",
    "reservoir_reject_no_history",
    "reservoir_reject_reprojection_or_owner",
    "reservoir_reject_generation_or_algorithm",
    "reservoir_reject_endpoint_identity_or_version",
    "reservoir_reject_visibility",
    "reservoir_reject_jacobian",
    "reservoir_reject_age",
    "reservoir_visibility_rays",
    "reservoir_visibility_visible",
    "reservoir_visibility_occluded",
    "reservoir_m_cap_applied",
    "reservoir_selected_fresh",
    "reservoir_selected_history",
    "reservoir_final_valid",
    "reservoir_final_invalid",
    "reservoir_nonfinite",
    "reservoir_robust_jacobian_clamp",
    "reservoir_max_m",
    "reservoir_max_age",
    "reservoir_sum_m",
    "reservoir_packing_invalid",
    "reservoir_hit_reuse",
    "reservoir_sky_reuse",
    "reservoir_robust_flag_final_fresh",
    "reservoir_robust_flag_final_history",
    "reservoir_zero_target_mass_only",
)
COUNTER_NON_INTEGER_FIELDS = {
    "algorithm",
    "qa_segment",
    "raw_hdr_fixed_scale",
    "raw_hdr_lattice_phase_mask_words",
    "raw_hdr_mean_rgb",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--result", required=True, type=Path)
    parser.add_argument("--console-log", required=True, type=Path)
    parser.add_argument("--engine-log", required=True, type=Path)
    parser.add_argument("--expected", required=True, type=Path)
    parser.add_argument("--editor", required=True, type=Path)
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--editor-exit-code", required=True, type=int)
    parser.add_argument("--cpu-reference", type=Path)
    return parser.parse_args()


def clean_line(line: str) -> str:
    return ANSI_ESCAPE.sub("", line).rstrip("\r\n")


def read_lines(path: Path) -> list[str]:
    if not path.is_file():
        return []
    return [clean_line(line) for line in path.read_text(encoding="utf-8", errors="replace").splitlines()]


def parse_segment_descriptor(line: str) -> tuple[str, int | None] | None:
    marker_offset = line.find(SEGMENT_MARKER)
    if marker_offset < 0:
        return None
    descriptor = line[marker_offset + len(SEGMENT_MARKER) :].strip()
    tagged = TAGGED_SEGMENT.fullmatch(descriptor)
    if tagged:
        return tagged.group(2), int(tagged.group(1))
    return descriptor, None


def add_unique(items: list[str], message: str) -> None:
    if message not in items:
        items.append(message)


def safe_int(value: Any, default: int = 0) -> int:
    """Convert untrusted JSON to an exact integer without ever raising."""
    if isinstance(value, bool):
        return default
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value) if math.isfinite(value) and value.is_integer() else default
    if isinstance(value, str) and re.fullmatch(r"[+-]?[0-9]+", value.strip()):
        try:
            return int(value, 10)
        except ValueError:
            return default
    return default


def exact_int(value: Any) -> int | None:
    sentinel = object()
    converted = safe_int(value, sentinel)  # type: ignore[arg-type]
    return None if converted is sentinel else converted  # type: ignore[return-value]


def safe_float(value: Any, default: float = math.nan) -> float:
    if isinstance(value, bool):
        return default
    try:
        converted = float(value)
    except (TypeError, ValueError, OverflowError):
        return default
    return converted if math.isfinite(converted) else default


def get_path(value: Any, dotted_path: str) -> Any:
    current = value
    for component in dotted_path.split("."):
        if not isinstance(current, dict) or component not in current:
            raise KeyError(dotted_path)
        current = current[component]
    return current


def summarize(values: list[float]) -> dict[str, float | int]:
    if not values:
        return {"count": 0, "mean": 0.0, "variance": 0.0, "min": 0.0, "max": 0.0}
    mean = sum(values) / len(values)
    variance = max(sum(value * value for value in values) / len(values) - mean * mean, 0.0)
    return {
        "count": len(values),
        "mean": mean,
        "variance": variance,
        "min": min(values),
        "max": max(values),
    }


def parse_counters(lines: list[str]) -> tuple[list[dict[str, Any]], list[str]]:
    snapshots: list[dict[str, Any]] = []
    malformed: list[str] = []
    current_segment = "unsegmented"
    tagged_segments: dict[int, str] = {}
    for line_number, line in enumerate(lines, start=1):
        segment_descriptor = parse_segment_descriptor(line)
        if segment_descriptor is not None:
            current_segment, segment_tag = segment_descriptor
            if segment_tag is not None:
                if segment_tag in tagged_segments:
                    malformed.append(f"line {line_number}: duplicate debug counter segment tag {segment_tag}")
                tagged_segments[segment_tag] = current_segment
            continue
        marker_offset = line.find(COUNTER_MARKER)
        if marker_offset < 0:
            continue
        payload = line[marker_offset + len(COUNTER_MARKER) :].strip()
        try:
            parsed = json.loads(payload)
        except json.JSONDecodeError as exc:
            malformed.append(f"line {line_number}: malformed counter JSON ({exc.msg})")
            continue
        if isinstance(parsed, dict):
            counter_tag = exact_int(parsed.get("debug_counter_tag"))
            if counter_tag is not None and counter_tag in tagged_segments:
                parsed["qa_segment"] = tagged_segments[counter_tag]
            else:
                parsed["qa_segment"] = current_segment
                if "debug_counter_tag" in parsed:
                    malformed.append(
                        f"line {line_number}: counter tag {parsed.get('debug_counter_tag')!r} has no segment mapping"
                    )
            snapshots.append(parsed)
        else:
            malformed.append(f"line {line_number}: counter payload is not a JSON object")
    return snapshots, malformed


def parse_gpu_profile(lines: list[str]) -> dict[str, Any]:
    all_block_count = 0
    hddagi_blocks: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None
    current_segment = "unsegmented"

    def flush() -> None:
        nonlocal current
        if current and current["hddagi_tasks"]:
            hddagi_blocks.append(current)
        current = None

    for line in lines:
        stripped = line.strip()
        segment_descriptor = parse_segment_descriptor(line)
        if segment_descriptor is not None:
            flush()
            current_segment = segment_descriptor[0]
            continue
        header_match = GPU_HEADER.match(stripped)
        if header_match:
            flush()
            all_block_count += 1
            current = {
                "qa_segment": current_segment,
                "total_gpu_ms": float(header_match.group(1)),
                "hddagi_tasks": {},
                "hddagi_total_ms": 0.0,
            }
            continue
        if current is None:
            continue
        task_match = GPU_TASK.match(stripped)
        if task_match:
            task_name = task_match.group(1)
            task_ms = float(task_match.group(2))
            if "HDDAGI Screen Probe" in task_name or "HDDAGI NRD" in task_name:
                current["hddagi_tasks"][task_name] = task_ms
                current["hddagi_total_ms"] += task_ms
            continue
        if stripped:
            flush()
    flush()

    def summarize_blocks(blocks: list[dict[str, Any]]) -> dict[str, Any]:
        task_values: dict[str, list[float]] = {}
        for block in blocks:
            for task_name, task_ms in block["hddagi_tasks"].items():
                task_values.setdefault(task_name, []).append(float(task_ms))
        return {
            "block_count": len(blocks),
            "hddagi_sample_count": sum(len(block["hddagi_tasks"]) for block in blocks),
            "task_summaries_ms": {name: summarize(values) for name, values in sorted(task_values.items())},
            "hddagi_total_per_block_ms": summarize([float(block["hddagi_total_ms"]) for block in blocks]),
        }

    global_summary = summarize_blocks(hddagi_blocks)
    candidate_segments: dict[str, dict[str, Any]] = {}
    stable_candidate_blocks: list[dict[str, Any]] = []
    for candidate_count in (1, 2, 4, 8):
        segment_name = f"phase1_fresh/candidates_{candidate_count}_sample"
        segment_blocks = [block for block in hddagi_blocks if block["qa_segment"] == segment_name]
        # Godot's periodic GPU PROFILE block is a trailing aggregate. The first
        # block printed after a warmup -> sample marker can still include warmup,
        # pipeline-transition, or clock-ramp work, so it is diagnostic only.
        stable_blocks = segment_blocks[1:] if len(segment_blocks) > 1 else []
        stable_candidate_blocks.extend(stable_blocks)
        block_contracts: list[dict[str, Any]] = []
        for block_index, block in enumerate(stable_blocks):
            observed_tasks = set(block["hddagi_tasks"])
            missing_tasks = sorted(set(PHASE1_REQUIRED_PROFILE_TASKS) - observed_tasks)
            unexpected_tasks = sorted(observed_tasks - set(PHASE1_ALLOWED_PROFILE_TASKS))
            block_contracts.append(
                {
                    "stable_block_index": block_index,
                    "missing_tasks": missing_tasks,
                    "unexpected_tasks": unexpected_tasks,
                    "valid": not missing_tasks and not unexpected_tasks,
                }
            )
        task_contract_valid = bool(stable_blocks) and all(
            bool(contract["valid"]) for contract in block_contracts
        )
        candidate_segments[str(candidate_count)] = {
            "qa_segment": segment_name,
            "observed_block_count": len(segment_blocks),
            "transition_blocks_excluded": min(len(segment_blocks), 1),
            "stable": summarize_blocks(stable_blocks),
            "task_contract": {
                "required_tasks": list(PHASE1_REQUIRED_PROFILE_TASKS),
                "allowed_tasks": list(PHASE1_ALLOWED_PROFILE_TASKS),
                "apply_observed_block_count": sum(
                    int("HDDAGI Screen Probe Apply" in block["hddagi_tasks"])
                    for block in stable_blocks
                ),
                "valid": task_contract_valid,
                "complete_block_count": sum(int(contract["valid"]) for contract in block_contracts),
                "invalid_block_count": sum(int(not contract["valid"]) for contract in block_contracts),
                "blocks": block_contracts,
            },
        }
    stable_candidate_summary = summarize_blocks(stable_candidate_blocks)
    stable_candidate_summary["candidate_segment_coverage_count"] = sum(
        int(segment["task_contract"]["valid"]) for segment in candidate_segments.values()
    )
    stable_candidate_summary["candidate_segments"] = candidate_segments
    stable_candidate_summary["selection_contract"] = (
        "phase1_fresh candidates N=1/2/4/8 sample segments; first trailing GPU PROFILE block "
        "after each warmup-to-sample transition is excluded; every retained block must contain "
        "Surface Select, Fresh Trace, and Raw Resolve, may additionally print Apply, and may not "
        "contain any other HDDAGI task. Godot suppresses averaged GPU PROFILE tasks <=0.01 ms, so "
        "Apply execution is gated by independent raw-to-output image checks rather than marker presence"
    )

    phase2_segments: dict[str, dict[str, Any]] = {}
    stable_phase2_blocks: list[dict[str, Any]] = []
    for case_name in ("constant", "colored"):
        segment_name = f"phase2_temporal/{case_name}/p2_n1_visibility_sample"
        segment_blocks = [block for block in hddagi_blocks if block["qa_segment"] == segment_name]
        stable_blocks = segment_blocks[1:] if len(segment_blocks) > 1 else []
        stable_phase2_blocks.extend(stable_blocks)
        block_contracts: list[dict[str, Any]] = []
        for block_index, block in enumerate(stable_blocks):
            observed_tasks = set(block["hddagi_tasks"])
            missing_tasks = sorted(set(PHASE2_REQUIRED_PROFILE_TASKS) - observed_tasks)
            unexpected_tasks = sorted(observed_tasks - set(PHASE2_ALLOWED_PROFILE_TASKS))
            block_contracts.append(
                {
                    "stable_block_index": block_index,
                    "missing_tasks": missing_tasks,
                    "unexpected_tasks": unexpected_tasks,
                    "valid": not missing_tasks and not unexpected_tasks,
                }
            )
        task_contract_valid = bool(stable_blocks) and all(
            bool(contract["valid"]) for contract in block_contracts
        )
        phase2_segments[case_name] = {
            "qa_segment": segment_name,
            "observed_block_count": len(segment_blocks),
            "transition_blocks_excluded": min(len(segment_blocks), 1),
            "stable": summarize_blocks(stable_blocks),
            "task_contract": {
                "required_tasks": list(PHASE2_REQUIRED_PROFILE_TASKS),
                "allowed_tasks": list(PHASE2_ALLOWED_PROFILE_TASKS),
                "valid": task_contract_valid,
                "complete_block_count": sum(
                    int(contract["valid"]) for contract in block_contracts
                ),
                "invalid_block_count": sum(
                    int(not contract["valid"]) for contract in block_contracts
                ),
                "blocks": block_contracts,
            },
        }
    stable_phase2_summary = summarize_blocks(stable_phase2_blocks)
    stable_phase2_summary["segment_coverage_count"] = sum(
        int(segment["task_contract"]["valid"]) for segment in phase2_segments.values()
    )
    stable_phase2_summary["segments"] = phase2_segments
    stable_phase2_summary["selection_contract"] = (
        "phase2_temporal constant/colored P2 N=1+visibility sample segments; first trailing "
        "GPU PROFILE block after each warmup-to-sample transition is excluded; retained blocks "
        "must contain Surface Select, Phase 2 Fresh Reservoir, Phase 2 Temporal Stream Merge, "
        "Raw Resolve, and NRD Guide Preparation, may additionally print Apply, and may contain "
        "no obsolete HDDAGI task"
    )
    return {
        "enabled": True,
        "post_exit_complete_log": True,
        "profile_block_count": all_block_count,
        "hddagi_block_count": len(hddagi_blocks),
        "hddagi_sample_count": global_summary["hddagi_sample_count"],
        "hddagi_blocks": hddagi_blocks,
        "task_summaries_ms": global_summary["task_summaries_ms"],
        "hddagi_total_per_block_ms": global_summary["hddagi_total_per_block_ms"],
        "phase1_stable_candidate_samples": stable_candidate_summary,
        "phase2_stable_temporal_samples": stable_phase2_summary,
    }


def phase1_raw_phase_indices(mask_words: Any) -> list[int]:
    if not isinstance(mask_words, list) or len(mask_words) != 8:
        raise ValueError("raw HDR lattice phase mask must contain eight uint32 words")
    phases: list[int] = []
    for word_index, raw_word in enumerate(mask_words):
        converted = exact_int(raw_word)
        if converted is None:
            raise ValueError("raw HDR lattice phase mask word is not an exact integer")
        word = converted
        if word < 0 or word > 0xFFFFFFFF:
            raise ValueError("raw HDR lattice phase mask word is outside uint32")
        for bit_index in range(32):
            if word & (1 << bit_index):
                phases.append(word_index * 32 + bit_index)
    return phases


def phase1_expected_raw_sample_count(
    width: int, height: int, view_count: int, phases: list[int]
) -> int:
    expected = 0
    for phase in phases:
        phase_x = phase & (PHASE1_RAW_LATTICE_STRIDE - 1)
        phase_y = phase >> 4
        x_count = (
            (width - 1 - phase_x) // PHASE1_RAW_LATTICE_STRIDE + 1
            if phase_x < width
            else 0
        )
        y_count = (
            (height - 1 - phase_y) // PHASE1_RAW_LATTICE_STRIDE + 1
            if phase_y < height
            else 0
        )
        expected += x_count * y_count * view_count
    return expected


def validate_counter_semantics(
    snapshots: list[dict[str, Any]],
    required_fields: list[str],
    scenario: str,
    expected_width: int,
    expected_height: int,
    expected_view_count: int,
    phase2_configuration: dict[str, Any] | None = None,
) -> list[str]:
    failures: list[str] = []
    full_suite = scenario == "all"
    for index, snapshot in enumerate(snapshots):
        missing = [field for field in required_fields if field not in snapshot]
        if missing:
            failures.append(f"counter snapshot {index} missing fields: {', '.join(missing)}")
            continue
        for field in required_fields:
            if field not in COUNTER_NON_INTEGER_FIELDS and exact_int(snapshot.get(field)) is None:
                failures.append(f"counter snapshot {index}: {field} must be an exact finite integer")
        width = safe_int(snapshot.get("width"), -1)
        height = safe_int(snapshot.get("height"), -1)
        view_count = safe_int(snapshot.get("view_count"), -1)
        if width <= 0 or (scenario != "phase2_temporal" and width != expected_width):
            failures.append(f"counter snapshot {index}: width must match the rendered result")
        if height <= 0 or (scenario != "phase2_temporal" and height != expected_height):
            failures.append(f"counter snapshot {index}: height must match the rendered result")
        if view_count <= 0 or view_count != expected_view_count:
            failures.append(f"counter snapshot {index}: view_count must match the rendered result")
        rays = safe_int(snapshot.get("hdda_rays"), -1)
        hits = safe_int(snapshot.get("hdda_hits"), -1)
        misses = safe_int(snapshot.get("hdda_misses"), -1)
        if hits + misses != rays:
            failures.append(f"counter snapshot {index}: hdda_hits + hdda_misses != hdda_rays")
        sharc_fields = (
            "sharc_query_attempts",
            "sharc_query_hits",
            "sharc_query_ineligible",
            "sharc_query_misses",
            "sharc_update_rays",
            "sharc_update_misses",
            "sharc_update_rejects",
        )
        if any(safe_int(snapshot.get(field), -1) < 0 for field in sharc_fields):
            failures.append(f"counter snapshot {index}: SHARC counters must be uint32 values")
        query_attempts = safe_int(snapshot.get("sharc_query_attempts"), -1)
        query_hits = safe_int(snapshot.get("sharc_query_hits"), -1)
        query_ineligible = safe_int(snapshot.get("sharc_query_ineligible"), -1)
        query_misses = safe_int(snapshot.get("sharc_query_misses"), -1)
        if query_attempts != query_hits + query_ineligible + query_misses:
            failures.append(
                f"counter snapshot {index}: sharc_query_attempts must equal "
                "hits + ineligible + misses"
            )
        if query_attempts > hits:
            failures.append(f"counter snapshot {index}: SHARC query attempts exceed HDDA hits")
        update_rays = safe_int(snapshot.get("sharc_update_rays"), -1)
        update_misses = safe_int(snapshot.get("sharc_update_misses"), -1)
        update_rejects = safe_int(snapshot.get("sharc_update_rejects"), -1)
        if update_rays > rays:
            failures.append(f"counter snapshot {index}: SHARC update rays exceed HDDA rays")
        if update_misses + update_rejects > update_rays:
            failures.append(
                f"counter snapshot {index}: SHARC update misses + rejects exceed update rays"
            )
        if update_misses > misses:
            failures.append(f"counter snapshot {index}: SHARC update misses exceed HDDA misses")
        if update_rejects > hits:
            failures.append(f"counter snapshot {index}: SHARC update rejects exceed HDDA hits")
    off_snapshots = [
        snapshot
        for snapshot in snapshots
        if safe_int(snapshot.get("feature_flags"), -1) & (2 | 4 | 64) == 0
        and ((safe_int(snapshot.get("feature_flags"), -1) >> 3) & 7) == 0
    ]
    on_snapshots = [
        snapshot
        for snapshot in snapshots
        if safe_int(snapshot.get("feature_flags"), 0) & (2 | 64) == (2 | 64)
        and ((safe_int(snapshot.get("feature_flags"), 0) >> 3) & 7) >= 1
    ]
    if full_suite:
        for index, snapshot in enumerate(snapshots):
            feature_flags = safe_int(snapshot.get("feature_flags"), -1)
            algorithm_mode = safe_int(snapshot.get("algorithm_mode"), -1)
            algorithm = str(snapshot.get("algorithm", ""))
            valid_identity = (
                feature_flags & (2 | 64) == 0
                and algorithm_mode == 1
                and algorithm == "phase1_fresh"
            ) or (
                feature_flags & 64 != 0
                and algorithm_mode == 4
                and algorithm == "phase3_spatial_restir"
            )
            if not valid_identity:
                failures.append(
                    f"counter snapshot {index}: full suite observed unexpected "
                    f"(feature_flags, algorithm_mode, algorithm)={(feature_flags, algorithm_mode, algorithm)}"
                )
    if full_suite and not off_snapshots:
        failures.append("no default/off counter snapshot was captured")
    if full_suite and not on_snapshots:
        failures.append("no temporal+spatial Phase 3 counter snapshot was captured")
    for index, snapshot in enumerate(off_snapshots):
        if safe_int(snapshot.get("hdda_rays"), 0) <= 0:
            failures.append(f"off counter snapshot {index}: hdda_rays must be non-zero")
        if full_suite and safe_int(snapshot.get("algorithm_mode"), -1) != 1:
            failures.append(f"off counter snapshot {index}: algorithm_mode must be 1 (phase1_fresh)")
        if full_suite and snapshot.get("algorithm") != "phase1_fresh":
            failures.append(f"off counter snapshot {index}: algorithm must be phase1_fresh")
        if full_suite and (
            safe_int(snapshot.get("fresh_candidates"), 0)
            + safe_int(snapshot.get("sharc_update_rays"), 0)
            != safe_int(snapshot.get("hdda_rays"), -1)
        ):
            failures.append(
                f"off counter snapshot {index}: fresh_candidates + SHARC update rays must equal hdda_rays"
            )
        for field in (
            "temporal_guided_candidates",
            "spatial_guided_candidates",
        ):
            if safe_int(snapshot.get(field), -1) != 0:
                failures.append(f"off counter snapshot {index}: {field} must be zero")
    for index, snapshot in enumerate(on_snapshots):
        if safe_int(snapshot.get("hdda_rays"), 0) <= 0:
            failures.append(f"on counter snapshot {index}: hdda_rays must be non-zero")
        if full_suite and safe_int(snapshot.get("algorithm_mode"), -1) != 4:
            failures.append(f"on counter snapshot {index}: algorithm_mode must be 4 (phase3_spatial_restir)")
        if full_suite and snapshot.get("algorithm") != "phase3_spatial_restir":
            failures.append(f"on counter snapshot {index}: algorithm must be phase3_spatial_restir")
        if safe_int(snapshot.get("fresh_candidates"), 0) <= 0:
            failures.append(f"on counter snapshot {index}: fresh_candidates must be non-zero")

    if scenario == "phase1_fresh":
        allowed_feature_flags = {1, 9, 25, 57}
        for index, snapshot in enumerate(snapshots):
            identity = (
                safe_int(snapshot.get("feature_flags"), -1),
                safe_int(snapshot.get("algorithm_mode"), -1),
                str(snapshot.get("algorithm", "")),
            )
            if (
                identity[0] not in allowed_feature_flags
                or identity[1] != 2
                or identity[2] != "phase1_reference"
            ):
                failures.append(
                    f"counter snapshot {index}: Phase 1 observed unexpected "
                    f"(feature_flags, algorithm_mode, algorithm)={identity}"
                )
        for candidate_count in (1, 2, 4, 8):
            expected_feature_flags = 1 + ((candidate_count - 1) << 3)
            matching = [
                snapshot
                for snapshot in snapshots
                if safe_int(snapshot.get("feature_flags"), 0) == expected_feature_flags
            ]
            if not matching:
                failures.append(f"phase1 fresh reference captured no candidate_count={candidate_count} snapshot")
                continue
            for index, snapshot in enumerate(matching):
                if safe_int(snapshot.get("algorithm_mode"), -1) != 2:
                    failures.append(
                        f"phase1 candidate_count={candidate_count} snapshot {index}: algorithm_mode must be 2"
                    )
                if snapshot.get("algorithm") != "phase1_reference":
                    failures.append(
                        f"phase1 candidate_count={candidate_count} snapshot {index}: algorithm must be phase1_reference"
                    )
                fresh = safe_int(snapshot.get("fresh_candidates"), 0)
                rays = safe_int(snapshot.get("hdda_rays"), 0)
                if fresh <= 0:
                    failures.append(
                        f"phase1 candidate_count={candidate_count} snapshot {index}: fresh_candidates must be non-zero"
                    )
                if fresh + safe_int(snapshot.get("sharc_update_rays"), 0) != rays:
                    failures.append(
                        f"phase1 candidate_count={candidate_count} snapshot {index}: fresh_candidates + SHARC update rays must equal hdda_rays"
                    )
                if fresh % candidate_count != 0:
                    failures.append(
                        f"phase1 candidate_count={candidate_count} snapshot {index}: fresh candidate count is not divisible by N"
                    )
                for field in (
                    "temporal_guided_candidates",
                    "spatial_guided_candidates",
                ):
                    if safe_int(snapshot.get(field), -1) != 0:
                        failures.append(
                            f"phase1 candidate_count={candidate_count} snapshot {index}: {field} must be zero"
                        )
                raw_sample_count = safe_int(snapshot.get("raw_hdr_sample_count"), 0)
                raw_overflow = safe_int(snapshot.get("raw_hdr_nonfinite_or_overflow"), -1)
                raw_mean = snapshot.get("raw_hdr_mean_rgb", [])
                if raw_sample_count <= 0:
                    failures.append(
                        f"phase1 candidate_count={candidate_count} snapshot {index}: raw_hdr_sample_count must be positive"
                    )
                if raw_overflow != 0:
                    failures.append(
                        f"phase1 candidate_count={candidate_count} snapshot {index}: raw HDR nonfinite/overflow must be zero"
                    )
                if (
                    not isinstance(raw_mean, list)
                    or len(raw_mean) != 3
                    or any(not math.isfinite(safe_float(channel)) or safe_float(channel) < 0.0 for channel in raw_mean)
                ):
                    failures.append(
                        f"phase1 candidate_count={candidate_count} snapshot {index}: raw_hdr_mean_rgb must be finite non-negative RGB"
                    )
                    continue
                if raw_sample_count <= 0:
                    continue
                fixed_scale = safe_float(snapshot.get("raw_hdr_fixed_scale"))
                if not math.isclose(fixed_scale, PHASE1_RAW_FIXED_SCALE, rel_tol=0.0, abs_tol=0.0):
                    failures.append(
                        f"phase1 candidate_count={candidate_count} snapshot {index}: raw HDR fixed scale must be {PHASE1_RAW_FIXED_SCALE:g}"
                    )
                    continue
                if safe_int(snapshot.get("raw_hdr_lattice_stride"), 0) != PHASE1_RAW_LATTICE_STRIDE:
                    failures.append(
                        f"phase1 candidate_count={candidate_count} snapshot {index}: raw HDR lattice stride must be {PHASE1_RAW_LATTICE_STRIDE}"
                    )
                if safe_int(snapshot.get("raw_hdr_lattice_period"), 0) != PHASE1_RAW_LATTICE_PERIOD:
                    failures.append(
                        f"phase1 candidate_count={candidate_count} snapshot {index}: raw HDR lattice period must be {PHASE1_RAW_LATTICE_PERIOD}"
                    )
                accumulated_frames = safe_int(snapshot.get("raw_hdr_accumulated_frame_count"), 0)
                if accumulated_frames != PHASE1_RAW_WINDOW_FRAMES:
                    failures.append(
                        f"phase1 candidate_count={candidate_count} snapshot {index}: raw HDR window must contain exactly {PHASE1_RAW_WINDOW_FRAMES} rendered frames"
                    )
                try:
                    phases = phase1_raw_phase_indices(
                        snapshot.get("raw_hdr_lattice_phase_mask_words")
                    )
                except (TypeError, ValueError) as exc:
                    failures.append(
                        f"phase1 candidate_count={candidate_count} snapshot {index}: {exc}"
                    )
                    continue
                reported_phase_coverage = safe_int(
                    snapshot.get("raw_hdr_lattice_phase_coverage_count", -1)
                )
                if reported_phase_coverage != len(phases):
                    failures.append(
                        f"phase1 candidate_count={candidate_count} snapshot {index}: reported raw phase coverage does not match mask popcount"
                    )
                if len(phases) != PHASE1_RAW_WINDOW_FRAMES:
                    failures.append(
                        f"phase1 candidate_count={candidate_count} snapshot {index}: 60-frame raw window must cover 60 distinct lattice phases"
                    )
                expected_raw_sample_count = phase1_expected_raw_sample_count(
                    safe_int(snapshot.get("width"), 0),
                    safe_int(snapshot.get("height"), 0),
                    safe_int(snapshot.get("view_count"), 0),
                    phases,
                )
                if raw_sample_count != expected_raw_sample_count:
                    failures.append(
                        f"phase1 candidate_count={candidate_count} snapshot {index}: raw sample count {raw_sample_count} does not match lattice mask expectation {expected_raw_sample_count}"
                    )
                fixed_sums = [
                    safe_int(snapshot.get("raw_hdr_fixed_sum_r"), -1),
                    safe_int(snapshot.get("raw_hdr_fixed_sum_g"), -1),
                    safe_int(snapshot.get("raw_hdr_fixed_sum_b"), -1),
                ]
                if any(fixed_sum < 0 or fixed_sum > 0xFFFFFFFF for fixed_sum in fixed_sums):
                    failures.append(
                        f"phase1 candidate_count={candidate_count} snapshot {index}: raw fixed sums must be uint32"
                    )
                    continue
                derived_mean = [
                    fixed_sum / (raw_sample_count * fixed_scale) for fixed_sum in fixed_sums
                ]
                if any(
                    not math.isclose(
                        float(raw_mean[channel]),
                        derived_mean[channel],
                        rel_tol=0.0,
                        abs_tol=1e-12,
                    )
                    for channel in range(3)
                ):
                    failures.append(
                        f"phase1 candidate_count={candidate_count} snapshot {index}: raw_hdr_mean_rgb is inconsistent with fixed sums and sample count"
                    )
    if scenario == "phase2_temporal":
        failures.extend(
            validate_phase2_counter_semantics(snapshots, phase2_configuration or {})
        )
    return failures


def validate_phase2_counter_semantics(
    snapshots: list[dict[str, Any]], configuration: dict[str, Any]
) -> list[str]:
    failures: list[str] = []
    robust_coverage = bool(configuration.get("robust_coverage", False))
    age_rejection_coverage = bool(configuration.get("age_rejection_coverage", False))
    age_test_maximum = safe_int(configuration.get("age_rejection_test_maximum"), -1)
    allowed_phase2_flags = {3, 7} if robust_coverage else {3}
    phase2_snapshots = [
        snapshot
        for snapshot in snapshots
        if safe_int(snapshot.get("algorithm_mode"), -1) == PHASE2_ALGORITHM_MODE
    ]

    def ordered_phase2_segment(segment: str) -> list[dict[str, Any]]:
        return sorted(
            [
                snapshot
                for snapshot in phase2_snapshots
                if str(snapshot.get("qa_segment", "")) == segment
            ],
            key=lambda snapshot: safe_int(snapshot.get("frame"), -1),
        )

    baseline_snapshots = [
        snapshot
        for snapshot in snapshots
        if safe_int(snapshot.get("algorithm_mode"), -1) == 1
        and snapshot.get("algorithm") == "phase1_fresh"
        and safe_int(snapshot.get("feature_flags"), -1) == 9
    ]
    unexpected_identities = sorted(
        {
            (
                safe_int(snapshot.get("feature_flags"), -1),
                safe_int(snapshot.get("algorithm_mode"), -1),
                str(snapshot.get("algorithm", "")),
            )
            for snapshot in snapshots
            if safe_int(snapshot.get("algorithm_mode"), -1) not in (1, PHASE2_ALGORITHM_MODE)
            or (
                safe_int(snapshot.get("algorithm_mode"), -1) == 1
                and (
                    snapshot.get("algorithm") != "phase1_fresh"
                    or safe_int(snapshot.get("feature_flags"), -1) != 9
                )
            )
            or (
                safe_int(snapshot.get("algorithm_mode"), -1) == PHASE2_ALGORITHM_MODE
                and (
                    snapshot.get("algorithm") != PHASE2_ALGORITHM_NAME
                    or safe_int(snapshot.get("feature_flags"), -1)
                    not in allowed_phase2_flags
                )
            )
        }
    )
    if unexpected_identities:
        failures.append(
            "Phase 2 observed unexpected (feature_flags, algorithm_mode, algorithm) identities: "
            + repr(unexpected_identities)
        )
    if not baseline_snapshots:
        failures.append("Phase 2 captured no Phase 1 N=2 fresh fixed-ray-budget snapshot")
    if not phase2_snapshots:
        failures.append("Phase 2 captured no algorithm_mode=3 temporal ReSTIR snapshot")

    for index, snapshot in enumerate(phase2_snapshots):
        for field in (
            "history_valid",
            "history_reset",
            "camera_cut",
            "taa_jitter_nonzero",
        ):
            if safe_int(snapshot.get(field), -1) not in (0, 1):
                failures.append(f"phase2 snapshot {index}: {field} must be 0 or 1")
        if safe_int(snapshot.get("history_generation"), 0) <= 0:
            failures.append(
                f"phase2 snapshot {index}: history_generation must be positive"
            )
        if (
            safe_int(snapshot.get("history_valid"), -1) == 1
            and safe_int(snapshot.get("history_reset"), -1) == 1
        ):
            failures.append(
                f"phase2 snapshot {index}: history cannot be valid and reset in the same frame"
            )
        if (
            safe_int(snapshot.get("camera_cut"), -1) == 1
            and safe_int(snapshot.get("history_reset"), -1) != 1
        ):
            failures.append(
                f"phase2 snapshot {index}: camera_cut must reset the history generation"
            )

    for index, snapshot in enumerate(baseline_snapshots):
        fresh = safe_int(snapshot.get("fresh_candidates"), -1)
        rays = safe_int(snapshot.get("hdda_rays"), -1)
        update_rays = safe_int(snapshot.get("sharc_update_rays"), -1)
        if fresh <= 0 or fresh + update_rays != rays or fresh % 2 != 0:
            failures.append(
                f"phase2 P1-N2 baseline snapshot {index}: fresh_candidates must be positive/even and fresh + SHARC update rays must equal hdda_rays"
            )
        for field in (
            "temporal_guided_candidates",
            "spatial_guided_candidates",
            *PHASE2_COUNTER_FIELDS,
        ):
            if safe_int(snapshot.get(field), -1) != 0:
                failures.append(f"phase2 P1-N2 baseline snapshot {index}: {field} must be zero")

    maximum_m = safe_int(configuration.get("maximum_output_m"), -1)
    maximum_age = safe_int(configuration.get("maximum_age"), -1)
    aggregate = {field: 0 for field in PHASE2_COUNTER_FIELDS}
    strict_snapshot_count = 0
    robust_snapshot_count = 0
    strict_clamp_total = 0
    robust_clamp_total = 0
    strict_final_fresh_flag_total = 0
    strict_final_history_flag_total = 0
    robust_final_fresh_flag_total = 0
    robust_final_history_flag_total = 0
    for index, snapshot in enumerate(phase2_snapshots):
        values = {field: safe_int(snapshot.get(field), -1) for field in PHASE2_COUNTER_FIELDS}
        for field, value in values.items():
            if value < 0 or value > 0xFFFFFFFF:
                failures.append(f"phase2 snapshot {index}: {field} must be uint32")
            else:
                aggregate[field] += value

        feature_flags = safe_int(snapshot.get("feature_flags"), -1)
        robust_snapshot = feature_flags == 7
        if robust_snapshot:
            robust_snapshot_count += 1
            robust_clamp_total += values["reservoir_robust_jacobian_clamp"]
            robust_final_fresh_flag_total += values["reservoir_robust_flag_final_fresh"]
            robust_final_history_flag_total += values["reservoir_robust_flag_final_history"]
            if not str(snapshot.get("qa_segment", "")).startswith(
                "phase2_temporal/robust_clamp"
            ):
                failures.append(
                    f"phase2 snapshot {index}: robust feature_flags=7 appeared outside the robust_clamp QA segments"
                )
        else:
            strict_snapshot_count += 1
            strict_clamp_total += values["reservoir_robust_jacobian_clamp"]
            strict_final_fresh_flag_total += values["reservoir_robust_flag_final_fresh"]
            strict_final_history_flag_total += values["reservoir_robust_flag_final_history"]

        history_is_valid = safe_int(snapshot.get("history_valid"), -1)
        if history_is_valid not in (0, 1):
            failures.append(f"phase2 snapshot {index}: history_valid must be zero or one")

        fresh = safe_int(snapshot.get("fresh_candidates"), -1)
        rays = safe_int(snapshot.get("hdda_rays"), -1)
        visibility_rays = values["reservoir_visibility_rays"]
        update_rays = safe_int(snapshot.get("sharc_update_rays"), -1)
        if fresh <= 0:
            failures.append(f"phase2 snapshot {index}: fresh_candidates must be positive")
        if rays != fresh + visibility_rays + update_rays:
            failures.append(
                f"phase2 snapshot {index}: hdda_rays must equal fresh_candidates + reservoir_visibility_rays + SHARC update rays"
            )
        for field in (
            "temporal_guided_candidates",
            "spatial_guided_candidates",
        ):
            if safe_int(snapshot.get(field), -1) != 0:
                failures.append(f"phase2 snapshot {index}: legacy {field} must be zero")

        fresh_total = values["reservoir_fresh_valid"] + values["reservoir_fresh_invalid"]
        final_total = values["reservoir_final_valid"] + values["reservoir_final_invalid"]
        valid_surfaces = values["reservoir_valid_surfaces"]
        if fresh_total != final_total:
            failures.append(
                f"phase2 snapshot {index}: fresh valid+invalid must equal final valid+invalid"
            )
        if valid_surfaces < 0 or valid_surfaces > final_total:
            failures.append(f"phase2 snapshot {index}: valid surface count is outside dispatch total")
        if values["reservoir_selected_fresh"] + values["reservoir_selected_history"] != valid_surfaces:
            failures.append(
                f"phase2 snapshot {index}: selected fresh+history must equal valid surfaces"
            )
        if values["reservoir_reject_no_history"] + values["reservoir_temporal_attempts"] != valid_surfaces:
            failures.append(
                f"phase2 snapshot {index}: no-history+temporal-attempts must equal valid surfaces"
            )
        if values["reservoir_temporal_accepted"] > values["reservoir_temporal_attempts"]:
            failures.append(f"phase2 snapshot {index}: temporal accepted exceeds attempts")

        invalid_surfaces = final_total - valid_surfaces
        attempted_owner_rejections = (
            values["reservoir_reject_reprojection_or_owner"] - invalid_surfaces
        )
        if attempted_owner_rejections < 0:
            failures.append(
                f"phase2 snapshot {index}: reprojection/owner rejects are below invalid-surface count"
            )
        elif values["reservoir_nonfinite"] == 0:
            classified_attempts = (
                values["reservoir_temporal_accepted"]
                + attempted_owner_rejections
                + values["reservoir_reject_generation_or_algorithm"]
                + values["reservoir_reject_endpoint_identity_or_version"]
                + values["reservoir_reject_visibility"]
                + values["reservoir_reject_jacobian"]
                + values["reservoir_reject_age"]
                + values["reservoir_zero_target_mass_only"]
            )
            if classified_attempts != values["reservoir_temporal_attempts"]:
                failures.append(
                    f"phase2 snapshot {index}: accepted plus classified rejects must conserve temporal attempts"
                )

        if values["reservoir_visibility_visible"] + values["reservoir_visibility_occluded"] != visibility_rays:
            failures.append(
                f"phase2 snapshot {index}: visibility visible+occluded must equal visibility rays"
            )
        if values["reservoir_visibility_occluded"] != values["reservoir_reject_visibility"]:
            failures.append(
                f"phase2 snapshot {index}: visibility occluded must equal visibility rejects"
            )
        if (
            values["reservoir_hit_reuse"]
            + values["reservoir_sky_reuse"]
            + values["reservoir_reject_jacobian"]
            != values["reservoir_visibility_visible"]
        ):
            failures.append(
                f"phase2 snapshot {index}: hit+sky reuse plus Jacobian rejects must equal visible streams"
            )
        if values["reservoir_nonfinite"] != 0:
            failures.append(f"phase2 snapshot {index}: reservoir_nonfinite must be zero")
        if values["reservoir_packing_invalid"] != 0:
            failures.append(f"phase2 snapshot {index}: reservoir_packing_invalid must be zero")
        if values["reservoir_robust_jacobian_clamp"] > values["reservoir_hit_reuse"]:
            failures.append(
                f"phase2 snapshot {index}: robust Jacobian clamps must be a subset of hit reuse"
            )
        if not robust_snapshot and values["reservoir_robust_jacobian_clamp"] != 0:
            failures.append(
                f"phase2 snapshot {index}: robust Jacobian clamp must be zero in strict-mode QA"
            )
        final_robust_flags = (
            values["reservoir_robust_flag_final_fresh"]
            + values["reservoir_robust_flag_final_history"]
        )
        if final_robust_flags > values["reservoir_final_valid"]:
            failures.append(
                f"phase2 snapshot {index}: final robust flags exceed final valid reservoirs"
            )
        if final_robust_flags > values["reservoir_robust_jacobian_clamp"]:
            failures.append(
                f"phase2 snapshot {index}: final robust flags exceed Jacobian clamp events"
            )
        if values["reservoir_robust_flag_final_fresh"] > values["reservoir_selected_fresh"]:
            failures.append(
                f"phase2 snapshot {index}: final robust fresh flags exceed fresh selections"
            )
        if values["reservoir_robust_flag_final_history"] > values["reservoir_selected_history"]:
            failures.append(
                f"phase2 snapshot {index}: final robust history flags exceed history selections"
            )
        if values["reservoir_zero_target_mass_only"] > values["reservoir_selected_fresh"]:
            failures.append(
                f"phase2 snapshot {index}: zero-target mass-only streams exceed fresh selections"
            )
        if not robust_snapshot and final_robust_flags != 0:
            failures.append(
                f"phase2 snapshot {index}: final reservoir retained a robust-clamped flag in strict mode"
            )
        if maximum_m <= 0 or values["reservoir_max_m"] > maximum_m:
            failures.append(
                f"phase2 snapshot {index}: reservoir_max_m exceeds configured N + effective M cap"
            )
        if maximum_age <= 0 or values["reservoir_max_age"] > maximum_age:
            failures.append(f"phase2 snapshot {index}: reservoir_max_age exceeds configured maximum")
        if values["reservoir_sum_m"] < values["reservoir_max_m"]:
            failures.append(f"phase2 snapshot {index}: reservoir_sum_m is below reservoir_max_m")

    for field in (
        "reservoir_temporal_accepted",
        "reservoir_reject_no_history",
        "reservoir_reject_reprojection_or_owner",
        "reservoir_reject_endpoint_identity_or_version",
        "reservoir_reject_visibility",
        "reservoir_visibility_rays",
        "reservoir_selected_history",
        "reservoir_m_cap_applied",
    ):
        if phase2_snapshots and aggregate[field] <= 0:
            failures.append(f"Phase 2 scenario did not exercise {field}")
    if robust_coverage:
        if strict_snapshot_count <= 0:
            failures.append("Phase 2 robust coverage captured no strict feature_flags=3 snapshot")
        if robust_snapshot_count <= 0:
            failures.append("Phase 2 robust coverage captured no feature_flags=7 snapshot")
        if robust_clamp_total <= 0:
            failures.append("Phase 2 robust coverage did not exercise a Jacobian clamp")
        if robust_final_fresh_flag_total <= 0:
            failures.append("Phase 2 robust coverage produced no final fresh-selected robust flag")
        if robust_final_history_flag_total <= 0:
            failures.append("Phase 2 robust coverage produced no final history-selected robust flag")
    if strict_clamp_total != 0:
        failures.append("Phase 2 strict snapshots accumulated a non-zero robust clamp count")
    if strict_final_fresh_flag_total != 0 or strict_final_history_flag_total != 0:
        failures.append("Phase 2 strict snapshots retained a final robust-clamped reservoir flag")
    age_test_snapshots = ordered_phase2_segment(
        "phase2_temporal/maximum_age_2_sample"
    )
    if age_rejection_coverage:
        if age_test_maximum != 2:
            failures.append("Phase 2 age-rejection coverage must use maximum_age=2")
        if len(age_test_snapshots) != 32:
            failures.append(
                f"Phase 2 age-rejection coverage captured {len(age_test_snapshots)} snapshots, expected exactly 32"
            )
        if sum(
            safe_int(snapshot.get("reservoir_reject_age"), 0)
            for snapshot in age_test_snapshots
        ) <= 0:
            failures.append("Phase 2 maximum_age=2 coverage did not exercise an age rejection")
        age_rejecting_snapshot_count = sum(
            int(safe_int(snapshot.get("reservoir_reject_age"), 0) > 0)
            for snapshot in age_test_snapshots
        )
        if age_rejecting_snapshot_count < 16:
            failures.append(
                "Phase 2 maximum_age=2 coverage exercised age rejection on fewer than half of its exact sample frames"
            )
        observed_age = max(
            (
                safe_int(snapshot.get("reservoir_max_age"), -1)
                for snapshot in age_test_snapshots
            ),
            default=-1,
        )
        if observed_age != age_test_maximum:
            failures.append(
                f"Phase 2 age-rejection coverage observed max age {observed_age}, expected exactly {age_test_maximum}"
            )
        if not any(
            safe_int(snapshot.get("history_valid"), -1) == 1
            and safe_int(snapshot.get("reservoir_selected_history"), 0) > 0
            for snapshot in age_test_snapshots
        ):
            failures.append(
                "Phase 2 maximum_age=2 coverage never retained live selected history"
            )
        for index, snapshot in enumerate(age_test_snapshots):
            if safe_int(snapshot.get("feature_flags"), -1) != 3:
                failures.append(
                    f"Phase 2 age-test snapshot {index} was not strict feature_flags=3"
                )
            if safe_int(snapshot.get("reservoir_max_age"), -1) > age_test_maximum:
                failures.append(
                    f"Phase 2 age-test snapshot {index} exceeded maximum_age={age_test_maximum}"
                )
    content_segments: dict[
        str, tuple[list[dict[str, Any]], list[dict[str, Any]]]
    ] = {}
    for label in ("blocker", "light", "sky"):
        baseline_items = ordered_phase2_segment(
            f"phase2_temporal/dynamic_{label}_baseline"
        )
        step_items = ordered_phase2_segment(f"phase2_temporal/dynamic_{label}_step")
        content_segments[label] = (baseline_items, step_items)
        if len(baseline_items) != 4 or len(step_items) != 128:
            failures.append(
                f"Phase 2 dynamic {label} captured {len(baseline_items)}/4 baseline and "
                f"{len(step_items)}/128 step counter snapshots"
            )
            continue

        # The GPU-submission tag is sampled into each callback, so these are the
        # actual last two baseline and first two changed-content frames.
        baseline_guarded = baseline_items[-2:]
        step_guarded = step_items[:2]
        for window_name, window in (
            ("baseline", baseline_guarded),
            ("step", step_guarded),
        ):
            frames = [safe_int(snapshot.get("frame"), -1) for snapshot in window]
            if len(frames) != 2 or frames[1] != frames[0] + 1:
                failures.append(
                    f"Phase 2 dynamic {label} {window_name} guard did not contain two consecutive GPU frames"
                )

        baseline_generations = {
            safe_int(snapshot.get("history_generation"), -1)
            for snapshot in baseline_guarded
        }
        step_generation_window = step_items
        step_generations = {
            safe_int(snapshot.get("history_generation"), -1)
            for snapshot in step_generation_window
        }
        if (
            len(baseline_generations) != 1
            or len(step_generations) != 1
            or baseline_generations != step_generations
            or next(iter(baseline_generations), -1) <= 0
        ):
            failures.append(
                f"Phase 2 dynamic {label} content step changed the history generation"
            )

        if any(
            safe_int(snapshot.get("history_valid"), -1) != 1
            or safe_int(snapshot.get("history_reset"), -1) != 0
            or safe_int(snapshot.get("camera_cut"), -1) != 0
            for snapshot in step_generation_window
        ):
            failures.append(
                f"Phase 2 dynamic {label} content step reset or invalidated history after the guarded boundary"
            )
        all_frames = [
            safe_int(snapshot.get("frame"), -1)
            for snapshot in baseline_items + step_items
        ]
        all_sequences = [
            safe_int(snapshot.get("history_sequence"), -1)
            for snapshot in baseline_items + step_items
        ]
        if any(current != previous + 1 for previous, current in zip(all_frames, all_frames[1:])):
            failures.append(
                f"Phase 2 dynamic {label} exact baseline/transition GPU frames were not contiguous"
            )
        if any(
            current != previous + 1
            for previous, current in zip(all_sequences, all_sequences[1:])
        ):
            failures.append(
                f"Phase 2 dynamic {label} exact baseline/transition history sequence was not contiguous"
            )

        for guarded_index, snapshot in enumerate(step_guarded):
            valid_surfaces = safe_int(snapshot.get("reservoir_valid_surfaces"), -1)
            live_history = (
                safe_int(snapshot.get("history_valid"), -1) == 1
                and safe_int(snapshot.get("history_reset"), -1) == 0
                and safe_int(snapshot.get("camera_cut"), -1) == 0
                and safe_int(snapshot.get("reservoir_temporal_attempts"), 0) > 0
                and safe_int(snapshot.get("reservoir_selected_history"), 0) > 0
                and safe_int(snapshot.get("reservoir_reject_no_history"), -1)
                < valid_surfaces
            )
            if not live_history:
                failures.append(
                    f"Phase 2 dynamic {label} guarded step snapshot {guarded_index} did not preserve live temporal history"
                )

    blocker_baseline_snapshots, blocker_snapshots = content_segments["blocker"]
    if len(blocker_baseline_snapshots) == 4 and len(blocker_snapshots) == 128:
        def blocker_rejections(items: list[dict[str, Any]]) -> int:
            return sum(
                safe_int(snapshot.get("reservoir_reject_reprojection_or_owner"), 0)
                + safe_int(
                    snapshot.get("reservoir_reject_endpoint_identity_or_version"), 0
                )
                for snapshot in items
            )

        baseline_rejections = blocker_rejections(blocker_baseline_snapshots[-2:])
        step_rejections = blocker_rejections(blocker_snapshots[:2])
        rejection_delta = step_rejections - baseline_rejections
        step_valid_surfaces = sum(
            safe_int(snapshot.get("reservoir_valid_surfaces"), 0)
            for snapshot in blocker_snapshots[:2]
        )
        rejection_ratio = (
            step_rejections / baseline_rejections
            if baseline_rejections > 0
            else math.inf
        )
        delta_per_valid_surface = (
            rejection_delta / step_valid_surfaces
            if step_valid_surfaces > 0
            else 0.0
        )
        if rejection_ratio < 1.1 or delta_per_valid_surface < 0.005:
            failures.append(
                "Phase 2 dynamic blocker did not produce a significant guarded owner/endpoint rejection increase"
            )

    taa_stationary_snapshots = ordered_phase2_segment(
        "phase2_temporal/taa_jitter_stationary"
    )
    taa_motion_snapshots = ordered_phase2_segment("phase2_temporal/taa_jitter_motion")
    taa_guarded = taa_stationary_snapshots + taa_motion_snapshots
    if len(taa_stationary_snapshots) != 16 or len(taa_motion_snapshots) != 16:
        failures.append(
            f"Phase 2 TAA captured {len(taa_stationary_snapshots)}/16 stationary and "
            f"{len(taa_motion_snapshots)}/16 motion GPU frames"
        )
    if not taa_guarded or any(
        safe_int(snapshot.get("taa_jitter_nonzero"), 0) != 1
        for snapshot in taa_guarded
    ):
        failures.append(
            "Phase 2 TAA did not deliver non-zero input jitter on every exact stationary/motion GPU frame"
        )
    if any(
        safe_int(snapshot.get("history_valid"), -1) != 1
        or safe_int(snapshot.get("history_reset"), -1) != 0
        or safe_int(snapshot.get("camera_cut"), -1) != 0
        or safe_int(snapshot.get("reservoir_selected_history"), 0) <= 0
        for snapshot in taa_guarded
    ):
        failures.append(
            "Phase 2 TAA lost live selected temporal history in an exact stationary/motion GPU frame"
        )
    taa_generations = {
        safe_int(snapshot.get("history_generation"), -1)
        for snapshot in taa_guarded
    }
    if len(taa_generations) != 1 or next(iter(taa_generations), -1) <= 0:
        failures.append("Phase 2 TAA stationary/motion window changed the history generation")
    taa_frames = [safe_int(snapshot.get("frame"), -1) for snapshot in taa_guarded]
    taa_sequences = [safe_int(snapshot.get("history_sequence"), -1) for snapshot in taa_guarded]
    if any(current != previous + 1 for previous, current in zip(taa_frames, taa_frames[1:])):
        failures.append("Phase 2 TAA stationary/motion GPU frames were not one exact contiguous window")
    if any(
        current != previous + 1
        for previous, current in zip(taa_sequences, taa_sequences[1:])
    ):
        failures.append("Phase 2 TAA stationary/motion history sequence was not contiguous")
    reset_specs = (
        ("phase2_temporal/toggle_temporal_on_first_frame", None),
        ("phase2_temporal/toggle_screen_probes_on_first_frame", None),
        ("phase2_temporal/update_once_resize", (384, 216)),
        ("phase2_temporal/taa_jitter_camera_cut", None),
    )
    for segment, dimensions in reset_specs:
        reset_snapshots = [
            snapshot
            for snapshot in ordered_phase2_segment(segment)
            if dimensions is None
            or (
                safe_int(snapshot.get("width"), -1) == dimensions[0]
                and safe_int(snapshot.get("height"), -1) == dimensions[1]
            )
        ]
        if len(reset_snapshots) != 1:
            failures.append(
                f"Phase 2 lifecycle reset emitted {len(reset_snapshots)} snapshots for {segment}, expected exactly one"
            )
            continue
        snapshot = reset_snapshots[0]
        if not (
            safe_int(snapshot.get("reservoir_reject_no_history"), -1)
            == safe_int(snapshot.get("reservoir_valid_surfaces"), -2)
            and safe_int(snapshot.get("reservoir_temporal_accepted"), -1) == 0
            and safe_int(snapshot.get("history_valid"), -1) == 0
            and safe_int(snapshot.get("history_reset"), -1) == 1
            and (
                segment != "phase2_temporal/taa_jitter_camera_cut"
                or (
                    safe_int(snapshot.get("camera_cut"), -1) == 1
                    and safe_int(snapshot.get("taa_jitter_nonzero"), -1) == 1
                )
            )
        ):
            failures.append(
                f"Phase 2 lifecycle reset metadata/counters did not prove a clean guarded reset for {segment}"
            )

    def viewport_segment(
        segment: str, width: int, height: int
    ) -> list[dict[str, Any]]:
        return [
            snapshot
            for snapshot in ordered_phase2_segment(segment)
            if safe_int(snapshot.get("width"), -1) == width
            and safe_int(snapshot.get("height"), -1) == height
        ]

    intermittent_first = viewport_segment(
        "phase2_temporal/update_once_first", 320, 180
    )
    intermittent_second = viewport_segment(
        "phase2_temporal/update_once_second_after_idle", 320, 180
    )
    intermittent_resize = viewport_segment(
        "phase2_temporal/update_once_resize", 384, 216
    )
    if not (
        len(intermittent_first) == 1
        and len(intermittent_second) == 1
        and len(intermittent_resize) == 1
    ):
        failures.append(
            "Phase 2 UPDATE_ONCE lifecycle must emit exactly one viewport-local snapshot for each update"
        )
    else:
        first = intermittent_first[0]
        second = intermittent_second[0]
        resized = intermittent_resize[0]
        first_generation = safe_int(first.get("history_generation"), -1)
        second_generation = safe_int(second.get("history_generation"), -2)
        resized_generation = safe_int(resized.get("history_generation"), -1)
        if not (
            safe_int(first.get("history_valid"), -1) == 0
            and safe_int(first.get("history_reset"), -1) == 1
            and safe_int(first.get("history_sequence"), -1) == 0
        ):
            failures.append(
                "Phase 2 UPDATE_ONCE first local frame did not start at reset sequence 0"
            )
        if not (
            second_generation == first_generation
            and safe_int(second.get("history_valid"), -1) == 1
            and safe_int(second.get("history_reset"), -1) == 0
            and safe_int(second.get("history_sequence"), -1) == 1
            and safe_int(second.get("reservoir_temporal_attempts"), 0) > 0
            and safe_int(second.get("reservoir_selected_history"), 0) > 0
        ):
            failures.append(
                "Phase 2 UPDATE_ONCE idle gap advanced or lost viewport-local temporal history"
            )
        if not (
            resized_generation > 0
            and resized_generation != second_generation
            and safe_int(resized.get("history_valid"), -1) == 0
            and safe_int(resized.get("history_reset"), -1) == 1
            and safe_int(resized.get("history_sequence"), -1) == 0
            and safe_int(resized.get("reservoir_temporal_accepted"), -1) == 0
        ):
            failures.append(
                "Phase 2 UPDATE_ONCE resize did not create a new local generation at sequence 0"
            )
    return failures


def summarize_phase2_counters(snapshots: list[dict[str, Any]]) -> dict[str, Any]:
    def median(values: list[int]) -> float:
        ordered = sorted(values)
        if not ordered:
            return math.nan
        middle = len(ordered) // 2
        if len(ordered) % 2:
            return float(ordered[middle])
        return (ordered[middle - 1] + ordered[middle]) * 0.5

    def phase2_segment(segment: str) -> list[dict[str, Any]]:
        return sorted(
            [
                snapshot
                for snapshot in snapshots
                if snapshot.get("qa_segment") == segment
                and safe_int(snapshot.get("algorithm_mode"), -1)
                == PHASE2_ALGORITHM_MODE
                and safe_int(snapshot.get("feature_flags"), -1) == 3
            ],
            key=lambda snapshot: safe_int(snapshot.get("frame"), -1),
        )

    def guarded_live_history_count(items: list[dict[str, Any]]) -> int:
        return sum(
            int(
                safe_int(item.get("history_valid"), -1) == 1
                and safe_int(item.get("history_reset"), -1) == 0
                and safe_int(item.get("camera_cut"), -1) == 0
                and safe_int(item.get("reservoir_temporal_attempts"), 0) > 0
                and safe_int(item.get("reservoir_selected_history"), 0) > 0
                and safe_int(item.get("reservoir_reject_no_history"), -1)
                < safe_int(item.get("reservoir_valid_surfaces"), -2)
            )
            for item in items[:2]
        )

    def guarded_generation_preserved(
        baseline_items: list[dict[str, Any]], step_items: list[dict[str, Any]]
    ) -> int:
        if len(baseline_items) != 4 or len(step_items) != 128:
            return 0
        generations = {
            safe_int(item.get("history_generation"), -1)
            for item in baseline_items[-2:] + step_items
        }
        return int(len(generations) == 1 and next(iter(generations), -1) > 0)

    def guarded_step_reset_count(items: list[dict[str, Any]]) -> int:
        return sum(
            int(
                safe_int(item.get("history_valid"), -1) != 1
                or safe_int(item.get("history_reset"), -1) != 0
                or safe_int(item.get("camera_cut"), -1) != 0
            )
            for item in items
        )

    baseline = [
        snapshot
        for snapshot in snapshots
        if snapshot.get("qa_segment") == "phase2_temporal/constant/p1_n2_sample"
        and safe_int(snapshot.get("algorithm_mode"), -1) == 1
        and safe_int(snapshot.get("feature_flags"), -1) == 9
    ]
    temporal = [
        snapshot
        for snapshot in snapshots
        if snapshot.get("qa_segment") == "phase2_temporal/constant/p2_n1_visibility_sample"
        and safe_int(snapshot.get("algorithm_mode"), -1) == PHASE2_ALGORITHM_MODE
        and safe_int(snapshot.get("feature_flags"), -1) == 3
    ]
    baseline_rays = median([safe_int(item.get("hdda_rays"), 0) for item in baseline])
    temporal_rays = median([safe_int(item.get("hdda_rays"), 0) for item in temporal])
    aggregates = {
        field: sum(safe_int(item.get(field), 0) for item in snapshots)
        for field in PHASE2_COUNTER_FIELDS
    }
    robust_snapshots = [
        snapshot
        for snapshot in snapshots
        if safe_int(snapshot.get("algorithm_mode"), -1) == PHASE2_ALGORITHM_MODE
        and safe_int(snapshot.get("feature_flags"), -1) == 7
    ]
    strict_snapshots = [
        snapshot
        for snapshot in snapshots
        if safe_int(snapshot.get("algorithm_mode"), -1) == PHASE2_ALGORITHM_MODE
        and safe_int(snapshot.get("feature_flags"), -1) == 3
    ]
    age_test_snapshots = phase2_segment("phase2_temporal/maximum_age_2_sample")
    blocker_baseline_snapshots = phase2_segment(
        "phase2_temporal/dynamic_blocker_baseline"
    )
    blocker_snapshots = phase2_segment("phase2_temporal/dynamic_blocker_step")
    light_baseline_snapshots = phase2_segment(
        "phase2_temporal/dynamic_light_baseline"
    )
    light_snapshots = phase2_segment("phase2_temporal/dynamic_light_step")
    sky_baseline_snapshots = phase2_segment(
        "phase2_temporal/dynamic_sky_baseline"
    )
    sky_snapshots = phase2_segment("phase2_temporal/dynamic_sky_step")
    taa_stationary_snapshots = phase2_segment("phase2_temporal/taa_jitter_stationary")
    taa_motion_snapshots = phase2_segment("phase2_temporal/taa_jitter_motion")
    taa_guarded_snapshots = taa_stationary_snapshots + taa_motion_snapshots
    taa_cut_snapshots = phase2_segment("phase2_temporal/taa_jitter_camera_cut")
    update_once_first_snapshots = [
        item
        for item in phase2_segment("phase2_temporal/update_once_first")
        if safe_int(item.get("width"), -1) == 320
        and safe_int(item.get("height"), -1) == 180
    ]
    update_once_second_snapshots = [
        item
        for item in phase2_segment(
            "phase2_temporal/update_once_second_after_idle"
        )
        if safe_int(item.get("width"), -1) == 320
        and safe_int(item.get("height"), -1) == 180
    ]
    update_once_resize_snapshots = [
        item
        for item in phase2_segment("phase2_temporal/update_once_resize")
        if safe_int(item.get("width"), -1) == 384
        and safe_int(item.get("height"), -1) == 216
    ]
    update_once_first = update_once_first_snapshots[0] if update_once_first_snapshots else {}
    update_once_second = update_once_second_snapshots[0] if update_once_second_snapshots else {}
    update_once_resize = update_once_resize_snapshots[0] if update_once_resize_snapshots else {}
    lifecycle_reset_snapshots: list[dict[str, Any]] = []
    for segment, dimensions in (
        ("phase2_temporal/toggle_temporal_on_first_frame", None),
        ("phase2_temporal/toggle_screen_probes_on_first_frame", None),
        ("phase2_temporal/update_once_resize", (384, 216)),
        ("phase2_temporal/taa_jitter_camera_cut", None),
    ):
        matching = sorted(
            [
            snapshot
            for snapshot in snapshots
            if snapshot.get("qa_segment") == segment
            and safe_int(snapshot.get("algorithm_mode"), -1) == PHASE2_ALGORITHM_MODE
            and (
                dimensions is None
                or (
                    safe_int(snapshot.get("width"), -1) == dimensions[0]
                    and safe_int(snapshot.get("height"), -1) == dimensions[1]
                )
            )
            ],
            key=lambda snapshot: safe_int(snapshot.get("frame"), -1),
        )
        if len(matching) == 1:
            lifecycle_reset_snapshots.append(matching[0])
    return {
        "status": "passed" if baseline and temporal else "failed",
        "baseline_snapshot_count": len(baseline),
        "temporal_snapshot_count": len(temporal),
        "phase1_n2_median_hdda_rays": baseline_rays,
        "phase2_n1_visibility_median_hdda_rays": temporal_rays,
        "phase2_to_phase1_ray_budget_ratio": (
            temporal_rays / baseline_rays
            if math.isfinite(baseline_rays) and baseline_rays > 0.0
            else math.nan
        ),
        "strict_snapshot_count": len(strict_snapshots),
        "robust_snapshot_count": len(robust_snapshots),
        "strict_jacobian_clamp_total": sum(
            safe_int(item.get("reservoir_robust_jacobian_clamp"), 0)
            for item in strict_snapshots
        ),
        "robust_jacobian_clamp_total": sum(
            safe_int(item.get("reservoir_robust_jacobian_clamp"), 0)
            for item in robust_snapshots
        ),
        "strict_robust_flag_final_fresh_total": sum(
            safe_int(item.get("reservoir_robust_flag_final_fresh"), 0)
            for item in strict_snapshots
        ),
        "strict_robust_flag_final_history_total": sum(
            safe_int(item.get("reservoir_robust_flag_final_history"), 0)
            for item in strict_snapshots
        ),
        "robust_flag_final_fresh_total": sum(
            safe_int(item.get("reservoir_robust_flag_final_fresh"), 0)
            for item in robust_snapshots
        ),
        "robust_flag_final_history_total": sum(
            safe_int(item.get("reservoir_robust_flag_final_history"), 0)
            for item in robust_snapshots
        ),
        "age_test_snapshot_count": len(age_test_snapshots),
        "age_test_reject_total": sum(
            safe_int(item.get("reservoir_reject_age"), 0)
            for item in age_test_snapshots
        ),
        "age_test_reject_snapshot_count": sum(
            int(safe_int(item.get("reservoir_reject_age"), 0) > 0)
            for item in age_test_snapshots
        ),
        "age_test_observed_max_age": max(
            (safe_int(item.get("reservoir_max_age"), 0) for item in age_test_snapshots),
            default=0,
        ),
        "age_test_live_history_snapshot_count": sum(
            int(
                safe_int(item.get("history_valid"), -1) == 1
                and safe_int(item.get("reservoir_selected_history"), 0) > 0
            )
            for item in age_test_snapshots
        ),
        "dynamic_blocker_baseline_snapshot_count": len(blocker_baseline_snapshots),
        "dynamic_blocker_step_snapshot_count": len(blocker_snapshots),
        "dynamic_blocker_guarded_baseline_rejection_total": sum(
            safe_int(item.get("reservoir_reject_reprojection_or_owner"), 0)
            + safe_int(item.get("reservoir_reject_endpoint_identity_or_version"), 0)
            for item in blocker_baseline_snapshots[-2:]
        ),
        "dynamic_blocker_guarded_step_rejection_total": sum(
            safe_int(item.get("reservoir_reject_reprojection_or_owner"), 0)
            + safe_int(item.get("reservoir_reject_endpoint_identity_or_version"), 0)
            for item in blocker_snapshots[:2]
        ),
        "dynamic_blocker_guarded_two_frame_rejection_delta": sum(
            safe_int(item.get("reservoir_reject_reprojection_or_owner"), 0)
            + safe_int(item.get("reservoir_reject_endpoint_identity_or_version"), 0)
            for item in blocker_snapshots[:2]
        )
        - sum(
            safe_int(item.get("reservoir_reject_reprojection_or_owner"), 0)
            + safe_int(item.get("reservoir_reject_endpoint_identity_or_version"), 0)
            for item in blocker_baseline_snapshots[-2:]
        ),
        "dynamic_blocker_guarded_rejection_ratio": (
            sum(
                safe_int(item.get("reservoir_reject_reprojection_or_owner"), 0)
                + safe_int(item.get("reservoir_reject_endpoint_identity_or_version"), 0)
                for item in blocker_snapshots[:2]
            )
            / max(
                sum(
                    safe_int(item.get("reservoir_reject_reprojection_or_owner"), 0)
                    + safe_int(item.get("reservoir_reject_endpoint_identity_or_version"), 0)
                    for item in blocker_baseline_snapshots[-2:]
                ),
                1,
            )
        ),
        "dynamic_blocker_guarded_rejection_delta_per_valid_surface": (
            (
                sum(
                    safe_int(item.get("reservoir_reject_reprojection_or_owner"), 0)
                    + safe_int(item.get("reservoir_reject_endpoint_identity_or_version"), 0)
                    for item in blocker_snapshots[:2]
                )
                - sum(
                    safe_int(item.get("reservoir_reject_reprojection_or_owner"), 0)
                    + safe_int(item.get("reservoir_reject_endpoint_identity_or_version"), 0)
                    for item in blocker_baseline_snapshots[-2:]
                )
            )
            / max(
                sum(
                    safe_int(item.get("reservoir_valid_surfaces"), 0)
                    for item in blocker_snapshots[:2]
                ),
                1,
            )
        ),
        "dynamic_blocker_guarded_live_history_count": guarded_live_history_count(
            blocker_snapshots
        ),
        "dynamic_blocker_generation_preserved": guarded_generation_preserved(
            blocker_baseline_snapshots, blocker_snapshots
        ),
        "dynamic_blocker_step_reset_count": guarded_step_reset_count(
            blocker_snapshots
        ),
        "dynamic_light_baseline_snapshot_count": len(light_baseline_snapshots),
        "dynamic_light_step_snapshot_count": len(light_snapshots),
        "dynamic_light_guarded_live_history_count": guarded_live_history_count(
            light_snapshots
        ),
        "dynamic_light_generation_preserved": guarded_generation_preserved(
            light_baseline_snapshots, light_snapshots
        ),
        "dynamic_light_step_reset_count": guarded_step_reset_count(light_snapshots),
        "dynamic_sky_baseline_snapshot_count": len(sky_baseline_snapshots),
        "dynamic_sky_step_snapshot_count": len(sky_snapshots),
        "dynamic_sky_guarded_live_history_count": guarded_live_history_count(
            sky_snapshots
        ),
        "dynamic_sky_generation_preserved": guarded_generation_preserved(
            sky_baseline_snapshots, sky_snapshots
        ),
        "dynamic_sky_step_reset_count": guarded_step_reset_count(sky_snapshots),
        "taa_jitter_stationary_snapshot_count": len(taa_stationary_snapshots),
        "taa_jitter_motion_snapshot_count": len(taa_motion_snapshots),
        "taa_jitter_guarded_snapshot_count": len(taa_guarded_snapshots),
        "taa_jitter_nonzero_snapshot_count": sum(
            int(safe_int(item.get("taa_jitter_nonzero"), 0) == 1)
            for item in taa_guarded_snapshots
        ),
        "taa_jitter_guarded_nonzero_ratio": (
            sum(
                int(safe_int(item.get("taa_jitter_nonzero"), 0) == 1)
                for item in taa_guarded_snapshots
            )
            / max(len(taa_guarded_snapshots), 1)
        ),
        "taa_jitter_guarded_live_history_ratio": (
            sum(
                int(
                    safe_int(item.get("history_valid"), -1) == 1
                    and safe_int(item.get("history_reset"), -1) == 0
                    and safe_int(item.get("reservoir_selected_history"), 0) > 0
                )
                for item in taa_guarded_snapshots
            )
            / max(len(taa_guarded_snapshots), 1)
        ),
        "taa_jitter_generation_preserved": int(
            bool(taa_guarded_snapshots)
            and len(
                {
                    safe_int(item.get("history_generation"), -1)
                    for item in taa_guarded_snapshots
                }
            )
            == 1
        ),
        "taa_cut_metadata_reset_count": sum(
            int(
                safe_int(item.get("history_valid"), -1) == 0
                and safe_int(item.get("history_reset"), -1) == 1
                and safe_int(item.get("camera_cut"), -1) == 1
                and safe_int(item.get("taa_jitter_nonzero"), -1) == 1
            )
            for item in taa_cut_snapshots
        ),
        "update_once_first_snapshot_count": len(update_once_first_snapshots),
        "update_once_second_snapshot_count": len(update_once_second_snapshots),
        "update_once_resize_snapshot_count": len(update_once_resize_snapshots),
        "update_once_first_sequence": safe_int(
            update_once_first.get("history_sequence"), -1
        ),
        "update_once_second_sequence": safe_int(
            update_once_second.get("history_sequence"), -1
        ),
        "update_once_idle_sequence_delta": safe_int(
            update_once_second.get("history_sequence"), -1
        )
        - safe_int(update_once_first.get("history_sequence"), -1),
        "update_once_generation_preserved_across_idle": int(
            bool(update_once_first and update_once_second)
            and safe_int(update_once_first.get("history_generation"), -1)
            == safe_int(update_once_second.get("history_generation"), -2)
        ),
        "update_once_second_live_history": int(
            bool(update_once_second)
            and safe_int(update_once_second.get("history_valid"), -1) == 1
            and safe_int(update_once_second.get("history_reset"), -1) == 0
            and safe_int(update_once_second.get("reservoir_selected_history"), 0) > 0
        ),
        "update_once_resize_sequence": safe_int(
            update_once_resize.get("history_sequence"), -1
        ),
        "update_once_resize_generation_changed": int(
            bool(update_once_second and update_once_resize)
            and safe_int(update_once_resize.get("history_generation"), -1)
            != safe_int(update_once_second.get("history_generation"), -1)
        ),
        "lifecycle_reset_snapshot_count": len(lifecycle_reset_snapshots),
        "lifecycle_reset_zero_history_accept_count": sum(
            int(
                safe_int(item.get("reservoir_reject_no_history"), -1)
                == safe_int(item.get("reservoir_valid_surfaces"), -2)
                and safe_int(item.get("reservoir_temporal_accepted"), -1) == 0
                and safe_int(item.get("history_valid"), -1) == 0
                and safe_int(item.get("history_reset"), -1) == 1
            )
            for item in lifecycle_reset_snapshots
        ),
        "aggregates": aggregates,
        "contract": "steady constant scene; P1 N=2 fresh versus P2 N=1 fresh plus explicit visibility",
    }


def phase2_digest_reservoir_words(words: list[int]) -> list[int]:
    """Independent validator copy of the four-lane shader digest."""

    if len(words) != 26:
        raise ValueError(f"expected 26 reservoir words, got {len(words)}")
    digest = [0x811C9DC5, 0x9E3779B9, 0x243F6A88, 0xB7E15162]
    primes = [0x01000193, 0x85EBCA6B, 0xC2B2AE35, 0x27D4EB2F]
    for index, word in enumerate(words):
        mixed_word = (word + ((index * 0x9E3779B9) & 0xFFFFFFFF)) & 0xFFFFFFFF
        digest = [
            ((lane ^ mixed_word) * prime) & 0xFFFFFFFF
            for lane, prime in zip(digest, primes)
        ]
    digest = [(lane ^ (lane >> 16)) & 0xFFFFFFFF for lane in digest]
    digest = [(lane * 0x85EBCA6B) & 0xFFFFFFFF for lane in digest]
    digest = [(lane ^ (lane >> 13)) & 0xFFFFFFFF for lane in digest]
    digest = [(lane * 0xC2B2AE35) & 0xFFFFFFFF for lane in digest]
    return [(lane ^ (lane >> 16)) & 0xFFFFFFFF for lane in digest]


def parse_phase2_cpu_gpu_golden(cpu_reference: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    failures: list[str] = []
    raw_vector = cpu_reference.get("gpu_golden_vectors", {}).get("fixed_weighted_update", {})
    vector = raw_vector if isinstance(raw_vector, dict) else {}
    raw_words = vector.get("reservoir_abi_words", [])
    words: list[int] = []
    if isinstance(raw_words, list):
        for index, value in enumerate(raw_words):
            try:
                parsed = int(value, 16) if isinstance(value, str) else int(value)
            except (TypeError, ValueError):
                failures.append(f"CPU GPU-golden reservoir word {index} is not uint32")
                continue
            if parsed < 0 or parsed > 0xFFFFFFFF:
                failures.append(f"CPU GPU-golden reservoir word {index} is outside uint32")
            words.append(parsed & 0xFFFFFFFF)
    else:
        failures.append("CPU GPU-golden reservoir words are not an array")
    if safe_int(vector.get("reservoir_abi_word_count"), -1) != 26 or len(words) != 26:
        failures.append("CPU GPU-golden reservoir does not contain the complete 26-word ABI")
    expected_round_trip = (
        "phase2_store_current -> memoryBarrierImage -> phase2_load_current -> repack current seven-atlas ABI"
    )
    if vector.get("gpu_round_trip") != expected_round_trip:
        failures.append("CPU GPU-golden does not declare the current seven-atlas store/load round-trip")
    if vector.get("previous_descriptor_bitwise_covered") is not False:
        failures.append("CPU GPU-golden must explicitly exclude previous sampled descriptors from bitwise coverage")
    compressed = vector.get("compressed_temporal", {})
    if not isinstance(compressed, dict) or not (
        safe_int(compressed.get("history_M"), -1) == 9
        and safe_int(compressed.get("history_M_cap"), -1) == 4
        and safe_int(compressed.get("effective_history_M"), -1) == 4
        and safe_int(compressed.get("merged_M"), -1) == 7
        and compressed.get("visibility") is True
        and compressed.get("selected_history") is True
    ):
        failures.append("CPU GPU-golden does not exercise the fixed visible, M-capped compressed history stream")
    zero_target_compressed = vector.get(
        "zero_current_target_compressed_temporal", {}
    )
    if not isinstance(zero_target_compressed, dict) or not (
        safe_int(zero_target_compressed.get("history_M"), -1) == 9
        and safe_int(zero_target_compressed.get("history_M_cap"), -1) == 4
        and safe_int(zero_target_compressed.get("effective_history_M"), -1) == 4
        and safe_int(zero_target_compressed.get("merged_M"), -1) == 7
        and zero_target_compressed.get("current_target_bits") == "0x00000000"
        and zero_target_compressed.get("history_mass_bits") == "0x00000000"
        and zero_target_compressed.get("selected_history") is False
        and safe_int(zero_target_compressed.get("digest_generation"), -1) > 0
    ):
        failures.append(
            "CPU GPU-golden does not exercise zero-current-target M preservation"
        )

    raw_digest = vector.get("reservoir_gpu_digest", [])
    digest = [exact_int(value) for value in raw_digest] if isinstance(raw_digest, list) else []
    if (
        safe_int(vector.get("reservoir_gpu_digest_schema_version"), -1)
        != PHASE2_GPU_GOLDEN_DIGEST_SCHEMA_VERSION
        or len(digest) != 4
        or any(value is None or value < 0 or value > 0xFFFFFFFF for value in digest)
    ):
        failures.append(
            f"CPU GPU-golden digest is not a schema-{PHASE2_GPU_GOLDEN_DIGEST_SCHEMA_VERSION} "
            "four-word uint32 vector"
        )
    expected_digest = [int(value) for value in digest if value is not None]
    if len(words) == 26 and len(expected_digest) == 4:
        recomputed = phase2_digest_reservoir_words(words)
        if recomputed != expected_digest:
            failures.append("CPU GPU-golden digest does not match its complete 26-word reservoir ABI")

    return (
        {
            "status": "passed" if not failures else "failed",
            "schema_version": vector.get("reservoir_gpu_digest_schema_version"),
            "word_count": len(words),
            "words": raw_words,
            "digest": expected_digest,
            "round_trip": vector.get("gpu_round_trip"),
            "previous_descriptor_bitwise_covered": vector.get(
                "previous_descriptor_bitwise_covered"
            ),
            "compressed_temporal": compressed,
            "zero_current_target_compressed_temporal": zero_target_compressed,
            "failures": failures,
        },
        failures,
    )


def validate_phase2_gpu_golden_snapshots(
    snapshots: list[dict[str, Any]], expected_digest: list[int]
) -> tuple[dict[str, Any], list[str]]:
    failures: list[str] = []
    phase2_snapshots = [
        snapshot
        for snapshot in snapshots
        if safe_int(snapshot.get("algorithm_mode"), -1) == PHASE2_ALGORITHM_MODE
    ]
    observed: list[list[int]] = []
    mismatch_count = 0
    zero_target_branch_golden_count = 0
    if len(expected_digest) != 4:
        failures.append("validated CPU GPU-golden digest is unavailable")
    if not phase2_snapshots:
        failures.append("no Phase 2 snapshot was available for GPU reservoir conformance")
    for index, snapshot in enumerate(phase2_snapshots):
        if safe_int(snapshot.get("reservoir_gpu_zero_target_branch_golden"), -1) != 1:
            failures.append(
                f"Phase 2 snapshot {index} failed the GPU zero-target production-branch fixture"
            )
        else:
            zero_target_branch_golden_count += 1
        raw_digest = snapshot.get("reservoir_gpu_golden_digest")
        values = [exact_int(value) for value in raw_digest] if isinstance(raw_digest, list) else []
        if (
            safe_int(snapshot.get("reservoir_gpu_golden_schema_version"), -1)
            != PHASE2_GPU_GOLDEN_DIGEST_SCHEMA_VERSION
            or safe_int(snapshot.get("reservoir_gpu_golden_word_count"), -1) != 26
            or len(values) != 4
            or any(value is None or value < 0 or value > 0xFFFFFFFF for value in values)
        ):
            failures.append(
                f"Phase 2 snapshot {index} has no valid schema-"
                f"{PHASE2_GPU_GOLDEN_DIGEST_SCHEMA_VERSION} GPU reservoir digest"
            )
            continue
        digest = [int(value) for value in values if value is not None]
        observed.append(digest)
        if len(expected_digest) == 4 and digest != expected_digest:
            mismatch_count += 1
            failures.append(
                f"Phase 2 snapshot {index} GPU reservoir digest {digest!r} != CPU golden {expected_digest!r}"
            )
    unique_observed = sorted({tuple(digest) for digest in observed})
    if observed and len(unique_observed) != 1:
        failures.append("Phase 2 GPU reservoir digest changed across deterministic snapshots")
    return (
        {
            "status": "passed" if not failures else "failed",
            "contract": "real Vulkan shader shared fresh/temporal compressed-stream math plus current seven-atlas store/load/repack round-trip",
            "scope_limitation": "previous sampled-image descriptors are exercised by rendering but are not bitwise read back by this golden",
            "schema_version": PHASE2_GPU_GOLDEN_DIGEST_SCHEMA_VERSION,
            "expected_cpu_digest": expected_digest,
            "phase2_snapshot_count": len(phase2_snapshots),
            "valid_digest_count": len(observed),
            "unique_observed_digests": [list(value) for value in unique_observed],
            "mismatch_count": mismatch_count,
            "zero_target_branch_golden_count": zero_target_branch_golden_count,
            "failures": failures,
        },
        failures,
    )


def validate_phase2_dynamic_convergence(
    result: dict[str, Any],
) -> tuple[dict[str, Any], list[str]]:
    """Recompute every derived dynamic half-life gate from emitted samples.

    The runner is responsible for image capture and primitive MAE measurements;
    the post-exit validator must not trust its derived half-life booleans or gate
    scalars. Requiring the complete residual and stable-noise sample populations
    also prevents a shortened diagnostic run from masquerading as acceptance.
    """

    failures: list[str] = []
    scenarios = result.get("scenarios", {})
    phase2 = scenarios.get("phase2_temporal", {}) if isinstance(scenarios, dict) else {}
    dynamic = phase2.get("dynamic_steps", {}) if isinstance(phase2, dict) else {}
    gate_metrics = phase2.get("gate_metrics", {}) if isinstance(phase2, dict) else {}
    dynamic_checks = dynamic.get("checks", {}) if isinstance(dynamic, dict) else {}
    phase2_checks = phase2.get("checks", {}) if isinstance(phase2, dict) else {}
    summaries: dict[str, Any] = {}
    derived_reached: list[bool] = []
    derived_signals: list[float] = []

    for key, gate_prefix in (
        ("dynamic_blocker", "dynamic_blocker"),
        ("dynamic_light", "dynamic_light"),
        ("dynamic_sky", "dynamic_sky"),
    ):
        raw_case = dynamic.get(key, {}) if isinstance(dynamic, dict) else {}
        case = raw_case if isinstance(raw_case, dict) else {}
        case_failures: list[str] = []

        def check_float(label: str, observed: Any, expected: float) -> None:
            value = safe_float(observed)
            if not math.isfinite(value) or not math.isclose(
                value, expected, rel_tol=1e-9, abs_tol=1e-12
            ):
                case_failures.append(
                    f"{label} did not match the post-exit recomputation"
                )

        if safe_int(case.get("transition_frame_count"), -1) != 128:
            case_failures.append("transition_frame_count must be exactly 128")
        raw_residuals = case.get("residual_curve_normalized", [])
        reported_residuals = (
            [safe_float(value) for value in raw_residuals]
            if isinstance(raw_residuals, list)
            else []
        )
        if len(reported_residuals) != 128 or any(
            not math.isfinite(value) or value < 0.0 for value in reported_residuals
        ):
            case_failures.append("residual_curve_normalized must contain 128 finite non-negative samples")
        raw_transition_samples = case.get("transition_samples_mean_abs_luma", [])
        transition_samples = (
            [safe_float(value) for value in raw_transition_samples]
            if isinstance(raw_transition_samples, list)
            else []
        )
        if len(transition_samples) != 128 or any(
            not math.isfinite(value) or value < 0.0 for value in transition_samples
        ):
            case_failures.append(
                "transition_samples_mean_abs_luma must contain 128 finite non-negative samples"
            )

        raw_floor = case.get("stable_reference_noise_floor", {})
        floor = raw_floor if isinstance(raw_floor, dict) else {}
        raw_noise_samples = floor.get("samples_mean_abs_luma", [])
        noise_samples = (
            [safe_float(value) for value in raw_noise_samples]
            if isinstance(raw_noise_samples, list)
            else []
        )
        if safe_int(floor.get("sample_count"), -1) != 31 or len(noise_samples) != 31:
            case_failures.append("stable noise floor must contain exactly 31 samples")
        if any(not math.isfinite(value) or value < 0.0 for value in noise_samples):
            case_failures.append("stable noise samples must be finite and non-negative")

        stable_mean = safe_float(case.get("stable_mean_luma"))
        if not math.isfinite(stable_mean) or stable_mean <= 0.0:
            case_failures.append("stable_mean_luma must be finite and positive")

        canonical: dict[str, Any] = {
            "transition_frame_count": len(transition_samples),
            "stable_noise_sample_count": len(noise_samples),
        }
        if not case_failures:
            sorted_noise = sorted(noise_samples)
            median_noise = sorted_noise[len(sorted_noise) // 2]
            noise_normalized = median_noise / stable_mean
            residuals = [
                max(value - median_noise, 0.0) / stable_mean
                for value in transition_samples
            ]
            initial_peak_index = max(range(4), key=lambda index: residuals[index])
            initial_residual = residuals[initial_peak_index]
            half_threshold = initial_residual * 0.5
            half_life_frames = (
                0 if initial_residual <= max(noise_normalized, 1e-9) else -1
            )
            if half_life_frames < 0:
                for index in range(initial_peak_index, len(residuals) - 2):
                    if all(value <= half_threshold for value in residuals[index : index + 3]):
                        half_life_frames = index + 1
                        break
            half_life_reached = half_life_frames >= 0
            final_residual = residuals[-1]
            residual_frame_2 = residuals[1]
            residual_frame_4 = residuals[3]
            residual_frame_8 = residuals[7]

            step = case.get("step_signal", {})
            first = case.get("first_after_to_stable", {})
            step_mae = safe_float(step.get("mean_abs_luma")) if isinstance(step, dict) else math.nan
            first_mae = safe_float(first.get("mean_abs_luma")) if isinstance(first, dict) else math.nan
            if not math.isfinite(step_mae) or step_mae < 0.0:
                case_failures.append("step_signal.mean_abs_luma must be finite and non-negative")
                step_normalized = math.nan
            else:
                step_normalized = step_mae / stable_mean
            noise_to_step_ratio = (
                noise_normalized / step_normalized
                if math.isfinite(step_normalized) and step_normalized > 0.0
                else math.inf
            )
            if not math.isfinite(first_mae) or first_mae < 0.0:
                case_failures.append("first_after_to_stable.mean_abs_luma must be finite and non-negative")
                ghost_normalized = math.nan
            else:
                ghost_normalized = max(first_mae - median_noise, 0.0) / stable_mean

            canonical.update(
                {
                    "stable_noise_median_mean_abs_luma": median_noise,
                    "stable_noise_normalized": noise_normalized,
                    "step_signal_normalized": step_normalized,
                    "noise_to_step_ratio": noise_to_step_ratio,
                    "initial_residual_normalized": initial_residual,
                    "initial_peak_frame": initial_peak_index + 1,
                    "half_amplitude_threshold_normalized": half_threshold,
                    "half_life_reached": half_life_reached,
                    "half_life_frames": half_life_frames,
                    "residual_frame_2_normalized": residual_frame_2,
                    "residual_frame_4_normalized": residual_frame_4,
                    "residual_frame_8_normalized": residual_frame_8,
                    "final_residual_normalized": final_residual,
                    "ghost_proxy_normalized": ghost_normalized,
                }
            )

            check_float(
                f"{key}.stable_reference_noise_floor.median_mean_abs_luma",
                floor.get("median_mean_abs_luma"),
                median_noise,
            )
            check_float(
                f"{key}.stable_reference_noise_floor.normalized",
                floor.get("normalized"),
                noise_normalized,
            )
            if any(
                not math.isclose(observed, expected, rel_tol=1e-9, abs_tol=1e-12)
                for observed, expected in zip(reported_residuals, residuals)
            ):
                case_failures.append(
                    "residual_curve_normalized did not match the raw transition samples"
                )
            for field, expected in (
                ("step_signal_normalized", step_normalized),
                ("initial_residual_normalized", initial_residual),
                ("half_amplitude_threshold_normalized", half_threshold),
                ("residual_frame_2_normalized", residual_frame_2),
                ("residual_frame_4_normalized", residual_frame_4),
                ("residual_frame_8_normalized", residual_frame_8),
                ("final_residual_normalized", final_residual),
                ("ghost_proxy_normalized", ghost_normalized),
            ):
                check_float(f"{key}.{field}", case.get(field), expected)
            if safe_int(case.get("initial_peak_frame"), -1) != initial_peak_index + 1:
                case_failures.append("initial_peak_frame did not match frames 1..4")
            if math.isfinite(first_mae) and not math.isclose(
                transition_samples[0], first_mae, rel_tol=1e-9, abs_tol=1e-12
            ):
                case_failures.append(
                    "first transition sample did not match first_after_to_stable"
                )
            if case.get("half_life_reached") is not half_life_reached:
                case_failures.append("half_life_reached did not match the residual curve")
            if safe_int(case.get("half_life_frames"), -2) != half_life_frames:
                case_failures.append("half_life_frames did not match the residual curve")
            for suffix, expected in (
                ("step_signal_normalized", step_normalized),
                ("ghost_half_life_frames", float(half_life_frames)),
                ("ghost_proxy_normalized", ghost_normalized),
            ):
                check_float(
                    f"gate_metrics.{gate_prefix}_{suffix}",
                    gate_metrics.get(f"{gate_prefix}_{suffix}")
                    if isinstance(gate_metrics, dict)
                    else None,
                    expected,
                )
            residual_gate_suffix = (
                "residual_frame_4_normalized"
                if key == "dynamic_blocker"
                else "residual_frame_8_normalized"
            )
            residual_gate_value = (
                residual_frame_4 if key == "dynamic_blocker" else residual_frame_8
            )
            check_float(
                f"gate_metrics.{gate_prefix}_{residual_gate_suffix}",
                gate_metrics.get(f"{gate_prefix}_{residual_gate_suffix}")
                if isinstance(gate_metrics, dict)
                else None,
                residual_gate_value,
            )
            check_float(
                f"gate_metrics.{gate_prefix}_stable_noise_normalized",
                gate_metrics.get(f"{gate_prefix}_stable_noise_normalized")
                if isinstance(gate_metrics, dict)
                else None,
                noise_normalized,
            )
            check_float(
                f"gate_metrics.{gate_prefix}_noise_to_step_ratio",
                gate_metrics.get(f"{gate_prefix}_noise_to_step_ratio")
                if isinstance(gate_metrics, dict)
                else None,
                noise_to_step_ratio,
            )
            derived_reached.append(half_life_reached)
            derived_signals.append(step_normalized)

        summaries[key] = {
            "status": "passed" if not case_failures else "failed",
            "canonical": canonical,
            "failures": case_failures,
        }
        failures.extend(f"{key}: {failure}" for failure in case_failures)

    all_reached = len(derived_reached) == 3 and all(derived_reached)
    all_measurable = (
        len(derived_signals) == 3
        and all(math.isfinite(value) and value > 0.0 for value in derived_signals)
    )
    for label, observed, expected in (
        (
            "dynamic_steps.checks.all_dynamic_ghost_half_lives_reached",
            dynamic_checks.get("all_dynamic_ghost_half_lives_reached")
            if isinstance(dynamic_checks, dict)
            else None,
            all_reached,
        ),
        (
            "dynamic_steps.checks.all_dynamic_steps_have_measurable_signal",
            dynamic_checks.get("all_dynamic_steps_have_measurable_signal")
            if isinstance(dynamic_checks, dict)
            else None,
            all_measurable,
        ),
        (
            "phase2.checks.dynamic_ghost_half_lives_reached",
            phase2_checks.get("dynamic_ghost_half_lives_reached")
            if isinstance(phase2_checks, dict)
            else None,
            all_reached,
        ),
        (
            "phase2.checks.dynamic_steps_have_measurable_signal",
            phase2_checks.get("dynamic_steps_have_measurable_signal")
            if isinstance(phase2_checks, dict)
            else None,
            all_measurable,
        ),
    ):
        if observed is not expected:
            failures.append(f"{label} did not match the post-exit recomputation")

    return (
        {
            "status": "passed" if not failures else "failed",
        "contract": "recompute 128 residuals from raw transition MAE; subtract median of 31 later steady-state MAE samples; starting at the frames 1..4 peak, find the first three-sample run at or below half that peak",
            "cases": summaries,
            "all_half_lives_reached": all_reached,
            "all_steps_measurable": all_measurable,
            "failures": failures,
        },
        failures,
    )


def summarize_phase1_raw_hdr(snapshots: list[dict[str, Any]]) -> dict[str, Any]:
    analytic_constant = (0.18, 0.18, 0.18)
    # The colored sky shader is evaluated over a cosine distribution where
    # E[z^k] = 2/(k+2).
    analytic_colored = (
        0.04 + 0.28 * (2.0 / 3.0),
        0.06 + 0.14 * (2.0 / 4.0),
        0.02 + 0.24 * (2.0 / 5.0),
    )

    def relative_error(actual: list[float], expected: tuple[float, float, float]) -> float:
        return max(
            abs(actual[index] - expected[index]) / expected[index] for index in range(3)
        )

    def aggregate_rgb(items: list[dict[str, Any]]) -> tuple[list[float], int]:
        total_sample_count = sum(safe_int(item.get("raw_hdr_sample_count"), 0) for item in items)
        fixed_sums = [
            sum(safe_int(item.get(field), 0) for item in items)
            for field in ("raw_hdr_fixed_sum_r", "raw_hdr_fixed_sum_g", "raw_hdr_fixed_sum_b")
        ]
        return (
            [
                fixed_sum / (total_sample_count * PHASE1_RAW_FIXED_SCALE)
                for fixed_sum in fixed_sums
            ],
            total_sample_count,
        )

    def phase_coverage(items: list[dict[str, Any]]) -> int:
        union_words = [0] * 8
        for item in items:
            words = item.get("raw_hdr_lattice_phase_mask_words", [])
            if not isinstance(words, list) or len(words) != 8:
                continue
            for word_index, word in enumerate(words):
                union_words[word_index] |= safe_int(word, 0)
        return sum(word.bit_count() for word in union_words)

    reference_snapshots = [
        snapshot
        for snapshot in snapshots
        if safe_int(snapshot.get("algorithm_mode"), -1) == 2
        and snapshot.get("algorithm") == "phase1_reference"
        and safe_int(snapshot.get("feature_flags"), 0) == 1
        and safe_int(snapshot.get("raw_hdr_sample_count"), 0) > 0
        and safe_int(snapshot.get("raw_hdr_nonfinite_or_overflow"), -1) == 0
        and isinstance(snapshot.get("raw_hdr_mean_rgb"), list)
        and len(snapshot["raw_hdr_mean_rgb"]) == 3
        and snapshot.get("qa_segment") == "phase1_fresh/white_furnace_long_run"
    ]
    constant_candidates: list[dict[str, Any]] = []
    for snapshot in reference_snapshots:
        raw_mean = [float(channel) for channel in snapshot["raw_hdr_mean_rgb"]]
        if not all(math.isfinite(channel) for channel in raw_mean):
            continue
        constant_candidates.append(snapshot)

    constant_mean, constant_sample_count = (
        aggregate_rgb(constant_candidates) if constant_candidates else (None, 0)
    )
    constant_phase_coverage = phase_coverage(constant_candidates)
    constant_error = (
        relative_error(constant_mean, analytic_constant) if constant_mean else math.inf
    )

    colored_by_count: dict[str, Any] = {}
    colored_means: list[list[float]] = []
    colored_failures: list[str] = []
    for candidate_count in (1, 2, 4, 8):
        feature_flags = 1 + ((candidate_count - 1) << 3)
        matching = [
            snapshot
            for snapshot in snapshots
            if safe_int(snapshot.get("algorithm_mode"), -1) == 2
            and snapshot.get("algorithm") == "phase1_reference"
            and safe_int(snapshot.get("feature_flags"), 0) == feature_flags
            and safe_int(snapshot.get("raw_hdr_sample_count"), 0) > 0
            and safe_int(snapshot.get("raw_hdr_nonfinite_or_overflow"), -1) == 0
            and isinstance(snapshot.get("raw_hdr_mean_rgb"), list)
            and len(snapshot["raw_hdr_mean_rgb"]) == 3
            and str(snapshot.get("qa_segment", "")).startswith(
                f"phase1_fresh/candidates_{candidate_count}_"
            )
        ]
        if not matching:
            colored_failures.append(f"no colored-lobe raw HDR snapshot for candidate_count={candidate_count}")
            colored_by_count[str(candidate_count)] = {"snapshot_count": 0}
            continue
        raw_mean, raw_sample_count = aggregate_rgb(matching)
        raw_phase_coverage = phase_coverage(matching)
        error = relative_error(raw_mean, analytic_colored)
        if error >= 0.03:
            colored_failures.append(
                f"candidate_count={candidate_count} colored-lobe raw HDR error {error:.6g} >= 3%"
            )
        if raw_phase_coverage < 160:
            colored_failures.append(
                f"candidate_count={candidate_count} colored-lobe raw HDR covered only "
                f"{raw_phase_coverage}/256 lattice phases; expected at least 160"
            )
        colored_means.append(raw_mean)
        colored_by_count[str(candidate_count)] = {
            "snapshot_count": len(matching),
            "total_sample_count": raw_sample_count,
            "lattice_phase_coverage_count": raw_phase_coverage,
            "raw_hdr_mean_rgb": raw_mean,
            "maximum_channel_relative_error": error,
        }

    colored_pairwise_error = 0.0
    for first_index, first in enumerate(colored_means):
        for second in colored_means[first_index + 1 :]:
            colored_pairwise_error = max(
                colored_pairwise_error,
                max(
                    abs(first[channel] - second[channel])
                    / max((first[channel] + second[channel]) * 0.5, 1e-12)
                    for channel in range(3)
                ),
            )
    if len(colored_means) == 4 and colored_pairwise_error >= 0.02:
        colored_failures.append(
            f"colored-lobe raw HDR candidate-count pairwise error {colored_pairwise_error:.6g} >= 2%"
        )

    energy_specs = {
        "zero": (0.0, "0"),
        "half": (0.5, "0_5"),
        "double": (2.0, "2"),
    }
    energy_by_level: dict[str, Any] = {}
    energy_means: dict[str, list[float]] = {}
    energy_failures: list[str] = []
    for level_name, (energy, segment_suffix) in energy_specs.items():
        matching = [
            snapshot
            for snapshot in snapshots
            if safe_int(snapshot.get("algorithm_mode"), -1) == 2
            and snapshot.get("algorithm") == "phase1_reference"
            and safe_int(snapshot.get("feature_flags"), 0) == 1
            and snapshot.get("qa_segment") == f"phase1_fresh/energy_{segment_suffix}_target"
            and safe_int(snapshot.get("raw_hdr_sample_count"), 0) > 0
            and safe_int(snapshot.get("raw_hdr_nonfinite_or_overflow"), -1) == 0
            and isinstance(snapshot.get("raw_hdr_mean_rgb"), list)
            and len(snapshot["raw_hdr_mean_rgb"]) == 3
        ]
        analytic = [0.18 * energy] * 3
        if not matching:
            energy_failures.append(f"no raw HDR snapshot for dynamic_gi_energy={energy:g}")
            energy_by_level[level_name] = {
                "energy": energy,
                "analytic_raw_D": analytic,
                "snapshot_count": 0,
            }
            continue
        raw_mean, raw_sample_count = aggregate_rgb(matching)
        energy_means[level_name] = raw_mean
        maximum_absolute_error = max(
            abs(raw_mean[channel] - analytic[channel]) for channel in range(3)
        )
        maximum_relative_error = (
            max(
                abs(raw_mean[channel] - analytic[channel]) / analytic[channel]
                for channel in range(3)
            )
            if energy > 0.0
            else 0.0
        )
        if energy == 0.0 and maximum_absolute_error >= 0.001:
            energy_failures.append(
                f"dynamic_gi_energy=0 raw HDR absolute error {maximum_absolute_error:.6g} >= 0.001"
            )
        if energy > 0.0 and maximum_relative_error >= 0.01:
            energy_failures.append(
                f"dynamic_gi_energy={energy:g} raw HDR error {maximum_relative_error:.6g} >= 1%"
            )
        energy_by_level[level_name] = {
            "energy": energy,
            "analytic_raw_D": analytic,
            "snapshot_count": len(matching),
            "total_sample_count": raw_sample_count,
            "lattice_phase_coverage_count": phase_coverage(matching),
            "raw_hdr_mean_rgb": raw_mean,
            "maximum_channel_absolute_error": maximum_absolute_error,
            "maximum_channel_relative_error": maximum_relative_error,
        }

    if constant_mean:
        for level_name in ("half", "double"):
            energy = energy_specs[level_name][0]
            raw_mean = energy_means.get(level_name)
            if raw_mean is None:
                continue
            ratio_error = max(
                abs(raw_mean[channel] / constant_mean[channel] - energy) / energy
                for channel in range(3)
            )
            energy_by_level[level_name]["maximum_ratio_to_energy_one_relative_error"] = ratio_error
            if ratio_error >= 0.01:
                energy_failures.append(
                    f"dynamic_gi_energy={energy:g} ratio-to-one error {ratio_error:.6g} >= 1%"
                )
    else:
        energy_failures.append("energy scaling has no energy-one white-furnace baseline")

    exposure_matching = [
        snapshot
        for snapshot in snapshots
        if safe_int(snapshot.get("algorithm_mode"), -1) == 2
        and snapshot.get("algorithm") == "phase1_reference"
        and safe_int(snapshot.get("feature_flags"), 0) == 1
        and snapshot.get("qa_segment") == "phase1_fresh/exposure_2_target"
        and safe_int(snapshot.get("raw_hdr_sample_count"), 0) > 0
        and safe_int(snapshot.get("raw_hdr_nonfinite_or_overflow"), -1) == 0
        and isinstance(snapshot.get("raw_hdr_mean_rgb"), list)
        and len(snapshot["raw_hdr_mean_rgb"]) == 3
    ]
    exposure_failures: list[str] = []
    exposure_summary: dict[str, Any] = {
        "exposure_multiplier": 2.0,
        "analytic_raw_D": [0.36, 0.36, 0.36],
        "snapshot_count": len(exposure_matching),
    }
    if exposure_matching:
        exposure_mean, exposure_sample_count = aggregate_rgb(exposure_matching)
        exposure_error = relative_error(exposure_mean, (0.36, 0.36, 0.36))
        exposure_summary.update(
            {
                "total_sample_count": exposure_sample_count,
                "lattice_phase_coverage_count": phase_coverage(exposure_matching),
                "raw_hdr_mean_rgb": exposure_mean,
                "maximum_channel_relative_error": exposure_error,
            }
        )
        if exposure_error >= 0.01:
            exposure_failures.append(
                f"CameraAttributes exposure=2 raw HDR error {exposure_error:.6g} >= 1%"
            )
    else:
        exposure_failures.append("no raw HDR snapshot for CameraAttributes exposure=2")
    exposure_summary["failures"] = exposure_failures
    exposure_summary["status"] = "passed" if not exposure_failures else "failed"

    failures = list(colored_failures) + energy_failures + exposure_failures
    if constant_phase_coverage != PHASE1_RAW_LATTICE_PERIOD:
        failures.append(
            f"constant white-furnace raw HDR covered {constant_phase_coverage}/256 lattice phases"
        )
    if constant_error >= 0.01:
        failures.append(f"constant white-furnace raw HDR error {constant_error:.6g} >= 1%")
    return {
        "analytic_constant_environment_D": list(analytic_constant),
        "constant_snapshot_count": len(constant_candidates),
        "constant_total_sample_count": constant_sample_count,
        "constant_lattice_phase_coverage_count": constant_phase_coverage,
        "constant_raw_hdr_mean_rgb": constant_mean,
        "constant_maximum_channel_relative_error": constant_error,
        "analytic_colored_lobe_D": list(analytic_colored),
        "colored_lobe_by_candidate_count": colored_by_count,
        "colored_lobe_maximum_pairwise_relative_error": colored_pairwise_error,
        "energy_scaling": {
            "by_level": energy_by_level,
            "failures": energy_failures,
            "status": "passed" if not energy_failures and len(energy_means) == 3 else "failed",
            "nonzero_raw_acceptance_relative_error": 0.01,
            "zero_raw_acceptance_absolute_error": 0.001,
            "ratio_to_one_acceptance_relative_error": 0.01,
        },
        "camera_attributes_exposure": exposure_summary,
        "failures": failures,
        "status": "passed" if not failures and len(colored_means) == 4 else "failed",
        "constant_acceptance_relative_error": 0.01,
        "colored_acceptance_relative_error": 0.03,
        "candidate_pairwise_acceptance_relative_error": 0.02,
        "reference_kind": "60-rendered-frame windows of a rotating 16x16 full-resolution D lattice, sample-count-weighted GPU fixed-point reduction with explicit 256-phase coverage; pre-apply and pre-tonemap",
    }


def summarize_phase2_raw_hdr_pre_tonemap(
    snapshots: list[dict[str, Any]], warmup_frames: int, sample_frames: int
) -> tuple[dict[str, Any], list[str]]:
    """Compare P1-N2 and P2-N1 raw D using only segment-pure 60-frame windows.

    Raw slots accumulate on a generation-local 60-frame cadence, while the QA
    warmup/sample marker changes after at least 64 frames. Consequently, the
    first complete readback labelled as a sample overlaps the last warmup
    frames. Derive each algorithm generation's first rendered frame from its
    first complete warmup window, then admit a sample-labelled window only when
    its complete [end - 59, end] interval lies inside the known sample interval.
    """

    effective_warmup_frames = max(warmup_frames, PHASE2_COMPARISON_MIN_FRAMES)
    effective_sample_frames = max(sample_frames, PHASE2_COMPARISON_MIN_FRAMES)
    failures: list[str] = []
    cases: dict[str, Any] = {}
    identities = {
        "p1_n2": (1, "phase1_fresh", 9),
        "p2_n1_visibility": (PHASE2_ALGORITHM_MODE, PHASE2_ALGORITHM_NAME, 3),
    }

    def identity_matches(snapshot: dict[str, Any], identity: tuple[int, str, int]) -> bool:
        return (
            safe_int(snapshot.get("algorithm_mode"), -1) == identity[0]
            and snapshot.get("algorithm") == identity[1]
            and safe_int(snapshot.get("feature_flags"), -1) == identity[2]
        )

    def validate_window(snapshot: dict[str, Any], label: str) -> tuple[dict[str, Any], list[str]]:
        window_failures: list[str] = []
        endpoint_frame = exact_int(snapshot.get("frame"))
        width = exact_int(snapshot.get("width"))
        height = exact_int(snapshot.get("height"))
        view_count = exact_int(snapshot.get("view_count"))
        sample_count = exact_int(snapshot.get("raw_hdr_sample_count"))
        fixed_scale = safe_float(snapshot.get("raw_hdr_fixed_scale"))
        fixed_sums = [
            exact_int(snapshot.get(field))
            for field in ("raw_hdr_fixed_sum_r", "raw_hdr_fixed_sum_g", "raw_hdr_fixed_sum_b")
        ]

        if endpoint_frame is None or endpoint_frame < PHASE1_RAW_WINDOW_FRAMES - 1:
            window_failures.append(f"{label}: endpoint frame is not a valid exact integer")
        if width is None or width <= 0 or height is None or height <= 0:
            window_failures.append(f"{label}: dimensions must be positive exact integers")
        if view_count is None or view_count <= 0:
            window_failures.append(f"{label}: view_count must be a positive exact integer")
        if safe_int(snapshot.get("raw_hdr_accumulated_frame_count"), -1) != PHASE1_RAW_WINDOW_FRAMES:
            window_failures.append(
                f"{label}: raw HDR accumulation must contain exactly {PHASE1_RAW_WINDOW_FRAMES} frames"
            )
        if not math.isclose(fixed_scale, PHASE1_RAW_FIXED_SCALE, rel_tol=0.0, abs_tol=0.0):
            window_failures.append(
                f"{label}: raw HDR fixed scale must be exactly {PHASE1_RAW_FIXED_SCALE:g}"
            )
        if safe_int(snapshot.get("raw_hdr_lattice_stride"), -1) != PHASE1_RAW_LATTICE_STRIDE:
            window_failures.append(
                f"{label}: raw HDR lattice stride must be {PHASE1_RAW_LATTICE_STRIDE}"
            )
        if safe_int(snapshot.get("raw_hdr_lattice_period"), -1) != PHASE1_RAW_LATTICE_PERIOD:
            window_failures.append(
                f"{label}: raw HDR lattice period must be {PHASE1_RAW_LATTICE_PERIOD}"
            )
        if safe_int(snapshot.get("raw_hdr_nonfinite_or_overflow"), -1) != 0:
            window_failures.append(f"{label}: raw HDR nonfinite/overflow counter must be zero")

        try:
            phases = phase1_raw_phase_indices(snapshot.get("raw_hdr_lattice_phase_mask_words"))
        except (TypeError, ValueError) as exc:
            phases = []
            window_failures.append(f"{label}: {exc}")
        reported_coverage = exact_int(snapshot.get("raw_hdr_lattice_phase_coverage_count"))
        if reported_coverage != len(phases):
            window_failures.append(f"{label}: reported phase coverage does not match mask popcount")
        if len(phases) != PHASE1_RAW_WINDOW_FRAMES:
            window_failures.append(
                f"{label}: complete raw window must cover 60 distinct lattice phases"
            )
        if endpoint_frame is not None:
            expected_phases = sorted(
                frame & (PHASE1_RAW_LATTICE_PERIOD - 1)
                for frame in range(
                    endpoint_frame - (PHASE1_RAW_WINDOW_FRAMES - 1),
                    endpoint_frame + 1,
                )
            )
            if phases != expected_phases:
                window_failures.append(
                    f"{label}: lattice phase mask does not match the exact 60-frame interval"
                )
        history_generation = exact_int(snapshot.get("history_generation"))
        history_sequence = exact_int(snapshot.get("history_sequence"))
        if history_generation is None or history_generation <= 0:
            window_failures.append(f"{label}: history_generation must be positive")
        if (
            history_sequence is None
            or history_sequence < 0
            or history_sequence % PHASE1_RAW_WINDOW_FRAMES
            != PHASE1_RAW_WINDOW_FRAMES - 1
        ):
            window_failures.append(
                f"{label}: complete raw window must end at generation-local sequence 59 modulo 60"
            )
        if safe_int(snapshot.get("history_valid"), -1) != 1:
            window_failures.append(f"{label}: complete raw window must have live history")

        if sample_count is None or sample_count <= 0:
            window_failures.append(f"{label}: raw HDR sample count must be positive")
        elif width is not None and height is not None and view_count is not None:
            expected_sample_count = phase1_expected_raw_sample_count(
                width, height, view_count, phases
            )
            if sample_count != expected_sample_count:
                window_failures.append(
                    f"{label}: raw sample count {sample_count} does not match lattice expectation "
                    f"{expected_sample_count}"
                )

        if any(value is None or value < 0 or value > 0xFFFFFFFF for value in fixed_sums):
            window_failures.append(f"{label}: raw HDR fixed sums must be uint32")

        reported_mean = snapshot.get("raw_hdr_mean_rgb")
        if (
            not isinstance(reported_mean, list)
            or len(reported_mean) != 3
            or any(
                not math.isfinite(safe_float(channel)) or safe_float(channel) < 0.0
                for channel in reported_mean
            )
        ):
            window_failures.append(f"{label}: raw_hdr_mean_rgb must be finite non-negative RGB")
            reported_mean = None

        derived_mean: list[float] | None = None
        if (
            sample_count is not None
            and sample_count > 0
            and math.isfinite(fixed_scale)
            and fixed_scale > 0.0
            and all(value is not None and 0 <= value <= 0xFFFFFFFF for value in fixed_sums)
        ):
            derived_mean = [
                float(value) / (sample_count * fixed_scale)  # type: ignore[arg-type]
                for value in fixed_sums
            ]
            if reported_mean is not None and any(
                not math.isclose(
                    safe_float(reported_mean[channel]),
                    derived_mean[channel],
                    rel_tol=0.0,
                    abs_tol=1e-12,
                )
                for channel in range(3)
            ):
                window_failures.append(
                    f"{label}: raw_hdr_mean_rgb is inconsistent with fixed sums and sample count"
                )

        return (
            {
                "start_frame": endpoint_frame - (PHASE1_RAW_WINDOW_FRAMES - 1)
                if endpoint_frame is not None
                else None,
                "end_frame": endpoint_frame,
                "sample_count": sample_count,
                "lattice_phase_coverage_count": len(phases),
                "lattice_phase_indices": phases,
                "history_generation": history_generation,
                "history_sequence": history_sequence,
                "fixed_sums_rgb": fixed_sums,
                "mean_rgb": derived_mean,
                "status": "passed" if not window_failures else "failed",
                "failures": window_failures,
            },
            window_failures,
        )

    def aggregate_windows(windows: list[dict[str, Any]]) -> dict[str, Any] | None:
        if not windows:
            return None
        total_sample_count = sum(int(window["sample_count"]) for window in windows)
        fixed_sums = [
            sum(int(window["fixed_sums_rgb"][channel]) for window in windows)
            for channel in range(3)
        ]
        mean_rgb = [
            fixed_sum / (total_sample_count * PHASE1_RAW_FIXED_SCALE)
            for fixed_sum in fixed_sums
        ]
        return {
            "window_count": len(windows),
            "total_sample_count": total_sample_count,
            "fixed_sums_rgb": fixed_sums,
            "mean_rgb": mean_rgb,
            "mean_luminance_rec709": (
                mean_rgb[0] * 0.2126 + mean_rgb[1] * 0.7152 + mean_rgb[2] * 0.0722
            ),
        }

    for case_name in ("constant", "colored"):
        case_summary: dict[str, Any] = {}
        transport_aggregates: dict[str, dict[str, Any] | None] = {}
        for transport_name, identity in identities.items():
            warmup_segment = f"phase2_temporal/{case_name}/{transport_name}_warmup"
            sample_segment = f"phase2_temporal/{case_name}/{transport_name}_sample"
            complete_warmup = sorted(
                (
                    snapshot
                    for snapshot in snapshots
                    if snapshot.get("qa_segment") == warmup_segment
                    and identity_matches(snapshot, identity)
                    and safe_int(snapshot.get("raw_hdr_accumulated_frame_count"), -1)
                    == PHASE1_RAW_WINDOW_FRAMES
                    and exact_int(snapshot.get("frame")) is not None
                ),
                key=lambda snapshot: safe_int(snapshot.get("frame"), 0),
            )
            if not complete_warmup:
                failures.append(
                    f"{case_name}/{transport_name}: no complete 60-frame warmup anchor was captured"
                )
                case_summary[transport_name] = {
                    "warmup_segment": warmup_segment,
                    "sample_segment": sample_segment,
                    "status": "failed",
                    "eligible_window_count": 0,
                }
                transport_aggregates[transport_name] = None
                continue

            anchor_end = safe_int(complete_warmup[0].get("frame"), 0)
            anchor_generation = safe_int(
                complete_warmup[0].get("history_generation"), -1
            )
            anchor_sequence = safe_int(
                complete_warmup[0].get("history_sequence"), -1
            )
            algorithm_start = anchor_end - (PHASE1_RAW_WINDOW_FRAMES - 1)
            sample_start = algorithm_start + effective_warmup_frames
            sample_end = sample_start + effective_sample_frames - 1
            complete_sample = sorted(
                (
                    snapshot
                    for snapshot in snapshots
                    if snapshot.get("qa_segment") == sample_segment
                    and identity_matches(snapshot, identity)
                    and safe_int(snapshot.get("raw_hdr_accumulated_frame_count"), -1)
                    == PHASE1_RAW_WINDOW_FRAMES
                    and exact_int(snapshot.get("frame")) is not None
                ),
                key=lambda snapshot: safe_int(snapshot.get("frame"), 0),
            )
            misaligned_end_frames = [
                safe_int(snapshot.get("frame"), -1)
                for snapshot in complete_sample
                if safe_int(snapshot.get("frame"), -1) <= anchor_end
                or (safe_int(snapshot.get("frame"), -1) - anchor_end)
                % PHASE1_RAW_WINDOW_FRAMES
                != 0
            ]
            if misaligned_end_frames:
                failures.append(
                    f"{case_name}/{transport_name}: complete sample windows are not aligned to "
                    f"the warmup generation anchor: {misaligned_end_frames!r}"
                )

            generation_or_sequence_mismatches = [
                safe_int(snapshot.get("frame"), -1)
                for snapshot in complete_sample
                if safe_int(snapshot.get("history_generation"), -2)
                != anchor_generation
                or safe_int(snapshot.get("history_sequence"), -1)
                != anchor_sequence
                + safe_int(snapshot.get("frame"), -1)
                - anchor_end
            ]
            if generation_or_sequence_mismatches:
                failures.append(
                    f"{case_name}/{transport_name}: raw windows crossed a generation reset or sequence discontinuity: {generation_or_sequence_mismatches!r}"
                )

            def lies_wholly_in_sample(snapshot: dict[str, Any]) -> bool:
                endpoint = safe_int(snapshot.get("frame"), 0)
                return (
                    endpoint - (PHASE1_RAW_WINDOW_FRAMES - 1) >= sample_start
                    and endpoint <= sample_end
                )

            eligible_snapshots = [
                snapshot for snapshot in complete_sample if lies_wholly_in_sample(snapshot)
            ]
            excluded_snapshots = [
                snapshot for snapshot in complete_sample if not lies_wholly_in_sample(snapshot)
            ]

            endpoint_frames = [safe_int(snapshot.get("frame"), -1) for snapshot in eligible_snapshots]
            expected_eligible_endpoint_frames = [
                endpoint
                for endpoint in range(
                    anchor_end + PHASE1_RAW_WINDOW_FRAMES,
                    sample_end + 1,
                    PHASE1_RAW_WINDOW_FRAMES,
                )
                if endpoint - (PHASE1_RAW_WINDOW_FRAMES - 1) >= sample_start
            ]
            if endpoint_frames != expected_eligible_endpoint_frames:
                failures.append(
                    f"{case_name}/{transport_name}: eligible raw-window endpoints {endpoint_frames!r} != expected {expected_eligible_endpoint_frames!r}"
                )
            if len(endpoint_frames) != len(set(endpoint_frames)):
                failures.append(
                    f"{case_name}/{transport_name}: duplicate complete-window endpoint frame"
                )
            if not eligible_snapshots:
                failures.append(
                    f"{case_name}/{transport_name}: no complete 60-frame raw window lies wholly "
                    "inside the sample segment"
                )

            validated_windows: list[dict[str, Any]] = []
            window_summaries: list[dict[str, Any]] = []
            for window_index, snapshot in enumerate(eligible_snapshots):
                window_summary, window_failures = validate_window(
                    snapshot, f"{case_name}/{transport_name} window {window_index}"
                )
                window_summaries.append(window_summary)
                if window_failures:
                    failures.extend(window_failures)
                else:
                    validated_windows.append(window_summary)

            aggregate = aggregate_windows(validated_windows)
            transport_aggregates[transport_name] = aggregate
            case_summary[transport_name] = {
                "warmup_segment": warmup_segment,
                "sample_segment": sample_segment,
                "algorithm_identity": {
                    "algorithm_mode": identity[0],
                    "algorithm": identity[1],
                    "feature_flags": identity[2],
                },
                "algorithm_generation_start_frame": algorithm_start,
                "sample_interval_frames_inclusive": [sample_start, sample_end],
                "warmup_anchor_end_frame": anchor_end,
                "warmup_anchor_generation": anchor_generation,
                "warmup_anchor_sequence": anchor_sequence,
                "complete_sample_window_count": len(complete_sample),
                "misaligned_window_end_frames": misaligned_end_frames,
                "boundary_or_out_of_segment_window_count_excluded": len(excluded_snapshots),
                "excluded_window_end_frames": [
                    safe_int(snapshot.get("frame"), -1) for snapshot in excluded_snapshots
                ],
                "eligible_window_count": len(eligible_snapshots),
                "expected_eligible_window_count": len(
                    expected_eligible_endpoint_frames
                ),
                "expected_eligible_window_end_frames": expected_eligible_endpoint_frames,
                "valid_window_count": len(validated_windows),
                "windows": window_summaries,
                "aggregate": aggregate,
                "status": (
                    "passed"
                    if eligible_snapshots and len(validated_windows) == len(eligible_snapshots)
                    else "failed"
                ),
            }

        p1_aggregate = transport_aggregates.get("p1_n2")
        p2_aggregate = transport_aggregates.get("p2_n1_visibility")
        if p1_aggregate is not None and p2_aggregate is not None:
            p1_rgb = p1_aggregate["mean_rgb"]
            p2_rgb = p2_aggregate["mean_rgb"]
            channel_differences = [
                abs(float(p2_rgb[channel]) - float(p1_rgb[channel]))
                / max(
                    (abs(float(p2_rgb[channel])) + abs(float(p1_rgb[channel]))) * 0.5,
                    1e-12,
                )
                for channel in range(3)
            ]
            p1_luminance = float(p1_aggregate["mean_luminance_rec709"])
            p2_luminance = float(p2_aggregate["mean_luminance_rec709"])
            case_summary.update(
                {
                    "channel_relative_differences_p2_vs_p1_n2": channel_differences,
                    "maximum_channel_relative_difference_p2_vs_p1_n2": max(
                        channel_differences
                    ),
                    "luminance_relative_difference_p2_vs_p1_n2": (
                        abs(p2_luminance - p1_luminance)
                        / max((abs(p2_luminance) + abs(p1_luminance)) * 0.5, 1e-12)
                    ),
                }
            )
        else:
            case_summary.update(
                {
                    "channel_relative_differences_p2_vs_p1_n2": None,
                    "maximum_channel_relative_difference_p2_vs_p1_n2": None,
                    "luminance_relative_difference_p2_vs_p1_n2": None,
                }
            )
        cases[case_name] = case_summary

    summary = {
        "status": "passed" if not failures else "failed",
        "domain": "linear full-resolution raw D before NRD, material apply, and tonemap",
        "window_frames": PHASE1_RAW_WINDOW_FRAMES,
        "effective_warmup_frames": effective_warmup_frames,
        "effective_sample_frames": effective_sample_frames,
        "selection_contract": (
            "derive each algorithm generation start from its first complete warmup window; "
            "retain only exact 60-frame sample-labelled windows whose full frame interval is "
            "inside the configured sample interval; reject boundary-overlapping windows; "
            "aggregate GPU uint32 fixed sums weighted by exact lattice sample count"
        ),
        "cases": cases,
        "failures": failures,
    }
    return summary, failures


def validate_image_dimensions(value: Any, width: int, height: int, path: str = "result") -> list[str]:
    failures: list[str] = []
    if isinstance(value, dict):
        if "sampled_pixels" in value:
            if safe_int(value.get("sampled_pixels"), 0) <= 0:
                failures.append(f"{path}.sampled_pixels must be positive")
            if "width" in value and safe_int(value.get("width"), -1) != width:
                failures.append(f"{path}.width does not match result resolution")
            if "height" in value and safe_int(value.get("height"), -1) != height:
                failures.append(f"{path}.height does not match result resolution")
        if "sampled_pixels_per_frame" in value and safe_int(value.get("sampled_pixels_per_frame"), 0) <= 0:
            failures.append(f"{path}.sampled_pixels_per_frame must be positive")
        for key, child in value.items():
            failures.extend(validate_image_dimensions(child, width, height, f"{path}.{key}"))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            failures.extend(validate_image_dimensions(child, width, height, f"{path}[{index}]"))
    return failures


def profile_mismatches(profile: dict[str, Any], result: dict[str, Any], scenario: str) -> list[str]:
    match = profile.get("match", {})
    renderer = result.get("renderer", {})
    resolution = result.get("resolution", {})
    mismatches: list[str] = []
    if match.get("adapter_name_contains", "") not in renderer.get("adapter_name", ""):
        mismatches.append("adapter_name")
    if "adapter_vendor" in match and match.get("adapter_vendor") != renderer.get("adapter_vendor"):
        mismatches.append("adapter_vendor")
    if "api_version" in match and match.get("api_version") != renderer.get("api_version"):
        mismatches.append("api_version")
    if "driver_info" in match and match.get("driver_info") != renderer.get("driver_info"):
        mismatches.append("driver_info")
    if match.get("rendering_method") != renderer.get("rendering_method"):
        mismatches.append("rendering_method")
    if match.get("rendering_driver") != renderer.get("rendering_driver"):
        mismatches.append("rendering_driver")
    for field in ("width", "height", "sample_stride"):
        if field in match and safe_int(match.get(field), -2) != safe_int(resolution.get(field), -1):
            mismatches.append(field)
    expected_scenario = profile.get("suite_parameters", {}).get("scenario", "all")
    if expected_scenario != scenario:
        mismatches.append("scenario")
    suite_parameters = profile.get("suite_parameters", {})
    result_frames = result.get("frames", {})
    frame_mapping = {
        "warmup_frames": "warmup",
        "sample_frames": "sample",
        "settle_frames": "settle",
        "phase1_long_frames": "phase1_long",
        "phase2_long_frames": "phase2_long",
    }
    for expected_field, result_field in frame_mapping.items():
        if expected_field in suite_parameters and safe_int(
            suite_parameters.get(expected_field), -2
        ) != safe_int(result_frames.get(result_field), -1):
            mismatches.append(expected_field)
    if "roi_border_fraction" in suite_parameters:
        expected_roi = safe_float(suite_parameters.get("roi_border_fraction"))
        observed_roi = safe_float(resolution.get("roi_border_fraction"))
        if not (
            math.isfinite(expected_roi)
            and math.isfinite(observed_roi)
            and math.isclose(expected_roi, observed_roi, rel_tol=0.0, abs_tol=1e-9)
        ):
            mismatches.append("roi_border_fraction")
    return mismatches


def validate_expected_metrics(
    manifest: dict[str, Any], result: dict[str, Any], scenario: str, runtime_error_count: int
) -> tuple[dict[str, Any], list[str]]:
    if "acceptance_ready" in manifest and manifest.get("acceptance_ready") is not True:
        return (
            {
                "status": "unbaselined",
                "reason": str(
                    manifest.get(
                        "unbaselined_reason",
                        "Expected-metrics manifest is explicitly not ready for acceptance.",
                    )
                ),
            },
            ["Expected-metrics manifest is explicitly unbaselined; acceptance is disabled."],
        )
    candidates = manifest.get("profiles", [])
    mismatch_report: dict[str, list[str]] = {}
    matches: list[dict[str, Any]] = []
    for profile in candidates:
        mismatches = profile_mismatches(profile, result, scenario)
        if not mismatches:
            matches.append(profile)
        else:
            mismatch_report[str(profile.get("id", "unnamed"))] = mismatches
    if not matches:
        failure = "No expected-metrics hardware profile matched; acceptance cannot pass as skipped."
        if not candidates:
            failure = "Expected-metrics manifest has no calibrated hardware profile; run is diagnostic only."
        return (
            {
                "status": "skipped",
                "reason": "No expected-metrics profile matched this hardware/render configuration and scenario.",
                "profile_mismatches": mismatch_report,
            },
            [failure],
        )
    if len(matches) != 1:
        matching_ids = [str(profile.get("id", "unnamed")) for profile in matches]
        return (
            {
                "status": "failed",
                "reason": "Expected-metrics profile matching is ambiguous.",
                "matching_profile_ids": matching_ids,
            },
            [f"Expected exactly one matching hardware profile, found {len(matches)}: {matching_ids}"],
        )
    selected = matches[0]

    failures: list[str] = []
    required = selected.get("required", {})
    if result.get("status") != required.get("status", "completed"):
        failures.append("runner status did not satisfy expected profile")
    if runtime_error_count != safe_int(required.get("runtime_error_count"), 0):
        failures.append("runtime error count did not satisfy expected profile")
    counters = result.get("debug_counters", {})
    if bool(counters.get("schema_valid")) != bool(required.get("counter_schema_valid", True)):
        failures.append("counter schema validity did not satisfy expected profile")
    if safe_int(counters.get("snapshot_count"), 0) < safe_int(required.get("minimum_counter_snapshots"), 0):
        failures.append("counter snapshot count was below expected minimum")
    gpu_profile = result.get("gpu_profile", {})
    if safe_int(gpu_profile.get("profile_block_count"), 0) < safe_int(required.get("minimum_gpu_profile_blocks"), 0):
        failures.append("GPU profile block count was below expected minimum")
    if safe_int(gpu_profile.get("hddagi_sample_count"), 0) < safe_int(required.get("minimum_hddagi_gpu_samples"), 0):
        failures.append("HDDAGI GPU profile sample count was below expected minimum")
    observed_gpu_tasks = list(gpu_profile.get("task_summaries_ms", {}))
    for required_substring in required.get("gpu_task_names_contain", []):
        if not any(str(required_substring) in task_name for task_name in observed_gpu_tasks):
            failures.append(f"required GPU task marker was not observed: {required_substring}")
    for forbidden_substring in required.get("gpu_task_names_exclude", []):
        if any(str(forbidden_substring) in task_name for task_name in observed_gpu_tasks):
            failures.append(f"forbidden GPU task marker was observed: {forbidden_substring}")
    observed_flags = {safe_int(snapshot.get("feature_flags"), -1) for snapshot in counters.get("snapshots", [])}
    for required_flag in required.get("counter_feature_flags", []):
        if safe_int(required_flag, -2) not in observed_flags:
            failures.append(f"required counter feature_flags={required_flag} was not observed")
    for check_path in required.get("checks", []):
        try:
            if get_path(result, check_path) is not True:
                failures.append(f"required check was false: {check_path}")
        except KeyError:
            failures.append(f"required check was missing: {check_path}")
    for metric_path, limits in selected.get("thresholds", {}).items():
        try:
            metric_value = safe_float(get_path(result, metric_path))
        except KeyError:
            failures.append(f"threshold metric was missing or non-numeric: {metric_path}")
            continue
        if not math.isfinite(metric_value):
            failures.append(f"threshold metric was non-finite: {metric_path}")
            continue
        if not isinstance(limits, dict):
            failures.append(f"threshold limits must be an object: {metric_path}")
            continue
        minimum = safe_float(limits.get("min")) if "min" in limits else None
        maximum = safe_float(limits.get("max")) if "max" in limits else None
        if minimum is not None and not math.isfinite(minimum):
            failures.append(f"threshold minimum was non-finite: {metric_path}")
            continue
        if maximum is not None and not math.isfinite(maximum):
            failures.append(f"threshold maximum was non-finite: {metric_path}")
            continue
        if minimum is None and maximum is None:
            failures.append(f"threshold declared neither finite min nor max: {metric_path}")
            continue
        if minimum is not None and metric_value < minimum:
            failures.append(f"threshold failed: {metric_path} < {limits['min']}")
        if maximum is not None and metric_value > maximum:
            failures.append(f"threshold failed: {metric_path} > {limits['max']}")
    return (
        {
            "status": "passed" if not failures else "failed",
            "profile_id": selected.get("id"),
            "failures": failures,
        },
        failures,
    )


def validate_profile_authoring_contract(manifest: dict[str, Any]) -> list[str]:
    """Reject incomplete or drifting Phase 2 acceptance profiles before a run is scored."""
    if manifest.get("acceptance_ready") is False:
        return []
    failures: list[str] = []
    contract = manifest.get("profile_authoring_contract")
    if not isinstance(contract, dict):
        return ["profile_authoring_contract must be an object"]
    def string_list(owner: dict[str, Any], field: str, path: str) -> list[str]:
        value = owner.get(field)
        if not isinstance(value, list) or not value:
            failures.append(f"{path}.{field} must be a non-empty list")
            return []
        if any(not isinstance(item, str) or not item for item in value):
            failures.append(f"{path}.{field} must contain only non-empty strings")
            return []
        if len(value) != len(set(value)):
            failures.append(f"{path}.{field} must not contain duplicates")
        return list(value)

    manifest_fields = string_list(manifest, "counter_fields", "manifest")
    required_match_fields = string_list(contract, "required_match_fields", "profile_authoring_contract")
    required_suite_parameters = string_list(
        contract, "required_suite_parameters", "profile_authoring_contract"
    )
    required_checks = string_list(contract, "required_checks", "profile_authoring_contract")
    required_thresholds = string_list(
        contract, "metrics_requiring_real_gpu_thresholds", "profile_authoring_contract"
    )
    required_gpu_tasks = string_list(
        contract, "required_gpu_task_markers", "profile_authoring_contract"
    )
    string_list(contract, "required_counter_identities", "profile_authoring_contract")

    profiles = manifest.get("profiles")
    if not isinstance(profiles, list) or not profiles:
        return failures + ["profiles must be a non-empty list"]
    profile_ids: list[str] = []
    for index, profile in enumerate(profiles):
        path = f"profiles[{index}]"
        if not isinstance(profile, dict):
            failures.append(f"{path} must be an object")
            continue
        profile_id = profile.get("id")
        if not isinstance(profile_id, str) or not profile_id:
            failures.append(f"{path}.id must be a non-empty string")
        else:
            profile_ids.append(profile_id)

        match = profile.get("match")
        if not isinstance(match, dict):
            failures.append(f"{path}.match must be an object")
        else:
            for field in required_match_fields:
                if field not in match or match.get(field) in (None, ""):
                    failures.append(f"{path}.match is missing required field: {field}")

        suite_parameters = profile.get("suite_parameters")
        if not isinstance(suite_parameters, dict):
            failures.append(f"{path}.suite_parameters must be an object")
        else:
            for field in required_suite_parameters:
                if field not in suite_parameters or suite_parameters.get(field) in (None, ""):
                    failures.append(f"{path}.suite_parameters is missing required field: {field}")

        required = profile.get("required")
        if not isinstance(required, dict):
            failures.append(f"{path}.required must be an object")
            continue
        profile_checks = required.get("checks")
        if not isinstance(profile_checks, list):
            failures.append(f"{path}.required.checks must be a list")
        else:
            for check in required_checks:
                if check not in profile_checks:
                    failures.append(f"{path}.required.checks is missing: {check}")
        profile_fields = required.get("counter_fields")
        if not isinstance(profile_fields, list):
            failures.append(f"{path}.required.counter_fields must be a list")
        elif profile_fields != manifest_fields:
            missing = [field for field in manifest_fields if field not in profile_fields]
            extra = [field for field in profile_fields if field not in manifest_fields]
            failures.append(
                f"{path}.required.counter_fields must exactly match the canonical manifest schema "
                f"(missing={missing}, extra={extra}, order_matches={not missing and not extra})"
            )
        profile_gpu_tasks = required.get("gpu_task_names_contain")
        if not isinstance(profile_gpu_tasks, list):
            failures.append(f"{path}.required.gpu_task_names_contain must be a list")
        else:
            for marker in required_gpu_tasks:
                if marker not in profile_gpu_tasks:
                    failures.append(f"{path}.required.gpu_task_names_contain is missing: {marker}")

        thresholds = profile.get("thresholds")
        if not isinstance(thresholds, dict):
            failures.append(f"{path}.thresholds must be an object")
        else:
            for metric in required_thresholds:
                if metric not in thresholds:
                    failures.append(f"{path}.thresholds is missing required GPU metric: {metric}")

    duplicate_ids = sorted({profile_id for profile_id in profile_ids if profile_ids.count(profile_id) > 1})
    if duplicate_ids:
        failures.append(f"profile ids must be unique: {duplicate_ids}")
    return failures


def git_output(repo_root: Path, *arguments: str, binary: bool = False) -> bytes | str:
    completed = subprocess.run(
        ["git", *arguments],
        cwd=repo_root,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return completed.stdout if binary else completed.stdout.decode("utf-8", errors="replace").strip()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_editor_payload(editor: Path) -> Path:
    name = editor.name
    suffix = ".console.exe"
    if name.lower().endswith(suffix):
        payload = editor.with_name(name[: -len(suffix)] + ".exe")
        if not payload.is_file():
            raise FileNotFoundError(f"Windows console wrapper payload does not exist: {payload}")
        return payload
    return editor


def collect_provenance(
    repo_root: Path,
    editor: Path,
    console_log: Path,
    engine_log: Path,
    expected_manifest: Path,
    validator: Path,
    runner_result_sha256: str,
) -> dict[str, Any]:
    status = str(git_output(repo_root, "status", "--porcelain=v1", "--untracked-files=all"))
    diff = bytes(git_output(repo_root, "diff", "--binary", "HEAD", binary=True))
    untracked_output = bytes(
        git_output(repo_root, "ls-files", "--others", "--exclude-standard", "-z", binary=True)
    )
    untracked_payload = bytearray(untracked_output)
    for relative_path_bytes in untracked_output.split(b"\0"):
        if not relative_path_bytes:
            continue
        relative_path = relative_path_bytes.decode("utf-8", errors="surrogateescape")
        candidate = repo_root / relative_path
        if candidate.is_file():
            untracked_payload.extend(hashlib.sha256(candidate.read_bytes()).digest())
    fingerprint_payload = status.encode("utf-8") + b"\0" + diff + b"\0" + bytes(untracked_payload)
    editor_stat = editor.stat()
    editor_payload = resolve_editor_payload(editor)
    payload_stat = editor_payload.stat()
    return {
        "git_head": git_output(repo_root, "rev-parse", "HEAD"),
        "worktree_dirty": bool(status),
        "worktree_status": status.splitlines(),
        "worktree_diff_sha256": hashlib.sha256(fingerprint_payload).hexdigest(),
        "editor_path": str(editor.resolve()),
        "editor_size_bytes": editor_stat.st_size,
        "editor_mtime_utc": dt.datetime.fromtimestamp(editor_stat.st_mtime, dt.timezone.utc).isoformat(),
        "editor_sha256": file_sha256(editor),
        "editor_is_console_wrapper": editor_payload.resolve() != editor.resolve(),
        "editor_payload_path": str(editor_payload.resolve()),
        "editor_payload_size_bytes": payload_stat.st_size,
        "editor_payload_mtime_utc": dt.datetime.fromtimestamp(
            payload_stat.st_mtime, dt.timezone.utc
        ).isoformat(),
        "editor_payload_sha256": file_sha256(editor_payload),
        "runner_result_sha256_before_post_validation": runner_result_sha256,
        "console_log_path": str(console_log.resolve()),
        "console_log_sha256": file_sha256(console_log),
        "engine_log_path": str(engine_log.resolve()),
        "engine_log_sha256": file_sha256(engine_log),
        "expected_manifest_path": str(expected_manifest.resolve()),
        "expected_manifest_sha256": file_sha256(expected_manifest),
        "validator_path": str(validator.resolve()),
        "validator_sha256": file_sha256(validator),
    }


def main() -> int:
    args = parse_args()
    if not args.result.is_file():
        print(f"QA validator: result does not exist: {args.result}", file=sys.stderr)
        return 1
    runner_result_bytes = args.result.read_bytes()
    result = json.loads(runner_result_bytes.decode("utf-8"))
    manifest = json.loads(args.expected.read_text(encoding="utf-8"))
    missing_logs = [path for path in (args.console_log, args.engine_log) if not path.is_file()]
    console_lines = read_lines(args.console_log)
    engine_lines = read_lines(args.engine_log)
    # Preserve the runner-owned input separately so post-exit validation is
    # idempotent. A second validation pass must not treat errors written by a
    # previous validator version (or its final failed status) as runtime input.
    validation_input = result.get("post_validation_input")
    runner_result_sha256 = hashlib.sha256(runner_result_bytes).hexdigest()
    if isinstance(validation_input, dict):
        preserved_runner_sha256 = validation_input.get(
            "runner_result_sha256_before_post_validation"
        )
        if not (
            isinstance(preserved_runner_sha256, str)
            and re.fullmatch(r"[0-9a-f]{64}", preserved_runner_sha256)
        ):
            previous_provenance = result.get("provenance", {})
            if isinstance(previous_provenance, dict):
                preserved_runner_sha256 = previous_provenance.get(
                    "runner_result_sha256_before_post_validation"
                )
        if (
            isinstance(preserved_runner_sha256, str)
            and re.fullmatch(r"[0-9a-f]{64}", preserved_runner_sha256)
        ):
            runner_result_sha256 = preserved_runner_sha256
        validation_input["runner_result_sha256_before_post_validation"] = (
            runner_result_sha256
        )
        result["status"] = validation_input.get("status", result.get("status"))
        errors = list(validation_input.get("errors", []))
        warnings = list(validation_input.get("warnings", []))
    else:
        errors = list(result.get("errors", []))
        warnings = list(result.get("warnings", []))
        result["post_validation_input"] = {
            "status": result.get("status"),
            "errors": list(errors),
            "warnings": list(warnings),
            "runner_result_sha256_before_post_validation": runner_result_sha256,
        }
    if result.get("schema_version") != RESULT_SCHEMA_VERSION:
        add_unique(errors, f"Runner result schema must be {RESULT_SCHEMA_VERSION}.")
    if result.get("suite") != manifest.get("suite"):
        add_unique(errors, "Runner result suite does not match the expected-metrics manifest suite.")
    if args.scenario != "all" and args.scenario not in result.get("scenarios", {}):
        add_unique(errors, f"Runner result did not contain requested scenario {args.scenario!r}.")
    if args.scenario == "phase2_temporal":
        if manifest.get("schema_version") != PHASE2_MANIFEST_SCHEMA_VERSION:
            add_unique(errors, f"Phase 2 manifest schema must be {PHASE2_MANIFEST_SCHEMA_VERSION}.")
        if manifest.get("suite") != PHASE2_SUITE_NAME:
            add_unique(errors, f"Phase 2 manifest suite must be {PHASE2_SUITE_NAME}.")
        for failure in validate_profile_authoring_contract(manifest):
            add_unique(errors, f"Phase 2 profile authoring contract: {failure}")
    engine = result.get("engine", {})
    for field in ("version", "hash", "build"):
        if not isinstance(engine.get(field), str) or not engine.get(field):
            add_unique(errors, f"Runner engine.{field} must be a non-empty string.")
    try:
        result["provenance"] = collect_provenance(
            args.repo_root,
            args.editor,
            args.console_log,
            args.engine_log,
            args.expected,
            Path(__file__),
            runner_result_sha256,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        add_unique(errors, f"Unable to collect git/editor/log/manifest/validator provenance: {exc}")
    else:
        engine_hash = str(engine.get("hash", ""))
        git_head = str(result["provenance"].get("git_head", ""))
        if not engine_hash or engine_hash != git_head:
            add_unique(
                errors,
                f"Runtime Engine.hash must exactly match provenance git_head (engine={engine_hash!r}, git={git_head!r}).",
            )
    phase2_cpu_gpu_golden: dict[str, Any] = {"status": "unavailable", "digest": []}

    if args.scenario == "phase1_fresh":
        if args.cpu_reference is None or not args.cpu_reference.is_file():
            add_unique(errors, "Phase 1 requires a completed --cpu-reference JSON from phase1_reference.py.")
        else:
            try:
                cpu_reference = json.loads(args.cpu_reference.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                add_unique(errors, f"Unable to read Phase 1 CPU reference result: {exc}")
            else:
                raw_cpu_cases = cpu_reference.get("cases", [])
                cpu_cases = raw_cpu_cases if isinstance(raw_cpu_cases, list) else []
                cpu_failures = [
                    case
                    for case in cpu_cases
                    if not isinstance(case, dict) or case.get("status") != "passed"
                ]
                expected_cpu_case_names = {
                    "fixed_shader_random_stream",
                    "shader_contract_alignment",
                    "cosine_warp_and_pdf",
                    "constant_environment_and_radiometry",
                    "nonconstant_integrand_and_candidate_invariance",
                    "visibility_and_sky_miss",
                }
                cpu_valid = (
                    cpu_reference.get("suite") == "hddagi_screen_probe_phase1_cpu_reference"
                    and cpu_reference.get("status") == "completed"
                    and cpu_reference.get("precision")
                    == "Python binary64 estimator with explicit GLSL float32 random-stream rounding"
                    and safe_int(cpu_reference.get("failure_count"), -1) == 0
                    and safe_int(cpu_reference.get("frames_per_monte_carlo_case"), 0) >= 65_536
                    and cpu_reference.get("candidate_counts") == [1, 2, 4, 8]
                    and len(cpu_cases) == len(expected_cpu_case_names)
                    and {
                        case.get("name") for case in cpu_cases if isinstance(case, dict)
                    }
                    == expected_cpu_case_names
                    and not cpu_failures
                )
                if not cpu_valid:
                    add_unique(errors, "Phase 1 CPU reference result did not satisfy the complete six-case, 65,536-frame contract.")
                result["cpu_reference"] = {
                    "status": "passed" if cpu_valid else "failed",
                    "path": str(args.cpu_reference.resolve()),
                    "sha256": hashlib.sha256(args.cpu_reference.read_bytes()).hexdigest(),
                    "suite": cpu_reference.get("suite"),
                    "precision": cpu_reference.get("precision"),
                    "frames_per_monte_carlo_case": cpu_reference.get("frames_per_monte_carlo_case"),
                    "candidate_counts": cpu_reference.get("candidate_counts"),
                    "case_count": len(cpu_cases),
                    "failure_count": cpu_reference.get("failure_count"),
                    "case_statuses": {
                        case.get("name", "unnamed"): case.get("status")
                        for case in cpu_cases
                        if isinstance(case, dict)
                    },
                }
    elif args.scenario == "phase2_temporal":
        if args.cpu_reference is None or not args.cpu_reference.is_file():
            add_unique(errors, "Phase 2 requires a completed --cpu-reference JSON from phase2_reference.py.")
        else:
            try:
                cpu_reference = json.loads(args.cpu_reference.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                add_unique(errors, f"Unable to read Phase 2 CPU reference result: {exc}")
            else:
                raw_cpu_cases = cpu_reference.get("cases", [])
                cpu_cases = raw_cpu_cases if isinstance(raw_cpu_cases, list) else []
                case_statuses = {
                    str(case.get("name", "unnamed")): case.get("status")
                    for case in cpu_cases
                    if isinstance(case, dict)
                }
                required_case_names = {
                    "fixed_float32_stream",
                    "packing_round_trip",
                    "stream_permutation_and_compression",
                    "fresh_vector_ris",
                    "temporal_merge_and_m_cap",
                    "hit_and_sky_jacobians",
                    "rejection_and_version_contract",
                    "thousand_frame_finite_stress",
                    "jitter_neutral_reprojection_and_history_footprint",
                }
                missing_or_failed_cases = sorted(
                    name for name in required_case_names if case_statuses.get(name) != "passed"
                )
                phase2_cpu_gpu_golden, gpu_golden_failures = parse_phase2_cpu_gpu_golden(
                    cpu_reference
                )
                cpu_valid = (
                    cpu_reference.get("suite") == "hddagi_screen_probe_phase2_cpu_reference"
                    and cpu_reference.get("schema_version") == "2.5.0"
                    and cpu_reference.get("status") == "completed"
                    and safe_int(cpu_reference.get("algorithm_version"), -1) == 2
                    and safe_int(cpu_reference.get("failure_count"), -1) == 0
                    and safe_int(cpu_reference.get("trials_per_fresh_candidate_count"), 0) >= 65_536
                    and safe_int(cpu_reference.get("stress_frames"), 0) >= 1_000
                    and cpu_reference.get("candidate_counts") == [1, 2, 4, 8]
                    and not missing_or_failed_cases
                    and all(status == "passed" for status in case_statuses.values())
                    and not gpu_golden_failures
                )
                if not cpu_valid:
                    add_unique(
                        errors,
                        "Phase 2 CPU reference did not satisfy the deterministic float32/packing/stream-equivalence/RIS/temporal/Jacobian/reprojection/2x2-footprint/rejection/1000-frame contract.",
                    )
                result["cpu_reference"] = {
                    "status": "passed" if cpu_valid else "failed",
                    "path": str(args.cpu_reference.resolve()),
                    "sha256": hashlib.sha256(args.cpu_reference.read_bytes()).hexdigest(),
                    "suite": cpu_reference.get("suite"),
                    "schema_version": cpu_reference.get("schema_version"),
                    "precision": cpu_reference.get("precision"),
                    "algorithm_version": cpu_reference.get("algorithm_version"),
                    "trials_per_fresh_candidate_count": cpu_reference.get(
                        "trials_per_fresh_candidate_count"
                    ),
                    "stress_frames": cpu_reference.get("stress_frames"),
                    "candidate_counts": cpu_reference.get("candidate_counts"),
                    "case_count": len(cpu_cases),
                    "failure_count": cpu_reference.get("failure_count"),
                    "required_case_names": sorted(required_case_names),
                    "missing_or_failed_required_cases": missing_or_failed_cases,
                    "case_statuses": case_statuses,
                    "gpu_reservoir_golden": phase2_cpu_gpu_golden,
                }

    for missing_log in missing_logs:
        add_unique(errors, f"Required post-exit log does not exist: {missing_log}")

    if args.editor_exit_code != 0:
        add_unique(errors, f"Godot editor exited with code {args.editor_exit_code}.")
    console_errors = [line[line.find("ERROR:") :] for line in console_lines if "ERROR:" in line]
    engine_errors = [line[line.find("ERROR:") :] for line in engine_lines if "ERROR:" in line]
    if console_errors:
        add_unique(errors, f"Complete console log contains {len(console_errors)} ERROR line(s).")
    if engine_errors:
        add_unique(errors, f"Complete engine log contains {len(engine_errors)} ERROR line(s).")
    result["post_exit_runtime_log"] = {
        "console_log": str(args.console_log.resolve()),
        "engine_log": str(args.engine_log.resolve()),
        "console_error_count": len(console_errors),
        "engine_error_count": len(engine_errors),
        "unique_console_errors": sorted(set(console_errors))[:20],
        "unique_engine_errors": sorted(set(engine_errors))[:20],
        "complete_after_process_exit": True,
    }

    snapshots, malformed_counter_payloads = parse_counters(console_lines)
    for malformed_payload in malformed_counter_payloads:
        add_unique(errors, f"Counter validation: {malformed_payload}")
    manifest_fields = manifest.get("counter_fields", [])
    required_fields: list[str] = list(manifest_fields) if isinstance(manifest_fields, list) else []
    if not required_fields:
        matching_profiles = [
            profile
            for profile in manifest.get("profiles", [])
            if isinstance(profile, dict)
            and not profile_mismatches(profile, result, args.scenario)
        ]
        if len(matching_profiles) == 1:
            legacy_profile_fields = matching_profiles[0].get("required", {}).get(
                "counter_fields", []
            )
            if isinstance(legacy_profile_fields, list):
                required_fields = list(legacy_profile_fields)
    if not required_fields:
        add_unique(
            errors,
            "expected_metrics manifest defined neither a canonical counter_fields schema nor one unambiguous matching-profile schema.",
        )
    resolution = result.get("resolution", {})
    counter_failures = validate_counter_semantics(
        snapshots,
        required_fields,
        args.scenario,
        safe_int(resolution.get("width"), 0),
        safe_int(resolution.get("height"), 0),
        safe_int(resolution.get("view_count"), 0),
        result.get("phase2_configuration", {}),
    )
    for failure in counter_failures:
        add_unique(errors, f"Counter validation: {failure}")
    result["debug_counters"] = {
        "enabled": True,
        "marker": COUNTER_MARKER.strip(),
        "source_log": str(args.console_log.resolve()),
        "required_fields": required_fields,
        "snapshots": snapshots,
        "snapshot_count": len(snapshots),
        "malformed_payload_count": len(malformed_counter_payloads),
        "malformed_payloads": malformed_counter_payloads,
        "schema_valid": not malformed_counter_payloads
        and not any("missing fields" in failure for failure in counter_failures),
        "semantic_validation": {
            "status": "passed" if not counter_failures else "failed",
            "failures": counter_failures,
        },
        "complete_after_process_exit": True,
    }
    if args.scenario == "phase1_fresh":
        try:
            raw_hdr_summary = summarize_phase1_raw_hdr(snapshots)
        except (KeyError, TypeError, ValueError, ZeroDivisionError) as exc:
            raw_hdr_summary = {
                "status": "failed",
                "failures": [f"raw HDR summary could not be derived: {exc}"],
            }
        result["debug_counters"]["phase1_raw_hdr_reference"] = raw_hdr_summary
        if raw_hdr_summary["status"] != "passed":
            add_unique(
                errors,
                "Phase 1 raw HDR analytic reduction failed: "
                + "; ".join(raw_hdr_summary.get("failures", ["unknown raw HDR failure"])),
            )
    elif args.scenario == "phase2_temporal":
        phase2_summary = summarize_phase2_counters(snapshots)
        result["debug_counters"]["phase2_temporal"] = phase2_summary
        if phase2_summary["status"] != "passed":
            add_unique(
                errors,
                "Phase 2 fixed-ray-budget counter summary lacked steady P1-N2 or P2-N1+visibility snapshots.",
            )
        gpu_golden_summary, gpu_golden_failures = validate_phase2_gpu_golden_snapshots(
            snapshots,
            list(phase2_cpu_gpu_golden.get("digest", [])),
        )
        result["debug_counters"]["phase2_gpu_reservoir_golden"] = gpu_golden_summary
        if gpu_golden_failures:
            add_unique(
                errors,
                "Phase 2 GPU reservoir/CPU deterministic-stream conformance failed: "
                + "; ".join(gpu_golden_failures),
            )
        result_frames = result.get("frames", {})
        phase2_raw_hdr_summary, phase2_raw_hdr_failures = (
            summarize_phase2_raw_hdr_pre_tonemap(
                snapshots,
                safe_int(result_frames.get("warmup"), 0),
                safe_int(result_frames.get("sample"), 0),
            )
        )
        result["debug_counters"]["phase2_raw_hdr_pre_tonemap"] = phase2_raw_hdr_summary
        for failure in phase2_raw_hdr_failures:
            add_unique(errors, f"Phase 2 pre-tonemap raw HDR comparison failed: {failure}")
        dynamic_summary, dynamic_failures = validate_phase2_dynamic_convergence(result)
        result["phase2_dynamic_convergence_validation"] = dynamic_summary
        if dynamic_failures:
            add_unique(
                errors,
                "Phase 2 dynamic convergence post-exit recomputation failed: "
                + "; ".join(dynamic_failures),
            )

    result["gpu_profile"] = parse_gpu_profile(console_lines)
    if args.scenario in ("all", "phase1_fresh", "phase2_temporal") and result["gpu_profile"]["hddagi_sample_count"] == 0:
        add_unique(errors, "Complete --gpu-profile log contained no HDDAGI Screen Probe/NRD task sample.")
    if args.scenario == "phase1_fresh" and not any(
        "HDDAGI Screen Probe Fresh Trace" in task_name
        for task_name in result["gpu_profile"]["task_summaries_ms"]
    ):
        add_unique(errors, "Phase 1 GPU profile contained no HDDAGI Screen Probe Fresh Trace marker.")
    if args.scenario == "phase1_fresh":
        stable_profile = result["gpu_profile"].get("phase1_stable_candidate_samples", {})
        if safe_int(stable_profile.get("candidate_segment_coverage_count"), 0) != 4:
            add_unique(
                errors,
                "Phase 1 GPU profile did not provide four candidate sample segments whose "
                "retained blocks contain Surface Select, Fresh Trace, and Raw Resolve with no unexpected HDDAGI task.",
            )
    if args.scenario == "phase2_temporal":
        observed_profile_tasks = result["gpu_profile"]["task_summaries_ms"]
        for marker in (
            "HDDAGI Screen Probe Phase 2 Fresh Reservoir",
            "HDDAGI Screen Probe Phase 2 Temporal Stream Merge",
            "HDDAGI NRD Guide Preparation",
        ):
            if marker not in observed_profile_tasks:
                add_unique(errors, f"Phase 2 GPU profile contained no {marker} marker.")
        stable_phase2_profile = result["gpu_profile"].get(
            "phase2_stable_temporal_samples", {}
        )
        if safe_int(stable_phase2_profile.get("segment_coverage_count"), 0) != 2:
            add_unique(
                errors,
                "Phase 2 GPU profile did not provide stable constant and colored sample segments with the exact P2 task contract.",
            )

    renderer = result.get("renderer", {})
    if renderer.get("rendering_method") != "forward_plus":
        add_unique(errors, "QA requires RenderingServer rendering_method=forward_plus.")
    if str(renderer.get("rendering_driver", "")).lower() != "vulkan":
        add_unique(errors, "QA requires RenderingServer rendering_driver=vulkan.")
    width = safe_int(result.get("resolution", {}).get("width"), 0)
    height = safe_int(result.get("resolution", {}).get("height"), 0)
    if width <= 0 or height <= 0:
        add_unique(errors, "Result resolution must be positive.")
    for failure in validate_image_dimensions(result.get("scenarios", {}), width, height):
        add_unique(errors, f"Image validation: {failure}")

    for scenario_name, scenario in result.get("scenarios", {}).items():
        checks = scenario.get("checks")
        if not isinstance(checks, dict):
            add_unique(errors, f"Scenario {scenario_name} did not report checks.")
            continue
        for check_name, passed in checks.items():
            if passed is not True:
                add_unique(errors, f"Scenario check failed: {scenario_name}.{check_name}")
    if args.scenario == "all":
        required_scenarios = {"baseline", "motion", "feature_off_toggle"}
        missing_scenarios = required_scenarios - set(result.get("scenarios", {}))
        for missing_scenario in sorted(missing_scenarios):
            add_unique(errors, f"Full suite did not execute scenario: {missing_scenario}")

    memory = result.get("memory", {})
    memory_snapshots = memory.get("snapshots", [])
    if args.scenario == "all" and not memory_snapshots:
        add_unique(errors, "Full suite did not record RenderingServer memory snapshots.")
    if memory_snapshots:
        for field in MEMORY_FIELDS:
            if max(safe_int(snapshot.get(field), 0) for snapshot in memory_snapshots) <= 0:
                add_unique(errors, f"RenderingServer memory field {field} never reported a positive value.")
    if args.scenario == "all":
        required_labels = {
            "feature_off_toggle/probes_on_experimental_off",
            "feature_off_toggle/screen_probes_disabled",
            "feature_off_toggle/probes_on_experimental_on",
            "feature_off_toggle/recovered_experimental_off",
        }
        observed_labels = {snapshot.get("label") for snapshot in memory_snapshots}
        for missing_label in sorted(required_labels - observed_labels):
            add_unique(errors, f"Missing memory snapshot: {missing_label}")

    runtime_error_count = len(console_errors) + len(engine_errors)
    expected_validation, expected_failures = validate_expected_metrics(
        manifest, result, args.scenario, runtime_error_count
    )
    result["expected_metrics_validation"] = expected_validation
    for failure in expected_failures:
        add_unique(errors, f"Expected metrics: {failure}")

    result["errors"] = errors
    result["warnings"] = warnings
    result["status"] = "failed" if errors else "completed"
    result["post_run_validation"] = {
        "status": "failed" if errors else "passed",
        "completed_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "validator": "validate_result.py",
        "error_count": len(errors),
    }
    temporary = args.result.with_suffix(args.result.suffix + ".tmp")
    temporary.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(temporary, args.result)
    print(
        "HDDAGI_QA_POST_VALIDATION "
        + json.dumps(
            {
                "status": result["post_run_validation"]["status"],
                "errors": len(errors),
                "counter_snapshots": len(snapshots),
                "gpu_profile_samples": result["gpu_profile"]["hddagi_sample_count"],
                "expected_profile": expected_validation.get("profile_id", expected_validation["status"]),
            },
            separators=(",", ":"),
        )
    )
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())

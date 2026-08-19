#!/usr/bin/env python3
"""Post-exit validator for the portable HDDAGI screen-probe Phase 3 smoke."""

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

import validate_result as shared


RESULT_SCHEMA_VERSION = "1.0.0"
MANIFEST_SCHEMA_VERSION = "3.0.0"
CPU_SCHEMA_VERSION = "3.0.0"
SUITE_NAME = "hddagi_screen_probe_phase3_spatial_restir_smoke"
SCENARIO_NAME = "phase3_spatial"
ALGORITHM_MODE = 4
ALGORITHM_NAME = "phase3_spatial_restir"

NON_INTEGER_COUNTER_FIELDS = {"algorithm", "qa_segment"}
UINT32_COUNTER_FIELDS = (
    "fresh_candidates",
    "temporal_guided_candidates",
    "spatial_guided_candidates",
    "hdda_rays",
    "hdda_steps",
    "hdda_hits",
    "hdda_misses",
    "sharc_query_attempts",
    "sharc_query_hits",
    "sharc_query_ineligible",
    "sharc_query_misses",
    "sharc_update_rays",
    "sharc_update_misses",
    "sharc_update_rejects",
    "raw_hdr_nonfinite_or_overflow",
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
    "reservoir_gpu_zero_target_branch_golden",
    "spatial_streams",
    "spatial_accepted",
    "spatial_edge_rejected",
    "spatial_identity_rejected",
    "spatial_visibility_rays",
    "spatial_visibility_visible",
    "spatial_visibility_occluded",
    "spatial_m_cap_applied",
    "spatial_zero_target_mass_only",
    "spatial_selected_center",
    "spatial_selected_neighbor",
    "spatial_nonfinite",
    "spatial_max_m",
)
NONFINITE_COUNTER_FIELDS = (
    "raw_hdr_nonfinite_or_overflow",
    "reservoir_nonfinite",
    "reservoir_packing_invalid",
    "spatial_nonfinite",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--result", required=True, type=Path)
    parser.add_argument("--console-log", required=True, type=Path)
    parser.add_argument("--engine-log", required=True, type=Path)
    parser.add_argument("--expected", required=True, type=Path)
    parser.add_argument("--cpu-reference", required=True, type=Path)
    parser.add_argument("--editor", required=True, type=Path)
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--editor-exit-code", required=True, type=int)
    return parser.parse_args()


def add_failure(failures: list[str], message: str) -> None:
    if message not in failures:
        failures.append(message)


def validate_cpu_reference(path: Path) -> tuple[dict[str, Any], list[str]]:
    failures: list[str] = []
    summary: dict[str, Any] = {"status": "failed", "path": str(path.resolve())}
    if not path.is_file():
        return summary, ["Phase 3 CPU reference JSON does not exist."]
    try:
        result = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return summary, [f"Unable to read Phase 3 CPU reference: {exc}"]

    raw_cases = result.get("cases", [])
    cases = raw_cases if isinstance(raw_cases, list) else []
    case_statuses = {
        str(case.get("name", "unnamed")): case.get("status")
        for case in cases
        if isinstance(case, dict)
    }
    required_cases = {
        "fixed_center_uniform_unique_neighbors",
        "uniform_neighbor_proposal_trials",
        "spatial_m_cap_and_invalid_mapping",
        "visibility_and_zero_target_preserve_m",
        "hit_and_sky_jacobians",
        "stream_permutation_and_compression",
        "thousand_frame_finite_stress",
    }
    invalid_cases = sorted(
        name for name in required_cases if case_statuses.get(name) != "passed"
    )
    valid = (
        result.get("suite") == "hddagi_screen_probe_phase3_cpu_reference"
        and result.get("schema_version") == CPU_SCHEMA_VERSION
        and result.get("status") == "completed"
        and result.get("acceptance_ready") is True
        and shared.safe_int(result.get("algorithm_version"), -1) == 3
        and shared.safe_int(result.get("failure_count"), -1) == 0
        and shared.safe_int(result.get("trials_per_uniform_neighbor_proposal"), 0)
        >= 65_536
        and shared.safe_int(result.get("stress_frames"), 0) >= 1_000
        and not invalid_cases
        and len(case_statuses) == len(required_cases)
    )
    if not valid:
        failures.append(
            "Phase 3 CPU reference did not satisfy schema 3.0.0, seven passed cases, "
            "65,536 proposal trials, and 1,000 stress frames."
        )
    summary.update(
        {
            "status": "passed" if valid else "failed",
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "suite": result.get("suite"),
            "schema_version": result.get("schema_version"),
            "algorithm_version": result.get("algorithm_version"),
            "acceptance_ready": result.get("acceptance_ready"),
            "trials": result.get("trials_per_uniform_neighbor_proposal"),
            "stress_frames": result.get("stress_frames"),
            "case_count": len(case_statuses),
            "case_statuses": case_statuses,
            "missing_or_failed_required_cases": invalid_cases,
        }
    )
    return summary, failures


def sum_counter(snapshots: list[dict[str, Any]], field: str) -> int:
    return sum(shared.safe_int(snapshot.get(field), 0) for snapshot in snapshots)


def validate_counters(
    snapshots: list[dict[str, Any]],
    malformed: list[str],
    manifest: dict[str, Any],
    result: dict[str, Any],
) -> tuple[dict[str, Any], list[str]]:
    failures: list[str] = []
    required_fields = manifest.get("counter_fields", [])
    if not isinstance(required_fields, list) or not required_fields:
        return {"status": "failed"}, ["Phase 3 manifest counter_fields must be a non-empty list."]
    for message in malformed:
        add_failure(failures, f"Malformed counter stream: {message}")

    resolution = result.get("resolution", {})
    expected_width = shared.safe_int(resolution.get("width"), -1)
    expected_height = shared.safe_int(resolution.get("height"), -1)
    expected_views = shared.safe_int(resolution.get("view_count"), -1)
    for index, snapshot in enumerate(snapshots):
        missing = [field for field in required_fields if field not in snapshot]
        if missing:
            add_failure(
                failures,
                f"counter snapshot {index} is missing fields: {', '.join(missing)}",
            )
            continue
        for field in required_fields:
            if field not in NON_INTEGER_COUNTER_FIELDS and shared.exact_int(snapshot.get(field)) is None:
                add_failure(failures, f"counter snapshot {index}: {field} must be an exact integer")
        for field in UINT32_COUNTER_FIELDS:
            value = shared.safe_int(snapshot.get(field), -1)
            if value < 0 or value > 0xFFFFFFFF:
                add_failure(failures, f"counter snapshot {index}: {field} must be uint32")
        if shared.safe_int(snapshot.get("width"), -1) != expected_width:
            add_failure(failures, f"counter snapshot {index}: width does not match the result")
        if shared.safe_int(snapshot.get("height"), -1) != expected_height:
            add_failure(failures, f"counter snapshot {index}: height does not match the result")
        if shared.safe_int(snapshot.get("view_count"), -1) != expected_views:
            add_failure(failures, f"counter snapshot {index}: view_count does not match the result")
        if (
            shared.safe_int(snapshot.get("algorithm_mode"), -1) != ALGORITHM_MODE
            or snapshot.get("algorithm") != ALGORITHM_NAME
        ):
            add_failure(
                failures,
                f"counter snapshot {index}: expected algorithm_mode={ALGORITHM_MODE}, "
                f"algorithm={ALGORITHM_NAME}",
            )
        feature_flags = shared.safe_int(snapshot.get("feature_flags"), -1)
        if feature_flags not in (65, 67):
            add_failure(
                failures,
                f"counter snapshot {index}: unexpected Phase 3 feature_flags={feature_flags}",
            )
        rays = shared.safe_int(snapshot.get("hdda_rays"), -1)
        hits = shared.safe_int(snapshot.get("hdda_hits"), -1)
        misses = shared.safe_int(snapshot.get("hdda_misses"), -1)
        if hits + misses != rays:
            add_failure(failures, f"counter snapshot {index}: hdda hit/miss conservation failed")
        query_attempts = shared.safe_int(snapshot.get("sharc_query_attempts"), -1)
        query_hits = shared.safe_int(snapshot.get("sharc_query_hits"), -1)
        query_ineligible = shared.safe_int(snapshot.get("sharc_query_ineligible"), -1)
        query_misses = shared.safe_int(snapshot.get("sharc_query_misses"), -1)
        if query_attempts != query_hits + query_ineligible + query_misses:
            add_failure(
                failures,
                f"counter snapshot {index}: SHARC query outcome conservation failed",
            )
        if query_attempts > hits:
            add_failure(failures, f"counter snapshot {index}: SHARC query attempts exceed HDDA hits")
        update_rays = shared.safe_int(snapshot.get("sharc_update_rays"), -1)
        update_misses = shared.safe_int(snapshot.get("sharc_update_misses"), -1)
        update_rejects = shared.safe_int(snapshot.get("sharc_update_rejects"), -1)
        if update_rays > rays:
            add_failure(failures, f"counter snapshot {index}: SHARC update rays exceed HDDA rays")
        if update_misses + update_rejects > update_rays:
            add_failure(
                failures,
                f"counter snapshot {index}: SHARC update outcome count exceeds update rays",
            )
        if update_misses > misses:
            add_failure(failures, f"counter snapshot {index}: SHARC update misses exceed HDDA misses")
        if update_rejects > hits:
            add_failure(failures, f"counter snapshot {index}: SHARC update rejects exceed HDDA hits")
        expected_rays = (
            shared.safe_int(snapshot.get("fresh_candidates"), -1)
            + shared.safe_int(snapshot.get("reservoir_visibility_rays"), -1)
            + shared.safe_int(snapshot.get("spatial_visibility_rays"), -1)
            + update_rays
        )
        if rays != expected_rays:
            add_failure(
                failures,
                f"counter snapshot {index}: hdda_rays must equal fresh + temporal visibility + spatial visibility + SHARC update rays",
            )
        if shared.safe_int(snapshot.get("fresh_candidates"), 0) <= 0:
            add_failure(failures, f"counter snapshot {index}: fresh candidates must be active")
        if (
            shared.safe_int(snapshot.get("reservoir_visibility_visible"), -1)
            + shared.safe_int(snapshot.get("reservoir_visibility_occluded"), -1)
            != shared.safe_int(snapshot.get("reservoir_visibility_rays"), -1)
        ):
            add_failure(failures, f"counter snapshot {index}: temporal visibility conservation failed")
        if (
            shared.safe_int(snapshot.get("spatial_visibility_visible"), -1)
            + shared.safe_int(snapshot.get("spatial_visibility_occluded"), -1)
            != shared.safe_int(snapshot.get("spatial_visibility_rays"), -1)
        ):
            add_failure(failures, f"counter snapshot {index}: spatial visibility conservation failed")
        for field in NONFINITE_COUNTER_FIELDS:
            if shared.safe_int(snapshot.get(field), -1) != 0:
                add_failure(failures, f"counter snapshot {index}: {field} must be zero")
        for field in ("temporal_guided_candidates", "spatial_guided_candidates"):
            if shared.safe_int(snapshot.get(field), -1) != 0:
                add_failure(
                    failures,
                    f"counter snapshot {index}: legacy {field} must remain zero on the isolated P3 route",
                )

    minimum_per_segment = shared.safe_int(
        manifest.get("minimum_counter_snapshots_per_sample_segment"), 1
    )
    segment_summaries: dict[str, Any] = {}
    temporal_modes: set[bool] = set()
    all_segments_active = True
    all_temporal_contracts = True
    for specification in manifest.get("required_sample_segments", []):
        if not isinstance(specification, dict):
            add_failure(failures, "Phase 3 manifest contains a non-object sample segment specification.")
            continue
        segment = str(specification.get("segment", ""))
        label = str(specification.get("label", segment))
        temporal = specification.get("temporal") is True
        expected_flags = shared.safe_int(specification.get("feature_flags"), -1)
        temporal_modes.add(temporal)
        selected = [
            snapshot for snapshot in snapshots if snapshot.get("qa_segment") == segment
        ]
        if len(selected) < minimum_per_segment:
            add_failure(
                failures,
                f"sample segment {segment!r} captured {len(selected)} counters; expected at least {minimum_per_segment}",
            )
        if any(shared.safe_int(item.get("feature_flags"), -1) != expected_flags for item in selected):
            add_failure(failures, f"sample segment {segment!r} used the wrong feature flags")

        aggregate = {field: sum_counter(selected, field) for field in UINT32_COUNTER_FIELDS}
        core_active = (
            aggregate["spatial_streams"] > 0
            and aggregate["spatial_accepted"] > 0
            and aggregate["spatial_visibility_rays"] > 0
            and aggregate["spatial_selected_center"]
            + aggregate["spatial_selected_neighbor"]
            > 0
            and max(
                (shared.safe_int(item.get("spatial_max_m"), 0) for item in selected),
                default=0,
            )
            > 0
        )
        if not core_active:
            all_segments_active = False
            add_failure(failures, f"sample segment {segment!r} did not exercise the core P3 spatial counters")

        if temporal:
            temporal_contract = (
                aggregate["reservoir_temporal_attempts"] > 0
                and aggregate["reservoir_visibility_rays"] > 0
            )
        else:
            temporal_contract = all(
                aggregate[field] == 0
                for field in (
                    "reservoir_temporal_attempts",
                    "reservoir_temporal_accepted",
                    "reservoir_visibility_rays",
                    "reservoir_visibility_visible",
                    "reservoir_visibility_occluded",
                )
            )
        if not temporal_contract:
            all_temporal_contracts = False
            add_failure(failures, f"sample segment {segment!r} violated its temporal on/off contract")

        segment_summaries[label] = {
            "segment": segment,
            "temporal": temporal,
            "feature_flags": expected_flags,
            "snapshot_count": len(selected),
            "core_spatial_active": core_active,
            "temporal_contract_passed": temporal_contract,
            "aggregates": aggregate,
        }

    checks = {
        "algorithm_is_phase3_spatial_restir": bool(snapshots)
        and all(
            shared.safe_int(snapshot.get("algorithm_mode"), -1) == ALGORITHM_MODE
            and snapshot.get("algorithm") == ALGORITHM_NAME
            for snapshot in snapshots
        ),
        "all_required_sample_segments_captured": len(segment_summaries)
        == len(manifest.get("required_sample_segments", []))
        and all(
            shared.safe_int(summary.get("snapshot_count"), 0) >= minimum_per_segment
            for summary in segment_summaries.values()
        ),
        "core_spatial_counters_active_in_every_configuration": all_segments_active,
        "temporal_on_and_off_counter_contracts_passed": all_temporal_contracts
        and temporal_modes == {False, True},
        "all_nonfinite_counters_are_zero": all(
            shared.safe_int(snapshot.get(field), -1) == 0
            for snapshot in snapshots
            for field in NONFINITE_COUNTER_FIELDS
        ),
    }
    for name, passed in checks.items():
        if not passed:
            add_failure(failures, f"Phase 3 counter check failed: {name}")
    return (
        {
            "status": "passed" if not failures else "failed",
            "snapshot_count": len(snapshots),
            "malformed_payload_count": len(malformed),
            "required_fields": required_fields,
            "checks": checks,
            "segments": segment_summaries,
        },
        failures,
    )


def validate_gpu_profile(
    lines: list[str], manifest: dict[str, Any]
) -> tuple[dict[str, Any], list[str]]:
    profile = shared.parse_gpu_profile(lines)
    failures: list[str] = []
    observed_tasks = set(profile.get("task_summaries_ms", {}))
    for marker in manifest.get("required_gpu_task_markers", []):
        if not any(str(marker) in task for task in observed_tasks):
            add_failure(failures, f"GPU profile did not observe required task marker: {marker}")
    for marker in manifest.get("forbidden_gpu_task_markers", []):
        matching = sorted(task for task in observed_tasks if str(marker) in task)
        if matching:
            add_failure(
                failures,
                f"GPU profile observed forbidden obsolete marker {marker!r}: {matching}",
            )
    if shared.safe_int(profile.get("profile_block_count"), 0) < shared.safe_int(
        manifest.get("minimum_gpu_profile_blocks"), 1
    ):
        add_failure(failures, "GPU profile block count is below the Phase 3 smoke minimum.")
    if shared.safe_int(profile.get("hddagi_sample_count"), 0) <= 0:
        add_failure(failures, "GPU profile contained no HDDAGI task samples.")
    profile["phase3_smoke_validation"] = {
        "status": "passed" if not failures else "failed",
        "required_task_markers": manifest.get("required_gpu_task_markers", []),
        "forbidden_task_markers": manifest.get("forbidden_gpu_task_markers", []),
        "failures": failures,
    }
    return profile, failures


def main() -> int:
    args = parse_args()
    required_files = (args.result, args.console_log, args.engine_log, args.expected)
    missing_files = [path for path in required_files if not path.is_file()]
    if missing_files:
        for path in missing_files:
            print(f"Phase 3 QA validator: required file does not exist: {path}", file=sys.stderr)
        return 1

    runner_bytes = args.result.read_bytes()
    try:
        result = json.loads(runner_bytes.decode("utf-8"))
        manifest = json.loads(args.expected.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError, OSError) as exc:
        print(f"Phase 3 QA validator: unable to read JSON input: {exc}", file=sys.stderr)
        return 1

    preserved = result.get("post_validation_input")
    runner_sha256 = hashlib.sha256(runner_bytes).hexdigest()
    if isinstance(preserved, dict):
        errors = list(preserved.get("errors", []))
        warnings = list(preserved.get("warnings", []))
        result["status"] = preserved.get("status", result.get("status"))
        runner_sha256 = str(
            preserved.get("runner_result_sha256_before_post_validation", runner_sha256)
        )
    else:
        errors = list(result.get("errors", []))
        warnings = list(result.get("warnings", []))
        result["post_validation_input"] = {
            "status": result.get("status"),
            "errors": list(errors),
            "warnings": list(warnings),
            "runner_result_sha256_before_post_validation": runner_sha256,
        }

    if result.get("schema_version") != RESULT_SCHEMA_VERSION:
        add_failure(errors, f"Runner result schema must be {RESULT_SCHEMA_VERSION}.")
    if result.get("suite") != SUITE_NAME:
        add_failure(errors, f"Runner suite must be {SUITE_NAME}.")
    if manifest.get("schema_version") != MANIFEST_SCHEMA_VERSION:
        add_failure(errors, f"Phase 3 smoke manifest schema must be {MANIFEST_SCHEMA_VERSION}.")
    if manifest.get("suite") != SUITE_NAME:
        add_failure(errors, "Phase 3 smoke manifest suite does not match the runner.")
    if manifest.get("acceptance_ready") is not True:
        add_failure(errors, "Phase 3 smoke manifest is not marked acceptance_ready.")
    if result.get("status") != "completed":
        add_failure(errors, "Phase 3 runner did not complete successfully.")
    scenarios = result.get("scenarios", {})
    scenario = scenarios.get(SCENARIO_NAME, {}) if isinstance(scenarios, dict) else {}
    if not isinstance(scenario, dict) or not scenario:
        add_failure(errors, f"Runner result did not contain scenario {SCENARIO_NAME!r}.")
    else:
        checks = scenario.get("checks", {})
        if not isinstance(checks, dict):
            add_failure(errors, "Phase 3 runner scenario did not emit checks.")
        else:
            for check_name in manifest.get("required_runner_checks", []):
                if checks.get(check_name) is not True:
                    add_failure(errors, f"Phase 3 runner check failed or is missing: {check_name}")

    if args.editor_exit_code != 0:
        add_failure(errors, f"Godot editor exited with code {args.editor_exit_code}.")
    console_lines = shared.read_lines(args.console_log)
    engine_lines = shared.read_lines(args.engine_log)
    console_errors = [line[line.find("ERROR:") :] for line in console_lines if "ERROR:" in line]
    engine_errors = [line[line.find("ERROR:") :] for line in engine_lines if "ERROR:" in line]
    if console_errors:
        add_failure(errors, f"Complete console log contains {len(console_errors)} ERROR line(s).")
    if engine_errors:
        add_failure(errors, f"Complete engine log contains {len(engine_errors)} ERROR line(s).")
    result["post_exit_runtime_log"] = {
        "console_log": str(args.console_log.resolve()),
        "engine_log": str(args.engine_log.resolve()),
        "console_error_count": len(console_errors),
        "engine_error_count": len(engine_errors),
        "unique_console_errors": sorted(set(console_errors))[:20],
        "unique_engine_errors": sorted(set(engine_errors))[:20],
        "complete_after_process_exit": True,
    }

    renderer = result.get("renderer", {})
    if renderer.get("rendering_method") != "forward_plus":
        add_failure(errors, "Phase 3 runtime smoke requires Forward+.")
    if str(renderer.get("rendering_driver", "")).lower() != "vulkan":
        add_failure(errors, "Phase 3 runtime smoke requires Vulkan.")
    width = shared.safe_int(result.get("resolution", {}).get("width"), 0)
    height = shared.safe_int(result.get("resolution", {}).get("height"), 0)
    if width <= 0 or height <= 0:
        add_failure(errors, "Phase 3 result resolution must be positive.")
    for failure in shared.validate_image_dimensions(scenarios, width, height):
        add_failure(errors, f"Image validation: {failure}")

    cpu_summary, cpu_failures = validate_cpu_reference(args.cpu_reference)
    result["cpu_reference"] = cpu_summary
    for failure in cpu_failures:
        add_failure(errors, failure)

    snapshots, malformed = shared.parse_counters(console_lines)
    counter_summary, counter_failures = validate_counters(
        snapshots, malformed, manifest, result
    )
    result["debug_counters"] = {
        "enabled": True,
        "marker": shared.COUNTER_MARKER.strip(),
        "source_log": str(args.console_log.resolve()),
        "snapshots": snapshots,
        "snapshot_count": len(snapshots),
        "schema_valid": not malformed
        and not any("missing fields" in failure for failure in counter_failures),
        "phase3_spatial": counter_summary,
        "complete_after_process_exit": True,
    }
    for failure in counter_failures:
        add_failure(errors, f"Counter validation: {failure}")

    gpu_profile, gpu_failures = validate_gpu_profile(console_lines, manifest)
    result["gpu_profile"] = gpu_profile
    for failure in gpu_failures:
        add_failure(errors, failure)

    engine = result.get("engine", {})
    for field in ("version", "hash", "build"):
        if not isinstance(engine.get(field), str) or not engine.get(field):
            add_failure(errors, f"Runner engine.{field} must be a non-empty string.")
    try:
        provenance = shared.collect_provenance(
            args.repo_root,
            args.editor,
            args.console_log,
            args.engine_log,
            args.expected,
            Path(__file__),
            runner_sha256,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        add_failure(errors, f"Unable to collect Phase 3 provenance: {exc}")
    else:
        result["provenance"] = provenance
        if str(engine.get("hash", "")) != str(provenance.get("git_head", "")):
            add_failure(
                errors,
                "Runtime Engine.hash must exactly match provenance git_head.",
            )

    result["phase3_smoke_validation"] = {
        "status": "failed" if errors else "passed",
        "scope": manifest.get("scope"),
        "error_count": len(errors),
        "completed_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "validator": "validate_phase3_result.py",
    }
    result["errors"] = errors
    result["warnings"] = warnings
    result["status"] = "failed" if errors else "completed"
    temporary = args.result.with_suffix(args.result.suffix + ".tmp")
    temporary.write_text(
        json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    os.replace(temporary, args.result)
    print(
        "HDDAGI_PHASE3_QA_POST_VALIDATION "
        + json.dumps(
            {
                "status": result["phase3_smoke_validation"]["status"],
                "errors": len(errors),
                "counter_snapshots": len(snapshots),
                "gpu_profile_samples": gpu_profile.get("hddagi_sample_count", 0),
            },
            separators=(",", ":"),
        )
    )
    if errors:
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

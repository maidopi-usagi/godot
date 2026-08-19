#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../../.." && pwd)"
godot_bin="${GODOT_BIN:-}"
scenario="${SCENARIO:-all}"
output="${OUTPUT:-$script_dir/qa-results/hddagi_screen_probe_qa.json}"
log="${COUNTER_LOG:-${output%.*}.log}"
engine_log="${ENGINE_LOG:-${output%.*}.engine.log}"
warmup="${WARMUP_FRAMES:-32}"
frames="${SAMPLE_FRAMES:-12}"
settle="${SETTLE_FRAMES:-24}"
stride="${SAMPLE_STRIDE:-2}"
phase1_long_frames="${PHASE1_LONG_FRAMES:-1000}"
phase2_long_frames="${PHASE2_LONG_FRAMES:-1000}"
expected_metrics="${EXPECTED_METRICS:-$script_dir/expected_metrics.json}"
cpu_reference="${CPU_REFERENCE:-}"

if [[ -z "$godot_bin" ]]; then
    godot_bin="$(find "$repo_root/bin" -maxdepth 1 -type f -name 'godot.*.editor*' ! -name '*.exe' | head -n 1 || true)"
fi
if [[ -z "$godot_bin" ]]; then
    echo "No editor binary found. Set GODOT_BIN to the current Godot editor binary." >&2
    exit 2
fi

mkdir -p "$(dirname -- "$output")" "$(dirname -- "$log")" "$(dirname -- "$engine_log")"
rm -f -- "$output" "$log" "$engine_log"

set +e
extra_arguments=()
if [[ "$scenario" == "phase1_fresh" ]]; then
    extra_arguments+=("--phase1-long-frames=$phase1_long_frames")
elif [[ "$scenario" == "phase2_temporal" ]]; then
    extra_arguments+=("--phase2-long-frames=$phase2_long_frames")
fi

"$godot_bin" --path "$script_dir" --log-file "$engine_log" --gpu-profile -- \
    "--scenario=$scenario" \
    "--output=$output" \
    "--warmup=$warmup" \
    "--frames=$frames" \
    "--settle=$settle" \
    "--sample-stride=$stride" \
    "--counter-log=$log" \
    "--gpu-profile-enabled" \
    "${extra_arguments[@]}" \
    2>&1 | tee "$log"
editor_exit="${PIPESTATUS[0]}"
set -e

set +e
validator_arguments=(
    "$script_dir/validate_result.py"
    --result "$output"
    --console-log "$log"
    --engine-log "$engine_log"
    --expected "$expected_metrics"
    --editor "$godot_bin"
    --repo-root "$repo_root"
    --scenario "$scenario"
    --editor-exit-code "$editor_exit"
)
if [[ -n "$cpu_reference" ]]; then
    validator_arguments+=(--cpu-reference "$cpu_reference")
fi
python3 "${validator_arguments[@]}"
validator_exit="$?"
set -e
exit "$validator_exit"

#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../../.." && pwd)"
godot_bin="${GODOT_BIN:-}"
cpu_output="${CPU_OUTPUT:-$script_dir/qa-results/phase3-cpu-reference.json}"
gpu_output="${OUTPUT:-$script_dir/qa-results/phase3-gpu-smoke.json}"
counter_log="${COUNTER_LOG:-${gpu_output%.*}.log}"
engine_log="${ENGINE_LOG:-${gpu_output%.*}.engine.log}"
expected="${EXPECTED_METRICS:-$script_dir/expected_phase3_smoke_metrics.json}"
cpu_trials="${CPU_TRIALS:-65536}"
cpu_stress_frames="${CPU_STRESS_FRAMES:-1000}"
warmup_frames="${WARMUP_FRAMES:-64}"
sample_frames="${SAMPLE_FRAMES:-128}"
sample_stride="${SAMPLE_STRIDE:-2}"
headless="${HEADLESS:-0}"

python3 "$script_dir/phase3_reference.py" \
    --trials "$cpu_trials" \
    --stress-frames "$cpu_stress_frames" \
    --json-output "$cpu_output"

if [[ -z "$godot_bin" ]]; then
    godot_bin="$(find "$repo_root/bin" -maxdepth 1 -type f -name 'godot.*.editor*' ! -name '*.exe' | head -n 1 || true)"
fi
if [[ -z "$godot_bin" ]]; then
    echo "No editor binary found. Set GODOT_BIN to the current Godot editor binary." >&2
    exit 2
fi

mkdir -p "$(dirname -- "$gpu_output")" "$(dirname -- "$counter_log")" "$(dirname -- "$engine_log")"
rm -f -- "$gpu_output" "$counter_log" "$engine_log"

godot_arguments=(
    --path "$script_dir"
    --log-file "$engine_log"
    --gpu-profile
)
if [[ "$headless" == "1" ]]; then
    godot_arguments+=(--headless)
fi
godot_arguments+=(
    res://phase3_qa_runner.tscn
    --
    --scenario=phase3_spatial
    "--output=$gpu_output"
    "--warmup=$warmup_frames"
    "--frames=$sample_frames"
    --settle=32
    "--sample-stride=$sample_stride"
    "--counter-log=$counter_log"
    --gpu-profile-enabled
)

set +e
"$godot_bin" "${godot_arguments[@]}" 2>&1 | tee "$counter_log"
editor_exit="${PIPESTATUS[0]}"
set -e

set +e
python3 "$script_dir/validate_phase3_result.py" \
    --result "$gpu_output" \
    --console-log "$counter_log" \
    --engine-log "$engine_log" \
    --expected "$expected" \
    --cpu-reference "$cpu_output" \
    --editor "$godot_bin" \
    --repo-root "$repo_root" \
    --editor-exit-code "$editor_exit"
validator_exit="$?"
set -e
exit "$validator_exit"

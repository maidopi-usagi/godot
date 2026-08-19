#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cpu_output="${CPU_OUTPUT:-$script_dir/qa-results/phase2-cpu-reference.json}"
gpu_output="${OUTPUT:-$script_dir/qa-results/phase2-gpu-acceptance.json}"
cpu_trials="${CPU_TRIALS:-65536}"
cpu_stress_frames="${CPU_STRESS_FRAMES:-1000}"

python3 "$script_dir/phase2_reference.py" \
    --trials "$cpu_trials" \
    --stress-frames "$cpu_stress_frames" \
    --json-output "$cpu_output"

SCENARIO=phase2_temporal \
OUTPUT="$gpu_output" \
EXPECTED_METRICS="$script_dir/expected_phase2_metrics.json" \
CPU_REFERENCE="$cpu_output" \
WARMUP_FRAMES="${WARMUP_FRAMES:-64}" \
SAMPLE_FRAMES="${SAMPLE_FRAMES:-128}" \
SETTLE_FRAMES="${SETTLE_FRAMES:-32}" \
SAMPLE_STRIDE="${SAMPLE_STRIDE:-2}" \
PHASE2_LONG_FRAMES="${PHASE2_LONG_FRAMES:-1000}" \
bash "$script_dir/run_qa.sh"

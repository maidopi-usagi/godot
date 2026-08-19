#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cpu_output="${CPU_OUTPUT:-$script_dir/qa-results/phase1-cpu-reference.json}"
gpu_output="${OUTPUT:-$script_dir/qa-results/phase1-gpu-acceptance.json}"
cpu_frames="${CPU_FRAMES:-65536}"

python3 "$script_dir/phase1_reference.py" \
    --frames "$cpu_frames" \
    --json-output "$cpu_output"

SCENARIO=phase1_fresh \
OUTPUT="$gpu_output" \
EXPECTED_METRICS="$script_dir/expected_phase1_metrics.json" \
CPU_REFERENCE="$cpu_output" \
WARMUP_FRAMES="${WARMUP_FRAMES:-64}" \
SAMPLE_FRAMES="${SAMPLE_FRAMES:-128}" \
SETTLE_FRAMES="${SETTLE_FRAMES:-32}" \
SAMPLE_STRIDE="${SAMPLE_STRIDE:-2}" \
PHASE1_LONG_FRAMES="${PHASE1_LONG_FRAMES:-1000}" \
bash "$script_dir/run_qa.sh"

#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# stage5-bench.sh — one-shot bench_serving.py runner for a deployed Stage 5 run.
#
# Pattern: run inside a kubectl exec in the prefill pod (sglang + all deps are
# already there) and point the bench at the LB service. Writes the raw JSON
# output + a SUMMARY.txt to results/stage5-p5en/<run>/<UTC-stamp>/.
#
# Usage:
#   scripts/stage5-bench.sh <run-id> <region> [rate] [num_prompts] [isl] [osl] [dataset]
#
# Defaults target the R1a sweet spot: rate=4 rps, 128 prompts, ISL=1024, OSL=512
# (same as Stage 4 Kimi-K2 baseline). Override per-run.
#
#   run-id       e.g. r1a-kimi-k2-1p1d
#   region       us-east-2 | us-west-2
#   rate         requests per second        (default 4)
#   num_prompts  total                       (default 128)
#   isl          input seq len               (default 1024)
#   osl          output seq len              (default 512)
#   dataset      random | sharegpt | ...     (default random)
#
# Example:
#   scripts/stage5-bench.sh r1a-kimi-k2-1p1d us-east-2 4 128 1024 512 random
# -----------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/stage5-lib.sh"

RUN="${1:?run-id required}"
REGION="${2:?region required}"
RATE="${3:-4}"
NUM_PROMPTS="${4:-128}"
ISL="${5:-1024}"
OSL="${6:-512}"
DATASET="${7:-random}"

stage5_load_region "${REGION}"
stage5_kubeconfig

# Pick a launcher pod as the bench host. For R1a-style runs it's a prefill pod;
# for R0 it's the single smoke pod. We grep by app label prefix.
HOST_POD=$(kubectl -n "${STAGE5_NS}" get pods \
  -l "app in (sglang-${RUN%%-*},sglang-${RUN})" \
  --no-headers -o custom-columns=":metadata.name" 2>/dev/null \
  | grep -v lb | head -1 || true)
if [ -z "${HOST_POD}" ]; then
  # Fallback to a name substring match
  HOST_POD=$(kubectl -n "${STAGE5_NS}" get pods --no-headers -o custom-columns=":metadata.name" \
    | grep "${RUN}" | grep -v lb | head -1 || true)
fi
[ -n "${HOST_POD}" ] || { echo "no bench host pod found for run=${RUN}"; exit 3; }

# Target URL: for disaggregated runs, hit the LB service on :8000.
# For R0 (single pod) hit :30000 directly.
if kubectl -n "${STAGE5_NS}" get svc "sglang-${RUN%%-*}-lb" >/dev/null 2>&1; then
  TARGET_URL="http://sglang-${RUN%%-*}-lb.${STAGE5_NS}.svc:8000"
elif kubectl -n "${STAGE5_NS}" get svc "sglang-${RUN}" >/dev/null 2>&1; then
  TARGET_URL="http://sglang-${RUN}.${STAGE5_NS}.svc:30000"
else
  TARGET_URL="http://localhost:30000"
fi

OUT_DIR="$(stage5_result_dir "${RUN}")"
echo "[bench] run=${RUN} host-pod=${HOST_POD} target=${TARGET_URL} out=${OUT_DIR}"

# Resolve served model-path (bench_serving.py needs --model)
MODEL_PATH=$(kubectl -n "${STAGE5_NS}" exec "${HOST_POD}" -c server -- \
  bash -lc 'echo ${MODEL_PATH:-/models/current}' 2>/dev/null || echo "/models/current")

# Compose remote command
BENCH_CMD="python3 -m sglang.bench_serving \
  --backend sglang \
  --base-url '${TARGET_URL}' \
  --dataset-name '${DATASET}' \
  --num-prompts ${NUM_PROMPTS} \
  --request-rate ${RATE} \
  --random-input-len ${ISL} \
  --random-output-len ${OSL} \
  --output-file /tmp/bench-${RUN}.json \
  --model '${MODEL_PATH}'"

echo "[bench] exec: ${BENCH_CMD}"
kubectl -n "${STAGE5_NS}" exec "${HOST_POD}" -c server -- bash -lc "${BENCH_CMD}" \
  | tee "${OUT_DIR}/bench-stdout.log"

# Copy the JSON out.
kubectl -n "${STAGE5_NS}" cp "${STAGE5_NS}/${HOST_POD}:/tmp/bench-${RUN}.json" \
  "${OUT_DIR}/bench.json" -c server || echo "warn: could not cp bench.json"

# Mini summary
{
  echo "run:        ${RUN}"
  echo "region:     ${REGION}"
  echo "target:     ${TARGET_URL}"
  echo "rate:       ${RATE}"
  echo "num_prompts:${NUM_PROMPTS}"
  echo "isl/osl:    ${ISL}/${OSL}"
  echo "dataset:    ${DATASET}"
  echo "timestamp:  $(date -u -Is)"
  if [ -f "${OUT_DIR}/bench.json" ]; then
    python3 - <<PY
import json, sys
with open("${OUT_DIR}/bench.json") as f:
    d = json.load(f)
keys = ["completed", "mean_ttft_ms", "median_ttft_ms", "p99_ttft_ms",
        "mean_tpot_ms", "median_tpot_ms", "p99_tpot_ms",
        "mean_itl_ms", "median_itl_ms", "p99_itl_ms",
        "output_throughput", "total_token_throughput"]
for k in keys:
    if k in d:
        print(f"{k:26s} {d[k]}")
PY
  fi
} | tee "${OUT_DIR}/SUMMARY.txt"

echo "[bench] done -> ${OUT_DIR}"

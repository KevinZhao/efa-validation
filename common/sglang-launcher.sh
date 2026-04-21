#!/usr/bin/env bash
# Thin wrapper around `python -m sglang.launch_server`. The role / transport
# wiring is done here so the k8s manifests stay declarative.
#
# SGLang 0.4.10 PD model:
#   * prefill server  : --disaggregation-mode prefill --disaggregation-bootstrap-port 8998
#   * decode server   : --disaggregation-mode decode  --disaggregation-bootstrap-port 8998
#   * mini_lb (router): python -m sglang.srt.disaggregation.launch_lb
#                         --prefill http://<prefill>:30000 --decode http://<decode>:30000
#   decode does NOT directly know prefill; mini_lb fanouts requests.
set -eu

ROLE="${ROLE:-baseline}"
MODEL_PATH="${MODEL_PATH:-/models/current}"
TP="${TP:-8}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-30000}"
KV_BACKEND="${KV_TRANSPORT_BACKEND:-mooncake}"
BOOTSTRAP_PORT="${BOOTSTRAP_PORT:-8998}"
# EFA device name, e.g. rdmap80s0; default to "all" (mooncake default).
IB_DEVICE="${DISAGG_IB_DEVICE:-}"

# torch/lib on LD_LIBRARY_PATH so libc10.so is findable (Stage 2 fix)
TORCH_LIB=$(python3 -c 'import torch, os; print(os.path.join(os.path.dirname(torch.__file__), "lib"))')
export LD_LIBRARY_PATH="${TORCH_LIB}:${LD_LIBRARY_PATH:-}"

COMMON_ARGS=(
  --model-path "${MODEL_PATH}"
  --tp "${TP}"
  --host "${HOST}"
  --port "${PORT}"
  --trust-remote-code
  --mem-fraction-static 0.85
)

DISAGG_EXTRA=()
if [ -n "${IB_DEVICE}" ]; then
  DISAGG_EXTRA+=(--disaggregation-ib-device "${IB_DEVICE}")
fi

case "${ROLE}" in
  baseline)
    echo "[sglang-launcher] role=baseline single-node TP=${TP}"
    exec python3 -m sglang.launch_server "${COMMON_ARGS[@]}"
    ;;
  prefill)
    echo "[sglang-launcher] role=prefill TP=${TP} kv=${KV_BACKEND} bootstrap=${BOOTSTRAP_PORT} ib=${IB_DEVICE:-<all>}"
    exec python3 -m sglang.launch_server \
      "${COMMON_ARGS[@]}" \
      --disaggregation-mode prefill \
      --disaggregation-transfer-backend "${KV_BACKEND}" \
      --disaggregation-bootstrap-port "${BOOTSTRAP_PORT}" \
      "${DISAGG_EXTRA[@]}"
    ;;
  decode)
    echo "[sglang-launcher] role=decode TP=${TP} kv=${KV_BACKEND} bootstrap=${BOOTSTRAP_PORT} ib=${IB_DEVICE:-<all>}"
    exec python3 -m sglang.launch_server \
      "${COMMON_ARGS[@]}" \
      --disaggregation-mode decode \
      --disaggregation-transfer-backend "${KV_BACKEND}" \
      --disaggregation-bootstrap-port "${BOOTSTRAP_PORT}" \
      "${DISAGG_EXTRA[@]}"
    ;;
  lb)
    : "${PREFILL_URL:?lb role requires PREFILL_URL (e.g. http://sglang-prefill:30000)}"
    : "${DECODE_URL:?lb role requires DECODE_URL (e.g. http://sglang-decode:30000)}"
    LB_PORT="${LB_PORT:-8000}"
    echo "[sglang-launcher] role=lb prefill=${PREFILL_URL} decode=${DECODE_URL} listen=${LB_PORT}"
    exec python3 -m sglang.srt.disaggregation.launch_lb \
      --prefill "${PREFILL_URL}" \
      --decode "${DECODE_URL}" \
      --host 0.0.0.0 \
      --port "${LB_PORT}"
    ;;
  *)
    echo "[sglang-launcher] unknown ROLE=${ROLE}"; exit 2
    ;;
esac

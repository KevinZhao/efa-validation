#!/bin/bash
# Stage 6 R1a prefill entrypoint — Kimi-K2.5 INT4 PD-1P1D, Mooncake KV (NO DeepEP).
#
# R1a = R1b MINUS L4 (DeepEP). Stacks only 2 optimizations on top of the Stage 5 baseline
# (scripts/stage5-pd-1p1d-mc-vs-nixl/entrypoints/prefill_entrypoint.sh):
#   P0  image upgraded to public.ecr.aws/n3l4x8f3/sglang-mooncake-uccl:2026.05.02-h200.dp16
#       (contains Mooncake PR #2023 tip 4a306de8 DP>1 root fix, sglang 0.5.10 + Henan 5 PRs)
#   L5  3 missing env: SGLANG_MOONCAKE_CUSTOM_MEM_POOL / FI_EFA_ENABLE_SHM_TRANSFER / FI_EFA_FORK_SAFE
#
# DeepEP stays OFF (default --moe-a2a-backend = none) and Mooncake KV uses ALL 16 EFA rails
# (same as Stage 5 baseline). Purpose: measure "image + env" delta alone before layering
# DeepEP risk (p5en real-node PD-disagg + DeepEP has not been smoke-tested).
#
# KV_BACKEND is fixed to mooncake (Stage 6 is not an A/B with nixl).
set -eu

KV_BACKEND="${KV_BACKEND:-mooncake}"
if [ "$KV_BACKEND" != "mooncake" ]; then
    echo "[launcher] FATAL: Stage 6 R1a only supports KV_BACKEND=mooncake, got '$KV_BACKEND'" >&2
    exit 2
fi
echo "[launcher] Stage 6 R1a prefill (KV=${KV_BACKEND}, a2a=none/DeepEP OFF, all 16 rails unified)"

# PyTorch lib path (mooncake TE bindings link against torch's cuda shims)
TORCH_LIB=$(python3 -c 'import torch, os; print(os.path.join(os.path.dirname(torch.__file__), "lib"))')
export LD_LIBRARY_PATH="${TORCH_LIB}:${LD_LIBRARY_PATH:-}"

# http_server.py VLM bypass patch (K2.5 is VLM; stock sglang blocks disagg on VLM)
python3 << 'EOF'
import os
file_path = '/usr/local/lib/python3.10/dist-packages/sglang/srt/entrypoints/http_server.py'
if os.path.exists(file_path):
    with open(file_path, 'r') as f:
        content = f.read()
    old = 'if is_vlm and not server_args.skip_tokenizer_init:'
    new = 'if is_vlm and not server_args.skip_tokenizer_init and server_args.disaggregation_mode == "null":'
    if old in content:
        content = content.replace(old, new)
        with open(file_path, 'w') as f:
            f.write(content)
        print('[launcher] patched http_server.py (VLM disaggregation bypass)')
        pyc = '/usr/local/lib/python3.10/dist-packages/sglang/srt/entrypoints/__pycache__/http_server.cpython-310.pyc'
        if os.path.exists(pyc):
            os.remove(pyc)
    else:
        print('[launcher] http_server.py already patched or pattern not found')
EOF

# ---- Rail unified (R1a: no L4 split) -------------------------------------
# Mooncake KV uses ALL 16 EFA rails — same as Stage 5 baseline.
# No UCCL-EP rail carve-out; no UCCL_IB_HCA / FI_EFA_IFACE env.
ALL_RAILS_DEFAULT="rdmap110s0,rdmap111s0,rdmap112s0,rdmap113s0,rdmap135s0,rdmap136s0,rdmap137s0,rdmap138s0,rdmap160s0,rdmap161s0,rdmap162s0,rdmap163s0,rdmap85s0,rdmap86s0,rdmap87s0,rdmap88s0"

IB_DEVICE="${IB_DEVICE:-}"
if [ -z "${IB_DEVICE}" ] && command -v fi_info >/dev/null 2>&1; then
    IB_DEVICE=$(fi_info -p efa 2>/dev/null | awk '/domain:/ {print $2}' | sed 's/-rdm$//;s/-dgrm$//' | sort -u | paste -sd, -)
fi
FINAL_IB_DEVICE="${IB_DEVICE:-$ALL_RAILS_DEFAULT}"
echo "[launcher] Mooncake KV rails (all 16): ${FINAL_IB_DEVICE}"

echo "[launcher] starting sglang prefill (Mooncake KV only, DeepEP OFF)"
exec python3 -m sglang.launch_server \
    --model-path /models/model \
    --served-model-name kimi-k2-5-pd \
    --watchdog-timeout 3600 \
    --enable-metrics \
    --log-level-http debug \
    --log-requests-level 3 \
    --collect-tokens-histogram \
    --show-time-cost \
    --disaggregation-mode prefill \
    --disaggregation-transfer-backend "${KV_BACKEND}" \
    --disaggregation-ib-device "${FINAL_IB_DEVICE}" \
    --host 0.0.0.0 \
    --port 30081 \
    --trust-remote-code \
    --tp-size 8 \
    --chunked-prefill-size 16384 \
    --mem-fraction-static 0.85 \
    --disable-cuda-graph \
    --max-running-requests 256 \
    --context-length 262144 \
    --attention-backend fa3 \
    --page-size 64 \
    --crash-dump-folder /sglang/logs \
    --tool-call-parser kimi_k2 \
    --reasoning-parser kimi_k2 \
    --tokenizer-worker-num 8 \
    --enable-dynamic-batch-tokenizer \
    --dynamic-batch-tokenizer-batch-size 8 \
    --ep-dispatch-algorithm dynamic \
    --eplb-algorithm deepseek \
    --disable-shared-experts-fusion \
    --moe-dense-tp-size 1 \
    --enable-multimodal \
    --mm-enable-dp-encoder

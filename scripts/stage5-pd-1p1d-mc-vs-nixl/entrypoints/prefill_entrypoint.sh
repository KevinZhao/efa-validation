#!/bin/bash
# Prefill entrypoint for PD 1P1D A/B — mooncake vs nixl.
# KV_BACKEND env var picks the backend (default: mooncake).
# Single variable between variants = --disaggregation-transfer-backend.
set -e

KV_BACKEND="${KV_BACKEND:-mooncake}"
if [[ "$KV_BACKEND" != "mooncake" && "$KV_BACKEND" != "nixl" ]]; then
    echo "[launcher] FATAL: KV_BACKEND must be 'mooncake' or 'nixl', got '$KV_BACKEND'" >&2
    exit 2
fi
echo "[launcher] KV_BACKEND=${KV_BACKEND}"

# PyTorch lib path (mooncake TE bindings link against torch's cuda shims)
TORCH_LIB=$(python3 -c 'import torch, os; print(os.path.join(os.path.dirname(torch.__file__), "lib"))')
export LD_LIBRARY_PATH="${TORCH_LIB}:${LD_LIBRARY_PATH:-}"

# Auto-detect EFA rails (16 on p5en)
IB_DEVICE="${IB_DEVICE:-}"
if [ -z "${IB_DEVICE}" ] && command -v fi_info >/dev/null 2>&1; then
    IB_DEVICE=$(fi_info -p efa 2>/dev/null | awk '/domain:/ {print $2}' | sed 's/-rdm$//;s/-dgrm$//' | sort -u | paste -sd, -)
fi
[ -n "${IB_DEVICE}" ] && echo "[launcher] IB_DEVICE=${IB_DEVICE}"

# http_server.py VLM bypass patch (customer-verified; image does not bake this)
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

# rdma -> efa Mooncake patch is baked in the image at Dockerfile line 152-159.
# Do NOT re-patch here (it would be a no-op anyway).

# Fallback rail list for p5en if fi_info fails (matches customer)
DEFAULT_DEVICES="rdmap110s0,rdmap111s0,rdmap112s0,rdmap113s0,rdmap135s0,rdmap136s0,rdmap137s0,rdmap138s0,rdmap160s0,rdmap161s0,rdmap162s0,rdmap163s0,rdmap85s0,rdmap86s0,rdmap87s0,rdmap88s0"
FINAL_IB_DEVICE="${IB_DEVICE:-$DEFAULT_DEVICES}"

echo "[launcher] starting sglang prefill (backend=${KV_BACKEND}, rails=${FINAL_IB_DEVICE})"
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

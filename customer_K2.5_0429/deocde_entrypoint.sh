#!/bin/bash
set -e

# 设置 PyTorch lib 路径
TORCH_LIB=$(python3 -c 'import torch, os; print(os.path.join(os.path.dirname(torch.__file__), "lib"))')
export LD_LIBRARY_PATH="${TORCH_LIB}:${LD_LIBRARY_PATH:-}"

# 自动检测 IB_DEVICE
IB_DEVICE="${IB_DEVICE:-}"
if [ -z "${IB_DEVICE}" ] && command -v fi_info >/dev/null 2>&1; then
    IB_DEVICE=$(fi_info -p efa 2>/dev/null | awk '/domain:/ {print $2}' | sed 's/-rdm$//;s/-dgrm$//' | sort -u | paste -sd, -)
fi
[ -n "${IB_DEVICE}" ] && echo "[launcher] IB_DEVICE=${IB_DEVICE}"

# Patch mooncake_transfer_engine.py
MC_PY=/usr/local/lib/python3.10/dist-packages/sglang/srt/distributed/device_communicators/mooncake_transfer_engine.py
if [ -f "${MC_PY}" ] && grep -q '"rdma",' "${MC_PY}"; then
    echo "[launcher] patching ${MC_PY}: rdma -> efa"
    sed -i 's/"rdma",$/"efa",/' "${MC_PY}"
    rm -f /usr/local/lib/python3.10/dist-packages/sglang/srt/distributed/device_communicators/__pycache__/mooncake_transfer_engine.cpython-310.pyc 2>/dev/null || true
fi

# Patch http_server.py (使用 Python 内联)
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
        print('[launcher] Successfully patched http_server.py')
        pyc = '/usr/local/lib/python3.10/dist-packages/sglang/srt/entrypoints/__pycache__/http_server.cpython-310.pyc'
        if os.path.exists(pyc):
            os.remove(pyc)
    else:
        print('[launcher] http_server.py already patched or pattern not found')
EOF

# 设置默认 IB_DEVICE
DEFAULT_DEVICES="rdmap110s0,rdmap111s0,rdmap112s0,rdmap113s0,rdmap135s0,rdmap136s0,rdmap137s0,rdmap138s0,rdmap160s0,rdmap161s0,rdmap162s0,rdmap163s0,rdmap85s0,rdmap86s0,rdmap87s0,rdmap88s0"
FINAL_IB_DEVICE="${IB_DEVICE:-$DEFAULT_DEVICES}"

# 启动 sglang
exec python3 -m sglang.launch_server \
    --model-path /models/model \
    --served-model-name kimi-k2-5-pd \
    --enable-metrics \
    --log-level-http debug \
    --log-requests-level 3 \
    --watchdog-timeout 1200 \
    --decode-log-interval 50 \
    --collect-tokens-histogram \
    --show-time-cost \
    --disaggregation-mode decode \
    --disaggregation-ib-device "${FINAL_IB_DEVICE}" \
    --host 0.0.0.0 \
    --port 30082 \
    --trust-remote-code \
    --tp-size 8 \
    --dp-size 8 \
    --enable-dp-attention \
    --moe-dense-tp-size 1 \
    --enable-dp-lm-head \
    --ep-dispatch-algorithm dynamic \
    --eplb-algorithm deepseek \
    --disable-shared-experts-fusion \
    --mem-fraction-static 0.85 \
    --cuda-graph-max-bs 32 \
    --max-running-requests 256 \
    --context-length 262144 \
    --prefill-round-robin-balance \
    --tokenizer-worker-num 8 \
    --enable-dynamic-batch-tokenizer \
    --dynamic-batch-tokenizer-batch-size 8 \
    --page-size 64 \
    --crash-dump-folder /sglang/logs \
    --tool-call-parser kimi_k2 \
    --reasoning-parser kimi_k2
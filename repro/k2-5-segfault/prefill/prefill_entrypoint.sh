#!/bin/bash
# DeepSeek-V4-Flash prefill entrypoint — mirrors customer's Kimi-K2.5 prefill entrypoint 1:1
# except: parser / reasoning / model / no multimodal (V4-Flash is text-only)
set -e

# 设置 PyTorch lib 路径
TORCH_LIB=$(python3 -c 'import torch, os; print(os.path.join(os.path.dirname(torch.__file__), "lib"))')
export LD_LIBRARY_PATH="${TORCH_LIB}:${LD_LIBRARY_PATH:-}"

# 自动检测 IB_DEVICE (p5 = 8 rail, customer's p5en = 16 rail; fi_info 覆盖默认)
IB_DEVICE="${IB_DEVICE:-}"
if [ -z "${IB_DEVICE}" ] && command -v fi_info >/dev/null 2>&1; then
    IB_DEVICE=$(fi_info -p efa 2>/dev/null | awk '/domain:/ {print $2}' | sed 's/-rdm$//;s/-dgrm$//' | sort -u | paste -sd, -)
fi
[ -n "${IB_DEVICE}" ] && echo "[launcher] IB_DEVICE=${IB_DEVICE}"

# Patch mooncake_transfer_engine.py (客户镜像 .3 已经 bake 过，但保留以防回滚)
MC_PY=/usr/local/lib/python3.10/dist-packages/sglang/srt/distributed/device_communicators/mooncake_transfer_engine.py
if [ -f "${MC_PY}" ] && grep -q '"rdma",' "${MC_PY}"; then
    echo "[launcher] patching ${MC_PY}: rdma -> efa"
    sed -i 's/"rdma",$/"efa",/' "${MC_PY}"
    rm -f /usr/local/lib/python3.10/dist-packages/sglang/srt/distributed/device_communicators/__pycache__/mooncake_transfer_engine.cpython-310.pyc 2>/dev/null || true
fi

# Patch http_server.py (客户 hotfix — PD 模式下跳过 VLM tokenizer init)
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

# p5en 16 rail (客户原值保留)
DEFAULT_DEVICES="rdmap110s0,rdmap111s0,rdmap112s0,rdmap113s0,rdmap135s0,rdmap136s0,rdmap137s0,rdmap138s0,rdmap160s0,rdmap161s0,rdmap162s0,rdmap163s0,rdmap85s0,rdmap86s0,rdmap87s0,rdmap88s0"
FINAL_IB_DEVICE="${IB_DEVICE:-$DEFAULT_DEVICES}"

# core dump capture to host volume
ulimit -c unlimited || true
echo "/coredump/core.%e.%p.%t" > /proc/sys/kernel/core_pattern 2>/dev/null || true

echo "[launcher] starting sglang prefill (Kimi-K2 1P1D repro of customer K2.5 segfault)"

exec python3 -m sglang.launch_server \
    --model-path /models/model \
    --served-model-name deepseek-v4-flash-pd \
    --watchdog-timeout 3600 \
    --enable-metrics \
    --log-level-http debug \
    --log-requests-level 3 \
    --collect-tokens-histogram \
    --show-time-cost \
    --disaggregation-mode prefill \
    --disaggregation-ib-device "${FINAL_IB_DEVICE}" \
    --host 0.0.0.0 \
    --port 30081 \
    --trust-remote-code \
    --tp-size 8 \
    --dp-size 2 \
    --enable-dp-attention \
    --chunked-prefill-size 16384 \
    --mem-fraction-static 0.85 \
    --disable-cuda-graph \
    --max-running-requests 128 \
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

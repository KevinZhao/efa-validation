TORCH_LIB=$(python3 -c 'import torch, os; print(os.path.join(os.path.dirname(torch.__file__), "lib"))')
export LD_LIBRARY_PATH="${TORCH_LIB}:${LD_LIBRARY_PATH:-}"

export FI_PROVIDER="efa"  # 强制 Libfabric 使用 EFA 提供者
export FI_EFA_USE_DEVICE_RDMA=1  # 开启 EFA 的设备端 RDMA 支持（绕过 CPU）
export FI_EFA_FORK_SAFE=1 # AWS EFA 专属的 Fork Safe 参数

export MOONCAKE_PROTOCOL="rdma"
export MOONCAKE_DEVICE="auto-discovery"

IB_DEVICE="${IB_DEVICE:-}"
if [ -z "${IB_DEVICE}" ] && command -v fi_info >/dev/null 2>&1; then
    IB_DEVICE=$(fi_info -p efa 2>/dev/null | awk '/domain:/ {print $2}' | sed 's/-rdm$//;s/-dgrm$//' | sort -u | paste -sd, -)
fi
[ -n "${IB_DEVICE}" ] && echo "[launcher] IB_DEVICE=${IB_DEVICE}"

# 开启 EFA 的 GPU Direct RDMA (GPUDirect)
export FI_EFA_ENABLE_SHM_TRANSFER=1
export SGLANG_MOONCAKE_CUSTOM_MEM_POOL=1

MC_PY=/usr/local/lib/python3.10/dist-packages/sglang/srt/distributed/device_communicators/mooncake_transfer_engine.py
if [ -f "${MC_PY}" ] && grep -q '"rdma",' "${MC_PY}"; then
    echo "[launcher] patching ${MC_PY}: rdma -> efa"
    sed -i 's/"rdma",$/"efa",/' "${MC_PY}"
    rm -f /usr/local/lib/python3.10/dist-packages/sglang/srt/distributed/device_communicators/__pycache__/mooncake_transfer_engine.cpython-310.pyc 2>/dev/null || true
fi

# export MC_TE_METRIC=1  # 开启监控，方便看更详细的网络日志
# export GLOO_SOCKET_IFNAME=enp71s0
# export NCCL_SOCKET_IFNAME=enp71s0

export NVSHMEM_DEBUG=INFO
export SGLANG_TORCH_PROFILER_DIR=/root/sglang/profile_log
export PYTHONUNBUFFERED=1 
export SGLANG_DISAGGREGATION_HEARTBEAT_INTERVAL=10
export SGLANG_DISAGGREGATION_BOOTSTRAP_TIMEOUT=181
export SGLANG_DISAGGREGATION_WAITING_TIMEOUT=179
export ENABLE_PD_GUARDIAN=0
export SGLANG_TOOL_STRICT_LEVEL=0
# export SGLANG_ENABLE_HEALTH_ENDPOINT_GENERATION=1
export SGLANG_VLM_CACHE_SIZE_MB=8192

python3 -m sglang.launch_server \
    --model-path /export/models/moonshotai/Kimi-K2.5 \
    --tp 8 \
    --dp 8 \
    --enable-dp-attention \
    --chunked-prefill-size 4096 \
    --host 0.0.0.0 \
    --port 30082 \
    --trust-remote-code \
    --mem-fraction-static 0.81 \
    --disaggregation-mode decode \
    --disaggregation-transfer-backend mooncake \
    --disaggregation-bootstrap-port 8998 \
    --disaggregation-ib-device "${IB_DEVICE}" \
    --attention-backend flashinfer \
    --tokenizer-path /export/models/moonshotai/Kimi-K2.5 \
    --chat-template /export/models/moonshotai/Kimi-K2.5/chat_template.jinja \
    --cuda-graph-max-bs 128 \
    --tool-call-parser kimi_k2 \
    --reasoning-parser kimi_k2 \
    --page-size 1 \
    --context-length 262144 \
    --moe-dense-tp-size 1 \
    --enable-dp-lm-head \
    --ep-dispatch-algorithm dynamic \
    --eplb-algorithm deepseek \
    --disable-shared-experts-fusion \
    --tokenizer-worker-num 8 \
    --enable-dynamic-batch-tokenizer \
    --dynamic-batch-tokenizer-batch-size 8 \
    --dynamic-batch-tokenizer-batch-timeout 5 \
    --enable-multimodal \
    --mm-enable-dp-encoder
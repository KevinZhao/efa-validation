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

# # 降低 libfabric 重连激进程度
# export FI_EFA_AV_TYPE=HASH
# export FI_EFA_MAX_LONG_MSG_SIZE=1048576
# export FI_EFA_USE_ZEROCOPY=0  # 部分实例上 ZeroCopy 与频繁重连冲突

# # 限制单进程 RDMA 提交并发度，避免 QP 提交竞争
# export OMP_NUM_THREADS=1
# export MOONCAKE_EFA_MAX_CQ_SIZE=4096

# ulimit -l unlimited
# echo "* soft memlock unlimited" | sudo tee -a /etc/security/limits.conf
# echo "* hard memlock unlimited" | sudo tee -a /etc/security/limits.conf

# # 增加 RDMA 内存注册表上限
# sudo sysctl -w vm.max_map_count=200000000
# sudo sysctl -w net.core.rmem_max=3355443200
# sudo sysctl -w net.core.wmem_max=3355443200

MC_PY=/usr/local/lib/python3.10/dist-packages/sglang/srt/distributed/device_communicators/mooncake_transfer_engine.py
if [ -f "${MC_PY}" ] && grep -q '"rdma",' "${MC_PY}"; then
    echo "[launcher] patching ${MC_PY}: rdma -> efa"
    sed -i 's/"rdma",$/"efa",/' "${MC_PY}"
    rm -f /usr/local/lib/python3.10/dist-packages/sglang/srt/distributed/device_communicators/__pycache__/mooncake_transfer_engine.cpython-310.pyc 2>/dev/null || true
fi

# export MC_TE_METRIC=1  # 开启监控，方便看更详细的网络日志
# export GLOO_SOCKET_IFNAME=enp71s0
# export NCCL_SOCKET_IFNAME=enp71s0

# export NVSHMEM_DEBUG=INFO
# export SGLANG_TORCH_PROFILER_DIR=/root/sglang/profile_log
# export PYTHONUNBUFFERED=1 
# export SGLANG_DISAGGREGATION_HEARTBEAT_INTERVAL=10
# export SGLANG_DISAGGREGATION_BOOTSTRAP_TIMEOUT=181
# export SGLANG_DISAGGREGATION_WAITING_TIMEOUT=179
# export ENABLE_PD_GUARDIAN=0
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
    --port 30081 \
    --trust-remote-code \
    --mem-fraction-static 0.81 \
    --disaggregation-mode prefill \
    --disaggregation-transfer-backend mooncake \
    --disaggregation-bootstrap-port 8998 \
    --disaggregation-ib-device "${IB_DEVICE}" \
    --attention-backend fa3 \
    --enable-multimodal \
    --tokenizer-path /export/models/moonshotai/Kimi-K2.5 \
    --chat-template /export/models/moonshotai/Kimi-K2.5/chat_template.jinja \
    --cuda-graph-max-bs 256 \
    --tool-call-parser kimi_k2 \
    --reasoning-parser kimi_k2 \
    --page-size 1 \
    --context-length 262144 \
    --moe-dense-tp-size 1 \
    --enable-dp-lm-head \
    --ep-dispatch-algorithm dynamic \
    --eplb-algorithm deepseek \
    --disable-shared-experts-fusion \
    --mm-enable-dp-encoder \
    --prefill-round-robin-balance


# MC_TE_METRIC=1



# # # nvidia
# # export NVIDIA_SPARSE_ENABLE=1
# # export NCCL_SOCKET_IFNAME=bond0
# # export GLOO_SOCKET_IFNAME=bond0
# # # export NCCL_IB_GID_INDEX=3
# # export NCCL_NET_GDR_LEVEL=2
# # export NCCL_IB_TC=160
# # export NCCL_DEBUG=INFO
# # export NCCL_DEBUG_SUBSYS=ALL
# # export NCCL_DEBUG_FILE=nccl_debug.log
# # export NCCL_IB_DISABLE=0
# # export NCCL_IB_QPS_PER_CONNECTION=8 # added
# # export NCCL_IB_SPLIT_DATA_ON_QPS=1 # added
# # # export NCCL_IB_HCA=mlx5_bond_0 # fix by zxb
# # export NCCL_IB_HCA=mlx5_gdr_0:1,mlx5_gdr_1:1,mlx5_gdr_2:1,mlx5_gdr_3:1,mlx5_gdr_4:1,mlx5_gdr_5:1,mlx5_gdr_6:1,mlx5_gdr_7:1
# # export NCCL_SOCKET_NTHREADS=4 # added
# # export NCCL_NSOCKS_PERTHREAD=8 # added
# # export OMP_NUM_THREADS=1 #TDDO

# # # add by zxb
# # export NCCL_IB_TIMEOUT=23 # add by zxb
# # export NCCL_TIMEOUT=1200 
# # export UCX_RC_TIMEOUT=15s
# # export UCX_UD_TIMEOUT=30s
# # export SGLANG_MOONCAKE_CUSTOM_MEM_POOL=NVLINK
# # export MC_FORCE_MNNVL=True
# # export SGLANG_DISAGGREGATION_THREAD_POOL_SIZE=8 # int(0.75 * os.cpu_count()) // 8)
# # export SGLANG_DISAGGREGATION_QUEUE_SIZE=8
# # export SGLANG_DISAGGREGATION_BOOTSTRAP_ENTRY_CLEANUP_INTERVAL=200
# # export SGLANG_DISAGGREGATION_HEARTBEAT_MAX_FAILURE=1


# # export TORCHINDUCTOR_CACHE_DIR=/sglang/torch-compile
# # export MC_TE_METRIC=true
# # export MC_LOG_LEVEL=ERROR # 原本trace
# # export MC_LOG_DIR=/sglang/logs/
# # export SGLANG_ENABLE_HEALTH_ENDPOINT_GENERATION=False


# # export SGLANG_SET_CPU_AFFINITY=1
# # export SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1
# # export SGLANG_MOE_PADDING=1
# # export SGLANG_ENABLE_JIT_DEEPGEMM=1
# # export SGLANG_JIT_DEEPGEMM_COMPILE_WORKERS=32
# # export SGLANG_DG_CACHE_DIR=/sglang/deep_gemm
# # export SGLANG_CHUNKED_PREFIX_CACHE_THRESHOLD=16384
# # export SGLANG_DISAGGREGATION_HEARTBEAT_INTERVAL=10
# # export SGLANG_DISAGGREGATION_BOOTSTRAP_TIMEOUT=181
# # export SGLANG_DISAGGREGATION_WAITING_TIMEOUT=179
# # export PYTHONUNBUFFERED=1
# # export UCX_TLS=tcp,sm 
# # export UCX_NET_DEVICES=bond0
# # export METRICS_PREFIX=prefill
# # # export SGLANG_HEALTH_CHECK_MEM_FREE=50
# # export NVSHMEM_DEBUG=INFO
# # export ENABLE_PD_GUARDIAN=0
# # export SGLANG_TORCH_PROFILER_DIR=/sglang/logs/profile_log
# # export SGLANG_TOOL_STRICT_LEVEL=0
# # # export SGLANG_ENABLE_SPEC_V2=true
# # export SGLANG_VLM_CACHE_SIZE_MB=8192
# # export SGLANG_ENABLE_HEALTH_ENDPOINT_GENERATION=1

# # # export SGLANG_ENABLE_OVERLAP_SCHEDULE=1

# # python3 -m sglang.launch_server \
# #   --model-path /ufs/zxb/models/Kimi-K2.5 \
# #   --tp-size 8 \
# #   --dp-size 2 \
# #   --enable-dp-attention \
# #   --chunked-prefill-size 8192 \
# #   --disaggregation-mode prefill \
# #   --disaggregation-bootstrap-port 8998 \
# #   --disaggregation-ib-device "mlx5_gdr_0,mlx5_gdr_1,mlx5_gdr_2,mlx5_gdr_3,mlx5_gdr_4,mlx5_gdr_5,mlx5_gdr_6,mlx5_gdr_7" \
# #   --host 0.0.0.0 \
# #   --port 30001 \
# #   --attention-backend flashinfer \
# #   --tokenizer-path /ufs/zxb/models/Kimi-K2.5 \
# #   --mem-fraction-static 0.81 \
# #   --trust-remote-code \
# #   --chat-template /ufs/zxb/models/Kimi-K2.5/chat_template.jinja \
# #   --cuda-graph-max-bs 256 \
# #   --tool-call-parser kimi_k2 \
# #   --reasoning-parser kimi_k2 \
# #   --enable-metrics \
# #   --log-level-http debug \
# #   --log-requests-level 3 \
# #   --watchdog-timeout 1200 \
# #   --decode-log-interval 5 \
# #   --collect-tokens-histogram \
# #   --show-time-cost \
# #   --page-size 128 \
# #   --context-length 262144 \
# #   --moe-dense-tp-size 1 \
# #   --enable-dp-lm-head \
# #   --ep-dispatch-algorithm dynamic \
# #   --eplb-algorithm deepseek \
# #   --disable-shared-experts-fusion \
# #   --prefill-round-robin-balance \
# #   --tokenizer-worker-num 8 \
# #   --enable-dynamic-batch-tokenizer \
# #   --dynamic-batch-tokenizer-batch-size 8 \
# #   --dynamic-batch-tokenizer-batch-timeout 5 \
# #   --enable-multimodal \
# #   --mm-enable-dp-encoder \
# #   --disable-radix-cache \
# #   --model-loader-extra-config '{"enable_multithread_load": true, "num_threads": 8}' \
# #   2>&1 | tee -a "/ufs/zxb/SpecForge/examples/kimi_k2.5/1p1d_2x1_nodes/logs/test_prefill_v4.log"
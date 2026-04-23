# Kimi-K2-Instruct-0905 on AWS p5en — 从零复现指南

**目标读者**: JD / 其他 AWS 客户，想在 p5en.48xlarge × N 节点上跑 Kimi-K2-Instruct-0905 (1T MoE, FP8) 的 SGLang + Mooncake PD 分离栈。

**前置假设**：
- 已有 EKS 集群带 p5en GPU NodeGroup（GPU Operator v25.10.1 + `toolkit.enabled=true` + `cdi.enabled=true`，containerd 2.2 + driver 580 + CUDA 13）
- 已能 `kubectl` 访问集群
- 已有 ECR 镜像 `yanxi/sglang-mooncake:v2`（基于 `yanxi/mooncake-nixl:v2`，含 Mooncake post2 Henan PRs + SGLang 0.5.10）
- AWS 账号有 S3 bucket 用来分发 manifest（或直接走 `kubectl apply -f -`）
- p5en spot/on-demand quota 足够 3 台

**时间预算**（冷启动，3 节点）：
- NVMe 挂载: 2 min
- Kimi K2 权重下载 (959 GB): ~15 min
- 首次 pod 部署到 3/3 Ready: ~7 min（用 CUTLASS fp8 backend）
- Smoke + bench: 3 min
- **总计: ~30 min**

---

## Step 0 — 准备 Namespace、ECR pull secret、ServiceAccount

```bash
kubectl create namespace yanxi-validation

# 若 ECR 在同一账号，EKS 自带 node-IAM 角色能 pull；若跨账号，参考 scripts/share-ecr-cross-account.sh

kubectl -n yanxi-validation create serviceaccount yanxi-runner
```

---

## Step 1 — 挂载 p5en NVMe instance store（一次性）

p5en.48xlarge 出厂带 8 × 3.84 TB NVMe SSD（未格式化，总计 ~30 TB）。我们把它们做 RAID0 挂到 `/var/lib/yanxi-models`，Kimi K2 的 959 GB 权重就能放下。

**`nvme-setup.yaml`** 已入仓于 `stage4-p5en/nvme-setup.yaml`。关键思路：
- DaemonSet + `privileged: true` + `nsenter -t 1 -m -p --`：在宿主机 namespace 执行
- 识别 `Amazon EC2 NVMe Instance Storage` 设备，mdadm RAID0 → mkfs.xfs → mount `/mnt/instance-store`
- `mount --bind /mnt/instance-store/yanxi-models /var/lib/yanxi-models` 保证现有 hostPath Volumes 自动走 NVMe
- 幂等：重跑不会重建 RAID

部署 + 验证：
```bash
kubectl apply -f stage4-p5en/nvme-setup.yaml

# 等 DaemonSet 全部 Running（每台 p5en 一个 pod）
kubectl -n yanxi-validation wait pod -l app=nvme-setup --for=condition=Ready --timeout=120s

# 验证每节点有 28TB 空间
kubectl -n yanxi-validation logs -l app=nvme-setup --tail=5 | grep /var/lib/yanxi-models
# 期望: /dev/md0   28T   228G   28T   1%  /var/lib/yanxi-models
```

**注意**: p5en 重启后 instance store 数据丢失。DaemonSet 每次 pod 重启会重新格式化（幂等 if-check 保证不误删）。实际生产建议把 NVMe 挂载写进 node bootstrap userdata 以避开这个。

---

## Step 2 — 预取 Kimi-K2-Instruct-0905 权重到每个节点

Kimi K2 不走共享 FSx，直接每台 p5en 本地下一份（`hostPath`）。3 台并行下 HF，约 15 分钟。

**`model-prefetch-3node.yaml`**（关键节选，完整见 `stage4-p5en/model-prefetch-3node.yaml`）：

```yaml
kind: Job
spec:
  completions: 3
  parallelism: 3
  completionMode: Indexed
  template:
    spec:
      topologySpreadConstraints:  # 强制每台 p5en 一个 pod
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
      containers:
        - env:
            - { name: MODEL_ID, value: "moonshotai/Kimi-K2-Instruct-0905" }
            - { name: DEST, value: "/models/current" }
          command: ["/bin/bash", "/scripts/prefetch.sh"]
```

预取脚本核心（`configMap` 里的 `prefetch.sh`）：
```bash
#!/usr/bin/env bash
set -eux
MODEL_ID="${MODEL_ID:-moonshotai/Kimi-K2-Instruct-0905}"
DEST="${DEST:-/models/current}"
mkdir -p "$DEST"

# 幂等：若已存在同名 model 则跳过
if [ -f "$DEST/.model-id" ] && [ "$(cat $DEST/.model-id)" = "$MODEL_ID" ]; then
  echo "Target model ${MODEL_ID} already present; skipping."; exit 0
fi

echo "Wiping old model at $DEST"
find "$DEST" -mindepth 1 -delete 2>/dev/null || true

export HF_HUB_ENABLE_HF_TRANSFER=1       # 开 hf_transfer（多线程）
export HF_HOME=/models/.hf-cache

# sglang-mooncake:v2 镜像用 hf 替换了 huggingface-cli
if command -v hf >/dev/null 2>&1; then
  hf download "$MODEL_ID" --local-dir "$DEST" --max-workers 16
else
  huggingface-cli download "$MODEL_ID" --local-dir "$DEST" --local-dir-use-symlinks False --max-workers 8
fi
echo "$MODEL_ID" > "$DEST/.model-id"
```

部署 + 验证：
```bash
kubectl apply -f stage4-p5en/model-prefetch-3node.yaml

# 预计 15 分钟（959 GB / 3 节点并行）
kubectl -n yanxi-validation wait job/model-prefetch-p5en --for=condition=Complete --timeout=1800s

# 抽查 3 节点大小一致
kubectl -n yanxi-validation logs -l app=yanxi-model-prefetch --tail=3 | grep "^[0-9]"
# 期望: 959G  /models/current  × 3
```

**私有模型 / 带 gating 的 repo**: 加 `HF_TOKEN` secret：
```bash
kubectl -n yanxi-validation create secret generic hf-token --from-literal=HF_TOKEN=hf_xxx
# 然后在 Job 的 env 里加
#   - name: HF_TOKEN
#     valueFrom: { secretKeyRef: { name: hf-token, key: HF_TOKEN } }
```

---

## Step 3 — 部署 1P:2D SGLang + Mooncake 栈

**`disagg-1p2d-kimi.yaml`**（完整见 `stage4-p5en/disagg-1p2d-kimi.yaml`，420 行）包含：
- ConfigMap `sglang-launcher-override`: 启动脚本，支持 ROLE=prefill|decode|lb
- Service: `sglang-prefill`, `sglang-decode-0`, `sglang-decode-1`, `sglang-lb`
- Deployment: 各 1 replica，用 `podAntiAffinity` 强制跨 3 节点

### 启动脚本的关键行为

```bash
# A. AWS EFA 激活 patch — sglang 0.5.10 硬编码 protocol="rdma"，EFA 上要 "efa"
MC_PY=/usr/local/lib/python3.10/dist-packages/sglang/srt/distributed/device_communicators/mooncake_transfer_engine.py
sed -i 's/"rdma",$/"efa",/' "${MC_PY}"

# B. 自动探测 16 × EFA 设备名（去 libfabric 的 -rdm / -dgrm 后缀，sglang 要 kernel name）
IB_DEVICE=$(fi_info -p efa 2>/dev/null | awk '/domain:/ {print $2}' \
          | sed 's/-rdm$//;s/-dgrm$//' | sort -u | paste -sd, -)

# C. launch sglang with Kimi K2 tuned args
python3 -m sglang.launch_server \
  --model-path /models/current \
  --tp 8 \
  --trust-remote-code \
  --context-length 131072 \
  --mem-fraction-static 0.92 \
  --chunked-prefill-size 4096 \
  --fp8-gemm-backend cutlass \    # ←关键：默认 deep_gemm 冷启动 3+ 小时
  --skip-server-warmup \
  --disaggregation-mode prefill \  # 或 decode
  --disaggregation-transfer-backend mooncake \
  --disaggregation-ib-device "${IB_DEVICE}" \
  --disaggregation-bootstrap-port 8998 \
  --host 0.0.0.0 --port 30000
```

### Pod 资源要求（prefill / decode 同，TP=8 占满一节点）

```yaml
resources:
  limits: { nvidia.com/gpu: 8, vpc.amazonaws.com/efa: 16, hugepages-2Mi: 5120Mi, memory: 500Gi }
  requests: { nvidia.com/gpu: 8, vpc.amazonaws.com/efa: 16, hugepages-2Mi: 5120Mi, memory: 500Gi }
volumeMounts:
  - { name: models, mountPath: /models }   # hostPath /var/lib/yanxi-models
  - { name: shm, mountPath: /dev/shm }     # emptyDir Memory 64Gi
securityContext:
  capabilities: { add: [IPC_LOCK] }          # Mooncake 需要 mlock
readinessProbe:
  httpGet: { path: /get_model_info, port: 30000 }
  initialDelaySeconds: 180                    # Kimi K2 权重加载慢
  periodSeconds: 10
  failureThreshold: 120                       # 容 20 分钟启动
```

### LB (sglang-router 0.3.2)

SGLang 0.5.10 **删除了** 内建的 `sglang.srt.disaggregation.launch_lb`。必须 pip install `sglang-router`：
```bash
pip install sglang-router==0.3.2
python3 -m sglang_router.launch_router \
  --pd-disaggregation \
  --prefill http://sglang-prefill:30000 \
  --decode  http://sglang-decode-0:30000 \
  --decode  http://sglang-decode-1:30000 \
  --host 0.0.0.0 --port 8000
```

启动 launcher 在 `ROLE=lb` 时会自动执行上面的 pip + launch。

### 部署 + 等 Ready

```bash
kubectl apply -f stage4-p5en/disagg-1p2d-kimi.yaml

# 预计 7 min，3 个 Deployment 全部 1/1
kubectl -n yanxi-validation wait deployment/sglang-prefill \
                                  deployment/sglang-decode-0 \
                                  deployment/sglang-decode-1 \
                                  deployment/sglang-lb \
  --for=condition=Available --timeout=1200s
```

---

## Step 4 — 验证 EFA 激活（重要）

部署完后检查 prefill log 有以下关键行：
```bash
kubectl -n yanxi-validation logs -l role=prefill --tail=400 | grep -E "EfaTransport|CQ polling|Auto-split|Chunk.*registered"
```

期望输出（Henan 4 个 PR 全激活）：
```
I topology.cpp:124]       Device rdmap{85..88,110..113,135..138,160..163}s0 port 1 is available  ×16
I transfer_engine_py.cpp:198] Topology discovery complete for EFA. Found 16 devices.
I efa_transport.cpp:94]    [EFA] AWS Elastic Fabric Adapter transport initialized
I efa_transport.cpp:113]   EfaTransport: Started 16 CQ polling worker threads              # PR #1821
I efa_transport.cpp:278]   Auto-split params: page_size=4096, max_pte_entries=23068672...  # PR #1912
W efa_transport.cpp:486]   Chunk 0/1 registered on 16 NICs, duration=10ms                   # PR #1821
```

若看到 `Installing TCP transport` **替代** EFA transport，说明 sed patch 没生效 → 检查 `${MC_PY}` 路径是否对（某些镜像版本 sglang 装在 `site-packages` 而非 `dist-packages`）。

---

## Step 5 — Smoke test

```bash
kubectl -n yanxi-validation run smoke-k --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --timeout=300s \
  --overrides='{"spec":{"tolerations":[{"key":"nvidia.com/gpu","operator":"Equal","value":"true","effect":"NoSchedule"}]}}' \
  -- curl -sS --max-time 240 -X POST http://sglang-lb:8000/v1/chat/completions \
     -H "Content-Type: application/json" \
     -d '{"model":"/models/current","messages":[{"role":"user","content":"What is 2+2?"}],"max_tokens":30}'
```

期望：
```json
{"content":"2 + 2 = 4","finish_reason":"stop","completion_tokens":8}
```

---

## Step 6 — Bench sweep

见 `stage4-p5en/bench-kimi-k2.yaml`。核心命令：
```bash
python3 -m sglang.bench_serving \
  --backend sglang-oai-chat \
  --host sglang-lb --port 8000 \
  --model /models/current \
  --tokenizer /models/current \
  --num-prompts 16 \
  --dataset-name random \
  --random-input-len 512 --random-output-len 128 \
  --request-rate ${RATE} \
  --pd-separated \
  --output-file /results/kimi-r${RATE}.json
```

实测数据（rate=1/2/4, 16 prompts × 512in/128out）：

| rate | Mean TTFT | Mean TPOT | Out tok/s | Success |
|---|---|---|---|---|
| 1 | 689 ms | 18.95 ms | 53 | 16/16 |
| 2 | 562 ms | 12.55 ms | 99 | 16/16 |
| 4 | 448 ms | 10.94 ms | 171 | 16/16 |

---

## 故障排查速查

| 现象 | 根因 | 修复 |
|---|---|---|
| Prefill pod `Pending` — `Insufficient nvidia.com/gpu` | GPU Operator 没认出来 | 走 RUNBOOK "2026-04-22 p5en rerun" 段：helm uninstall v24.9.2 → install v25.10.1 with `toolkit.enabled=true --set cdi.enabled=true` |
| 启动 `Invalid IB devices specified` | `-rdm` 后缀没去 | 确认 launcher sed: `sed 's/-rdm$//;s/-dgrm$//'` 之后传 |
| 启动 `huggingface-cli: deprecated` | sglang-mooncake:v2 删了 CLI | 用 `hf download`（脚本已有兼容分支） |
| DeepGEMM JIT 卡 30+ min @ `Entering DeepGEMM JIT Pre-Compile session` | 默认 fp8 backend | 换 `--fp8-gemm-backend cutlass`（~7 min 起）。或离线跑 `python3 -m sglang.compile_deep_gemm` 生成 JIT 缓存烘镜像 |
| 真实请求挂起 90s，warmup 却成功 | sglang 传 `"rdma"` 给 Mooncake，EFA 走不了 | `sed -i 's/"rdma",$/"efa",/' ${MC_PY}` + 删 `.pyc` |
| Decode pod OOM 重启 | `mem-fraction-static` 太高 | Kimi K2 在 H200 上需 **0.92**（权重 ~120 GB/GPU 占 85%）；Llama 8B 用 0.85 就够 |
| 磁盘 `No space left on device` 下模型时 | 没挂 NVMe | `kubectl apply -f nvme-setup.yaml` 后重跑 prefetch |
| sglang-router 报 `HTTP health check failed TimedOut` 但 warmup 成功 | sglang `/health` 拿不到 detokenizer 响应（已知 bug） | 无需处理；真实 `/v1/chat/completions` 仍走通 |

---

## 关键决策（给产品 / 架构评审用）

1. **为什么 CUTLASS 而不是 DeepGEMM？** DeepGEMM 是 H100 优化过的 JIT GEMM，对 FP8 block quant 有 10-30% 吞吐优势，但冷启动每 GEMM shape 都要 JIT 16384 变量 × 61 层 ≈ **3+ 小时**。生产场景建议跑 `sglang.compile_deep_gemm` 预编译，把 cache 烘进镜像 → 切回 DeepGEMM。
2. **为什么用 Mooncake 而不是 NIXL？** 客户（JD）生产栈就用 Mooncake + SGLang；Mooncake Henan post2 在 p5en 上走到 **123 GB/s** DRAM→DRAM（Stage 3 bench）。NIXL v1.0.1 LIBFABRIC 也能走 EFA，是个备选。
3. **为什么 1P:2D 不是 2P:2D？** 本次仅 3 台 p5en 容量，1P:2D 是 3 节点下唯一非退化配置。生产建议 P:D 比例从真实 prompt_len/output_len 数据推出（prefill 多拿 token → P 多；decode batch 大 → D 多）。
4. **FP8 精度够吗？** Kimi K2 官方就是 FP8 block-quantized（`weight_block_size=[128,128]`）；HF repo 里的 `model.safetensors.index.json` 就是 FP8 shard。BF16 版本 (~2TB) 在同样 3 节点 p5en 放不下，除非跨节点 PP。

---

## 相关文件索引

| 文件 | 用途 |
|---|---|
| `stage4-p5en/nvme-setup.yaml` | 8 × NVMe RAID0 DaemonSet |
| `stage4-p5en/model-prefetch-3node.yaml` | 3-node Kimi K2 HF download Job |
| `stage4-p5en/disagg-1p2d-kimi.yaml` | 1P:2D Kimi K2 manifest（ConfigMap + 4 Deploy + 4 Svc） |
| `stage4-p5en/bench-kimi-k2.yaml` | bench sweep Job |
| `results/stage4-p5en/KIMI_K2_RESULTS.md` | 完整验证报告 + 数据表 |
| `RUNBOOK.md` | 整个项目时间线 |

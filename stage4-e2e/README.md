# Stage 4 — SGLang PD 分离 1P:1D + Mooncake KV over EFA

Stage 4 目标：SGLang PD 分离 1P:1D + Mooncake KV over EFA v2。

## 目标

| 形态 | 部署 | 角色 |
|------|------|------|
| (a) baseline | `lws-baseline-tp8.yaml` | 单节点 TP=8，给 PD 分离提供 TTFT/TPOT/OTPS 基线 |
| (b) PD 1P:1D | `lws-prefill.yaml` + `lws-decode.yaml` | **主路径**，跨 2 节点，KV 走 Mooncake EfaTransport |
| (c) EP=16 TP=2 | 暂未落地 | 仅当形态 (b) Decode 侧 MoE all-to-all 成瓶颈时再启；走 UCCL-EP on EFA |

SLA 判据：**(b) 的 TTFT / TPOT ≤ (a) 的 1.3×**，OTPS 达 SLA 假设。

---

## 产物清单

| 文件 | 用途 |
|------|------|
| `../common/Dockerfile.sglang-mooncake` | 镜像：base-cuda-efa + PyTorch (cu126) + SGLang + Mooncake (EfaTransport) + UCCL 源码 |
| `lws-prefill.yaml` | Prefill LWS（size=1）+ headless Service（Mooncake/bootstrap 端点） |
| `lws-decode.yaml` | Decode LWS（size=1）+ ClusterIP Service（OpenAI 兼容 HTTP） |
| `lws-baseline-tp8.yaml` | 单机 TP=8 对照基线 |
| `job-bench-serving.yaml` | ShareGPT + LongBench-style 发压 Job（非 GPU 节点） |

---

## 前置：镜像构建

```bash
# 在堡垒机 → builder 上跑（参考 RUNBOOK.md）
cd <repo_root>
./scripts/build-image.sh \
    common/Dockerfile.sglang-mooncake \
    sglang-mooncake \
    v1 \
    --build-arg=BASE_IMAGE=<AWS_ACCOUNT_ID>.dkr.ecr.us-east-2.amazonaws.com/efa-validation/base-cuda-efa:v1
# 镜像推到：<AWS_ACCOUNT_ID>.dkr.ecr.us-east-2.amazonaws.com/efa-validation/sglang-mooncake:v1
```

镜像构建期间可以并行做模型预热（见下节）。

---

## 前置：模型权重预下载

**强烈建议**先把 `<MODEL_ID>` 预拉到共享存储，避免两个实例各拉一次拖慢冷启动。

两种方案，按可用性选其一：

1. **FSx for Lustre（推荐）**
   - 在集群部署仓库中按 `scripts/option_install_csi_drivers.sh` 装 FSx CSI。
   - 建一个 `StorageClass: fsx-sc` + `PVC: generic-model-weights`（ReadWriteMany，1.2 TB）。
   - 起一个一次性 Pod 在 FSx 上跑 `huggingface-cli download <MODEL_ID> --local-dir /models/generic-model`。
   - 把三个 LWS 里 `volumes.models.emptyDir` 全改成 `persistentVolumeClaim.claimName: generic-model-weights`，并把 `--model-path` 改为 `/models/generic-model`。

2. **S3 预热到节点 NVMe**
   - 在节点启动时通过 userdata / DaemonSet 把权重从 `s3://<bucket>/models/generic-model/` 同步到 `/mnt/nvme/models`。
   - hostPath 挂进去。

> 当前 3 个 LWS 里的 `models` volume 都是 `emptyDir` placeholder，在阶段开始前必须替换。三个 YAML 里都已打上 `TODO: 阶段开始前换 FSx PVC` 标记。

---

## 执行顺序

所有命令在 Ohio 堡垒机 `<OHIO_BASTION_ID>` 上执行。Namespace 统一 `efa-validation`（已由 `common/00-namespace.yaml` 创建）。

### 0. Sanity：确认集群就绪

```bash
kubectl -n efa-validation get sa efa-runner
kubectl get nodes -l node.kubernetes.io/instance-type=p5.48xlarge \
  -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable."nvidia\.com/gpu",EFA:.status.allocatable."vpc\.amazonaws\.com/efa"
# 期望：2 节点都是 gpu=8 efa=32
kubectl get crd leaderworkersets.leaderworkerset.x-k8s.io
```

### 1. 采基线（形态 a）

```bash
kubectl apply -f lws-baseline-tp8.yaml
kubectl -n efa-validation rollout status lws/sglang-baseline-tp8 --timeout=20m
# 跟 probe：initialDelaySeconds=180s，首次健康约 5 分钟
kubectl -n efa-validation logs -f sglang-baseline-tp8-0 | tail -f

# 发压（TARGET_SVC 默认已是 sglang-decode-svc，本步改成 baseline）
sed -i 's|value: "sglang-decode-svc"|value: "sglang-baseline-svc"|' job-bench-serving.yaml
kubectl apply -f job-bench-serving.yaml
kubectl -n efa-validation wait --for=condition=complete job/sglang-bench-serving --timeout=2h
kubectl -n efa-validation logs job/sglang-bench-serving | tail -200 | tee ../logs/stage4-baseline.log

# 清理
kubectl delete -f job-bench-serving.yaml
kubectl delete -f lws-baseline-tp8.yaml
```

### 2. 部署 PD 分离主路径（形态 b）

**必须先 prefill 再 decode**；Decode 启动时会轮询 Prefill `/health`。

```bash
kubectl apply -f lws-prefill.yaml
kubectl -n efa-validation rollout status lws/sglang-prefill --timeout=20m

kubectl apply -f lws-decode.yaml
kubectl -n efa-validation rollout status lws/sglang-decode --timeout=25m

# 两个实例都 Ready 后，复核 Mooncake 握手成功
kubectl -n efa-validation logs sglang-prefill-0   | grep -iE "mooncake|efa|disagg" | tail -30
kubectl -n efa-validation logs sglang-decode-0    | grep -iE "mooncake|efa|disagg" | tail -30
```

### 3. 采 1P:1D 数据

```bash
# 确保 TARGET_SVC 指回 decode
sed -i 's|value: "sglang-baseline-svc"|value: "sglang-decode-svc"|' job-bench-serving.yaml
kubectl apply -f job-bench-serving.yaml
kubectl -n efa-validation wait --for=condition=complete job/sglang-bench-serving --timeout=2h
kubectl -n efa-validation logs job/sglang-bench-serving | tail -200 | tee ../logs/stage4-pd.log
```

### 4. 对比

`../logs/stage4-baseline.log` vs `../logs/stage4-pd.log`，重点看 `TTFT / TPOT / P50 / P95 / P99 / OTPS`。
判 SLA：PD 分离各项 ≤ baseline × 1.3。若不达，分别采集：

- `sglang-prefill-0` 容器内 `/results/prefill.log` 尾部
- `sglang-decode-0`  容器内 `/results/decode.log`  尾部
- 两端 Mooncake transfer 的 transfer 统计（`kubectl exec sglang-prefill-0 -- curl localhost:18000/metrics`）

### 5.（可选）形态 c — UCCL-EP EP=16 TP=2

仅当步骤 4 显示 Decode 侧 MoE all-to-all 是主瓶颈时触发。需新增 `lws-ep16-tp2.yaml`（当前未产出），镜像中已 clone 好 UCCL 源码，启动脚本里加
`pip install -e /opt/uccl && python3 -m sglang.launch_server ... --ep-size 16 --tp-size 2 --expert-parallel-backend uccl`。

---

## TODO（阶段开始前必须解决）

- [ ] `Dockerfile.sglang-mooncake`：锁定 SGLang / Mooncake / UCCL 的具体 commit 或 tag，替换 `main`
- [ ] `lws-prefill.yaml` / `lws-decode.yaml` / `lws-baseline-tp8.yaml`：`volumes.models` 从 `emptyDir` 换 FSx PVC，并把 `--model-path` 指向本地目录
- [ ] `lws-prefill.yaml` / `lws-decode.yaml` / `lws-baseline-tp8.yaml`：`volumes.results` 换共享 PVC 或 S3 sink 以便收集 Mooncake metrics
- [ ] `lws-prefill.yaml` / `lws-decode.yaml`：SGLang `--disaggregation-*` CLI 参数名对齐到选定版本的实际命名（main 线漂移较快）
- [ ] `lws-prefill.yaml`：Mooncake master/engine 的端口与配置文件格式最终对齐（Transfer Engine 的初始化路径）
- [ ] `job-bench-serving.yaml`：`nodeSelector` 指向实际存在的非 GPU 节点标签；LongBench 如需真实数据集改 `--dataset-name` 并挂数据集 PVC
- [ ] 若 Oregon 回切：镜像 URI 的 region 需随 ECR 调整（当前硬编码 `us-east-2`）

---

## 参考

- RUNBOOK：`../RUNBOOK.md`
- 构建脚本：`../scripts/build-image.sh`
- LWS 示例：https://github.com/kubernetes-sigs/lws/tree/main/docs/examples（sglang 目录）
- SGLang disaggregation：https://github.com/sgl-project/sglang（main 分支 docs/router / disaggregation 章节）
- Mooncake EFA：https://kvcache-ai.github.io/Mooncake/getting_started/supported-protocols.html

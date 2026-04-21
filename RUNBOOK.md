# EFA Validation Runbook

**起始时间**：2026-04-21
**执行方式**：本机 AWS CLI + SSM send-command → 堡垒机 EC2 instance (`<OHIO_BASTION_ID>`) → EKS 私有 API

---

## 资产清单

### Region / 集群

| 项 | 值 |
|---|---|
| 主 Region | `us-east-2` (Ohio) |
| Fallback Region | `us-west-2` (Oregon) |
| 主集群 | `<EKS_CLUSTER_NAME_OHIO>`（K8s 1.35，私有 API） |
| Ohio VPC | `<VPC_ID>` |
| Oregon VPC | `<VPC_ID>` |
| GPU Subnet (Ohio) | `<SUBNET_ID>` (`<AWS_AZ>`, CIDR `<VPC_CIDR>`) |
| GPU 节点组 | `gpu-p5-48xlarge-spot`（min=0 max=4 desired=2） |
| GPU SG | `<SECURITY_GROUP_ID>` |

### 堡垒机

| 项 | Oregon | Ohio |
|---|---|---|
| InstanceId | `<OREGON_BASTION_ID>` | `<OHIO_BASTION_ID>` |
| Name | `EKS-Deploy-Bastion-<EKS_CLUSTER_NAME_OREGON>` | `EKS-Deploy-Bastion-<EKS_CLUSTER_NAME_OHIO>` |
| IAM Role | `EKS-Deploy-Role` (AdministratorAccess) | 同 |
| SSM | Online | Online |

### Builder

| 项 | 值 |
|---|---|
| InstanceId | `<BUILDER_ID>` |
| Name | `efa-builder` |
| 初始规格 | m7i.xlarge（2026-04-21 04:22 启动） |
| 升级规格 | m7i.4xlarge（2026-04-21 04:~40 升级，原因：base 层大 + 并行 make 受限） |
| AMI | `<AMI_ID>` (AL2023 ECS x86_64，Docker 预装) |
| Subnet | `<SUBNET_ID>` |
| Root EBS | gp3 200GB |

### ECR

| Repo URI | 用途 | Tag 约定 |
|---|---|---|
| `<AWS_ACCOUNT_ID>.dkr.ecr.us-east-2.amazonaws.com/efa-validation/base-cuda-efa` | 共用基础层（CUDA + EFA + MPI + NCCL + aws-ofi-nccl） | `v1`, `latest` |
| `<AWS_ACCOUNT_ID>.dkr.ecr.us-east-2.amazonaws.com/efa-validation/nccl-tests` | 阶段 1 | `v1`, `latest` |
| `<AWS_ACCOUNT_ID>.dkr.ecr.us-east-2.amazonaws.com/efa-validation/uccl-ep` | 阶段 2 | `v1`, `latest` |
| `<AWS_ACCOUNT_ID>.dkr.ecr.us-east-2.amazonaws.com/efa-validation/sglang-mooncake` | 阶段 3、4 | `v1`, `latest` |

### S3

| Bucket | 用途 |
|---|---|
| `efa-validation-<AWS_ACCOUNT_ID>` | Dockerfile / manifest 分发、日志归档 |

### Kubernetes

| 资源 | 名字 |
|---|---|
| Namespace | `efa-validation` |
| ServiceAccount | `efa-runner` |
| MPI Operator | `mpi-operator` ns，v0.6.0 |
| LeaderWorkerSet | `lws-system` ns，v0.7.0 |

---

## 执行时间线

| 时间 (UTC) | 动作 | 脚本 / Payload | 结果 |
|---|---|---|---|
| 04:10 | AWS 凭证确认、两个集群列表 | 本机 `aws eks list-clusters` | OK |
| 04:11 | 两个堡垒机 SSM 连通检查 | `ssm-payloads/bastion-state-check.json` | Online |
| 04:12 | 两堡垒机 git clone 内部部署仓库 | `scripts/bastion-bootstrap.sh`（见下） | HEAD pinned |
| 04:13 | 两堡垒机注入 `.env`、kubeconfig | `ssm-payloads/bastion-push-env-{oregon,ohio}.json` | kubectl 两边都能列 nodes |
| 04:14 | 切主 region 为 Ohio（Oregon 无 GPU NG，Ohio Spot 稳） | — | — |
| 04:14 | Ohio GPU NG 扩容：desired 0→2，max 1→4 | 本机 `aws eks update-nodegroup-config` | update Successful |
| 04:15 | 2 × p5.48xlarge Spot 起来（`<AWS_AZ>`） | — | `<GPU_NODE_0_ID>`, `<GPU_NODE_1_ID>`  pending→Ready |
| 04:17 | 验证节点资源 | `ssm-payloads/ohio-check-node-alloc.json` | `nvidia.com/gpu: 8`, `vpc.amazonaws.com/efa: 32` ✅ |
| 04:19 | 装 MPI Operator v0.6.0 + LWS v0.7.0 | `ssm-payloads/ohio-install-operators.json` | 全部 Running |
| 04:21 | 创建 3 个 ECR 仓库（base 层后续补） | 本机 `aws ecr create-repository` | OK |
| 04:22 | 启动 builder EC2 (m7i.xlarge, SSM) | `scripts/launch-builder.sh` + `scripts/builder-userdata.sh` | `<BUILDER_ID>` Online |
| 04:23 | 创建 S3 bucket `efa-validation-<AWS_ACCOUNT_ID>` | `aws s3api create-bucket` | OK |
| 04:26 | 创建 Namespace + SA | `ssm-payloads/ohio-apply-ns.json` | OK |
| 04:27 | 第一次 build（单层 Dockerfile，pytorch 24.10 base ~40GB）——**过慢，放弃** | `common/Dockerfile.nccl-tests`（弃用） | base pull 超 5 分钟，放弃 |
| 04:~40 | **决策**：切分层 Dockerfile（`base-cuda-efa` + `nccl-tests`），builder 升 m7i.4xlarge | `common/Dockerfile.base-cuda-efa`、`common/Dockerfile.nccl-tests-v2` | 新 build 进行中 |
| 04:41 | base build 第 2 次失败：EFA installer 需要 `pciutils/environment-modules/tcl`，apt cache 被提前清掉 | 修 Dockerfile：三包预装 + cache 清理延后到 EFA 后 | 继续重试 |
| 04:47 | base build 第 3 次失败：`aws-ofi-nccl v1.14.0-aws` tag 不存在（真实 latest 是 `v1.19.0`） | 升 AWS_OFI_NCCL_VERSION 到 v1.19.0 | 继续重试 |
| 04:56 | base build 终于成功但 push 失败：忘建 ECR repo `efa-validation/base-cuda-efa` | 补建 repo + 手动 push | `base-cuda-efa:v1` 8.76GB 已入 ECR |
| 05:00 | nccl-tests 薄层 build + push 完成 | `nccl-tests:v1+latest` 已入 ECR | — |
| 05:04 | 阶段 1 MPIJob 第 1 次失败：launcher 被调度到 ARM64 eks-utils 节点，x86 镜像报 `exec format error` | 给 Launcher 加 tolerations + `nodeSelector: p5.48xlarge` | 继续 |
| 05:06 | 阶段 1 第 2 次失败：`discover_hosts.sh` 立即执行返回空 HOSTS | 加等待循环直到 worker 数 ≥ 2 | 继续 |
| 05:10 | 阶段 1 第 3 次失败：launcher SSH 到 worker `Permission denied (publickey)` | 根因：OpenSSH `StrictModes yes` 拒绝 kubeflow projected volume (mode 1777) 里的 key | 修 base Dockerfile：`StrictModes no` + 显式 IdentityFile；重构 base:v2 |
| ~06:40 | 阶段 1 ✅ busBW 476.91 GB/s @ 8GB（目标 ≥320，达成 149%） | `results/stage1/SUMMARY.md` | — |
| ~09:20 | 阶段 2 UCCL-EP 镜像 v1 → v2（base:v2 + 修 pip install wheel 问题 → `python setup.py install`） | `common/Dockerfile.uccl-ep` | `uccl-ep:v2` 入 ECR |
| ~09:40 | 阶段 2 v1 尝试：自写 compare_ep.py + DeepEP 对比 → `undefined symbol __cudaRegisterLinkedBinary_*_layout_cu_*`（DeepEP v1.2.1 cu124 预编译 × CUDA 12.6 运行时不匹配） | `stage2-uccl-ep/diag-ep-import.yaml` 独立诊断 | 确认 UCCL-EP 加 `torch/lib` 到 LD_LIBRARY_PATH 后可 import；DeepEP 无法简单修复 |
| 10:17 | 阶段 2 v2 调整：放弃 DeepEP 对比，改用 upstream `/opt/uccl/ep/bench/test_low_latency.py` 跑 UCCL-EP 自身一致性 | `stage2-uccl-ep/mpijob-uccl-upstream.yaml` + wrapper.sh 翻译 OMPI→torchrun env | — |
| 10:22 | 阶段 2 ✅ 16 rank 全通过：`All correctness tests passed` × 16；Dispatch+Combine ~6.9~7.0 GB/s/rank | `results/stage2/SUMMARY.md`、`results/stage2/uccl-upstream-full.log` | — |
| 09:31 | 阶段 3 Mooncake/NIXL 镜像首 build 失败：NIXL v1.0.1 的 python binding 由 meson install 放在 `/opt/nixl/lib/python3/dist-packages/nixl_cu12`，不再有 setup.py | 修 Dockerfile 去掉 pip install，改 PYTHONPATH | 继续 |
| 10:11 | 阶段 3 build 第 2 次失败：`fi_info -p efa` 在 builder 里返回 `-61 No data available`（非致命） | 放宽 sanity check 容忍无 EFA | 继续 |
| 10:17 | 阶段 3 build 第 3 次 ✅：镜像 8.67 GB，tag `v1+latest` 入 ECR | `common/Dockerfile.mooncake-nixl` | — |
| 10:29 | 阶段 3.1 apply：metadata Deployment + target Pod + initiator Pod（headless svc `mooncake-bench`） | `stage3-mooncake-nixl/mooncake-efa-bench.yaml` + `ssm-payloads/apply-mooncake-bench.json` | 运行中 |
| 10:47 | **阶段 3.1 smoke ✅ 19.31 GB/s write** / 60.11s / 4324 batches (block=4MiB,threads=12)；**未达 Plan 150 GB/s 目标**（~8×差距），调优留后续 | `results/stage3/SUMMARY.md` | — |
| 10:52 | 阶段 4 sglang-mooncake:v1 镜像 build + push（SGLang 0.4.10.post2 on mooncake-nixl:v1） | `common/Dockerfile.sglang-mooncake` + `common/sglang-launcher.sh` | 12.4GB 入 ECR |
| 11:46 | 阶段 4 模型选型踩坑：Qwen2.5-7B (28 heads) TP=8 失败 → Qwen2.5-14B (40 heads) 43.7GB 撑爆节点 50GB root → SmolLM2-1.7B (32 heads, 3.4GB) | `stage4-sglang-mooncake/model-prefetch.yaml` 双节点 topologySpread | 勉强塞下 |
| 12:14 | **阶段 4 baseline TP=8 ✅**：Mean TTFT 430ms / Mean ITL 7.19ms / 128 prompts × 1024/256 tok，output 9795 tok/s | `results/stage4/SUMMARY.md` | — |
| 12:31 | **阶段 4 1P:1D smoke ✅**：Mean TTFT 3320ms (7.7× baseline ❌) / Mean ITL 3.79ms (0.53× baseline ✅) / output 2994 tok/s | `stage4-sglang-mooncake/disagg-1p1d.yaml` + `bench-serving-disagg.yaml` | TPOT 达标；TTFT 未达 1.3× 目标，原因 req-rate=inf 并发洪峰 + 模型太小 |
| 10:30 | 阶段 3.1 v1 失败：`http-metadata-server-python` 是目录/库（bootstrap_server.py），不能直接 `python3 执行` | 改用 Go 版 `http-metadata-server`（image 自带 Go 1.23）：`go mod tidy && go build` → 独立 Deployment | 继续 |
| 10:34 | 阶段 3.1 v2 失败：Mooncake 客户端 `PUT /?key=...` 返回 404（GIN 只挂了 `/metadata`） | metadata_server URL 加 `/metadata` path | 继续 |
| 10:38 | 阶段 3.1 v3 smoke ✅：EFA endpoint 全起来（32 设备 × 2 节点），`write` 跑 8 batches 0.02 GB/s；建链占绝大部分时间 | — | 调参继续 |
| 10:44 | 阶段 3.1 v4 失败：`threads=32 block=8MiB duration=60` → `FAILED`（CQ/CPU 饱和） | 回退到 upstream `efa_latency_bench.py` 默认 `threads=12` | 继续 |
| 10:47 | **阶段 3.1 ✅ 19.31 GB/s write，duration 60.11s, batch count 4324**（block=4MiB, batch=64, threads=12, DRAM→DRAM） | `results/stage3/SUMMARY.md` + `results/stage3/mooncake-init.log` | — |


---

## 产物索引

- Dockerfile：`common/Dockerfile.base-cuda-efa`, `common/Dockerfile.nccl-tests-v2`
- 手动 SSM payload：`ssm-payloads/*.json`
- 脚本：`scripts/*.sh`
- 阶段 manifest：`manifests/stage1-*.yaml`（生成后）
- 日志：`logs/stage0-setup/*`

---

## 决策 / 偏离记录

| 日期 | 决策 | 原因 |
|---|---|---|
| 2026-04-21 | 主 region 用 Ohio 而非原计划 Oregon | Ohio 已有 GPU NG + 模板；Spot 价 $10.6 vs Oregon $13–22 且稳定；节省搭建时间 |
| 2026-04-21 | 不为 GPU NG 加 Cluster Placement Group | 同 subnet 已够用；若阶段 1 all-reduce 达不到判据再回头加 |
| 2026-04-21 | 改用分层 Dockerfile（base + per-stage） | 避免重复构建 CUDA/EFA/NCCL；需求明确要求记录入仓、价格不是主要因素 |

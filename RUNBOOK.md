# JoyAI EFA 验证 RUNBOOK

**起始时间**：2026-04-21
**关联方案**：[`../EFA_Validation_Plan.md`](../EFA_Validation_Plan.md)
**负责人**：AWS Account Team (JD)
**执行方式**：本机 AWS CLI + SSM send-command → Ohio 堡垒机 (`i-0341d214635c1ca74`)

---

## 资产清单

### Region / 集群

| 项 | 值 |
|---|---|
| 主 Region | `us-east-2` (Ohio) |
| Fallback Region | `us-west-2` (Oregon) |
| 主集群 | `gpu-cluster-ohio`（K8s 1.35，私有 API） |
| Ohio VPC | `vpc-0bcb622cffd226d26` |
| Oregon VPC | `vpc-081ea929da61b21d7` |
| GPU Subnet (Ohio) | `subnet-0c86f1c69e4067890` (us-east-2b, 10.1.12.0/24) |
| GPU 节点组 | `gpu-p5-48xlarge-spot`（min=0 max=4 desired=2） |
| GPU SG | `sg-067fb33ae2c309f5f` |

### 堡垒机

| 项 | Oregon | Ohio |
|---|---|---|
| InstanceId | `i-081b2b010b6af530c` | `i-0341d214635c1ca74` |
| Name | `EKS-Deploy-Bastion-gpu-cluster-oregon` | `EKS-Deploy-Bastion-gpu-cluster-ohio` |
| IAM Role | `EKS-Deploy-Role` (AdministratorAccess) | 同 |
| SSM | Online | Online |

### Builder

| 项 | 值 |
|---|---|
| InstanceId | `i-0f6dc7baf7825b30f` |
| Name | `yanxi-builder` |
| 初始规格 | m7i.xlarge（2026-04-21 04:22 启动） |
| 升级规格 | m7i.4xlarge（2026-04-21 04:~40 升级，原因：base 层大 + 并行 make 受限） |
| AMI | `ami-03f272c8e6091aa73` (AL2023 ECS x86_64，Docker 预装) |
| Subnet | `subnet-06b9c08e3273826ca` |
| Root EBS | gp3 200GB |

### ECR

| Repo URI | 用途 | Tag 约定 |
|---|---|---|
| `788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/base-cuda-efa` | 共用基础层（CUDA + EFA + MPI + NCCL + aws-ofi-nccl） | `v1`, `latest` |
| `788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/nccl-tests` | 阶段 1 | `v1`, `latest` |
| `788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/uccl-ep` | 阶段 2 | `v1`, `latest` |
| `788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/sglang-mooncake` | 阶段 3、4 | `v1`, `latest` |

### S3

| Bucket | 用途 |
|---|---|
| `yanxi-validation-788668107894` | Dockerfile / manifest 分发、日志归档 |

### FSx for Lustre（模型权重缓存，2026-04-24 起）

| Region | FileSystemId | Lustre | MountName | Subnet / AZ | SG | 类型 | 容量 | Name |
|---|---|---|---|---|---|---|---|---|
| us-east-2 | `fs-0e7e1313a9c964d34` | 2.15 | `5w7shb4v` | `subnet-0c86f1c69e4067890` / us-east-2b | `sg-062ae2f53a5e61e49` | SCRATCH_2 | 2400 GiB | `yanxi-model-cache` |
| us-west-2 | `fs-079832d056597a33b` | 2.15 | `tjvijb4v` | `subnet-0343696171ce4cdc9` / us-west-2b | `sg-0c2f826221429c8f3` | SCRATCH_2 | 2400 GiB | `yanxi-model-cache` |

> 首版（08:01 起的 `fs-0adb0b44ce313faea` / `fs-0a0a98a5f21d6f9fc`）为 Lustre 2.10，与 AL2023 自带 2.15.6 client 不兼容；于 09:50-10:00 UTC 删库重建到 2.15。`fsx-create.sh` 现已 pin `FSX_LUSTRE_VERSION=2.15`。

生命周期脚本（全部幂等）：`scripts/fsx-{lib,sg-setup,create,status,destroy,apply-pvpvc}.sh`。
CSI / PV / PVC 资料：`manifests/fsx/README.md`、`manifests/fsx/pv-pvc.yaml.tpl`。
基于 FSx 的模型预取：EC2 Spot 一次性 prefetcher（`scripts/prefetch-models-{launch.sh,userdata.sh.tpl}`）或 K8s Job（`stage4-p5en/model-prefetch-fsx.yaml`）。

### Kubernetes

| 资源 | 名字 |
|---|---|
| Namespace | `yanxi-validation` |
| ServiceAccount | `yanxi-runner` |
| MPI Operator | `mpi-operator` ns，v0.6.0 |
| LeaderWorkerSet | `lws-system` ns，v0.7.0 |

---

## 执行时间线

| 时间 (UTC) | 动作 | 脚本 / Payload | 结果 |
|---|---|---|---|
| 04:10 | AWS 凭证确认、两个集群列表 | 本机 `aws eks list-clusters` | OK |
| 04:11 | 两个堡垒机 SSM 连通检查 | `ssm-payloads/bastion-state-check.json` | Online |
| 04:12 | 两堡垒机 git clone `eks-cluster-deployment` | `scripts/bastion-bootstrap.sh`（见下） | HEAD `fca8aa6` |
| 04:13 | 两堡垒机注入 `.env`、kubeconfig | `ssm-payloads/bastion-push-env-{oregon,ohio}.json` | kubectl 两边都能列 nodes |
| 04:14 | 切主 region 为 Ohio（Oregon 无 GPU NG，Ohio Spot 稳） | — | — |
| 04:14 | Ohio GPU NG 扩容：desired 0→2，max 1→4 | 本机 `aws eks update-nodegroup-config` | update `4d281993-…` Successful |
| 04:15 | 2 × p5.48xlarge Spot 起来（us-east-2b） | — | i-0fbc…, i-0114…  pending→Ready |
| 04:17 | 验证节点资源 | `ssm-payloads/ohio-check-node-alloc.json` | `nvidia.com/gpu: 8`, `vpc.amazonaws.com/efa: 32` ✅ |
| 04:19 | 装 MPI Operator v0.6.0 + LWS v0.7.0 | `ssm-payloads/ohio-install-operators.json` | 全部 Running |
| 04:21 | 创建 3 个 ECR 仓库（base 层后续补） | 本机 `aws ecr create-repository` | OK |
| 04:22 | 启动 builder EC2 (m7i.xlarge, SSM) | `scripts/launch-builder.sh` + `scripts/builder-userdata.sh` | i-0f6dc… Online |
| 04:23 | 创建 S3 bucket `yanxi-validation-788668107894` | `aws s3api create-bucket` | OK |
| 04:26 | 创建 Namespace + SA | `ssm-payloads/ohio-apply-ns.json` | OK |
| 04:27 | 第一次 build（单层 Dockerfile，pytorch 24.10 base ~40GB）——**过慢，放弃** | `common/Dockerfile.nccl-tests`（弃用） | base pull 超 5 分钟，放弃 |
| 04:~40 | **决策**：切分层 Dockerfile（`base-cuda-efa` + `nccl-tests`），builder 升 m7i.4xlarge | `common/Dockerfile.base-cuda-efa`、`common/Dockerfile.nccl-tests-v2` | 新 build 进行中 |
| 04:41 | base build 第 2 次失败：EFA installer 需要 `pciutils/environment-modules/tcl`，apt cache 被提前清掉 | 修 Dockerfile：三包预装 + cache 清理延后到 EFA 后 | 继续重试 |
| 04:47 | base build 第 3 次失败：`aws-ofi-nccl v1.14.0-aws` tag 不存在（真实 latest 是 `v1.19.0`） | 升 AWS_OFI_NCCL_VERSION 到 v1.19.0 | 继续重试 |
| 04:56 | base build 终于成功但 push 失败：忘建 ECR repo `yanxi/base-cuda-efa` | 补建 repo + 手动 push | `base-cuda-efa:v1` 8.76GB 已入 ECR |
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
| 10:17 | 阶段 3 build 第 3 次 ✅：镜像 8.67 GB，digest `sha256:…762ebb`，tag `v1+latest` 入 ECR | `common/Dockerfile.mooncake-nixl` | — |
| 10:29 | 阶段 3.1 apply：metadata Deployment + target Pod + initiator Pod（headless svc `mooncake-bench`） | `stage3-mooncake-nixl/mooncake-efa-bench.yaml` + `ssm-payloads/apply-mooncake-bench.json` | 运行中 |
| 10:47 | **阶段 3.1 smoke ✅ 19.31 GB/s write** / 60.11s / 4324 batches (block=4MiB,threads=12)；**未达 Plan 150 GB/s 目标**（~8×差距），调优留后续 | `results/stage3/SUMMARY.md` | — |
| 10:52 | 阶段 4 sglang-mooncake:v1 镜像 build + push（SGLang 0.4.10.post2 on mooncake-nixl:v1） | `common/Dockerfile.sglang-mooncake` + `common/sglang-launcher.sh` | ECR digest `52662fa02023...610ddb6`, 12.4GB |
| 11:46 | 阶段 4 模型选型踩坑：Qwen2.5-7B (28 heads) TP=8 失败 → Qwen2.5-14B (40 heads) 43.7GB 撑爆节点 50GB root → SmolLM2-1.7B (32 heads, 3.4GB) | `stage4-sglang-mooncake/model-prefetch.yaml` 双节点 topologySpread | 勉强塞下 |
| 12:14 | **阶段 4 baseline TP=8 ✅**：Mean TTFT 430ms / Mean ITL 7.19ms / 128 prompts × 1024/256 tok，output 9795 tok/s | `results/stage4/SUMMARY.md` | — |
| 12:31 | **阶段 4 1P:1D smoke ✅**：Mean TTFT 3320ms (7.7× baseline ❌) / Mean ITL 3.79ms (0.53× baseline ✅) / output 2994 tok/s | `stage4-sglang-mooncake/disagg-1p1d.yaml` + `bench-serving-disagg.yaml` | TPOT 达标；TTFT 未达 1.3× 目标，原因 req-rate=inf 并发洪峰 + 模型太小 |
| 10:30 | 阶段 3.1 v1 失败：`http-metadata-server-python` 是目录/库（bootstrap_server.py），不能直接 `python3 执行` | 改用 Go 版 `http-metadata-server`（image 自带 Go 1.23）：`go mod tidy && go build` → 独立 Deployment | 继续 |
| 10:34 | 阶段 3.1 v2 失败：Mooncake 客户端 `PUT /?key=...` 返回 404（GIN 只挂了 `/metadata`） | metadata_server URL 加 `/metadata` path | 继续 |
| 10:38 | 阶段 3.1 v3 smoke ✅：EFA endpoint 全起来（32 设备 × 2 节点），`write` 跑 8 batches 0.02 GB/s；建链占绝大部分时间 | — | 调参继续 |
| 10:44 | 阶段 3.1 v4 失败：`threads=32 block=8MiB duration=60` → `FAILED`（CQ/CPU 饱和） | 回退到 upstream `efa_latency_bench.py` 默认 `threads=12` | 继续 |
| 10:47 | **阶段 3.1 ✅ 19.31 GB/s write，duration 60.11s, batch count 4324**（block=4MiB, batch=64, threads=12, DRAM→DRAM） | `results/stage3/SUMMARY.md` + `results/stage3/mooncake-init.log` | — |

### 2026-04-22 (p5en rerun with Mooncake v0.3.10.post2 全 Henan EFA PR)

| 时间 | 动作 | 脚本 / Payload | 结果 |
|---|---|---|---|
| 13:27 | 3× p5en.48xlarge 加入 `gpu-cluster-ohio` (us-east-2a)，EFA v3 (16×200Gb) | 客户侧 eks-cluster-deployment 脚本 | Ready |
| ~14:30 | p5en GPU Operator v24.9.2 validator/device-plugin 全卡 `Init:0/4`；Pod sandbox 报 `no runtime for "nvidia"` | `kubectl describe` 定位 | 诊断完成 |
| 14:45 | 定位根因：containerd 2.2.1 + CUDA 13 + driver 580 + p5en H200 → Operator v24.9.2 的 toolkit 配不出 containerd nvidia runtime | - | - |
| 14:50 | p5 节点打 `nvidia.com/gpu.deploy.*=false` label exclude，保护客户正在跑的 sglang-tp16 | `kubectl label` | OK |
| 15:03 | **uninstall gpu-operator v24.9.2**（helm status failed） | `helm uninstall` | Clean |
| 15:05 | **install gpu-operator v25.10.1**，`--set toolkit.enabled=true --set cdi.enabled=true --set cdi.default=true --set driver.enabled=false` | `helm upgrade --install` | STATUS: deployed |
| 15:06 | 3 p5en 全部 `nvidia.com/gpu: 8` / `vpc.amazonaws.com/efa: 16` Allocatable | `kubectl get node` | ✅ |
| 15:10 | **gpu-smoke pod ✅** `/dev/nvidia0..7` + nvidia-smi 看到 H200 141GB（CUDA 13.0 driver 580） | `gpu-smoke-p5en.yaml` | ✅ 全修复 |
| 15:15 | 批量 sed manifests: `p5.48xlarge→p5en.48xlarge`, `efa:32→16` | in-place 改所有 stage*-*/ | 11 files patched |
| 15:20 | **stage 1 ✅ NCCL all-reduce 479.97 GB/s @ 8GB** (vs p5 476.91), Avg bus BW 178.94 (vs 172.31) | `stage1-nccl-tests/mpijob-nccl-tests.yaml` | 判据 320 GB/s，达 150% |
| 15:28 | Mooncake v2 镜像 build 失败：`WITH_STORE_RUST=ON requires WITH_STORE=ON` | 加 `-DWITH_STORE_RUST=OFF` | 继续 |
| 15:40 | **stage 2 ✅ UCCL-EP 36.49–36.64 GB/s/rank** (vs p5 6.92, **5.2×**) + 16/16 correctness PASS | `stage2-uccl-ep/mpijob-uccl-upstream.yaml` | H200 HBM3e 带来的巨大跃进 |
| 15:44 | **mooncake-nixl:v2 镜像 build ✅** (MOONCAKE_REF=e1d6d6f6f4 = v0.3.10.post2 SHA，含 Henan 4 PRs #1509/#1523/#1821/#1912) | `scripts/build-image.sh common/Dockerfile.mooncake-nixl mooncake-nixl v2` | ECR digest 7216c138 |
| 15:42 | Stage 3 VRAM 路径 target SIGSEGV（exit 139）于 `Allocating memory on GPU 0` 之后 | `stage3-mooncake-nixl/mooncake-efa-bench-A-vram.yaml` | Deferred 待排查 |
| 15:50 | **stage 3 DRAM ✅ 123.20 GB/s** / duration 60.03s / batch_count 27553 (t=12, blk=4MiB) | `stage3-mooncake-nixl/mooncake-efa-bench.yaml` | vs p5 19.31 = **6.4×** |
| 15:50 | Henan PR 全部生效证据: `Started 16 CQ polling worker threads` (#1821), `Auto-split params: page_size=4096 max_pte_entries=23068672` (#1912), `Chunk 0/1 registered on 16 NICs duration=427ms` (#1821) | initiator log | ✅ |
| 16:15 | **sglang-mooncake:v2 镜像 build ✅** (base mooncake-nixl:v2 + sglang 0.5.10 + 依赖 torch 2.9.1 / nvshmem-cu12 3.3.20 / nccl-cu12 2.27.5) | `scripts/build-image.sh common/Dockerfile.sglang-mooncake sglang-mooncake v2` | ECR digest aa7f2f6f |
| 16:30 | **sglang 0.5.10 + Mooncake post2 boot ✅** (import OK, TransferEngine 类加载 OK, disagg CLI 全存在) | `stage4-p5en/sglang-bootcheck.yaml` | Stage 4 PD 模型 prefetch 留给下次窗口 |

### 2026-04-22 关键发现

1. **H200 vs H100 在 MoE EP 小消息场景带来 5×** 增长（Stage 2 UCCL-EP）
2. **multi-NIC striping + PTE auto-split** 让 DRAM 路径 **123 GB/s**，打破之前"40 GB/s 天花板"（Stage 3）
3. **GPU Operator v25.10.1 + toolkit.enabled=true** 是 containerd 2.2 + CUDA 13 + H200 的正确配方
4. **sglang 0.5.10 CLI 与 0.4.x 二进制兼容**，新增 `--moe-a2a-backend`（绑 UCCL-EP 的原生入口） / `--hicache-storage-backend` / `--elastic-ep-backend`

### 2026-04-22 Stage 4 p5en 1P:2D 部署 + 真实请求阻塞

| 时间 | 动作 | 脚本 / Payload | 结果 |
|---|---|---|---|
| 17:00 | 3 节点模型预取（SmolLM2-1.7B 3.4GB/节点） | `stage4-p5en/model-prefetch-3node.yaml` | 3/3 Completed（`hf download` 替 `huggingface-cli`） |
| 17:13 | 1P:2D apply（3 × sglang-mooncake:v2, TP=8, podAntiAffinity 跨 3 节点） | `stage4-p5en/disagg-1p2d.yaml` | P on 10-1-11-108, D0 on 197, D1 on 93 |
| 17:20 | LB crash-loop（0.5.10 删除 `sglang.srt.disaggregation.launch_lb`） | — | 改用 `sglang_router.launch_router --pd-disaggregation`（pip sglang-router==0.3.2） |
| 17:25 | sglang-router 0.3.2 ✅ 识别 1P + 2D worker + tokenizer | — | workflow `activate_workers`/`register_tokenizer` 完整跑通 |
| 17:40 | 首次真实请求：prefill 接到 `#new-token: 1 #inflight-req: 1`，decode 侧无 KV 收到，60s 超时 | mooncake post2 RDMA 协议未被激活（C++ 日志只显 `Installing TCP transport`） | 加 `MOONCAKE_PROTOCOL=rdma` + `MOONCAKE_DEVICE=auto-discovery` env + `mem-fraction-static 0.70` |
| 17:45 | 修 `disaggregation-ib-device=rdmapXXXs0`（去 `-rdm` 后缀），16 × EFA 设备都纳入 | `_validate_ib_devices` 接受 | — |
| 18:00 | 新 pods 起来，warmup ✅ (`End of prefill disaggregation mode warmup status 200`) | — | — |
| 18:05 | 真实 `/v1/chat/completions` 通过 sglang-router ❌ 挂起 90s 超时；直 POST prefill 带 `bootstrap_room` ❌ 同样挂起 | 根因：Mooncake post2 p5en EFA KV 数据面不通（即便 MOONCAKE_PROTOCOL=rdma） | 阻塞在 KV 交接；留作 deferred；详情见 `results/stage4-p5en/DISAGG_1P2D_SWEEP.md` |

### 2026-04-22 Stage 4 1P:2D 根因 + 完整解决

**根因**: sglang 0.5.10 的 `mooncake_transfer_engine.py:186` 硬编码 `protocol="rdma"`，映射到 Mooncake C++ `RdmaTransport`（libibverbs 路径），而 EFA 不支持标准 RC QP `ibv_post_send`——所以真实 KV 传输永远卡在 CQ poll。

**修复**（1 行 sed）: launcher 启动时 `sed -i 's/"rdma",$/"efa",/' .../mooncake_transfer_engine.py` 让 Mooncake 激活 `EfaTransport`（libfabric efa provider + Henan 4 PRs）。

**验证**：启动日志出现 `[EFA] AWS Elastic Fabric Adapter transport initialized` + `Topology discovery complete for EFA. Found 16 devices`。

| 时间 | 动作 | 结果 |
|---|---|---|
| 23:05 | patch rolled，3 pod ready, EFA 16 NIC 全识别 | ✅ |
| 23:10 | Smoke `Say hi in 5 words` → `Hi, bro!` | ✅ 首个 cross-node Mooncake EFA KV 成功 |
| 23:12 | Bench sweep rate=4: 128/128, Mean TTFT 570ms, out 499 tok/s | — |
| 23:13 | Bench sweep rate=8: 128/128, Mean TTFT **41ms**, out 996 tok/s | ✅ |
| 23:13 | Bench sweep rate=16: 128/128, Mean TTFT **73ms**, out **1974 tok/s**, total **9655 tok/s** | ✅ 未饱和 |

**对比 p5 baseline (2026-04-21)**: Mean TTFT 3320 → 73 ms（**46×** 更好），Mean ITL 3.79 → 1.46 ms（**2.6×** 更好），success 128/128 无回归。

完整数据见 `results/stage4-p5en/DISAGG_1P2D_SWEEP.md`。

### 2026-04-23 Kimi-K2-Instruct-0905 (1T MoE FP8) 1P:2D ✅ PASS

**目标**: 在同一 3 × p5en + Mooncake EFA 栈上跑 Moonshot 最大的开放 checkpoint。959 GB on-disk，120 GB/GPU 权重。

| 时间 | 动作 | 结果 |
|---|---|---|
| 00:00 | 挂 p5en × 8 NVMe RAID0（28TB/node）到 `/var/lib/yanxi-models` | DaemonSet，nsenter + mdadm，一次性 |
| 00:02 | `hf download moonshotai/Kimi-K2-Instruct-0905 --max-workers 16` × 3 节点 | 959 GB，15 min |
| 00:20 | 首次部署 1P:2D (`mem-frac=0.92`, `--fp8-gemm-backend=deep_gemm` 默认) | **23 min 后仍在 DeepGEMM JIT**（第 7 session @ 34%，预估 3+ 小时） |
| 00:45 | 切 `--fp8-gemm-backend=cutlass` + `--skip-server-warmup` 重部署 | **7 min 到 3/3 Ready** |
| 00:52 | Smoke `"What is 2+2?"` → `"2 + 2 = 4"` ✅ (8 tok) | **首个 1T MoE cross-node KV over EFA token** |
| 00:55 | Bench sweep 16 prompts × 512in/128out × rate∈{1,2,4} | 48/48 全通 |

**核心数据**（rate=4）：Mean TTFT 448 ms / Mean TPOT 10.94 ms / Out 171 tok/s。对比 Llama-8B @ rate=4：TTFT 2.8×, TPOT 2.6× — **125× 参数 / 4× active 的 MoE 栈在相同 AWS EFA 拓扑上表现出真实可用的延迟**。

完整数据+配置见 `results/stage4-p5en/KIMI_K2_RESULTS.md`。

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
| 2026-04-21 | 改用分层 Dockerfile（base + per-stage） | 避免重复构建 CUDA/EFA/NCCL；客户明确要求记录入仓、价格不是主要因素 |

---

## 2026-04-23 · US Spot Placement Score 扫描（4 台）

**脚本**：`scripts/spot-placement-score.sh`
**结果目录**：`results/sps/latest/`（`SUMMARY.md` 为汇总报告）
**任务**：在 4 个美国 region 针对 `p5.48xlarge / p5e.48xlarge / p5en.48xlarge / p6-b200.48xlarge / p6-b300.48xlarge`，目标 capacity=4，做 region + 单 AZ 两个维度的 SPS 查询。账号未启用 GovCloud，仅 us-east-1/2 + us-west-1/2。

### 扫描 1（11:32 UTC）

- 最高分：`p5.48xlarge` @ us-east-1e = 3，其余全 1。

### 扫描 2（13:46 UTC，再次全美扫描）

- **`p5.48xlarge` @ us-west-2b (usw2-az2) = 9 / 10** ⭐
- **`p5en.48xlarge` @ us-west-2c (usw2-az3) = 9 / 10** ⭐
- `p6-b300.48xlarge` @ us-west-2b = 3（依旧全美唯一可选）
- `p5e.48xlarge` / `p6-b200.48xlarge`：全 1。

**结论**：2 小时内 Oregon Hopper/Blackwell 容量明显松动。如果要真起 4 台，**立刻在 us-west-2b/2c 上打 EC2 Fleet `capacity-optimized`**；SPS 实时变化，真 launch 前要再跑一次。

### 扫描 3（14:22 UTC，APAC 区域）

**脚本**：`scripts/spot-placement-score-apac.sh`
**结果目录**：`results/sps-apac/latest/`

账号 APAC 已启用：ap-south-1 (Mumbai) / ap-east-1 (HK) / ap-northeast-1/2/3 (Tokyo/Seoul/Osaka) / ap-southeast-1/2 (Singapore/Sydney)。未启用：ap-south-2、ap-east-2、ap-southeast-3/4/5/6/7。

**供给矩阵（5 款 GPU × APAC）**：

- `p5.48xlarge`：ap-south-1 / ap-northeast-1 / ap-northeast-2 / ap-southeast-2
- `p5e.48xlarge`：只 ap-southeast-2
- `p5en.48xlarge`：ap-south-1 / ap-northeast-1 / ap-northeast-2
- `p6-b200.48xlarge` / `p6-b300.48xlarge`：**APAC 全部不卖**

**关键结论**：

- **`p5en.48xlarge` @ Tokyo / ap-northeast-1a (apne1-az4) = 5/10** ⭐，是 APAC 唯一非 1 分。
- 其它 APAC 组合全部 1 分。
- APAC 不是 B200/B300 的选项；要 Blackwell 必须走 US。

---

## 2026-04-23 · Stage 5 计划落地

**方案文档**：[`STAGE5_PLAN.md`](./STAGE5_PLAN.md)
**约束**：7 × p5en.48xlarge（H200 × 56 卡），主走 FP8，旗舰不做 FP16。
**执行窗口**：**2026-04-24 ~ 2026-04-30（7 天）**。
**选址首选**：us-west-2c（SPS = 9）。
**候选模型**：Kimi-K2 / DeepSeek-V3.1 / GLM-4.6 / Qwen3-235B-A22B / Qwen3-Next-80B-A3B 全 FP8 MoE；**Day 7 最后追加 GLM-5.1 FP16 收尾 run（R5，4 node TP=16 1P:1D）**。
**重点课题（v2 更新）**：不做 vLLM / Dynamo，客户 Mooncake fork 不可得——本轮只在 **SGLang 0.5.10 + Mooncake upstream**（基线）之上做两条**可插拔组件**的深度调优：
1. **Lane K — NIXL vs Mooncake 技术差异量化**：产出架构差异（`TECH_DELTA.md`）、性能差值（`K_VS_MOONCAKE.md` 含 Δ%）、参数调优（`NIXL_TUNING.md`）、切换可观测项（`SWITCH_OBSERVABLES.md`，事实无评价）。
2. **Lane E — UCCL-EP vs NCCL-EP 技术差异量化**：产出架构差异（`TECH_DELTA.md`）、性能差值（`E_VS_NCCL.md` 含 Δ% + 2→4 节点扩展性）、参数调优（`UCCL_EP_TUNING.md`）、正确性（`CORRECTNESS.md`）、IB 参考标注（`IB_REFERENCE.md`）。
3. 主路径基线：SGLang + Mooncake EfaTransport 做 1P:1D → 3P:4D PD 比例扫描；出 `PD_RATIO_CURVE.md`。

**口径**：客户信息不足，不做"引 / 不引"或"必须 / 非必须"的业务判断；把**两条路径的技术差异和测试差值全部数字化、具象化**，用数据影响客户。`RECOMMENDATIONS.md` 只给技术建议（最优参数、env 白名单、PD 比例），不做决策。

**与客户对齐点（Stage 5 启动前）**：

1. Mooncake 客户 fork 的 delta（chunk / thread / retry）是否能拿到
2. FP16 是否为真生产 SLA（是否仍要跑旗舰 FP16）
3. PD 比例的目标区间（1P:1D / 1P:2D / 1P:3D 哪个最贴近欧洲 MaaS）
4. 投机解码（MTP/EAGLE）是否默认开
5. reasoning 路径权重（V3.1 单 SKU 还是 V3.1 + R1 双 SKU）

---

## 2026-04-24 · FSx for Lustre 模型缓存（两 region 同步上线）

**背景**：每轮 benchmark 都要从 HF 把 Kimi K2 (959 GB) / DeepSeek / Qwen 拉到每个 p5/p5en 节点的本地 NVMe，耗时 15 min+ 且重复，费出站带宽。改成 **FSx for Lustre 共享挂载**：一次下载，整个 region 所有 GPU pod 复用。

**决策理由**（vs S3 Express One Zone）：
- POSIX 原生，`huggingface-cli download --local-dir /fsx/xxx` 零改动；Mountpoint-S3 的 symlink / xattr 限制会污染 HF snapshot 目录结构。
- SCRATCH_2 2400 GiB 基线 480 MB/s、burst ~3 GB/s，足够 3 节点并发 read Kimi K2。
- 单 AZ 与 GPU NG 同 subnet，避免跨 AZ 流量。
- 不跑时 `fsx-destroy.sh --yes` 一条命令销毁，成本可控。

**时间线（UTC）**：

| 时间 | 动作 | 脚本 / 资源 | 结果 |
|---|---|---|---|
| 08:00 | 第一次 create 尝试，SG description 非 ASCII 被拒 | `scripts/fsx-sg-setup.sh` | 修掉 `—` 为 `-` |
| 08:01 | Ohio SG 建立 | `sg-062ae2f53a5e61e49` | 988 + 1018-1023 允许 `sg-067fb33ae2c309f5f`（GPU node） + self |
| 08:01 | Oregon SG 建立 | `sg-0c2f826221429c8f3` | 允许 `sg-0b5a28e11052ef250`（GPU node） + self |
| 08:01 | Ohio FSx 创建（SCRATCH_2 2400 GiB, us-east-2b） | `fs-0adb0b44ce313faea` | CREATING |
| 08:01 | Oregon FSx 创建（SCRATCH_2 2400 GiB, us-west-2b） | `fs-0a0a98a5f21d6f9fc` | CREATING |
| 08:08 | Ohio FSx v1 AVAILABLE | dns=`fs-0adb0b44ce313faea.fsx.us-east-2.amazonaws.com` mount=`xc4chb4v` (Lustre 2.10) | ⚠️ client 不兼容 |
| 08:09 | Oregon FSx v1 AVAILABLE | dns=`fs-0a0a98a5f21d6f9fc.fsx.us-west-2.amazonaws.com` mount=`uqkyjb4v` (Lustre 2.10) | ⚠️ client 不兼容 |
| 09:03 | 两 cluster 装 aws-fsx-csi-driver（helm `kube-system`） | controller ×2 + node DaemonSet | ✅ |
| 09:04 | 渲染并 apply 静态 PV/PVC `yanxi-model-cache` | `scripts/fsx-apply-pvpvc.sh` | ✅ |
| ~09:30 | 发现 AL2023 自带 Lustre client 2.15.6 挂不上 2.10 FSx（`mount.lustre: Invalid argument`） | — | 返工 |
| 09:50 | `fsx-create.sh` pin `FSX_LUSTRE_VERSION=2.15`，删旧库重建 | v1 destroy + v2 create | CREATING |
| 10:00 | Ohio FSx v2 AVAILABLE | dns=`fs-0e7e1313a9c964d34.fsx.us-east-2.amazonaws.com` mount=`5w7shb4v` (Lustre 2.15) | ✅ |
| 10:00 | Oregon FSx v2 AVAILABLE | dns=`fs-079832d056597a33b.fsx.us-west-2.amazonaws.com` mount=`tjvijb4v` (Lustre 2.15) | ✅ |
| 10:00 | PV/PVC 重新 bind 到新 FSx ID | — | ✅ 两 region Bound |
| 10:06 | EC2 Fleet `capacity-optimized` 拉起 m7i prefetcher Spot（两 region 同步，m6in.32xlarge 无 Spot 容量，降级到 m7i.16x/24x） | `scripts/prefetch-models-launch.sh` + `prefetch-models-userdata.sh.tpl` | Ohio `i-0e559f242487cc5f7` / Oregon `i-02606615a4464114a`，在跑 |
| 12:44 | 两 region PVC 状态复查（via bastion SSM） | `yanxi-model-cache` | ✅ Bound / RWX / 2400Gi（Ohio `Used By: fsx-ls` smoke pod） |
| 12:45 | 提 P Spot quota 1152 → 1344 vCPU | `L-7212CCBC` | Ohio req `40f36b30…xgSLbMSo` PENDING / Oregon req `8a7b5351…o7ymZ4Tz` PENDING |

**踩坑笔记**（写入脚本，避免下次再犯）：
1. Lustre 2.10 vs AL2023 client 2.15.6 不兼容 → `fsx-create.sh` pin `FSX_LUSTRE_VERSION=2.15`。
2. `huggingface_hub` 1.x 取消 `[cli]` extra，入口 `huggingface-cli` → `hf`；UserData 装 `huggingface_hub>=1.0 hf_transfer hf_xet`，直接 `hf download`。
3. m6in.32xlarge 在两个 FSx AZ 当前都无 Spot 容量；`prefetch-models-launch.sh` 用 EC2 Fleet + 9 档 instance type 候选（m6in → m7i → c7i）+ `capacityOptimized` 兜底。FSx SCRATCH_2 burst ~3 GB/s，m7i 25/37.5 Gbps ENA 不是瓶颈。
4. SG description 不能含非 ASCII 字符（`—` 被拒）。

**Prefetcher 下载顺序**（小→大，单实例一次拉完，完成后 self-terminate）：
Qwen3-Next-80B (~85 GB) → Qwen3-235B-A22B-FP8 (~240 GB) → GLM-4.6 (~340 GB) → DeepSeek-V3.1 (~640 GB) → Kimi-K2-Instruct-0905 (~959 GB)。总 ~2.26 TB / region，刚好塞进 2400 GiB SCRATCH_2。

**下一步**：
1. 等 prefetcher 完成（SSM `tail -F /var/log/yanxi-prefetch.log` 观察 `.prefetch-complete` sentinel）
2. 替换原有 `stage4-*/model-prefetch*.yaml` 的 hostPath 为 `persistentVolumeClaim: yanxi-model-cache`
3. 启 4 node p5en → Stage 5 Day 1 正式起跑（日程滑到 04-25）

---

## 2026-04-24 13:00 UTC · Stage 5 规模下调到 4 节点

**背景**：
- SPS cap=7 扫描（13:01 UTC）：us-east-2a=8、us-west-2c=6，其它 AZ=1。最高 8/10 说明 7 节点一起起**大概率拿不齐**。
- 原计划 7 节点要把 Spot quota 从 1152 提到 1344 vCPU，ticket `L-7212CCBC` 两 region 12:45 UTC 提交，仍 `CASE_OPENED`。
- 4 节点只要 768 vCPU，现有 quota 够用，不再阻塞。

**决策**：
- 规模由 **7 → 4 节点**。
- 首选 **us-east-2a**（Ohio，SPS=8），沿用已有 nodegroup `gpu-p5en-spot-useast2a`。
- 砍 **R1d（7 node 2P:5D）** 和 **R1e（7 node 3P:4D）**。PD 曲线只保留 1P:1D / 1P:2D / 1P:3D 三点（decode 扩展）。
- **prefill 侧扩展（2P/3P）放弃**：4 节点预算下，保留 decode 扩展曲线更有信息量。写进最终 `SUMMARY.md` 局限说明，让客户知道这部分不在本轮数据范围内。
- Lane E E-E3（EP=32 跨 4 node）**保留**——4 节点正好够打。
- R5 GLM-5.1 FP16 TP=16 跨 4 node **保留**——4 节点正好够打。

**动作**：
1. `STAGE5_PLAN.md §1.2 / §6 / §9 Day 4 / §10 风险` 同步更新。
2. `manifests/stage5-p5en/r1d-*.yaml`、`r1e-*.yaml` **删除**。
3. Ohio `gpu-p5en-spot-useast2a` nodegroup：`max=7`（保留 headroom），`desired=0`（quota 批下来 / 容量够时可直接拉 4）。
4. Oregon `gpu-p5en-48xlarge-spot`：`max=7`、`desired=0`（备份，不主跑）。
5. **Quota ticket `L-7212CCBC` 可撤回**（两 region）—— 4 节点不需要，撤回免得占 AWS Support 队列；要不要撤待用户确认。

---

## 2026-04-24 14:10 UTC · R6 取消

**结论**：放弃本轮 DeepSeek-V4-Pro 测试，等软件生态进一步完善。

**软件生态现状**（GitHub 查询 14:05 UTC）：
- SGLang main（0.5.10.post1 及之前所有 release）**不含** `deepseek_v4.py`，不支持 `DeepseekV4ForCausalLM`
- 主 tracking PR **#23600 "DeepSeek V4" open，未 merge**（head=`deepseek_v4` @ f5d03db8，base=main）
- 相关修复全 open：#23635（GB200 off-by-one）/ #23626（PP+PD disagg）/ #23639（HiCache）
- Roadmap #23602 明示还未完成：Hopper W4A16、PP、MegaMoE 优化、HiCache、SM120
- 要跑 V4 必须走未 merge 特性分支 + tilelang 0.1.8 + apache-tvm-ffi 0.1.9 + DeepSeek 官方 FlashMLA + 重新 build 一个 dsv4 变体镜像；而 Mooncake EFA 4 PR 与此分支的兼容性**未经验证**
- 决策：不赌未稳定软件栈；等 SGLang V4 支持 merge 回 main 后再做代际对比

**清理动作**：
1. 删 `manifests/stage5-b300/` 目录（含 `r6-ds-v4-pro-1p3d.yaml` + `r6-prefetch-v4-pro.yaml`）
2. `STAGE5_PLAN.md §3` / §6 / §9 Day 7 / §10 R6 相关条目全部 strike-through 并标记取消
3. `manifests/stage5-p5en/` 保留不变（9 个 p5en 的 run）
4. **Oregon FSx 上的 Kimi-K2 `.prefetch-complete` + `.SKIPPED` sentinel 保留不动**——即使 R6 不做，Oregon FSx 容量也本来就放不下 Kimi-K2 + V3.1 + 其它；Ohio 继续主跑 Kimi-K2，Oregon 仅作 Spot 备份
5. `scripts/stage5-render.sh` 新增的 `--instance-type` 参数保留（通用能力，将来需要 b300 再用）

**未来恢复条件**（给下一阶段用）：
- SGLang V4 PR #23600 merge 回 main 且在稳定 release 里
- SGLang + DSv4 + Mooncake EFA 组合有公开验证过
- 重新做 SPS cap=4 @ p6-b300 扫描（usw2-az2 单 AZ）
- 届时 `scripts/stage5-render.sh --instance-type p6-b300.48xlarge --region us-west-2` 一键重渲染即可

---

## ~~2026-04-24 13:45 UTC · R6 追加：DeepSeek-V4-Pro on p6-b300 × 4~~（已取消，见上）

**背景**：客户追加请求 —— 加一个 DeepSeek-V4 Pro（FP8）的测试，用 4 台 p6-b300。

**模型确认**（HF API 查询 2026-04-24 13:45）：
- 官方 `deepseek-ai/DeepSeek-V4-Pro`（latest update 2026-04-24T10:00）
- 已是 FP8 e4m3 + block 128×128；activation_scheme=dynamic；65k rope base + yarn factor 16 = 1M 有效 ctx
- 架构：61 层，hidden 7168，128 attn heads，MLA（q_lora_rank 1536, o_lora_rank 1024），384 routed experts top-6 + 1 shared
- 体积：**865 GB** (64 safetensors 分片)
- SGL 社区也有 `sgl-project/DeepSeek-V4-Pro-FP8`（同 base，同 FP8，2026-04-24T07:43）—— 官方版就是 FP8，**用官方**，少一步 weight conv

**硬件**：
- p6-b300.48xlarge × 4（Oregon usw2-az2，nodegroup `gpu-p6-b300-48xlarge-spot` 已存在，`max=4, desired=0`）
- 规格：8 × B300 / 2.2 TB HBM per node = **8.6 TB HBM total**；192 vCPU；16 EFA NIC
- 865 GB FP8 weight 在 32 × B300 上 **只占 10%**，TP/EP 拓扑非常自由
- SPS cap=4 @ usw2-az2 = **5/10**（可起，有 Spot 回收风险）
- 4 台 = 768 vCPU，现有 P Spot quota 1152 够用

**拓扑决策**：1P:3D TP=8（先摸 decode 扩展；prefill 1 台、decode 3 台，共 4 台）。Day 7 和 R5 **并行**（不同 region / 硬件）。

**FSx 容量问题**：
- Oregon FSx 2400 GiB；当前 1.4 TB used / 800 G free，且 prefetcher 正在下 DSv3.1（338/640 G）；Kimi-K2 959 G 未开始
- 加上 V4 Pro 865 G，**放不下 Kimi-K2**
- 决策：Oregon **砍 Kimi-K2**（Ohio 主跑 Kimi-K2 覆盖 R1/Lane 系列）；Oregon 只拉 R6 必须的 V4 Pro
- 13:50 UTC SSM 在 Oregon prefetcher 上写 `/fsx/Kimi-K2-Instruct-0905/.prefetch-complete` + `.SKIPPED` sentinel，prefetcher 下一轮循环会跳过

**产出**：
1. `manifests/stage5-b300/r6-ds-v4-pro-1p3d.yaml` —— R6 SGLang 1P:3D 部署（复用 `_launcher.yaml` ConfigMap）
2. `manifests/stage5-b300/r6-prefetch-v4-pro.yaml` —— K8s Job 下 V4 Pro 到 Oregon FSx（pre-flight 检查 900 G 可用空间）
3. `scripts/stage5-render.sh` 加 `--instance-type` 参数（默认 p5en.48xlarge，R6 传 p6-b300.48xlarge）
4. `STAGE5_PLAN.md §3 / §6 / §9 Day 7 / §10` 同步

**风险**（已入 §10）：
- p6-b300 × 4 拿不齐（SPS 5）→ 降级 2 节点 1P:1D 或砍
- SGLang 0.5.10 未支持 `model_type=deepseek_v4` → Day -1 验证 import；失败则用 repo 自带 `inference/generate.py`，不出 SGLang 数据
- Oregon FSx 容量 → 已通过 Kimi-K2 skip sentinel 缓解

**下一步**：
1. 等 Oregon prefetcher 把 DSv3.1 下完（可 SSM tail 观察），脚本自动跳过 Kimi-K2 → instance self-terminate
2. kubectl apply `r6-prefetch-v4-pro.yaml` 起 V4 Pro 下载 Job（需 Oregon 有一台 nodegroup 节点或 eks-utils 可调度）
3. Day 7 00:00 UTC 同步 `desired=4` 拉起 p6-b300 NG，apply `r6-ds-v4-pro-1p3d.yaml`

---

## 2026-04-24 Stage 5 Day 0 结（FSx 基建日）

详见 `results/stage5-p5en/2026-04-24_DAY0_SUMMARY.md`。关键动作：
- 两 region FSx SCRATCH_2 2400 GiB Lustre 2.15 全部 AVAILABLE（08:00→10:06 UTC，中间踩 Lustre 2.10 vs AL2023 client 不兼容坑返工一次）
- 模型预取启动：Qwen3-Next-80B ✅ / Qwen3-235B-FP8 / GLM-4.6 / DeepSeek-V3.1 / Kimi-K2 顺序下载，Ohio m6in.16x + Oregon c6in.16x Spot
- 代码：`scripts/fsx-{lib,sg-setup,create,status,destroy,apply-pvpvc}.sh` + `scripts/prefetch-models-{launch,watch}.sh` + `manifests/fsx/pv-pvc.yaml.tpl` 全部入仓

## 2026-04-24 15:13–16:25 UTC · Stage 5 R0 smoke PASS（Oregon）

详见 `results/stage5-p5en/r0-smoke/20260424T151359Z/{STEPS,RESULT,preflight-output}`。关键数字：
- **选址**：us-west-2c (usw2-az3, SPS=9 @ cap=1) —— Ohio SPS 短期跌到 3/2，切 Oregon
- **节点**：`i-016848633dec5b3e8` p5en.48xlarge Spot；scale → Ready 3 min 15 s
- **镜像**：`yanxi/sglang-mooncake:v2` digest `aa7f2f6f…`（Ohio→Oregon 15:06 UTC mirror）
- **preflight 5/5 PASS**：Mooncake 0.3.10.post2 / Henan EFA SO 103 hits / `MC_LEGACY_RPC_PORT_BINDING` / SGLang rdma hardcode 在 line 195 / SGLang 0.5.10
- **冷启动**：pod create → ready **22 min 55 s**，主导是 Qwen3-Next E=512 N=64 MoE Triton kernel JIT（0.5.10 无预编 config，fallback triton_3_4_0 + 重编）
- **generate probe**：`"The capital of France is"` → `"Paris. …Berlin. …Rome. …Madrid. …London."`，e2e 296 ms，5 in / 32 out

## 2026-04-25 03:19–03:56 UTC · Stage 5 切 v5 基线 + R1a 起跑

详见 `results/stage5-p5en/r1a-kimi-k2-1p1d/20260425T033552Z/{STEPS,BUILD_V3}.md`。

| 时间 UTC | 动作 | 结果 |
|---|---|---|
| 02:50 (16:25Z 扫) | SPS cap=2 rescan：us-east-2a=**9** / us-west-2c=4 / us-east-2b=3 | Ohio 重新领先 → R1a 选 Ohio |
| 03:19 | Ohio `gpu-p5en-spot-useast2a` NG desired=0→2 | `i-025388ac45366a78d` + `i-0a599cca49c3a8875` 两节点 Running us-east-2a |
| 03:35 | R1a v2 镜像 apply 触发（第一次起） | — |
| 03:52 | 切 v5 计划 kick-off：`common/Dockerfile.mooncake-nixl` `MOONCAKE_REF=634b7097`（#1944 SRD shared endpoint 合入点）| — |
| 03:56 | builder inspect 发现 Ohio ECR 已有 18h 前预 build 的 `yanxi/{mooncake-nixl,sglang-mooncake}:v5`（`/opt/mooncake` HEAD = `634b709` #1944） | 跳过本地 rebuild，直接用 v5 镜像 |
| 03:56 | v3 自 build 尝试失败于 Dockerfile 尾部 `efa_latency_bench.py` 路径检查（upstream #1944 后文件搬了位置），Dockerfile 已补 tolerate | 本地 rebuild 取消，v3 Dockerfile 改动保留 |
| 03:56+ | Oregon ECR mirror `sglang-mooncake:v5`（pid 3920191 后台）+ 新 manifest `_preflight-image-ohio-v5.yaml` + `r1a-kimi-k2-1p1d-v5.yaml` | 进行中 |

**Stage 5 正式基线**：`yanxi/sglang-mooncake:v5`，Mooncake @`634b7097` + Henan 5 EFA PRs（#1509/#1523/#1821/#1912/#1944）。R0/Stage 1-4 历史数据基于 v2（4 PR，不含 #1944），保留不回改。

**#1944 带来的 Stage 5 关键增量**：
- Cold submit #0：99 ms → **26 ms**（~4×，vLLM/SGLang 自动吃到）
- `warmupSegment()`：17 s（抖动 9/17/17 s）→ **1.1 s**（稳定 1.13/1.13/1.14，~15×）
- **修 VRAM `preTouchMemory` segfault**（Stage 3 挂账的 exit 139 问题 → 关闭）
- **修 teardown `fi_av_remove` after EP close 段错误**
- **移除 `MC_EFA_STRIPING_THRESHOLD`**：p5en sweep 实测 >2 MB 时 20× 负优化，默认不走那条路径
- 新 Python 绑定：`warmup_efa_segment(segment_name) -> int`（Lane K 可扫 on/off）

**上游在 #1944 之后还有一条 #1964 "[TE] reduce reg overhead"**（2026-04-24 01:42Z merge，stmatengss 非 Henan）—— 纯把 `vector<MemoryRegion>` 换成 `map<uintptr_t, MemoryRegion>`（O(N)→O(log N)），**不触 EFA transport 代码**，p5en KV disagg 场景收益近似为零；v5 基线**不追**该 commit，停在 `634b7097`。

**下一步**：
1. 等 Oregon v5 镜像 mirror 完成
2. 起 v5 preflight（新增 SRD shared-endpoint 符号检查作为第 6 项）
3. Apply `r1a-kimi-k2-1p1d-v5.yaml` 跑 R1a Kimi-K2 1P:1D

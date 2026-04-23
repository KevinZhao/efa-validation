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

# R6 B300 — STEPS (流水日志)

**Run**: R6 p6-b300 on Oregon
**Start (UTC)**: 2026-04-25T14:46:09Z
**Operator**: Kevin (via Claude)
**Goal (pending confirmation)**: R6a = 2× p6-b300 1P:1D GLM-4.6-FP8 same-AZ (usw2-az2) — 对照今早 R3 p5 same-AZ PASS (2315 tok/s) 单变量换 GPU/EFA

## 前置事实（14:46Z 已核验）

### SPS（14:34Z 刷新）
| 机型 | AZ | 分数 |
|---|---|---|
| p6-b300.48xlarge | usw2-az2 | **9** |
| p5.48xlarge | usw2-az1/2/3 | 9 |
| p5en.48xlarge | usw2-az3 / use2-az2 | 9 |

B300 唯一容量 AZ：**usw2-az2**（和历史一致，B300 是 single-AZ 现实）

### NG 状态
- Cluster: `gpu-cluster-oregon`
- NG: `gpu-p6-b300-48xlarge-spot`
- Status: ACTIVE, desired=0
- Subnets (4): usw2-az1/az2/az3/az4（跨 AZ，起之前要收窄到 az2）
- LT: `lt-03621a945916bcf2d` v6（有 userdata）
- AMI: `ami-0a84de20b5de8b750`
- Capacity: SPOT, max=4

### 历史参考
- 2026-04-23 该 NG 一次性起 4 node PASS（`results/oregon-probe/B300_RETRY_SUCCESS_2026-04-23.md`），AttachmentLimitExceeded fix 已 merge 到 LT（NIC 0 = ENA only, 16 EFA NICs）
- 节点规格确认：8× B300 GPU × 180 GB HBM3e = 1.44 TB/node，16× 400 Gbps EFA = 6.4 Tbps/node

## Preflight 未知项（起机器前必须先答）

1. **sglang-mooncake:v5 的 CUDA/torch 是否支持 B300 sm_100/sm_103**
   - B300 = Blackwell，要 CUDA 12.8+
   - v5 基于 Ohio build，torch version + CUDA version 待查
   - 检查路径：拉 v5 镜像看 `/usr/local/cuda/version.txt` + `python3 -c "import torch; print(torch.version.cuda, torch.cuda.get_arch_list())"`

2. **LT v6 userdata 是否是 `KevinZhao/eks-cluster-deployment` 新版（auto-LVM /data）**
   - 如是：节点起来直接有 `/data` 27.6 TB
   - 如不是：要手动 setup-nvme 或 LT 升级
   - 检查路径：拉 LT UserData base64 解码看是否含 `GPU_ENABLE_LOCAL_LVM=true`

## 同 AZ 规则（硬约束）

依 `feedback_same_az_all_tests.md`：
- NG subnets 必须收窄到单一 usw2-az2 subnet `subnet-0343696171ce4cdc9`
- Pod spec 加 `nodeAffinity: topology.kubernetes.io/zone=us-west-2b`（双保险）
- 预取 + bench client 也在 az2

---

## 时间线

| Time (UTC) | Event |
|---|---|
| 14:46:09 | STEPS.md 初始化，RESULT.md 占位；preflight 清单确认 |
| 14:52:00 | 用户确认 **R6a**（2× B300 1P:1D GLM-4.6-FP8）。开始 preflight。|
| 14:53:00 | Preflight 1 (LT userdata): **PASS** — `lt-03621a945916bcf2d` v6 含 `setup-local-lvm.sh`，instance-store → `vg_local/lv_scratch` xfs → `/data`，与 Oregon p5 NG 同一套 userdata（`KevinZhao/eks-cluster-deployment`），起来不用手动 setup-nvme |
| 14:54:00 | Preflight 2 (v5 镜像 CUDA/sm_arch): **PARTIAL** — `CLAUDE.md` 声称 v5 基于 `base-cuda-efa:v3`（CUDA 13.0.2 + sm_90/100/103），`results/stage1-p5en/SUMMARY.md` 证实 CUDA 13 / driver 580 在 p5en 稳；但 R1a preflight 只证明 sm_90 (H200) 跑过，**没有 B300 (sm_100) 实跑证据**。v5 image digest `sha256:aeabf68...ba47a70`（Oregon ECR pushed 2026-04-25T04:06Z）|
| 14:55:00 | **决策**：改为两步 scale — 先 desired=1 起 1 node 在 B300 上 preflight `torch.cuda.get_arch_list()` + mooncake/sglang import；PASS 才 scale to 2 + 预取。避免 B300 不能跑 v5 时起两节点空转 |
| 14:55:30 | ASG subnets 收窄：`eks-gpu-p6-b300-48xlarge-spot-f0cedf27-8480-00aa-e577-18c2bdc60ee0` VPCZoneIdentifier 从 4 subnet (az1/2/3/4) 改为单一 `subnet-0343696171ce4cdc9` (usw2-az2)。注意 EKS managed controller 可能后台回退，需快速 scale |
| 14:55:49 | 发起 NG scale desired=1，update id `50cccb5c-354b-3e0a-aec7-c963dfe0cde5`（InProgress）|
| 14:56:17 | Spot fulfilled：`i-0b9007c021273989c` (p6-b300, usw2-az2, IP 10.0.12.111, pending)。28s 从 scale 到 Spot 分配。等 EKS Ready + userdata LVM 完成（~5 min 参考 4-23 数据）|
| 14:59:00 | Oregon bastion `aws eks update-kubeconfig` 建立 `oregon` context。kubectl 可用 |
| 14:59:30 | 节点 Ready：`ip-10-0-12-111.us-west-2.compute.internal`，Ready 后 2m7s。 |
| 14:59:40 | Apply `manifests/stage5-p5en/r6-b300-preflight.yaml`（single-pod，1 GPU，node-selected usw2-az2 + p6-b300.48xlarge）|
| 14:59:44 | Pod scheduled，状态 ContainerCreating — v5 镜像 13 GB，第一次拉约 4-6 min |
| 15:06:47 | Pod **Completed**，preflight 输出（下面结果）|
| 15:07:00 | **Preflight CONDITIONAL PASS** — 摘要： |
|          | • **GPU**: NVIDIA B300 SXM6 AC, compute_cap=**10.3** (sm_103), **HBM=275 GB/卡**（比文档 180 GB/卡大 53%）|
|          | • **torch**: 2.9.1+cu128 / CUDA 12.8 |
|          | • **arch_list**: `['sm_70', 'sm_75', 'sm_80', 'sm_86', 'sm_90', 'sm_100', 'sm_120']` — **没有原生 sm_103**，但 sm_100 PTX 可 JIT |
|          | • Mooncake + sglang 0.5.10 import 通过 |
|          | • `/data` = 28 TB xfs，auto-LVM 成功（vg_local/lv_scratch）|
|          | • 简单 matmul kernel OK（JIT 路径 work，sum=-54808.98）|
|          | • `fi_info -p efa` 报 "-61 no data available" — 因为 preflight pod 未 request `vpc.amazonaws.com/efa` 资源，不是问题；正式 run 会 request 16 NIC |
|          | **残留风险**：sglang 的 FP8 block-scaled MoE fused kernel 没 exercise，sm_103 上是否能 JIT/fallback 未知。2 节点起来后如果 sglang startup 挂 kernel-not-found 立即 abort |
| 15:07:30 | **资源规划更新**：B300 HBM 275 GB/卡 × 8 = **2.2 TB/node**（p5en 1.13 TB 的 2×）。GLM-4.6-FP8 340 GB 权重 + 长 KV → B300 可以轻松 1 pod 容纳，完全不需要 ctx-len 降级 |
| 15:08:00 | 尝试 scale NG desired=2 → **fail**: NG 进入 DEGRADED（`AutoScalingGroupInvalidConfiguration` — ASG subnet=[az2] 与 NG config 期望的 4 subnet 不一致），`update-nodegroup-config` 被阻断 |
| 15:08:30 | **Work-around**: 直接 `aws autoscaling update-auto-scaling-group --desired-capacity 2`（绕过 EKS MNG controller），ASG 仍 pin az2，桨 desired=2 |
| 15:09:29 | Spot fulfilled 第二台：`i-0250a5eebff6bbd50` (p6-b300, usw2-az2, IP 10.0.12.125)，scale 到 Spot 分配仅 ~60s |
| 15:10:30 | 两节点 kubelet Ready：`ip-10-0-12-111` 14m, `ip-10-0-12-125` 56s。EFA=16 双节点。GPU device-plugin 在第二节点尚未报告 GPU=8（预期再等 2-5 min）|
| 15:11:00 | 生成 `manifests/stage5-p5en/_prefetch-hf-glm46-b300.yaml`（2 副本 Indexed Job，nodeSelector p6-b300 + az2，`/data/models` hostPath）|
| 15:11:30 | 生成 `manifests/stage5-p5en/r6a-glm46-1p1d-v5-b300-az2.yaml`（基于 R3 manifest 改 nodeSelector p6-b300 + az2，其它不变）|
| 15:12:00 | Apply prefetch job：`glm46-prefetch-hf-b300`，两节点并行 HF 下载 GLM-4.6-FP8 (~340 GB) 到 `/data/models/GLM-4.6-FP8`。pod-0 已 Running（镜像已缓存），pod-1 ContainerCreating（拉 v5 镜像，~4-6 min）|
| 15:16:57 | Node-0 prefetch Completed。`hf download` 16-worker 真正下载用时 ~5 min（Pod 自 15:12 起，含镜像启动 + 下载）。**`/data/models/GLM-4.6-FP8 = 337 GB, 100 files, sentinel written`** |
| 15:17:17 | Node-1 prefetch 启动下载（镜像 13 GB 先拉了 ~5 min 才开始 hf download）|
| 15:20:10 | Node-1 prefetch Completed。实际 `hf download` **2m53s** 完成 101 文件（比 Node-0 还快，可能是 HF CDN 缓存命中）。**337 GB, sentinel written** |
| 15:21:00 | Job `glm46-prefetch-hf-b300` Complete 2/2，总 duration 7m52s。两节点 `/data/models/GLM-4.6-FP8/.nvme-prefetch-done` 都存在 |
| 15:37:00 | Apply `r6a-glm46-1p1d-v5-b300-az2.yaml`：prefill + decode + lb 三 Deployment 起。podAntiAffinity 生效，pod 分到两节点（prefill→12-125, decode→12-111，都 az2）|
| 15:39:49 | **Mooncake EFA v5 on B300 = PASS**：两 pod 都看到 `libfabric efa (shared endpoint, max_wr=256)` + `EfaTransport: Started 16 CQ polling worker threads` + `max_mr_size=412316860416` (412 GB，p5en ~195 GB 的 2×) |
| 15:40:29 | Init torch distributed ends. elapsed=40 s（TP=8 Gloo 互通）。`avail mem=265.27 GB/GPU` 验证 B300 HBM 275 GB 真实可用 |
| 15:40:42 | FP8 MoE kernel：`Using CompressedTensorsW8A8Fp8MoE`（未报 kernel-not-found，sm_100 PTX JIT 通）|
| 15:48:12 | **CUDA graph capture FAILED** — Triton PTXASError：`--gpu-name=sm_103a` ptxas exit 255 (`Internal Triton PTX codegen error`)。根因：v5 镜像 ptxas 不认 sm_103a 虚拟 arch。Pod Restart 1 次 |
| 15:49:00 | 决策（用户拍板路径 A）：加 `--disable-cuda-graph` + `--attention-backend flashinfer` 重新 apply。代价：decode throughput 损失 30-50%，但 Mooncake EFA v5 整链路通仍有价值 |
| 15:49:30 | Edit `manifests/stage5-p5en/r6a-glm46-1p1d-v5-b300-az2.yaml` launcher COMMON_ARGS 加两个 flag |
| 15:53:46 | Decode pod **"The server is fired up and ready to roll!"**（1/1 Ready）。Mooncake MR 注册 + EFA 16 NIC 全部正常，`Chunk 0/1 registered on 16 NICs, duration=4ms` |
| 15:54:10 | Prefill pod 同样 "ready to roll!"，`[r6a] IB_DEVICE=rdmap{86,87,101,102,116,117,131,132,146,147,161,162,176,177,191,192}s0`（16 NIC 全枚举）|
| 15:57:00 | 尝试 bench：`python3 -m sglang.bench_serving --backend sglang --dataset-name random --num-prompts 128 --request-rate 4 --random-input-len 1024 --random-output-len 512 --host localhost --port 8000 --tokenizer zai-org/GLM-4.6` |
| 15:57:30 | Bench fail：`Service Unavailable: No prefill workers available`。lb 认为 prefill 不 healthy |
| 15:58:00 | 诊断：`curl http://sglang-r6a-prefill.svc:30000/get_model_info` = `Connection refused`。查 prefill log previous：**sglang 的 `running_phase_sigquit_handler` SIGQUIT**，trigger 是 lb 健康检查触发 `health_generate` → decode 路径 → Triton JIT → 又 `ptxas sm_103a exit 255` |
| 16:00:06 | **FAIL #2 确认**：`--disable-cuda-graph` 只 disable CUDA graph capture，**没 disable Triton piecewise kernel**。sglang 0.5.10 的 GLM-MoE FP8 decode 依赖 Triton JIT，B300 sm_103a 上就是坏的 |
| 16:05:00 | 用户拍板路径 C（ABORT 收工），kubectl delete 所有 R6 资源 |
| 16:06:00 | `aws autoscaling update-auto-scaling-group --desired-capacity 0`。两节点 shutting-down |
| 16:06:30 | `aws autoscaling update-auto-scaling-group --vpc-zone-identifier <4 subnet>` 恢复 4 AZ subnet，让 EKS NG DEGRADED 自愈 |
| 16:07:00 | 写 `RESULT.md` + `ABORT.md`，结束本 run |

## 最终状态

- 两 B300 已 shutting-down（`i-0b9007c021273989c`, `i-0250a5eebff6bbd50`）
- ASG desired=0, VPCZoneIdentifier=4 subnet（恢复）
- EKS NG 仍 cached DEGRADED，会在 2-5 min 内自愈
- K8s yanxi-validation 命名空间内已清空本 run 的 deployment/svc/cm/job
- 成本估计：2 × p6-b300 × ~1h 20min Spot ≈ **$40-50**（B300 spot $15-30/h）

## 结论

R6a ABORT，但拿到 3 条有价值信息：
1. **B300 硬件订正**：HBM 275 GB/卡（文档错写 180），compute_cap (10, 3) 即 sm_103a
2. **Mooncake EFA v5 在 B300 EFA v3 上初始化 PASS**（max_mr=412 GB，首次实测）
3. **v5 镜像（torch 2.9.1 + Triton）在 B300 上不能跑 sglang e2e** — Stage 6.5 必须完成才能 retry

见 `RESULT.md` + `ABORT.md`。









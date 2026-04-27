# R6a B300 — ABORT (2026-04-25)

**Status**: ABORTED — sglang 0.5.10 + Triton PTX codegen 不兼容 B300 (sm_103a)
**Run stamp**: 20260425T144609Z
**Region / AZ**: us-west-2 / usw2-az2（硬同 AZ）
**Node count**: 2 × p6-b300.48xlarge Spot（same-AZ）
**Total node-hour**: ~40 min 每节点 × 2 = ~1.3 node-hour Spot

## 一句话

**Mooncake EFA v5 on B300 = 完整初始化 PASS（首次实测）；sglang 0.5.10 的 Triton 动态 codegen 不认 `sm_103a`，decode health probe 一触发 kernel 就 `ptxas exit 255` 自杀，ABORT**。

## 今日从 B300 拿到的**可用**数据

### 1. Mooncake v5（Henan 5 PRs + PR #1944 SRD）在 B300 EFA v3 上首次初始化 PASS

Prefill + decode 两 pod 的 libfabric + EFA 端口全部枚举正常：

```
I0425 15:47:15 EFA device (libfabric): rdmap177s0, domain: rdmap177s0-rdm,
               provider: efa (shared endpoint, max_wr=256)
I0425 15:47:15 EfaTransport: Initialized EFA device rdmap177s0
I0425 15:47:15 EfaTransport: Clamped max_mr_size to device limit: 412316860416
I0425 15:47:15 EfaTransport: Started 16 CQ polling worker threads
I0425 15:47:15 Auto-split params: page_size=4096, max_pte_entries=23068672,
               pte_limit=94489280512, max_mr_size=412316860416, chunk_limit=94489280512
W0425 15:54:09 Chunk 0/1 registered on 16 NICs, addr=...,
               length=524288, duration=4ms
```

**关键数字对比 p5en（Stage 4 baseline）**：

| 项 | p5en (EFA v2?) | **B300 (EFA v3)** | 说明 |
|---|---|---|---|
| `max_mr_size` | ~195 GB | **412 GB** (×2.11) | 单个 MR 注册大小上限，B300 EFA controller 新代 |
| `pte_limit` | ~47 GB | **94 GB** (×2.0) | PTE 表条目上限，对应 B300 GPU HBM 275 GB 的线性地址空间 |
| `max_pte_entries` | ~11.5M | **23M** (×2.0) | |
| CQ polling worker threads | 16 | **16** | 对上两代的 16 NIC / node |
| MR register duration | 6-8 ms | **4-12 ms** | 中位数略快 |

**这是 stage 6.5 "CUDA 13 + B300 + Mooncake v5" 的第一个确认数据点**。

### 2. B300 硬件规格订正

| 项 | 文档旧值 | **实测新值** |
|---|---|---|
| GPU | NVIDIA B300 SXM6 AC | 同 |
| compute capability | (10, 0) | **(10, 3)** / `sm_103a` |
| HBM / GPU | 180 GB | **275 GB** (+53%) |
| HBM / node | 1.44 TB | **2.2 TB** |
| EFA NICs / node | 16 | 16 |
| EFA bandwidth / node | 6.4 Tbps | 6.4 Tbps |

sglang weight load 也证实 `avail mem=265.27 GB/GPU` (275 - system overhead)。

### 3. v5 镜像 software stack 实际内容（preflight）

```
torch       2.9.1+cu128
cuda        12.8
arch_list   sm_70, sm_75, sm_80, sm_86, sm_90, sm_100, sm_120
Mooncake    0.3.10.post2 @ commit 634b709 (includes #1944 SRD)
sglang      0.5.10
```

**注意 arch_list 没有 sm_103**（只到 sm_100），这是后来 fail 的根因之一。

## 根因：Triton PTX codegen `sm_103a` 不可用

### 第一次 fail（15:48 UTC）

Sglang CUDA graph capture 阶段，Triton 根据 `torch.cuda.get_device_capability() == (10, 3)` 生成 `sm_103a` PTX 文件，然后调 `ptxas`：

```
/usr/local/lib/python3.10/dist-packages/triton/backends/nvidia/bin/ptxas
  -lineinfo -v --gpu-name=sm_103a /tmp/tmpXXX.ptx -o /tmp/tmpXXX.ptx.o
  → returned non-zero exit status 255
  → PTXASError: Internal Triton PTX codegen error
  → NoTritonConfigsError: No valid triton configs
  → Exception: Capture cuda graph failed
```

Sglang log 明确给了 4 个 workaround 建议，其中 (4) 是 `--disable-cuda-graph`。

### 第二次 fail（走路径 A，加 `--disable-cuda-graph`，15:53 UTC）

两 pod 都 **`The server is fired up and ready to roll!`**，lb health=OK，decode `/get_model_info` 正常返回 GLM-4.6 model info。但是：

- **Prefill HTTP server 没起**（connection refused on port 30000），虽然 log 里写了 "ready"
- sglang-router bench `No prefill workers available`
- Prefill pod 进入 `CrashLoopBackOff`，previous container 最后 stack：

```python
File "sglang/srt/managers/tokenizer_manager.py", line 2568, in running_phase_sigquit_handler
    kill_process_tree(os.getpid())
  SystemExit: 0
File "sglang/srt/entrypoints/http_server.py", line 529, in health_generate
    await asyncio.sleep(1)
  asyncio.exceptions.CancelledError
[2026-04-25 16:00:06] INFO:  10.0.12.234:36638 - "GET /health HTTP/1.1" 500 Internal Server Error
```

**诊断**：sglang 的 `running_phase_sigquit_handler` 触发了 process tree kill。
- lb 的 `/health` → sglang 内部跑 `health_generate` → 这个 endpoint 会实际调 decode 路径
- decode 路径里有 **Triton-JIT 的 fused MoE / attention kernel**（GLM-4.6 compressed-tensors FP8）
- **Triton 仍走 ptxas + `--gpu-name=sm_103a`** → 又是 PTXASError
- 触发 sglang 的 fatal handler → SIGQUIT 整个 process tree

**结论**：`--disable-cuda-graph` 只 disable CUDA graph capture，**没有 disable Triton piecewise kernel**。sglang 0.5.10 的 GLM-MoE FP8 decode 重度依赖 Triton-JIT 的 kernel，而 v5 镜像的 Triton 在 B300 sm_103a 上就是坏的。

## 为什么不是 simple "降 sm_100" 能解决

- torch 2.9.1 识别 device capability 的逻辑是硬编码的 `(10, 3)` for B300
- Triton 用 `torch.cuda.get_device_capability()` 作 target arch 参数
- 即使 `CUDA_COMPUTE_CAP_OVERRIDE=10.0` 之类环境变量也不一定生效
- 根本问题：**v5 镜像的 `triton/nvidia/bin/ptxas` 来自 torch 2.9 wheel**，版本不支持 sm_103a compilation target
- **正解** = 升级到 CUDA 13.0.2 + 对应 Triton wheel + 重 build 镜像链 = stage 6.5

## 今天在 B300 上**没**拿到的

- ❌ End-to-end bench 数据（tok/s, TTFT, TPOT）
- ❌ Mooncake KV 跨节点 RTT 数据（没进入 bench 阶段就挂了）
- ❌ B300 vs p5 干净单变量对比
- ❌ PR #1944 SRD 在 B300 上的 handshake 性能数

## 运维实况

### 时间线（最终版）

| Time (UTC) | Event |
|---|---|
| 14:46:09 | STEPS.md 初始化 |
| 14:55:30 | ASG subnets 收窄到 `subnet-0343696171ce4cdc9` (usw2-az2) |
| 14:56:17 | 第 1 台 B300 Spot fulfilled |
| 15:06:47 | Preflight PASS（LT auto-LVM /data 28 TB + v5 image CUDA import 通） |
| 15:09:29 | 第 2 台 B300 Spot fulfilled（绕 EKS DEGRADED 直接 ASG scale）|
| 15:12:00 | Apply prefetch job |
| 15:20:10 | Prefetch Complete 2/2（337 GB × 2 nodes, 7m52s 总时长）|
| 15:37:00 | Apply R6a manifest |
| 15:39:49 | Mooncake EFA PASS（shared endpoint + 16 CQ polling + 412 GB MR）|
| 15:40:42 | FP8 MoE kernel 加载通（CompressedTensorsW8A8Fp8MoE） |
| 15:48:12 | **FAIL #1**: CUDA graph capture ptxas sm_103a exit 255 |
| 15:49:30 | Edit manifest 加 --disable-cuda-graph + flashinfer |
| 15:53:46 | Decode pod "ready to roll" |
| 15:54:10 | Prefill pod "ready to roll" |
| 15:57:00 | Bench 启动 → `No prefill workers available` |
| 16:00:06 | **FAIL #2**: prefill SIGQUIT on health_generate（Triton 仍在 sm_103a 上失败）|
| 16:05:00 | 用户拍板路径 C，kubectl delete resources |
| 16:06:00 | ASG desired=0，两 node shutting-down |
| 16:06:30 | ASG vpc 恢复 4 subnet（让 EKS NG 自愈 DEGRADED）|

### 节点回收

```
i-0b9007c021273989c  p6-b300  usw2-az2  shutting-down
i-0250a5eebff6bbd50  p6-b300  usw2-az2  shutting-down
```

两 B300 spot 已 shutting-down。ASG subnets 恢复 4 AZ。EKS NG status 仍 cached DEGRADED，controller 会在几分钟内 reconcile。

### 同 AZ 规则遵守

✅ 两节点都 usw2-az2
✅ Pod nodeAffinity `topology.kubernetes.io/zone=us-west-2b` 强制
✅ 没有任何跨 AZ 流量
（此规则已在 2026-04-25 记入 `feedback_same_az_all_tests.md`）

## 下一步（不 commit，给后续 session 参考）

### 想在 B300 上拿 sglang e2e 数据，需要先做 stage 6.5：

1. **升级 base-cuda-efa** 到 v3：CUDA 13.0.2 + cuDNN + EFA installer + Blackwell driver 580+
2. **Rebuild mooncake-nixl:v5** 基于新 base
3. **Rebuild sglang-mooncake:v5** 基于新 mooncake，拉 sglang 0.5.10 + torch 2.10（含 Blackwell sm_103 支持）或 2.9 的 B300 patch
4. 做 preflight：`torch.cuda.get_arch_list()` 必须有 `sm_103`，Triton `ptxas --gpu-name=sm_103a` 空文件 compile 成功（不报 255）
5. 再跑 R6a

### 今天从 B300 Spot 还能抢到的（替代路径，未走）：

- Lane K microbench：`transfer_engine_bench` 同 AZ p2p，拿 **Mooncake v5 B300 EFA v3** 的 BW/latency 数字。**完全不走 Triton/sglang**，v5 镜像已经验证 Mooncake 能初始化，一定能跑
- 这个数据对 UCCL-EP PR 的 AWS bench body 也直接有用

### 开后门的 hack（未试）：

- `CUDA_COMPUTE_CAP_OVERRIDE=10.0` 或 `TRITON_OVERRIDE_CTAS=100` 之类 env var，强行告诉 Triton 用 sm_100
- 风险：数值正确性未知，kernel 性能打折，可能别处还挂

## 记忆沉淀候选（session 内 pending）

应该写一条新 feedback 永久记忆：

**"v5 镜像（torch 2.9.1+cu128, arch_list 最高 sm_100）不能在 B300 (sm_103a) 上跑 sglang decode — Triton PTX codegen fails on ptxas sm_103a。要跑 B300 必须先完成 stage 6.5 CUDA 13 全栈升级。"**

（如果用户允许，我会把这条写成 `feedback_v5_image_b300_incompatible.md`）

## Artifacts

- Manifests:
  - `manifests/stage5-p5en/r6-b300-preflight.yaml`（preflight pod，single-GPU，通过）
  - `manifests/stage5-p5en/_prefetch-hf-glm46-b300.yaml`（2 node prefetch，通过）
  - `manifests/stage5-p5en/r6a-glm46-1p1d-v5-b300-az2.yaml`（R6a 主 manifest，含 `--disable-cuda-graph` edit，最终 ABORT）
- Timeline: `STEPS.md`
- Status: `RESULT.md`（即将更新为 ABORT summary）

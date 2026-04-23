# Stage 4 — NIXL vs Mooncake 端到端对照（同环境同 workload）

## 测试条件

| 维度 | 值 |
|---|---|
| 硬件 | 2 × p5.48xlarge (8 × H100 + 32 × EFA NIC), cross-AZ |
| 模型 | Mistral-7B-Instruct-v0.2 bf16, 13.5 GB |
| 部署 | sglang 0.4.10.post2 1P:1D, TP=8 per role, 跨节点 |
| EBS | 2TB × 4 volumes (root + data × 2 nodes), gp3 16k IOPS / 1000 MB/s throughput |
| Workload | 128 prompts × 1024 input × 256 output, random, `sglang.bench_serving --pd-separated` |
| Sweep rates | 2, 4, 8, 16, inf |

唯一变量：`disaggregation-transfer-backend` = `nixl` 还是 `mooncake`（仅切换此 env var + 重启 prefill/decode deployment）。

## NIXL (LIBFABRIC backend) — 5/5 全通

| rate | req/s | TTFT mean (ms) | TTFT p99 (ms) | ITL mean (ms) | ITL p99 (ms) | E2E mean (ms) | out tok/s | total tok/s |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 2   | 2.47  | **76**   | 576   | 2.87 | 4.75  | 453    | 326  | 1590  |
| 4   | 4.89  | **48**   | 77    | 2.67 | 5.11  | 398    | 646  | 3150  |
| 8   | 9.58  | **50**   | 76    | 2.81 | 5.69  | 418    | 1266 | 6177  |
| 16  | 18.26 | **62**   | 218   | 3.09 | 7.28  | 468    | 2413 | 11777 |
| inf | 47.42 | **1182** | 1950  | 4.78 | 16.90 | 1809   | 6266 | 30581 |

## Mooncake — rate=2 勉强完成，rate=4 全崩

| rate | req/s | TTFT mean (ms) | ITL mean (ms) | E2E mean (ms) | total tok/s | 状态 |
|---:|---:|---:|---:|---:|---:|---|
| 2   | **0.20** (期望 2.0)  | 839    | 2.80 | **22269**   | 127  | ✅ 跑完，但最后 9 个 prompt 每个 88s，排队爆炸 |
| 4   | 0.14                 | 0      | 0    | **443735**  | 90   | ❌ 绝大多数请求 300s KV transfer timeout |
| 8/16/inf | —               | —      | —    | —           | —    | ⏩ 主动终止（rate=4 已证实失效） |

rate=4 的数字 TTFT=0, ITL=0 表示 **没有请求在 timeout 前产生 first token**。E2E=443s 是 sglang 内置 300s KV poll timeout + 重试/报错退出的总时长。

## 直接对比（rate=2，唯一 Mooncake 有完整数据的点）

| 指标 | NIXL | Mooncake | NIXL 优势 |
|---|---:|---:|---:|
| TTFT mean | 76 ms | 839 ms | **11.0×** |
| TTFT p99 | 576 ms | 3076 ms | 5.3× |
| ITL mean | 2.87 ms | 2.80 ms | 持平（decode 阶段同一 SGL scheduler，正常） |
| ITL p99 | 4.75 ms | 5.23 ms | 1.1× |
| E2E mean | 453 ms | 22269 ms | **49.2×** |
| Actual req/s | 2.47 | 0.20 | **12.4×** |
| Total tok/s | 1590 | 127 | **12.5×** |

## 解读

### 1. 协议本身：NIXL (LIBFABRIC) 快 **约 10-12×**

- 首 token 延迟（TTFT）11×、总吞吐 12×、实际处理率 12× — 这三个基本自洽，指向 KV 传递这一层的差距
- **ITL 持平**说明 decode 阶段（一旦 KV 就绪）两家性能一样，瓶颈全在 KV 跨节点传输

### 2. Mooncake 的本质问题：EFA 路径没走 GPUDirect

- Mooncake v0.3.10.post1 EFA transport 的 `fi_mr_reg` 调用**缺少 `FI_HMEM` flag**
- 结果：每次 KV transfer 都要 `GPU → pinned CPU buf → EFA → pinned CPU buf → GPU`（两次 PCIe D2H/H2D bounce）
- 单次延迟 ≫ NIXL LIBFABRIC plugin 的 GPU direct RDMA
- 在 rate=2 时已经饱和到每个请求 ~5s KV wait，队列持续堆积导致 last 9 prompts 每个 88s
- rate=4 直接溢出 sglang 300s `KVPoll.WaitingForInput` timeout

### 3. 稳定性：NIXL 5 rate 全通，Mooncake ≥ rate=4 就崩

- 这不是 Mooncake 代码有 bug，是 EFA 上协议实现不完整
- **同一镜像、同一 sglang、同一模型、同一 EBS**，只切 backend → 差别完全来自 KV transport 层

### 4. 为什么第一次说"46×"？

- 上轮首次跑 Mooncake Mistral-7B 时没扩 EBS，磁盘压力叠加使得 rate=2 直接崩溃没出稳态数字（崩溃前单点 3533 ms）
- 现在 2TB EBS 后 rate=2 能跑完 128 prompts，拿到稳态 **839 ms TTFT** —— 这才是公允值
- **真实 NIXL vs Mooncake 差距 ≈ 11×**，不是 46×

## 归档

- `disagg-nixl-summary.tsv` / `disagg-mooncake-summary.tsv`
- `NIXL_KV_BACKEND.md`（NIXL 部分完整通路搭建 + 5 gap workaround）
- raw per-rate logs: bench pod `/results/disagg-rate-*.{json,log}` (pod terminated，最终以 TSV 为准)
- prefill/decode 本身在 Mooncake rate=4 期间不崩，只是 decode 侧打印大量 `KVTransferError: Request … timed out after 300.0s in KVPoll.WaitingForInput`

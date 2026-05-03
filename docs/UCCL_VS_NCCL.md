# UCCL-EP vs NCCL：定位对比

**日期**：2026-04-25
**读者假设**：已看过 `docs/MOONCAKE_OVERVIEW.md` + `docs/NIXL_VS_MOONCAKE.md`
**来源**：UCCL README + `uccl/ep/` 子项目 + OSDI'26 论文 + Stage 5 Lane E 设计

---

## 0. 一句话区分

- **NCCL**（NVIDIA Collective Communications Library）= **最成熟的 GPU 集合通信库**，生产事实标准；支持 `all_reduce` / `all_gather` / `broadcast` / `all_to_all` 等密集型 collective；做 MoE 只能用"全量 all_to_all"（不稀疏）
- **UCCL-EP** = UC Berkeley（Sky Lab）+ UCCL team 开发的**专为 MoE dispatch/combine 设计的稀疏 all_to_all 库**，DeepEP API 兼容，但**可移植**（支持 NVIDIA + AMD + EFA + Broadcom，DeepEP 只支持 NVIDIA+IB）

**关系**：UCCL 是个**家族**（UCCL-collective / UCCL-P2P / UCCL-EP 三子项目），整体想做"NCCL 的替代品"。UCCL-EP 是其中专攻 MoE 推理/训练的那一块，和 NCCL 的 MoE 场景正面竞争。

---

## 1. 出身与目标

| 维度 | NCCL | UCCL-EP |
|---|---|---|
| **作者** | NVIDIA | UC Berkeley Sky Lab + UCCL 开源团队（PI: Ion Stoica / Costin Raiciu / 周扬等）|
| **首版** | 2015 | 2025；OSDI'26 paper（UCCL-Tran + UCCL-EP 两篇）|
| **原始动机** | 多 GPU / 多机训练的高性能 collective | 解 DeepEP 的两个痛点：① 只跑 NVIDIA+IB，不跨厂；② IBGDA 绑死 Mellanox |
| **当前阶段** | 超稳定，vLLM/SGLang/PyTorch 全部默认依赖 | 2026 初才达 OSDI 级可用性，生产部署刚开始（AMD TheRock 生态收了）|
| **开源许可** | BSD-3 | Apache-2.0 |
| **NCCL 替代 / 扩展** | —— | UCCL-collective = NCCL 替代品（drop-in NCCL API）；UCCL-EP = DeepEP 替代品（不同 API） |

---

## 2. UCCL 家族的三层（别混淆）

```
UCCL 整体
├── UCCL-collective  (drop-in 替代 NCCL/RCCL)
│     - 同 NCCL API，app 零改动
│     - packet spraying + 多路径 + 软件 congestion control
│     - 性能：6×HGX 8×400G RoCE 上 allreduce 2.5× NCCL
│     - 主要用于训练场景（梯度 allreduce 等）
│
├── UCCL-P2P         (点对点搬运，NIXL-style + NCCL-style 双 API)
│     - 目标：800Gbps NIC，多线程 transfer engine
│     - 和 Mooncake TE / NIXL 竞争 KV cache transfer 场景
│     - 和 NCCL 的关系：可替代 NCCL 用于 KV 搬运
│
└── UCCL-EP          ← 我们 Stage 5 Lane E 的主角
      - DeepEP 兼容 API（buffer.low_latency_dispatch/combine）
      - GPU-initiated MoE all-to-all（类 IBGDA，但 NIC-agnostic）
      - 跨 GPU 厂（Nvidia/AMD）+ 跨 NIC 厂（Nvidia/Broadcom/AWS EFA）
      - 和 NCCL 的关系：**根本不做同一件事**（NCCL 的 alltoall 是密集全量；UCCL-EP 是稀疏 top-k）
```

**注意**：Stage 5 memory 里说的 "UCCL-EP vs NCCL-EP" 是简化说法。真正对比的是：
- **UCCL-EP**（稀疏 top-k MoE alltoall）
- **NCCL 的 all_to_all primitive**（密集全量，被 SGLang `--moe-a2a-backend=none` 变相用到）

---

## 3. MoE alltoall 的本质问题（为什么要有 UCCL-EP / DeepEP）

### 3.1 MoE 的通信模式特殊

每层 MoE：
- Router 给每 token 选 top-8 expert（共 256 experts）
- Dispatch：token 只送给它对应的 8 个 expert 所在 GPU
- Combine：expert 输出只发回原 token 所在 GPU

**特殊性**：每 token 只接触 `8/256 = 3%` 的 expert，**96% 的通信量是浪费的**（如果用全量 alltoall）。

### 3.2 NCCL 怎么处理

NCCL 只有 `ncclAllToAll` （**密集**）：
- 每个 rank 给其他所有 rank 各发一份数据
- 通信量 = `batch × hidden × num_experts`（全量）
- **正确但浪费**：256 expert 中 96% 的传输可以省掉

在 SGLang 里当 `--moe-a2a-backend=none` 时就走这条路；在 NCCL 的 EP 场景叫"fake MoE alltoall"。

### 3.3 DeepEP / UCCL-EP 怎么处理

**稀疏 dispatch/combine**：
- 按 `topk_idx` 索引只发 token 给选中的 expert
- 通信量 = `batch × hidden × top_k`（`top_k/num_experts` 倍节省）
- **GPU-initiated**：kernel 直接触发 NIC 操作（不经 CPU），减延迟
- DeepEP 原始实现用 **IBGDA**（InfiniBand GPU Direct Async），**锁死 Mellanox CX7/ConnectX 系列**

### 3.4 UCCL-EP 如何"去 IBGDA 锁"

DeepEP 的 `ibgda_post_send` 是直接在 GPU SM 里走 InfiniBand verbs doorbell —— 这个硬件特性**只有 Mellanox 有**。

UCCL-EP 的方案：
- 引入一个 **CPU proxy 线程**（"SMEMO" / "mlx5gda" 替代层）
- GPU kernel 写 shared memory FIFO
- CPU proxy 轮询 FIFO，调 `ibv_post_send` / `fi_write`（EFA 场景）
- 付出代价：多一跳 CPU 中介（~5-10 µs per op）
- 收益：NIC-agnostic，**能跑在 AWS EFA、Broadcom Thor-2、AMD Pollara 上**

这也是为什么 UCCL-EP 在 SGLang decode 延迟测试里 combine both 占 326.7 µs（post-PR #745 p5en 2-node 16-GPU benchmark）——"GPU 写 FIFO → CPU proxy poll → NIC DMA" 这段是不可避免的软件路径。[^baseline]

[^baseline]: 以前本文档称 "600 µs"，是 stage2 p5 BF16 test_internode 非-LL 数字。2026-04-26 订正为 p5en LL post-PR #745 实际 326.7 µs；基线来源见 `ALLTOALL_DEEP_DIVE.md`（已移至 sibling repo `../../uccl-ep-optimization/docs/`）。

---

## 4. 功能对比

| 能力 | NCCL | UCCL-collective | UCCL-P2P | UCCL-EP | DeepEP (参考) |
|---|---|---|---|---|---|
| 密集 collective（allreduce / allgather / broadcast）| ✅ | ✅ drop-in | ❌ | ❌ | ❌ |
| 密集 alltoall | ✅ | ✅ | ❌ | ❌ | ❌ |
| **稀疏 MoE dispatch/combine** | ❌（只能密集模拟）| ❌ | ❌ | **✅** | **✅** |
| P2P KV cache 搬运 | ✅（低级 API 可）| ✅ | ✅ | ❌ | ❌ |
| GPU-initiated（kernel 里发 NIC 操作）| ❌ | ❌ | ❌ | ✅ (via CPU proxy) | ✅ (via IBGDA) |
| NVIDIA GPU | ✅ | ✅ | ✅ | ✅ | ✅ |
| AMD GPU (MI300X 等) | ❌（用 RCCL）| ✅ | ✅ | ✅ | ❌ |
| **AWS EFA** | ✅（经 aws-ofi-nccl）| ✅ | ✅ | **✅ 原生** | **❌ 不支持** |
| Broadcom NIC | ❌ | ✅ | ✅ | ✅ | ❌ |
| Mellanox CX7/IB | ✅ | ✅ | ✅ | ✅ | ✅ |
| AFXDP / ENA (非 RDMA) | ❌ | ✅ | ❌ | ❌ | ❌ |

---

## 5. 架构对比（以 EFA + MoE alltoall 为例）

### NCCL 密集 alltoall on EFA
```
SGLang --moe-a2a-backend=none
  ↓
PyTorch ProcessGroup (NCCL backend)
  ↓
ncclAllToAll (密集，全量 256 expert × batch × hidden)
  ↓
aws-ofi-nccl plugin
  ↓
libfabric efa → EFA NIC
```
**问题**：全量 alltoall 浪费 96% 带宽；每层一次，每 forward 61 层共 61 次。

### UCCL-EP 稀疏 dispatch/combine on EFA
```
SGLang --moe-a2a-backend=deepep (配 UCCL-EP patch)
  ↓
buffer.low_latency_dispatch(topk_idx, topk_weights, ...)
  ↓ (GPU 写 FIFO, CPU proxy 读)
uccl_ep.cc: submit_dispatch
  ↓
CPU proxy thread → libfabric efa fi_write
  ↓
EFA NIC → wire → 对端
  ↓ (CPU proxy poll, GPU kernel wait on atomic)
dispatched_x (稀疏收到自己负责的 token)
```
**节省**：`top_k/num_experts = 8/256 = 3%` 的通信量；但每次加 CPU-proxy 一跳 5-10 µs。

### DeepEP 稀疏 on IB（对照，EFA 上不可用）
```
SGLang --moe-a2a-backend=deepep
  ↓
buffer.low_latency_dispatch
  ↓ (GPU kernel 直接 IBGDA doorbell)
Mellanox CX7 → IB wire → 对端
```
**最快**（无 CPU 中介），但**只能在 Mellanox+IB 上跑**。

---

## 6. 为什么 Stage 5 Lane E 只对比 UCCL-EP vs NCCL-EP

来自 `KNOWLEDGE_BASE_2026-04-25.md §8.2`：

| 选项 | EFA 支持 | 稀疏 MoE dispatch | 客户可用性 |
|---|---|---|---|
| NCCL-EP（密集 alltoall）| ✅ aws-ofi-nccl | ❌ 全量 | ✅ 兜底，性能不理想 |
| **UCCL-EP** | ✅ 原生 libfabric | ✅ top-k 稀疏 | ⚠️ 首发，正确性待验 |
| DeepEP | ❌ 需 IBGDA | ✅ | ❌ 排除 |
| pplx-kernels | ❌ IBGDA 依赖 | ✅ | ❌ 排除 |
| Mooncake-EP | ⚠️ 默认不编 | ✅ | ❌ v5 镜像未编进 |

**结论**：EFA 上 EP 层实际**只有 NCCL-EP（兜底）和 UCCL-EP（新候选）两个选择**。

这也是为什么 Lane E 的态度和 Lane K 不同：
- Lane K (Mooncake vs NIXL)：**不强推 NIXL**，客户已在用 Mooncake
- Lane E (UCCL-EP vs NCCL-EP)：**深度测 UCCL-EP 生产可用性**，因为客户**没有别的选择**

---

## 7. 在 SGLang 里的集成点

### 7.1 SGLang 的 `--moe-a2a-backend` 选项

SGLang 0.5.10 main 的选项：`{none, deepep, mori}`，**不含 uccl**。

- `none` → 走 NCCL ncclAllToAll（密集）
- `deepep` → 走 DeepEP（需 IBGDA，EFA 不行）
- `mori` → 一个更新的 MoE backend

要用 UCCL-EP，需要：
1. 客户 fork 的 SGLang 有 `uccl` 选项（我们还在确认）
2. 或 cherry-pick UCCL 上游 SGLang PR（需找 UCCL 团队）
3. 或用 `LD_PRELOAD` hack 把 `deepep.py` 里的 buffer 替换成 UCCL 的（风险高）
4. 或 Lane E E2E 退化为仅 microbench

### 7.2 我们当前进展

- 已 fork `KevinZhao/uccl`（见 memory `reference_uccl_fork.md`）
- upstream PR #904（`UCCL_EP_CPU_TIMEOUT_SECS` env）OPEN
- 正在推进 **P0 combine signal API**（给 `low_latency_combine` 加 `comp_signal` / `overlap` / `num_sms` 参数，解锁 SGLang SBO overlap）[^api]
- 预期收益：p5en decode mean ITL **-5~-8%**（锚 SGLang PR #9660 H20 实测 -7.9%；详见 sibling repo `../../uccl-ep-optimization/docs/UCCL_EP_OPTIMIZATION_V2.md`，取代了旧版 `EXPECTED_PERFORMANCE_GAINS.md`）

[^api]: 2026-04-26 订正：Hopper 走 `comp_signal`（DeepEP antgroup-opt PR #483 / DeepGemm PR #183），Blackwell 走 `src_signals`（FlashInfer CuteDSL）。之前说 `src_signals` 是错的 API 选型。

---

## 8. 性能数据点（当前）

### 训练场景（allreduce，和 UCCL-collective 对比）
- 6×HGX 8×400G RoCE: UCCL vs NCCL allreduce **2.5×**
- 2×AWS g4dn 1×50G ENA: UCCL vs NCCL **3.7×**

### MoE 场景（UCCL-EP 自报）
- p5en 8×H200 16×200G EFA 上 EP=32 dispatch/combine：UCCL-EP "达到 IBGDA-level 性能"
- 具体 µs 级数字：combine 600µs（dispatch 450µs）—— Stage 5 Lane E 会实测

### 我们 Lane E 要产出的 6 组正确性闸门
Qwen3-235B-A22B-FP8 / Kimi-K2 / DeepSeek-V3.1 × (ISL=128, ISL=8192) = 6 组，每组 1000 请求 token match rate ≥ 99.9%。不通过 → 只出 NCCL-EP 数字。

---

## 9. NCCL 的优势（客观列一下）

| 维度 | NCCL 强项 |
|---|---|
| **成熟度** | 2015 至今，vLLM / PyTorch / TensorRT 全部默认，生产踩过无数坑 |
| **vendor 支持** | NVIDIA 自家，最新 CUDA 特性第一时间进 |
| **错误恢复** | 有成熟的 `NCCL_ASYNC_ERROR_HANDLING`、ranks 死了能重建 comm |
| **多 rail / 多 path** | aws-ofi-nccl plugin 调优多年，EFA 上已跑到很接近线速 |
| **文档/社区** | 巨量 |
| **EFA 密集 allreduce** | 等效于 aws-ofi-nccl 性能，Stage 1-4 验证过吞吐可达线速 |

**UCCL 的风险**：
- 2026 年才出 OSDI 论文，生产部署还很少
- bug 在高速修（`Fix/bdf connect API` `#899`、`#904` 都是上月的）
- SGLang 官方 `--moe-a2a-backend` 还没列 uccl（要等 upstream merge）
- 社区小，踩坑要自己搞

---

## 10. 选择建议

### 用 NCCL 的场景
- **所有密集 collective 场景**（allreduce / broadcast / 密集 alltoall）—— 稳，不用换
- **小模型 / TP≤8 单机推理**（MoE 都在 NVLink 里，alltoall 走 NVLink 很快，密集浪费也不疼）
- **不能承受"正确性首发风险"** 的客户

### 用 UCCL-EP 的场景
- **跨机 MoE 推理**（EP ≥ 16）—— 稀疏 3% 通信比密集 100% 节省巨大
- **AWS EFA 集群**（DeepEP 不能用，UCCL-EP 是唯一稀疏选项）
- **AMD GPU 生态**（NCCL/RCCL 已有，但 AMD + EFA + MoE 只有 UCCL-EP）
- **愿意承担首发风险 + 深度自测**的客户（我们 Lane E 的 6 组闸门就是为这个准备）

### 用 UCCL-collective（对比 NCCL 本身）
- 想在 RoCE/IB 上压榨 1.5-3× 性能，有能力换 `NCCL_NET_PLUGIN` 的团队
- Stage 5 **没用**，客户栈的 collective 层还是 aws-ofi-nccl + NCCL

---

## 11. 一张对比总表

| | **NCCL** | **UCCL-collective** | **UCCL-EP** |
|---|---|---|---|
| **定位** | 事实标准密集 collective | NCCL drop-in 替代（性能导向）| DeepEP 替代（稀疏 MoE）|
| **API** | NCCL 原生 | 同 NCCL（零改动）| DeepEP 兼容 |
| **集合操作** | allreduce / alltoall / ... | 同 NCCL | dispatch / combine 两个 |
| **稀疏性** | 密集 | 密集 | **稀疏 top-k** |
| **GPU 发起** | ❌ | ❌ | ✅（CPU proxy 中介） |
| **EFA 原生** | ✅（via aws-ofi-nccl） | ✅ | ✅ |
| **AMD 支持** | ❌（RCCL 代替） | ✅ | ✅ |
| **成熟度** | ★★★★★ | ★★★☆（OSDI'26） | ★★☆（刚可用）|
| **Stage 5 用途** | Lane E 兜底 | **未用** | Lane E 主 candidate |
| **客户立场** | 默认接受 | 暂不换 | 必须用（EFA 上无替代）|

---

## 12. 顺便澄清：DeepEP / Mooncake-EP / UCCL-EP / pplx 的关系

| 项目 | 作者 | API 风格 | NIC 依赖 | GPU 依赖 |
|---|---|---|---|---|
| **DeepEP** | DeepSeek | 首创，其他都兼容它 | Mellanox IB + IBGDA | NVIDIA only |
| **Mooncake-EP** | Moonshot | DeepEP 兼容 | Mellanox IB + IBGDA | NVIDIA only |
| **pplx-kernels** | Perplexity | DeepEP 兼容 | Mellanox IB + IBGDA | NVIDIA only |
| **UCCL-EP** | UC Berkeley + UCCL team | DeepEP 兼容 | **NIC-agnostic**（via CPU proxy）| **GPU-agnostic** |

DeepEP 是祖师爷，其他三个都兼容它的 API；Mooncake-EP 和 pplx 都是 DeepEP 在各自生态的"更贴近内部栈"的分支；**UCCL-EP 是唯一解 IBGDA 锁、真正跨厂的**，所以在 EFA 上是必选。

**一句话总结**：**NCCL 是密集集合通信的祖师爷，UCCL 家族想做替代品；UCCL-EP 专攻 MoE 稀疏通信这一片，和 NCCL 的稀疏 MoE 支持（没有）错位竞争，真正的竞品是 DeepEP/Mooncake-EP/pplx，而 EFA 场景里只有 UCCL-EP 能用。**

# Stage 5 知识库 — 2026-04-25 对话沉淀

**整理日期**：2026-04-25
**来源**：Stage 5 Day 1 执行期间的技术讨论，涵盖 Mooncake/SGLang 栈、镜像链、MoE/TP/EP/PP 原理、EFA 通信路径、Lane K/E 方案设计
**覆盖范围**：本文档是 Stage 5 相关技术知识的"集中参考"，在未来 session 无会话记忆时可直接回读本文快速 onboard

---

## 目录

1. [Mooncake upstream 和 Henan PR 现状](#1-mooncake-upstream-和-henan-pr-现状)
2. [v2 → v5 镜像基线切换](#2-v2--v5-镜像基线切换)
3. [镜像链结构 (base / mooncake-nixl / sglang-mooncake)](#3-镜像链结构)
4. [PR #1964 reduce reg overhead 代码分析](#4-pr-1964-reduce-reg-overhead-代码分析)
5. [MoE 模型推理结构：TP / EP / PP 的本质区别](#5-moe-模型推理结构)
6. [Prefill / Decode / KV 传输的完整数据流](#6-prefill--decode--kv-传输的完整数据流)
7. [EFA 上的通信路径分类](#7-efa-上的通信路径分类)
8. [Lane K / Lane E 设计与决策判据](#8-lane-k--lane-e-设计与决策判据)
9. [Stage 5 方案能给客户的结论 / 硬缺口](#9-stage-5-方案能给客户的结论--硬缺口)
10. [Stage 5 方案 2026-04-25 修订清单](#10-stage-5-方案-2026-04-25-修订清单)
11. [给客户的配置推荐速查表](#11-给客户的配置推荐速查表)
12. [常见误区订正](#12-常见误区订正)

---

## 1. Mooncake upstream 和 Henan PR 现状

### 1.1 Henan（王鹤男 / whn09）在 kvcache-ai/Mooncake 的 PR 清单

截至 2026-04-25 00:00 UTC，whn09 在 Mooncake 主线上共 5 个 EFA 相关 PR，**全部已 merge**：

| PR | Merge 时间 UTC | 标题 | 关键内容 |
|---|---|---|---|
| #1509 | 2026-02-08 03:41 | [TE] Add AWS EFA transport using libfabric | 首发 EFA transport，`FI_EP_RDM` / `FI_HMEM_CUDA` 支持 GPU 内存注册 |
| #1523 | 2026-02-11 02:50 | [TE] Support TCP fallback in EFA build | `USE_EFA=ON` 构建下 TCP 回退支持 + 文档 |
| #1821 | 2026-04-16 17:30 | [TE] Add fi_read support, LRU eviction, multi-NIC striping | `fi_read`、endpoint LRU、multi-NIC striping、round-robin CQ、batched submission |
| #1912 | 2026-04-20 07:04 | [TE] PTE-aware auto-split large MR registration | PTE-aware auto-split（页大小检测）、full NIC coverage、C API `discoverTopology()` |
| **#1944** | **2026-04-23 08:52** | **[TE] EFA SRD shared-endpoint refactor** | **SRD 共享 `fid_ep` + `fi_addr_t` AV 寻址**（消除 QP 墙）、**修 VRAM `preTouchMemory` segfault**、**修 teardown `fi_av_remove` 段错误**、**移除 `MC_EFA_STRIPING_THRESHOLD`** |

whn09 的 **open PR = 0**（截至 2026-04-25）。

在 sgl-project/sglang 上 whn09 有 1 个 **open PR**：
- #22958 "fix: add padding handling in multi-layer EAGLE draft extend CUDA graph runner"（2026-04-16 提交，未合并）。仅在客户启用 multi-layer EAGLE 时阻塞；Stage 5 默认不开，暂不阻塞。

### 1.2 #1944 对 Stage 5 的关键增量

| 维度 | Pre-#1944（v2 = v0.3.10.post2 tag） | Post-#1944（v5 = @634b7097） | 增益 |
|---|---|---|---|
| Cold submit #0（no warmup）| 99 ms | **26 ms** | **~4×** |
| `warmupSegment()` 耗时 | 17 s（抖动 9/17/17 s）| **1.1 s**（稳定 1.13/1.13/1.14）| **~15×** |
| QP 消耗模型 | per-(local NIC, peer) 对 1 个 `fid_ep`，16 NIC × 48 peer = 768 QP 墙 | 每本地 NIC 1 个共享 `fid_ep`，peer 以 `fi_addr_t` AV 索引 | 消除 QP 墙 |
| Peak throughput（p5en 16 NIC × 200 Gb）| — | **Write 365 GB/s / Read 304 GB/s**（91% 线速）| 无回归 |
| VRAM `preTouchMemory` | ❌ SIGSEGV（CPU store 到 `cudaMalloc` 指针）| ✅ 已修，pre-touch 仅 host mem 路径 | Stage 3 挂账问题已关闭 |
| teardown `fi_av_remove` | ❌ EP close 后调用 → EFA provider 段错误 | ✅ 已修，先关 EP 再释放 AV | — |
| per-request NIC striping | `MC_EFA_STRIPING_THRESHOLD` 存在（p5en 实测 >2 MB 时 20× 负优化）| **已移除**；保留 register-time #1912 PTE-aware 多 NIC 覆盖 | — |
| Python 绑定 `warmup_efa_segment` | 无 | ✅ 新增，vLLM/SGLang 可 opt-in 预连接 | — |

### 1.3 Upstream 主线 post-#1944 的其他变化

#1944 之后（2026-04-23 08:52 UTC 起）upstream main 还有两个 commit：

| SHA | 时间 | PR | 作者 | 是否影响 EFA |
|---|---|---|---|---|
| `0a7e38fd` | 2026-04-23 14:47 | #1961 | stmatengss | [Build] Upgrade yalantinglibs —— 构建层，不影响 |
| `c251eefa` | 2026-04-24 01:42 | #1964 | stmatengss | [TE] reduce reg overhead —— **不触 EFA 代码**，只优化上层 MR 元数据 `vector → map`（O(N) → O(log N)）；p5en KV disagg 场景收益近似为 0 |

**结论**：v5 基线固定在 `634b7097`（#1944 merge 头），**不追 #1964**，后者对 EFA 路径无增益。

### 1.4 Mooncake 官方版本 tag

| Tag | SHA | 日期 | 含义 |
|---|---|---|---|
| v0.3.10.post1 | ~ | 2026-04-01 | USE_EFA=ON landed |
| **v0.3.10.post2** | `e1d6d6f6f4` | 2026-04-22 03:01 | Stage 1-4 v2 镜像基线（含 Henan 4 PR）|
| — (untagged) | **`634b7097`** | 2026-04-23 08:52 | Stage 5 v5 镜像基线（含 Henan 5 PR，追加 #1944）|

---

## 2. v2 → v5 镜像基线切换

### 2.1 基线切换时间线

| 时间 UTC | 事件 |
|---|---|
| 2026-04-22 03:01 | Mooncake v0.3.10.post2 tag（`e1d6d6f6f4`）发布 |
| 2026-04-22 15:44 | `mooncake-nixl:v2` build 完成（MOONCAKE_REF=e1d6d6f6f4）|
| 2026-04-22 16:15 | `sglang-mooncake:v2` build 完成（base v2 + SGLang 0.5.10）|
| 2026-04-23 08:52 | Mooncake #1944 merge（SHA `634b7097`）|
| 2026-04-24 ~15:00 | Ohio ECR 出现预 build 的 v5 镜像（管理员或自动化）|
| 2026-04-24 15:13–16:25 | R0 smoke on v2（Qwen3-Next-80B PASS）|
| 2026-04-25 03:35 | R1a 初次用 v2 起 |
| 2026-04-25 03:52 | BUILD_V3.md 记录切 v5 计划 |
| 2026-04-25 03:56 | 确认 Ohio ECR `:v5` 存在（`/opt/mooncake` HEAD = `634b709`）|
| 2026-04-25 03:56+ | 镜像 mirror Ohio → Oregon，起 R1a v5 |

### 2.2 为什么 Stage 5 主线切 v5

- **#1944 修了 Stage 3 挂账的 VRAM SIGSEGV**（preTouchMemory 对 `cudaMalloc` 指针的 CPU-side store 导致段错误）—— Lane K microbench 扫 VRAM 路径时必需
- **移除了 `MC_EFA_STRIPING_THRESHOLD`** —— p5en sweep 实测 >2 MB 时 20× 负优化，老版本带着这条劣化路径
- **warmupSegment 15× 提速** —— 直接影响 R1a/b/c 冷启动对比数据质量
- **消除 per-peer QP 墙** —— 对 1P:ND 多 peer 场景有实际意义

### 2.3 v2 和 v5 的一致关键标识

| 标识 | v2（Stage 1-4）| v5（Stage 5+）|
|---|---|---|
| Mooncake SHA | `e1d6d6f6f4` | `634b7097` |
| Mooncake 版本表面 | v0.3.10.post2 | v0.3.10.post2（tag 没升，但有 post-tag 提交）|
| Henan PR 数 | 4（#1509/#1523/#1821/#1912）| 5（+ #1944）|
| VRAM preTouch | SIGSEGV | 已修 |
| `MC_EFA_STRIPING_THRESHOLD` | 存在且有 20× 劣化风险 | 已移除 |
| Python `warmup_efa_segment` 绑定 | 无 | 有 |

### 2.4 历史数据保留策略

**Stage 1-4 的数据保持不变**（v2 基线）：
- `results/stage1-p5en/SUMMARY.md`
- `results/stage2-p5en/SUMMARY.md`
- `results/stage3-p5en/SUMMARY.md`
- `results/stage4-p5en/*.md`
- `results/STAGE1-4_P5EN_SUMMARY.md`

**全部加 cross-ref 指向 v5**，不回改数字。Stage 5 R1a/b 会在 v5 上复测 1P:1D / 1P:2D，产出 v2→v5 对照数据。

---

## 3. 镜像链结构

### 3.1 三层继承关系

```
nvidia/cuda:12.6.2-cudnn-devel-ubuntu22.04  (公共基础)
    └─> yanxi/base-cuda-efa:v1    (CUDA 12.6 + EFA installer 1.47 + NCCL 2.23 + aws-ofi-nccl 1.19.0)
            └─> yanxi/mooncake-nixl:v5    (UCX 1.18 + Mooncake @634b7097 + NIXL 1.0.1)
                    └─> yanxi/sglang-mooncake:v5    (SGLang 0.5.10 + launcher)
```

**关键设计原则**：
- 分层构建，上层迭代不重 build 下层（SGLang 迭代快，Mooncake/NIXL 编译慢）
- **Lane K 同层对照**：Mooncake 和 NIXL 在同一镜像 `mooncake-nixl` 里，运行时 flag 切换 backend
- 跨 region（Ohio/Oregon）ECR mirror 有脚本 `scripts/stage5-mirror-ecr.sh`

### 3.2 各层软件组件详单

#### 第 1 层：`base-cuda-efa:v1` (~8-10 GB)

| 组件 | 版本 | 来源 / 安装方式 |
|---|---|---|
| 基础 image | `nvidia/cuda:12.6.2-cudnn-devel-ubuntu22.04` | nvcr.io |
| CUDA | 12.6.2 | 基础 image 自带 |
| cuDNN | cuDNN devel | 基础 image 自带 |
| OS | Ubuntu 22.04 | 基础 image 自带 |
| EFA installer | 1.47.0 | `efa-installer.amazonaws.com`，`--skip-kmod` |
| libfabric | EFA installer 带 | `/opt/amazon/efa` |
| OpenMPI | EFA installer 带 | `/opt/amazon/openmpi` |
| NCCL | v2.23.4-1 | 源码构建，`sm_90`（H200）|
| aws-ofi-nccl | v1.19.0 | 源码构建，绑 libfabric/EFA |

运行时关键 env：
```
FI_PROVIDER=efa
FI_EFA_USE_DEVICE_RDMA=1
FI_EFA_FORK_SAFE=1
NCCL_NET_PLUGIN=/opt/aws-ofi-nccl/lib/libnccl-net.so
```

#### 第 2 层：`mooncake-nixl:v5` (~14 GB)

继承 v1 的全部，加：

| 组件 | 版本 / 关键配置 |
|---|---|
| UCX | v1.18.0 源码构建到 `/opt/ucx`（`--with-cuda --with-verbs --with-rdmacm --enable-mt`） |
| **Mooncake** | **@634b7097** (v0.3.10.post2 post-SRD-refactor，含 Henan 5 PRs) |
| Mooncake cmake | `-DUSE_EFA=ON -DUSE_CUDA=ON -DWITH_TE=ON -DWITH_STORE=OFF -DWITH_STORE_RUST=OFF -DWITH_EP=OFF` |
| NIXL | v1.0.1 |
| NIXL meson | `-Denable_plugins=UCX,LIBFABRIC`（两路径都可用）|

产物（Stage 3 + Lane K microbench 直接用）：
- `/opt/mooncake/build/mooncake-transfer-engine/example/transfer_engine_bench`
- `/opt/mooncake/mooncake-transfer-engine/example/efa_latency_bench.py`
- `/opt/nixl/bin/nixlbench`
- `python3 -c "import mooncake"`
- `python3 -c "import nixl_cu12"`

#### 第 3 层：`sglang-mooncake:v5` (~14 GB，sglang 薄层)

| 组件 | 版本 / 说明 |
|---|---|
| SGLang | 0.5.10（客户 JD JoyAI prod 同版本）|
| sglang-router | 0.3.2（LB 启动时 pip install）|
| torch | 2.9.1（被 `sglang[all]` 拉起，覆盖 base 的 2.4）|
| nvshmem-cu12 | 3.3.20 |
| nccl-cu12 | 2.27.5（pip 层，运行时覆盖 base 系统的 2.23）|
| launcher | `/usr/local/bin/sglang-launcher.sh`（Dockerfile base64 内嵌，含 `rdma→efa` sed patch）|

---

## 4. PR #1964 reduce reg overhead 代码分析

### 4.1 基本事实

- **作者**：stmatengss（不是 Henan，Mooncake maintainer 之一）
- **Merge**：2026-04-24 01:42Z，SHA `c251eefa`
- **Description**：空白（review by merge，代码层 review 走完）
- **变更文件**：4 个，总 +151 / -68
  - `include/transfer_engine_impl.h` (+15/-1)
  - `src/transfer_engine_impl.cpp` (+81/-36)
  - `include/transport/rdma_transport/rdma_context.h` (+9/-1)
  - `src/transport/rdma_transport/rdma_context.cpp` (+46/-30)
- **不触碰**：`src/transport/efa_transport/*` —— EFA transport 代码未改

### 4.2 核心优化

把 `std::vector<MemoryRegion>` 换成 `std::map<uintptr_t, MemoryRegion>`：

```cpp
// Before (O(N) linear scan)
std::vector<MemoryRegion> local_memory_regions_;
for (auto it = ...; it != end; ++it)
    if (it->addr <= addr && addr < (char*)it->addr + it->length)
        return it->mr->rkey;

// After (O(log N) map lookup via upper_bound + std::prev)
using MemoryRegionMap = std::map<uintptr_t, MemoryRegion>;
MemoryRegionMap local_memory_regions_;

MemoryRegionMap::iterator findMemoryRegionContaining(uintptr_t addr) {
    auto upper = local_memory_regions_.upper_bound(addr);
    if (upper == begin()) return end();
    auto candidate = std::prev(upper);
    return overlapWithRegion(addr, 1, candidate->second.addr,
                             candidate->second.length)
               ? candidate : end();
}
```

### 4.3 对 EFA 的影响

**只影响上层 `TransferEngineImpl` 的元数据簿记**：
- `checkOverlap` / `registerLocalMemory` / `unregisterLocalMemory` 的 MR 查询
- RDMA 路径下 `rkey()` / `lkey()`（EFA 路径的 `EfaContext` 未改）

**p5en KV disagg 典型场景**：
- MR 总数 = 16 NIC × ~8 chunks ≈ 128
- O(N) 扫 128 次 vs O(log N) 扫 7 次，每次 submit 省 ~100 ns
- 每秒几千次 submit，节省微秒级
- **不是性能主干改进**

### 4.4 一个语义变化（需警觉）

RDMA 路径的 `unregisterMemoryRegion` 从 "删所有覆盖 addr 的 MR" 变成 "只删 `start_addr==addr` 的一条"：

```cpp
// Before
do {
    for (auto iter = ...; ; ) {
        if (iter->addr <= addr && addr < (char*)iter->addr + iter->mr->length) {
            ibv_dereg_mr(iter->mr);
            memory_region_list_.erase(iter);
            has_removed = true;
            break;
        }
    }
} while (has_removed);  // 删所有覆盖 addr 的

// After
auto iter = findMemoryRegionContaining(addr);
if (iter == end) return 0;
ibv_dereg_mr(iter->second.mr);
memory_region_map_.erase(iter);  // 只删一条
```

SGLang 路径是 "一对一 register/unregister"，不会踩坑；但上层若有"同 addr 重复注册"隐式行为，新版会静默少删。

### 4.5 对 Stage 5 的决策

**v5 基线不追 #1964**（停在 `634b7097`）：
- 对 EFA 路径无增益
- 引入语义变化需额外验证
- 如果未来跑 Mooncake Store 或大规模多 peer 场景（MR > 几百）再追

---

## 5. MoE 模型推理结构

### 5.1 TP / EP / PP 的本质区别

| 维度 | 切的对象 | 通信模式 | 每次 forward 触发次数 |
|---|---|---|---|
| **TP (Tensor Parallelism)** | Attention / dense FFN 的大矩阵（按行或列切）| all-reduce（同步）| 每层 1 次，每 forward 61 次 |
| **EP (Expert Parallelism)** | MoE 的 expert 列表（384 experts 分给多 GPU）| all-to-all（稀疏 dispatch）| 每层 1 次，每 forward 61 次 |
| **PP (Pipeline Parallelism)** | 层与层之间切（Layer 1-30 vs Layer 31-61）| send/recv（activation passing）| 每 forward 1 次（切面上）|
| **DP (Data Parallelism)** | 不同 replica 处理不同 request | 同步梯度（训练时）/ 无（推理）| 推理时每 forward 0 次 |

**关键**：TP 和 EP 作用在**不同权重子集**上：
- TP → Attention 权重（Q/K/V/O 矩阵，每层 4 个）
- EP → MoE Expert 权重（每层 384 个 expert 的 gate/up/down 矩阵）
- 两者**同时生效**在同一个模型的同一批权重上

### 5.2 单层内部的计算流程

```
Layer i 入口 (输入 shape [batch, seq_len, 7168])
  ↓
  LayerNorm
  ↓
  ┌────────── Attention 子层（TP 在此起作用）──────────┐
  │  W_Q, W_K, W_V, W_O 各自按 TP 切                     │
  │  计算 Q·K, softmax, Q·V                              │
  │  → TP all-reduce 合并 TP=N 份结果                    │
  └──────────────────────────────────────────────────────┘
  ↓
  残差 + LayerNorm
  ↓
  ┌────────── MoE 子层（EP 在此起作用）──────────────────┐
  │  Router [7168, 384] → 每 token 选 top-8 expert        │
  │  Dispatch: token 发给负责对应 expert 的 GPU (EP a2a)  │
  │  Expert 本地计算 (gate + up + down)                   │
  │  Combine: 结果 all-to-all 收回 + 加权合并             │
  └──────────────────────────────────────────────────────┘
  ↓
  残差 → Layer i+1 入口
```

**每一层都有 Attention + MoE**，Kimi-K2 共 61 层，所以每 forward 跑 61 次 attention + 61 次 MoE + 61 次 EP a2a。

### 5.3 算力分布（以 Kimi-K2 prefill 2048 token 为例）

| 组件 | FLOPs 占比 | 说明 |
|---|---|---|
| Tokenizer (CPU) | 0% | 不在 GPU |
| Embedding | ~0.001% | 查表，忽略 |
| **61 层 Attention** | **~30%** | 每层 4 个大矩阵乘法 |
| **61 层 MoE FFN** | **~70%** | 每层 3 矩阵 × top-8 expert |
| LM Head | ~0.1% | 最后一层，只算 sampled token |
| Softmax/sample | ~0% | |

**99.9% 算力在 61 层中**；Embedding / tokenizer 可忽略。

### 5.4 权重分布示例（Kimi-K2 TP=8 EP=16 跨 2 机）

```
Node A:                                   Node B:
  GPU A0: ATT 1/8 + Exp 0-23              GPU B0: ATT 1/8 + Exp 192-215
  GPU A1: ATT 2/8 + Exp 24-47             GPU B1: ATT 2/8 + Exp 216-239
  ...                                     ...
  GPU A7: ATT 8/8 + Exp 168-191           GPU B7: ATT 8/8 + Exp 360-383
  
Attention 权重: Node A 和 B 各有一份完整 replica（每机内部 TP=8 切）
Expert 权重: 16 GPU 不重复，每 GPU 24 个 expert
通信:
  TP all-reduce: intra-node NVLink（每机独立，不跨机）
  EP all-to-all: inter-node EFA（跨机，Lane E 测的就是这个）
```

---

## 6. Prefill / Decode / KV 传输的完整数据流

### 6.1 Prefill 阶段（P 节点做的事）

```
输入: T1..T10 (10 tokens 一起 batch)
  ↓
Embedding (查表，每 GPU 一份 embedding 表)
  ↓
Layer 1..61: 每层 Attention (TP) + MoE FFN (EP)
  每层顺带产出 "10 个 token 的 K 和 V 向量" → 存进 KV cache
  ↓
LM Head → logits → sample → T11 (第一个新 token)

产出:
  (1) 10 tokens × 61 layers × (K, V) 的 KV cache
  (2) T11 的 token ID
```

**关键**：
- Prefill 跑完**完整 61 层**（不是"只算 attention"）
- 所有输入 token 一起 batch 过，吃满 GPU 算力
- 每层产出 10 tokens 的 KV，累积 61 层的 KV cache
- 61 次 EP a2a（MoE 层）+ 61 次 TP all-reduce（attention 层）

### 6.2 KV 传输（Mooncake / NIXL over EFA）

```
P 节点产出 10 tokens × 61 layers 的 KV cache + T11
  ↓
Mooncake EfaTransport 通过 EFA 推送给 D 节点
  - 10 token 的 KV（几十 KB-几 MB，取决于模型）
  - T11 的 token ID（几字节）
  ↓
D 节点收到后加入 decode batch
```

**Mooncake 的 EFA 通信次数**：**每请求 1 次**（只传 KV，不传 T11 之后的）。

### 6.3 Decode 阶段（D 节点做的事）

```
D 节点初始状态:
  - KV cache: T1..T10 (从 P 收来的)
  - 待处理 token: T11

生成 T12 (第 1 次 decode):
  Layer 1..61: 每层先算 T11 的 K/V → append 到 cache
              用 T11 做 query 跨 T1..T11 做 attention
              MoE FFN (EP a2a)
  LM Head → T12

生成 T13 (第 2 次 decode):
  Layer 1..61: 算 T12 的 K/V → append
              用 T12 做 query 跨 T1..T12 做 attention
              MoE FFN
  LM Head → T13

... 滚动直到生成结束
```

**关键**：
- 每次 decode 跑**完整 61 层**，但 batch = 1 token
- P 和 D 的模型结构**完全相同**（TP/EP 配置一样，权重分布一样）
- D 每生成 1 个 token，跑 61 次 EP a2a（MoE 层）

### 6.4 Prefill vs Decode 对比

| 维度 | Prefill | Decode |
|---|---|---|
| 输入 token 数 | N（prompt 长度）| 1 |
| Batch 大小 | N（大）| 1（小）|
| 每次 forward 触发的 EP a2a | 61 × 1 次（一次 prefill）| 61 × 1 次（每 token）|
| 生成 M 个输出的 EP 总次数 | N/A（一次搞定）| **M × 61 次** |
| EP 通信特性 | 带宽主导（大 batch 发多 token）| **延迟主导**（小 batch 发 1 token，通信占比高）|
| 瓶颈 | GPU 算力 | **通信延迟**（TPOT 直接受 EP p99 影响）|

**TPOT 来源**：生成 1024 个 token = 1024 × 61 ≈ 62,464 次 EP a2a。每次多 1 μs → TPOT 多 62 ms。

### 6.5 1P:ND 拓扑的实际工作方式

**核心**：**一个请求的 KV 只发给一个 D**，不复制、不分发。

```
LB (sglang-router) 维护每个 D 的负载状态
请求 #1 来 → LB 选 least loaded D（比如 D0）
  → 告诉 P "target=D0, bootstrap_room=xxx"
  → P prefill → Mooncake 推 KV 给 D0
  → D0 加入 decode batch

请求 #2 来 → LB 选 D1
  → P prefill → Mooncake 推 KV 给 D1
  → D1 独立处理

D0 和 D1 之间 **没有 KV 同步**，各自 batch 不同的 request。
```

多个 D 的价值 = **batching 和并发**，不是冗余。

### 6.6 关于 "1P:2D KV 是否负载均衡到两个 D" 的误解

**误区**：以为 KV 会被拆分 / 复制到 2 个 D。

**真相**：
- KV **整份**发给**一个** D
- D0 和 D1 各自有独立的 decode batch（各容纳多个 request）
- LB 决定每个 request 的 KV 去哪个 D（request 级负载均衡，不是 KV 级）

### 6.7 关于 "P 送给 D 的 KV 是 N 还是 N+1 个 token" 的澄清

**正确顺序**：
- P 拿 T1..TN 做 prefill
- P 产出：**T1..TN 的 KV cache（N 个 token 的 KV）+ TN+1 的 token ID**
- **发给 D 的是：N 个 token 的 KV + TN+1 的 token ID**
- D 第一次 decode：接收 KV 后，先算 TN+1 的 KV（追加到 cache），然后输出 TN+2

**关键**：T\_{N+1} 的 KV **不在 P 的产出里**（P 算完最后一层 logits 后才 sample 出 T\_{N+1}，此时不再做 forward），而是 D 做第一次 decode 时顺手算出。

---

## 7. EFA 上的通信路径分类

### 7.1 四条通信路径

| 路径 | 触发频率 | 走哪里 | 谁优化 |
|---|---|---|---|
| **Mooncake / NIXL KV** | 每请求 1 次 | **EFA**（跨机 PD 分离） | Lane K |
| **TP all-reduce**（attention 每层）| 每 forward × 61 次 | NVLink（intra-node）或 **EFA**（跨机 TP）| 硬件决定，尽量避免跨机 |
| **EP all-to-all**（MoE 每层）| 每 forward × 61 次 | NVLink（intra-node EP ≤ 8）或 **EFA**（跨机 EP ≥ 16）| Lane E |
| **DP attention sync**（若开 `--enable-dp-attention`）| 每层 | NVLink / EFA | 单独处理 |

### 7.2 不同配置下 EFA 的压力

| 配置 | 模型能塞下吗 | EFA 路径 | EFA 负载 |
|---|---|---|---|
| TP=8 EP=8 单机 | 小模型 | 仅 Mooncake KV | **低**（每请求 1 次）|
| TP=8 EP=16 跨 2 机 | 大 MoE（Kimi-K2）推荐 | Mooncake KV + EP a2a 跨机 | **高**（每 forward 61 次 EP a2a）|
| TP=16 EP=16 跨 2 机 | 超大模型（GLM-5.1 FP16）不得已 | Mooncake KV + TP all-reduce 跨机 + EP a2a 跨机 | **极高**（每 forward 61 × 2 次，TP 在 critical path）|
| PP=2 跨 2 机 | 理论上能 | Mooncake KV + PP activation 跨机 | **极低**（每 forward 1 次）但 **decode bubble 致命**，不推荐 |

### 7.3 EP ≤ 8 intra-node 时的关键认知

**EP=8 单机不走 EFA**（all-to-all 走 NVLink 900 GB/s）。  
但 D 机器仍有 EFA 流量（Mooncake KV 接收），只是频率低。

**EP=8 是否触发 EFA-EP 不取决于 EP 值，取决于 EP group 的物理分布**：
- EP=8 且 8 GPU 全在一台机 → NVLink
- EP=8 但 4 GPU 在 Node A、4 GPU 在 Node B（极少见配置）→ EFA

SGLang 默认把 EP group 尽量装在单机内，所以 EP ≤ 8 基本都是 intra-node。

### 7.4 TP 跨机 vs EP 跨机

**TP 比 EP 更糟**：

| 特性 | TP all-reduce 跨机 | EP a2a 跨机 |
|---|---|---|
| 每次通信数据量 | 全 token hidden 向量（大）| 稀疏 top-k token（小）|
| 是否在 critical path | **是**（同步操作，阻塞算力）| 可部分 overlap compute |
| 所有参与者 | 全 GPU | top-k 个 GPU（稀疏）|

**业界共识**（DeepSeek-V3 论文明确）：
> "In deployment, we use tensor parallelism (TP) and expert parallelism (EP), not pipeline parallelism, to minimize inference latency."

**推荐优先级**：TP 尽量不跨机；EP 可以跨机（Kimi-K2 生产常见配置）；PP 推理基本不用（bubble 致命）。

### 7.5 PP 为什么在推理场景不用

**PP bubble 的数学**：
```
efficiency = batch_size / (batch_size + pp_stages - 1)

Prefill (batch = 2048):
  efficiency ≈ 2048 / (2048 + 1) ≈ 99.95%   (可用)

Decode (batch = 1):
  efficiency ≈ 1 / (1 + 1) = 50%             (差)
```

Decode batch=1 意味着 PP=2 时 GPU 有 50% 时间在 idle。虽然 EFA 通信次数降 60 倍（每 forward 1 次 vs 每 forward 61 次），但 GPU idle 让 TPOT 净升 30-80%。

**PP 只有在 training（大 batch）或极端大模型（TP/EP 跨很多机的延迟更糟）才值得**。Kimi-K2 不到这个规模。

---

## 8. Lane K / Lane E 设计与决策判据

### 8.1 Lane K 和 Lane E 的关系

| | Lane K (KV transport) | Lane E (MoE EP) |
|---|---|---|
| 对象 | Mooncake vs NIXL | UCCL-EP vs NCCL-EP |
| 测量维度 | 每请求 1 次的 KV 传输 | 每 forward 61 次的 a2a |
| 客户现有栈 | **Mooncake 已在用**（IB 上）| 国内用 DeepEP on IB，EFA 上必须换 |
| 客户接受度 | NIXL 作为可选，Mooncake 是默认 | **EP 层唯一候选是 UCCL-EP**（DeepEP 不支持 EFA）|
| 本轮重点 | 客观数字 + 切换观测清单，**不强推 NIXL** | **深度测 UCCL-EP 生产可用性 + 参数推荐**，因为客户没其他选择 |

### 8.2 EP 层在 EFA 上的唯一真正候选 — UCCL-EP

所有可选项对比（2026-04）：

| 选项 | EFA 支持 | MoE 稀疏 dispatch | 客户可用性 |
|---|---|---|---|
| **NCCL-EP** | ✅（aws-ofi-nccl）| ❌ 全量 alltoall | ✅ 兜底，但性能不理想 |
| **UCCL-EP** (OSDI'26) | ✅ 原生 libfabric | ✅ top-k 稀疏 | ⚠️ 首发，正确性待验 |
| DeepEP | ❌（需 IBGDA + ibv_post_send）| ✅ | ❌ 排除 |
| pplx-kernels | ❌（IBGDA 依赖）| ✅ | ❌ 排除 |
| Mooncake-EP | ⚠️（`-DWITH_EP=OFF` 默认不编）| ✅ | ❌ v5 镜像未编进 |

**结论**：EFA 上 EP 层**实际只有 NCCL-EP（兜底）和 UCCL-EP（新候选）两个选择**。

### 8.3 UCCL-EP 正确性闸门（Stage 5 修订后）

6 组闸门，全部必须通过（token match rate ≥ 99.9%）：

| 组 | 模型 | 场景 | 样本 |
|---|---|---|---|
| G1 | Qwen3-235B-A22B-FP8 | ISL 128 / OSL 128 | 1000 sharegpt |
| G2 | Qwen3-235B-A22B-FP8 | ISL 8192 / OSL 128 | 1000 longbench-v2 |
| G3 | Kimi-K2 | ISL 128 / OSL 128 | 1000 sharegpt |
| G4 | Kimi-K2 | ISL 8192 / OSL 128 | 1000 longbench-v2 |
| G5 | DeepSeek-V3.1 | ISL 128 / OSL 128 | 1000 sharegpt |
| G6 | DeepSeek-V3.1 | ISL 8192 / OSL 128 | 1000 longbench-v2 |

不通过 → Lane E 性能部分回退到 "只出 NCCL-EP 数据 + UCCL 定性结论"。

### 8.4 Lane E microbench 扫描剪枝

两层结构（避免全组合爆炸）：

**层 1 核心 MoE 拓扑（必扫 ~20 组）**：
- EP world size {2, 4, 8, 16, 32} × Hidden {4096, 7168} × Tokens/batch {2048, 8192}
- Top-k = 8 固定（客户模型锁定）

**层 2 EFA 硬件参数（OFAT ~12 组）**：
- NIC 绑定 3 档
- `FI_EFA_TX_SIZE/RX_SIZE` 3 档
- `UCCL_RDMA_QUEUE_DEPTH` 4 档
- `UCCL_MAX_INFLIGHT` 2 档

**固定不扫**：`FI_EFA_USE_DEVICE_RDMA=1`、`FI_EFA_FORK_SAFE=1`、`FI_EFA_USE_HUGE_PAGE=0`、`FI_MR_CACHE_MONITOR=memhooks`。

### 8.5 UCCL-EP SGLang 接入路径（关键前置，Day 2 必闭合）

SGLang 0.5.10 main 的 `--moe-a2a-backend` 取值：`{none, deepep, mori}`，**不含 uccl**。

四档决策：
- (a) 客户 fork 有 `uccl` 支持 → 用客户 patch build `sglang-mooncake:v5-uccl`
- (b) UCCL 上游 sglang PR open → cherry-pick
- (c) `LD_PRELOAD` + env hack → 风险高
- (d) 全走不通 → Lane E E2E 退化为仅 microbench

---

## 9. Stage 5 方案能给客户的结论 / 硬缺口

### 9.1 能直接给的结论（置信度高）

| 客户问 | 方案产出 | 置信度 |
|---|---|---|
| SGLang 0.5.10 在 EFA 上能跑吗 | R0 PASS + R1a/b/c 数据 | ★★★★★ |
| Mooncake EFA 路径怎么配 | §4.3 sweep + §7.2 env 表 | ★★★★☆ |
| 启动有没有坑（sed rdma→efa）| §4.2 + Stage 4 已验证 | ★★★★★ |
| Henan 5 PR 值不值得拉 | v2 vs v5 基线对比 | ★★★★☆ |
| MoE all-to-all 在 EFA 上怎么办 | Lane E（UCCL-EP vs NCCL-EP）| ★★★☆☆（首发风险）|
| PD 比例选几比几 | R1a/b/c decode 曲线 | ★★★★☆ |
| 失败后能不能恢复 | Day 4 故障恢复 4h 专项 | ★★★★☆ |
| `FI_EFA_*` 环境变量怎么设 | §7.4/§7.5 + Lane E sweep | ★★★★☆ |

### 9.2 硬缺口（方案明确不覆盖）

| 缺口 | 原因 | 客户可能的追问 |
|---|---|---|
| **长时间稳定性 SOAK** | 每点 ≥ 3 min 不够 | "24h/72h 跑会不会挂？" |
| **EP world size > 32** | 4 节点硬件限制 | "EP=64/128 呢？" |
| **客户 fork vs upstream 差值** | fork 不可得 | "我们 fork 也这样吗？" |
| **多租户混合流量** | 合成负载 | "混合 ISL/OSL 呢？" |
| **prefill 扩展 2P:ND / 3P:ND** | R1d/e 砍了 | "加 prefill 呢？" |
| **IB vs EFA 同模型差距** | AWS 上没 IB 硬件 | **客户后期可提供 IB 数据**（本轮不阻塞）|

### 9.3 客户目标定位（2026-04-25 晚明确）

客户真正关心：**"在 AWS EFA 硬件上，跑 SGLang 推理的最佳软件栈"**。

- Mooncake 已在用，改造小 → NIXL 不强推（Lane K 给差异数字但不推销）
- **EP 部分没有别的选择**（DeepEP/pplx 都不适用 EFA）→ **Lane E 深度测 UCCL-EP 适配后的生产可用性**
- IB 数据客户后期给，与我们测试无关

**方案定位调整**：从"只给差异，不下结论"收紧到"首选栈 + 触发切换的量化条件 + UCCL-EP 生产可用性报告"。

---

## 10. Stage 5 方案 2026-04-25 修订清单

### 10.1 P0（阻塞结论置信度）

1. §4.4.1 新增 Lane K 正确性闸门：1000 请求 × token match rate ≥ 99.9%
2. §4.3 Mooncake baseline 改背靠背采样（同 pod 交替，不借用 R1b 历史）
3. §10.1 新增 R5 Go/No-Go pre-flight：Day 6 23:00 UTC HBM dry-run + 5 档决策

### 10.2 P1（纳入本轮）

4. §4.3.2 新增 K-E1' 次优点 E2E 验证（验证 microbench 最优 ⇒ E2E 最优）
5. §4.4 故障恢复 30 min → 4h，3 场景 × ≥3 次复测（Day 4 20:00）
6. §5.2 / §5.6 IB 参考线独立文件（`IB_REFERENCE.md`），主表 `E_VS_NCCL.md` 不含 IB 列
7. §5.4 UCCL-EP 正确性闸门加 token match rate

### 10.3 Lane E 深度收紧（2026-04-25 晚）

8. §5.4 升级 6 组闸门（3 模型 × 2 场景 × 1000 请求 × 99.9%）
9. §5.3 扫描分两层剪枝（层 1 ~20 组 + 层 2 OFAT ~12 组）
10. §9 Day 1-2 并行 pre-task：UCCL-EP SGLang 接入路径（Day 2 20:00 UTC 闭合）
11. §12 客户对齐 UCCL-EP 升级为 BLOCKING，四档决策
12. §5.6 新增 `E_DECISION_TREE.md`（模型 + EP 规模 → 推荐配置）
13. `E_VS_NCCL.md` 免责声明（EP 上限 32，不外推）

### 10.4 P2（本轮不做）

- Spot 价采样脚注
- P99.9 CI 标注

### 10.5 承诺不动

- R3（GLM-4.6 长 ctx）/ R4（Qwen3-235B）保留
- 4 节点 p5en 预算
- 7 天窗口

---

## 11. 给客户的配置推荐速查表

### 11.1 按模型规模决策

| 模型 | FP8 显存 | 单机 (8×H200=1128GB) 能塞？ | 推荐配置 | EFA 吃什么 |
|---|---|---|---|---|
| Qwen3-Next-80B | ~85 GB | ✅ 大把余量 | 单机 TP=8 EP=8 | 仅 Mooncake KV |
| Qwen3-235B-A22B-FP8 | 240 GB | ✅ | 单机 TP=8 EP=8 | 仅 Mooncake KV |
| GLM-4.6 | 340 GB | ✅ | 单机 TP=8 EP=8 | 仅 Mooncake KV |
| DeepSeek-V3.1 | 640 GB | ✅ 紧 | 单机 TP=8 EP=8 或跨 2 机 TP=8 EP=16 | 可选 |
| **Kimi-K2** | **959 GB** | ❌ | **跨 2 机 TP=8 EP=16**（首选）| EP a2a + Mooncake KV |
| GLM-5.1 FP16 | ~710 GB | ❌ | 跨 2 机 TP=16 EP=16（硬上）或降到 BF16/FP8 | TP + EP + Mooncake 都吃 |

### 11.2 通用配置建议

```bash
# SGLang 启动必须 flag（v5 镜像已固化）
--fp8-gemm-backend cutlass               # Stage 4 验证：deep_gemm 冷启 30-60 min → cutlass 3 min
--attention-backend flashinfer           # 非 Qwen3-Next 模型
--mem-fraction-static 0.88~0.92          # 按模型调
--chunked-prefill-size 4096              # 旗舰模型
--disaggregation-mode prefill|decode
--disaggregation-transfer-backend mooncake
--disaggregation-ib-device rdmap*s0      # 16 × EFA
--moe-a2a-backend none                   # 单机；跨机 EP 换 nccl 或 uccl

# 必备 env
FI_PROVIDER=efa
FI_EFA_USE_DEVICE_RDMA=1
FI_EFA_FORK_SAFE=1
FI_EFA_USE_HUGE_PAGE=0                   # Stage 4 验证 1 有问题
NCCL_NET_PLUGIN=/opt/aws-ofi-nccl/lib/libnccl-net.so
NCCL_CROSS_NIC=1                         # 多 NIC
NCCL_NVLS_ENABLE=1                       # H200
MC_MS_AUTO_DISC=1
MC_LEGACY_RPC_PORT_BINDING=1

# 启动补丁（launcher 自动做）
sed -i 's/"rdma",$/"efa",/' \
  /usr/local/lib/python3.10/dist-packages/sglang/srt/distributed/device_communicators/mooncake_transfer_engine.py
```

### 11.3 Lane K 决策

默认 Mooncake（@`634b7097`），除非特定场景 NIXL 明显更优：
- KV chunk < 256 KB（短 prefix）→ NIXL 可能占优（裸 BW 在 rendezvous 触发前）
- KV chunk 1-4 MB（主流 Kimi-K2）→ Mooncake 更优（SRD endpoint + PTE-aware）
- 客户已用 Mooncake，切 NIXL 的运维成本不值

### 11.4 Lane E 决策

- EP ≤ 8 单机 → NCCL-EP 或 `--moe-a2a-backend=none`（走 NVLink，无关紧要）
- EP = 16-32 跨 2-4 机：
  - UCCL-EP（前提：正确性闸门过 + Stage 5 sweep 最优参数）→ 性能更好
  - NCCL-EP → 兜底，正确性稳定
- EP > 32 → Stage 5 未测，客户自行实验

---

## 12. 常见误区订正

### 误区 1："PD 分离 = P 算 attention，D 算 FFN"
**错**。P 和 D 都跑**完整 61 层**（含 attention + MoE FFN）。PD 分离的意义不是"拆计算"，而是"让 P 做 prefill batch（大）、D 做 decode batch（小），两者特性不同分开优化"。

### 误区 2："P 送给 D 的 KV 是 N+1 个 token 的"
**错**。送的是 N 个输入 token 的 KV + T\_{N+1} 的 token ID。T\_{N+1} 的 KV 在 D 的第一次 decode 时才算出。

### 误区 3："1P:2D 时 KV 会复制 / 负载均衡到 2 个 D"
**错**。一个请求的 KV 只发给一个 D。LB 做 request 级负载均衡，决定每个 request 的 KV 去哪个 D。2 个 D 的价值是 batching 和并发。

### 误区 4："EP=8 单机就完全不碰 EFA"
**部分对**。MoE EP a2a 不碰 EFA（走 NVLink）；但 Mooncake KV 接收仍走 EFA（每请求 1 次，Lane K 的对象）。

### 误区 5："TP 和 EP 是模型的两部分权重"
**错**。TP 和 EP 是**同一模型的两种切分方式**，作用在不同权重子集（TP 切 attention，EP 切 expert），但对同一份权重同时生效。

### 误区 6："PP 能减少 EFA 影响"
**错**。PP 减 EFA 次数（60 倍），但 decode batch=1 时 PP bubble 让 GPU idle 50%，净 TPOT 反而升 30-80%。推理场景不用 PP。

### 误区 7："EP ≥ 16 一定跨机"
**看 GPU 物理分布**。EP=16 且 16 GPU 全在单机（单机 16 GPU 的机型不存在于 p5en，所以此场景默认跨机）→ NVLink；p5en 最多 8 GPU/机，EP=16 必然跨 2 机。

### 误区 8："FP8/FP4 混合和 TP/EP 是一回事"
**错**。FP8/FP4 是**数据类型**（每个权重占多少 bit），TP/EP 是**切分方式**（权重怎么分到 GPU）。两者正交，可以自由组合。

---

## 附：关键文件和数据位置

| 文件 | 作用 |
|---|---|
| `STAGE5_PLAN.md` | Stage 5 方案主文档，含 Changelog 记录所有修订 |
| `RUNBOOK.md` | 逐步执行日志（session 间权威状态）|
| `CLAUDE.md` | 项目入口，Current stage 状态 |
| `common/Dockerfile.mooncake-nixl` | v5 基线 build 入口（MOONCAKE_REF=634b7097）|
| `results/stage5-p5en/r0-smoke/` | R0 PASS 记录（v2 基线）|
| `results/stage5-p5en/r1a-kimi-k2-1p1d/20260425T033552Z/BUILD_V3.md` | v5 切换记录 |
| `results/stage5-p5en/lane-k/TECH_DELTA.md` | NIXL vs Mooncake 静态架构对比 |
| `results/stage5-p5en/2026-04-24_DAY0_SUMMARY.md` | FSx 基建日 Day 0 汇总 |
| `results/STAGE1-4_P5EN_SUMMARY.md` | Stage 1-4 历史数据（v2 基线，含 cross-ref 到 v5）|

**MEMORY.md**（session 间的持久化）指向的记忆文件：
- `feedback_r0_preflight.md` —— R0/Stage 5 起 run 前镜像核验规则
- `reference_ohio_bastion.md` —— Ohio EKS 访问路径
- `feedback_sps_before_launch.md` —— 每次起 run 前 SPS 扫描
- `feedback_stage5_run_docs.md` —— 每个 run 的 STEPS.md + RESULT.md 规范

---

**文档版本**：v1.0 (2026-04-25)
**作者**：Claude Opus 4.7 · workspace `/home/ec2-user/workspace/efa-validation`
**下次更新触发条件**：
- Mooncake upstream 出现影响 EFA 路径的新 PR（whn09 或其他）
- Stage 5 Lane K/E 数据跑完产出新结论
- 客户提供 IB 生产数据作为对比基线
- SGLang 0.5.11+ 接入 UCCL-EP 正式 support

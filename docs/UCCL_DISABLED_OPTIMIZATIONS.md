# UCCL-EP 已写但未启用的优化路径

扫描日期：2026-04-26
扫描基线：`/home/ec2-user/workspace/uccl` HEAD = `a7eb743e` (2026-04-24 CPU-timeout helper merge 后的 main)
扫描范围：`uccl/ep/src/**`、`uccl/ep/include/**`、`uccl/ep/setup.py`、`uccl/ep/Makefile`
不在扫描范围：`uccl/thirdparty/DeepEP`（第三方，不是 UCCL 控制的路径）、`uccl/p2p/`（另一个产品线）

## 0. TL;DR

- **Env var 总数**：13 个运行期 env var（含 `UCCL_IB_*` 家族 8 个、`UCCL_EP_*` 2 个、`UCCL_ATOMICS_*` 1 个、`USE_INTEL_RDMA_NIC` / `DISABLE_SM90_FEATURES` 等编译期 2 个）
  - "更快但没开" 的模式：**0 个**（所有 UCCL_EP_* 都是 workaround 或平台 gate）
- **#ifdef 总数**：约 430 条（主要是 `__HIP_PLATFORM_AMD__` / `__NVCC__` / `EFA` 平台 gate）
  - 真正意义上 "feature 做好但 default off" 的：**3 个**（PER_EXPERT_BATCHING、USE_SUBSET_BARRIER、MEASURE_PER_OP_LATENCY 系列）
  - 其中 1 个是有实测证据显示 "已经能跑但作者没敢默认开"（PER_EXPERT_BATCHING，#800 有结果但 Makefile 默认 0）
- **Dead / unused 函数**：未发现 EP src 层的明显 dead code
- **Commented-out 优化**：4 处（`SOFTWARE_ORDERING`、`USE_SUBSET_BARRIER`、`MEASURE_PER_OP_LATENCY`、`MEASURE_PER_VERB_LATENCY`），前 3 个是"未完成的优化尝试"，后 2 个是"bench 用 instrumentation，不该默认开"
- **CMake 选项**：EP 不用 CMake，用 `setup.py + Makefile`，所有 feature 开关是 `-D` 宏
- **最高 ROI 默认启用前 3**：
  1. 无 ✗  —— 真正 "加个 -D 就能提速" 的路径，现仓库里**不存在**。这是个诚实回答。
  2. 次高 ROI 的是为 **PER_EXPERT_BATCHING** 建立 decode/low-latency 场景下的 **实测 gate**（见 §7.1），如果 p5en decode 实测有 -5% ITL 就推 PR 把默认值从 0 改为 1
  3. 第三是把 `UCCL_IB_MAX_INFLIGHT_BYTES=SIZE_MAX` 的"no limit"默认在 **EFA 路径**下设成 **8 MB**（现在是无限，线头阻塞风险）。详见 §7.2
- 重要的负面结论：大量直觉上像是 "hidden optimization" 的东西（USE_MSCCLPP_FIFO_BACKEND、USE_RECEIVER_BARRIER、aggressive_atomic、aggressive_ptx）**核查后都 NOT "hidden"**——它们要么在 EFA 路径已经 default on，要么 default off 是 known-regression 或 known-broken 的结果

---

## 1. Env var 扫描结果

所有运行期 env var（排除 `MASTER_ADDR` / `WORLD_SIZE` 等 torchrun 约定变量）：

| Env var | Default | When set | Analysis | Speed-up hidden? |
|---|---|---|---|---|
| `UCCL_IB_GID_INDEX` | -1 (auto-detect) | 指定 RoCE GID | NIC 配置，不是性能开关 | No — platform gate |
| `UCCL_IB_ROUTABLE_FLID_GID_INDEX` | 1 | 用户指定 | 同上 | No |
| `UCCL_IB_ROCE_VERSION_NUM` | 2 | 用户指定 | 同上 | No |
| `UCCL_IB_ADDR_FAMILY` | AF_INET | AF_INET6 | 同上 | No |
| `UCCL_IB_ADDR_RANGE` | 空 | CIDR | 同上 | No |
| `UCCL_IB_HCA` | 空→auto-select | 用户强制 HCA | 同上 | No |
| `UCCL_IB_SL` | 3 (RoCE) / 自动 8 (EFA LL) | 用户覆盖 | EFA 下已走 `use_ll_sl=true` 自动设 SL=8 路径 (`ep/src/rdma.cpp:911`)，不需再人工设 | No — 已是 default on |
| `UCCL_IB_TC` | 104 | 用户覆盖 | RoCE traffic class；EFA 不走这条 | No |
| `UCCL_IB_MAX_INFLIGHT_BYTES` | `SIZE_MAX`（即无限）(`ep/include/common.hpp:72`) | 用户覆盖 | 当前 EFA 无 byte-level 流控；大消息场景可能线头阻塞。**见 §7.2** | **Possibly** — 保守默认可能是防御性配置 |
| `UCCL_IB_MAX_INFLIGHT_LOW_LATENCY` | 32 (`ep/include/common.hpp:66`) | 用户覆盖 | 已经比 normal (8) 大 4 倍，LL 默认已激进 | No |
| `UCCL_IB_MAX_INFLIGHT_NORMAL` | 8 (`ep/include/common.hpp:67`) | 用户覆盖 | Broadcom Thor-2 / Pollara 场景 README 建议设 1 做流控；对 EFA 不需要 | No — NIC-specific |
| `UCCL_EP_ENABLE_AGGRESSIVE_ATOMIC` | 0 (`ep/include/common.hpp:145-151`) | 1 启用 relaxed atomics | **README.md:135** 明确 "AMD only"；PR #680 / #858 都是因为 AMD 失败才关；CUDA 路径上这个 flag 不展开任何优化分支（只在 `dispatch<...,true>` 模板上）——已默认开（模板分化）但 atomic 类型实际在 EFA 路径上不是瓶颈 | No — AMD workaround |
| `UCCL_EP_CPU_TIMEOUT_SECS` | 100 (`ep_configs.cuh:14`) | 用户覆盖 | PR #904 warm-up 已在做；不是性能开关是长训练 safety net | No |
| `UCCL_ATOMICS_USE_HOST_MEMORY` | 0 (取决于平台 probe) | 1 强制 host | EFA 路径上 atomic buffer **已经强制 host allocated** (`uccl_proxy.cpp:67-71`)，这个 env 在 EFA 下不生效 | No — EFA 已是 host |
| `USE_INTEL_RDMA_NIC` | 自动检测 irdma sysfs (`setup.py:241-247`) | 1 编译期强制 | Intel NIC 专用，非优化 | No — platform gate |
| `DISABLE_SM90_FEATURES` | 0（CUDA）/ 1（AMD）(`setup.py:256`) | 1 强制退化 | 仅 Ampere 兼容，不是优化 | No — downgrade |
| `DISABLE_BUILTIN_SHLF_SYNC` | **1 ON（AMD）/ 未应用（CUDA）**(`setup.py:308`) | 0 关闭 | AMD 路径已默认 ON，CUDA 路径根本没这条分支（CUDA 上把 sync 去掉在 Volta+ 上是 UB，不能默认 on） | No — CUDA 不能开 |
| `DISABLE_AGGRESSIVE_PTX_INSTRS` | 0（CUDA ≥ 9.0）/ 1（< 9.0）(`setup.py:325-337`) | 1 关闭激进 PTX | SM90+ 已默认 ON（`ld.global.nc.L1::no_allocate`），见 `ep/include/ep_utils.cuh:439`；反向是退化 | No — 已 default on |
| `PER_EXPERT_BATCHING` | **0 OFF**（Makefile `ep/Makefile:81` + setup.py `ep/setup.py:318`） | 1 编译 per-expert batching 路径 | **PR #745 合入，PR #800 有实测结果文档**。见 §7.1 | **YES** — 这是唯一可能 "hidden" 的 |

**总结**：
- 所有 `UCCL_IB_*` 都是 NIC 配置 / 平台 gate，不是性能开关
- `UCCL_EP_ENABLE_AGGRESSIVE_ATOMIC` 是 AMD workaround，在 NVIDIA EFA 路径上影响极小且已有 PR #680 证据说 AMD 会挂
- `UCCL_EP_CPU_TIMEOUT_SECS` 是长训练 safety net，不是优化
- **唯一真正 "编译期 default off 但可能值得 on" 的是 `PER_EXPERT_BATCHING`**

---

## 2. #ifdef 扫描结果

按功能分类（忽略 HIP/CUDA/x86/arm 平台 gate 和 header guard）：

| Macro | Default | Purpose | Feature ready? | Can we default-on? |
|---|---|---|---|---|
| `EFA` | ON on p5/p5en/p6 (`setup.py:228`) | EFA ibverbs 专用路径 | Yes | N/A — 已 default on |
| `USE_GRACE_HOPPER` | ON on GH200 (`setup.py:237`) | arm64 + GH200 专属路径 | Yes | N/A — platform gate |
| `INTEL_RDMA_NIC` | 自动检测 irdma (`setup.py:241`) | Intel NIC 专用（走 DMA-BUF + host atomic + Ethernet CQ） | Yes | N/A — platform gate |
| `USE_DMABUF` | 只在 `INTEL_RDMA_NIC` 下自动 on (`common.hpp:41`) | DMA-BUF GPU memory registration | Yes on Intel；NVIDIA 上未测 | **NO** — PR #756 "fix dmabuf perf regression"，作者承认有 regression |
| `ATOMICS_USE_HOST_MEMORY` | 只在 `INTEL_RDMA_NIC` 下自动 on | 把 atomic buffer 从 device 改成 pinned host | Yes；EFA 运行时已自动 host 分配 | N/A — EFA 已 host |
| `ETHERNET_RDMA` | 只在 `INTEL_RDMA_NIC` 下自动 on | iWARP/RoCEv2 专属 CQ flags | Yes | N/A — Intel-specific |
| `USE_MSCCLPP_FIFO_BACKEND` | **硬编码 ON** (`common.hpp:34`)，无 ifndef 保护 | mscclpp FIFO 提供 CPU↔GPU 双向 doorbell 替代 ring-buffer | Yes，PR #465 合入 | N/A — 已 default on |
| `USE_SENDER_BARRIER` | OFF（EFA 路径自动切到 RECEIVER_BARRIER）(`common.hpp:23-27`) | 发送端同步 | 已废弃，见 commit `66adf3b5 remove USE_SENDER_BARRIER` | **NO** — 作者移除了这条路径的对外暴露 |
| `USE_RECEIVER_BARRIER` | **EFA 路径自动 ON**（`common.hpp:23-27` 的 `#ifdef EFA` 分支） | 接收端 barrier | Yes | N/A — 已 default on for EFA |
| `USE_SUBSET_BARRIER` | **注释掉**（`common.hpp:35`） | 只等部分 peers 的 barrier（理论上减少同步开销） | 代码存在于 `proxy.cpp:1269` 等多处但没定义宏 | **可能** — 见 §7.3，但作者把它注释掉说明有未解决的正确性风险 |
| `PER_EXPERT_BATCHING` | OFF | Dispatch-LL 的 per-expert 批量发送 | Yes，PR #745 / #800 | **候选** — 见 §7.1 |
| `DISABLE_SM90_FEATURES` | OFF on CUDA ≥ 9.0 | Ampere 兼容（无 FP8/TMA） | Yes | N/A — downgrade flag |
| `DISABLE_AGGRESSIVE_PTX_INSTRS` | OFF on CUDA ≥ 9.0 | 关闭 `.L1::no_allocate` / `.L2::256B` | Yes；SM90+ 已 default on `ld.global.nc.L1::no_allocate.L2::256B` | N/A — 已 default on |
| `DISABLE_BUILTIN_SHLF_SYNC` | AMD ON / CUDA 未应用 | AMD-only combine 加速 | Yes on AMD | N/A — CUDA 不能开 |
| `DISABLE_NVSHMEM` | CUDA OFF (`ep_config.hpp:77`) / 永远走 DeepEP 路径 | 不依赖 NVSHMEM 的 fallback | Yes | N/A — 依赖检测 |
| `ENABLE_FAST_DEBUG` | 注释掉 (`ep_configs.cuh:12`) | 10s 超时（开发用） | — | **NO** — 调试专用，不能 default on |
| `MEASURE_PER_OP_LATENCY` | 注释掉 (`common.hpp:19`) | bench instrumentation | Yes | **NO** — bench 专用，会占 CPU 且干扰稳态 |
| `MEASURE_PER_VERB_LATENCY` | 注释掉 (`common.hpp:20`) | 同上 | Yes | **NO** |
| `SOFTWARE_ORDERING` | 注释掉 (`common.hpp:17`) | 不用 multi-QP 用 software ordering | 只剩一个 `#elif defined(SOFTWARE_ORDERING)` 分支 (`rdma.cpp:1511`)，是 multi-QP 路径的备份 | **NO** — 作者走 multi-QP (PR #485)，这条是 legacy dead path |
| `DEBUG_PRINT` | OFF | 调试 print | — | N/A |
| `MEASURE_KERNEL_TIME` | 仅在 `tests/pcie_bench.cu` | bench | — | N/A |

**总结**：
- 所有 `#ifdef EFA` / `#ifdef USE_GRACE_HOPPER` / `#ifdef INTEL_RDMA_NIC` 都是硬件 platform gate，不是"优化 hidden"
- `USE_MSCCLPP_FIFO_BACKEND` 是**硬编码 ON** (`#define` 在 `common.hpp:34` 顶层)，不是 hidden
- `USE_RECEIVER_BARRIER` 在 EFA 路径已自动 on
- `USE_SENDER_BARRIER` 已被 PR `66adf3b5` 从默认切走，现在只在非 EFA 路径保留
- `USE_SUBSET_BARRIER` 被注释 — 见 §7.3 的风险评估
- `PER_EXPERT_BATCHING` 是 **唯一** "作者写完、测过、合入但 default 0" 的路径

---

## 3. Dead / unused 代码

方法：对 `include/*.hpp/*.cuh` 的每个 public symbol 看是否在 `src/` 被调用。

发现的潜在 dead paths：

- **`rdma.cpp:1511` 的 `#elif defined(SOFTWARE_ORDERING)` 分支**：从来没被编译进去（`SOFTWARE_ORDERING` 宏无处定义），是 PR #485 multi-QP 的 legacy fallback。约 80 行代码，纯字典堆积。**建议：发 housekeeping PR 删掉**，但不是性能优化。
- **`uccl_proxy.cpp:276/327/344` 的 `MEASURE_PER_VERB_LATENCY` 块**：只在 `#define MEASURE_PER_VERB_LATENCY` 时编译。`bench_utils.hpp` 里有 `MEASURE_PER_OP_LATENCY` 的多处同类块。这些是 bench 期测量代码，非 dead code 但非正式路径。
- **`kSenderAckQueueDepth = 2048`**（`common.hpp:81`）：定义但 grep 没找到直接使用。属于 `USE_SENDER_BARRIER` 路径的遗留常量。归类为 "near-dead constant"。
- **`kReorderingBufferSize = 16`**（`common.hpp:85`）：注释说"目前只占 4 bits"，是 imm 字段复用打包的设计决定。TODO 留着说明未来可能加大。非 dead。

**结论**：没有找到值得"挽救"的 dead optimization 函数。主要 dead 是 `SOFTWARE_ORDERING` legacy 分支——清理性价值，不是性能价值。

---

## 4. 注释掉的优化

| 位置 | 内容 | 为什么关 | 能否开 |
|---|---|---|---|
| `common.hpp:17` | `// #define SOFTWARE_ORDERING` | 被 multi-QP 替代 | **不能** — legacy |
| `common.hpp:19-20` | `// #define MEASURE_PER_OP_LATENCY` / `VERB_LATENCY` | bench 专用 | **不能** — 干扰稳态 |
| `common.hpp:35` | `// #define USE_SUBSET_BARRIER` | 正确性风险 | 见 §7.3，**需要额外测试才能考虑** |
| `common.hpp:77-78` | `// #define kObjectSize 10752/14336` | bench 参数变体 | **不能** — bench knob |
| `ep_configs.cuh:12` | `// #define ENABLE_FAST_DEBUG` | 10s 超时仅开发用 | **不能** |
| `rdma.hpp:41` | `// #ifdef EFA` | 原本想 gate 某块，但代码在运行时检查了 | 不是优化 |
| `setup.py:313-314` | `# cxx_flags.append("-DENABLE_FAST_DEBUG")` | 同上 | **不能** |

没有在注释里发现 "already-wired but deliberately off performance optimization"。

---

## 5. CMake 选项（UCCL-EP 无 CMake）

UCCL-EP 用 `setup.py + Makefile`，不是 CMake 项目。所有开关是 `-D`：

**setup.py 定义的宏（按 default 归类）**：

Default ON（CUDA EFA 路径）：
- `-DEFA`, `-DNB_STABLE_ABI=1`, `-DPy_LIMITED_API=0x030C0000`

Default ON（条件）：
- `-DUSE_GRACE_HOPPER`（GH200 only）
- `-DINTEL_RDMA_NIC`（irdma 自动检测）
- `-DDISABLE_SM90_FEATURES`（Ampere / AMD）
- `-DDISABLE_AGGRESSIVE_PTX_INSTRS`（CUDA < 9.0）
- `-DDISABLE_BUILTIN_SHLF_SYNC`（AMD）
- `-DDISABLE_NVSHMEM`（第三方 DeepEP build 时）

Default OFF：
- `-DPER_EXPERT_BATCHING` — 见 §7.1（候选）

**Makefile (`ep/Makefile:81`)**：
```
PER_EXPERT_BATCHING ?= 0
```
Makefile 和 setup.py 都 default 0，保持一致。

**OFF 里没有 production-grade 的"隐藏优化"**。所有 default OFF 的宏都是：
1. Platform-specific workaround（`INTEL_RDMA_NIC` 被自动检测触发）
2. 调试/bench 用（`ENABLE_FAST_DEBUG`、`MEASURE_*`）
3. 兼容性降级（`DISABLE_SM90_FEATURES`）
4. 尚未完全 mainline 的 feature（`PER_EXPERT_BATCHING`）

---

## 6. Git log 里的未启用痕迹

按时间倒序扫了 EP 相关的 80 个 commit，找 "feature merged but disabled by default" 的 pattern：

| SHA (short) | PR | 分析 |
|---|---|---|
| `0d2d2d01` | #745 | "Improve LL performance by per-expert token batching" — merge 了但 `PER_EXPERT_BATCHING=0` 默认关 |
| `add45290` | #800 | "add per-expert batching results" — 说明 **作者有实测数据但仍未默认开** |
| `7462ce28` | — | "[Lite-ep] document GDR discovery, add batched IPC P2P path for PER_EXPERT_BATCHING" — 进一步扩展但仍然 gated |
| `e65c7866` | #865 | "fixing amd per-expert batching" — 有 bug fix，说明实测过 |
| `4f14b7d9` | #766 | "Fix off13 overflow and PER_EXPERT_BATCHING receiver barrier stride" — 另一个 fix |
| `9d64f7f4` | #858 | "disable aggressive atomic in both setup.py and makefile" — **从 default on 改到 default off**，理由见 PR body |
| `bea4b098` | #859 | "Runtime aggressive atomic control and AMD memory ordering fixes" — 进一步固化 default off |
| `b592ac4f` | #680 | "disable aggressive atomic on amd by default, as it fails stress test" — **stress test 失败** 是明确理由 |
| `66adf3b5` | — | "remove USE_SENDER_BARRIER" — 作者确认放弃 sender barrier 路径 |
| `1307cf3b` | — | "add DISABLE_BUILTIN_SHLF_SYNC to speedup combine performance" — AMD only，commit message 说 speedup combine performance，是已激活路径 |
| `92b96373` | — | "Remove experimental flow control" — 之前加过实验性流控，**作者主动删了**，说明实测不 work |
| `ab5c10ed` | #723 | "bug EFA fixed degraded performance" — 修复了 EFA 退化，**非 hidden optimization 而是 bugfix** |

**关键观察**：
- PR #745 / #800 → **PER_EXPERT_BATCHING 已合入并有 result**，但 Makefile 默认仍是 0
- PR #680 / #858 → AGGRESSIVE_ATOMIC 默认关 **有 stress test 失败的实证证据**，不是偶发谨慎
- commit `92b96373` → "Remove experimental flow control" **负面教训**：看起来像 hidden opt 的东西，作者自己实测后删掉

---

## 7. 高 ROI 默认启用设计（仅 §7.1 / §7.2 值得推 PR；§7.3 高风险）

### 7.1 PER_EXPERT_BATCHING — 候选推 PR

**改动位置**：
- `ep/Makefile:81` 改 `PER_EXPERT_BATCHING ?= 1`
- `ep/setup.py:318` 改 `if int(os.getenv("PER_EXPERT_BATCHING", "1")):`
- 或不改默认，而是**加一个 autotune bench gate** PR，让它根据 GPU / #experts 自动决定

**原理回顾**：
- Dispatch-LL 原路径：每个 token 独立发 RDMA write
- PER_EXPERT_BATCHING 路径：先把发往同一 expert 的 token copy 到一个 per-expert batch buffer，批量发一次 RDMA write
- 换一次 GPU-to-GPU mem copy 换一次 RDMA verb，在 verb-count-bound 场景应该有明显收益（EFA 是典型 verb-count-bound 场景）

**作者为什么没 default on（推测）**：
1. **多了一次 GPU mem copy**（在 FP8 路径上是 temp→per-expert 的额外一 copy），在 hidden-size 大的场景可能拖慢
2. Signaling buffer 大小变了：从 `num_experts * sizeof(int)` 变成 `num_ranks * num_ranks * sizeof(int)`（见 `ep_config.hpp:243-250`），EP64 以上会吃额外内存
3. 有至少 2 个 fix PR（#766, #865）说明 correctness 曾有 subtle bugs
4. 最关键：**Makefile 默认 0 说明作者没把它推到 general-purpose**，只给愿意实验的用户使用

**证明安全 / 有收益的验证方式**：
1. `ep/bench/test_low_latency.py` 跑 **p5en 2-node 16-rank** 基线：分别用 `make` 和 `PER_EXPERT_BATCHING=1 make`，对比 dispatch-LL 各档 (`num_tokens` = 64/128/256) 的 P50/P99 latency
2. 复现 PR #800 的结果（`results/stage5-p5en` 下）
3. 在 **Kimi-K2 / GLM-4.6 decode 场景**（hidden 7168, num_topk=8, num_experts=288/384）下测 ITL
4. 如果 +5% 或更好，推 PR 说 "p5en + hidden=7168 + num_experts=288 场景下 default on"；**不是全局开**

**预期收益**：小而明确（+2~+8% ITL 在 low-latency 路径），不是翻倍
**风险评估**：3 中等（之前有 correctness bug，虽然已修）

**—— 要推 PR 必须先跑 §7.1 的对比实验，有数据再推 ——**

### 7.2 UCCL_IB_MAX_INFLIGHT_BYTES 在 EFA 路径默认值

**改动位置**：`ep/include/common.hpp:72-127`

**现状**：
```cpp
#define kMaxInflightBytes SIZE_MAX  // no limit
```
任何用户没设 `UCCL_IB_MAX_INFLIGHT_BYTES` 就走"无限"。

**问题**：EFA SRD 在大包 / 多流场景下，没有 byte-level 流控可能导致：
- NIC send queue 堆积 → 队头阻塞
- CQE 风暴 → CPU 轮询开销上升

**但这也是为什么作者不默认加限**：EFA 协议层自己有 rate control，软件层再叠一层可能 underutilize bandwidth。

**改动建议（保守版）**：
- **不改默认值**，而是**给 EFA 路径加一个"若 num_nics ≥ 4 && hidden_bytes ≥ 7168 则建议 8MB"** 的 warn 日志
- 或在 README.md:130 加上 "p5en+高 hidden 场景建议显式设 `UCCL_IB_MAX_INFLIGHT_BYTES=8388608`"

**预期收益**：未测；如果 EFA 大包线头阻塞存在，会有 tail latency 改善
**验证方式**：`bench/test_low_latency.py` 开 P99 tail 监控，比较 `UCCL_IB_MAX_INFLIGHT_BYTES=SIZE_MAX` vs `=8388608` 的 P99 分布

**—— 这不是推 PR 改默认，而是 README 加使用指南 ——**

### 7.3 USE_SUBSET_BARRIER — ⚠️ 不建议

**位置**：`common.hpp:35` 注释掉；`proxy.cpp:1269` 等处有 `#ifdef USE_SUBSET_BARRIER` 的分支体

**理论收益**：barrier 只等参与的那 subset peers 而非全局，应当降低 dispatch/combine 的同步尾延迟

**为什么作者不开**：注释掉的定义 + `proxy.cpp:1269` 的 `#ifdef` 分支体显示作者写了代码但没定义宏。没有 commit message 说明原因，但结合 `92b96373 Remove experimental flow control` 的模式推断：**这是未完成的 WIP**。

**风险**：barrier 语义错误会导致 kernel hang 或数据 corruption，不是 latency regression 那么简单。

**结论**：**不推荐默认开**，除非先：
1. 写 correctness test（2-node EP16 + 4-node EP32 多轮 alltoall 结果校验）
2. 在 `ep/tests/` 加一个 `test_subset_barrier.py`
3. 跑 ≥ 10000 次 stress 不挂

这个工作量 ≈ 1-2 周，**收益小于 §7.1**，不优先。

---

## 8. 不能默认启用的（作者担心的 edge case 真存在）

| 宏 / env | 为什么不能开 | 证据 |
|---|---|---|
| `UCCL_EP_ENABLE_AGGRESSIVE_ATOMIC=1` | AMD stress test 挂 | PR #680 标题：**"disable aggressive atomic on amd by default, as it fails stress test"** |
| `USE_SENDER_BARRIER` | 已被 replace | commit `66adf3b5 remove USE_SENDER_BARRIER` |
| `SOFTWARE_ORDERING` | multi-QP 是替代路径 | PR #485 multi-QP merge 后这条变成 legacy |
| `ENABLE_FAST_DEBUG` | 10 秒超时在真实训练下 100% FAIL | `ep_configs.cuh:14-26` 注释"~= 10s" |
| `MEASURE_PER_OP_LATENCY` / `MEASURE_PER_VERB_LATENCY` | 额外 `std::chrono` + unordered_map 插入拖慢 hot path | 代码位置 `uccl_proxy.cpp:276-288` |
| `UCCL_ATOMICS_USE_HOST_MEMORY=1` 在 CUDA 上 | CUDA 路径 atomic buffer 用 cudaMalloc 更快（被 probe gate） | `uccl_proxy.cpp:76-83` 的 probe 逻辑 |
| `DISABLE_BUILTIN_SHLF_SYNC` 在 CUDA 上 | Volta+ 要求 sync mask 否则 UB | CUDA Programming Guide + `ep_utils.cuh:17-21` 只在 AMD 下替换 |
| `DISABLE_AGGRESSIVE_PTX_INSTRS=1` | 退化到 `.volatile`，性能下降 | `ep_utils.cuh:439-443` |

这些都是 **"看起来像 hidden optimization" 但实际是 known-broken 或 platform-incompatible** 的 flag。任何建议默认 on 必须先翻上面的证据。

---

## 附录 A：扫描方法论

1. **Env var**：`grep -n "getenv\|std::getenv"` 全仓，对每个 env var 定位：
   - 定义处的 default fallback 值
   - 所有使用处的语义分支
   - 通过 `git log -S "ENV_NAME"` 查 commit message 找 "为什么加这个 env"
2. **#ifdef**：`grep -n "^\s*#if\|#ifdef\|#ifndef\|#elif"` 在 `ep/src`、`ep/include` 中，按宏名分类：
   - HIP/CUDA/x86 等 compiler-intrinsic → 平台 gate，不是 hidden opt
   - `EFA`、`USE_GRACE_HOPPER`、`INTEL_RDMA_NIC` → 硬件 gate
   - 剩下的才是 feature gate，逐个查 `git log --grep="<宏名>"`
3. **Dead code**：对每个 header 里 `extern`/声明的 symbol `grep -c <name> ep/src` 期待 ≥ 2；只 1 就是可能 dead
4. **Commented optim**：`grep "^\s*// *#define"` 找注释掉的宏
5. **Build system**：读 `setup.py`、`Makefile`、搜 `-D` 开头的字符串
6. **Git log**：`git log --oneline --grep="<关键词>"` 找 "disable...default"、"experimental"、"fast path"、"WIP"、"not landed"

## 附录 B：扫描边界

**不包含的范围**：
- `uccl/thirdparty/DeepEP/` — 第三方，UCCL 不直接控
- `uccl/p2p/` — 另一个产品线
- `uccl/collective/`、`uccl/ep/bench/baseline/` — bench 对照组
- `uccl/ep/tests/pcie_bench.cu` — 独立 bench 工具，不在运行期路径
- `uccl/ep/deep_ep_wrapper/` — wrapper 胶水

**已在之前轮次识别过、本次跳过的**（根据任务要求）：
- SBO Sprint A/B/C、multi-QP #485、shared-SRD-QP、count-send coalescing、flow_label/SL/EFA 协议层、`efadv_query_device` 漏调、launcher-cache/NUMA pin、`UCCL_EP_CPU_TIMEOUT_SECS`

## 附录 C：核心结论（一句话版）

**UCCL-EP 代码库的整体卫生度比预想的高**：绝大多数 `#ifdef` 是硬件平台 gate、绝大多数 env var 是 NIC 配置或已知 workaround，**真正 "作者写完没默认开" 的只有 PER_EXPERT_BATCHING 一条**。并且这条要默认开也需要 p5en 实测数据先行（见 §7.1），不能凭直觉推 PR。

# UCCL-EP MVP Compromises & Polish Opportunities

调研仓库快照：`/home/ec2-user/workspace/uccl/ep/` (main，2026-04-26)
目的：从 "UCCL-EP motivation + 外部约束" 推 MVP 妥协点，定位一个 PR 能修的工程细节，作为 SBO/multi-QP/shared-QP 之外的第二梯队 lever 储备。

---

## 0. TL;DR

- **找到的 MVP 点数**：38 条（TODO/FIXME/XXX 原注释 18 条 + 独立源码观察 20 条）
- **类别分布**：
  - 数据结构（热路径 `std::unordered_map` 重建）：4 条
  - hot-path 临时 `std::vector` 分配：5 条
  - Config / 调参表 hard-coded：6 条
  - CUDA kernel 配置（launch_bounds/cluster/SM 数）：4 条
  - Python/nanobind marshalling：3 条
  - 错误路径 / guard printf：6 条
  - Init vs hot path 分离（Layout 重算、getenv）：4 条
  - 协议 / imm 位预算：3 条
  - 算法精度（"TODO: faster encoding"、reduction）：3 条
- **前 5 高 ROI lever**（细节见 §3）：
  1. **L-01 CPU proxy hot-path stateless → flat arrays** — 消除 `post_rdma_async_batched` 每次调用建 2-3 个 `unordered_map`，ROI：每批 WR 省 500 ns–3 µs，decode batch=1 尤其收益显著
  2. **L-02 `LowLatencyLayout` 从 launcher 移到 `Buffer` 构造期** — `uccl_ep.cc:1218, 1160` 每次 dispatch 重算一次 8+ 字段布局
  3. **L-03 `post_gpu_commands_mixed` 的 8 个 `std::vector` 池化** — `proxy.cpp:863–864` 纯 kWarmup≠0 就能看到的分配噪声
  4. **L-04 `__launch_bounds__(X, 1)` 全量放开 min blocks/SM** — 所有 LL kernel 都是硬写 1，PTXAS 可能过度寄存器分配
  5. **L-05 Device-side error `printf` 挪到 host-checked fast-path** — kernel 热路径上存在多处无条件 `printf` 分支（即使命中率=0，编译器也要留 BRA 槽位）

以上 5 条和 SBO Sprint A/B/C、multi-QP、shared-SRD-QP 互补（§4 单独说明），**不冲突、且都在 CPU proxy / host launcher / kernel launch 三层，完全避开 SBO/EFA 协议层改动**。

---

## 1. TODO/FIXME 扫描结果

> 仅列与性能 / hot-path 直接相关的条目，纯功能性 TODO（例如 uccl_bench 未接 mscclpp fifo）略。

| # | 文件:行 | 注释 | 性能相关？ | 分类 |
|---|---|---|---|---|
| T1 | `src/proxy.cpp:105` | `TODO(MaoZiming): improves pinning.` | ✅ | NUMA / pinning |
| T2 | `src/proxy.cpp:182` | `TODO(MaoZiming): Skip registering for EFA.` | ✅ | init，浪费 atomic MR slot |
| T3 | `include/uccl_ibgda.cuh:176` | `TODO(MaoZiming): Fix. This should be a non-fetch add operation.` | ✅ | 多打一次 round-trip |
| T4 | `src/internode_ll.cu:252` | `TODO: This has an extra temp->per-expert copy in the FP8 path.` | ✅✅ | 双份显存拷贝 |
| T5 | `src/internode_ll.cu:917` | `TODO: try elect_one_sync` | ✅ | warp divergence |
| T6 | `src/internode.cu:24` | `TODO: faster encoding` (SourceMeta) | ✅ | 每 token 构造 |
| T7 | `src/internode.cu:188-189` | `TODO: more light fence / overlap EP barrier and NVL cleaning` | ✅✅ | 同步开销 |
| T8 | `src/internode.cu:254` | `TODO: may use NVSHMEM reduction` | ➖（我们已弃 NVSHMEM） | — |
| T9 | `src/internode.cu:998` | `TODO: try thread-level put_nbi?` | ✅ | 粒度 |
| T10 | `src/internode.cu:2021` | `TODO: maybe too many registers here` (combine kernel) | ✅✅ | register pressure 直接影响 occupancy |
| T11 | `src/internode.cu:1455,2009` | `TODO: make it as finer-grained template` | ✅ | branch-free inlining |
| T12 | `include/ep_config.hpp:211` | `TODO: Support per-GPU destination batching in this path.` | ✅ | 另一个 batching 维度 |
| T13 | `include/ep_config.hpp:230` | `TODO: optimize memory usages` | ➖ | 容量非延迟 |
| T14 | `bench/buffer.py:55` | `TODO(MaoZiming): Reduce SMs. UCCL Proxy should reduce the usage of SMs.` | ✅✅ | `num_sms=20` 硬写，占用 compute SM |
| T15 | `bench/buffer.py:691, 719` | `TODO: automatically tune` (Config table) | ✅✅ | DeepEP 表直接套用 |
| T16 | `include/ring_buffer.cuh:309` | `TODO(MaoZiming) to refactor` | — | 代码洁净，非性能 |
| T17 | `include/common.hpp:83` | `TODO(MaoZiming): I tried to fit more bits, but this eats into offset and values.` | ✅ | imm 位宽 → kReorderingBufferSize=16 |
| T18 | `src/rdma.cpp:2331` | `TODO(MaoZiming): pass node_idx instead.` | ➖ | API |

重点 4 条高 ROI：**T4（FP8 双拷贝）/ T10（register pressure）/ T14（num_sms=20 硬写）/ T15（Config 表未为 EFA 重调）**。

---

## 2. 按类别分 MVP 点

### 2.1 数据结构

**D1. Hot-path `std::unordered_map` 重建（每批 WR 一次）**
`src/rdma.cpp:1374, 1402, 1812, 1838, 2241, 2417, 2807, 2824, 2985, 3129, 3269, 3286`
- `post_rdma_async_batched_normal_mode` (line 1374)：`std::unordered_map<int, std::vector<size_t>> dst_rank_wr_ids;` 每次分桶再 iterate。
- `post_rdma_async_batched_fast_mode` (line 1812)：同样模式 + `std::unordered_map<int, std::vector<size_t>> dst_expert_wr_ids;` (line 1838，`USE_RECEIVER_BARRIER` 下)。
- 这两个函数是 CPU proxy → EFA WR 的最内层路径，被 `Proxy::process_gpu_commands` → `post_gpu_commands_mixed` 每批调用一次。
- 为啥慢：`unordered_map` 桶数组触发 `new`（tc-malloc 下 ~30-80 ns）+ hash + 链表节点分配；对 ≤8 个 dst_rank 的 EP，**固定大小 `std::array<std::vector<size_t>, kMaxRanks>` 就够用**。
- 复杂度 & 证据：N（batch size）= 32–256，map insert 付 N 次 allocator hit。

**D2. `std::set<PendingUpdate>`（poll-cq loop）**
`src/proxy.cpp:999`，每次 `quiet_cq` 迭代重建 set，虽然在退出路径，但 `std::set` 是红黑树，对热路径的 poll loop 仍是不必要的 cache miss 源。可用 intrusive list 或 flat_set。

**D3. `ctx_by_tag_: std::vector<ProxyCtx*>` 作为 O(1) 查表**
`src/proxy.cpp` + `rdma.cpp` 多处，此处**已是 vector**（OK），保留做对比——说明作者知道 vector 优势，但在 2.1 D1 场景没用，有明显的 MVP 不一致。

**D4. `std::map<std::pair<int, size_t>, bool> cache`（`can_register_gpu_memory_for_rdma`）**
`src/rdma.cpp:763`，虽然 `thread_local` + static，cache key 是 `(gpu_idx, bytes)`。此函数在 init 路径调用，OK，但 `getenv()` 内联在 `can_register_gpu_memory_for_atomics` (line 818) 每次调用仍会触发 libc 锁。
- 改为 `static const bool cached = [](){...}()` lambda 模式（`common.hpp:121` 已有这种写法），保证 `getenv` 仅一次。

### 2.2 hot-path 临时 `std::vector` 分配

**V1. `post_gpu_commands_mixed` 的 8 个 vector**
`src/proxy.cpp:863-864`：
```cpp
std::vector<uint64_t> rdma_wrs, atomic_wrs, quiet_wrs, barrier_wrs;
std::vector<TransferCmd> rdma_cmds, atomic_cmds, quiet_cmds, barrier_cmds;
```
每次 `process_gpu_commands` 调用都创建 8 个空 vector，然后 push_back 再 clear。
- 对比 line 751-753 `wrs_to_post.clear(); cmds_to_post.clear();` — **这两个 vector 已经是成员，不会重新分配**。说明作者在最外层做了 pool，但下一层忘了。
- Fix：把 8 个也提到 `Proxy` 成员，`.clear()` 而非重建。每次 `post_gpu_commands_mixed` 省 8×24B 栈→堆 + vector 内部 buf（如果溢出）。
- 低成本、零风险、30 分钟就能 PR。

**V2. `ring_wrids` 内层循环 push_back**
`src/rdma.cpp:1428` `std::vector<uint64_t> ring_wrids; ring_wrids.reserve(idxs.size());`
- 单次 `post_rdma_async_batched_normal_mode` 内部对每个 ring 都重建。有 reserve 所以不重分配，但 heap alloc 本身 ~50 ns × num_rings。
- Fix：thread_local 或 Proxy 成员复用。

**V3. `uccl_ep.cc:863-864` 姐妹问题的镜像**
同 V1，`post_gpu_commands_mixed` 是 Proxy 成员方法，放 Proxy 成员一次分配即可。

**V4. `d2hq::HostD2HHandle h{};` 在 `Proxy::set_bench_d2h_channel_addrs`**
init 路径 OK。

**V5. `per_tag: std::unordered_map<uint32_t, std::vector<ibv_recv_wr>>`**
`src/rdma.cpp:2241, 2417`，`post_receive_buffer_for_imm` 系列。调用频率不高，但对 receive 突发场景仍可优化。

### 2.3 Config / 调参表 hard-coded

**C1. `Buffer.num_sms = 20` 固定**
`bench/buffer.py:55-56` 注释 `TODO(MaoZiming): Reduce SMs.`
- UCCL proxy 已接管 RDMA path，**仍占 20 个 SM 的 warp 负责发 count/clean**；DeepEP 原版占 SM 数 ≠ UCCL-EP 应占的数。
- 这是 paper 级别的优化空间，但也可以视作 MVP：**把 num_sms 做成 hidden / batch-aware 自动调**。

**C2. `get_dispatch_config / get_combine_config`（DeepEP 调参表）直接继承**
`bench/buffer.py:680-733`，对 `num_ranks ∈ {2,4,8,16,24,32,64,128,144,160}` 手写表，注释 `# TODO: automatically tune`。
- 这些常数（24, 288, 20, 128 等）是 **NVIDIA IB 上 DeepEP 原版的 sweet spot**，EFA 网卡 + p5en 拓扑从未重调。
- 直接起 sweep script（num_channels × recv_tokens × send_tokens × message_bytes）4 小时能标掉一版 EFA 原生表。

**C3. `common.hpp:62-89` 所有 `k*` 常数**
- `kMaxInflightLowLatency=32`
- `kMaxInflightNormal=8`
- `kChannelPerProxy=8`, `kNumProxyThs=4` → 每 GPU 32 个 channel，EFA 32 QP 建议值
- `kBatchSize=32`，`kMaxOutstandingSends=2048`，`kObjectSize=7168`
- `kReorderingBufferSize=16`（注释 "Right now only 4 bits" → imm 位预算约束，T17）
- Fix：暴露为 `UCCL_*` 环境变量；T17 的 4-bit 限制可通过 repurpose 未用的 imm 字段扩展到 6-bit。

**C4. `kQueueSize=2048`**（`common.hpp:62`）
CPU proxy ring buffer 长度。p5en 大 batch 下可能不够，小 batch 下 cache 不友好。

**C5. AH SL / TC hard-coded default**
`src/rdma.cpp:1198`（SL=3）、`:1201`（TC=104）
- 注释提到是 RoCE 场景的默认值。EFA SRD 不用 SL/TC，但变量仍跑 `ah_attr.sl` 赋值。
- 清理成本低，避免误解。

**C6. `kPrintCycleInterval = 100000000000ULL`（common.hpp:94）**
device 内部 `clock64()` 对比，实际 10s@1GHz；改为 env-tunable。

### 2.4 CUDA kernel 配置

**K1. `__launch_bounds__(X, 1)` 所有 LL kernel**
`src/internode_ll.cu:23, 50, 735`；`src/internode.cu:480, 2086, 2088`；`src/intranode.cu:186, 722`。
- 第 2 个参数是 "minBlocksPerMultiprocessor"，**全部硬编码 1**。
- 这告诉 PTXAS "每 SM 只需一个 block"，于是 PTXAS 可以把寄存器用满，导致 occupancy = 1 block/SM。
- **对大 hidden / small batch**（decode 场景 batch=1 hidden=7168），寄存器压力本来就不满，提高到 2 会让两个 block 能并行 latency-hide。
- 证据：`internode.cu:2021` 作者自己注释 "TODO: maybe too many registers here"。
- Fix：加 `__launch_bounds__(X, 2)` template 变体，A/B 测试 decode ITL。

**K2. `cudaLaunchAttributeClusterDimension = (num_sms % 2 == 0 ? 2 : 1)`**
`include/ep_launch.cuh:12` — 所有 kernel 走 TMA cluster=2。
- 对 decode batch=1 单 token 通信，TMA cluster 同步开销 > 收益。
- Fix：per-call 路径走 cluster=1；只有高吞吐路径用 cluster=2。

**K3. shared memory `__align__(1024) uint8_t smem_buffer[]`**
`src/internode_ll.cu:821`。对齐到 1024 保证 TMA，但 small-token 场景 shared memory 冗余。不是 critical，记录。

**K4. 无 `__launch_bounds__` 的 helper kernel**
`layout.cu`（153 行，全是 host code）没有 `clean` 等独立 kernel，OK；但 `clean_low_latency_buffer` (`internode_ll.cu:40`) 是 `kNumThreads=256` 固定，没有 `__launch_bounds__`。这个 kernel 每次 dispatch 都启动一次，overhead = 1 kernel launch ≈ 3-5 µs。能否和 dispatch 合并？

### 2.5 Python binding

**P1. nanobind 大量 individual `std::uintptr_t` + `int` 参数**
`src/uccl_ep.cc:1892-1939, 1940-1976, 1977-2018, ...`，`intranode_dispatch` / `intranode_combine` / `internode_*` 系列每个有 30+ 标量参数。
- nanobind 每个参数付一次 marshalling（~20-50 ns/arg），一次调用 ~1 µs Python→C++ overhead。
- **Fix**：引入单一 `DispatchParams` dataclass（Python）+ `DispatchParams*` 指针（C++），一次传 struct。ROI ≈ 每次调用省 0.5-1 µs。decode 端每 token ~10 µs 预算，1 µs 是 10%。

**P2. `previous_event` 是 `nb::object`（可能是 None）每次 `.is_none()` 判断**
`uccl_ep.cc:1908-1912` 等多处重复模式。nb::cast 里 Python GIL 仍持有。
- Fix：引入单一 `EventOption = (cudaEvent_t) or 0` 的 uintptr_t 接口，避免 Python object。

**P3. `std::optional<std::function<void()>> recv_hook = std::nullopt;`**
`uccl_ep.cc:1280`。`std::function` 在 lambda 捕获长对象时会 heap-allocate。
- Fix：`recv_hook` 可改成 POD 回调（函数指针 + user_data 指针）或从返回值中移除（由 Python 记录 launch_stream 再主动触发）。

### 2.6 错误路径 / guard printf

**E1. 设备内 `printf` 在 hot warp**
`include/uccl_ibgda.cuh:132, 139, 145, 165-168` + `src/internode_ll.cu` 多处。
- 这些是 "bytes_val 太大" 的 guard，命中率应该是 0。但 PTXAS 编译时会留 BRA + 文字字符串 + `vprintf` stub。
- 影响 instruction cache + register lifetime。改为 `EP_DEVICE_ASSERT` 在 DEBUG build 才包含，release build 用 `__builtin_unreachable()`。

**E2. 大量 `std::abort()` / `printf(...); std::abort();` 在 `post_rdma_async_batched_*`**
`src/rdma.cpp:1371, 1379, 1386, 1399, 1507-1510` 等。
- 虽然 abort 路径本身 OK，但每个 `if (...) { std::abort(); }` 都占分支预测 slot。
- Fix：`UCCL_ASSERT(cond)` 宏在 release build 里展开成 `__builtin_expect(cond, 1)` + compact `std::abort`。

**E3. `std::abs((int)cmds_to_post[i].dst_rank - (int)my_rank) % MAX_NUM_GPUS != 0` 判断**
`src/rdma.cpp:1381`。每个 WR 做一次 mod 操作，注释说 "NOTE(MaoZiming): this should not happen."。
- 这是 runtime guard，但**成本 O(batch_size)**，可以挪到 init/debug。

**E4. `fprintf(stderr, ...); std::abort()` 多处**
`rdma.cpp` 139 次 printf，大部分是 guard。建议 `#ifdef UCCL_DEBUG` 包。

**E5. `fprintf(stderr, "Size mismatch...")`**
`src/rdma.cpp:1369, 1805`，命中率 0；保留但宏封装。

**E6. GPU 侧 "stuck waiting" loop printf**
`include/uccl_ibgda.cuh:163-170`，`clock64() - last_print > kPrintCycleInterval` 每 10s 一次。对健康运行无开销（只有计数），但 `clock64()` 本身每次 poll 触发一次 special register 读。
- Fix：改成 CPU 侧 timeout + watchdog thread，GPU 侧只 spin。

### 2.7 Init vs hot path 分离

**I1. `LowLatencyLayout` 每次 dispatch 重算**
`src/uccl_ep.cc:1160, 1218`。构造函数 `LowLatencyLayout(rdma_buffer_ptr, num_max_dispatch_tokens_per_rank, hidden, num_ranks, num_experts, atomic_buffer_ptr)`：
- 算出 8+ 个 offset/size 字段。
- 所有参数在 Buffer 生命周期内不变。
- **每次 dispatch / combine 都算一次** — 占 CPU launch 的一部分，~200-500 ns。
- Fix：把 layout 存到 `Buffer` 成员，构造时算一次。
- 见 `include/ep_config.hpp:168-317`，构造函数非 trivial。

**I2. `auto [ptr0, ptr_internode0, count0] = next_buffer.clean_meta();` 每次 dispatch 算**
`src/uccl_ep.cc:1253`。同 I1，purely 从 layout 推导。缓存后直接读。

**I3. `get_max_inflight_bytes()` 等 lambda static**
`include/common.hpp:121-146`。**已用 lambda static 模式**，OK，说明 idiom 懂但 `can_register_gpu_memory_for_atomics:818` 忘了用。不一致。

**I4. `pin_thread_to_numa_wrapper` 里 `sched_getcpu()` + `pthread_getaffinity_np`**
`src/proxy.cpp:126-131`。init 一次，OK。但 `pin_thread_to_cpu_wrapper` 版本 `sched_getcpu()` 同步 print，也是 init 路径，OK。

### 2.8 协议 / imm 位预算

**X1. `kReorderingBufferSize=16`（4 bits）**
`include/common.hpp:85`，注释 "Right now only 4 bits"。
- imm_data 32 bit，作者自己说想扩但 "eats into offset and values"。
- Fix：**WriteImm / AtomicsImm 字段重排**，例如把 `num_tokens` 从 13 bit 降到 10 bit，换 3 bit 给 seq，把 reordering buffer 扩到 128。

**X2. `pack_ll_expert_slot(expert_idx, num_tokens)` 用 10+13=23 bit**
`include/uccl_ibgda.cuh:157`（调用点）。为什么 num_tokens 要 13 bit？decode batch ≤ 128 时只需 7 bit，省 6 bit 给别的。

**X3. `atomic_val >> 8` 判断溢出**
`include/uccl_ibgda.cuh:144`。atomic_val 只留 8 bit。这是 SBO Sprint C 想解的 "signal payload 位宽不够" 的根因之一。

### 2.9 算法 / kernel 细节

**A1. `SourceMeta` 构造里 bitfield 循环 OR**
`src/internode.cu:24-31`，作者注释 `TODO: faster encoding`。
- 用 `__ballot_sync` 或 `__vcmpgeu4` 一句即可替代 `for (int i = 1; i < 8; ++i) bits |= is_token_in[i] << i`。
- 虽然单次 ns 级，每 token 调用一次，累计有意义。

**A2. combine reduce 里 `kMaxNumRanks` 大小的 int4 数组**
`src/internode.cu:2022`（`TODO: maybe too many registers here`），每线程开 kMaxNumRanks(=64) 个 int4 = 1024 B 寄存器。
- 这是 K1 提到的 register pressure 源头。
- Fix：改为 tile 方式分多轮 reduce，用 shared memory 做中间暂存。但这是较大改动。

**A3. `atomicAdd` 本地 vs `nvshmemi_ibgda_amo_nonfetch_add` 远程**
`include/uccl_ibgda.cuh:185-187`，本地 fast-path 直接 `atomicAdd`；远程走 proxy 做 fetch-add（注释 T3 说应为 non-fetch add）。
- Fix：**T3 的 non-fetch add**（Mooncake 已有实现）能省一次 CQE 等待。

---

## 3. 最高 ROI 前 5（PR-level 设计）

### L-01：CPU proxy hot path stateless → flat arrays（推翻 D1/V1/V2）

**现状**：`post_rdma_async_batched_normal_mode` / `_fast_mode` 每批 WR 调用一次，每次 `new std::unordered_map<int, std::vector<size_t>>`，再 `new std::unordered_map<size_t, std::vector<size_t>>` for ring 分组，再 `std::vector<uint64_t> ring_wrids` 内层。

**PR 设计**：
- 在 `ProxyCtx` 里固定预分配 `std::array<std::vector<size_t>, kMaxRanks> dst_rank_wr_ids;`（kMaxRanks=128 已足以）。
- 每次调用用 `.clear()`（vector 保留 capacity），避免 hash 桶重建。
- `ring_to_indices` 同样改为 thread_local 或 ctx 成员。

**收益估算**：
- 每个 `std::unordered_map<int, vector>` 空构造 ~80 ns + 每个 insert ~50 ns。
- 典型批 32 个 WR，跨 8 个 dst_rank：2×(80 + 32×50) = 3.4 µs 净分配开销 / 批。
- decode ITL 预算 ~200-400 µs，节省 3 µs ≈ 1%。
- 高并发 prefill 批（1000 WR）：可能 50 µs 差值。

**实现成本**：1 天（改 3 个函数签名，benchmark 前后对比）。
**风险**：无，纯工程。
**与 SBO 关系**：独立。SBO Sprint B 改 CPU proxy 内部的 poll 结构；L-01 改 CPU proxy 的 WR 批处理结构，两者可并行。

---

### L-02：`LowLatencyLayout` 一次算常驻

**现状**：`uccl_ep.cc:1160, 1218` 每次 `low_latency_dispatch` / `low_latency_combine` 都调 `LowLatencyLayout layout(...)` 构造函数，算 8 个字段。

**PR 设计**：
- 在 `Buffer` 类成员加 `uccl::LowLatencyLayout ll_layout_[2]`（for buffer_idx 0/1）。
- `Buffer` 构造（或 first dispatch）时一次算好，之后只读 `ll_layout_[idx]`。
- `clean_meta()` 结果也缓存。

**收益估算**：
- Layout 构造每次 ~300-500 ns CPU。
- decode ITL loop 每 token 约 200 µs，0.3-0.5 µs 约 0.15-0.25%。
- **复合收益**：当 decode batch=1，launcher CPU 路径是 ~3-5 µs total，此项占 10-15%。

**实现成本**：半天。
**风险**：需确保 `num_max_dispatch_tokens_per_rank/hidden/num_ranks/num_experts` 确实 buffer 生命周期内不变（代码里是 Buffer 构造参数，是）。

---

### L-03：`post_gpu_commands_mixed` 8 vector 池化

**现状**：`src/proxy.cpp:863-864` 每次调用创建 8 个空 vector；虽然 push_back 再 clear，每次调用都是新的 stack frame。

**PR 设计**：
- 把 8 个 vector 提到 `Proxy` 成员：`std::vector<uint64_t> rdma_wrs_, atomic_wrs_, quiet_wrs_, barrier_wrs_;` + 同 TransferCmd 版本。
- 进入 `post_gpu_commands_mixed` 先 `clear()`，出口同样。

**收益估算**：
- 每个 `std::vector<T>` 默认构造 24 B，不触发 heap。但**第一次 push_back 会 malloc**。
- 对 warm batch（每次都有 4 类 cmd）：8 次 malloc → 8 次 cache 重复建 capacity。池化后稳态 0 malloc。
- 估 1-2 µs / 批省。

**实现成本**：30 分钟。
**风险**：几乎无。注意 `post_rdma_async_batched` 内部对 `rdma_wrs` 有隐式拷贝？答案：否，它按 const& 传。OK。

---

### L-04：`__launch_bounds__(X, 1)` 放开到 2

**现状**：所有 LL kernel 硬 `__launch_bounds__(X, 1)`，告诉 PTXAS min blocks/SM=1 → 寄存器尽用。

**PR 设计**：
- 对 `dispatch` / `combine` kernel 加 template 参数 `int kMinBlocksPerSM = 1`，默认保持 1，但导出 `kMinBlocksPerSM = 2` 变体。
- Runtime 据 `num_tokens` 选：batch=1 用 2，batch≥4 用 1。

**收益估算**：
- decode batch=1 场景 occupancy 从 1 → 2 block/SM，latency-hide 提升，ITL 预计 -2~-5%。
- 需实测：NVCC 可能因寄存器不够拒绝编译。

**实现成本**：1-2 天（涵盖 profiler run 验证）。
**风险**：中。若 PTXAS 给更激进 register cap，combine kernel（T10）可能 register spill → L1 miss 反而变慢。
**与 SBO 关系**：SBO Sprint A 改 GPU kernel 的 comp_signal；L-04 改的是 launch config，不碰 kernel 内部，互不相干。

---

### L-05：device `printf` / `std::abort` guard 清理

**现状**：`uccl_ibgda.cuh:132, 139, 145` 有多处 "bytes too large" guard；`rdma.cpp` 139 次 `printf`/`fprintf`。

**PR 设计**：
- 引入 `UCCL_RELEASE_ASSERT(cond, msg)` 宏：`#ifdef NDEBUG` 展开为 `if (__builtin_expect(!(cond), 0)) __builtin_trap();`；debug 模式展开为完整 `fprintf + abort`。
- kernel 内同理，release 走 `__trap()` 无 printf。

**收益估算**：
- GPU kernel 侧：每个 `printf` 保留的 vprintf stub 在 binary 里占 ~100 字节 + runtime 每个 warp 的分支 slot。
- 多个 `trap()` 可合并为一个 "bad path" block，PTXAS 可更好优化 register lifetime。
- 典型：1-2% 提升，且代码清理价值高。

**实现成本**：1-2 天（但改动面广，需 review）。
**风险**：低，但丢失调试信息——需确保 debug build 仍保留。

---

## 4. 和之前 lever 的互补性

| 之前的 lever | 层位 | 本次 lever | 层位 | 冲突？ |
|---|---|---|---|---|
| SBO Sprint A (CPU spin → GPU spin) | GPU kernel signal poll | L-04 launch_bounds | kernel launch config | 互补 |
| SBO Sprint B (CPU spin EFA 独占) | CPU proxy 内部 | L-01 / L-03 CPU proxy 数据结构 | CPU proxy 外部 | 互补，都在 proxy.cpp 里但改不同函数 |
| SBO Sprint C (Blackwell src_signals) | EFA + kernel | — | — | 独立 |
| multi-QP PR #485 | QP 数量 | L-04 launch_bounds | kernel launch | 互补 |
| shared-SRD-QP (Mooncake #1944) | QP 数量 | L-02 Layout 缓存 | host launcher | 互补 |
| count-send coalescing | proxy batching 策略 | L-03 vector 池化 | proxy batching 实现 | 同函数，但 count-send 改输出格式，L-03 改内部数据结构。需同一 PR 里协调。 |
| efadv caps 漏查 | EFA 层 | L-05 printf guard | kernel / proxy | 独立 |
| launcher-cache / NUMA pin | host launcher | L-02 Layout 缓存 | host launcher | 互补，L-02 是 launcher-cache 的一个具体化 |

**结论**：L-01/L-02/L-03 都是 **host-side 工程优化**，SBO 是 **协议 / kernel 路径优化**，正交。如果都做，复合收益可达 decode ITL -5% 到 -10%。

---

## 5. 诚实标注的 UNKNOWN

1. **T4 (FP8 temp→per-expert copy) 量级**：没在代码里看到 `num_bytes_per_msg` 被多拷一次的确切显存带宽影响。需 nsys profile 确认。
2. **L-04 (launch_bounds=2) 是否真能编译通过**：NVCC 可能对 combine kernel 因 `kMaxNumRanks=64` int4 数组拒绝 min_blocks=2。需实际尝试 `make` 验证。
3. **L-01 vs tc-malloc / jemalloc 分配器**：如果部署栈默认用 tc-malloc，`unordered_map` 桶分配已被线程 cache 吸收，收益可能只 1 µs 而非 3 µs。
4. **P1 (nanobind 参数 marshalling) 实际开销**：声称 20-50 ns/arg 是 pybind11 数据，nanobind 更快（号称 3-10×），所以 P1 收益可能被高估 3-5 倍，减到 0.2-0.3 µs。
5. **X1 (imm 位预算 / kReorderingBufferSize 扩展)**：扩到 6 bit (64 slot) 需要重排 AtomicsImm / WriteImm 字段布局，可能牵连 sender/receiver barrier 协议。改动面较大，列为 MVP 但工程成本非一人日。
6. **C1 (`num_sms=20`) 和 compute stream 抢 SM**：是否真抢不清楚——p5en Hopper 有 132 SM，20 算占 15%，不排除 compute kernel 本来 occupancy<85% 情况下互不影响。需 nsys 对比 num_sms=8/16/20/24 的 end-to-end。
7. **A2 (combine register tile)**：需实际 nvcc --ptxas-options=-v 看 regs/thread 决定是否需要。
8. **K2 (cluster=2 对 small-batch 影响)**：SM90+ 的 thread block cluster API 在 small workload 是否真引入同步开销未测过。

---

> 附：验证后端方法建议
> - L-01/L-03：写 micro-bench，mock batch_size=32 + 8 dst_rank，对比有无 map 重建。
> - L-02：加 `printf("layout construct")` log + time，对比 dispatch loop 1000 次的时间差。
> - L-04：`nvcc --ptxas-options=-v` 前后 regs/thread 差值 + `nsys profile` occupancy。
> - L-05：Release build binary size diff + `cuobjdump --dump-sass` 比对 BRA 数量。

— Agent Q，2026-04-26

# NIXL EFA 专有修改对 UCCL-EP 的借鉴价值

**生成时间**: 2026-04-26
**NIXL 版本**: ai-dynamo/nixl main @ 2026-04-26 shallow clone
**UCCL-EP 路径**: `/home/ec2-user/workspace/uccl/ep/src/`
**NIXL libfabric 插件路径**: `/tmp/nixl/src/plugins/libfabric/`, `/tmp/nixl/src/utils/libfabric/`

---

## 0. TL;DR

- **NIXL libfabric backend 的 EFA 专有工程优化**: 扫到 ~14 条明确的 provider-specific / 拓扑-specific 代码路径。
- **UCCL-EP 对应位置没做的**: 6 条（其余 8 条已被 UCCL-EP 以不同形式覆盖或不适用）。
- **可借鉴到 all-to-all 场景的**: 3 条（考虑 NIXL=点对点 KV，UCCL-EP=EP×rank 多对多 MoE dispatch/combine，很多单链接优化搬不过来）。
- **建议立即评估的 TOP 3**:
  1. **SRD RNR-retry=7 (infinite) via 专用接口**（UCCL-EP `#ifdef EFA { return; }` 完全跳过 RNR 配置，这是 bug 级遗漏）
  2. **Progress loop 只轮询 active rails/QPs**（NIXL 用 refcount 跳过 idle CQ，UCCL-EP proxy 对每个 ring 的 CQ 都 poll）
  3. **FI_MR_VIRT_ADDR 开/关的双地址模式**（NIXL 根据 provider 自动切 virt-addr vs offset 语义；UCCL-EP 硬编码 iova；跨 provider/版本测试有隐患）
- **排除在外的** (不重复已知 lever): multi-NIC LB、PCIe-NUMA 拓扑分组、CQ_WITH_EXT_MEM、launcher-cache、flow_label 等 — 这些已在 Phase 1-16 或 `reference_alltoall_deep_dive` 里覆盖。

---

## 1. NIXL libfabric backend 架构速览

### 1.1 核心文件

| 文件 | 行数 | 作用 |
|------|------|------|
| `src/plugins/libfabric/libfabric_backend.cpp` | 1633 | 引擎主逻辑: `nixlLibfabricEngine` — postXfer, 进度线程, notification, CUDA 上下文 |
| `src/plugins/libfabric/libfabric_backend.h` | 599 | 类定义 |
| `src/utils/libfabric/libfabric_rail.cpp` | 1532 | 单 rail (= 单 EFA 设备) libfabric 资源封装 |
| `src/utils/libfabric/libfabric_rail_manager.cpp` | 1686 | 多 rail 调度 + striping + rail selection policy |
| `src/utils/libfabric/libfabric_topology.cpp` | 1283 | hwloc PCIe/NUMA 拓扑发现 + GPU↔EFA 映射 |
| `src/utils/libfabric/libfabric_common.cpp` | 301 | 工具: XFER_ID、env 覆盖、NUMA 查询 |

### 1.2 关键类 / 函数

- `nixlLibfabricEngine::postXfer()` — 统一入口，走 striping 或 round-robin
- `nixlLibfabricRailManager::prepareAndSubmitTransfer()` — 在 rail 间分片/分派
- `nixlLibfabricRailManager::progressActiveRails()` — **只轮询被引用的 rail**（lever 2）
- `nixlLibfabricRail::progressCompletionQueue()` — 单 rail CQ batch read (batch=16)
- `nixlLibfabricRail::postWrite/postSend` — `fi_writedata` / `fi_senddata` + **带 EAGAIN-driven progress 的无限重试**
- `nixlLibfabricNumaRailSelectionPolicy::selectRails()` — 按 NUMA 距离选 rail
- `nixlLibfabricTopology::buildTopologyAwareGrouping()` — hwloc grouping + PCIe switch 带宽限制
- `nixlLibfabricCudaCtx::cudaUpdateCtxPtr` — **CUDA 多进程 primary context workaround**

---

## 2. EFA 专有修改清单

### [NIXL 修改 1] — `FI_OPT_EFA_USE_UNSOLICITED_WRITE_RECV = false`

**位置**: `src/utils/libfabric/libfabric_rail.cpp:527-544`
```c
const bool use_unsolicited_write_recv = false;
ret = fi_setopt(&endpoint->fid, FI_OPT_ENDPOINT,
                FI_OPT_EFA_USE_UNSOLICITED_WRITE_RECV,
                &use_unsolicited_write_recv, sizeof(...));
```

**做什么**: 明确关闭 EFA "unsolicited write recv" 行为，让带 imm 的 RDMA_WRITE 消费接收 WR（而不是无需 WR）。

**为什么**: 注释写 "to reduce CQ overflow likelihood" — NIXL 用预发 recv pool（`NIXL_LIBFABRIC_RECV_POOL_SIZE=1024`）做流控；如果开 unsolicited，每个 remote write 都直接走 CQ，接收侧 CQ 容易冲爆（CQ size=12288, ref `libfabric_rail.cpp:482`）。

**UCCL-EP 对应位置**: `src/rdma.cpp:913-914`：
```c
// If set, Receive WRs will not be consumed for RDMA write with imm.
efa_attr.flags |= EFADV_QP_FLAGS_UNSOLICITED_WRITE_RECV;
```
UCCL-EP **启用** unsolicited（相反决策）。UCCL-EP 之所以能这么做，是因为它不依赖 recv WR 匹配 imm — imm data 直接带 wr_id 到 CQE，走不同的流控（shared completion path）。

**能否移植到 all-to-all**: **No**。UCCL-EP 架构本来就是 "write-only no-recv-WR" 模式，关掉 unsolicited 反而会引入恢复问题（要预发海量 recv）。NIXL 的做法适合点对点 KV（固定 1:1 流），不适合 EP=32 节点到 32 节点的 dispatch fan-out。

**预期收益**: 无，已覆盖（相反决策更合 UCCL-EP workload）。**跳过**。

---

### [NIXL 修改 2] — `FI_OPT_EFA_RNR_RETRY = 7` (infinite)

**位置**: `src/utils/libfabric/libfabric_rail.cpp:546-557`
```c
size_t rnr_retry = 7; // EFA_RNR_INFINITE_RETRY
ret = fi_setopt(&endpoint->fid, FI_OPT_ENDPOINT,
                FI_OPT_EFA_RNR_RETRY, &rnr_retry, sizeof(rnr_retry));
```

**做什么**: 把 EFA SRD QP 的 RNR (Receiver Not Ready) retry 次数设为 7 — 在 EFA provider 里，7 意味着硬件层**无限重传**而不是失败上报。

**为什么**: 接收 QP 的 RQ 暂时空（来不及 post recv）时，发送方不会 drop，而是在链路层重试。对 SRD 这种无内建流控的 QP type 至关重要。没设的话，默认值会在若干 RNR 后报错。

**UCCL-EP 对应位置**: `src/rdma.cpp:1280-1289` 的 `modify_qp_to_rts()`:
```c
#ifdef EFA
  return;   // ← EFA 路径直接跳过
#endif
  attr.retry_cnt = 7;
  attr.rnr_retry = 7;
```
UCCL-EP 在 EFA 分支**完全不配 RNR retry**，理由推测是 "verbs 的 `rnr_retry` 字段对 SRD 无效"。这是对的 — **但 libfabric 的 `FI_OPT_EFA_RNR_RETRY` 是专门为此设计的 SRD 专用 knob，UCCL-EP 漏掉了它的对应路径 (`efadv_set_driver_features` 或 rdma-core ibv_* 的等价项)**。

**能否移植到 all-to-all**: **Yes**。UCCL-EP 在 MoE dispatch 时，receiver 的 recv buffer 刷新是 GPU-paced (atomic counter)，completely 有可能出现 sender 先到 receiver 还没 post 的情况 — RNR 无限重试直接救场。但注意：UCCL-EP 是 `EFADV_QP_FLAGS_UNSOLICITED_WRITE_RECV` 模式，不消费 recv WR，RNR 触发条件不完全等同 — 需要先 micro-bench 验证在 UCCL-EP 当前模式下 SRD 是否还有 RNR 事件。

**预期收益**: **不确定，需要实测**。如果 UCCL-EP 现在偶发尾延迟尖刺、CQE error 日志里有 RNR 字样，这就是解。要是日志里没有，收益≈0。**建议先装 instrumentation 采 RNR 事件**。

---

### [NIXL 修改 3] — Progress loop 只轮询 active rails (`progressActiveRails()`)

**位置**: `src/utils/libfabric/libfabric_rail_manager.cpp:962-990` + `libfabric_rail_manager.h:257-270`
```c
nixl_status_t nixlLibfabricRailManager::progressActiveRails() {
    std::unordered_set<size_t> rails_to_process;
    {
        std::lock_guard<std::mutex> lock(active_rails_mutex_);
        rails_to_process.insert(0);  // rail 0 总是轮询（notifications）
        for (const auto &[rail_id, refcount] : active_rails_) {
            rails_to_process.insert(rail_id);
        }
    }
    // ... 只 poll 这几条 rail 的 CQ
}
```
配合 `registerMemory` 里的 `incRailActive(rail_idx)`（`libfabric_rail_manager.cpp:795`），每注册一块 memory 到 rail i 就给 i +1，这样 progress thread 知道哪些 rail "有货"。

**做什么**: 进度线程每轮只 poll 被标记活跃的 CQ，idle rail 直接跳过。

**为什么**: NIXL 预想 16+ EFA rail 的机型（p5en 4×100G, 实际 NIC 按 PCIe switch 分布），全部 poll 一遍浪费 ~N× CPU 和 PCIe MMIO。

**UCCL-EP 对应位置**: `src/proxy.cpp:500-543` `Proxy::run_progress()` — UCCL-EP 每个 proxy 线程绑 1 个 NIC 1 个 CQ，`poll_cq_dual` 每轮都 poll。**没有 "active ring" 的概念** — 如果某个 channel 暂时没有 outgoing request 也继续 poll。

**能否移植到 all-to-all**: **Partial**。UCCL-EP 一个 proxy 一个 NIC，单 CQ 架构下 "跳过 idle CQ" 不 apply。但 UCCL-EP 在 multi-channel 模式（`data_qps_by_channel`）下的 per-QP polling，如果将来合并用 `ibv_create_cq_ex` shared CQ，**可以借鉴 active-channel 标记跳过 idle QP 的 SQE drain**。另外 `kNumChannels=N` 的情况下，如果做 per-channel sqe 队列统计，idle channel 可以降 polling 频率。

**预期收益**: UCCL-EP 目前 proxy spin loop 占一个完整 CPU — 就算把它减半也没省，因为 CPU 是独占的。**除非** 改成 multiplex 多 NIC / 多 channel 共享一个 proxy（这是 NIXL 的架构但不是 UCCL-EP 的），否则 lever 不生效。**降级为备选**。

---

### [NIXL 修改 4] — `FI_THREAD_COMPLETION` + 每 rail 独立 endpoint lock

**位置**: `src/utils/libfabric/libfabric_rail.cpp:435` + 各 `fi_*` 调用里的 `ep_mutex_`（line 723, 1008, 1047, 1129, 1212）
```c
hints->domain_attr->threading = FI_THREAD_COMPLETION;
// ...
{
    std::lock_guard<std::mutex> ep_lock(ep_mutex_);
    ret = fi_cq_read(cq, completions, NIXL_LIBFABRIC_CQ_BATCH_SIZE);
}
```

**做什么**: 告诉 libfabric "我保证同一个 CQ/endpoint 同时只有一个线程操作"（FI_THREAD_COMPLETION），自己用 `ep_mutex_` 实现这个保证。

**为什么**: EFA provider 在 FI_THREAD_SAFE 下会加内部锁，FI_THREAD_COMPLETION 下 provider 可以省掉 libfabric 自己的锁，让用户代码负责排他访问。性能上能省一层。

**UCCL-EP 对应位置**: 无直接对应。UCCL-EP 不用 libfabric；但 UCCL-EP 的 `ibv_post_send` / `ibv_poll_cq` 也是 thread-unsafe 的 — UCCL-EP 单 proxy 线程独占 QP/CQ，天然满足 equivalent 语义，不用特别声明。

**能否移植到 all-to-all**: **N/A** — 不同协议栈。UCCL-EP 的 "单线程独占 QP" 本来就是 FI_THREAD_COMPLETION 的等价设计。**跳过**。

---

### [NIXL 修改 5] — `FI_CQ_FORMAT_DATA` + CQ size 12288 + `FI_WAIT_NONE` 非阻塞

**位置**: `src/utils/libfabric/libfabric_rail.cpp:479-490`
```c
struct fi_cq_attr cq_attr = {};
cq_attr.format = FI_CQ_FORMAT_DATA;   // 带 imm data 的 CQ 条目
cq_attr.wait_obj = FI_WAIT_NONE;       // 纯 polling，不 block
cq_attr.size = 12288;                  // 大 CQ
ret = fi_cq_open(domain, &cq_attr, &cq, NULL);
```

**做什么**: CQ 格式包含 4B imm data（用来搬 `NIXL_MAKE_IMM_DATA(msg_type, agent_idx, xfer_id, seq_id)`），纯轮询模式，CQ 容量 12288 entry。

**为什么**:
- `FI_CQ_FORMAT_DATA` 比 `FI_CQ_FORMAT_MSG` 多带 64-bit data 字段 — NIXL 用这个 imm 做 XFER_ID 追踪和 agent routing，省一次 recv buffer scan。
- `FI_WAIT_NONE` = 纯 polling（进度线程 + main thread spin）。
- size 12288 高 outstanding 容量。

**UCCL-EP 对应位置**: `src/rdma.cpp:850` `cq_ex_attr.cqe = cq_depth`（默认跟 kMaxOutstandingSends=128 相关）+ `IBV_WC_EX_WITH_IMM` 走的是 verbs 的 ibv_cq_ex，`cq_depth` 小，大约是 128~512 级别（调用点 `create_cq(ctx)` 会传 `kMaxOutstandingSends * something`）。

**能否移植到 all-to-all**: **Partial/不是新 lever**。UCCL-EP 已经用 `ibv_create_cq_ex` + imm 数据，等价。CQ 大小可以测一下是不是够用（UCCL-EP 在 EP=32 rank × 8 expert × backlog=4 下，瞬时 CQE 可能 >1K）。
**但这是 "depth 参数" 而不是新 lever**，并不属于专有优化 — **跳过**。

---

### [NIXL 修改 6] — EAGAIN-driven CQ progress 自驱动

**位置**: `src/utils/libfabric/libfabric_rail.cpp:1065-1096` (`postSend`), `1149-1180` (`postWrite`), `1231-1262` (`postRead`)
```c
while (true) {
    ret = fi_writedata(...);
    if (ret == 0) return NIXL_SUCCESS;
    if (ret == -FI_EAGAIN) {
        attempt++;
        // Progress completion queue to drain pending completions before retry
        if (!progress_thread_enabled_) {
            nixl_status_t progress_status = progressCompletionQueue();
            // ...
        }
        continue;
    }
    break;
}
```

**做什么**: post 遇到 `EAGAIN`（provider 内部队列满）时，**自己主动 drain CQ 再重试**，不是被动 sleep。

**为什么**: EFA provider 内部的 send buffer / shm buffer 有限，高并发 post 会 EAGAIN。与其 sleep，不如把 completion 处理掉（释放 wr slot）然后立刻重 post。

**UCCL-EP 对应位置**: 部分对应。UCCL-EP 在 `ibv_post_send` 之前通常已经做了 `poll_cq_once` drain（通过 `kMaxOutstandingSends` back-pressure）+ credit 管理。但**在 post 失败 (`-ENOMEM`) 路径上 UCCL-EP 是 assert exit**（`src/rdma.cpp:919-922` 等）— 不是 retry。

**能否移植到 all-to-all**: **Yes, partial**。UCCL-EP 的 back-pressure 模型是 "GPU 端 credit 保证永远不超发"，verbs 理论上不会 EAGAIN。但**在极限场景**（EP=32, micro-batch burst, 多 channel 同时 post）还是可能遇到 `send_wr` 队列满。此时如果自驱 drain 而非 exit，可提升鲁棒性。**不是性能 lever，是 robustness lever**。

**预期收益**: 鲁棒性，性能无直接提升。**降级为 P2 备选 (非性能)**。

---

### [NIXL 修改 7] — CUDA primary context workaround (`cuda_addr_wa_`)

**位置**: `src/plugins/libfabric/libfabric_backend.cpp:107-224`

NIXL 在 `registerMem` 和 `postXfer` 里都会调 `vramUpdateCtx(mem.addr, mem.devId, ...)`：
```c
int nixlLibfabricEngine::vramUpdateCtx(void *address, uint64_t devId, bool &restart_reqd) {
    ret = cudaCtx_->cudaUpdateCtxPtr(address, devId, was_updated);
    // ...
    restart_reqd = was_updated;  // 返回 true 时，外面重启 progress thread
}
```
其中 `cudaUpdateCtxPtr` 用 `cuPointerGetAttributes(..., CU_POINTER_ATTRIBUTE_CONTEXT, ...)` 拿到 buffer 对应的 CUDA context，若和缓存的不同就重绑。

**做什么**: 应对 "应用创建 primary context 比 libfabric backend 初始化晚" 的情况 — 第一次 registerMem 时如果 context 还没 ready，后续补绑。

**为什么**: 典型 PyTorch/Triton 场景：main process create engine → 之后才 `torch.cuda.init()` 创建 primary ctx。EFA HMEM registration 要求 ctx 已 current。NIXL 用 wa 兜底。
env `NIXL_DISABLE_CUDA_ADDR_WA` 可以关掉。

**UCCL-EP 对应位置**: 无 workaround。UCCL-EP 依赖调用者在调 UCCL init 之前已 init CUDA context（SGLang 里成立）。

**能否移植到 all-to-all**: **No**。UCCL-EP 集成 SGLang 时 context 创建顺序稳定，没有这个问题。也跟 all-to-all 性能无关。**跳过**。

---

### [NIXL 修改 8] — `FI_MR_VIRT_ADDR` / offset 双地址模式

**位置**: `src/utils/libfabric/libfabric_rail_manager.cpp:407-416, 487-497`
```c
if (rails_[rail_id]->getRailInfo()->domain_attr->mr_mode & FI_MR_VIRT_ADDR) {
    req->remote_addr = remote_target_addr;            // virt-addr 模式: 用 VA
} else {
    req->remote_addr = remote_target_addr - remote_registered_base;  // offset 模式
}
```

**做什么**: 根据 MR mode 是否带 `FI_MR_VIRT_ADDR` 自动切换 remote 地址的语义（VA 还是相对 offset）。EFA 的 efa-direct vs efa provider 在这里有差异。

**为什么**: `efa-direct` (SRD native) 使用 offset-based rkey (FI_MR_OFFSET semantics)；`efa` (with SHM) 用 virtual address。代码要跨两个 provider 跑。

**UCCL-EP 对应位置**: `src/rdma.cpp` 里 UCCL-EP 始终用 `iova`（`ibv_reg_mr_iova2` + dmabuf），硬编码 iova-addressed。**只支持一种模式**。

**能否移植到 all-to-all**: **Partial**。UCCL-EP 的 iova 模式依赖 GPU virtual address 恒定，DMA-BUF 支持好的平台 OK。但如果**将来要 port 到不支持 dmabuf 的 EFA 版本**（e.g. kernel 太老、peermem 未装），UCCL-EP 硬编码会 break。NIXL 这套双模式可作为**portability lever**。
对 MoE all-to-all 性能**无直接影响**。

**预期收益**: portability / debug，非 performance。**跳过作为性能 lever**。

---

### [NIXL 修改 9] — PCIe switch 带宽感知的 DRAM rail 限制 (`max_bw_per_dram_seg`)

**位置**: `src/utils/libfabric/libfabric_rail_manager.cpp:547-640` (`getDramRailLimit`) + topology `buildNumaSpeedMap()`

**做什么**: 注册 DRAM buffer 时，按 NUMA 节点的 PCIe switch 总带宽算 "最多用几条 rail"，避免 PCIe 上行链路被打爆。e.g. 一个 NUMA 下面是 PCIe Gen5 x16 总口 (64 GB/s)，下挂 4×100G EFA (50 GB/s)，算出 "顶多 3 条 rail" —— 第 4 条上去只会 PCIe 拥塞。

**UCCL-EP 对应位置**: `src/rdma.cpp:427-502` `safe_pcie_distance` + GPU→NIC 最近映射 —— 只做 "离 GPU 最近的 NIC"，**没做 PCIe 带宽上限计算**。

**能否移植到 all-to-all**: **No**（在 MoE 场景里不适用）。UCCL-EP 的 MoE dispatch 数据**只走 VRAM**（GPU buffer），不走 DRAM；也不存在 "多 rail 打爆 PCIe switch" 的问题（每个 GPU 绑 1 个 NIC）。这个 lever 是给 "CPU-side KV cache write-back via EFA" 用的。

**UCCL-EP 相关场景**: 如果**将来做 CPU-offload KV cache**（把 expert weight 或 KV history 放 CPU 内存经 EFA 传出），这个 lever 值得借鉴。短期不 apply。**跳过**。

---

### [NIXL 修改 10] — NUMA-aware rail selection policy (`nixlLibfabricNumaRailSelectionPolicy`)

**位置**: `src/utils/libfabric/libfabric_rail_manager.cpp:1302-1700`

**做什么**: 对 DRAM 原点 buffer，按 NUMA 节点距离选 rail：先本地 NUMA 的 rail，再相邻 NUMA（按 `numa_distance` 排序）。还带 switch-level round-robin (atomic `next_rail_index_` 原子轮转)。

**UCCL-EP 对应位置**: `src/rdma.cpp:467-471` 有 GPU NUMA ↔ NIC NUMA 粗匹配（`nic_numa == gpu_numa_node`），但**没有 NUMA-distance 排序 fallback**。只是 tie-break。

**能否移植到 all-to-all**: **No**（同上）— UCCL-EP MoE all-to-all 全 VRAM，不 apply。

**跳过**。

---

### [NIXL 修改 11] — Striping 阈值 (128KB) + round-robin vs multi-rail split

**位置**: `src/utils/libfabric/libfabric_common.h:42` + `libfabric_rail_manager.cpp:357-358, 386-540`
```c
#define NIXL_LIBFABRIC_DEFAULT_STRIPING_THRESHOLD (128 * 1024)
bool shouldUseStriping(size_t transfer_size) const {
    return transfer_size >= striping_threshold_;
}
```
小 message (<128KB) → 单 rail 轮转；大 message (≥128KB) → 所有 selected rail 切片并行。

**做什么**: 动态选择 "聚合带宽 vs 并发 small 消息" 策略。small message 用单 rail 避免切分开销；large message 拆成 n_rails 份并行发。

**UCCL-EP 对应位置**: 无。UCCL-EP 的 MoE dispatch message 每份是固定 `hidden_dim*sizeof(elem)*num_tokens`，跑在一个 NIC 上，不 split 到多 NIC。

**能否移植到 all-to-all**: **已被 "已知避开 multi-NIC LB" 规则排除**。Phase 1-16 明确 multi-NIC LB 在 UCCL-EP 架构里价值有限（GPU↔NIC 是 1:1 绑定）。**跳过**。

---

### [NIXL 修改 12] — `FI_MR_PROV_KEY` 自动 rkey 分配

**位置**: `src/utils/libfabric/libfabric_rail.cpp:430-433, 1301-1309`
```c
hints->domain_attr->mr_mode =
    FI_MR_LOCAL | FI_MR_HMEM | FI_MR_VIRT_ADDR | FI_MR_ALLOCATED | FI_MR_PROV_KEY;
hints->domain_attr->mr_key_size = 2;  // 2B rkey
```
让 provider 自己生成 rkey，避免用户空间管理 key collision。

**做什么**: rkey 由 provider 自选，NIXL 只管存。TCP/socket 等不支持 `FI_MR_PROV_KEY` 的 provider 回退成用 buffer addr 做 key。

**UCCL-EP 对应位置**: `src/rdma.cpp` 注册 MR 后直接用 `mr->rkey`，verbs API 语义等价于 `FI_MR_PROV_KEY`。不是新 lever。

**跳过**。

---

### [NIXL 修改 13] — Binary notification fragmentation 协议

**位置**: `src/utils/libfabric/libfabric_common.h:98-255` + `libfabric_backend.cpp:1446-1500`

**做什么**: 自定义 notification 协议：每个 notification 分片成 ≤8KB 的 fragment，每个 fragment 10B header + 10B metadata (仅 fragment 0) + payload。Receiver 侧 `pending_notifications_` map 做重组。

**UCCL-EP 对应位置**: UCCL-EP 不用 application-level notification，用 `IBV_WR_RDMA_WRITE_WITH_IMM` 的 imm data（4B）直接 encode [wr_id, signal bits]。两种架构设计不同。

**能否移植到 all-to-all**: **No**。UCCL-EP 的 MoE combine_signal 只需要单 u64 signal，不需要 variable-length message fragment。**跳过**。

---

### [NIXL 修改 14] — Recv pool 预 post + 自动再 post

**位置**: `src/utils/libfabric/libfabric_rail.cpp:593-614` (init 时预 post 1024 个 recv) + `923-948` (完成后立刻 alloc + post 新的)

**做什么**: 启动时预发 1024 个 recv WR，每次 recv 完成立即 allocate + post 新的 — "ring" 语义，维持接收窗口恒定。

**UCCL-EP 对应位置**: `src/proxy.cpp:507` `post_receive_buffer_for_imm` — UCCL-EP 走的是 `EFADV_QP_FLAGS_UNSOLICITED_WRITE_RECV` 模式，**不消费 recv WR**，所以**不需要 recv pool**。两种不同模式下的等价处理。

**能否移植到 all-to-all**: **No**（架构选择不同）。**跳过**。

---

## 3. 建议的 PR 候选（最多 5 条）

### 候选 A: SRD RNR-retry 配置（移植自 NIXL 修改 2）

- **改动位置**: `/home/ec2-user/workspace/uccl/ep/src/rdma.cpp:885-920` (`create_srd_qp_ex`)
- **借鉴自 NIXL**: `libfabric_rail.cpp:546-557`
- **具体改动**: 在创建 SRD QP 后调用 efadv 专用接口（或 rdma-core 的 `efadv_set_driver_features`/`EFADV_DEVICE_ATTR_CAPS_RNR_RETRY` 如果暴露）设置 RNR retry=7 infinite。**需先 grep rdma-core / libfabric efa prov 源码确认 EFA 下层 API 叫什么**（libfabric 的 `FI_OPT_EFA_RNR_RETRY` 底层是 `efa_rdm_ep_set_rnr_retry`）。
- **工期估算**: 2 天（1d 找到 verbs-level API + 1d 接入测试）。有风险：可能 rdma-core ibv API 不 expose，需要直接 ioctl 或 contribute patch 到 rdma-core。
- **风险**:
  1. 在 UCCL-EP 的 `UNSOLICITED_WRITE_RECV` 模式下，RNR 事件可能根本不触发（unsolicited 不需要 RQ），这个 lever 价值=0。
  2. verbs API 可能不暴露 — 需要切回 libfabric 或 fork rdma-core。
- **收益**:
  - **decode batch=1 scenario**: 如果实际触发过 RNR（要先装 CQE error log + `ibv_devx_qp_get_state` 检查），减少 p99 尖刺。**先装 instrumentation，看到 RNR 再做**。
  - **prefill batch=N scenario**: burst 场景更可能 RNR，改进可能更明显。但 unsolicited 模式下不应出现。
  - **遵循 `feedback_baseline_cross_hardware.md`**：**此条不能盲报数字；必须先 instrumentation 采证据再决定**。
- **结论**: P2 — **先做 RNR instrumentation (0.5 day)，证据充分再做这条**。

### 候选 B: Post-retry 遇 EAGAIN 自驱 drain（移植自 NIXL 修改 6）

- **改动位置**: `/home/ec2-user/workspace/uccl/ep/src/rdma.cpp` 所有 `ibv_post_send` 调用点 + proxy.cpp `post_gpu_command`
- **借鉴自 NIXL**: `libfabric_rail.cpp:1065-1096` EAGAIN retry loop
- **具体改动**: 把 UCCL-EP 里 post 失败 `assert(…)` 改成 "drain CQ 一次 + retry N 次，N=16"，不要直接 exit。
- **工期估算**: 1 天（2 小时改 + 半天写 unit test + 剩下压测）。
- **风险**: 低。纯鲁棒性改动。
- **收益**:
  - **decode batch=1**: 0（back-pressure 模型下本来不 EAGAIN）。
  - **prefill batch=N**: 0~小（极限 burst 下避免异常 exit，不提性能）。
  - **这是 rubustness lever 不是 performance lever**。
- **结论**: P3 — 可做但非性能优先。

### 候选 C: Active-QP 跳过 polling（部分移植自 NIXL 修改 3）

- **改动位置**: `/home/ec2-user/workspace/uccl/ep/src/proxy.cpp:500-543` `run_progress()` + `poll_cq_dual`
- **借鉴自 NIXL**: `libfabric_rail_manager.cpp:962-990` active rail set
- **具体改动**: 维护 `active_channels` 位图（per proxy），每次 `post_gpu_command` 给对应 channel +1 submitted，poll 完 inflight=0 时移出 active 集合。poll 时只遍历 active 集合。
- **工期估算**: 3 天。
- **风险**: 中等。UCCL-EP 的 `poll_cq_dual` 同时处理 ack/data/combine 三条路径，拆开后 idle 判定条件不平凡。
- **收益**:
  - **decode batch=1**: UCCL-EP proxy 已独占 CPU，跳过 idle channel 对总延迟 ≈0，因为 spin loop 本来就不限速。
  - **prefill batch=N**: **无**。
  - **是否降延迟**: 只有在 "CPU 不是独占，和 scheduler 抢" 的部署模式下才有意义。SGLang 通常独占 proxy core，这个 lever **基本无收益**。
- **结论**: P4 — **不推荐**，除非部署模式变化。

---

**总的 PR shortlist 排序** (满足 `feedback_claim_verification_discipline.md` 不夸大):
1. **Instrumentation first**: 先装 RNR event / `EAGAIN` count / CQE error 抓取 (0.5 day) — 没数据不做 A/B/C。
2. 如果 RNR 事件 >0.1% post: 做候选 A。
3. 候选 B、C 不推荐作为 performance PR — 降级为 robustness / future portability。

---

## 4. 不可借鉴 / 已覆盖的

| NIXL 修改 | 为什么不 apply |
|-----------|---------------|
| #1 Unsolicited write recv=false | UCCL-EP 架构相反（用 unsolicited）且已决策，不回退 |
| #4 FI_THREAD_COMPLETION | UCCL-EP 单线程独占 QP，等价语义已满足 |
| #5 CQ size 12288 + format DATA | 是 depth 参数不是专有 lever；UCCL-EP `ibv_create_cq_ex` 等价 |
| #7 CUDA addr workaround | UCCL-EP 通过 SGLang 调用链保证 ctx 早 init，不需要 |
| #8 FI_MR_VIRT_ADDR 双模式 | UCCL-EP 硬绑 dmabuf iova；port 不是 Stage 5 目标 |
| #9 PCIe switch BW-aware DRAM rail limit | UCCL-EP MoE 全 VRAM，不 apply |
| #10 NUMA-aware rail selection | 同上 |
| #11 Striping threshold (multi-NIC) | 已覆盖 "multi-NIC LB" — 1 GPU : 1 NIC 架构不需 |
| #12 FI_MR_PROV_KEY | verbs API 等价，非新 lever |
| #13 Binary notification fragmentation | UCCL-EP 用 imm 4B signal，不需要 app-level 协议 |
| #14 Recv pool 预 post | UCCL-EP 走 unsolicited，不消费 recv WR |

---

## 5. 残余 UNKNOWN

1. **NIXL 有 AWS benchmark 数据吗？** 读 README 和代码没看到任何 "在 p5en 实测 X GB/s" 的实际数字。NIXL 的 README.md 只声明 "validated on AWS EFA"。**需要翻 commit message / NVIDIA blog / Dynamo release notes 找 benchmark**。没有证据前，"NIXL 某优化带来 Y% 提升" 的 claim 都不能直接搬。

2. **FI_OPT_EFA_RNR_RETRY=7 在 UNSOLICITED_WRITE_RECV=true 模式下是否有效？** 这是候选 A 的关键前提。libfabric efa provider 源码层需要进一步 grep — 但 UCCL-EP 不走 libfabric，只能看 rdma-core 的 `efa_kern_*` / `efadv_*` 符号是否 expose RNR retry。**待查 rdma-core**。

3. **NIXL 的 "PCIe switch BW-aware DRAM rail limit" 是自创还是来自 AWS NCCL plugin？** hwloc upstream 和 AWS libfabric repo 可能早就有。**待查 aws-ofi-nccl 源码看 lineage**。

4. **UCCL-EP 当前是否实际观测到 `ibv_post_send` EAGAIN？** 没有 log aggregation，无从证实。**建议加一个 atomic counter 上报**，确认候选 B 是否有实际意义。

5. **NIXL 是否针对 EFA 用 `fi_inject` / `fi_writemsg` 的 FI_INJECT flag 做小消息零拷贝？** 快速扫没看到（grep 不到 `fi_inject` / `FI_INJECT`）。如果没做，这里反而是 **NIXL 自己的 gap**，不是我们能借鉴的。

---

## 附录：源码路径速查

**NIXL (clone 到 /tmp/nixl)**:
- Rail manager: `/tmp/nixl/src/utils/libfabric/libfabric_rail_manager.cpp`
- Rail impl: `/tmp/nixl/src/utils/libfabric/libfabric_rail.cpp`
- Topology: `/tmp/nixl/src/utils/libfabric/libfabric_topology.cpp`
- Engine: `/tmp/nixl/src/plugins/libfabric/libfabric_backend.cpp`
- Plugin README: `/tmp/nixl/src/plugins/libfabric/README.md`

**UCCL-EP (本地)**:
- RDMA init/QP: `/home/ec2-user/workspace/uccl/ep/src/rdma.cpp`
- Proxy progress: `/home/ec2-user/workspace/uccl/ep/src/proxy.cpp`
- Common: `/home/ec2-user/workspace/uccl/ep/src/common.cpp`
- Bindings: `/home/ec2-user/workspace/uccl/ep/src/uccl_ep.cc`

**Cross-ref (Phase 前述已覆盖的 lever)**:
- `docs/LEVER_VALIDATION_SUMMARY.md` — Phase 16 真实性核查
- `docs/FINAL_EXECUTION_CHECKLIST.md` — 最终 checklist
- `docs/EXPECTED_PERFORMANCE_GAINS.md` — 性能期望锚定
- `docs/SRD_PROTOCOL_PART2.md` — EFA SRD 协议 lever 排序
- `docs/ALLTOALL_DEEP_DIVE.md` — p5en 基线数字

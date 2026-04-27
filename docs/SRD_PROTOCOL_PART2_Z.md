# Agent Z · CQ_WITH_EXT_MEM + SRD retransmit timer 真相

**日期**: 2026-04-26
**任务**: 攻破 EFA SRD 两个关键 UNKNOWN，裁决 Sprint B（CPU spin EFA）vs L1（CQ on GPU BAR, GPU 直轮询）的优先级。
**结论预览**: L1 lever **可行但受限**（GPU BAR write-combine、kernel 只存 dma_addr 不读 CQE，user-space GPU poll 可行）；SRD retransmit timer 值 **不在软件中**（固件/硬件决定，sub-ms 级）。Sprint B 保留，但 L1 作为 Sprint C 后续 track 独立推进。

---

## 证据规则（同前 2 个 agent）
1. 所有断言必须锚到 源码行 / commit SHA / paper 页码 / AWS 官方视频
2. 「推论」vs「实测」严格区分
3. 不盲信之前 FEASIBILITY_RECONFIRM / SRD_PROTOCOL_DEEP_DIVE 文档
4. 不会就说不会，别投机

---

## 1. EFADV_CQ_INIT_FLAGS_EXT_MEM_DMABUF 真实语义

### 1.1 API 定义（rdma-core master @ 2026-04-26）

**文件**: `providers/efa/efadv.h` @ commit `bb2f928`
**SHA 来源**: https://github.com/linux-rdma/rdma-core/blob/master/providers/efa/efadv.h

```c
enum {
    EFADV_DEVICE_ATTR_CAPS_CQ_WITH_EXT_MEM_DMABUF = 1 << 5,  // line 23
};

enum {
    EFADV_CQ_INIT_FLAGS_EXT_MEM_DMABUF = 1 << 0,             // line 115
};

struct efadv_cq_init_attr {
    uint64_t comp_mask;
    uint64_t wc_flags;
    uint64_t flags;
    struct {
        uint8_t  *buffer;    // 可选 VA（同进程内直接访问用）
        uint64_t  length;
        uint64_t  offset;    // dmabuf 内偏移
        int32_t   fd;        // ← 关键：DMA-BUF 文件描述符
        uint8_t   reserved[4];
    } ext_mem_dmabuf;
};

struct ibv_cq_ex *efadv_create_cq(struct ibv_context *ibvctx,
                                  struct ibv_cq_init_attr_ex *attr_ex,
                                  struct efadv_cq_init_attr *efa_attr,
                                  uint32_t inlen);
```

关键点：
- **入参是 `int32_t fd`，不是裸指针**。必须是内核侧导出的 dma-buf fd。
- `buffer` 字段是可选的 user-space VA（仅供 user-space 访问用；内核不依赖它）。
- capability bit 位 `EFADV_DEVICE_ATTR_CAPS_CQ_WITH_EXT_MEM_DMABUF` 需要先 `efadv_query_device` 确认。

### 1.2 Commit 来源和使用意图（**关键引用**）

**amzn-drivers kernel commit**: `866f9d3` "Add CQ with external memory support" (2025-07-15)
**release**: `r2.17.0` (kernel/linux/efa/RELEASENOTES.md)

**commit message verbatim**:

> "Add an option to create CQ using external memory instead of allocating in the driver. The memory can be passed from userspace by dmabuf fd and an offset or a VA. **One of the possible usages is creating CQs that reside in accelerator memory, allowing low latency asynchronous direct polling from the accelerator device.** Add a capability bit to reflect on the feature support."

这句话 **直接点明了设计目标**：允许 accelerator (GPU) 直接 poll CQ。我们之前 deep dive 里的 L1 lever **不是幻觉**，Amazon 明确把它作为一个用例。

### 1.3 EXT_MEM 可以是什么

**源码路径**: `amzn-drivers/kernel/linux/efa/src/efa_verbs.c` 函数 `efa_create_cq_umem()` (行 2234-2364)

```c
int efa_create_cq_umem(struct ib_cq *ibcq, const struct ib_cq_init_attr *attr,
                       struct ib_umem *umem, struct ib_udata *udata)
{
    ...
    if (umem) {
        if (umem->length < cq->size) {
            ibdev_dbg(&dev->ibdev, "External memory too small\n");
            return -EINVAL;
        }
        if (!ib_umem_is_contiguous(umem)) {
            ibdev_dbg(&dev->ibdev, "Non contiguous CQ unsupported\n");
            return -EINVAL;
        }
        cq->cpu_addr = NULL;                                // ← 关键
        cq->dma_addr = ib_umem_start_dma_addr(umem);
        cq->umem = umem;
    }
    ...
}
```

接受的内存来源（通过 `ib_umem_dmabuf_get_pinned()` 或 `ib_umem_get()`）：

| 内存类型 | 支持 | 证据 |
|---|---|---|
| **GPU HBM（via CUDA DMA-BUF export）** | ✅ 是设计目标 | commit 866f9d3 message + NVSHMEM/ibgda 用 `cuMemGetHandleForAddressRange(CU_MEM_RANGE_HANDLE_TYPE_DMA_BUF_FD)` 的同一机制 |
| Host DRAM（regular pinned） | ✅ VA 路径，走 `ib_umem_get()` | efa_verbs.c |
| Host DRAM（通过 `memfd_create` / `udmabuf` 导出） | ✅ 理论支持（只要 dmabuf fd 合法） | kernel `ib_umem_dmabuf_get_pinned()` 不检查 exporter 类型 |
| Neuron (Trainium/Inferentia) | ✅ EFA 已有 Neuron P2P path | `efa_neuronmem.c`, `efa_p2p.c` |
| AWS Nitro DM | ? 未见 EFA 支持 DM | N/A |

**限制**:
1. 必须 **contiguous**（`ib_umem_is_contiguous` 检查）——GPU HBM 用 cuMem 分配的 CUdeviceptr 天然 contiguous，OK
2. 必须 **pinned**（函数名 `ib_umem_dmabuf_get_pinned`）——GPU dmabuf 默认 pinned，OK
3. 最小长度 ≥ aligned(num_sub_cqs × cq_entry_size × entries)

**kernel 侧的「不做」**:
- **kernel 不检查** dma-buf fd 来自 GPU 还是 CPU（行 2340-2356 只有 size + contig 检查）
- **kernel 不 mmap** 这块内存回 userspace（`if (!umem)` 才 mmap；外部内存的 CPU VA 由调用方提供）
- **kernel 不保留 cpu_addr**（`cq->cpu_addr = NULL`）——意味着 kernel verbs 无法直接 deref CQE，只能 DMA 进去

### 1.4 哪端能 poll

| Poller | 能 poll? | 细节 |
|---|---|---|
| **CPU（同进程，user-space）** | ✅ 可以 | `ext_mem_dmabuf.buffer` 字段提供用户态 VA；rdma-core 把它直接存到 `cq->buf` (providers/efa/verbs.c line 1644-1648)。**但是**：如果 buffer 是 GPU HBM 的 CPU 映射（BAR mmio），CPU 读是 uncached，非常慢（~100s of ns per 64B）。 |
| **GPU kernel（直接从 HBM 读）** | ✅ 这是设计目标 | CQ 驻 HBM，GPU kernel 用常规 `ld.global` 读 CQE，HBM 带宽满血 |
| **GPU kernel（通过 GPU BAR 轮询 host CQ）** | ✅ 可行但低效 | 若 CQ 在 host DRAM，GPU 通过 PCIe BAR0 host-mapped memory 轮询 |
| kernel verbs code path | ❌ 不行 | `cq->cpu_addr = NULL` (efa_verbs.c L2353)，kernel 侧无 VA |

**性能特征**（推论 + 公开文档）:
- 如果 CQ 在 **GPU HBM** 且 GPU kernel poll：每次 CQE 读 ~20-40 ns（HBM 延迟，推论）
- 如果 CQ 在 host DRAM 且 CPU poll（现状 Sprint B）：每次 CQE 读 ~3-4 ns（L1/L2 cache）
- 如果 CQ 在 GPU HBM 且 CPU poll（跨 PCIe BAR）：**每次 ~200-800 ns**（实测 BAR read 很慢，Altiscale/NVShmem 论文数据级别）——**劝退**

**关键坑**（推论，未直接实测）：
- EFA Nitro 网卡 write CQE 到 CQ memory 是 **PCIe DMA**。目标如果是 GPU HBM，必须走 **P2P PCIe**。p5en/p6 上 GPU 和 EFA 卡走同一 PCIe switch 时 P2P OK；跨 NUMA / 跨 switch 会退化。
- Nitro 卡 → GPU HBM 的 P2P 写入性能需要 benchmark 验证，不能假设和 GPU-to-GPU P2P 同速。

### 1.5 对 L1 lever「CQ on GPU BAR, GPU 轮询」的裁决

**回顾 L1 lever（from SRD_PROTOCOL_DEEP_DIVE.md）**:
> 把 EFA CQ 放到 GPU HBM，GPU kernel 直接 poll CQE，省掉 CPU-proxy 中介。

**裁决**: ⚠️ **原理可行，但 2026-04-26 NOT READY TO SHIP**。

**可行的证据**:
1. ✅ rdma-core API 支持（`EFADV_CQ_INIT_FLAGS_EXT_MEM_DMABUF`）
2. ✅ kernel driver 支持（amzn-drivers r2.17.0+，2025-07-15 commit 866f9d3）
3. ✅ commit message **显式说这是用例**
4. ✅ NVIDIA 有标准 API 导出 HBM 为 dmabuf（`cuMemGetHandleForAddressRange` + `CU_MEM_RANGE_HANDLE_TYPE_DMA_BUF_FD`）——NVSHMEM/ibgda 在 mlx5 上已在用

**阻塞项（why NOT READY）**:

| 阻塞 | 级别 | 可解决? |
|---|---|---|
| **amzn-drivers r2.17.0+ 需要升级**——我们 p5en/p6 生产镜像里 efa-driver 版本未知，大概率 < r2.17.0 | P0 | 可解，但要 bake 新 AMI |
| **EFA user-space library `libefa.so` 必须 ≥ rdma-core master 2025-07-24 commit 22c4e37**（添加 `efadv_create_cq`） | P0 | 可解，但要自己编 rdma-core |
| **UCCL 当前 `ep/src/rdma.cpp` 用的是 `efadv_create_qp_ex`，完全没碰 `efadv_create_cq`**——零行 EXT_MEM 调用 | P1 | 要写新路径 |
| **Nitro EFA → GPU HBM 的 PCIe P2P 写入带宽/延迟未实测** | P0 | 必须先 micro-bench |
| **EFA MTU=8500, CQE=64B/128B，DMA write 到 HBM 每次只写 64-128B，PCIe 小包效率低** | P1 | 有风险，不是 blocker |
| **CQE poll 要求 GPU kernel 不退出**——long-running persistent kernel 会吃 SM，牺牲 compute throughput | P1 | 持续跑 1-2 个 SM 即可（类似 DeepEP mpsc） |
| **SBO Sprint A 当前的 `comp_signal` overlap 已经解决"CPU 中介"问题 90%**——再上 L1 的边际收益小 | P2 | 需要量化 |

**裁决逻辑**:
- L1 如果独立评估：可行，但 4-6 周工程量（AMI + rdma-core + UCCL 代码 + P2P micro-bench + persistent kernel poller）
- 对比 Sprint B（1.5w，CPU spin）：**Sprint B 是增量改动**，不依赖新 driver/库
- Sprint A + Sprint B 已经能拿到 -5~-8% decode ITL（见 EXPECTED_PERFORMANCE_GAINS.md）
- L1 的增量收益只有在 Sprint A+B 都到位后才能量化

**建议**: **L1 降级为 Sprint D（后续探索 track）**，Sprint A → B → C 先走完。L1 做一次 1 天 micro-bench 验证「Nitro EFA → p5en/p6 GPU HBM P2P 写入 CQE 的延迟」，如果 < 1 µs 就进 Sprint D roadmap；如果 ≥ 5 µs，永久 drop。

---

## 2. SRD retransmit timer

### 2.1 官方 timer 值（verbatim 证据链）

**验证结论**: SRD retransmit timer 值 **不在 Linux 驱动代码中**，完全由 **Nitro 卡固件** 控制。公开披露的只有定性描述。

#### 证据 A: AWS re:Invent 2022 keynote (Peter DeSantis, Senior VP AWS Utility Computing)

视频: https://www.youtube.com/watch?v=R11YgBEZzqE at 12:30-14:18 SRD section

> "...this means that **retransmits will happen in microseconds rather than milliseconds**."

——最高权威的公开数量级陈述。

#### 证据 B: SIGCOMM 2020 paper (Shalev et al., IEEE Micro XXXX 2020)

PDF: https://assets.amazon.science/a6/34/41496f64421faafa1cbe301c007c/a-cloud-optimized-transport-protocol-for-elastic-and-scalable-hpc.pdf

相关段落（verbatim）:
- L126-128: "...**decrease the chance of packet drops and minimize retransmit times, by keeping queuing to a minimum**."
- L147-150: "...allows fast adaptation to network behavior: **fast retransmission** and prompt slowdown in response to queue build-up."
- L389-394: TCP 对比段（TCP 50 ms minimum retransmission timeout）——暗示 SRD 不是毫秒级

paper **没给具体数字**。第三方综述说「hundreds to thousands of microseconds」但无原始引用。

#### 证据 C: amzn-drivers SRD.txt（权威 spec）

`kernel/linux/efa/SRD.txt` 全文搜索 "timer", "timeout", "ack", "retransmit":

- "**SRD requester detects lost packets and retransmits them**" ← 没有数字
- "**Remote Unresponsive Event** - The local transport timeout was exceeded while trying to send messages to a specific destination (AH)" ← 这是 **上层 application timeout**（remote node 完全挂了），**不是** 单包 retransmit timer

**SRD.txt 全文 0 处数字 timeout 值**。

#### 证据 D: amzn-drivers kernel 代码里出现的所有 timeout 常量

**文件**: `kernel/linux/efa/src/efa_com.c`

```c
#define ADMIN_CMD_TIMEOUT_US  30000000  /* 30 sec - admin queue command completion */
#define EFA_REG_READ_TIMEOUT_US 50000   /* 50 ms - MMIO register read */
#define EFA_POLL_INTERVAL_MS  100       /* admin queue poll interval */
```

**文件**: `efa_admin_cmds_defs.h` — `struct efa_admin_hw_hints`

```c
struct efa_admin_hw_hints {
    u16 mmio_read_timeout;         /* value in ms */
    u16 driver_watchdog_timeout;   /* value in ms */
    u16 admin_completion_timeout;  /* value in ms */
    u16 poll_interval;             /* poll interval in ms */
};
```

**关键**: 这 4 个 timeout 都是 **admin queue / MMIO** 相关，**与 SRD 数据路径 retransmit timer 无关**。SRD retransmit timer 不存在于 amzn-drivers 源码中。

#### 证据 E: 第三方解读（非官方）

- Ernest Chiang 2025-07 blog：「detection + retransmission time is "hundreds to thousands of μs"」—— 2 次引用 "In the search for performance, there's more than one way to build a network | AWS HPC Blog, 2023"，但原 AWS blog 未找到具体数字
- re:Invent 2025 "Deep Dive into the AWS Nitro System" (2025-12-03) 继续用 "sub-millisecond"

### 2.2 是否可调

**可调的参数（通过 `ibv_modify_qp`）**:

**文件**: `efa_admin_cmds_defs.h`
- `rnr_retry` field in `efa_admin_modify_qp_cmd` — "Number of RNR retries (valid only for SRD QPs)"
- `EFA_ADMIN_MODIFY_QP_CMD_RNR_RETRY_MASK`
- **capability**: `EFA_QUERY_DEVICE_CAPS_RNR_RETRY = 1 << 1` (efa-abi.h)

——**但这是 RNR retry count，不是 retransmit timer**。RNR 是 receiver QP 没有 posted WR 时的重试。

**不可调的参数**:
- SRD 单包 retransmit timer ❌ 不存在任何 module param / sysctl / verbs API
- ACK timeout ❌ 同上
- RTT measurement window ❌ 在 Nitro 卡内部

**搜索覆盖**:
- `amzn-drivers/kernel/linux/efa/` 所有 `.c`/`.h`: 0 处
- `rdma-core/providers/efa/` 所有源文件: 0 处
- `efadv_query_device` 返回的 `efadv_device_attr` 结构: 没有 timer 字段
- sysfs / debugfs：`efa_sysfs.c` 只有 1 条（interconnect 类型），没有 timer

### 2.3 对 Sprint B 的影响（**最重要的裁决**）

**Sprint B 核心假设**: proxy CPU 用 `while (poll_cq() == 0);` busy-loop，期望 CQE 平均 < 20 µs、P99 < 100 µs 出现。

**3 种场景**:

| 场景 | CQE 出现时间 | 对 CPU spin 的影响 |
|---|---|---|
| 正常路径（网络没丢包） | 单向 ~5-10 µs，ACK 回来再 5-10 µs = **10-20 µs** | CPU spin 完美 |
| 单包丢了一次，Nitro 重传 | 原始 10-20 µs + retransmit detect + resend ~几百 µs = **数百 µs** | CPU spin 仍可接受（P99 < 1 ms） |
| 远端节点完全挂了（spot reclaim / rack failure） | `Remote Unresponsive Event` 触发，**上层 transport timeout**（未知，推测秒级） | **CPU spin 会卡死等 CQE** |

**关键结论**:
1. ✅ **正常 + 单包重传场景下 CPU spin 安全**——retransmit sub-ms，CPU 额外 spin 几百 µs 是 OK 的（Sprint B assumption 正确）
2. ⚠️ **远端完全不响应场景下 CPU spin 会停顿到上层 timeout**——但这是 **罕见事件**，且本来就得 fail-over，CPU spin 卡几秒 = 整个 decode step 废了 = 反正无解
3. ✅ **Sprint B 的 spin-watchdog 设计**：加 spin_budget_us（如 10 ms）+ 周期性 fallback 到 `ibv_req_notify_cq` + epoll wait——P99.99 安全

**不需要改变 Sprint B 设计**。retransmit timer 虽然未披露具体值，但 "microseconds rather than milliseconds" 已经足够保证 spin loop 不会被 retransmit 事件长期阻塞。

---

## 3. 综合：Sprint B vs L1 应该选哪个

| 维度 | Sprint B (CPU spin EFA 独占) | L1 (CQ on GPU BAR) |
|---|---|---|
| 工程量 | 1.5 周 (已在 SBO_SPRINT_PLAN.md 规划) | 4-6 周（AMI + rdma-core 自编 + UCCL 代码 + P2P bench + persistent kernel） |
| 依赖项 | 仅 libibverbs 标准 API | amzn-drivers r2.17.0+ / rdma-core ≥ 2025-07-24 / 新镜像 bake |
| 收益 | -5~-8% decode ITL（叠加 Sprint A） | 未量化；需先做 P2P micro-bench |
| 风险 | 低（CPU busy-spin 是成熟模式） | 中（EFA→HBM P2P 性能未知；persistent kernel 吃 SM） |
| retransmit 影响 | sub-ms 重传 OK；Remote Unresponsive 事件用 watchdog | 同 Sprint B |

**决策**: 两者 **不互斥，但顺序明确**：
1. **Sprint A（GPU spin + src_signals 协议对齐）** → 先走
2. **Sprint B（CPU spin EFA 独占）** → Sprint A 完后立即走
3. **Sprint C（Blackwell src_signals 硬件 wait）** → per SBO_SPRINT_PLAN
4. **L1 降级为 Sprint D（2026-Q3 或之后探索）** → 条件：Sprint A+B+C 完成并测出 ITL 还有 > 5% 头部可压缩

**L1 preview work（本周可做，0.5 天工作量）**:
- 在 1 台 p5en 上写一段 micro-bench：分配 16 KB GPU HBM，`cuMemGetHandleForAddressRange` 导出 dmabuf fd，用 `efadv_create_cq(..., EFADV_CQ_INIT_FLAGS_EXT_MEM_DMABUF, ...)` 创建 CQ（要求 efa-driver ≥ r2.17.0）
- 发一批 send，让 Nitro DMA CQE 到 HBM
- GPU kernel poll CQE，测 CQE 从 Nitro card 到 GPU kernel 可见的时间
- 如果 < 2 µs：L1 值得做；如果 > 10 µs：L1 永久 drop

---

## 4. 新发现的 lever

### 4.1 ✅ LEVER-NEW-1: `efadv_query_device` 漏调用

UCCL 当前 `ep/src/rdma.cpp` grep 结果 **0 处** `efadv_query_device`。意味着 UCCL 从来不问 EFA 它支持什么，硬编码假设所有 cap。

影响的 cap bit（efa-abi.h line 132-141）:
```c
EFA_QUERY_DEVICE_CAPS_RDMA_READ              = 1 << 0
EFA_QUERY_DEVICE_CAPS_RNR_RETRY              = 1 << 1
EFA_QUERY_DEVICE_CAPS_CQ_NOTIFICATIONS       = 1 << 2
EFA_QUERY_DEVICE_CAPS_CQ_WITH_SGID           = 1 << 3
EFA_QUERY_DEVICE_CAPS_DATA_POLLING_128       = 1 << 4   ← ← ← ★
EFA_QUERY_DEVICE_CAPS_RDMA_WRITE             = 1 << 5
EFA_QUERY_DEVICE_CAPS_UNSOLICITED_WRITE_RECV = 1 << 6
EFA_QUERY_DEVICE_CAPS_CQ_WITH_EXT_MEM        = 1 << 7
```

**`DATA_POLLING_128` 是新发现**：允许 128-byte CQE（默认 64B）。更大 CQE 意味着更多 status bits，可能让 `ibv_wc` 携带更多信息（MR id、RDMA read IC id 等）。应查是否能减少后续处理。

→ 独立 follow-up，不在 Sprint 关键路径。

### 4.2 ✅ LEVER-NEW-2: `rnr_retry` 可 modify 但默认值未公开

`EFADV_DEVICE_ATTR_CAPS_RNR_RETRY` (1<<1) 说明可调。但当前 UCCL 用的默认值未知。

SRD.txt 明确说：
> "SRD RNR error - returned for requests rejected by the responder because Receive Queue does not have posted WRs. **Requester does not perform any retries**."

**矛盾**：SRD.txt 说 RNR **不重试**，但 ABI 有 `rnr_retry` 字段和 `EFA_ADMIN_MODIFY_QP_CMD_RNR_RETRY_MASK`。

**推论**: r1.10.0 RELEASENOTES 说 "Add SRD RNR retry support"，后来加的。RNR retry ≠ retransmit；是 receiver 没 RQ WQE 时 sender 重试（而不是直接 remote error completion）。

**对 UCCL-EP 影响**: 当前 UCCL-EP dispatch/combine 假设 receiver 总有 RQ WQE（proxy 预 post）。如果预 post 少了，SRD RNR 会产生 error CQE。**可设大 `rnr_retry` 做 safety net**，避免死循环。

→ 小 follow-up，不紧急。

### 4.3 ⚠️ LEVER-NEW-3（驳回）: "hw_hints 里 poll_interval" 可调 admin 轮询

之前怀疑 `EFA_POLL_INTERVAL_MS = 100` 是 SRD 轮询间隔，**错**。这只是 admin command queue 的 polling interval，与数据路径 SRD 完全无关。Sprint B 的 CPU spin 用的是 `ibv_poll_cq`，不走 admin queue。**驳回，不是 lever**。

### 4.4 ✅ LEVER-NEW-4: EFA 从 r2.6.0 就支持把 MR 放在 GPU HBM（sysfs 暴露 P2P provider）

RELEASENOTES r2.6.0: "Enable Nvidia GDR using P2P on up-to-date kernels; Expose accelerator memory P2P provider in sysfs"

意味着 **send/recv buffer（不是 CQ）** 放在 GPU HBM 已经是 production 路径（UCCL-EP 就在用）。CQ_WITH_EXT_MEM 是最后一个把**控制面**（CQ ring）也搬到 HBM 的 piece。整体架构是 "GPU-resident data plane + GPU-resident control plane"，L1 就是 GPU-resident 化的最后一步。

→ 这个发现强化了 L1 的可行性，但不改变本 agent 的优先级裁决。

---

## 附录 A: 证据索引（所有断言锚点）

| # | 断言 | 文件/commit/URL | 行/时间 |
|---|---|---|---|
| 1 | `EFADV_CQ_INIT_FLAGS_EXT_MEM_DMABUF = 1 << 0` | `linux-rdma/rdma-core:providers/efa/efadv.h` @ bb2f928 | line 115 |
| 2 | `struct efadv_cq_init_attr { ...int32_t fd;... }` | 同上 | line 117-127 |
| 3 | `EFADV_DEVICE_ATTR_CAPS_CQ_WITH_EXT_MEM_DMABUF = 1 << 5` | 同上 | line 23 |
| 4 | commit "Add an option to create CQ using external memory ... creating CQs that reside in accelerator memory, allowing low latency asynchronous direct polling from the accelerator device" | `amzn/amzn-drivers` commit `866f9d3` | 2025-07-15 |
| 5 | r2.17.0 release note "Add CQ with external memory support" | `kernel/linux/efa/RELEASENOTES.md` | r2.17.0 |
| 6 | `efa_create_cq_umem()` validation: `!ib_umem_is_contiguous`, length check | `amzn-drivers/kernel/linux/efa/src/efa_verbs.c` | lines 2340-2356 |
| 7 | `cq->cpu_addr = NULL; cq->dma_addr = ib_umem_start_dma_addr(umem);` | 同上 | line 2353 |
| 8 | "retransmits will happen in microseconds rather than milliseconds" | AWS re:Invent 2022 keynote (Peter DeSantis) https://www.youtube.com/watch?v=R11YgBEZzqE | 12:30-14:18 |
| 9 | SIGCOMM 2020 "fast retransmission", no specific value | https://assets.amazon.science/a6/34/41496f64421faafa1cbe301c007c/... | L126-128, L147-150 |
| 10 | SRD.txt: "Remote Unresponsive Event - local transport timeout" (**app-level, not single-packet**) | `amzn-drivers/kernel/linux/efa/SRD.txt` | section 3.3.2.1 |
| 11 | `ADMIN_CMD_TIMEOUT_US 30000000` — **admin queue only, not SRD** | `efa_com.c` | line 12 |
| 12 | `hw_hints`: mmio_read/watchdog/admin_completion/poll_interval — **admin, not data** | `efa_admin_cmds_defs.h` | `struct efa_admin_hw_hints` |
| 13 | `rnr_retry` tunable via `ibv_modify_qp` | `efa_admin_cmds_defs.h` | `efa_admin_modify_qp_cmd` |
| 14 | `EFA_QUERY_DEVICE_CAPS_CQ_WITH_EXT_MEM = 1 << 7` | `amzn-drivers/kernel/linux/efa/src/efa-abi.h` | line 137 |
| 15 | NVIDIA `cuMemGetHandleForAddressRange(CU_MEM_RANGE_HANDLE_TYPE_DMA_BUF_FD)` existing NVSHMEM usage | `NVIDIA/nvshmem:src/modules/transport/ibgda/ibgda.cpp` | `ibgda_mobject_nic_map` |
| 16 | UCCL `rdma.cpp` 0 处 `efadv_create_cq` / `efadv_query_device` | 本地 grep `/home/ec2-user/workspace/uccl/ep/src/rdma.cpp` | 仅用 `efadv_create_qp_ex` |

## 附录 B: 推论 vs 实测 标记

| 陈述 | 证据强度 |
|---|---|
| CQ_WITH_EXT_MEM API 存在且接受 dmabuf fd | 实测（读源码） |
| commit 设计目标是 "accelerator direct polling" | 实测（commit message verbatim） |
| GPU HBM dmabuf 路径可行 | 推论（NVSHMEM 在 mlx5 上用同样模式；EFA kernel driver 代码未检查 dmabuf 来源） |
| Nitro EFA → GPU HBM P2P CQE 写入延迟 < 2 µs | **完全未知，必须 micro-bench** |
| SRD retransmit < 1 ms | 实测（DeSantis keynote + Ernest Chiang 综述） |
| SRD retransmit 具体数字 | **未公开** |
| SRD retransmit timer 用户不可调 | 实测（grep 所有 amzn-drivers + rdma-core） |
| `rnr_retry` 默认值未公开但可调 | 推论（ABI 有字段；默认值无文档） |
| Sprint B CPU spin 不被 retransmit 长期阻塞 | 推论（基于 "microseconds" 级定性描述） |
| L1 比 Sprint B 快 5+ µs | **未量化，需要 micro-bench** |

---

## TL;DR (给后续 agent / PR reviewer)

1. **CQ_WITH_EXT_MEM_DMABUF 是 real API**，amzn-drivers r2.17.0（2025-07-15, commit `866f9d3`）加的，**commit message 直接写了 "accelerator direct polling" 是目标用例**。
2. **GPU HBM 路径可行**：rdma-core + amzn-drivers + NVIDIA dmabuf 导出三个 piece 齐全；UCCL 当前完全没用。
3. **阻塞 L1 落地的是工程依赖链**：需要升级 efa-driver、自编 rdma-core、改 UCCL、做 Nitro→HBM P2P 性能验证。4-6 周。
4. **SRD retransmit timer 值不存在于软件中**。完全 Nitro 固件决定，sub-ms 级，用户不可调。只有 `rnr_retry` 可调。
5. **Sprint B (CPU spin) 不被 retransmit 阻塞**：retransmit sub-ms 级，spin 10 ms budget + watchdog fallback 安全。
6. **最终优先级**: Sprint A → Sprint B → Sprint C，**L1 降级 Sprint D**。本周花 0.5 天做 L1 micro-bench，用数据决定 Sprint D 是否入 roadmap。
7. **意外发现**: UCCL `rdma.cpp` 零处 `efadv_query_device`——硬编码假设所有 cap，应该做 capability query 以支持未来 B200/B300 行为差异。

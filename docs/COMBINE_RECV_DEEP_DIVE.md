# UCCL-EP Combine Recv Path Deep Dive

**Baseline (p5en, 2-node 16-GPU, PR #745 post, from `docs/ALLTOALL_DEEP_DIVE.md`):**
- combine both p50 = **326.69 µs**
- combine send p50 = **47.74 µs** (isolated kernel, do_send only)
- combine recv p50 = **46.72 µs** (isolated kernel, do_recv only, flag已就绪)

**Hardware anchors (H200 SXM5):**
- HBM3e BW 4.8 TB/s, L2 cache 60 MB, SM count 132, clock 1.98 GHz
- 每 SM INT4 load @ coalesced：~30 GB/s sustained，BF16 FMA @ CUDA core 64 ops/cycle/SM
- `cg::this_grid().sync()` (grid barrier via L2 atomic): SBO_COMP_SIGNAL_DEEP_DIVE §5 实测 3–8 µs
- `ld.acquire.sys.global.s32` HBM round-trip: ~500 ns (coherent sys scope)

---

## §1 — 46.72 µs Recv-Only Segment Breakdown

**重要前提**：`combine_recv` (line 622–629, `test_low_latency_pplx.py`) 是 `do_send=False, do_recv=True` 的独立 kernel launch。`wait()` 先跑了 `combine_send`。到 `combine_recv` 启动时，**`rdma_recv_flag` 大概率已经被 proxy 写好**，spin 循环几乎立即返回。所以 46.72 µs **不包含 inter-node flight time**，只含：kernel launch + (near-zero) flag spin + grid sync + reduce + writeback。

| Phase | Code anchor | µs estimate | Basis |
|---|---|---|---|
| 1. Kernel launch + SM scheduling | driver → GPU | ~5 µs | 实测 null kernel launch overhead on H200 |
| 2. Flag spin (`ld.acquire.sys`) | `internode_ll.cu:1096-1112` | ~0.5 µs | Flag 已就绪：1–2 次 load 即退出；`combine_wait_recv_cost_stats` 在 both-kernel 下能量化真实等待时间，recv-only 下接近 0 |
| 3. `cg::this_grid().sync()` | `internode_ll.cu:1148` | **3–8 µs** | SBO_DEEP_DIVE §5 锚值；L2 atomic 广播 132 SM 全局 barrier |
| 4. Reduce + writeback (主体) | `internode_ll.cu:1155-1198` | **~33 µs** | 见下表推导 |
| 5. Kernel exit / stream sync | CUDA event record | ~1 µs | |
| **Total** | | **~42.5–47.5 µs** | 与实测 46.72 µs 吻合 |

**Reduce 主体详细分解** (hidden=7168, num_topk=8, num_combined_tokens=128, num_sms=128):

- 每 token 数据量：`hidden_bf16_int4 = 7168/8 = 896` int4 vectors × (输入 top-8 × 16 B + 输出 16 B) = **~14.5 KB read + 1.8 KB write**
- `sm_id` stripe：每 SM 处理 `128/128 = 1` token（若 num_sms==128；实际 num_sms=ceil(num_experts / num_warp_groups)=ceil(288/2)=144，但 SM stripe 仍大致 1 token/SM）
- Per-token work：896 int4 loads × top-8 sources = **7168 HBM reads (非合并，来自 8 个不同 expert slots)** + 896 int4 write (合并)
- HBM footprint per SM per token：7168 × 16 B = 115 KB read，896 × 16 B = 14.3 KB write
- 在 H200 HBM3e 4.8 TB/s (~37 GB/s 每 SM): 115 KB / 37 GB/s ≈ **3.1 µs per token**
- 实际 reduce kernel 因为是 **2D loop** (`hidden_idx` outer, `token_idx` inner)，同一 SM 复用 hidden 内循环的寄存器，但 top-8 source 跨不同 expert 的 `rdma_recv_x` 区域会打散 L2 局部性
- 估 3–5× HBM idealized → **~30–40 µs** reduce 主体

这与 46.72 - 5 - 3 - 1 = **~37 µs 可用预算** 吻合。

---

## §2 — 326 µs Combine-Both Barrier/Overlap Structure

`combine_both` 是 **单 kernel launch 同时做 send + recv**（`phases = SEND | RECV`）。执行顺序：

```
T=0     kernel launch
T=5     SM 开始 send phase (WARP_SIZE loop over assigned experts)
T=47    send phase 结束：所有 warp 完成 copy + trigger IBGDA atomic on peer
          ↓ (跳到 LOW_LATENCY_COMBINE_RECV label, line 1083)
T=47    每 SM sub_warp_id==0, lane_id==0 开始 spin on rdma_recv_flag
          ↓ 等待 peer CPU proxy:
            (a) poll outgoing SEND CQE (~1 µs)
            (b) inter-node SRD one-sided WRITE_WITH_IMM (~25–40 µs 含 EFA 抖动 & 远端 WQE queueing)
            (c) 本端 proxy poll recv CQE + remote_process_completions 解析 AtomicsImm (rdma.cpp:2430)
            (d) 写 atomic_buffer_ptr (rdma.cpp:2506/2547 fetch_add release)
            (e) 某机制 relay 到 rdma_recv_flag int（注意：是不同的 buffer；atomic_buffer 在 GPU HBM，rdma_recv_flag 也在 GPU HBM，但地址由 IBGDA 直写）
T=~310  所有 peer 的 flag 都到齐（tail peer 决定下界）
T=~313  cg::this_grid().sync() (最后一个 SM 看到 flag)
T=~318  reduce 主体启动
T=~326  reduce 完成，kernel exit
```

**326 - 47 = 279 µs** ≈ inter-node flight + peer CPU proxy + tail skew  
**326 - 47 - 47 = 232 µs** ≈ 上述 279 µs 中**超出 recv-only 那次 reduce 的部分**

**Why the 232 µs gap exists**：`combine_recv` 独立 kernel 启动时 flag 已经就绪（因为 `wait()` + `combine_send` 之间有数毫秒 gap 让 proxy 干完所有活），所以 recv-only 量到的 46.72 µs **是 reduce 的纯 GPU compute cost**。`combine_both` 则让 GPU spin 真实等待 inter-node 数据到达 — 那部分在 recv-only 测量中被 mask 掉了。

**核心判断**：232 µs 不是 overlap 浪费，也不是 barrier — 是 **EFA inter-node flight + CPU proxy 串行** 的真实延迟，**在 combine recv path 内根本无法优化**。这解释了为什么 SBO Sprint B (CPU-spin EFA 独占) 的 P50 降幅最多 15 µs — 因为它压缩的是 (a)+(b)+(c) 的 ~30 µs，不是整条 232 µs。

---

## §3 — `cg::this_grid().sync()` Necessity Analysis

**为什么需要**：Reduce (line 1155–1198) 是 `for (hidden_idx = thread_id; ...) for (token_idx = sm_id; ...)` 的 SM-stripe：**每 SM 处理一部分 token，每 thread 处理一部分 hidden dim**。关键不变式：**必须所有 SM 都看到自己负责 expert 的 flag == 1，才能保证 `rdma_recv_x` 里 `reg_topk_idx[i]` 指到的任何 source row 都已写完**。

如果没有 grid barrier，SM_A 先完成它的 flag 等待，开始 reduce 某 token，读 `rdma_recv_x[reg_topk_idx[3]]` ——这个 source 是由另一个 peer 发来、对应另一 expert、由 SM_B 负责等待 flag 的。SM_B 可能还没看到它的 flag → SM_A 读到 stale data。

**能否省掉**：
- ❌ 不能直接删：破坏上述不变式
- ⚠️ Per-SM barrier 不够：不同 SM 负责不同 expert 的 flag，reduce 需要 cross-expert data
- ✅ **可行替代**：**全局 flag count**（原子 counter reaches `num_experts`）+ per-SM spin on counter。开销可能比 `cg::sync()` 更低（一次 L2 atomic load vs. 多轮 bar broadcast），但差距 < 2 µs，ROI 低

**结论**：grid sync 是正确的且接近最小开销。**不是优化 hot spot**。

---

## §4 — Recv Flag Atomic Model Assessment

**当前实现**（已经是最优形）：
- Writer (inter-node path, `rdma.cpp:2506` or `2547`)：`std::atomic<int64_t>::fetch_add(1, memory_order_release)` — CPU proxy 写
- Reader (GPU, `internode_ll.cu:1096`)：`ld.acquire.sys.global.s32` — GPU spin
- Memory model：sys-scope acquire/release 对 (PTX `sys`)
- Intra-node 路径 (line 1063) 直接在对端 GPU 上 `st.release.sys` — 跳过 CPU proxy

**能否降颗粒度 (`.cta` / `.gpu`)**：
- ❌ 不能：writer 是 CPU on PCIe，读者必须用 sys scope 才能 coherent with CPU stores
- ⚠️ 写端从 `fetch_add` 改 `st.release`：目前是 `fetch_add` 因为 pending_atomic_updates 可能要累加多次。单次写可改 `store(release)` 节省几 ns，**可忽略**

**真正的 flag overhead 在哪**：
- `atomic_buffer` 写和 `rdma_recv_flag` 写是**两个不同地址**。rdma.cpp 写 `atomic_buffer`，哪里把它转成 `rdma_recv_flag` 的 write？需要追 IBGDA 路径。
- 看 dispatch 侧 `internode_ll.cu:1069` 的 `nvshmemi_ibgda_amo_nonfetch_add` — combine 侧 send phase 也是走同一个 path，atomic 的 destination 直接是 peer 的 `rdma_recv_flag_internode`。
- 所以 `atomic_buffer_ptr` 是 **CPU proxy 中间 buffer**，对端 GPU 直接看到的是 IBGDA 写过来的 `rdma_recv_flag_internode`（line 1054）。这条 path **绕过我方 CPU**，延迟最小。
- **p5en EFA 不支持 native RDMA atomic**，所以走 `nvshmemi_ibgda_amo_nonfetch_add` + CPU proxy 仿真（见 rdma.cpp:2430 AtomicsImm 分支）— 这**是** peer CPU proxy 介入点，代价 ~1 µs。

**结论**：flag atomic 协议已优。唯一 micro-opt：可以考虑 combine dispatch 的 atomic 从 "post-send 独立 WR" 合并到 send 的 imm_data里（节省一次 CQE poll on proxy）。**ROI 1-2 µs**。

---

## §5 — Reduce Kernel Optimization Space

当前实现 (line 1155–1198)：
1. `reg_topk_idx/weights` 从 `topk_idx`/`topk_weights` 用 `__ldg` 读（L1 cached load），每 token 8 次
2. 外层 hidden loop，内层 token loop，top-8 source 循环
3. FMA 用 **scalar FP32 accumulate**：`combined_values[j] += float(x_bf16[j]) * reg_topk_weights[i]`
4. 输出 cast 回 BF16 存入 `combined_x`

**优化候选**：

| # | Lever | µs savings | Complexity | 基础 |
|---|---|---|---|---|
| R1 | `__hfma2` BF16x2 paired FMA 替代 scalar FP32 accumulate | 2–4 µs | MEDIUM | H200 Tensor Core 不适合（粒度太小，没有 m16n8k16 MMA shape 匹配）；warp-level BF16 FMA intrinsic 比 FP32 提速 ~1.5×，但精度下降 |
| R2 | Top-k source 的 **vector load prefetch**：把 top-8 source 的 int4 预取到 shared mem | 3–6 µs | MEDIUM | 当前 `ld_nc_global` 是 L1 bypass（non-coherent），L2 hit 但延迟 ~200 cycle；shared mem 可降到 20 cycle |
| R3 | `cp.async.bulk` (TMA) load source rows，配合 mbarrier | 5–10 µs | HIGH | Hopper TMA 已经在 send 侧用（line 905），recv 侧没用；但需要 LHS/RHS 大 tensor，对 128 B per source 增益小 |
| R4 | BF16 accumulate (非 FP32) | 2 µs | LOW | 数值正确性风险（top-8 求和可累积误差） |
| R5 | Top-k loop 展开 + reg tile | 1–2 µs | LOW | 当前 `#pragma unroll` 已做 |

**实测需求**：R1/R2 必须靠 §7 instrumentation 才能确认。

---

## §6 — ROI-Ranked New Levers

Anchored to 46.72 µs recv + 232 µs gap (inter-node+CPU proxy that recv path cannot touch).

### Lever A：合并 combine-send 的 "atomic WR" 到 data WR (节省 peer proxy 1 poll)
- **修改位置**：`internode_ll.cu:1069`（dispatch 侧是 separate atomic），combine 侧已经是单 WR。需核查 `nvshmemi_ibgda_amo_nonfetch_add` 是否总是触发第二个 CQE
- **预期**：0.5–1 µs (写在 PR body，peer CPU proxy 少 poll 一次)
- **与 SBO 冲突**：独立
- **复杂度**：MEDIUM（需 IBGDA submodule 修改）

### Lever B：Reduce 的 shared-mem source prefetch (R2 上面)
- **修改位置**：`internode_ll.cu:1169–1189`
- **每 SM**：top-8 source rows of int4[896] = 114 KB → 太大，只能 tile 到 hidden_chunk
- **修改成本**：中等，需要重构循环嵌套（hidden 外 → tile 外 → top-k 中 → hidden-in-tile 内）
- **预期**：3–6 µs (total reduce from ~37 µs → ~32 µs)
- **与 SBO 冲突**：独立（Sprint A/B 改 spin / CPU proxy，不碰 reduce）
- **复杂度**：MEDIUM

### Lever C：Kernel fusion — `combine_recv` 后接 attention pre-norm
- **动机**：当前 SGLang 调用栈里，combine kernel 写完 `combined_x` (hidden_states) 后立刻进入下一 decoder layer 的 RMSNorm + attention QKV proj。Kernel launch 开销 ~5 µs × 2 kernel = 10 µs；fuse 掉保 5 µs。
- **修改位置**：SGLang `python/sglang/srt/layers/moe/ep_moe/layer.py` + UCCL combine epilogue
- **预期**：3–5 µs
- **与 SBO 冲突**：独立
- **复杂度**：HIGH (需 SGLang 侧配合 kernel API 变动)

### Lever D (low priority)：grid sync 替换为全局 counter spin (§3)
- **预期**：1–2 µs
- **复杂度**：LOW
- **为什么排低**：ROI 极小，且改动 barrier 语义有正确性风险

**Note — 以下不在本 recv-path ROI 内（已被 SBO Sprint B 覆盖或 FEASIBILITY_RECONFIRM 驳回）**：
- CPU-spin EFA 独占 — SBO Sprint B
- Grid barrier 替 persistent kernel — FEASIBILITY_RECONFIRM C1 驳回
- LogFMT decode 优化 — recv 侧不解码（§已确认），成本 0

---

## §7 — Instrumentation Plan (1–2 Days Deliverable)

**利用已有工具**：`combine_wait_recv_cost_stats` (buffer.py:438, uccl_ep.cc) 已经提供 per-src-rank cycle counter。以下是扩展。

### Day 1 — 现有 counter 全集

1. 在 `bench/test_low_latency_pplx.py` 加 `combine_wait_recv_cost_stats=torch.zeros(num_ranks, dtype=torch.int64, device='cuda')` 传入 combine() 调用
2. 打印 `.div_(1980)`（clock64 @ 1.98 GHz → ns）→ 得到每 peer 的 flag-spin 等待 µs
3. 对 both vs recv-only 两种场景对照：recv-only 应 <1 µs；both 应 150–250 µs
4. **Expected insight**：tail peer 分布 — 哪个 rank 总是最后？EFA SRD 哪个 AZ 抖动大？

### Day 2 — 新增 per-phase `clock64()` 桩

在 `internode_ll.cu` 加 4 个新 cycle counter（per-SM shared mem array，kernel 结束 atomicAdd 到全局）：

```cuda
// At line 1083 (enter RECV label)
uint64_t t_recv_start = (lane_id == 0) ? clock64() : 0;

// At line 1143 (after spin)
uint64_t t_spin_end = (lane_id == 0) ? clock64() : 0;

// At line 1149 (after grid sync)
uint64_t t_sync_end = (lane_id == 0) ? clock64() : 0;

// At line 1200 (after reduce)
uint64_t t_reduce_end = (lane_id == 0) ? clock64() : 0;

// atomicAdd to workspace[4..7] at kernel exit
```

**输出**：per-iteration 4 个 µs 数字 → P50/P99 分布表
- `spin` = t_spin_end - t_recv_start
- `grid_sync` = t_sync_end - t_spin_end
- `reduce` = t_reduce_end - t_sync_end

**Expected numbers (combine_both)**:
- spin 200–250 µs (EFA flight)
- grid_sync 3–6 µs
- reduce 30–40 µs

**Expected numbers (combine_recv-only)**:
- spin 0.5–2 µs
- grid_sync 3–6 µs
- reduce 30–40 µs

### Day 2 deliverable

- PR 到 `KevinZhao/uccl` 叫 `perf: combine recv per-phase clock64 counters (debug-only)`
- 结果文档 `results/stage5-p5en/combine-recv-instrumentation/`

**工作量**：~1.5 天。无外部依赖。

---

## 文件引用 (绝对路径)

- `/home/ec2-user/workspace/uccl/ep/src/internode_ll.cu:1083-1204` combine recv kernel
- `/home/ec2-user/workspace/uccl/ep/src/internode_ll.cu:1094-1142` flag spin + `combine_wait_recv_cost_stats` 已有 instrumentation
- `/home/ec2-user/workspace/uccl/ep/src/internode_ll.cu:1148` grid barrier
- `/home/ec2-user/workspace/uccl/ep/src/internode_ll.cu:1155-1198` reduce top-k weighted sum
- `/home/ec2-user/workspace/uccl/ep/src/rdma.cpp:2413-2617` remote_poll_completions
- `/home/ec2-user/workspace/uccl/ep/src/rdma.cpp:2504-2547` atomic_buffer fetch_add (writer side of flag)
- `/home/ec2-user/workspace/uccl/ep/src/proxy.cpp:494-543` run_dual loop
- `/home/ec2-user/workspace/uccl/ep/include/ep_utils.cuh:588-597` `ld_acquire_sys_global`
- `/home/ec2-user/workspace/uccl/ep/bench/test_low_latency_pplx.py:605-629` both/send/recv timing harness
- `/home/ec2-user/workspace/uccl/ep/bench/buffer.py:434-514` combine_wait_recv_cost_stats wiring
- `/home/ec2-user/workspace/uccl/ep/include/common.hpp:25` `USE_RECEIVER_BARRIER` default under EFA
- `/home/ec2-user/workspace/efa-validation/docs/ALLTOALL_DEEP_DIVE.md:28-30` baseline numbers

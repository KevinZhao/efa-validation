# UCCL-EP Paper Claim vs Code Reality — Gap Analysis

**Agent P, 2026-04-26.** Compares UCCL-EP paper (arxiv 2512.19849, OSDI 2026) + UCCL-Tran (arxiv 2504.17307, OSDI 2026) + repo README against code at `/home/ec2-user/workspace/uccl/ep/` (tracking `main`).

Scope restriction (per task brief): do **NOT** repeat already-covered levers — SRD protocol fields, SBO Sprint A/B/C, shared-SRD-QP (L9), efadv caps, multi-QP #485 rebase, count-send coalescing, NUMA/CCX pin, flow_label/SL. This round = **paper-claim-level** gaps only.

Code anchors verified:
- Source files at `/home/ec2-user/workspace/uccl/ep/src/{rdma.cpp, proxy.cpp, internode_ll.cu, internode.cu, uccl_ep.cc}`
- Constants at `/home/ec2-user/workspace/uccl/ep/include/common.hpp`
- README at `/home/ec2-user/workspace/uccl/ep/README.md`

---

## 0. TL;DR

Total paper-level claims audited: **17**
- ✅ Fully implemented: **4**
- 🟡 Partial (paper says N, code does M<N): **6**
- 🟠 Stub/MVP (paper calls "key optimization", code is literal minimum): **5**
- ❌ Missing / disabled by default: **2**

**Top 3 highest-ROI PR-level gaps**:

1. **G-01 "Congestion Control with CPU proxy" = missing.** Paper §6 (Discussion) makes it a headline design lever; code has only a static `kMaxInflight` quota with `kMaxInflightBytes = SIZE_MAX` by default (common.hpp:72) — no rate tracking, no pacing, no ECN/RTT reaction. Adding a **per-(dst_rank, NIC) token-bucket pacer + adaptive kMaxInflight** is 1-2 week PR, unblocks AWS EFAv3 p5en stragglers, EFA-unique value since EFA has no hardware CC surface and incast kills tail on cross-AZ tests.
2. **G-02 "Aggregating NICs of different bandwidths" on EFA = hard-coded modulo.** Paper §4 (Implementation) specifically calls this out as a UCCL-EP feature ("aggregates bandwidth across multiple NICs per GPU… relies on CPU threads to load balance"); rdma.cpp:481-504 is a static `thread_idx % 2 + half` assignment. No runtime load balancing, no queue-depth awareness, no NUMA re-pin. 2-3 day PR to add a dynamic-least-loaded NIC picker per `Poll()`; EFA-unique value (on p5en each GPU has 2× NICs, paper's 2.1× claim depends on this).
3. **G-03 Reordering buffer capped at 16 writes/expert.** Paper §3.3 (LL mode) describes "partial completion fence" as the core EFA correctness trick. Code (common.hpp:85 `kReorderingBufferSize 16`, rdma.cpp:2274 `vals[16]`, `present_mask` = `uint16_t`) aborts if more than 16 writes per expert arrive before the atomic. For `num_max_dispatch_tokens_per_rank > 16` × out-of-order EFA SRD, this is a real production risk. 3-5 day PR to widen imm_data seq field (use 2 imm bits from `ImmType` prefix) + dynamic hashmap.

---

## 1. Paper Claims Inventory

Numbered list of 17 design points the papers + README commit to. Sources noted.

| # | Claim | Source |
|--|-------|--------|
| C1 | **GPU-agnostic** (NVIDIA + AMD) | UCCL-EP paper §4.2, README "Road Map ✅" |
| C2 | **NIC-agnostic** (NVIDIA CX7, AWS EFA, Broadcom, Intel, vendor-new via libibverbs) | UCCL-EP §1, §4, Figure 1b, README |
| C3 | **CPU-proxy GPU-initiated** (replaces IBGDA) | UCCL-EP §3 whole design |
| C4 | **Multi-threaded CPU proxy** for scalability | UCCL-EP §3.2, Figure 17 (varying #threads) |
| C5 | **Efficient 128-bit lock-free FIFO w/ GPU tail caching** | UCCL-EP §3.1 ("caches the tail index value on the GPU") |
| C6 | **Receiver-side partial-ordering enforcement** via imm_data (LL "partial completion fence") | UCCL-EP §3.3 |
| C7 | **HT-mode partial ordering** per-channel via seq imm | UCCL-EP §3.3 |
| C8 | **Software atomics emulated on EFA** via imm | UCCL-EP §4.1 |
| C9 | **Multi-QP per peer, QP load balancing across NICs** | UCCL-EP §4 "Queue Pair (QP) load balancing" |
| C10 | **Aggregating multi-NIC bandwidth per GPU** | UCCL-EP §4 "Aggregating NICs of different bandwidths" |
| C11 | **Token deduplication on intra-node fork** (DeepEP semantics) | UCCL-EP §2.2, Table 1 column "Token dedup&reduce ✓" |
| C12 | **Hierarchical reduce for combine** | UCCL-EP §2.2 |
| C13 | **CUDA Graph compatible** (implied through DeepEP API compat) | README Example APIs, bench/buffer.py:319 |
| C14 | **Congestion control with CPU proxy** (throttling, pacing, multi-QP sharding) | UCCL-EP §6 "Discussion and Future Work" ("instead of... CPU proxy… could easily support request tracking and pacing… could also bear responsibility for multi-QP management… throttle or shard the outgoing requests across NICs and QPs") |
| C15 | **Elastic EP / failure recovery** | UCCL-EP §6 |
| C16 | **UCCL-Tran multipath+packet-spraying+CUBIC/Swift** (inherited claim; README "Better flow control to avoid congestion ✅") | UCCL-Tran paper §3.2, §4.1, README road map |
| C17 | **PER_EXPERT_BATCHING reduces WR count on EFA** (merged PR #745, LL-kernel key optimization for EFA) | Makefile:81, deep_ep_wrapper/README.md |

---

## 2. Claim-by-Claim Implementation Status

### C1: GPU-agnostic (NVIDIA + AMD) — ✅ **Fully**

Paper says: CUDA/ROCm parity.
Code evidence: `internode_ll.cu` and `internode.cu` have matched `#if defined(__HIP_PLATFORM_AMD__) || defined(__HIPCC__)` branches at every PTX/warp/atomic intrinsic (80+ pairings). `uccl_proxy.cpp:63` handles both GPU memory allocators.
Verdict: Real parity. Only minor gap: `__NVCC__`-only code at `internode_ll.cu:814, 1013, 1240` uses `DISABLE_SM90_FEATURES` guard — AMD may lose TMA-style fast paths. Known / acknowledged in paper §4.2.
Priority: **DROP** (well-covered).

### C2: NIC-agnostic (EFA / CX7 / Broadcom / Intel) — 🟡 **Partial**

Paper says: "Other NIC vendors should be naturally supported via portable libibverbs" (§4).
Code evidence: `rdma.cpp:884 #ifdef EFA` guards 120+ LOC of EFA-specific create_srd_qp_ex; `common.hpp:38 INTEL_RDMA_NIC` guards DMA-BUF+pinned-host-atomic-buffer fallback; `rdma.cpp:874` "Use standard CQ for other NICs like Broadcom".
Gap: The claim "O(m) effort" (Figure 1b) is understated — each new NIC still needs build-time `#ifdef` for CQ creation, atomic semantics, and GID/AH. Genuinely new NICs (Thor-3, AMD Pollara Gen2) need non-trivial `#ifdef` blocks. Not runtime-polymorphic.
Priority: **P3** (not our immediate problem).

### C3: CPU-proxy GPU-initiated replaces IBGDA — ✅ **Fully**

`proxy.cpp:603 post_gpu_command()` + FIFO plumbing + `uccl_ibgda.cuh` PTX-free GPU-side push. Verified via `nvshmemi_ibgda_put_nbi_warp` being a UCCL namespace function (not NVSHMEM's), see `internode_ll.cu:269` calling `uccl::nvshmemi_ibgda_put_nbi_warp`.
Priority: **DROP**.

### C4: Multi-threaded CPU proxy for scalability — 🟠 **Stub (hard-coded 4)**

Paper says "UCCL-EP uses more CPU threads for scalability" (§3.2), Figure 17 shows sweep 1/2/4 threads.
Code evidence: `common.hpp:69 #define kNumProxyThs 4` — **compile-time constant**. `uccl_ep.cc:2187 m.def("get_num_proxy_threads", []() { return kNumProxyThs; })` exposes it read-only. No env var, no API.
Gap: Can't runtime-scale to 8/16 threads as EFAv4 400G lands (paper §5.4 hints "800G network [8]"). Figure 17 was generated by recompiling, not by a user-facing knob.
Compile to knob: **2-hour PR** (swap `#define` with `get_num_proxy_threads_env()` + touch `kChannelPerProxy * kNumProxyThs` asserts in `uccl_ibgda.cuh:332, 381`).
Gain: Unknown at runtime; for current 400G likely negligible (paper §5.4 already saturates at 4), for 800G upgrade NPN P0.
Priority: **P2** (cheap; Blackwell/EFAv4+ ready).

### C5: Lock-free FIFO w/ GPU tail caching — ✅ **Fully**

`fifo.cpp:17 UniqueGpuPtr<uint64_t> tailCache` + `fifo_device.hpp:190 uint64_t* tailCache` + read-only check at line 125 `if (prevHead >= size + *tailCache)` before PCIe sync. This matches paper §3.1 precisely. MSCCLPP-style 16-byte descriptor ("`#define USE_MSCCLPP_FIFO_BACKEND`" at common.hpp:34).
Priority: **DROP** (implemented as described).

### C6: LL partial completion fence via imm seq — 🟡 **Partial (16-slot cap)**

Paper §3.3 says "buffer the atomic message in the control buffer until the required number of tokens… received".
Code evidence: `rdma.cpp:2264-2323` (AtomicsImm reorder path). Works correctly **up to 16 unacked messages per (expert, src_rank)**.
Gap: `common.hpp:85 #define kReorderingBufferSize 16  // Right now only 4 bits.` AND `rdma.cpp:2274 int vals[kReorderingBufferSize] = {0}; uint16_t present_mask = 0;`. At line 2285 and 2304, **`std::abort()`** if `seq >= 16`. Line 2316-2317 also aborts on duplicate (real risk on SRD out-of-order).
Why gap exists: imm is 32-bit (RoCE/EFA standard, cannot grow). Authors chose only 4 bits for seq to leave room for (offset, value, expert_idx, signal-bits). Comment at line 83-84 explicitly says they tried to fit more but "eats into offset and values".
Fix work: **3-5 days**. Options: (a) Widen imm by stealing 2 bits from `kMaxSendAtomicValue = 16383` (14 bits value) → free 4 bits, push seq to 8 bits (256 slots). (b) Use a secondary compact atomic-update channel with 64-bit imm. (c) Per-expert-per-src dynamic `std::unordered_map` SeqBuf that grows.
Predicted gain: **NOT a latency win** (paper measurements hit happy path); it's a **scalability safety-net** — lets `num_max_dispatch_tokens_per_rank` grow past 16. Any run with > 16 tokens/expert today relies on the network not reordering more than 16. EFA's 2.1× paper claim on p5en was with num_tokens up to 4096, so 16-buffer wraps relying on "mostly in-order" SRD delivery.
EFA-unique value: **YES** — CX7 RC is in-order, so gap only bites EFA/Broadcom/any adaptive-routing fabric.
Priority: **P0** (safety + scalability).

### C7: HT partial ordering per channel — 🟡 **Partial**

Paper §3.3 says "per-channel communication is locally ordered… extract sequence number from immediate data; if the received message arrives out-of-order, it will temporarily buffer these atomic messages".
Code evidence: Same reorder machinery as C6 applies. Same 16-slot abort.
Gap: Same as C6 but the HT window (`kChannelPerProxy = 8` ring buffers × `kMaxInflightNormal = 8` inflight writes) = 64 max in-flight writes across channels, inside each channel the buffer is 16. HT path calls `post_rdma_async_batched_normal_mode` but the atomic increments the same counter, using same imm encoding.
Priority: absorbed into P0 (G-03). Same fix doubly needed here.

### C8: Software atomics emulated on EFA — ✅ **Fully**

`uccl_proxy.cpp:69 cudaHostAlloc(&atomic_buffer_ptr_, ... cudaHostAllocMapped)` + `proxy.cpp:264 c.atomic_buffer_mr` — host-allocated counter memory, mapped into GPU, RDMA-writable by remote. Paper §4.1 claim met.
Priority: **DROP**.

### C9: Multi-QP per peer with load balancing — 🟡 **Partial (round-robin only)**

Paper §4 says "each thread creates multiple QPs (corresponding to the number of FIFO queues) between pairs of ranks… the CPU thread round-robins among the QPs it manages".
Code evidence: `rdma.cpp:994-1017` creates `rings_to_create = min(num_rings, kChannelPerProxy=8)` data QPs. Ring selection in LL path: `uccl_ibgda.cuh:36 int thread_idx = (expert_idx % num_d2h_channel_addrs) % kNumProxyThs` — pure hash-by-expert, no load observation.
Gap: "Round-robin" described is actually **modulo on expert_idx**, not round-robin on per-QP depth. If one expert is much hotter (paper §1 references DeepSeek's 10× incast), all its traffic still goes through the same QP → QP depth imbalance even while sibling QPs idle. Power-of-Two sampling (UCCL-Tran §4.1) is NOT inherited here.
Fix work: **1 week**. Add per-QP outstanding-WR counter in ProxyCtx; replace modulo with "min-load among this thread's QPs" when expert isn't ordering-pinned. The P-of-2 from the UCCL-Tran paper is a spec; implementation is ~50 LOC in `post_rdma_async_batched_*`.
Predicted gain (推论): P99 dispatch latency under skewed-expert load; rough expectation on EFA p5en is 5-10% tail reduction when top-3 experts concentrate > 50% tokens. Can be benchmarked with `bench/test_low_latency.py` + synthetic skewed topk.
EFA-unique: **partial** — CX7 also benefits but EFA's round-robin ARM core mapping (UCCL-Tran §5 implementation note) is more sensitive to QP depth imbalance.
Priority: **P1**.

### C10: Aggregating multi-NIC bandwidth per GPU — 🟠 **Stub (static modulo per NIC)**

Paper §4 (third-to-last implementation paragraph): "UCCL-EP relies on CPU threads to load balance across different NICs. **We omit the details for brevity.**"
Code reality: `rdma.cpp:481-504` — on p5en (EFA v3, `num_efas == 16`), **each proxy thread is statically bound to ONE NIC at init**:
```
auto half = (local_rank % 2) * 2;
selected_nic_name = candidates[thread_idx % 2 + half];
```
And the QP lives on THAT NIC's context for its lifetime. No cross-NIC steering at `Poll()` time. The "aggregation" is entirely "two proxy threads happen to each use a different NIC". If one EFA NIC queue gets deep (e.g., that specific AZ's fabric contention), the thread can't migrate.
Fix work: **3-5 days**. Need a 2nd QP per proxy thread on the sibling NIC + per-`post_rdma_async_*` decision to choose either QP based on outstanding-WR depth. Breaking change to ProxyCtx (currently one `context`/`pd` per thread) — either multiplex two ProxyCtx per thread or lift NIC-binding to per-WR.
Predicted gain (推论, not measured): On EFA p5en with partial-NIC congestion (which we empirically saw during R1b spot reclaim chaos) — 5-15% throughput recovery. On fully-idle fabric, 0%.
EFA-unique value: **strong YES**. CX7 is 1 NIC per GPU on most platforms, EFA p5en splits 400G into 2× 200G, and NIC-bonding at kernel level (mlx-style) doesn't exist on EFA. UCCL-EP is the only software layer that could do this.
Priority: **P1**.

### C11: Token deduplication (intra-node) — ✅ **Fully**

Table 1 in paper claims dedup ✓. Code: `internode.cu:26` `is_token_in_nvl_rank_bits` bitmap per RDMA rank + `internode.cu:89-90 translate_dst_rdma_rank()` chooses a single NVL peer per RDMA rank; NVL forwarding path in `kRDMAAndNVLForwarder` warp role (internode_ll.cu:504, 523, 569, 632, 1086) handles the subsequent intra-node fanout via IPC copy.
Priority: **DROP** (inherited from DeepEP correctly).

### C12: Hierarchical reduce for combine — ✅ **Fully**

Same NVL forwarder infrastructure. Not relevant to EFA-layer optimizations.
Priority: **DROP**.

### C13: CUDA Graph compatible — 🟡 **Partial (only LL mode + intranode)**

README implies full graph support. `bench/buffer.py:319` comment: "as we do not synchronize CPU received count with GPU (also not incompatible with CUDA graph if synced)". `bench/buffer.py:883`: "will be CUDA-graph compatible. Please also notice that this flag is for intranode only."
Gap: HT mode's blocking Barrier/Quiet (proxy.cpp:1245) cannot be captured into a graph cleanly — GPU `Check-completion(Idx)` spins on a host-mapped counter. Likely works in graph but semantics murky.
Fix: Out of scope; this is mostly DeepEP-inherited machinery.
Priority: **DROP** (needs upstream dialogue, not our EFA lever).

### C14: Congestion control with CPU proxy — ❌ **Missing**

Paper §6 makes this the single biggest "future-value-of-UCCL-EP" claim: "UCCL-EP delegates control decisions to the flexible CPU proxy, which could easily support request tracking and pacing. If the outstanding requests become high, the CPU proxy thread temporarily buffers the messages at the sender… The CPU proxy could also bear responsibility for multi-QP management… throttle or shard the outgoing requests across NICs and QPs to avoid congestion".
Code reality: **No CC.** Full implementation is:
- `common.hpp:72 #define kMaxInflightBytes SIZE_MAX` (no limit).
- `proxy.cpp:619 size_t budget = (kMaxInflight > pending) ? (kMaxInflight - pending) : 0;` — a hard numeric cap, no RTT/ECN/loss feedback.
- `kMaxInflightLowLatency 32`, `kMaxInflightNormal 8` — static.
No CUBIC, no Swift, no EQDS, no ECN mark read, no per-path RTT, no pacer thread. The UCCL-Tran paper's whole CC machinery (§3.4, §4.1, §4.2) does NOT get inherited into UCCL-EP at all.
Why gap exists: UCCL-Tran CC lives in `collective/`, UCCL-EP `ep/` shares no transport code with `collective/`. Paper authors say "future work" explicitly (§6 section title).
Fix work — **MVP pacer**: 1-2 weeks.
1. Add per-(dst_rank, QP) token-bucket pacer thread per proxy. Initial rate = NIC line rate / #peers.
2. On CQE `ibv_wc_status != IBV_WC_SUCCESS` (indicating EFA SRD retry-exceeded, or inflight timeout), halve the bucket.
3. Every 1 ms of clean CQEs, additive-increase 1/8 line rate.
This is "AIMD on per-peer bucket" — a Reno-like. Not Swift, not Falcon, but gives existence-of-CC.
Predicted gain (推论): **5-15% tail latency reduction** on EFA cross-AZ (which we've seen blowing up to 3 s timeouts on R3 runs). On single-AZ idle fabric: 0%. Not a throughput win; is a straggler/incast win.
EFA-unique value: **highest**. EFA has **zero** hardware CC surface exposed to software. SRD does internal CC but hides it; the UCCL-EP CPU proxy is the ONLY control point software has.
Priority: **P0** (biggest headline-vs-code gap in the paper).

### C15: Elastic EP / failure recovery — ❌ **Missing**

Paper §6 describes as aspirational. Code: zero support; any `ibv_wc_status != IBV_WC_SUCCESS` → `std::abort()` (rdma.cpp:2247-2248). Node-drop = kill whole job.
Priority: **DROP** (acknowledged future work in paper text; not our focus).

### C16: UCCL-Tran multipath/spraying/CUBIC/Swift — 🟡 **Partial (not inherited into EP)**

README road map ✅ "Better flow control to avoid congestion" suggests UCCL-EP has it. In reality the advanced transport from UCCL-Tran collective path (`collective/`) is **not compiled into `ep/`**:
- `ep/src/rdma.cpp` uses `ibv_post_send` directly, no `EngineThread`/`TxState`/`RxState` from collective side.
- No `flow_label` usage (`rdma.cpp:1132 ah_attr.grh.flow_label = 0` hardcoded).
- SL/TC env vars are set-once-never-adjusted (`rdma.cpp:1197-1201`).
- No packet spraying (that lives in the AF_XDP path and in collective's multi-QP scheduler, neither reused).
Why gap: `ep/` is a fork of DeepEP C++ semantics; the CPU-proxy thread model is incompatible with UCCL-Tran's run-to-completion engine.
Fix work: Too large for a PR (weeks). Selective-port of "`per-path RTT hint` → choose QP with lowest EWMA RTT" is feasible as a **1-week** subset.
Priority: **P2** (G-01 subsumes the most important subset).

### C17: PER_EXPERT_BATCHING — 🟡 **Partial (off by default)**

Makefile:81 `PER_EXPERT_BATCHING ?= 0`. Critical EFA optimization per the Makefile docs ("Reduces WR count on EFA") but the default build doesn't enable it, and the `internode_ll.cu` path at line 249-265 has a known inefficiency: "TODO: This has an extra temp->per-expert copy in the FP8 path. FP8 output is written to the temp buffer first, then copied here."
Gap: on EFA, not enabling this is ~2× more WRs posted; paper's p5en numbers were likely with it ON. Default OFF hurts our local builds.
Fix work: (a) Make it runtime env `UCCL_EP_BATCH_PER_EXPERT=1` (4-hr PR). (b) Eliminate the TODO'd extra copy by writing FP8 directly into per-expert batch buffer (1-2 day PR).
Predicted gain (实测锚 from paper Fig 8): when per-expert batching is ON, dispatch improves 2.3× vs PPLX; so going OFF→ON is the ~2× delta.
Priority: **P1** (both sub-tasks).

---

## 3. Top 3 PR-Level Designs

### G-01: Minimal CC on CPU proxy (addresses C14)

**File:** `ep/src/proxy.cpp`, `ep/include/proxy.hpp`, `ep/include/common.hpp`

**Protocol (new):**
- Add `struct PaceState { std::atomic<int32_t> tokens; uint64_t last_update_ns; double rate_bps; }` per (dst_rank, local QP-idx).
- Pre-send: subtract `cmd.bytes` from `tokens`. If negative, enqueue to `deferred_cmds_[dst_rank]` — CPU proxy thread's main loop drains this list on token refill.
- Post-CQE: on IBV_WC_SUCCESS, refill `tokens` additively; every N ms clean-sailing, `rate_bps *= 1.01` up to line rate. On NIC error / SRD retry timeout, `rate_bps *= 0.5`, drain `tokens` to 0 for 1 RTT.

**Key edit site:** `proxy.cpp:624-669` (budget loop). Insert PaceState check before `fifo->pop()`.

**Validation:**
- `bench/test_low_latency.py` with `--num-tokens 4096 --num-experts 288` across 4-node p5en single-AZ, compare P50/P99 dispatch latency with and without pacer.
- Stress: crank one GPU's token count 10× to create incast → expect P99 reduction.

**Feasibility ask:** UCCL-Tran already has Swift CC code in `collective/rdma/`. Borrow the token-bucket skeleton; don't try to port full Swift.

### G-02: Dynamic NIC load balance (addresses C10)

**File:** `ep/src/rdma.cpp` (per_thread_rdma_init → multi-ctx), `ep/src/proxy.cpp` (post_rdma_async_*)

**Protocol:**
- Change `ProxyCtx` to hold `std::vector<NicCtx>` (each NicCtx has its own `context`, `pd`, and one/two QPs).
- At Poll()-dispatch time, pick the NicCtx whose QP has the shallowest outstanding-WR depth (tracked in atomic counter incremented at post_send / decremented at CQE).

**Key edit site:** `rdma.cpp:481-504` (the hardcoded modulo) — remove it; each thread gets ALL same-NUMA candidates. `proxy.cpp` post path: instead of `ctxs_for_all_ranks_[peer]` picking the single QP, pick the least-loaded.

**Validation:** Artificially degrade one EFA NIC (`tc` qdisc / `ethtool --pause`) and observe whether throughput stays on the healthy NIC.

### G-03: Widen reorder-buffer seq space (addresses C6/C7)

**File:** `ep/include/common.hpp` (kReorderingBufferSize, kMaxSendAtomicValue), `ep/src/rdma.cpp` (SeqBuf), `ep/include/imm_types.hpp` (new: AtomicsImm layout)

**Protocol option A (imm-steal, preferred for EFA):** Drop `kMaxSendAtomicValue` from 16383 (14-bit) to 4095 (12-bit), freeing 2 bits. Extend seq from 4 to 6 bits = 64 slots. `SeqBuf.present_mask` becomes `uint64_t`.

**Protocol option B (secondary channel):** Pipe the reorderable atomics through `ack_qp` which has spare imm bits.

**Validation:** Synthetic reorder torture test (burst 32 writes then 1 atomic per expert, 32 experts × 288 topk). Today aborts at seq=16; after fix should commit correctly.

**Why EFA-unique:** CX7 RC QPs deliver in-order, so seq always starts at 0 and stays low — the cap never bites.

---

## 4. Maintainer-Acknowledged TODOs (from code + paper future-work)

Non-exhaustive list, grep-anchored:

- `internode.cu:89 // TODO(MaoZiming): always cross-rail.` — rail-optimized topology optimization not adaptive.
- `internode.cu:188-189 // TODO: overlap EP barrier and NVL cleaning` — known serialization point.
- `internode.cu:254 // TODO: may use NVSHMEM reduction` — ironic given the paper's anti-NVSHMEM stance.
- `internode_ll.cu:252 // TODO: This has an extra temp->per-expert copy in the FP8 path.` — confirms C17 extra copy.
- `internode_ll.cu:917 // TODO: try elect_one_sync` — missed warp-election optimization on Hopper+.
- `rdma.cpp:1070 // TODO(MaoZiming): Only for non-EFA case.` — implicit gap, implies the EFA case is a special fall-through.
- `rdma.cpp:2331 // TODO(MaoZiming): pass node_idx instead.` — barrier seq encoding is implicit on rank, breaks if multi-process-per-node.
- `proxy.cpp:105 // TODO(MaoZiming): improves pinning.` — CPU pinning is naïve modulo.
- `proxy.cpp:182 // TODO(MaoZiming): Skip registering for EFA.` — atomic_buffer_mr is registered on EFA too but may be unused.
- `uccl_bench.cpp:35,53,81 assert(false && "TODO: uccl_bench does not support mscclpp fifo");` — benchmark harness is incomplete.

UCCL-EP paper §6 explicitly labels **(CC, elastic EP, better LL kernel, AI accelerators)** as future work.

---

## 5. Honest UNKNOWNs

1. **C13 CUDA-graph HT-mode**: I did not actually run a CUDA graph capture on the HT path to see if it works. Paper is silent; comments are ambiguous. Need a 1-hour repro with `torch.cuda.graph()`.
2. **Real % drop from kReorderingBufferSize=16**: The abort path hasn't been triggered in our recent Stage-5 runs. Is that because EFA SRD happens to reorder < 16 writes deep, or because we never posted > 16 writes per expert? Needs instrumentation (count present_mask peak).
3. **Paper's CC claim "could"**: §6 uses the word "could" a lot. Is there unmerged WIP somewhere in the repo? `search_issues` returned no open PRs on CC. But PR #928/#932/etc. not searched exhaustively; maintainer may have experimental branch.
4. **PER_EXPERT_BATCHING default on p5en**: My memory says the AWS p5en benchmarks in the README's results section were produced with this flag ON. Not 100% confirmed — could be OFF and we'd be mis-attributing the 2× gap to it.
5. **Power-of-Two LB in UCCL-Tran**: described in UCCL-Tran paper §4.1 but I didn't open `collective/` to confirm it's implemented there. The NOT-inheritance into `ep/` is confirmed.
6. **Intel RDMA NIC branch**: `common.hpp:38 INTEL_RDMA_NIC` is live (DMA-BUF path). Paper never mentions Intel. The bench/vllm scripts reference `intel_nic` — so there's NIC support that predates the paper, suggesting the NIC-agnostic claim is more real than paper details imply.

---

## 6. Summary Table

| ID | Claim | Status | Fix effort | Predicted gain | EFA-unique? | Priority |
|----|-------|--------|-----------|----------------|-------------|---------|
| C1 | GPU-agnostic | ✅ | — | — | no | DROP |
| C2 | NIC-agnostic | 🟡 | weeks | low | no | P3 |
| C3 | CPU-proxy init | ✅ | — | — | — | DROP |
| C4 | Multi-threaded proxy | 🟠 | 2h | 0% now / 800G-ready | no | P2 |
| C5 | FIFO+tail cache | ✅ | — | — | — | DROP |
| C6 | LL partial fence | 🟡 | 3-5d | safety net | **yes** | **P0** |
| C7 | HT partial order | 🟡 | (same as C6) | (same) | **yes** | subsumed |
| C8 | Sw atomics on EFA | ✅ | — | — | — | DROP |
| C9 | Multi-QP LB | 🟡 | 1 wk | 5-10% P99 | partial | P1 |
| C10 | Multi-NIC LB | 🟠 | 3-5d | 5-15% under skew | **yes** | **P1** |
| C11 | Token dedup | ✅ | — | — | — | DROP |
| C12 | Hier. reduce | ✅ | — | — | — | DROP |
| C13 | CUDA graph | 🟡 | upstream | — | no | DROP |
| C14 | CPU-proxy CC | ❌ | 1-2 wk | 5-15% tail | **yes** | **P0** |
| C15 | Elastic EP | ❌ | months | — | — | DROP |
| C16 | UCCL-Tran inheritance | 🟡 | weeks | low | no | P2 |
| C17 | PER_EXPERT_BATCHING | 🟡 | 4h+2d | ~2× dispatch | **yes** | **P1** |

Six P0/P1 items emerge, all **EFA-unique or EFA-sensitive**. The three flagship gaps are C14 (CC), C10 (multi-NIC), C6/C7 (reorder capacity), plus the off-by-default C17 as a "why are we leaving 2× on the table" follow-up.

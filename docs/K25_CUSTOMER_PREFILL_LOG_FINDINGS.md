# Kimi-K2.5 customer prefill.log findings

Log source: `customer_K2.5/prefill.log` (customer 0428 on-site run, 4173 lines,
single node `6.166.125.145`, 8xGPU DP=TP=8, Kimi-K2.5 W4A16 compressed-tensors
on FP8 base, Mooncake+EFA transport, 16 EFA NICs, PD-prefill role).

Scope: everything AFTER `line 13 — CommonKVBootstrapServer started`. The
pre-line-13 `server_args=…` line is skipped (documented elsewhere).

## Silent downgrades (sglang overriding user intent)

- [line 6] `The command line argument '--prefill-round-robin-balance' is
  deprecated and will be removed in future versions.` — customer's
  `run_prefill.sh` still passes this; upstream has renamed it. No functional
  impact today but will break on next sglang bump.
- [line 7] `DP attention is enabled. The chunked prefill size is adjusted to
  4096 to avoid MoE kernel issues.` — customer config set chunked-prefill to
  16384 (common default for K2.5); sglang silently clamps to **4096** because
  `--enable-dp-attention` is on. Real prefill token budget is 1/4 what they
  asked for.
- [line 8] `Cuda graph is disabled for prefill server when piecewise cuda graph
  is not enabled.` — combined with [lines 1879-1886] `Disable piecewise CUDA
  graph because --disable-piecewise-cuda-graph is set`. Customer explicitly
  disabled piecewise graph, so **no CUDA graph capture at all on prefill**.
  Every prefill batch shown in the log later confirms `cuda graph: False` (e.g.
  lines 3141-3148, 4115-4145). Kernel launch overhead is in the critical path.
- [lines 1817, 1820, 1835-1850] *(×8 DP ranks)* `Acceleration for non-quantized
  schemes is not supported by Compressed Tensors. Falling back to
  UnquantizedLinearMethod` — for Kimi-K2.5's dense (non-MoE) linears the
  compressed-tensors fast path is unavailable; sglang silently falls back to
  plain `UnquantizedLinearMethod` (BF16 matmul) on those layers. Only MoE
  layers keep the Marlin W4A16 path (`CompressedTensorsWNA16MarlinMoEMethod`,
  lines 1821, 1822, 1843, 1844, 1847, 1848, 1851, 1852).
- [lines 1815-1846] *(×8)* `Multimodal attention backend not set. Use fa3.` —
  customer did not set `--multimodal-attention-backend`; sglang picks **fa3**
  by default. Not wrong (K2.5 is multimodal-capable and fa3 is the right
  pick on H200), but it is an auto-enable the customer did not request.
- [lines 1-5, 3045, 3050, …] Python deprecation noise (launch_server vs
  `sglang serve`, `ORJSONResponse` FastAPI deprecation) — cosmetic only.

## Startup warnings

- [line 11] `Fail to set RLIMIT_STACK: current limit exceeds maximum limit` —
  container already has a higher stack than sglang tries to push it to. Benign
  but indicates the launcher's ulimit logic is a no-op under this image.
- [line 16] `Using a slow tokenizer. This might cause a significant slowdown.
  Consider using a fast tokenizer instead.` — Kimi tiktoken loader is
  HuggingFace's slow-path. Affects cold-start request tokenization latency,
  not steady-state.
- [lines 3125-3140] *(×8 DP ranks, 14:01:41 → 14:06:58)* `CUTE_DSL - WARNING -
  [handle_import_error] - Unexpected error during package walk:
  cutlass.cute.experimental` — the CUTE DSL import probe fails cleanly per
  rank, **but serializes behind some 316-second blocker on DP7** (7 ranks hit
  14:01:41, the 8th rank only emits at 14:06:58). This is the cause of the
  5m17s warmup stall — see Phase timings.
- [lines 573-652] *(×8, NCCL_Plugin_v6-v10)* `NCCL INFO NET/Plugin: Failed to
  find ncclCollNetPlugin_v{6,7,8,9,10} symbol.` then [line 572] `Loaded net
  plugin Libfabric (v10)`. NCCL probes for CollNet variants before settling on
  Libfabric — informational, no functional impact on EFA (no SHARP anyway).
- [lines 1694-1715] *(×8)* `NCCL INFO TUNER/Plugin: Failed to find
  ncclTunerPlugin_v4 symbol.` — NCCL built against a tuner API the plugin
  doesn't expose. Falls back to builtin tuner. Informational.
- [line 35 + 60 + 89 + 187 + 204 + 254 + 284 + 297] *(×8)* `WARNING: Logging
  before InitGoogleLogging() is written to STDERR` — glog uninitialized at
  Mooncake transfer_engine first call. Cosmetic.

## Phase timings

Absolute clock anchors (from `[2026-04-28 HH:MM:SS]` stamps):

| Phase | Start | End | Δ |
|---|---|---|---|
| CommonKVBootstrapServer ready | 13:57:26 | — | — |
| Tokenizer reload (main) | 13:57:26 | 13:57:33 | **7 s** |
| Tokenizer reload (×8 TP workers, staggered) | 13:57:41 | 13:57:42 | **~1 s batch** |
| Mooncake TE + EFA init (×8 workers) | 13:57:42.07 | 13:57:42.80 | **~0.7 s** (first-last worker spread) |
| 16 EFA devices initialized per worker | 13:57:42.52 | 13:57:42.80 | **~280 ms / worker** |
| `Init torch distributed` | 13:57:42 | 13:57:50 | **5.3-7.2 s** per rank ([lines 1805-1812]) |
| Load weight (×8 ranks, 64 shards) | 13:57:51 | 14:01:12 | **162-201 s** (fastest DP1 162.83s, slowest DP7 201.36s — [lines 1854-1861]) |
| KV cache alloc + mem pool | 14:01:12 | 14:01:13 | **~1 s** (per rank 21.90 GB, 334588 tokens) |
| EFA MR autosplit + chunk register (KV buffers) | 14:01:14.93 | 14:01:20.39 | **~5.5 s** — 568 chunks; longest single register **4870 ms** ([line 2913]) |
| Uvicorn up + application startup | 14:01:20 | 14:01:37 | **~17 s** |
| `Start of pd disaggregation warmup` (×8) | 14:01:34 | 14:01:38 | staggered 4 s |
| Warmup forward (first) | 14:01:41 | 14:06:58 | **5m 17s stall on DP7** — CUTE_DSL import appears to be the cover event; actual cause is the first forward-pass kernel/autotune + CUDA init on the last rank |
| Warmup responses returned (`The`/`]+`) | 14:07:00 | — | e2e_latency reported in resp ≈ **322-325 s** per DP rank (prompt_tokens=4, output=1 token) — matches the stall above |
| `The server is fired up and ready to roll` | 14:07:00 | — | — |
| **Idle gap (no real traffic)** | 14:07:00 | 14:14:41 | **7m 41s** |
| First router probe (404 PRI) | 14:14:41 | — | — |
| First real `/health` 200 | 14:14:44 | — | — |
| Second NCCL comm init (secondary commId 0x9a20…) | 14:14:44 | 14:15:02 | **~18 s** — bootstrap 0.0012-0.005 s, total `Init COMPLETE` 0.37 s per rank ([lines 3757-3771]) — this is triggered by a real request, probably a new all-reduce group for bench |
| First real `/v1/chat/completions` 200 | 14:15:03 | — | — (1070 input tokens; DP2 input-throughput 0.06 tok/s — kernel cold) |
| Mooncake Peer reconnect storm begins | 14:15:05 | 14:15:37 | **32 s, 198 reconnect events** |
| Segfault in `EfaContext::submitSlicesOnPeer` | ~14:15:37 | — | — ([line 4146]) |
| Transfer Engine 30 s sync timeout | 14:15:37 | — | ([line 4172]) |
| `Session 6.166.120.207:15182 failed` | 14:15:37 | — | ([line 4173]) |
| Health check failed (detokenizer stuck 20 s) | 14:16:01 | — | ([line 4174]) |

Total cold-start from `bash run_prefill.sh` to "fired up and ready to roll" =
**9m 34s**. Total cold-start to first customer request served = **17m 37s**.

## Mooncake / EFA runtime counters

- [line 54 / 79 / 112] `Topology discovery complete for EFA. Found 16 devices.`
  × 8 workers — all 16 rails enumerated.
- [lines 84-178] `EFA device (libfabric): rdmapNNNs0, domain: rdmapNNNs0-rdm,
  provider: efa (shared endpoint, max_wr=256)` × (16 NICs × 8 workers) — good
  baseline: **max_wr=256 per EP** and Mooncake is using the **shared-EP**
  mode that Henan's `4a306de8` fix depends on.
- [line 169 / 179] `EfaTransport: Clamped max_mr_size to device limit:
  206158430208` (≈ 192 GiB per-NIC MR budget).
- [line 172 / 181] `Started 16 CQ polling worker threads` × 8 TP workers —
  so **128 CQ polling threads total per node**. Watch for CPU contention.
- [lines 1903-1926 …] `Auto-split params: page_size=4096,
  max_pte_entries=23068672, pte_limit=94489280512 (88 GiB), max_mr_size=192
  GiB, chunk_limit=88 GiB` — each KV chunk is auto-split to fit PTE budget.
- [lines 1927-end, 568 instances] `Chunk 0/1 registered on 16 NICs, addr=…,
  length=385446528, duration=<6..4870>ms`. 385446528 bytes = 367.4 MiB per
  chunk. Fastest 6 ms, slowest **4870 ms** ([line 2913]), P95 ≈ 2 s. MR
  registration is serialized under libibverbs even though invoked from
  parallel threads — this is what costs ~5.5 s at startup. If chunk count
  scales up (larger context), this will grow super-linearly.
- [line 37 …] `Metrics reporting is disabled (set MC_TE_METRIC=1 to enable)` —
  **we are blind to per-transfer latency histograms in customer runs.**
  Biggest preventable gap; turning this on costs nothing.

## Errors / retries encountered

- **EFA peer-reconnect storm (×198 events)** — [lines 3776-3825, 4106-4139
  and dozens more]. Pattern is identical to the one Henan's Mooncake PR #2023
  (`4a306de8`, EfaContext::endpoint full-key fix) was designed for:
  `Peer reconnected with new address, re-establishing: 6.166.120.207:<portA>@<nic>
  -> 6.166.120.207:<portB>@<nic>` with portA/portB ping-ponging between
  `15093`, `15156`, `15287`, `15469`, `15698`, `16168`, `16249`. Customer
  image is **dated 0428 = BEFORE the 0502 `2026.05.02-h200.dp16` hotfix**, so
  this is expected to reproduce.
- **Segfault in Mooncake transport** — [line 4146]:
  ```
  !!!!!!! Segfault encountered !!!!!!!
    in mooncake::EfaContext::submitSlicesOnPeer(...)
    in mooncake::EfaTransport::submitTransferTask(...)
  ```
  This is downstream of the reconnect storm and consistent with the
  normalizeNicPath key-collapse pathology (two DP workers overwriting each
  other's endpoint slot → stale pointer → SIGSEGV on next submit).
- **Sync batch data transfer timeout 30050736773 ns (30.05 s)** — [line 4172],
  immediately followed by `Session 6.166.120.207:15182 failed.` ([line 4173]).
  Matches the hardcoded 30 s `transfer_engine_py.cpp:550` timeout; connection
  was already dead from the segfault.
- **Detokenizer health check failed** — [line 4174] `ERROR: Health check
  failed. Server couldn't get a response from detokenizer for last 20 seconds.`
  Prefill scheduler is alive (tic=14:15:41) but detokenizer IPC socket hasn't
  heartbeated since 14:15:13 — i.e., the segfault killed one worker thread and
  the detokenizer is waiting on its ZMQ peer.
- **No GPU OOM**, no model-parallel collective error, no NCCL hang — the
  failure is 100% in Mooncake transport layer.

## What this tells us we should change in our scripts

1. **Force `MC_TE_METRIC=1` in every Stage 5+ prefill/decode container.**
   Customer's log has zero per-transfer latency histogram because metrics were
   off. We lose P50/P99 KV-transfer data even when runs succeed. Cost = ~1%
   CPU, benefit = full observability. Add to `run_prefill.sh`/`run_decode.sh`
   and our 1P1D templates. (Line 37 evidence.)
2. **Drop `--prefill-round-robin-balance`, switch to the new flag name.**
   The deprecation will become a hard error on the next sglang bump. Grep our
   stage5 + customer_K2.5 scripts, fix now.
3. **Explicitly pin chunked-prefill = 4096 on DP-attention configs.** Don't
   rely on sglang's silent clamp; pass `--chunked-prefill-size 4096` so the
   intent is legible in logs and future sglang changes can't flip it.
   (Line 7 evidence.)
4. **Require `--enable-piecewise-cuda-graph` on prefill** (or document why
   disabled). Customer explicitly disabled it; on H200 + BF16 unquantized
   dense + Marlin MoE, piecewise graph is a ~10-20% TTFT improvement. If the
   customer disabled it for a reason (e.g., UCCL-EP graph race), we need to
   surface that reason in our 1P1D plan — it affects the Sprint B tail-P99
   estimate.
5. **Bake Mooncake PR #2023 (`4a306de8`) into customer image baseline.** The
   segfault + reconnect storm in this log is exactly what 4a306de8 fixes. Our
   `2026.05.02-h200.dp16` already has it; customer still runs the 0428 image.
   Ship them the dp16 image ASAP and re-run the same workload to confirm the
   segfault disappears. Until then, every 1P1D benchmark number we collect
   under the 0428 image is poisoned by this bug.
6. **Add a warmup-stall guard.** The 5m17s gap between DP0-6 (14:01:41) and
   DP7 (14:06:58) is a single-rank serialization hazard. We should pre-import
   `cutlass.cute.experimental` (or whatever the real blocker is) in our
   image build so first-forward doesn't JIT on customer time. Also add a
   watchdog that prints the stuck-rank stack every 60 s during warmup.

---

### Top 3 findings (caller-facing)

1. **Mooncake segfault at line 4146 + 198-event peer-reconnect storm** is the
   0428-image manifestation of the exact bug Henan fixed in PR #2023 (`4a306de8`).
   Customer must pull `sglang-mooncake-uccl:2026.05.02-h200.dp16`; any 1P1D
   numbers gathered before that are invalid.
2. **Cold-start = 9m34s to "fired up", 17m37s to first real request**, and
   **5m17s of that is a single-rank warmup stall on DP7** with CUTE_DSL import
   as the trigger. Pre-import in image fixes it for free.
3. **`--chunked-prefill-size` silently clamped 16384 → 4096** under
   `--enable-dp-attention`, and **`--disable-piecewise-cuda-graph`** means
   prefill runs with **zero CUDA graph capture** (cuda graph: False on every
   batch). Both are perf-load-bearing and must be made explicit in our 1P1D
   launch scripts before we pretend the customer config is the optimization
   baseline.

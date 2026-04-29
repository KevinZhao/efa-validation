# Customer 1P:1D perf bench — DeepSeek-V3.1 block-FP8 on Ohio p5en H200

**Date**: 2026-04-28
**Operator**: Kevin Zhao
**Region / AZ**: us-east-2 / use2-az2 (p5en spot)
**Cluster**: gpu-cluster-ohio
**Topology**: 1 prefill pod (p5en × 1, TP=8) + 1 decode pod (p5en × 1, TP=8) + 1 LB pod + Mooncake KV over EFA
**Image stream**: `public.ecr.aws/n3l4x8f3/sglang-mooncake-{uccl,nccl}:2026.04.28-h200.2`
**Model**: `deepseek-ai/DeepSeek-V3.1` (671B params, block-FP8 w/ `weight_block_size=[128,128]`, top_k=8, 256 routed experts + 1 shared, MLA attention)
**Bench**: `sglang.bench_serving --dataset-name random --random-input-len 2048 --random-output-len 1024 --num-prompts 128 --max-concurrency 16 --warmup-requests 8`

## Why DS-V3.1 (not GLM-4.6 as originally planned)

GLM-4.6 BF16 + `--moe-a2a-backend deepep` hits `sglang 0.5.10 ep_moe/layer.py` assert
`forward_deepgemm_{contiguous,masked} is deprecated` — **upstream sglang bug, BF16 MoE + deepep is
unfixable from our side**. Documented in `feedback_sglang_0_5_10_uccl_ep_bf16_moe_broken`.
DS-V3.1 is block-FP8 (`Fp8Config`), hits the working `deprecate_flag=True` path via
`super().run_moe_core` → `Fp8MoEMethod.apply`. Also top_k=8 ≤ UCCL kNumMaxTopK=9, 688 GB fits
H200 × 8 (1128 GB).

## Results

### nccl variant — PASS

`--moe-a2a-backend none` (NCCL fake-alltoall, single-node NVLink). Bench completed cleanly:

| Metric | Value |
|---|---|
| Benchmark duration | 74.65 s |
| Completed | 128 / 128 |
| Request throughput | 1.71 req/s |
| Input throughput | 1907.9 tok/s |
| Output throughput | 884.4 tok/s |
| Total throughput | 2792.3 tok/s |
| Peak output throughput | 1349 tok/s |
| Mean TTFT | 731.9 ms |
| Median TTFT | 342.0 ms |
| P99 TTFT | 3175.3 ms |
| Mean TPOT | 15.63 ms |
| Median TPOT | 15.64 ms |
| P99 TPOT | 17.27 ms |
| Mean ITL | 15.50 ms |
| P95 ITL | 16.38 ms |
| P99 ITL | 18.17 ms |
| Max ITL | 246.8 ms |
| Mean E2E latency | 8711 ms |
| P90 E2E latency | 14679 ms |
| Concurrency (achieved) | 14.94 |

Raw log: `bench-nccl-dsv31.log`.

### uccl variant — FAIL (not because of UCCL itself)

`--moe-a2a-backend deepep` triggers DeepEP intranode path during PD-disagg warmup:

```
File "/usr/local/lib/python3.10/dist-packages/deep_ep/buffer.py", line 1038, in dispatch
    self.runtime.intranode_prepare(...)
RuntimeError: DeepEP error: CPU recv timeout
DeepEP timeout check failed: rank = 1, thread = 0, value = 1024
[2026-04-28 02:47:12] SIGQUIT received. signum=None, frame=None. It usually means one child failed.
```

PD warmup crashes before the bench client ever connects. Prefill server goes into crashloop.

**This is NOT a UCCL-EP failure**. The trace shows
`self.runtime.intranode_prepare`, which is DeepEP's **single-node P2P NVLink path** — UCCL-EP
only substitutes the **internode** path. In our 1P:1D topology all 8 TP ranks of each role sit
inside the same node, so the MoE all-to-all is fully intranode and UCCL-EP never gets called.

DeepEP's intranode NVLink P2P setup times out waiting for CPU-side handshake. Probable causes (not
further investigated):
1. sglang 0.5.10 + deep_ep combo has a startup race under PD-disagg warmup
2. deep_ep IPC SHM handle exchange failing on the host
3. UCCL's deep_ep drop-in wrapper not correctly exposing `intranode_prepare`

## Fundamental issue with this bench design

In a 1 prefill + 1 decode topology with each role running single-node TP=8, the MoE alltoall
**never goes across the network**. It's always intranode NVLink. So:

- `--moe-a2a-backend none` (nccl variant) → NCCL within single node → fine
- `--moe-a2a-backend deepep` (uccl variant) → DeepEP **intranode** → never invokes UCCL-EP kernel

**The whole A/B comparison is invalid for measuring UCCL-EP value** in this topology. A meaningful
UCCL-EP vs NCCL (or DeepEP-over-IB) comparison requires **cross-node expert parallelism**, i.e.
`ep_size > tp_size` spread across 2+ nodes (e.g., TP=8, EP=16 spread across 2 nodes, or
wide-EP like EP=64 spread across 8 nodes). That's precisely the Stage 5 §5.8 / §5.7 setup for
larger customer deployments, not the 1P:1D bench.

The customer release image `{uccl,nccl}:2026.04.28-h200.2` still differs correctly in **which
alltoall kernel** is available for cross-node EP. But a single-node TP=8 bench cannot exercise
that difference.

## Infrastructure findings (valuable even though bench didn't produce A/B delta)

Four layered fixes needed before PD-disagg bench could run cleanly on Ohio p5en:

1. **h200.0 → h200.1**: runtime image missing `libpython3.10.so.1.0` + `Python.h` → Mooncake TE
   ImportError, triton JIT fallback spam. Added `libpython3.10 python3.10-dev` apt pkgs.
2. **h200.1 → h200.2**: runtime image missing `/usr/bin/ninja` → TP worker fork JIT kernel
   compile fails. Added `ninja-build` apt pkg.
3. **sglang_router + `/health` endpoint incompatibility**: sglang_router 0.3.2 `detect_connection_mode`
   probes `/health`, which in `--disaggregation-mode prefill` blocks forever (generate canary can't
   run without paired decode). Fix: switch LB to `--mini-lb --disable-health-check`; trust
   manifest-configured URL, skip detect.
4. **Scheduler watchdog + DeepGEMM JIT**: Default `--watchdog-timeout 300`, but DS-V3.1 FP8's
   DeepGEMM JIT Pre-Compile takes 10-20 min for 16384 kernels on first startup. With
   `--skip-server-warmup`, JIT is deferred to first forward, scheduler blocks → SIGQUIT →
   crashloop every ~14 min. Fix:
   - **Remove `--skip-server-warmup`** so sglang compiles DeepGEMM kernels at startup
   - **Set `--watchdog-timeout 1800`** for safety
5. **prefetch initContainer OOM**: s5cmd `--concurrency 64` pulling 688 GB DS-V3.1 from S3 under
   32Gi memory limit was OOM-killed on first run; restart succeeded because s5cmd resumes from
   partial files. Not fatal, but increase container memory to 64Gi+ for next release.

## Files

- `manifest-uccl.yaml`, `bench-job-uccl.yaml` — rendered kustomized manifests
- `manifest-nccl.yaml`, `bench-job-nccl.yaml` — rendered kustomized manifests
- `bench-nccl-dsv31.log` — **nccl variant bench SUCCESS log** (128 prompts completed, 74.65 s)
- `warmup-uccl.log` (from earlier failed BF16 attempt on GLM-4.6, obsolete)

## Conclusions

1. **sglang 0.5.10 + Mooncake KV over EFA + NCCL alltoall + DS-V3.1 FP8** — works, numbers
   above are the first clean bench data point for the customer release image on Ohio p5en.
2. **UCCL-EP value cannot be measured in 1P:1D single-node TP=8 topology**. Need cross-node
   expert parallelism to exercise the internode all-to-all kernel that UCCL-EP replaces.
3. **Four infrastructure issues uncovered and fixed** (image deps × 2, router health-check
   semantics, scheduler warmup/watchdog interaction). Manifest
   `manifests/customer-1p1d-dsv31-ohio.yaml` now captures all fixes.

## Next steps

- **To actually compare UCCL-EP vs DeepEP-intranode/NCCL for customer**: reshape bench to 2-node
  EP (TP=8 across 2 nodes with EP=16, or single role wide-EP on 2 × p5en). This is the real
  UCCL-EP use case. Use §5.7/§5.8 Stage 5 infrastructure.
- **For GLM-4.6 BF16 + UCCL-EP**: sglang 0.5.10 BF16 MoE + deepep path is upstream-broken; file
  issue comment on sglang #16952 with DS-V3.1 FP8 prefill-mode trace as repro.
- **For customer production**: if they stay with 1P:1D single-node TP=8 topology (what this
  bench tests), the `nccl` variant is enough — UCCL-EP won't be invoked. If they plan to scale
  to cross-node EP (customer GLM5 spec has D:TP16/EP16/DPattn16 which *is* cross-node), the
  `uccl` variant matters; that needs a proper 2+ node EP bench.
- **DeepGEMM pre-compile cache**: on a fresh pod the 15 min DeepGEMM JIT is unavoidable. For
  production, run `python3 -m sglang.compile_deep_gemm --model deepseek-ai/DeepSeek-V3 --tp 8
  --trust-remote-code` during image build or persist cache to hostPath. Customer will see this
  14-20 min startup cost on every pod scale-up otherwise.

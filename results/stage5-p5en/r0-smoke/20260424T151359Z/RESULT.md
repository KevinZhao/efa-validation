# R0 · Single-Node Smoke — RESULT

**Verdict**：**PASS ✅**
**Date (UTC)**：2026-04-24
**Start → Ready → Generate**：15:55:55 → 16:18:50 → 16:21:04

---

## 1. Environment

| Item | Value |
|---|---|
| Region / AZ | us-west-2 / us-west-2c (usw2-az3) |
| Node | `i-016848633dec5b3e8` p5en.48xlarge Spot, 10.0.13.153 |
| EKS cluster | `gpu-cluster-oregon` |
| Nodegroup | `gpu-p5en-48xlarge-spot` (desired=0→1 for R0) |
| Image | `788668107894.dkr.ecr.us-west-2.amazonaws.com/yanxi/sglang-mooncake:v2` (digest `aa7f2f6f5f2f1c15…`) |
| Model | Qwen3-Next-80B-A3B-Instruct FP8 (152 GB on FSx Lustre 2.15) |
| Model arch | `qwen3_next` (Qwen3NextForCausalLM), hybrid SSM+MoE |
| SGLang config | TP=8, ctx=131072, mem-frac=0.85, chunked=8192, fp8-backend=cutlass, attn=fa3, --skip-server-warmup |
| FSx | `fs-079832d056597a33b` / `/models` via PVC `yanxi-model-cache` (RWX, Lustre 2.15, cross-AZ from usw2-az2) |

---

## 2. Pre-flight (all PASS)

| Check | Result |
|---|---|
| Mooncake pip version | **0.3.10.post2** ✅ |
| Henan EFA SO symbols (EfaTransport / libfabric-efa / Chunk-registered) | **103 hits** ✅ |
| MC_LEGACY_RPC_PORT_BINDING env support | Present ✅ |
| SGLang rdma hardcode point (`"rdma",` @ line 195) | Intact; launcher sed target valid ✅ |
| SGLang version | **0.5.10** ✅ |

Image verified as the same Mooncake + Henan EFA PR stack validated in Stage 3/4.

---

## 3. Pass criteria

| # | Criterion | Observation | Pass |
|---|---|---|---|
| 1 | FSx Lustre PVC `yanxi-model-cache` mounted and readable | config.json found; 152 GB Qwen3-Next weights loaded into GPU mem | ✅ |
| 2 | EFA 16 NIC visible in pod | Not explicitly dumped inside this R0 pod (launcher skipped fi_info branch since single-node), but host-side `/sys/class/infiniband` shows 16 uverbs* + 16 rdmap*s0 | ✅ |
| 3 | SGLang 0.5.10 model load passed | 8 TP ranks initialised; no traceback; `/get_model_info` returns 200 with `model_type=qwen3_next`, `is_generation=true` | ✅ |
| 4 | Readiness probe passes | Pod `1/1 Running` at 16:18:57 UTC | ✅ |
| 5 | 1-prompt `/generate` returns valid tokens | `"The capital of France is Paris. The capital of Germany is Berlin. …"` (see §4) | ✅ |

**Overall: 5/5 PASS.**

---

## 4. Generate probe

Request:
```json
{"text":"The capital of France is","sampling_params":{"max_new_tokens":32,"temperature":0}}
```

Response (trimmed):
```json
{
  "text": " Paris. The capital of Germany is Berlin. The capital of Italy is Rome. The capital of Spain is Madrid. The capital of the United Kingdom is London.",
  "meta_info": {
    "finish_reason": {"type":"length","length":32},
    "prompt_tokens": 5,
    "completion_tokens": 32,
    "e2e_latency": 0.2964477390000866
  }
}
```

- **e2e latency**: **296 ms** for 5 in → 32 out tokens (greedy)
- Answer semantically correct
- Output includes both `text` and `output_ids` (model integrated tokenizer/detokenizer cleanly)

---

## 5. Timing breakdown (wall clock, UTC)

| Event | Timestamp | Δ from previous |
|---|---|---|
| `desiredSize=1` eks update | 15:15:43 | — |
| Spot instance `running` (az3) | 15:15:59 | 16 s |
| kubelet active + 8 GPUs + 16 EFA NIC | 15:18:58 | 3 min |
| **Node fully ready** | **15:18:58** | — |
| Preflight pod completed (image cached) | 15:55:55 | — |
| R0 pod applied, `Running` | 15:55:55 | — |
| TP distributed init end | 15:56:54 | 59 s |
| Load weight begin | 15:56:55 | 1 s |
| MoE kernel config loaded | 16:18:21 | 21 min 26 s (weight load + Triton/Inductor JIT) |
| CUDA graph capture end (52 batch sizes × 30 s total) | 16:18:48 | 27 s |
| **Server ready ("fired up and ready to roll")** | **16:18:50** | — |
| First `/get_model_info` 200 OK | 16:18:57 | 7 s |
| First `/generate` 200 OK (296 ms e2e) | ~16:21:04 | — |

**Total cold start (pod created → ready)**: **22 min 55 s**.

Dominant cost: Triton MoE kernel JIT — Qwen3-Next hybrid MoE has E=512 N=64 on H200, no pre-cached config in sglang 0.5.10 → fell back to triton 3.4.0 and JIT-compiled. This is a one-time per image/HW combo; subsequent cold starts should hit the kernel cache.

---

## 6. Known warnings (non-blocking)

1. `Config file not found ... triton_3_5_1/E=512,N=64,NVIDIA_H200.json → fallback to triton_3_4_0` — tuning file missing, performance "might be sub-optimal" (per SGLang warning). Not fatal; would only matter for measured throughput numbers. For R0 (functional smoke) ignored.
2. `torch_dtype` deprecation spam — transformers warning, cosmetic.
3. `Endpoint '/get_model_info' is deprecated` — we should switch to `/model_info` in later runs; for R0 both work.

---

## 7. Cost

- p5en.48xlarge Spot ≈ **$10.7/h**
- Wall clock from scale-up (15:15) to generate success (16:21) ≈ **1 h 6 min**
- Estimated spend: **~$11.8**
- Post-R0 cleanup returns node to Spot pool immediately.

---

## 8. Next actions

- Clean up: delete R0 pod + scale NG desired=0 (do BEFORE moving to R1a, to avoid paying idle)
- Proceed to R1a: Kimi-K2 1P:1D on 2 × p5en — requires Kimi-K2 `.prefetch-complete` on Oregon FSx (currently blocked by sentinel; need to reconsider since Oregon is now the active region)

### ⚠️ Oregon FSx Kimi-K2 sentinel problem (**RESOLVED 2026-04-25**)

Earlier (14:10 UTC) we placed a `.prefetch-complete` + `.SKIPPED` sentinel on Oregon's `/fsx/Kimi-K2-Instruct-0905/` to save space for the (cancelled) R6 V4 Pro. Now that we're running the main R1 series in Oregon, **that sentinel blocks Kimi-K2 download and blocks R1a**. Decision needed:
- Remove sentinel + delete V3.1 from Oregon (recover 338 GB) to make room for Kimi-K2 (959 GB)? — Oregon FSx has 883 GB free, Kimi-K2 is 959 GB. Would need to delete V3.1 (currently 351 GB, not prefetched elsewhere).
- OR: mirror R0 path and fall back to Ohio for R1a (requires p5en capacity in Ohio; SPS was 3 at last check).

Recommended: re-scan SPS cap=2 for R1a before committing either way.

**Resolution (2026-04-25 03:12 UTC)**: SPS cap=2 rescan → **us-east-2a=9, usw2-az3=4**. R1a switched back to Ohio, which has full Kimi-K2 weights on FSx. Oregon Kimi-K2 sentinel left as-is (no longer load-bearing). See §10 below + `results/stage5-p5en/r1a-kimi-k2-1p1d/20260425T033552Z/`.

---

## 9. Artifacts

- `STEPS.md` — step-by-step execution log
- `preflight-output.txt` — raw preflight pod log
- `RESULT.md` — this file

---

## 10. Post-R0 reconnaissance (16:25–03:35 UTC spanning cleanup → R1a prep)

### 10.1 SPS rescan (cap=2 for R1a)

| Region | AZ | Score |
|---|---|---|
| **us-east-2** | **use2-az1** | **9** |
| us-west-2 | usw2-az3 | 4 |
| us-east-2 | use2-az2 | 3 |
| (others) | — | 1 |

Capacity flipped back to Ohio. R1a should run in Ohio (closes the Oregon-Kimi-K2 sentinel problem automatically).

### 10.2 Ohio FSx content (probed via busybox pod on newly-launched p5en)

Probe attempt 1/2 on Ohio **eks-utils arm64 (m7g.large)**: failed — pod stuck in ContainerCreating 5+ min, empty event log past "Scheduled". Suspect: FSx CSI Lustre mount misbehaves on arm64 (lustre client compat on AL2023 arm?). Not investigated further; worked around with nodeSelector.

Probe on **p5en amd64**: SUCCESS, completed in 61 s. Findings:

```
=== Ohio FSx fs-0e7e1313a9c964d34 (discovered 4.4 TiB, not 2.4 as expected) ===
151.6G  /fsx/Qwen3-Next-80B-A3B-Instruct
220.4G  /fsx/Qwen3-235B-A22B-Instruct-2507-FP8
641.8G  /fsx/DeepSeek-V3.1
665.1G  /fsx/GLM-4.6
805.9G  /fsx/DeepSeek-V4-Pro          <- unexpected, kept despite R6 cancellation
959.2G  /fsx/Kimi-K2-Instruct-0905    <- KIMI-K2 COMPLETE (63 shards)
Total used: 3.4 TB / 1012 GB free
```

- **Kimi-K2 is fully prefetched in Ohio** — R1a is unblocked.
- **DSv4-Pro (806 G) is also complete** in Ohio; survives for a future R6 if SGLang V4 support lands.
- **Ohio FSx is actually 4.4 TiB** (not 2.4). Either someone grew the FS after Day 0 or the 2.4 figure was wrong; need to reconcile with RUNBOOK later.

### 10.3 Decision: R1a runs on Ohio

- Ohio SPS = 9 @ cap=2, all weights present, FSx 4.4 TB has capacity for remaining runs.
- Oregon stays as backup only. Oregon FSx Kimi-K2 sentinel **no longer needs removal** (Oregon is not on the R1 path).
- Ohio p5en NG scaled to `desiredSize=2` at 03:28 UTC (update id `f8affefa-d9be-33cb-bf34-5620a648c5fd`); first node `i-025388ac45366a78d` @ 10.1.11.4 already Ready in us-east-2a at 03:27.

Next R1a steps live in `results/stage5-p5en/r1a-kimi-k2-1p1d/<new-stamp>/STEPS.md`.

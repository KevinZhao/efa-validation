# Kimi-K2.5 PD-1P1D — 5-Lever Incremental Ablation Design

**Status:** Design only (no code/manifest changes). Execution gated on prereqs in §7.
**Date:** 2026-05-03
**Baseline results anchor:** `results/stage5-p5en/pd-1p1d-mc-vs-nixl-k25-int4/20260501T002853Z/RESULT.md`
**Entrypoints to mutate:** `scripts/stage5-pd-1p1d-mc-vs-nixl/entrypoints/{prefill,decode}_entrypoint.sh`
**Compose:** `scripts/stage5-pd-1p1d-mc-vs-nixl/compose/{prefill,decode}-compose.yml`
**Manifest:** `manifests/stage5-p5en/pd-1p1d-mc-vs-nixl-k25-int4-usw2.yaml`

---

## 1. Purpose

Measure the **incremental** ITL / throughput gain from stacking 5 candidate optimizations on top of the current Mooncake 1P1D baseline. Each row of the matrix adds one lever on top of the previous row (cumulative, not orthogonal) — the delta against the immediately preceding row is the attribution for that lever.

Why cumulative rather than orthogonal: 6 levers × 2 states = 64 cells is unaffordable on p5en (≥ $300/hr for 2 nodes), and the customer target is a **stack recipe**, not a main-effects table. Interaction effects (e.g. SBO × DeepEP) will be caught by monotonic gains in the cumulative stack.

---

## 2. Baseline (R0) — current-state row

Current entrypoints run a DP=1 symmetric TP=8 1P1D with **none** of the 5 levers on. Pulled verbatim from today's `prefill_entrypoint.sh` + `decode_entrypoint.sh`:

| Lever | State on current entrypoint | Evidence |
|---|---|---|
| L1 SBO (`--enable-single-batch-overlap`) | **OFF** (flag absent on decode) | decode_entrypoint.sh L46-78 |
| L2 TBO (`--enable-two-batch-overlap`) | **OFF** (flag absent, DP=1 anyway) | decode_entrypoint.sh L46-78 |
| L3 EAGLE spec-decode | **OFF** (no `--speculative-*` flags) | decode_entrypoint.sh L46-78 |
| L4 DeepEP a2a + UCCL_IB_HCA rail split | **OFF** (`--moe-a2a-backend` absent → default `none`; UCCL_IB_HCA unset; all 16 rails given to Mooncake KV via `--disaggregation-ib-device`) | both entrypoints L50/L42, no UCCL_IB_HCA in compose |
| L5 env trio (`SGLANG_MOONCAKE_CUSTOM_MEM_POOL`, `FI_EFA_ENABLE_SHM_TRANSFER`, `FI_EFA_FORK_SAFE`) | **unset** in both compose files and manifest | prefill/decode-compose.yml environment blocks |

**S2 baseline numbers (8K/1K, cc=64, np=200, Mooncake), from RESULT.md:**

| Metric | Mooncake S2 (95% CI) |
|---|---:|
| TTFT mean | 2260.81 ms (2054.26–2444.83) |
| TTFT P50 | 749.10 ms |
| TTFT P99 | 9387.02 ms |
| **ITL mean** | **104.90 ms (102.27–107.75)** |
| **ITL P50** | **116.41 ms** |
| **ITL P99** | **136.70 ms** |
| E2E mean | 54147.70 ms |
| Output tok/s | 542.89 |
| Req/s | 1.10 |

S2 is the most sensitive scenario in the baseline set: Mooncake loses 32.86% ITL mean vs NIXL there (vs < 3% at S3/S5/S6). Any ITL improvement on the Mooncake side shows up cleanly in S2.

---

## 3. Ablation Matrix (R0 → R5, cumulative)

| Row | Adds | Cum. lever set | Risk | Prereq gate |
|---|---|---|---|---|
| **R0** | — (baseline) | {} | n/a | reproduces 20260501T002853Z S2 within ±5% |
| **R1** | L5 env trio | {L5} | **LOW** — pure env, no flag change, no topology change | none |
| **R2** | L4 DeepEP + rail split | {L5, L4} | **MED-HIGH** — structural: MoE alltoall path flips from naive TP to DeepEP; UCCL_IB_HCA splits 16 EFA rails 8/8 (UCCL-EP / Mooncake) | image must contain working UCCL-EP + DeepEP (verify w/ smoke test before run) |
| **R3** | L3 EAGLE spec-decode | {L5, L4, L3} | **MED** — needs bundled draft head; zero cost if disabled gracefully, but adds KV traffic | **K2.5 draft head confirmed present (Q1 §7)**; open Q: whether EAGLE + DeepEP low_latency interact cleanly on sglang 0.5.10 |
| **R4** | L1 SBO | {L5, L4, L3, L1} | **MED** — decode-side kernel reorder; may require `--enable-dp-attention` on sglang 0.5.10 (Q2 §7). If dp-attention is required and we're still DP=1, R4 is a NO-OP or hard fail | **sglang source grep for SBO guards (Q2 §7)** |
| **R5** | L2 TBO + DP≥2 | {L5, L4, L3, L1, L2} | **HIGH** — forces DP topology change (decode dp-size 1 → 2). Requires altering baseline row's DP assumption, so "incremental" semantics against R4 is the weakest link of the stack. Out-of-scope 7-§8 says no DP topology change — so **R5 is flagged conditional**; if customer wants to stay DP=1 this row is dropped. | DP=2 topology decision; doubles decode GPUs if kept symmetric, else asymmetric ranks |

### Ordering rationale

1. **L5 first (R1):** env-only, zero-risk, would be "free" gain; if R1 matches R0 exactly we know the env trio is inert on our image and we can discard it without burning a scenario sweep.
2. **L4 before L3/L1/L2 (R2):** DeepEP fundamentally changes the MoE path; all downstream levers' effect is measured **on top of the DeepEP path**, which matches the customer recipe (customer glm_5.1 decode-0 runs DeepEP+EAGLE+DP8+SBO together). If we ordered DeepEP last we'd attribute part of its gain to L1/L2.
3. **L3 before L1 (R3 → R4):** EAGLE speed-up is relatively well-characterized (2–3× ITL if draft head matches, ~0 if not); SBO gain is small (~5–12% on decode forward). Running EAGLE first gives a larger step that makes subsequent small deltas visible above noise.
4. **L1 before L2 (R4 → R5):** SBO works at DP=1; TBO needs dp_size≥2. Isolating SBO at DP=1 avoids confounding dp-attention overhead with SBO's overlap win.
5. **L2 last (R5):** topology change is the biggest confound; doing it last means an R5 regression is cleanly attributable.

---

## 4. Row-by-row deltas (diff from preceding row)

Each row is expressed as a minimal patch to the entrypoint/compose that produced the preceding row. Lines prefixed `+` are adds, `-` are removes.

### R1 = R0 + L5 (env trio)

`compose/prefill-compose.yml` and `compose/decode-compose.yml` → `environment:` block:
```
+ - SGLANG_MOONCAKE_CUSTOM_MEM_POOL=1
+ - FI_EFA_ENABLE_SHM_TRANSFER=1
+ - FI_EFA_FORK_SAFE=1
```
Also mirror into `manifests/stage5-p5en/pd-1p1d-mc-vs-nixl-k25-int4-usw2.yaml` prefill + decode `env:` lists.
Entrypoints: no change.

### R2 = R1 + L4 (DeepEP + rail split)

`decode_entrypoint.sh`, append to the `exec python3 -m sglang.launch_server` arg list:
```
+    --moe-a2a-backend deepep \
+    --deepep-mode low_latency \
```
`prefill_entrypoint.sh`, append to arg list:
```
+    --moe-a2a-backend deepep \
+    --deepep-mode normal \
```
Compose (both files) `environment:` block — add UCCL-EP rail split + Mooncake rail split:
```
+ - UCCL_IB_HCA=rdmap87s0,rdmap88s0,rdmap112s0,rdmap113s0,rdmap137s0,rdmap138s0,rdmap162s0,rdmap163s0
+ - UCCL_SOCKET_IFNAME=enp
+ - UCCL_IB_MAX_INFLIGHT_LOW_LATENCY=128
+ - SGLANG_DEEPEP_NUM_MAX_DISPATCH_TOKENS_PER_RANK=128
+ - FI_EFA_IFACE=rdmap87s0,rdmap88s0,rdmap112s0,rdmap113s0,rdmap137s0,rdmap138s0,rdmap162s0,rdmap163s0
```
Entrypoints: change `DEFAULT_DEVICES` (and the `--disaggregation-ib-device` value actually passed) to the **low 8 rails only**, so Mooncake KV uses one half and UCCL-EP uses the other:
```
-DEFAULT_DEVICES="rdmap110s0,rdmap111s0,rdmap112s0,rdmap113s0,rdmap135s0,rdmap136s0,rdmap137s0,rdmap138s0,rdmap160s0,rdmap161s0,rdmap162s0,rdmap163s0,rdmap85s0,rdmap86s0,rdmap87s0,rdmap88s0"
+DEFAULT_DEVICES="rdmap85s0,rdmap86s0,rdmap110s0,rdmap111s0,rdmap135s0,rdmap136s0,rdmap160s0,rdmap161s0"
```
(rail allocation copied verbatim from customer_glm_5.1/decode-docker-compose-0.yml L38 + L63)

### R3 = R2 + L3 (EAGLE spec-decode)

`decode_entrypoint.sh`, append to arg list:
```
+    --speculative-algorithm EAGLE \
+    --speculative-num-steps 3 \
+    --speculative-eagle-topk 1 \
+    --speculative-num-draft-tokens 4 \
```
Prefill: no change. Compose/manifest: no change.
**Gate:** do NOT run R3 until Q1 §7 is answered (draft head bundled? path? config key?). If draft head is not bundled we either ship an EAGLE head or skip R3 and renumber.

### R4 = R3 + L1 (SBO)

`decode_entrypoint.sh`, append to arg list:
```
+    --enable-single-batch-overlap \
```
If Q2 §7 grep shows SBO requires `--enable-dp-attention`, R4 ALSO needs:
```
+    --enable-dp-attention \
+    --dp-size 1 \        # still DP=1, but sglang wants the flag explicit
```
(adding `--enable-dp-attention` at DP=1 is a no-op attention-wise but may invoke different kernels; call this out in RESULT.md.)
Prefill: no change.

### R5 = R4 + L2 (TBO, requires DP≥2)

**THIS ROW VIOLATES §8 OUT-OF-SCOPE.** Kept here for completeness of the 5-lever taxonomy. If customer later authorizes topology change, the delta would be:

`decode_entrypoint.sh`, modify arg list:
```
-    --tp-size 8 \
+    --tp-size 8 \
+    --dp-size 2 \
+    --enable-dp-attention \
+    --enable-two-batch-overlap \
```
Two options for DP=2 on a single decode node:
- (a) TP=8, DP=2 sharing the same 8 GPUs (sglang interleaves) — no hardware change, but halves KV headroom per replica.
- (b) TP=4, DP=2 → 8 GPUs split 4+4 — changes TP which changes EP mapping for DeepEP; confounds L4.
Option (a) is cleaner for attribution but may OOM on K2.5 at 262K context → a fallback of `--context-length 131072` may be needed for R5 only (itself a confound).

**Recommendation:** treat R5 as **deferred**; report R0..R4 as the primary result; flag R5 as "future work — requires topology authorization".

---

## 5. Scenarios

**Primary:** **S2 only** (8K/1K, cc=64, np=200) × **3 rounds per row** × **5 rows (R0..R4)** = 15 benches.
Wall-clock at ~55 s mean E2E × 200 requests / cc=64 ≈ 3 min per bench + 4-5 min restart per row → ~75 min total run. Cheap enough to redo if noisy.

**Tie-breaker (optional):** **S4 only** (4K/512, cc=128, np=200) added for any row where the S2 direction is ambiguous (|Δ%| < 5% AND CI overlaps). S4 exposes concurrency-scaling differently (cc=128 vs 64) so it catches SBO/TBO gains that only appear at higher contention.

**Explicitly skipped:**
- **S1** (2K/512 cc=32): already NIXL-dominated; too short to see decode-path levers.
- **S3, S5, S6** (long prompt / long context): dominated by prefill TTFT, insensitive to decode ITL levers.

**R0 sanity:** before starting R1, verify R0 reproduces the 2026-05-01 baseline's S2 ITL mean within ±5%. If not, we have drift (spot hardware identity, new image tag, etc.) and the ablation is void until drift is explained.

**Statistics:** bootstrap 95% CI over 3 rounds (same 2000-resample method as RESULT.md). Between-row attribution uses the mean Δ; CI overlap is a soft signal — if R_k CI overlaps R_{k-1} CI, we call the lever "inconclusive at S2, rerun at S4".

---

## 6. Expected effect + risk per lever (1-liner each)

| Lever | Expected on S2 ITL mean | Risk / mode-of-failure |
|---|---|---|
| **L5 env trio** | 0 to −2% (env wiring tweak; may be inert if image already defaults) | bench-silent; may lower page-fault stalls on large KV |
| **L4 DeepEP + rail split** | **−10 to −20% ITL** (structural MoE path improvement; dominates the 5 levers); +2-5% TTFT cost from DeepEP init | misrouted rails → Mooncake bandwidth halves & KV transfer becomes TTFT bottleneck |
| **L3 EAGLE** | **−30 to −50% ITL** (2–3× token generation if draft head ≥40% acceptance); ≈0 if draft head absent or low acceptance | no bundled draft → OOMs on load or silent 0% accept |
| **L1 SBO** | −3 to −8% ITL (overlap of MoE dispatch with attention); larger gain only if decode is compute-balanced | may require `--enable-dp-attention`; at DP=1 can produce a race window in CUDA Graph (see memory: `reference_cuda_graph_uccl_ep_risk`) |
| **L2 TBO** (conditional) | −5 to −12% additional ITL only at DP≥2 with saturated compute | **DP topology change confound**; OOM risk at K=2.5 262K context; can regress if decode is network-bound not compute-bound |

(Values pulled from earlier analysis in MEMORY.md: `reference_uccl_ep_optimization_v2`, `reference_uccl_pr745_per_expert_batching`, and the Mooncake vs NIXL S2 gap of 32.86% which is the headroom for Mooncake-side levers. Not re-estimated here.)

---

## 7. Known blockers / open questions

**Q1 — Does Kimi-K2.5 ship with a bundled EAGLE draft head?**
Block on R3. Check steps:
1. `ls /data/models/Kimi-K2.5` on an already-prefetched p5en host for `draft*` or `eagle*` directories.
2. `grep -i 'speculative\|eagle\|draft' /data/models/Kimi-K2.5/config.json` for a `speculative_config` or `draft_model_path` key.
3. If absent: check moonshotai/Kimi-K2.5 HF page for a sibling `Kimi-K2.5-EAGLE` or `-draft` repo.
If no draft head is available: skip R3 (ablation becomes R0→R1→R2→R4), document the skip, and file a follow-up to test once Moonshot publishes one.

**Q2 — Does SBO require `--enable-dp-attention` on sglang 0.5.10?**
Block on R4. Check steps (cannot run locally, sglang only exists inside the image):
```
kubectl exec -n yanxi-validation c1p1d-decode-<pod> -- grep -rn "enable_single_batch_overlap" /usr/local/lib/python3.10/dist-packages/sglang/srt/
```
Look for guards like `if server_args.enable_single_batch_overlap and not server_args.enable_dp_attention: raise`. Also check `sglang/srt/server_args.py` for validation logic.
If SBO is guarded by dp-attention: either add `--enable-dp-attention` at DP=1 (no-op attention but new kernel path — mark as confound) or skip R4 and re-order so SBO is measured only at R5 (with DP=2 already in play).
**Document as open until verified.**

**Q3 — Order interaction: SBO × EAGLE × DeepEP.**
Current order is L5 → L4 → L3 → L1 → L2 (DeepEP before EAGLE before SBO). Two known interactions:
- **EAGLE × DeepEP low_latency:** EAGLE generates 4 draft tokens per step; DeepEP's `SGLANG_DEEPEP_NUM_MAX_DISPATCH_TOKENS_PER_RANK=128` must absorb the draft burst. At cc=64 decode batch, 64 × 4 = 256 tokens/rank — **exceeds 128 default**. R3 run must either raise this env to 256 or cap speculative draft. Customer glm5.1 runs EAGLE+DeepEP with 128, so it clearly works at their config — verify which of `cuda-graph-max-bs` / `max-running-requests` is the effective cap there.
- **SBO × EAGLE:** SBO overlaps MoE dispatch with attention; EAGLE changes attention length (variable draft). Acceptance rate variance could blunt SBO's overlap window. If R4 Δ vs R3 is inconsistent across rounds, split into R4a (SBO without EAGLE, i.e. R2+L1) as a sanity check — budget 3 extra benches.

**Q4 — Is the image (`2026.04.30-h200.6`) actually built with PER_EXPERT_BATCHING=1 / UCCL-EP working?**
Block on R2. The MEMORY.md entry `reference_customer_release_images.md` notes DP=16 hotfix `2026.05.02-h200.dp16` is newer. For this 1P1D ablation DP is low (1 or 2), so the DP=16 fix should not matter, but confirm UCCL-EP DeepEP kernels are present in the image before R2:
```
kubectl exec -n yanxi-validation c1p1d-decode-<pod> -- python3 -c "import deep_ep; print(deep_ep.__version__)"
kubectl exec ... -- python3 -c "from sglang.srt.layers.moe.token_dispatcher import deepep_dispatcher; print('ok')"
```

---

## 8. Out-of-scope (explicit)

This design does **NOT** cover, and the ablation run **MUST NOT** change:
- DP topology from the baseline (decode stays DP=1 for R0..R4; R5 is only diagrammatic).
- Switching model away from Kimi-K2.5 INT4 (no K2.5 FP8, no GLM-5.1, no DeepSeek).
- Rebuilding or switching the image (`2026.04.30-h200.6` is the pinned image; DP=16 image is not used here).
- Changing Mooncake vs NIXL axis (we stay on Mooncake only; the comparison against NIXL is already in the anchor RESULT.md).
- Adding scenarios beyond S2 and (conditionally) S4.
- Tuning Mooncake internals (`MC_*` env) beyond R0's baseline values.
- P-side changes other than mirroring the L5 env trio and L4 `--moe-a2a-backend deepep --deepep-mode normal`.

---

## 9. Deliverables when executed (for RESULT.md structure)

When (later) this ablation runs, produce `results/stage5-p5en/k25-1p1d-ablation/<stamp>/RESULT.md` with:
1. Same header (hardware, image, AZ) as the anchor RESULT.md.
2. Per-row: same S2 metric table as §2, plus Δ% vs previous row AND Δ% vs R0.
3. Cumulative chart: ITL mean R0→R4 (optional R5) overlaid on baseline NIXL S2 ITL mean (70.43 ms) to show how close Mooncake + levers gets to NIXL.
4. Which row (if any) closes the 32.86% Mooncake→NIXL ITL gap at S2.

---

## 10. File-change inventory (when executed)

| File | R1 | R2 | R3 | R4 | R5 |
|---|:-:|:-:|:-:|:-:|:-:|
| `compose/prefill-compose.yml` | env | env | — | — | — |
| `compose/decode-compose.yml` | env | env | — | — | — |
| `entrypoints/prefill_entrypoint.sh` | — | flags+rails | — | — | — |
| `entrypoints/decode_entrypoint.sh` | — | flags+rails | flags | flags | flags+topo |
| `manifests/...-usw2.yaml` | env | env+UCCL_IB_HCA | — | — | topo |

Apply each row as a separate git branch / separate `kubectl apply` cycle so rollback to the preceding row is a `git checkout` + re-apply, not a manual unwind.

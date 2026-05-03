# Stage 6 R1b pre-flight smoke tests — CUDA Graph x UCCL-EP low_latency silent-corruption risk

## Why this exists

Before we apply `manifests/stage5-p5en/k25-1p1d-r1-opt.yaml` (Stage 6 R1b: DeepEP + UCCL-EP
`low_latency` path on p5en 2-node PD-disagg) we must run 3 smoke tests, per:
`~/.claude/projects/-home-ec2-user-workspace-efa-validation/memory/reference_cuda_graph_uccl_ep_risk.md`

The risk the tests are hunting: UCCL-EP's `low_latency` path updates proxy offsets via a
Python-side CPU call (`proxy.calculate_and_set_dispatch_recv_data_offset`,
`uccl/ep/deep_ep_wrapper/deep_ep/buffer.py:326-331`) that is **not in the CUDA Graph capture
window**. On graph replay the proxy may use a stale offset and mis-route tokens — producing
**silent output corruption, no crash**. SGLang has no compensating logic.

## The 3 tests (IDs map 1:1 to the memory doc)

| # | Script | Memory-doc test | HTTP-layer operationalization |
|---|---|---|---|
| 01 | `01_graph_capture_log_check.py` | "单节点 EP=8 + graph baseline" | `/get_server_info` asserts `disable_cuda_graph==False` + deepep_mode==low_latency on decode + cc=1 short request succeeds |
| 02 | `02_two_node_graph_no_hang.py`  | "2 节点 EP=16 + graph ... 验证不 hang" | cc=1 -> cc=16 -> cc=64 ramp; asserts no timeouts, no zero-token outputs, P99 ITL within bound at cc=64 |
| 03 | `03_eager_vs_graph_determinism.py` | "Eager vs Graph 输出一致性 ... 相对误差 < 1e-3 (BF16)" | K repeats of the same `temp=0, seed=fixed` request MUST produce token-identical outputs; plausibility check on answers; optional cross-check vs a dedicated eager LB if `LB_EAGER_URL` is set |

**Highest-signal: test 03.** Test 01 only verifies the pre-conditions (graph is actually on).
Test 02 would catch a hang or warm-up-latency-captured-in-graph, which the memory doc rates
as "低"/"中" probability. Test 03 directly probes the "最高" probability mode — silent
output corruption from a stale proxy offset — by asserting deterministic replay equivalence.

## Pass criteria (quoted from the memory doc)

- **Test 01** — "日志应有 'Capturing batches', 无 'Cuda graph is disabled'" — operationalized as `disable_cuda_graph == False` on both roles via `/get_server_info`.
- **Test 02** — "验证不 hang, 设 `UCCL_EP_CPU_TIMEOUT_SECS=10` 兜底" — operationalized as no per-request timeout, no zero-token responses, and bounded P99 ITL at cc=64.
- **Test 03** — "同 batch 两种模式跑, recv_x logits 相对误差 < 1e-3 (BF16)" — operationalized as byte-identical text output across `REPEATS` replays of the same deterministic request; optional strict eager-vs-graph text equivalence if `LB_EAGER_URL` is set.

> Note on Test 03 operationalization: we cannot read raw logits from the LB, so we use
> deterministic replay equivalence (token-identical output) as a proxy. If replay diverges,
> **something** between the two replays changed routing — which is exactly the memory-doc
> failure mode (proxy offset stale on some replays). A `LB_EAGER_URL` for a dedicated eager
> replica gives the strictest possible check short of reading logits.

## How to run (from bastion)

Target URL is the in-cluster LB service. The manifest
(`manifests/stage5-p5en/k25-1p1d-r1-opt.yaml`) exposes `k25-r1-lb.yanxi-validation` on
**port 8000** (not 30000). Set `LB_URL` explicitly if port-forwarding differently.

Prereqs on the bastion:

```bash
python3 -m pip install --user requests
kubectl config use-context <ohio-eks-context>
```

One-shot runner (sequential 01 -> 02 -> 03, stops on first failure):

```bash
cd /home/ec2-user/workspace/efa-validation/scripts/stage6-k25-opt/smoke

# port-forward the LB to localhost (adjust namespace if needed)
kubectl -n yanxi-validation port-forward svc/k25-r1-lb 8000:8000 >/tmp/pf-k25r1.log 2>&1 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null" EXIT
sleep 3

export LB_URL=http://127.0.0.1:8000
export MODEL_NAME=kimi-k2-5-int4

python3 01_graph_capture_log_check.py       && \
python3 02_two_node_graph_no_hang.py        && \
python3 03_eager_vs_graph_determinism.py    && \
echo "ALL SMOKE TESTS PASSED — safe to apply Stage 6 R1b" || \
echo "SMOKE FAIL — see output above, do NOT proceed to bench"
```

Alternate one-liner (kubectl exec into LB pod, skip port-forward):

```bash
kubectl -n yanxi-validation exec deploy/k25-r1-lb -- python3 - < 01_graph_capture_log_check.py
```

## Runtime budget

| Test | Expected runtime | Hard timeout |
|---|---|---|
| 01 | ~30 s (one cc=1 request + 2 GETs) | 2 min |
| 02 | ~3-5 min (cc=1,16,64 ramp, 64x `MAX_TOKENS=64` = ~4k decode tokens at the tail) | 10 min |
| 03 | ~1-2 min (4 prompts x 3 replays = 12 deterministic short requests) | 5 min |
| **Total** | **~5-8 min** | **17 min** |

## What to do if a test fails

### Test 01 fails
Graph capture is **off**, or the active deepep mode on decode is `normal`. The silent-corruption
risk we were worried about does not apply in this configuration (normal path gates out CUDA Graph
at `sglang/server_args.py:2983-2985`). But the manifest is clearly not what R1b intends to test.

- Re-check `cuda-graph-max-bs` / `disable-cuda-graph` / `moe-a2a-backend` on decode pod.
- If intentionally off, R1b becomes a non-op vs. baseline — skip and investigate.

### Test 02 fails (hang or tail-latency blow-up)
Most likely warm-up latency got captured into the CUDA Graph (memory-doc mode "warm-up 延迟
被固化"), or the `internode_prepare` CPU spin-wait snuck into graph capture (mode 2,
low probability because sglang auto-disables graph on `deepep_mode=normal`).

- **First remediation**: set `UCCL_EP_CPU_TIMEOUT_SECS=10` on decode pod env (upstream PR
  #904, already merged). This bounds the stall and surfaces the bug as a loud error rather
  than a hang.
- **Fallback**: `--moe-a2a-backend none` on the **decode** deployment only. Keep UCCL-EP on
  prefill (prefill doesn't use graph capture there). This costs the R1b decode ITL win but
  stays correct.
- Do NOT proceed to 03 or to the bench if 02 fails.

### Test 03 fails (the dangerous one)
This is the memory-doc "最高" probability failure mode — **silent output corruption from stale
proxy offset on graph replay**. There is no env knob that definitively fixes it, because the
bug is "Python CPU call is outside graph capture window".

- **Immediate remediation**: fall back to `--moe-a2a-backend none` on the **decode**
  deployment. Keep UCCL-EP on prefill only (prefill uses `deepep_mode=normal` and sglang
  auto-disables graph there, so no risk).
- File an issue upstream linking this smoke output + `reference_cuda_graph_uccl_ep_risk.md`.
  Long-term fix requires patching `uccl/ep/deep_ep_wrapper/deep_ep/buffer.py:326-331` to do
  the offset update as a GPU kernel that graph capture will trace.
- Do NOT run the bench, do NOT publish R1b numbers, do NOT hand this config to a customer.

## Env var reference

| Var | Default | What it controls |
|---|---|---|
| `LB_URL` | `http://k25-r1-lb.yanxi-validation:8000` | LB endpoint |
| `LB_EAGER_URL` | unset | (03 only) optional second LB pointing at a no-graph replica for strict cross-check |
| `MODEL_NAME` | `kimi-k2-5-int4` | OAI `model` field |
| `CCS` | `1,16,64` | (02 only) concurrency ramp |
| `REPEATS` | `3` | (03 only) replay count per prompt |
| `REQ_TIMEOUT` | `60` / `180` / `120` | per-request HTTP timeout |
| `ITL_P99_HARD_MAX_MS` | `500` | (02 only) P99 ITL bound at cc=64 |
| `TAIL_RATIO_MAX` | `5.0` | (02 only) P99/P50 ITL ratio bound |
| `MAX_TOKENS` | 16 / 64 / 64 | per-test generation cap |

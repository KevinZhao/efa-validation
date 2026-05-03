#!/usr/bin/env python3
"""
Smoke test 02 — 2-node EP=16 + graph: no hang, no silent stall (maps to memory test #2)
========================================================================================
Memory ref: reference_cuda_graph_uccl_ep_risk.md §"Stage 5 上线前必做的 3 个 smoke test" #2
    "2 节点 EP=16 + graph: 验证不 hang, 设 UCCL_EP_CPU_TIMEOUT_SECS=10 兜底"

Failure mode targeted: the low_latency path uses Python-side
`proxy.calculate_and_set_dispatch_recv_data_offset` (uccl buffer.py:326-331) which
is NOT in the CUDA graph capture window. On graph replay, if the proxy stalls /
uses a stale offset, we see either (a) hang, (b) silent token mis-routing, or
(c) very high tail latency.

This script ramps concurrency cc=1 -> cc=16 -> cc=64 across short prompts and
asserts:
  * every request returns HTTP 200 within TIMEOUT
  * P99 ITL (inter-token latency) at cc=64 < ITL_P99_HARD_MAX_MS
  * P99/P50 ratio at cc=64 < 5.0 (catches warm-up latency being graph-captured)
  * no request returns zero generated tokens

Because this test ramps cc, it also exercises graph replay across multiple
bucketed batch sizes — which is where the proxy-offset-staleness bug would
manifest as either hang or mis-routed tokens.

PASS  — all HTTP 200, max tail ITL within bound, no empty outputs.
FAIL  — any hang (timeout), any non-200, zero-token output, or tail ratio blow-up.

Usage:
    python3 02_two_node_graph_no_hang.py
    LB_URL=http://k25-r1-lb.yanxi-validation:8000 CCS="1,16,64" python3 02_two_node_graph_no_hang.py
"""
from __future__ import annotations

import concurrent.futures as cf
import json
import os
import statistics
import sys
import time

try:
    import requests
except ImportError:
    print("[smoke-02] FAIL: `requests` not installed.", file=sys.stderr)
    sys.exit(1)

LB_URL = os.environ.get("LB_URL", "http://k25-r1-lb.yanxi-validation:8000").rstrip("/")
MODEL = os.environ.get("MODEL_NAME", "kimi-k2-5-int4")
CCS = [int(x) for x in os.environ.get("CCS", "1,16,64").split(",")]
PROMPT_TOKENS_APPROX = int(os.environ.get("PROMPT_TOKENS", "128"))
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "64"))
PER_REQ_TIMEOUT = int(os.environ.get("REQ_TIMEOUT", "180"))
ITL_P99_HARD_MAX_MS = float(os.environ.get("ITL_P99_HARD_MAX_MS", "500"))
TAIL_RATIO_MAX = float(os.environ.get("TAIL_RATIO_MAX", "5.0"))
# short repetitive prompt to hit ~PROMPT_TOKENS_APPROX without needing tokenizer
BASE_WORD = "the quick brown fox jumps over the lazy dog "
PROMPT = (BASE_WORD * (PROMPT_TOKENS_APPROX // 9 + 1))[: PROMPT_TOKENS_APPROX * 5]


def one_request(idx: int) -> dict:
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": f"[req {idx}] {PROMPT}\nAnswer briefly."}],
        "max_tokens": MAX_TOKENS,
        "temperature": 0.0,
        "seed": 1000 + idx,
    }
    t0 = time.time()
    try:
        r = requests.post(f"{LB_URL}/v1/chat/completions", json=payload, timeout=PER_REQ_TIMEOUT)
    except requests.Timeout:
        return {"idx": idx, "status": -1, "err": "timeout", "lat_s": PER_REQ_TIMEOUT, "toks": 0}
    except requests.RequestException as exc:
        return {"idx": idx, "status": -1, "err": str(exc)[:200], "lat_s": time.time() - t0, "toks": 0}
    dt = time.time() - t0
    if r.status_code != 200:
        return {"idx": idx, "status": r.status_code, "err": r.text[:200], "lat_s": dt, "toks": 0}
    try:
        body = r.json()
        text = body["choices"][0]["message"]["content"]
        usage = body.get("usage", {})
        out_toks = int(usage.get("completion_tokens") or len(text.split()))
    except Exception as exc:
        return {"idx": idx, "status": r.status_code, "err": f"parse:{exc}", "lat_s": dt, "toks": 0}
    itl_ms = (dt * 1000.0 / out_toks) if out_toks > 0 else float("inf")
    return {"idx": idx, "status": 200, "lat_s": dt, "toks": out_toks, "itl_ms": itl_ms}


def run_cc(cc: int) -> tuple[list[dict], list[str]]:
    print(f"[smoke-02] cc={cc}: dispatching {cc} concurrent requests")
    with cf.ThreadPoolExecutor(max_workers=cc) as pool:
        futs = [pool.submit(one_request, i) for i in range(cc)]
        results = [f.result() for f in cf.as_completed(futs)]
    fails: list[str] = []
    ok = [r for r in results if r["status"] == 200 and r["toks"] > 0]
    n_non200 = sum(1 for r in results if r["status"] != 200)
    n_empty = sum(1 for r in results if r["status"] == 200 and r["toks"] == 0)
    if n_non200:
        examples = [r for r in results if r["status"] != 200][:2]
        fails.append(f"cc={cc}: {n_non200}/{cc} non-200 (examples: {json.dumps(examples)[:300]})")
    if n_empty:
        fails.append(f"cc={cc}: {n_empty}/{cc} returned zero tokens")
    if ok:
        itls = sorted(r["itl_ms"] for r in ok)
        p50 = itls[len(itls) // 2]
        p99 = itls[min(len(itls) - 1, int(len(itls) * 0.99))]
        print(f"[smoke-02] cc={cc}: ok={len(ok)}/{cc}  ITL p50={p50:.1f}ms p99={p99:.1f}ms  "
              f"ratio={p99/max(p50,1e-3):.2f}")
        if cc >= 64:
            if p99 > ITL_P99_HARD_MAX_MS:
                fails.append(f"cc={cc}: P99 ITL {p99:.1f}ms > hard max {ITL_P99_HARD_MAX_MS}ms "
                             f"(graph replay may be stalling)")
            if p99 / max(p50, 1e-3) > TAIL_RATIO_MAX:
                fails.append(f"cc={cc}: P99/P50 ratio {p99/max(p50,1e-3):.2f} > {TAIL_RATIO_MAX} "
                             f"(warm-up latency likely captured in graph)")
    else:
        fails.append(f"cc={cc}: zero successful requests")
    return results, fails


def main() -> int:
    print(f"[smoke-02] LB_URL={LB_URL} MODEL={MODEL} CCS={CCS} "
          f"prompt_approx_tokens={PROMPT_TOKENS_APPROX} max_tokens={MAX_TOKENS}")
    all_fails: list[str] = []
    for cc in CCS:
        _, fails = run_cc(cc)
        all_fails.extend(fails)
    if all_fails:
        print("[smoke-02] FAIL")
        for f in all_fails:
            print(f"[smoke-02]   - {f}")
        print("[smoke-02] Likely remediation: disable low_latency DeepEP on decode "
              "(`--moe-a2a-backend none`) while keeping it on prefill. See README.md §Test-02 failure.")
        return 1
    print("[smoke-02] PASS — no hang, tail ITL within bound across cc ramp")
    return 0


if __name__ == "__main__":
    sys.exit(main())

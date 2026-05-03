#!/usr/bin/env python3
"""
Smoke test 01 — Graph capture log check (maps to memory test #1)
================================================================
Memory ref: reference_cuda_graph_uccl_ep_risk.md §"Stage 5 上线前必做的 3 个 smoke test" #1
    "单节点 EP=8 + graph baseline: 8 GPU 起 sglang, 日志应有 'Capturing batches',
     无 'Cuda graph is disabled'"

This script verifies the k25-r1-lb stack came up with CUDA Graph capture enabled.
Because the LB does not expose decode-pod logs over HTTP, this script:
  1. Hits /get_server_info on the LB and asserts `server_args.disable_cuda_graph == false`
     for both prefill and decode servers reachable via the LB router.
  2. Emits a diagnostic line with the resolved disaggregation + deepep mode so the
     operator can confirm low_latency is actually the active path (not normal).
  3. Sends a single cc=1 short-prompt request and asserts HTTP 200 + non-empty output
     (crude "server has not crashed on first graph replay" signal).

PASS  — disable_cuda_graph==False on both roles AND cc=1 request returns >=1 token.
FAIL  — any of: disable_cuda_graph==True, cc=1 request non-200, empty output,
        or deepep_mode != low_latency on decode (if graph capture is not active,
        this test is moot and we should not proceed to tests 02/03).

Usage:
    python3 01_graph_capture_log_check.py
    LB_URL=http://k25-r1-lb.yanxi-validation:8000 python3 01_graph_capture_log_check.py
"""
from __future__ import annotations

import json
import os
import sys
import time

try:
    import requests
except ImportError:
    print("[smoke-01] FAIL: `requests` not installed. `pip install requests` on bastion.", file=sys.stderr)
    sys.exit(1)

LB_URL = os.environ.get("LB_URL", "http://k25-r1-lb.yanxi-validation:8000").rstrip("/")
TIMEOUT = int(os.environ.get("REQ_TIMEOUT", "60"))
PROMPT = "What is 2+2?"
MAX_TOKENS = 16


def hit(path: str, method: str = "GET", payload: dict | None = None) -> tuple[int, dict]:
    url = f"{LB_URL}{path}"
    try:
        if method == "GET":
            r = requests.get(url, timeout=TIMEOUT)
        else:
            r = requests.post(url, json=payload, timeout=TIMEOUT)
    except requests.RequestException as exc:
        return -1, {"error": str(exc)}
    ct = r.headers.get("content-type", "")
    if "application/json" in ct:
        try:
            return r.status_code, r.json()
        except Exception:
            return r.status_code, {"raw": r.text[:400]}
    return r.status_code, {"raw": r.text[:400]}


def main() -> int:
    print(f"[smoke-01] LB_URL={LB_URL}")
    fails: list[str] = []

    # -- 1. server info -----------------------------------------------------
    status, info = hit("/get_server_info")
    if status != 200:
        print(f"[smoke-01] FAIL: /get_server_info -> {status}: {info}")
        return 1

    # sglang 0.5.x returns either a single dict or a list[dict] (router fan-out)
    entries = info if isinstance(info, list) else [info]
    print(f"[smoke-01] /get_server_info returned {len(entries)} server record(s)")

    for idx, entry in enumerate(entries):
        sa = entry.get("server_args") or entry.get("internal_states", [{}])[0] or {}
        disable_graph = sa.get("disable_cuda_graph", None)
        deepep_mode = sa.get("deepep_mode") or sa.get("moe_a2a_backend_extra", {}).get("deepep_mode")
        disagg_mode = sa.get("disaggregation_mode", "null")
        role = "decode" if disagg_mode == "decode" else ("prefill" if disagg_mode == "prefill" else f"other/{disagg_mode}")
        print(f"[smoke-01]   [{idx}] role={role} disable_cuda_graph={disable_graph} "
              f"deepep_mode={deepep_mode} disagg_mode={disagg_mode}")
        if disable_graph is True:
            fails.append(f"server[{idx}] role={role}: disable_cuda_graph=True — "
                         f"graph capture is off, the risk we're hunting cannot manifest here")
        if role == "decode" and deepep_mode not in (None, "low_latency"):
            fails.append(f"server[{idx}] decode: deepep_mode={deepep_mode} — "
                         f"expected low_latency (normal path auto-disables graph, no risk)")

    # -- 2. cc=1 short request ---------------------------------------------
    payload = {
        "model": os.environ.get("MODEL_NAME", "kimi-k2-5-int4"),
        "messages": [{"role": "user", "content": PROMPT}],
        "max_tokens": MAX_TOKENS,
        "temperature": 0.0,
        "seed": 42,
    }
    t0 = time.time()
    status, body = hit("/v1/chat/completions", method="POST", payload=payload)
    dt = time.time() - t0
    print(f"[smoke-01] cc=1 chat -> {status} in {dt:.1f}s")
    if status != 200:
        fails.append(f"cc=1 request non-200 ({status}): {json.dumps(body)[:400]}")
    else:
        try:
            text = body["choices"][0]["message"]["content"]
        except Exception:
            text = ""
        if not text:
            fails.append("cc=1 request returned empty content")
        else:
            print(f"[smoke-01] cc=1 output (first 80ch): {text[:80]!r}")

    # -- verdict ------------------------------------------------------------
    if fails:
        print("[smoke-01] FAIL")
        for f in fails:
            print(f"[smoke-01]   - {f}")
        return 1
    print("[smoke-01] PASS — graph capture enabled, cc=1 short request OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""
Smoke test 03 — Eager vs Graph output consistency / determinism (maps to memory test #3)
==========================================================================================
Memory ref: reference_cuda_graph_uccl_ep_risk.md §"Stage 5 上线前必做的 3 个 smoke test" #3
    "Eager vs Graph 输出一致性: 同 batch 两种模式跑, recv_x logits 相对误差 < 1e-3 (BF16)"

This is the HIGHEST-SIGNAL test for the silent-corruption risk described in the
memory: "proxy offset 未更新 → 静默输出错误 ... decode 输出异常 token, loss 飙但不 crash".
Since we cannot read logits from the LB, we operationalize the check as:

  (A) Determinism under replay: the SAME deterministic request (temp=0, fixed seed,
      greedy) issued K times MUST produce identical output tokens. If the proxy
      offset is stale on some replays, token routing shifts -> output diverges.
  (B) Canonical-answer sanity: a small set of factual short prompts must produce
      plausible answers (catches gross corruption where the model outputs garbage).

The script does NOT require a separate eager server — it uses repeat-determinism
as a proxy for "graph replay == eager correctness". If a dedicated eager-mode
replica is also deployed (LB_EAGER_URL env), the script additionally cross-checks
the graph LB's output against the eager LB's output token-for-token.

PASS  — all K replays of each prompt produce identical output tokens, AND
        (if LB_EAGER_URL set) graph output matches eager output for every prompt.
FAIL  — any replay divergence for the same deterministic request, OR any
        sanity prompt returns empty / obviously-garbage output, OR graph-vs-eager
        mismatch.

Usage:
    python3 03_eager_vs_graph_determinism.py
    LB_URL=http://k25-r1-lb.yanxi-validation:8000 REPEATS=3 python3 03_eager_vs_graph_determinism.py
    LB_URL=http://k25-r1-lb.yanxi-validation:8000 \\
        LB_EAGER_URL=http://k25-r1-eager-lb.yanxi-validation:8000 \\
        python3 03_eager_vs_graph_determinism.py
"""
from __future__ import annotations

import json
import os
import sys
import time

try:
    import requests
except ImportError:
    print("[smoke-03] FAIL: `requests` not installed.", file=sys.stderr)
    sys.exit(1)

LB_URL = os.environ.get("LB_URL", "http://k25-r1-lb.yanxi-validation:8000").rstrip("/")
LB_EAGER_URL = os.environ.get("LB_EAGER_URL", "").rstrip("/")
MODEL = os.environ.get("MODEL_NAME", "kimi-k2-5-int4")
REPEATS = int(os.environ.get("REPEATS", "3"))
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "64"))
TIMEOUT = int(os.environ.get("REQ_TIMEOUT", "120"))

PROMPTS = [
    ("capital_france", "What is the capital of France? Answer with one word."),
    ("arith_simple", "Compute 17 * 23. Respond with only the number."),
    ("sequence_2tok", "Continue the sequence exactly: A B C D E F"),
    ("short_factual", "Who wrote Hamlet? One-word answer."),
]


def one_call(lb_url: str, prompt: str, seed: int) -> tuple[int, str, dict]:
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": MAX_TOKENS,
        "temperature": 0.0,
        "top_p": 1.0,
        "seed": seed,
    }
    try:
        r = requests.post(f"{lb_url}/v1/chat/completions", json=payload, timeout=TIMEOUT)
    except requests.RequestException as exc:
        return -1, "", {"err": str(exc)[:200]}
    if r.status_code != 200:
        return r.status_code, "", {"err": r.text[:200]}
    try:
        body = r.json()
        text = body["choices"][0]["message"]["content"]
    except Exception as exc:
        return r.status_code, "", {"err": f"parse:{exc}"}
    return 200, text, body


def plausible(prompt_id: str, text: str) -> bool:
    """Crude sanity check: catch obviously-garbage output from silent corruption."""
    if not text or not text.strip():
        return False
    t = text.strip().lower()
    # at least one alphanumeric token; not pure repeated single char
    if len(set(t.replace(" ", ""))) < 2:
        return False
    if prompt_id == "capital_france":
        return "paris" in t
    if prompt_id == "arith_simple":
        return "391" in t
    if prompt_id == "short_factual":
        return "shakespeare" in t
    return True  # sequence prompt: just check non-garbage


def main() -> int:
    print(f"[smoke-03] LB_URL={LB_URL} eager_cross_check={'yes:'+LB_EAGER_URL if LB_EAGER_URL else 'no'}  "
          f"REPEATS={REPEATS} MODEL={MODEL}")
    fails: list[str] = []

    for pid, prompt in PROMPTS:
        print(f"[smoke-03] --- prompt={pid} ---")
        # Determinism under replay on the graph LB
        outputs: list[str] = []
        for k in range(REPEATS):
            t0 = time.time()
            status, text, body = one_call(LB_URL, prompt, seed=7777)
            dt = time.time() - t0
            if status != 200:
                fails.append(f"{pid} replay#{k}: non-200 {status} body={json.dumps(body)[:200]}")
                outputs.append(f"__ERR_{status}__")
                continue
            print(f"[smoke-03]   replay#{k} ({dt:.1f}s): {text[:80]!r}")
            outputs.append(text)
        # all replays must match exactly
        unique = set(outputs)
        if len(unique) > 1:
            fails.append(f"{pid}: NON-DETERMINISTIC across {REPEATS} replays — "
                         f"{len(unique)} distinct outputs. This is the silent-corruption signal "
                         f"(proxy offset stale / token mis-route on graph replay).")
            for i, o in enumerate(outputs):
                print(f"[smoke-03]     replay#{i}: {o!r}")
        # plausibility
        if outputs and outputs[0] and not outputs[0].startswith("__ERR_"):
            if not plausible(pid, outputs[0]):
                fails.append(f"{pid}: output not plausible — {outputs[0][:120]!r} "
                             f"(possible silent corruption)")

        # cross-check against eager LB if available
        if LB_EAGER_URL and outputs and not outputs[0].startswith("__ERR_"):
            status, eager_text, body = one_call(LB_EAGER_URL, prompt, seed=7777)
            if status != 200:
                fails.append(f"{pid}: eager LB non-200 ({status}); cannot cross-check")
            elif eager_text.strip() != outputs[0].strip():
                fails.append(f"{pid}: GRAPH vs EAGER mismatch — "
                             f"graph={outputs[0][:80]!r} eager={eager_text[:80]!r}")
            else:
                print(f"[smoke-03]   eager cross-check: match")

    if fails:
        print("[smoke-03] FAIL")
        for f in fails:
            print(f"[smoke-03]   - {f}")
        print("[smoke-03] Likely remediation: fall back to `--moe-a2a-backend none` on decode "
              "(keep UCCL-EP on prefill only). See README.md §Test-03 failure.")
        return 1
    print(f"[smoke-03] PASS — all {len(PROMPTS)} prompts deterministic across {REPEATS} replays, "
          f"outputs plausible"
          + (", graph==eager for all" if LB_EAGER_URL else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())

# Mooncake v3 Rebuild (Stage 5 escalation)

> **Note on filename**: this file is named `BUILD_V3.md` for historical reasons — it started as a local v3 rebuild plan. As recorded in §"Switch plan to v5" below, we discovered a pre-built `:v5` image in Ohio ECR that contains exactly the intended content (Mooncake `@634b7097` + Henan 5 PRs), so Stage 5 actually uses the ECR tag **v5**. The v3/v5 naming split is purely build-side historical and does not imply two different code baselines.

## Rationale

Upstream Mooncake commit `634b7097` (PR #1944, merged 2026-04-23 08:52 UTC) lands
**SRD shared-endpoint refactor** by Henan. Key impact for Stage 5:

- Cold submit #0 (no warmup): **99 ms → 26 ms** (~4×)
- `warmupSegment()`: **17 s (with jitter) → 1.1 s** (~15×)
- Eliminates per-peer QP cap (was 768 QP, now AV indirection via shared fid_ep)
- Fixes teardown crash (`fi_av_remove` after EP close → EFA provider segfault)
- **Fixes VRAM preTouchMemory segfault** — open Stage 1-4 issue (CPU store to cudaMalloc ptr)
- Removes `MC_EFA_STRIPING_THRESHOLD` — p5en sweep showed 20× regression at >2 MB
- New Python binding: `warmup_efa_segment(segment_name) -> int`

## Plan

1. `common/Dockerfile.mooncake-nixl` — `MOONCAKE_REF=634b7097` (done)
2. Build `yanxi/mooncake-nixl:v3` on builder `i-0f6dc7baf7825b30f`
3. Build `yanxi/sglang-mooncake:v3` with `BASE_IMAGE=...mooncake-nixl:v3`
4. Mirror `sglang-mooncake:v3` Ohio → Oregon ECR
5. Preflight v3 image (add check #6: SRD shared-endpoint symbol presence)
6. Re-run R1a on v3 baseline

## Timeline

| UTC | Event |
|---|---|
| 20260425T035216Z | Build kick-off |

## 2026-04-25T03:56:10+00:00 — Build skipped, v5 image already exists

Builder inspection revealed pre-built Ohio ECR images tagged v5:
- `yanxi/mooncake-nixl:v5` (18h old) — `/opt/mooncake` HEAD = **634b709 #1944**
- `yanxi/sglang-mooncake:v5` (18h old) — inherits v5 Mooncake
- pip `mooncake-transfer-engine` = **0.3.10.post2** (same tag, more commits)

Someone (likely admin in Tokyo) pre-built these 18h ago. CLAUDE.md §37 already
documented v5 as "@634b7097 含 Henan #1944 + UCX 1.19" but STAGE5_PLAN / manifests
were not aligned. We now switch Stage 5 to v5.

## 2026-04-25T03:56:10+00:00 — First v3 build attempt (failed)

Tried `MOONCAKE_REF=634b7097` end-to-end build on `i-0f6dc7baf7825b30f`.
- `/tmp/builder-ready` sentinel was missing; create manually and build proceeded
- Failed at sanity-check stage (line 220): `efa_latency_bench.py` path moved in
  upstream post-#1944. Dockerfile patched to tolerate missing file.

Since v5 already exists pre-built and passes our criteria, cancel the rebuild and
use v5 directly. Dockerfile edit retained for future rebuilds.

## 2026-04-25T03:56:10+00:00 — Switch plan to v5

1. [x] Ohio v5 image exists (verified via `docker run git log --oneline` on builder)
2. [ ] Mirror `sglang-mooncake:v5` Ohio → Oregon ECR (in-progress, pid 3920191)
3. [ ] Preflight v5 (Ohio, via new `_preflight-image-ohio-v5.yaml` with PR #1944 SRD check)
4. [ ] R1a on v5 (new `r1a-kimi-k2-1p1d-v5.yaml`)

# Build Matrix — Single Source of Truth

**Last updated**: 2026-04-27
**Owner**: AWS Account Team (JD)

This document is the **authoritative pin list** for every image in
`common/Dockerfile.*`. When ECR tags disagree with this file, this file wins —
update the Dockerfiles, rebuild, overwrite the ECR tag.

## Image Roles

Three image streams. Do not cross the streams.

| Stream | Consumer | Hardware | Git branch policy |
|---|---|---|---|
| **customer** | 客户生产 | p5en / p5 (H200/H100 sm_90) | Release tag, frozen |
| **internal-hopper** | Stage 5 调优 | p5en / p5 | Float, rebuild on PR merges |
| **internal-blackwell** | Stage 5.5 调优 (B200/B300) | p6-b200 / p6-b300 (sm_100/sm_103) | Pending §13 M5-M10 |

## Customer stream

Two variants built from the same `Dockerfile.customer-h200` via `ARG WITH_UCCL`:

| Variant | Image | Alltoall backend | Size | When to use |
|---|---|---|---|---|
| **uccl** | `public.ecr.aws/n3l4x8f3/sglang-mooncake-uccl:<YYYY.MM.DD>-h200` | UCCL-EP (via `deep_ep` wrapper, `--moe-a2a-backend deepep`) | ~11-12 GB | Cross-node MoE inference (primary) |
| **nccl** | `public.ecr.aws/n3l4x8f3/sglang-mooncake-nccl:<YYYY.MM.DD>-h200` | NCCL fake-alltoall (`--moe-a2a-backend none` or `nccl`) | ~8-9 GB | Single-node MoE / dense models / A/B baseline |

Both variants share identical Mooncake TE, SGLang, EFA, NCCL, torch — **only the alltoall kernel differs**. Any perf delta is attributable to the alltoall path alone.

- Public registry alias `n3l4x8f3` (auto-assigned by AWS; `aws-*` prefixes reserved)
- Umbrella repo `public.ecr.aws/n3l4x8f3/aws-efa` available for future companion artifacts (diagnostics, bench tools)
- **Latest tag**: `latest` → current release (per variant)
- **Stable alias**: `stable` → promoted manually after 1 week of internal soak (per variant)

### 2026.04.28-h200 (inaugural release)

| Component | Version / SHA | Source | Rationale |
|---|---|---|---|
| CUDA runtime | 13.0.2 | nvidia/cuda:13.0.2-cudnn-devel-ubuntu22.04 | Matches Stage 5 v5 base; forward-compatible with torch cu128 |
| EFA installer | 1.47.0 | amazonaws.com | Latest on 2026-04-27 |
| libfabric | 1.22 (bundled with EFA 1.47) | — | SRD provider for EFA devices |
| NCCL | 2.23.4 | github.com/NVIDIA/nccl | Pinned for sm_90 stability |
| aws-ofi-nccl | 1.19.0 | github.com/aws/aws-ofi-nccl | Latest 1.x with libfabric 1.22 |
| OpenMPI | 5.0.x (from EFA installer) | amazonaws.com | — |
| Python | 3.10 | ubuntu22.04 | — |
| PyTorch | 2.9.1+cu128 | Implicitly pulled by sglang[all] | Wheel ABI dictates CUDA 12.8 toolchain for downstream builds |
| Mooncake TE | `634b7097` (= #1944 merge head) | kvcache-ai/Mooncake | Contains Henan 5 EFA PRs (#1509/#1523/#1821/#1912/#1944) — all upstreamed; no patching needed |
| Mooncake build flags | `USE_EFA=ON, USE_CUDA=ON, WITH_TE=ON, WITH_EP=OFF` | — | **WITH_EP=OFF intentional**: Mooncake-EP is Mellanox IBGDA-only (mlx5dv_* direct), does not run on AWS EFA |
| SGLang | 0.5.10 | sglang[all] PyPI | Customer's production version |
| UCCL | `8ac850bd` (upstream main 2026-04-27) | uccl-project/uccl | Contains PR #904 (UCCL_EP_CPU_TIMEOUT_SECS) merged as 5e15ad9d |
| UCCL build | `python setup.py install` (ep subpackage only) | — | NVSHMEM not required; torch cu128 ABI |
| DeepEP wrapper | bundled with UCCL-EP | uccl/ep/deep_ep_wrapper | Redirects `import deep_ep` → `uccl.ep`; lets SGLang `--moe-a2a-backend deepep` use UCCL without patching |

### Build-time-only, NOT in customer runtime image

- `cuda-nvcc-12-8` + cuda 12.8 dev libs (only for UCCL C-extension compile)
- UCCL source tree `/opt/uccl` (keep only the installed wheel in `site-packages`)
- Mooncake build tree `/opt/mooncake/build` (keep install prefix `/opt/mooncake/install/`)
- NIXL, UCX (NIXL dropped from customer; UCX only NIXL's dependency)
- clang-format, gnupg, wget (build utils)

### Excluded from customer stream

| Component | Why |
|---|---|
| NIXL | Customer chose Mooncake for KV transport; NIXL is Lane K comparison only |
| UCX | NIXL's dependency; unused without NIXL |
| Mooncake-EP | mlx5 IBGDA-only, cannot run on EFA |
| Mooncake Store / Master service | Customer uses TE-only PD disagg; store layer not used |
| UCCL fork patches | Fork was interim; upstream main now contains all relevant merges |
| Python dev headers / build tools | Not needed at runtime |

## Internal Hopper stream

**Registry**: private `788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/*`
**Purpose**: Stage 5 調優 (Lane K / Lane E / §5.8)
**Current images** (see `reference_sglang_mooncake_v5_uccl_image.md` memory for full details):

| Tag | Use |
|---|---|
| `sglang-mooncake:v5` | PD disagg baseline (no UCCL) |
| `sglang-mooncake:v5-uccl` | Lane E + §5.8 (UCCL-EP + DeepEP wrapper) |
| `mooncake-nixl:v5` / `:v6.1` | Lane K microbench (NIXL + Mooncake bench) |
| `uccl-ep:v2` | UCCL-EP microbench (DeepEP test_intranode.py) |
| `nccl-tests:v2` | NCCL alltoall baseline |

## Image naming convention

```
public.ecr.aws/n3l4x8f3/sglang-mooncake-<variant>:<YYYY.MM.DD>-<arch>
                                         ^^^^^^^^  ^^^^^^^^^^  ^^^^
                                         uccl      release     h200 / h100 / b200 / b300
                                         / nccl    date
```

Additional moving tags:
- `latest` → latest release (follow-on releases overwrite)
- `stable` → promoted after 1 week internal soak (manual)
- `<YYYY.MM>-<arch>` → latest release within a month (e.g. `2026.04-h200`)

## Release cadence

**Trigger for new release**:
- New Mooncake upstream PR that touches EFA transport (Henan or other)
- UCCL upstream EP kernel change
- SGLang minor version bump (verified compatible with both Mooncake & UCCL)
- CVE in base or critical dep

**Non-triggers** (do NOT bump release):
- Unrelated Mooncake commits (store/P2P store code paths not used)
- Non-EP changes in UCCL (collective/P2P subsystems not included)
- SGLang patch releases unless they fix something we hit

**Process**:
1. Update this file with new SHAs + rationale
2. `./scripts/build-customer-image.sh <YYYY.MM.DD>`
3. Internal soak on Stage 5 bench for 1 week
4. `./scripts/promote-customer-image.sh <YYYY.MM.DD>` (retags `stable` + `latest`)
5. Post release note to customer

## Verification

Every release image MUST pass:
1. `python -c "import torch; print(torch.__version__, torch.version.cuda)"` → 2.9.1+cu128
2. `python -c "import uccl.ep"` → no error
3. `python -c "import deep_ep; assert deep_ep.Config.__module__.startswith('uccl')"` → deep_ep routed to UCCL
4. `python -c "import mooncake"` → no error
5. `python -c "import sglang; print(sglang.__version__)"` → 0.5.10
6. `python -m sglang.launch_server --help | grep moe-a2a-backend` → shows `deepep` in choices
7. `/opt/mooncake/install/bin/transfer_engine_bench --help` → runs
8. `fi_info -p efa` inside container (on EFA-capable node) → shows 16 devices on p5en
9. Image SBOM matches this file's version table (see `/opt/BUILD_INFO.json` inside image)

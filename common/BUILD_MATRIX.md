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

### 2026.04.28-h200.4 hotfix (2026-04-29 rebuild)

Shipped 2026-04-29 after validating `.3` on a real p5.48xlarge and realizing
one of the two EFA test binaries from the Mooncake official test protocol
was missing from our runtime image:

| Missing binary | Source | Why it matters |
|---|---|---|
| `efa_first_submit_probe` (`/opt/mooncake/install/bin/`) | Built in `/opt/mooncake/build/mooncake-transfer-engine/example/`, not copied into install prefix by `ninja install` | Mooncake official doc [EFA Transport](https://kvcache-ai.github.io/Mooncake/design/transfer-engine/efa_transport.html) references this for first-submit latency measurement. Customer reproducing our validation would hit "binary not found" without a source checkout |

**Fix**: Dockerfile builder stage now also copies `efa_first_submit_probe`
next to `transfer_engine_bench` (conditional — skipped with a log message if
the Mooncake SHA pre-dates this binary, to keep future MOONCAKE_REF bumps
from breaking the build).

**Tag policy**: patch-bump to `2026.04.28-h200.4`; no other changes (Mooncake /
UCCL / SGLang / torch / CUDA / EFA / the rdma→efa patch all unchanged from
`.3`). Both `.3` tags remain valid for customer use; `.4` only adds a
diagnostic binary.

### 2026.04.28-h200.3 hotfix (2026-04-29 rebuild)

Shipped 2026-04-29 after customer GLM-5.1 2P:2D docker-compose run revealed
that SGLang's hardcoded Mooncake protocol silently fell back to TCP on our
EFA Mooncake build, producing minute-level KV-transfer latency:

| Bug in `.2` | Why | How we hit it |
|---|---|---|
| `sglang/srt/distributed/device_communicators/mooncake_transfer_engine.py` hardcodes protocol `"rdma"` when calling `TransferEngine.initialize(...)`. Our Mooncake build is `USE_EFA=ON` (`transfer_engine_py.cpp:237`), which installs TCP transport whenever the protocol string is not `"efa"`. Standard-RDMA Mooncake builds (customer's domestic IDC) accept `"rdma"` natively, so this only bites AWS EFA deployments | SGLang upstream has no env/flag to override this string; the `"rdma"` token is inline. `.2` image had a `sed` patch inside our launcher shell script (`manifests/customer-*-glm51-*.yaml`), but customer's docker-compose uses `entrypoint: python3 -m sglang.launch_server` directly — the launcher never runs, the patch never applies | Customer GLM-5.1 logs 2026-04-28 showed 24× `Installing TCP transport (auto_discover disabled in EFA build)` across prefill ranks; KV transfer ran on TCP sockets; compounded with CP `is_dummy_cp_rank` it produced 181s prefill + 300s decode timeouts |

**Fix**: Dockerfile builder stage now `sed -i 's/"rdma",$/"efa",/'` the file
into the image itself (before Mooncake TE build), so any entrypoint — our
launcher, bare `python -m sglang.launch_server`, custom wrappers — gets the
correct `"efa"` protocol. Build fails fast if upstream sglang changes the
string shape (token guard via `grep -q '"rdma",'` and post-sed assertions).

**Smoke check extended**: runtime stage now asserts at build time that
`inspect.getsource(sglang.srt.distributed.device_communicators.mooncake_transfer_engine)`
contains `"efa",` and does not contain `"rdma",`. Catches any future
regression where the patch didn't actually apply.

**Launcher change** (`manifests/customer-2p2d-glm51-ohio.yaml` et al.):
launcher now detects whether the image is pre-patched (`.3+`) or legacy
(`.2-`) and only runs the sed in the legacy case, emitting a log message
either way. This keeps old manifests compatible with new images and vice
versa.

**Tag policy**: patch-bump to `2026.04.28-h200.3`; no other changes (Mooncake
/ UCCL / SGLang / torch / CUDA / EFA SHAs unchanged from `.2`). `.2` tag
left in place for forensics but deprecated.

**Caveat**: `.3` fixes the **transport layer** (KV traffic now runs on EFA
SRD, not TCP). It does NOT fix the **PD-disagg + CP contract layer** —
sglang's `is_dummy_cp_rank` gating (PR #19504) still causes prefill CP
rank≠0 to skip bootstrap/send KV when prefill CP > 1 and decode CP = 1,
producing the same 181s+300s timeout pattern. The workaround remains
"disable `--enable-nsa-prefill-context-parallel`" (or set env
`SGLANG_DISAGGREGATION_ALL_CP_RANKS_TRANSFER=1`, not yet verified on AWS).

### 2026.04.28-h200.2 hotfix (2026-04-27 rebuild)

Shipped 2026-04-27 after customer Docker 1P:1D run revealed the `.1` image
was still missing a runtime CLI binary:

| Missing binary | Why SGLang needs it | How we hit it |
|---|---|---|
| `/usr/bin/ninja` (apt pkg `ninja-build`) | SGLang TP workers JIT-compile attention kernels (QK-Norm, tvm_ffi) via a forked `subprocess.run("ninja", ...)`. The pip-installed ninja wheel's CLI at `/usr/local/bin/ninja` from the builder stage is NOT copied to runtime (we only `COPY /usr/local/bin/python`, not the whole dir) | Decode pod crash loop: `Failed to load JIT QK-Norm kernel: 'ninja'` across TP workers. Prefill occasionally started because its first-touch kernels are different from decode's |

**Fix**: Dockerfile runtime apt install adds `ninja-build` (system PATH
`/usr/bin/ninja`, fork-safe for TP workers — doesn't rely on `/usr/local/bin`
being copied or PATH surviving multiprocessing fork).
**Smoke check extended**: `test -x /usr/bin/ninja && ninja --version`.
**Tag policy**: patch-bump to `2026.04.28-h200.2`; no other changes (Mooncake /
UCCL / SGLang / torch / CUDA / EFA SHAs unchanged from `.1`). `.1` tag
left in place for forensics but deprecated.

### 2026.04.28-h200.1 hotfix (2026-04-27 rebuild, DEPRECATED — missing runtime ninja)

Shipped 2026-04-27 after 1P:1D perf test on Oregon p5 revealed the original
`2026.04.28-h200` image was missing two runtime libs:

| Missing lib | Why SGLang needs it | How we hit it |
|---|---|---|
| `libpython3.10.so.1.0` (apt pkg `libpython3.10`) | Mooncake's cpython-310 binding `dlopen`s it at `from mooncake.engine import TransferEngine` — NOT covered by `import mooncake` which only loads package metadata | `ImportError: libpython3.10.so.1.0: cannot open shared object file` when SGLang init'd Mooncake TE |
| `Python.h` (apt pkg `python3.10-dev`) | Triton JIT fallback in `sglang/srt/layers/attention/fla/utils.py:223` compiles a tiny CUDA shim when triton can't load — without Python.h it emits noisy CPU fallback | `fatal error: Python.h: No such file or directory` spam in log |

**Fix**: Dockerfile runtime apt install adds `libpython3.10 python3.10-dev`.
**Smoke check extended** so future rebuilds catch it (uses `from mooncake.engine
import TransferEngine` + `test -f /usr/lib/x86_64-linux-gnu/libpython3.10.so.1.0`
+ `test -f /usr/include/python3.10/Python.h`).
**Tag policy**: patch-bump to `2026.04.28-h200.1`; no other changes (Mooncake /
UCCL / SGLang / torch / CUDA / EFA SHAs unchanged). Previous `2026.04.28-h200`
tag left in place for forensics but deprecated.

### 2026.04.28-h200 (inaugural release, DEPRECATED — missing libpython runtime deps)

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
2. `python -c "import uccl.ep"` → no error (uccl variant only)
3. `python -c "import deep_ep; assert deep_ep.Config.__module__.startswith('uccl')"` → deep_ep routed to UCCL (uccl variant only)
4. `python -c "import mooncake"` → no error
5. `python -c "from mooncake.engine import TransferEngine"` → no error (catches `libpython3.10.so.1.0` missing; pure metadata `import mooncake` does NOT)
6. `test -f /usr/lib/x86_64-linux-gnu/libpython3.10.so.1.0` (libpython3.10 apt pkg)
7. `test -f /usr/include/python3.10/Python.h` (python3.10-dev apt pkg; triton JIT fallback)
8. `python -c "import sglang; print(sglang.__version__)"` → 0.5.10
9. `python -m sglang.launch_server --help | grep moe-a2a-backend` → shows `deepep` in choices
10. `/opt/mooncake/install/bin/transfer_engine_bench --help` → runs
11. `fi_info -p efa` inside container (on EFA-capable node) → shows 16 devices on p5en
12. Image SBOM matches this file's version table (see `/opt/BUILD_INFO.json` inside image)
13. **E2E smoke on GPU node** — `sglang.launch_server --disaggregation-mode prefill --disaggregation-transfer-backend mooncake` must start without TransferEngine ImportError (this is what would have caught h200.0 → h200.1 bug)
14. **Mooncake EFA patch applied** — `python -c "import inspect, sglang.srt.distributed.device_communicators.mooncake_transfer_engine as m; src=inspect.getsource(m); assert '\"efa\",' in src and '\"rdma\",' not in src; print('ok')"` → ok (catches h200.2 → h200.3 TCP-fallback bug)

# efa-validation

End-to-end validation scripts for running disaggregated LLM inference
(SGLang prefill/decode separation + Mooncake KV + UCCL-EP) on **AWS EKS**
with **EFA v2** as the primary RDMA fabric.

The goal of this repository is to provide a reproducible, opinionated
skeleton for teams that want to benchmark the full "prefill on one
p5.48xlarge ↔ EFA ↔ decode on another p5.48xlarge" path before committing
to a production deployment on EFA.

It is **infrastructure-as-configuration** — mostly Kubernetes manifests,
Dockerfiles, shell scripts, and SSM payloads. No app-level Python beyond
small test drivers.

## Stages

| Stage | Goal | Key output |
|---|---|---|
| 1 — `archive/stage1-4/stage1-nccl-tests` | NCCL all-reduce / all-to-all on EFA | busBW baseline per-NIC / per-node |
| 2 — `stage2-uccl-ep` | UCCL-EP low-latency dispatch+combine | correctness + dispatch/combine BW |
| 3 — `archive/stage1-4/stage3-kv` / `stage3-mooncake-nixl` | Mooncake transfer_engine and NIXL over EFA | KV-transfer throughput + latency |
| 4 — `archive/stage1-4/stage4-e2e` / `stage4-sglang-mooncake` / `stage4-p5en` | SGLang PD 1P:1D end-to-end | TTFT / TPOT / OTPS vs single-node baseline |
| 5 — `manifests/stage5-p5en/` + `results/stage5-p5en/` | PD 1P1D / 2P2D on p5en (Mooncake v5 baseline, Henan EFA PRs) | 当前主线；详见 `STAGE5_PLAN.md` |

Stage 1-4 已完成并冻结，配置 manifest 已归档到 `archive/stage1-4/`；**原始测量数据仍保留在 `results/stage1..4*/`**（作为 Stage 5 对比基线）。当前主线是 Stage 5，见 `STAGE5_PLAN.md`。

`RUNBOOK.md` 是 Stage 1-4 的实际执行流水记录（为保留历史时间线准确性，里面的路径仍指向归档前位置）。

## Prerequisites

- AWS account with permission to: EKS, EC2 (p5.48xlarge), EFA v2, ECR, S3, SSM
- An EKS cluster on v1.35+ with:
  - A GPU nodegroup of **p5.48xlarge** (8× H100 80GB, 32× EFA NIC)
  - NVIDIA GPU Operator v24.9.2 (device plugin v0.17 + CDI)
  - MPI Operator v0.6.0
  - LeaderWorkerSet (LWS) v0.7.0
- A bastion EC2 instance in the VPC with `kubectl` + `aws` CLI, registered
  to SSM, used as the control plane for all `kubectl` operations against
  the EKS private API
- A build EC2 (x86, m7i.4xlarge or larger, SSM-enrolled) for Docker image
  builds — images are multi-GB and pushing to ECR from a laptop is slow

See [RUNBOOK.md](./RUNBOOK.md) for how the original run was wired up.

## Repository layout

```
.
├── RUNBOOK.md                 # step-by-step execution log + decisions log
├── common/                          # Current / customer-delivery Dockerfiles
│   ├── BUILD_MATRIX.md              # Authoritative pin list for all images
│   ├── Dockerfile.customer-h200     # 客户交付镜像 (uccl + nccl 两 variant 同源)
│   ├── Dockerfile.sglang-mooncake-uccl      # Stage 5 §5.8 Lane E (v5-uccl)
│   ├── Dockerfile.sglang-mooncake-nixl-uccl # 内部 A/B (Mooncake vs NIXL 同 pod 切换)
│   ├── Dockerfile.mooncake-nixl-v6  # Lane K microbench (v6.1)
│   ├── Dockerfile.uccl-ep           # Stage 2 UCCL-EP microbench (v2, 冻结)
│   ├── patch-mooncake-bench-v6.py   # build-context patch for mooncake-nixl-v6
│   └── sglang-launcher.sh           # Stage 5 manifest launcher (ConfigMap 内嵌)
├── archive/stage1-4/          # Frozen Stage 1-4 manifests (历史复现用)
│   ├── stage1-nccl-tests/     # Stage 1 MPIJob
│   ├── stage3-kv/             # Stage 3 (skeleton)
│   ├── stage3-mooncake-nixl/  # Stage 3 real bench manifests (transfer_engine_bench over EFA)
│   ├── stage3-nixl-bench/     # Stage 3 NIXL nixlbench manifests + build script
│   ├── stage4-e2e/            # Stage 4 skeleton (LWS prefill + decode)
│   ├── stage4-sglang-mooncake/# Stage 4 actual bench (baseline, 1P:1D, bench-serving)
│   └── stage4-p5en/           # Stage 4 p5en 1P:2D + Kimi-K2 setup guide
├── stage2-uccl-ep/            # Stage 2 MPIJob (correctness + perf + diag) — 活跃
├── manifests/                 # Cluster-level add-ons + Stage 5 manifests (stage5-p5en/)
├── scripts/                   # Orchestration helpers (lib.sh for ssm_run etc.)
├── results/                   # Stage 1-5 测量数据 / SUMMARY 文档（保留，作为基线）
└── ssm-payloads/              # One-shot SSM-RunShellScript payloads used during execution
```

## Related sibling repos

- `../uccl-ep-optimization/` — UCCL-EP on EFA optimization research (split from this repo 2026-05-03): 34 design docs, 3 upstream PR workspaces (warmup-cpu-timeout / combine-signal-api / efa-caps-dump), Hopper mem-ordering microbench. efa-validation now keeps only measurement data + positioning (`UCCL_VS_NCCL.md`) + Stage 2 validation manifests.
- `../uccl-ep-optimization/uccl/` — `KevinZhao/uccl` fork (upstream `uccl-project/uccl`), nested inside the sibling repo as of 2026-05-03; still an independent git repo (own `.git`, `.gitignore`-excluded by parent).

## Getting started

1. Copy `.env.example` to `.env` and fill in the placeholders for your
   environment (`<AWS_ACCOUNT_ID>`, `<EKS_CLUSTER_NAME>`, bastion & builder
   instance IDs, etc.).
2. Rebuild the four Docker images on your builder:
   ```
   scripts/build-image.sh base-cuda-efa v1
   scripts/build-image.sh nccl-tests v1
   scripts/build-image.sh uccl-ep v1
   scripts/build-image.sh mooncake-nixl v1
   scripts/build-image.sh sglang-mooncake v1
   ```
3. Apply the namespace + ServiceAccount:
   `kubectl apply -f common/00-namespace.yaml`
4. Walk through the stages in order. Each stage's `README.md` has the
   exact commands.

## Placeholders used throughout

Files in this repo reference placeholders that you need to replace
(either by `sed`, `envsubst`, `kustomize`, or hand-editing) before
applying to your cluster:

| Placeholder | Meaning |
|---|---|
| `<AWS_ACCOUNT_ID>` | Your AWS account ID (used in ECR URIs and S3 bucket names) |
| `<AWS_REGION>` | e.g. `us-east-2` |
| `<AWS_AZ>` | e.g. `us-east-2b` |
| `<VPC_ID>`, `<SUBNET_ID>`, `<SECURITY_GROUP_ID>`, `<AMI_ID>` | AWS resource IDs |
| `<EKS_CLUSTER_NAME>`, `<EKS_CLUSTER_NAME_OHIO>`, `<EKS_CLUSTER_NAME_OREGON>` | Your cluster names |
| `<OHIO_BASTION_ID>`, `<OREGON_BASTION_ID>`, `<BUILDER_ID>` | EC2 instance IDs for SSM |
| `<GPU_NODE_0>`, `<GPU_NODE_1>` | Internal DNS name for the two p5 nodes (filled by scheduler at runtime in most manifests) |
| `<GPU_NODE_0_IP>`, `<GPU_NODE_1_IP>` | VPC-internal IPs (only in documentation) |
| `<MODEL_ID>`, `<MODEL_NAME>`, `<HF_OWNER>` | HuggingFace model coordinates — swap in your target model |
| `<VPC_CIDR>` | CIDR of your VPC |
| `<BASE64_ENV_BLOB>` | Base64-encoded EKS-cluster-deployment `.env` file (see `ssm-payloads/bastion-push-env-*.json`) |

## Status of each stage (from the example run)

| Stage | Status | Headline metric |
|---|---|---|
| 1 — NCCL-tests on EFA | ✅ PASS | all_reduce busBW **476.91 GB/s** @ 8GB on 2×p5.48xlarge (target ≥320 GB/s) |
| 2 — UCCL-EP on EFA | ✅ PASS | 16 ranks all pass upstream `test_low_latency.py`; dispatch+combine ~7 GB/s per rank |
| 3.1 — Mooncake over EFA (smoke) | ⚠️ smoke only | 19.31 GB/s DRAM→DRAM write (vs 150 GB/s target; tuning needed) |
| 4 — SGLang 1P:1D with Mooncake KV over EFA | ⚠️ smoke only | 1P:1D TPOT 0.53× baseline ✅, TTFT 7.7× baseline ❌ (request-rate=inf; needs rate-limited rerun) |

All raw logs from the example run were scrubbed and are not included in
this repo. The headline numbers are captured in each stage's SUMMARY.md
equivalent or in `RUNBOOK.md`.

## License

Apache 2.0 — see [LICENSE](./LICENSE).

## Attribution

This codebase was written as part of an internal validation exercise
(EFA v2 feasibility for disaggregated LLM inference) and then sanitized
for public release. It intentionally does not cover any single workload
or model — it is the plumbing, not the application.

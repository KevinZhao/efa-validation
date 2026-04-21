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
| 1 — `stage1-nccl-tests` | NCCL all-reduce / all-to-all on EFA | busBW baseline per-NIC / per-node |
| 2 — `stage2-uccl-ep` | UCCL-EP low-latency dispatch+combine | correctness + dispatch/combine BW |
| 3 — `stage3-kv` / `stage3-mooncake-nixl` | Mooncake transfer_engine and NIXL over EFA | KV-transfer throughput + latency |
| 4 — `stage4-e2e` / `stage4-sglang-mooncake` | SGLang PD 1P:1D end-to-end | TTFT / TPOT / OTPS vs single-node baseline |

Each stage directory has its own `README.md` with the exact `kubectl apply`
workflow. `RUNBOOK.md` at the repo root is the step-by-step execution log
from a real run (every failure and fix recorded so you can skip the pitfalls
we hit).

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
├── common/
│   ├── Dockerfile.base-cuda-efa     # CUDA 12.6 + EFA 1.47 + NCCL 2.23 + aws-ofi-nccl v1.19
│   ├── Dockerfile.nccl-tests-v2     # Stage 1 image
│   ├── Dockerfile.uccl-ep           # Stage 2 image (UCCL-EP + DeepEP)
│   ├── Dockerfile.mooncake-nixl     # Stage 3 image (Mooncake + NIXL)
│   ├── Dockerfile.sglang-mooncake   # Stage 4 image (SGLang 0.4.10 + Mooncake)
│   └── sglang-launcher.sh           # baseline / prefill / decode / lb dispatcher
├── stage1-nccl-tests/         # Stage 1 MPIJob
├── stage2-uccl-ep/            # Stage 2 MPIJob (correctness + perf + diag)
├── stage3-kv/                 # Stage 3 (skeleton)
├── stage3-mooncake-nixl/      # Stage 3 real bench manifests (transfer_engine_bench over EFA)
├── stage4-e2e/                # Stage 4 skeleton (LWS prefill + decode)
├── stage4-sglang-mooncake/    # Stage 4 actual bench (baseline, 1P:1D, bench-serving)
├── manifests/                 # Cluster-level add-ons (GPU Operator, device plugin variants)
├── scripts/                   # Orchestration helpers (lib.sh for ssm_run etc.)
└── ssm-payloads/              # One-shot SSM-RunShellScript payloads used during execution
```

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

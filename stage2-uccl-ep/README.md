# Stage 2 — UCCL-EP on EFA

Runbook: [`../RUNBOOK.md`](../RUNBOOK.md)

## Layout

| File | Purpose |
|---|---|
| `../common/Dockerfile.uccl-ep` | UCCL-EP + DeepEP on top of `efa-validation/base-cuda-efa:v1` |
| `mpijob-correctness.yaml` | §4.2.0 correctness smoke (UCCL-EP vs DeepEP, fp16 max-abs-diff ~1e-3) |
| `mpijob-perf-uccl.yaml` | §4.2.1 UCCL-EP dispatch+combine perf |
| `mpijob-perf-nccl.yaml` | §4.2.1 DeepEP (NCCL-EP) reference perf |

## Build image

```bash
export ECR_REG=<AWS_ACCOUNT_ID>.dkr.ecr.us-east-2.amazonaws.com
export ECR_BASE=${ECR_REG}/efa-validation/base-cuda-efa

./scripts/build-image.sh \
  common/Dockerfile.uccl-ep \
  uccl-ep v1 \
  --build-arg=BASE_IMAGE=${ECR_BASE}:v1

./scripts/build-watch.sh uccl-ep-<stamp>
```

## Submit jobs (from Ohio bastion)

```bash
# Correctness
kubectl apply -f validation/stage2-uccl-ep/mpijob-correctness.yaml
kubectl -n efa-validation logs -f -l training.kubeflow.org/job-name=uccl-ep-correctness,training.kubeflow.org/job-role=launcher

# UCCL-EP perf
kubectl apply -f validation/stage2-uccl-ep/mpijob-perf-uccl.yaml
kubectl -n efa-validation logs -f -l training.kubeflow.org/job-name=uccl-ep-perf,training.kubeflow.org/job-role=launcher

# NCCL-EP (DeepEP) perf
kubectl apply -f validation/stage2-uccl-ep/mpijob-perf-nccl.yaml
kubectl -n efa-validation logs -f -l training.kubeflow.org/job-name=nccl-ep-perf,training.kubeflow.org/job-role=launcher
```

## Collect results

Launcher writes to `/workspace/out/` inside the pod:

```bash
LAUNCHER=$(kubectl -n efa-validation get pod \
  -l training.kubeflow.org/job-name=uccl-ep-correctness,training.kubeflow.org/job-role=launcher \
  -o name | head -1)
kubectl -n efa-validation cp ${LAUNCHER#pod/}:/workspace/out ./results/stage2-correctness
```

Repeat with `uccl-ep-perf` and `nccl-ep-perf` for the two perf runs.

## Open TODOs (confirm before first real run)

- Upstream UCCL-EP default branch + build flag (`UCCL_ENABLE_EFA`, platform switch).
- Exact Python module names for `uccl_ep` and `deep_ep` — wire into `compare_ep.py` in `mpijob-correctness.yaml` ConfigMap.
- Exact bench script paths: `/opt/uccl-ep/bench/bench_internode.py` and DeepEP equivalent (`tests/test_internode.py` vs `bench/bench_internode.py`).
- PyTorch CU126 wheels — currently pulling CU124 from `download.pytorch.org/whl/cu124`.

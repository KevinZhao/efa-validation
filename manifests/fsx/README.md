# FSx for Lustre — yanxi-validation model cache

Centralized, single-AZ, POSIX-mountable model cache for SGLang / Mooncake /
NIXL benchmarks. Each GPU region has one FSx file system with Name tag
`yanxi-model-cache`.

| Region | FSx Id | DNS | MountName | Subnet / AZ | GPU NG subnet match | SG |
|---|---|---|---|---|---|---|
| us-east-2 | `fs-0adb0b44ce313faea` | `fs-0adb0b44ce313faea.fsx.us-east-2.amazonaws.com` | `xc4chb4v` | `subnet-0c86f1c69e4067890` / `us-east-2b` | `gpu-p5-48xlarge-spot` | `sg-062ae2f53a5e61e49` |
| us-west-2 | `fs-0a0a98a5f21d6f9fc` | `fs-0a0a98a5f21d6f9fc.fsx.us-west-2.amazonaws.com` | `uqkyjb4v` | `subnet-0343696171ce4cdc9` / `us-west-2b` | `gpu-p6-b300-48xlarge-spot`, `gpu-p5en-48xlarge-spot` | `sg-0c2f826221429c8f3` |

Deployment type: **SCRATCH_2**, 2400 GiB. Baseline 200 MB/s/TiB, burst to
1.3 GB/s/TiB (~3 GB/s aggregate). Enough for Kimi K2 (959 GB) + DeepSeek / Qwen
variants + headroom.

## Scripts

| Script | Purpose |
|---|---|
| `scripts/fsx-lib.sh` | Region profiles + helpers (source only) |
| `scripts/fsx-sg-setup.sh <region>` | Idempotent SG (988 + 1018-1023 ingress from GPU node SG) |
| `scripts/fsx-create.sh <region>` | Idempotent FSx create, waits until AVAILABLE |
| `scripts/fsx-status.sh [region]` | Print mount details (DNS, MountName) |
| `scripts/fsx-destroy.sh <region> --yes [--drop-sg]` | Tear down |

## CSI driver

Install **aws-fsx-csi-driver** (static provisioning only — we don't need dynamic
CreateVolume because the FS is long-lived):

```bash
# Ohio cluster
aws eks update-kubeconfig --region us-east-2 --name gpu-cluster-ohio
helm repo add aws-fsx-csi-driver https://kubernetes-sigs.github.io/aws-fsx-csi-driver
helm repo update
helm upgrade --install aws-fsx-csi-driver aws-fsx-csi-driver/aws-fsx-csi-driver \
  --namespace kube-system

# Repeat for Oregon cluster
aws eks update-kubeconfig --region us-west-2 --name gpu-cluster-oregon
helm upgrade --install aws-fsx-csi-driver aws-fsx-csi-driver/aws-fsx-csi-driver \
  --namespace kube-system
```

No extra IAM needed for static provisioning (CSI driver only mounts).

## Static PV / PVC

`pv-pvc.yaml.tpl` is a template with `__FS_ID__`, `__DNS__`, `__MOUNT__`
placeholders — fill from `fsx-status.sh` output.

Helper:

```bash
./scripts/fsx-apply-pvpvc.sh us-east-2 gpu-cluster-ohio
./scripts/fsx-apply-pvpvc.sh us-west-2 gpu-cluster-oregon
```

The helper queries FSx for the real IDs, renders the manifest, and `kubectl
apply -f -`.

## Model prefetch on FSx

See `../../archive/stage1-4/stage4-p5en/model-prefetch-fsx.yaml` — one-shot Job
that downloads a HF model into the FSx PVC.

> ⚠️ **Deprecated**: Stage 5 起所有模型权重走 S3 → 节点本地 NVMe，不再用 FSx
> （见 `reference_s3_model_cache.md` / `feedback_load_models_from_s3.md`）。
> 本 manifest 仅作历史参考。

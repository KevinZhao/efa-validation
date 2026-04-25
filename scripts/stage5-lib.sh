#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Stage 5 common profiles / helpers. Sourced by scripts/stage5-*.sh.
# -----------------------------------------------------------------------------
# Layout:
#   - Two regions, each with its own EKS cluster, GPU nodegroup, FSx cache,
#     and ECR image. Pick with REGION={us-east-2|us-west-2}.
#   - Namespace: yanxi-validation (same as Stage 4).
#   - All manifests live under manifests/stage5-p5en/<run>.yaml.
#   - All results go under results/stage5-p5en/<run>/.
# -----------------------------------------------------------------------------
set -euo pipefail

export STAGE5_NS="${STAGE5_NS:-yanxi-validation}"
export STAGE5_PVC="${STAGE5_PVC:-yanxi-model-cache}"

# Model paths on FSx (set by the prefetcher; dir == repo basename).
export M_QWEN3_NEXT="/models/Qwen3-Next-80B-A3B-Instruct"
export M_QWEN3_235B="/models/Qwen3-235B-A22B-Instruct-2507-FP8"
export M_GLM46="/models/GLM-4.6"
export M_DEEPSEEK_V31="/models/DeepSeek-V3.1"
export M_KIMI_K2="/models/Kimi-K2-Instruct-0905"

stage5_load_region() {
  local region="$1"
  case "$region" in
    us-east-2)
      export STAGE5_REGION="us-east-2"
      export STAGE5_CLUSTER="gpu-cluster-ohio"
      export STAGE5_NG_P5EN="gpu-p5en-spot-useast2a"
      export STAGE5_ECR_IMAGE="788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/sglang-mooncake:v2"
      # GPU NG in us-east-2a, FSx in us-east-2b — cross-AZ mount via VPC router.
      export STAGE5_GPU_AZ="us-east-2a"
      export STAGE5_FSX_AZ="us-east-2b"
      ;;
    us-west-2)
      export STAGE5_REGION="us-west-2"
      export STAGE5_CLUSTER="gpu-cluster-oregon"
      export STAGE5_NG_P5EN="gpu-p5en-48xlarge-spot"
      export STAGE5_ECR_IMAGE="788668107894.dkr.ecr.us-west-2.amazonaws.com/yanxi/sglang-mooncake:v2"
      export STAGE5_GPU_AZ="us-west-2b"
      export STAGE5_FSX_AZ="us-west-2b"
      ;;
    *)
      echo "stage5_load_region: unknown region '$region' (want us-east-2 | us-west-2)" >&2
      return 1
      ;;
  esac
}

stage5_kubeconfig() {
  aws eks update-kubeconfig --region "${STAGE5_REGION}" --name "${STAGE5_CLUSTER}" >/dev/null
}

# stage5_ng_scale DESIRED — resize the p5en nodegroup to DESIRED nodes.
# Requires stage5_load_region to have been called.
stage5_ng_scale() {
  local desired="$1"
  aws eks update-nodegroup-config \
    --region "${STAGE5_REGION}" \
    --cluster-name "${STAGE5_CLUSTER}" \
    --nodegroup-name "${STAGE5_NG_P5EN}" \
    --scaling-config "minSize=0,maxSize=7,desiredSize=${desired}" \
    --query 'update.{id:id,status:status}' --output json
}

# stage5_ng_status — print current nodegroup scaling + EC2 instance state.
stage5_ng_status() {
  aws eks describe-nodegroup \
    --region "${STAGE5_REGION}" \
    --cluster-name "${STAGE5_CLUSTER}" \
    --nodegroup-name "${STAGE5_NG_P5EN}" \
    --query 'nodegroup.{desired:scalingConfig.desiredSize,min:scalingConfig.minSize,max:scalingConfig.maxSize,status:status}' \
    --output json
  echo "--- p5en instances ---"
  aws ec2 describe-instances \
    --region "${STAGE5_REGION}" \
    --filters "Name=instance-type,Values=p5en.48xlarge" \
              "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[].Instances[].[InstanceId,State.Name,LaunchTime,Placement.AvailabilityZone,PrivateIpAddress]' \
    --output table
}

# stage5_result_dir RUN_ID — create and echo results/stage5-p5en/<run>/<UTC-stamp>/
stage5_result_dir() {
  local run="$1"
  local root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  local out="${root}/results/stage5-p5en/${run}/${stamp}"
  mkdir -p "${out}"
  local latest="${root}/results/stage5-p5en/${run}/latest"
  ln -sfn "${stamp}" "${latest}"
  echo "${out}"
}

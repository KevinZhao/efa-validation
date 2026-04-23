#!/usr/bin/env bash
# Common helpers for Yanxi EFA validation orchestration.
# Sourced by other scripts, not executed directly.

set -euo pipefail

# -------- constants --------
export AWS_REGION_PRIMARY="${AWS_REGION_PRIMARY:-us-east-2}"
export AWS_REGION_FALLBACK="${AWS_REGION_FALLBACK:-us-west-2}"

export OHIO_BASTION="${OHIO_BASTION:-i-0341d214635c1ca74}"
export OREGON_BASTION="${OREGON_BASTION:-i-081b2b010b6af530c}"
export BUILDER_ID="${BUILDER_ID:-i-0f6dc7baf7825b30f}"

export OHIO_CLUSTER="gpu-cluster-ohio"
export OREGON_CLUSTER="gpu-cluster-oregon"

export ECR_REG="788668107894.dkr.ecr.us-east-2.amazonaws.com"
export ECR_BASE="${ECR_REG}/yanxi/base-cuda-efa"
export ECR_NCCL="${ECR_REG}/yanxi/nccl-tests"
export ECR_UCCL="${ECR_REG}/yanxi/uccl-ep"
export ECR_SGLANG="${ECR_REG}/yanxi/sglang-mooncake"

export S3_BUCKET="${S3_BUCKET:-yanxi-validation-788668107894}"

export REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SSM_PAYLOADS="${REPO_ROOT}/ssm-payloads"
export LOG_DIR="${REPO_ROOT}/logs"

# -------- helpers --------
log() {
  printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2
}

ts() {
  date -u +%Y%m%dT%H%M%SZ
}

# ssm_run REGION INSTANCE_ID PAYLOAD_FILE [COMMENT]
# Submits command and polls until done, streams output, returns exit code.
ssm_run() {
  local region="$1" instance="$2" payload="$3" comment="${4:-yanxi-validation}"
  local cid
  cid=$(aws ssm send-command --region "$region" --instance-ids "$instance" \
    --document-name "AWS-RunShellScript" \
    --parameters "file://${payload}" \
    --comment "$comment" \
    --query 'Command.CommandId' --output text)
  log "ssm cid=$cid ($comment) region=$region instance=$instance"
  local status
  for _ in $(seq 1 60); do
    sleep 5
    status=$(aws ssm get-command-invocation --region "$region" \
      --command-id "$cid" --instance-id "$instance" \
      --query 'Status' --output text 2>/dev/null || echo "InProgress")
    case "$status" in
      Success|Failed|Cancelled|TimedOut) break ;;
    esac
  done
  aws ssm get-command-invocation --region "$region" \
    --command-id "$cid" --instance-id "$instance" \
    --query '{status:Status,exit:ResponseCode,out:StandardOutputContent,err:StandardErrorContent}' \
    --output json
  [ "$status" = "Success" ]
}

# ssm_run_bg REGION INSTANCE_ID PAYLOAD_FILE COMMENT
# Kicks off and returns CID only; caller polls with ssm_check.
ssm_run_bg() {
  local region="$1" instance="$2" payload="$3" comment="$4"
  aws ssm send-command --region "$region" --instance-ids "$instance" \
    --document-name "AWS-RunShellScript" \
    --parameters "file://${payload}" \
    --comment "$comment" \
    --query 'Command.CommandId' --output text
}

ssm_check() {
  local region="$1" cid="$2" instance="$3"
  aws ssm get-command-invocation --region "$region" \
    --command-id "$cid" --instance-id "$instance" \
    --query '{status:Status,exit:ResponseCode,out:StandardOutputContent,err:StandardErrorContent}' \
    --output json
}

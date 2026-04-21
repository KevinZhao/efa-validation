#!/usr/bin/env bash
# Common helpers for the EFA validation orchestration.
# Sourced by other scripts, not executed directly.
#
# Configuration is read from the .env file at the repo root. Copy
# .env.example to .env and fill in the placeholders before sourcing.

set -euo pipefail

export REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "${REPO_ROOT}/.env" ]; then
  # shellcheck disable=SC1091
  set -a; . "${REPO_ROOT}/.env"; set +a
fi

: "${AWS_ACCOUNT_ID:?set AWS_ACCOUNT_ID in .env}"
: "${AWS_REGION_PRIMARY:=us-east-2}"
: "${AWS_REGION_FALLBACK:=us-west-2}"
: "${OHIO_BASTION:?set OHIO_BASTION in .env}"
: "${OREGON_BASTION:?set OREGON_BASTION in .env}"
: "${BUILDER_ID:?set BUILDER_ID in .env}"
: "${OHIO_CLUSTER:?set OHIO_CLUSTER in .env}"
: "${OREGON_CLUSTER:?set OREGON_CLUSTER in .env}"

export ECR_REG="${ECR_REG:-${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION_PRIMARY}.amazonaws.com}"
export ECR_BASE="${ECR_REG}/efa-validation/base-cuda-efa"
export ECR_NCCL="${ECR_REG}/efa-validation/nccl-tests"
export ECR_UCCL="${ECR_REG}/efa-validation/uccl-ep"
export ECR_MOONCAKE="${ECR_REG}/efa-validation/mooncake-nixl"
export ECR_SGLANG="${ECR_REG}/efa-validation/sglang-mooncake"

export S3_BUCKET="${S3_BUCKET:-efa-validation-${AWS_ACCOUNT_ID}}"

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
  local region="$1" instance="$2" payload="$3" comment="${4:-efa-validation}"
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

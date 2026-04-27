#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Launch a one-shot c8gn Graviton On-Demand EC2 Fleet instance that downloads
# the Stage-5 model catalog from Hugging Face and uploads to a regional S3
# bucket. Self-terminates on success.
#
#   Usage:
#     ./s3-prefetch-launch.sh us-east-2
#     ./s3-prefetch-launch.sh us-west-2
#
# Prereqs:
#   - S3 bucket: yanxi-validation-788668107894-{ohio,oregon}
#   - VPC gateway endpoint to S3 (already in place in both VPCs)
#   - JD-SSM-Role has inline policy yanxi-model-prefetch-s3-write
#   - HF_TOKEN stored in ~/.claude/.../memory/reference_hf_token.md
#     (read & inlined into UserData by this launcher; not committed anywhere)
# -----------------------------------------------------------------------------
set -euo pipefail

REGION="${1:-}"
if [ -z "$REGION" ]; then
  echo "usage: $0 <us-east-2|us-west-2>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# Reuse subnet + SG decisions from fsx-lib.sh (same AZ as GPU nodes, same VPC).
# shellcheck source=fsx-lib.sh
source "${SCRIPT_DIR}/fsx-lib.sh"
fsx_load_region "$REGION"

log() { printf '[%s] [%s] %s\n' "$(date -u +%H:%M:%S)" "$REGION" "$*" >&2; }

case "$REGION" in
  us-east-2) S3_BUCKET="yanxi-validation-788668107894-ohio"   ;;
  us-west-2) S3_BUCKET="yanxi-validation-788668107894-oregon" ;;
  *) echo "unsupported region $REGION" >&2; exit 2 ;;
esac
S3_PREFIX="models"
log "S3 target: s3://${S3_BUCKET}/${S3_PREFIX}/"

# MODELS_OVERRIDE: space-separated list. If empty, uses the default Stage-5 set.
# Example:
#   MODELS_OVERRIDE="deepseek-ai/DeepSeek-V4-Pro deepseek-ai/DeepSeek-V4-Flash" \
#     ./s3-prefetch-launch.sh us-east-2
if [ -n "${MODELS_OVERRIDE:-}" ]; then
  # shellcheck disable=SC2206
  MODEL_LIST=( $MODELS_OVERRIDE )
else
  MODEL_LIST=(
    "Qwen/Qwen3-Next-80B-A3B-Instruct"
    "Qwen/Qwen3-235B-A22B-Instruct-2507-FP8"
    "zai-org/GLM-4.6"
    "deepseek-ai/DeepSeek-V3.1"
    "moonshotai/Kimi-K2-Instruct-0905"
  )
fi
# Render as newline-quoted entries for the bash array in UserData.
models_block=""
for m in "${MODEL_LIST[@]}"; do
  models_block+="  \"${m}\""$'\n'
done
log "models to fetch:"
for m in "${MODEL_LIST[@]}"; do log "  - $m"; done

# --- HF token lookup --------------------------------------------------------
HF_TOKEN_FILE="${HOME}/.claude/projects/-home-ec2-user-workspace-efa-validation/memory/reference_hf_token.md"
if [ ! -f "$HF_TOKEN_FILE" ]; then
  echo "hf-token memory file missing: $HF_TOKEN_FILE" >&2
  exit 1
fi
HF_TOKEN="$(grep -oE 'hf_[A-Za-z0-9]+' "$HF_TOKEN_FILE" | head -n1)"
if [ -z "$HF_TOKEN" ]; then
  echo "could not extract hf_... token from $HF_TOKEN_FILE" >&2
  exit 1
fi
log "HF_TOKEN loaded (len=${#HF_TOKEN})"

# --- ARM64 AL2023 AMI -------------------------------------------------------
ami=$(aws ssm get-parameter --region "$REGION" \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
  --query Parameter.Value --output text)
log "AMI (arm64): ${ami}"

# --- Instance types (Graviton, 200+ Gbps, no instance-store so root is large) -
# c8gn is Graviton4 + 200 Gbps ENA. Fall back through c8gn sizes / c7gn.
INSTANCE_TYPES=(
  "c8gn.16xlarge"   # 64  vCPU, 128 GiB, 200 Gbps
  "c8gn.24xlarge"   # 96  vCPU, 192 GiB, 300 Gbps
  "c8gn.48xlarge"   # 192 vCPU, 384 GiB, 600 Gbps (overkill, fallback only)
  "c7gn.16xlarge"   # 64  vCPU, 128 GiB, 200 Gbps (Graviton3)
)

# --- Security group ---------------------------------------------------------
# Use the GPU node SG. It already has egress for HTTPS (HF) and DNS.
# All S3 traffic goes through the VPC gateway endpoint so no extra rules needed.
SG_ID="$FSX_GPU_NODE_SG"
log "SG: ${SG_ID}"

# --- Render UserData --------------------------------------------------------
tmpl="${SCRIPT_DIR}/s3-prefetch-userdata.sh.tpl"
rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT

# Escape slashes and ampersands in the token for sed (safe for hf_...).
safe_token=$(printf '%s' "$HF_TOKEN" | sed 's|[&/\]|\\&|g')
sed \
  -e "s|__REGION__|${REGION}|g" \
  -e "s|__S3_BUCKET__|${S3_BUCKET}|g" \
  -e "s|__S3_PREFIX__|${S3_PREFIX}|g" \
  -e "s|__HF_TOKEN__|${safe_token}|g" \
  -e "s|__LOG_BUCKET__|${LOG_BUCKET:-${S3_BUCKET}}|g" \
  "$tmpl" > "$rendered"
# __MODELS__ substitution (multi-line). Use python to avoid newline escaping
# issues in sed/awk.
MODELS_BLOCK="$models_block" python3 -c '
import os, sys
p = sys.argv[1]
block = os.environ["MODELS_BLOCK"].rstrip("\n")
with open(p) as f: src = f.read()
with open(p, "w") as f: f.write(src.replace("__MODELS_PLACEHOLDER__", block))
' "$rendered"
ud_b64=$(base64 -w0 "$rendered")

# --- IAM profile ------------------------------------------------------------
INSTANCE_PROFILE="${PREFETCH_INSTANCE_PROFILE:-JD-SSM-Profile}"
log "Instance profile: ${INSTANCE_PROFILE}"

# --- Launch template + EC2 Fleet (On-Demand) --------------------------------
NAME="yanxi-s3-prefetch-${REGION}-$(date -u +%Y%m%dT%H%M%SZ)"
log "creating launch template for On-Demand c8gn family in ${FSX_SUBNET}"

lt_data=$(jq -n \
  --arg ami "$ami" \
  --arg sg "$SG_ID" \
  --arg profile "$INSTANCE_PROFILE" \
  --arg ud "$ud_b64" \
  --arg name "$NAME" \
  '{
    ImageId: $ami,
    IamInstanceProfile: { Name: $profile },
    UserData: $ud,
    InstanceInitiatedShutdownBehavior: "terminate",
    NetworkInterfaces: [{
      DeviceIndex: 0,
      AssociatePublicIpAddress: true,
      Groups: [ $sg ]
    }],
    BlockDeviceMappings: [{
      DeviceName: "/dev/xvda",
      Ebs: {
        VolumeSize: 2000,
        VolumeType: "gp3",
        Iops: 16000,
        Throughput: 1000,
        DeleteOnTermination: true
      }
    }],
    TagSpecifications: [
      { ResourceType: "instance", Tags: [
          { Key: "Name",           Value: $name },
          { Key: "Project",        Value: "yanxi-validation" },
          { Key: "Stack",          Value: "s3-model-prefetch" },
          { Key: "auto-terminate", Value: "true" }
      ]},
      { ResourceType: "volume", Tags: [
          { Key: "Name",    Value: ($name + "-root") },
          { Key: "Project", Value: "yanxi-validation" },
          { Key: "Stack",   Value: "s3-model-prefetch" }
      ]}
    ]
  }')

lt_id=$(aws ec2 create-launch-template --region "$REGION" \
  --launch-template-name "${NAME}-lt" \
  --launch-template-data "$lt_data" \
  --query 'LaunchTemplate.LaunchTemplateId' --output text)
log "launch template: ${lt_id}"

overrides='[]'
for it in "${INSTANCE_TYPES[@]}"; do
  overrides=$(jq --arg it "$it" --arg subnet "$FSX_SUBNET" \
    '. + [{ InstanceType: $it, SubnetId: $subnet }]' <<< "$overrides")
done

fleet_cfg=$(mktemp)
trap 'rm -f "$rendered" "$fleet_cfg"' EXIT
jq -n --argjson overrides "$overrides" --arg lt "$lt_id" \
  '{
    LaunchTemplateConfigs: [{
      LaunchTemplateSpecification: { LaunchTemplateId: $lt, Version: "$Latest" },
      Overrides: $overrides
    }],
    TargetCapacitySpecification: {
      TotalTargetCapacity: 1,
      OnDemandTargetCapacity: 1,
      SpotTargetCapacity: 0,
      DefaultTargetCapacityType: "on-demand"
    },
    OnDemandOptions: {
      AllocationStrategy: "lowest-price"
    },
    Type: "instant"
  }' > "$fleet_cfg"

fleet_json=$(aws ec2 create-fleet --region "$REGION" --cli-input-json "file://$fleet_cfg" --output json)
fleet_id=$(echo "$fleet_json" | jq -r '.FleetId')
iid=$(echo "$fleet_json" | jq -r '.Instances[0].InstanceIds[0] // empty')

if [ -z "$iid" ] || [ "$iid" = "None" ]; then
  log "EC2 Fleet rejected all candidates:"
  echo "$fleet_json" | jq '.Errors'
  exit 1
fi

actual_type=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$iid" \
  --query 'Reservations[0].Instances[0].InstanceType' --output text 2>/dev/null || echo unknown)
log "fleet ${fleet_id} produced instance ${iid} (${actual_type})"
log "watch progress:"
log "  aws ec2 describe-instances --region ${REGION} --instance-ids ${iid} --query 'Reservations[0].Instances[0].State.Name' --output text"
log "  aws ssm start-session --region ${REGION} --target ${iid}"
log "  (inside the box) tail -F /var/log/yanxi-s3-prefetch.log"

# Persist a record.
records="${REPO_ROOT}/logs/s3-prefetch-launches.ndjson"
mkdir -p "$(dirname "$records")"
jq -c -n \
  --arg region "$REGION" \
  --arg iid "$iid" \
  --arg fleet_id "$fleet_id" \
  --arg name "$NAME" \
  --arg type "$actual_type" \
  --arg bucket "$S3_BUCKET" \
  --arg prefix "$S3_PREFIX" \
  --arg subnet "$FSX_SUBNET" \
  --arg sg "$SG_ID" \
  --arg ami "$ami" \
  --arg launched_at "$(date -u -Is)" \
  '{region:$region, instance_id:$iid, fleet_id:$fleet_id, name:$name, type:$type, bucket:$bucket, prefix:$prefix, subnet:$subnet, sg:$sg, ami:$ami, launched_at:$launched_at}' \
  >> "$records"

echo "$iid"

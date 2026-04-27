#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Create/update the yanxi FSx Lustre security group in one region.
#
#   Usage:
#     ./fsx-sg-setup.sh us-east-2
#     ./fsx-sg-setup.sh us-west-2
#
# Idempotent: re-run safe. Prints the final SG id on stdout.
#
# Allows the GPU node SG to reach the FSx SG on the Lustre client ports:
#   - TCP 988    (management)
#   - TCP 1018-1023 (LNET / data)
# -----------------------------------------------------------------------------
set -euo pipefail

REGION="${1:-}"
if [ -z "$REGION" ]; then
  echo "usage: $0 <region>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fsx-lib.sh
source "${SCRIPT_DIR}/fsx-lib.sh"
fsx_load_region "$REGION"

log() { printf '[%s] [%s] %s\n' "$(date -u +%H:%M:%S)" "$REGION" "$*" >&2; }

sg_id="$(fsx_sg_id "$REGION")"
if [ -z "$sg_id" ]; then
  log "creating SG ${FSX_SG_NAME} in ${FSX_VPC}"
  sg_id=$(aws ec2 create-security-group --region "$REGION" \
    --group-name "${FSX_SG_NAME}" \
    --description "FSx for Lustre - yanxi-validation model cache" \
    --vpc-id "${FSX_VPC}" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=${FSX_TAG_PROJECT}},{Key=Stack,Value=${FSX_TAG_STACK}},{Key=Name,Value=${FSX_SG_NAME}}]" \
    --query 'GroupId' --output text)
  log "created $sg_id"
else
  log "SG already exists: $sg_id"
fi

# Inbound rule: allow GPU node SG on TCP 988 + 1018-1023. Self-referencing as well
# so FSx servers can talk amongst themselves (best practice).
ensure_rule() {
  local proto="$1" from="$2" to="$3" src_sg="$4" desc="$5"
  local exists
  exists=$(aws ec2 describe-security-group-rules --region "$REGION" \
    --filters "Name=group-id,Values=${sg_id}" \
    --query "SecurityGroupRules[?IsEgress==\`false\` && IpProtocol=='${proto}' && FromPort==\`${from}\` && ToPort==\`${to}\` && ReferencedGroupInfo.GroupId=='${src_sg}'].SecurityGroupRuleId | [0]" \
    --output text 2>/dev/null | sed 's/^None$//')
  if [ -n "$exists" ]; then
    log "  rule already present: ${proto}/${from}-${to} from ${src_sg}"
    return
  fi
  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$sg_id" \
    --ip-permissions "IpProtocol=${proto},FromPort=${from},ToPort=${to},UserIdGroupPairs=[{GroupId=${src_sg},Description=\"${desc}\"}]" \
    >/dev/null
  log "  added ${proto}/${from}-${to} from ${src_sg}"
}

ensure_rule tcp 988  988  "${FSX_GPU_NODE_SG}" "lustre mgmt from GPU nodes"
ensure_rule tcp 1018 1023 "${FSX_GPU_NODE_SG}" "lustre data from GPU nodes"
# self-reference
ensure_rule tcp 988  988  "${sg_id}"          "lustre mgmt self"
ensure_rule tcp 1018 1023 "${sg_id}"          "lustre data self"

echo "$sg_id"

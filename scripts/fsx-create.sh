#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Create (idempotent) the yanxi FSx for Lustre file system in one region.
#
#   Usage:
#     ./fsx-create.sh us-east-2
#     ./fsx-create.sh us-west-2
#
# Behavior:
#   - Ensures the FSx SG exists (calls fsx-sg-setup.sh).
#   - If an FSx with Name=${FSX_NAME} already exists, prints its details and exits 0.
#   - Otherwise, creates a SCRATCH_2 FSx (${FSX_STORAGE_CAPACITY} GiB) in the
#     region's designated GPU subnet, tags it, and waits until AVAILABLE.
#
# Assumes current AWS creds can FSx:CreateFileSystem in the target region.
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

log "ensuring SG"
sg_id=$("${SCRIPT_DIR}/fsx-sg-setup.sh" "$REGION" | tail -n1)
log "SG: $sg_id"

existing=$(fsx_fs_id "$REGION")
if [ -n "$existing" ]; then
  log "FSx already exists (id=$existing); printing details and exiting"
  fsx_fs_details "$REGION" "$existing"
  exit 0
fi

client_token="yanxi-fsx-${REGION}-$(date -u +%Y%m%d%H%M%S)"
log "creating SCRATCH_2 FSx (${FSX_STORAGE_CAPACITY} GiB) in ${FSX_SUBNET} (${FSX_AZ})"
create_json=$(aws fsx create-file-system --region "$REGION" \
  --file-system-type LUSTRE \
  --file-system-type-version "${FSX_LUSTRE_VERSION}" \
  --storage-capacity "${FSX_STORAGE_CAPACITY}" \
  --subnet-ids "${FSX_SUBNET}" \
  --security-group-ids "${sg_id}" \
  --lustre-configuration "DeploymentType=${FSX_DEPLOYMENT_TYPE}" \
  --tags \
    "Key=Name,Value=${FSX_NAME}" \
    "Key=Project,Value=${FSX_TAG_PROJECT}" \
    "Key=Stack,Value=${FSX_TAG_STACK}" \
  --client-request-token "${client_token}" \
  --output json)

fs_id=$(echo "$create_json" | jq -r '.FileSystem.FileSystemId')
log "created $fs_id; waiting until AVAILABLE (can take 5-10 minutes)"

for _ in $(seq 1 90); do
  sleep 10
  life=$(aws fsx describe-file-systems --region "$REGION" --file-system-ids "$fs_id" \
    --query 'FileSystems[0].Lifecycle' --output text 2>/dev/null || echo "UNKNOWN")
  log "  lifecycle=$life"
  case "$life" in
    AVAILABLE) break ;;
    FAILED|DELETING|DELETED)
      log "unexpected lifecycle $life; aborting"
      exit 1
      ;;
  esac
done

final=$(aws fsx describe-file-systems --region "$REGION" --file-system-ids "$fs_id" \
  --query 'FileSystems[0].Lifecycle' --output text)
if [ "$final" != "AVAILABLE" ]; then
  log "timed out waiting for AVAILABLE (still $final)"
  exit 1
fi

log "FSx AVAILABLE: $fs_id"
fsx_fs_details "$REGION" "$fs_id"

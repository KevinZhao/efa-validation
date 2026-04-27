#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Destroy the yanxi FSx file system (and SG) in one region.
#
#   Usage:
#     ./fsx-destroy.sh us-east-2 --yes
#     ./fsx-destroy.sh us-west-2 --yes
#
# Requires --yes to actually delete (safety). Without --yes it's a dry run.
# Leaves the SG in place by default; pass --drop-sg to delete the SG too.
# -----------------------------------------------------------------------------
set -euo pipefail

REGION="${1:-}"
shift || true
CONFIRM=0
DROP_SG=0
for arg in "$@"; do
  case "$arg" in
    --yes) CONFIRM=1 ;;
    --drop-sg) DROP_SG=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [ -z "$REGION" ]; then
  echo "usage: $0 <region> [--yes] [--drop-sg]" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fsx-lib.sh
source "${SCRIPT_DIR}/fsx-lib.sh"
fsx_load_region "$REGION"

log() { printf '[%s] [%s] %s\n' "$(date -u +%H:%M:%S)" "$REGION" "$*" >&2; }

fsid=$(fsx_fs_id "$REGION")
if [ -z "$fsid" ]; then
  log "no FSx to delete (Name=${FSX_NAME})"
else
  log "target FSx: $fsid"
  if [ "$CONFIRM" != "1" ]; then
    log "DRY RUN — pass --yes to actually delete"
  else
    log "deleting $fsid"
    aws fsx delete-file-system --region "$REGION" --file-system-id "$fsid" >/dev/null
    for _ in $(seq 1 60); do
      sleep 10
      life=$(aws fsx describe-file-systems --region "$REGION" --file-system-ids "$fsid" \
        --query 'FileSystems[0].Lifecycle' --output text 2>/dev/null || echo "GONE")
      log "  lifecycle=$life"
      [ "$life" = "GONE" ] && break
      [ "$life" = "DELETED" ] && break
    done
  fi
fi

if [ "$DROP_SG" = "1" ]; then
  sg=$(fsx_sg_id "$REGION")
  if [ -z "$sg" ]; then
    log "no SG to drop"
  elif [ "$CONFIRM" != "1" ]; then
    log "DRY RUN — would delete SG $sg"
  else
    log "deleting SG $sg"
    aws ec2 delete-security-group --region "$REGION" --group-id "$sg" >/dev/null
  fi
fi

log "done"

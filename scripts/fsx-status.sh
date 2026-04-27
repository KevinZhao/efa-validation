#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Print status + mount info for the yanxi FSx in one or all regions.
#
#   Usage:
#     ./fsx-status.sh            # both regions
#     ./fsx-status.sh us-east-2  # just Ohio
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fsx-lib.sh
source "${SCRIPT_DIR}/fsx-lib.sh"

regions=()
if [ $# -eq 0 ]; then
  regions=(us-east-2 us-west-2)
else
  regions=("$@")
fi

for region in "${regions[@]}"; do
  fsx_load_region "$region"
  fsid=$(fsx_fs_id "$region")
  if [ -z "$fsid" ]; then
    printf '\n=== %s ===\nno FSx with Name=%s\n' "$region" "$FSX_NAME"
    continue
  fi
  printf '\n=== %s ===\n' "$region"
  fsx_fs_details "$region" "$fsid"
done

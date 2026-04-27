#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Render manifests/fsx/pv-pvc.yaml.tpl with real FSx details, then apply to the
# cluster in the requested region.
#
#   Usage:
#     ./fsx-apply-pvpvc.sh us-east-2 gpu-cluster-ohio
#     ./fsx-apply-pvpvc.sh us-west-2 gpu-cluster-oregon
#
# Requires:
#   - FSx already AVAILABLE (call fsx-create.sh first)
#   - kubectl configured (this script calls aws eks update-kubeconfig)
#   - namespace yanxi-validation exists
# -----------------------------------------------------------------------------
set -euo pipefail

REGION="${1:-}"
CLUSTER="${2:-}"
if [ -z "$REGION" ] || [ -z "$CLUSTER" ]; then
  echo "usage: $0 <region> <cluster-name>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=fsx-lib.sh
source "${SCRIPT_DIR}/fsx-lib.sh"
fsx_load_region "$REGION"

log() { printf '[%s] [%s] %s\n' "$(date -u +%H:%M:%S)" "$REGION" "$*" >&2; }

fsid=$(fsx_fs_id "$REGION")
if [ -z "$fsid" ]; then
  echo "no FSx with Name=${FSX_NAME} in ${REGION}; run fsx-create.sh first" >&2
  exit 1
fi

details=$(fsx_fs_details "$REGION" "$fsid")
life=$(echo "$details" | jq -r '.lifecycle')
if [ "$life" != "AVAILABLE" ]; then
  echo "FSx ${fsid} is in lifecycle ${life}; cannot mount yet" >&2
  exit 1
fi

dns=$(echo "$details" | jq -r '.dns')
mountname=$(echo "$details" | jq -r '.mount')
storage=$(echo "$details" | jq -r '.storage')

log "fsid=$fsid dns=$dns mount=$mountname capacity=${storage}GiB"

tmpl="${REPO_ROOT}/manifests/fsx/pv-pvc.yaml.tpl"
rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT

sed \
  -e "s|__FS_ID__|${fsid}|g" \
  -e "s|__DNS__|${dns}|g" \
  -e "s|__MOUNT__|${mountname}|g" \
  -e "s|__CAPACITY__|${storage}|g" \
  "$tmpl" > "$rendered"

log "rendered manifest:"
cat "$rendered" >&2

log "updating kubeconfig for ${CLUSTER}"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null

log "ensuring namespace yanxi-validation"
kubectl get ns yanxi-validation >/dev/null 2>&1 || kubectl create ns yanxi-validation

log "applying PV/PVC"
kubectl apply -f "$rendered"

log "status:"
kubectl get pv yanxi-model-cache-pv
kubectl -n yanxi-validation get pvc yanxi-model-cache

#!/usr/bin/env bash
# =============================================================================
# build-mooncake-nixl-uccl-image.sh — build the internal A/B comparison image
# that contains Mooncake TE + NIXL + UCCL-EP + SGLang side by side.
#
# Purpose: lets the same pod toggle
#   python -m sglang.launch_server --disaggregation-transfer-backend mooncake
#   python -m sglang.launch_server --disaggregation-transfer-backend nixl
# keeping every other dep byte-identical so KV-transfer perf delta is
# attributable to the transport layer only.
#
# Usage:
#   ./scripts/build-mooncake-nixl-uccl-image.sh [DATE] [ARCH]
#   ./scripts/build-mooncake-nixl-uccl-image.sh 2026.04.30 h200
#   ./scripts/build-mooncake-nixl-uccl-image.sh        # auto date, h200
#
# Env overrides (ad-hoc):
#   MOONCAKE_REF=<sha>  UCCL_REF=<sha>  NIXL_REF=<tag>  UCX_VERSION=<tag>
#   SGLANG_VERSION=0.5.10  TAG_SUFFIX=.1   DRY_RUN=1
#
# NOT a customer release. Private ECR only (no public.ecr.aws push).
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DATE="${1:-$(date -u +%Y.%m.%d)}"
ARCH="${2:-h200}"
TAG_SUFFIX="${TAG_SUFFIX:-}"

# Pins. Mooncake + UCCL match customer-h200.5 so the shared code is identical.
MOONCAKE_REF="${MOONCAKE_REF:-634b7097}"
UCCL_REF="${UCCL_REF:-8ac850bd}"
NIXL_REF="${NIXL_REF:-v1.0.1}"
UCX_VERSION="${UCX_VERSION:-v1.18.0}"
SGLANG_VERSION="${SGLANG_VERSION:-0.5.10}"

DRY_RUN="${DRY_RUN:-0}"

VCS_REF=$(cd "${REPO_ROOT}" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

IMAGE_NAME="sglang-mooncake-nixl-uccl"
TAG_PRIMARY="${DATE}-${ARCH}${TAG_SUFFIX}"

PRIVATE_IMAGE="${ECR_REG}/yanxi/${IMAGE_NAME}:${TAG_PRIMARY}"

log "=== internal A/B comparison image build ==="
log "  image      : ${IMAGE_NAME}"
log "  tag        : ${TAG_PRIMARY}"
log "  mooncake   : ${MOONCAKE_REF}"
log "  uccl       : ${UCCL_REF}"
log "  nixl       : ${NIXL_REF}"
log "  ucx        : ${UCX_VERSION}"
log "  sglang     : ${SGLANG_VERSION}"
log "  arch       : ${ARCH} (TORCH_CUDA_ARCH_LIST=9.0)"
log "  private tag: ${PRIVATE_IMAGE}"
log "  vcs        : ${VCS_REF}  build_date=${BUILD_DATE}"
log "  (internal only — this script never pushes to public.ecr.aws)"

if [ "${DRY_RUN}" = "1" ]; then
  log "DRY_RUN=1, stopping before builder kickoff."
  exit 0
fi

# ---- Upload Dockerfile + patch overlay to S3 ----
# Dockerfile references patches/*.patch via COPY, so the patch files must
# ride along into the build context on the builder EC2.
DOCKERFILE_REL="common/Dockerfile.sglang-mooncake-nixl-uccl"
PATCH_DIR_REL="patches"
STAMP="$(ts)"
DOCKERFILE_S3_KEY="dockerfiles/sglang-mooncake-nixl-uccl-${STAMP}/Dockerfile"
PATCH_S3_PREFIX="dockerfiles/sglang-mooncake-nixl-uccl-${STAMP}/patches"

log "Uploading Dockerfile to s3://${S3_BUCKET}/${DOCKERFILE_S3_KEY}"
aws s3 cp "${REPO_ROOT}/${DOCKERFILE_REL}" "s3://${S3_BUCKET}/${DOCKERFILE_S3_KEY}" --quiet

PATCH_FILES=()
if [ -d "${REPO_ROOT}/${PATCH_DIR_REL}" ]; then
  while IFS= read -r f; do
    PATCH_FILES+=("$f")
  done < <(find "${REPO_ROOT}/${PATCH_DIR_REL}" -maxdepth 1 -type f -name '*.patch' | sort)
fi
if [ ${#PATCH_FILES[@]} -eq 0 ]; then
  log "WARN: no *.patch files under ${PATCH_DIR_REL}/ — Dockerfile COPY will fail if patches are referenced"
fi
for patch_local in "${PATCH_FILES[@]}"; do
  patch_name=$(basename "${patch_local}")
  log "Uploading patch: ${patch_name}"
  aws s3 cp "${patch_local}" "s3://${S3_BUCKET}/${PATCH_S3_PREFIX}/${patch_name}" --quiet
done

# ---- Build command ----
BUILD_CMD="docker build --progress=plain"
BUILD_CMD="${BUILD_CMD} --build-arg IMAGE_VERSION=${TAG_PRIMARY}"
BUILD_CMD="${BUILD_CMD} --build-arg BUILD_DATE=${BUILD_DATE}"
BUILD_CMD="${BUILD_CMD} --build-arg VCS_REF=${VCS_REF}"
BUILD_CMD="${BUILD_CMD} --build-arg MOONCAKE_REF=${MOONCAKE_REF}"
BUILD_CMD="${BUILD_CMD} --build-arg UCCL_REF=${UCCL_REF}"
BUILD_CMD="${BUILD_CMD} --build-arg NIXL_REF=${NIXL_REF}"
BUILD_CMD="${BUILD_CMD} --build-arg UCX_VERSION=${UCX_VERSION}"
BUILD_CMD="${BUILD_CMD} --build-arg SGLANG_VERSION=${SGLANG_VERSION}"
BUILD_CMD="${BUILD_CMD} --build-arg VARIANT=mooncake-nixl-uccl"
BUILD_CMD="${BUILD_CMD} -t ${PRIVATE_IMAGE} ."

PUSH_CMD="docker push ${PRIVATE_IMAGE}"

# Optional public push (opt-in via PUBLISH=1). Only pushes the primary tag;
# does not touch `latest`/monthly moving tags (this is an internal comparison
# image, moving tags are reserved for customer release streams).
PUBLISH="${PUBLISH:-0}"
PUBLIC_CMD=""
PUBLIC_IMAGE=""
if [ "${PUBLISH}" = "1" ]; then
  ECR_PUBLIC_ALIAS="${ECR_PUBLIC_ALIAS:-n3l4x8f3}"
  PUBLIC_IMAGE="public.ecr.aws/${ECR_PUBLIC_ALIAS}/${IMAGE_NAME}:${TAG_PRIMARY}"
  PUBLIC_CMD=" && aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws"
  PUBLIC_CMD="${PUBLIC_CMD} && docker tag ${PRIVATE_IMAGE} ${PUBLIC_IMAGE}"
  PUBLIC_CMD="${PUBLIC_CMD} && docker push ${PUBLIC_IMAGE}"
  log "  public tag : ${PUBLIC_IMAGE}"
fi

INNER="${BUILD_CMD} && ${PUSH_CMD}${PUBLIC_CMD} && echo BUILD_DONE"

# Build JSON payload using python (same pattern as build-customer-image.sh)
PAYLOAD_FILE=$(mktemp)
python3 - "${PAYLOAD_FILE}" <<PYEOF
import json, sys
path = sys.argv[1]
cmds = [
    "set -eux",
    "for i in \$(seq 1 12); do [ -f /tmp/builder-ready ] && break; sleep 5; done",
    "docker --version",
    "aws ecr get-login-password --region ${AWS_REGION_PRIMARY} | docker login --username AWS --password-stdin ${ECR_REG}",
    "WORKDIR=/root/build/sglang-mooncake-nixl-uccl-${STAMP}",
    "mkdir -p \$WORKDIR/patches && cd \$WORKDIR",
    "aws s3 cp s3://${S3_BUCKET}/${DOCKERFILE_S3_KEY} ./Dockerfile",
    "aws s3 sync s3://${S3_BUCKET}/${PATCH_S3_PREFIX}/ ./patches/ || echo 'no patches'",
    "ls -la ./patches/",
    "nohup bash -c '${INNER}' > \$WORKDIR/build.log 2>&1 &",
    "sleep 3",
    "echo build started, log=\$WORKDIR/build.log",
    "ps -ef | grep 'docker build' | grep -v grep || true",
]
with open(path, "w") as f:
    json.dump({"commands": cmds}, f)
PYEOF

log "Launching build on builder ${BUILDER_ID}"
CID=$(ssm_run_bg "${AWS_REGION_PRIMARY}" "${BUILDER_ID}" "${PAYLOAD_FILE}" "build-mooncake-nixl-uccl-${TAG_PRIMARY}")
log "ssm cid=${CID}"
mkdir -p "${LOG_DIR}/stage0-setup"
echo "${CID}" > "${LOG_DIR}/stage0-setup/build-sglang-mooncake-nixl-uccl-${STAMP}.cid"
rm -f "${PAYLOAD_FILE}"

log ""
log "Build kicked off. Poll with:"
log "  ./scripts/build-watch.sh sglang-mooncake-nixl-uccl-${STAMP}"
log ""
log "When BUILD_DONE, pull and A/B test with:"
log "  docker pull ${PRIVATE_IMAGE}"
log "  # inside the pod:"
log "  python -m sglang.launch_server --disaggregation-transfer-backend mooncake ..."
log "  python -m sglang.launch_server --disaggregation-transfer-backend nixl     ..."

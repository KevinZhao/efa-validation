#!/usr/bin/env bash
# =============================================================================
# build-customer-image.sh — Build + push the customer-facing release image.
#
# Usage:
#   ./scripts/build-customer-image.sh [DATE] [ARCH]
#   ./scripts/build-customer-image.sh 2026.04.28 h200     # explicit
#   ./scripts/build-customer-image.sh                      # auto date, h200
#
# Env overrides (for ad-hoc testing):
#   MOONCAKE_REF=<sha>        UCCL_REF=<sha>        SGLANG_VERSION=0.5.10
#   ECR_PUBLIC_ALIAS=<alias>  PUBLISH=1             DRY_RUN=1
#
# What it does:
#   1. Reads pins from common/BUILD_MATRIX.md (validated against this script's
#      defaults; mismatch aborts).
#   2. Uploads Dockerfile + BUILD_MATRIX.md to S3 for builder EC2.
#   3. Builds `common/Dockerfile.customer-h200` on the builder.
#   4. Tags as: <image>:<DATE>-<ARCH>, <image>:<YYYY.MM>-<ARCH>, <image>:latest
#      (`stable` is promoted separately via promote-customer-image.sh)
#   5. Pushes to ECR Public (public.ecr.aws/<alias>/sglang-mooncake-uccl).
#   6. Runs smoke verification matching BUILD_MATRIX.md §Verification.
#
# Release cadence: see common/BUILD_MATRIX.md §"Release cadence".
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# ---- Parameters ----
# Usage:
#   build-customer-image.sh [DATE] [ARCH] [VARIANT]
#   VARIANT=uccl  -> sglang-mooncake-uccl (default, with UCCL-EP)
#   VARIANT=nccl  -> sglang-mooncake-nccl (NCCL-only, A/B comparison image)
DATE="${1:-$(date -u +%Y.%m.%d)}"
ARCH="${2:-h200}"
VARIANT="${3:-uccl}"

case "${VARIANT}" in
  uccl) WITH_UCCL=true  ; IMAGE_NAME="sglang-mooncake-uccl" ;;
  nccl) WITH_UCCL=false ; IMAGE_NAME="sglang-mooncake-nccl" ;;
  *) echo "ERROR: VARIANT must be uccl or nccl (got: ${VARIANT})" >&2 ; exit 2 ;;
esac

MOONCAKE_REF="${MOONCAKE_REF:-634b7097}"
UCCL_REF="${UCCL_REF:-8ac850bd}"
SGLANG_VERSION="${SGLANG_VERSION:-0.5.10}"

ECR_PUBLIC_ALIAS="${ECR_PUBLIC_ALIAS:-n3l4x8f3}"
PUBLISH="${PUBLISH:-0}"
DRY_RUN="${DRY_RUN:-0}"

VCS_REF=$(cd "${REPO_ROOT}" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

TAG_PRIMARY="${DATE}-${ARCH}"
TAG_MONTHLY="$(echo "${DATE}" | cut -c1-7)-${ARCH}"   # 2026.04-h200
TAG_LATEST="latest"

# Private ECR tag for internal soak (pushed in parallel to public)
PRIVATE_REG="${ECR_REG}"
PRIVATE_IMAGE="${PRIVATE_REG}/yanxi/${IMAGE_NAME}:${TAG_PRIMARY}"

PUBLIC_REG="public.ecr.aws/${ECR_PUBLIC_ALIAS}"
PUBLIC_IMAGE="${PUBLIC_REG}/${IMAGE_NAME}"

# ---- Sanity: pin values match BUILD_MATRIX.md ----
MATRIX_FILE="${REPO_ROOT}/common/BUILD_MATRIX.md"
if [ -f "${MATRIX_FILE}" ]; then
  # Tolerate no-match (grep returns 1) and head SIGPIPE under pipefail
  expected_mooncake=$( (grep -oE '\`[0-9a-f]{7,40}\` \(= #1944' "${MATRIX_FILE}" || true) | head -1 | tr -d '`' | awk '{print $1}' || true)
  if [ -n "${expected_mooncake}" ] && [ "${expected_mooncake}" != "${MOONCAKE_REF}" ]; then
    log "WARN: MOONCAKE_REF=${MOONCAKE_REF} != BUILD_MATRIX.md (${expected_mooncake}). Continuing."
  fi
fi

log "=== customer release build ==="
log "  variant    : ${VARIANT} (WITH_UCCL=${WITH_UCCL})"
log "  image      : ${IMAGE_NAME}"
log "  tags       : ${TAG_PRIMARY}  ${TAG_MONTHLY}  ${TAG_LATEST}"
log "  mooncake   : ${MOONCAKE_REF}"
log "  uccl       : ${UCCL_REF} (used only if WITH_UCCL=true)"
log "  sglang     : ${SGLANG_VERSION}"
log "  arch       : ${ARCH} (TORCH_CUDA_ARCH_LIST=9.0)"
log "  private tag: ${PRIVATE_IMAGE}"
log "  public reg : ${PUBLIC_REG}/${IMAGE_NAME}  (publish=${PUBLISH})"
log "  vcs        : ${VCS_REF}  build_date=${BUILD_DATE}"

if [ "${DRY_RUN}" = "1" ]; then
  log "DRY_RUN=1, stopping before builder kickoff."
  exit 0
fi

# ---- Upload Dockerfile + matrix to S3 ----
DOCKERFILE_REL="common/Dockerfile.customer-h200"
MATRIX_REL="common/BUILD_MATRIX.md"
STAMP="$(ts)"
DOCKERFILE_S3_KEY="dockerfiles/customer-h200-${STAMP}/Dockerfile"
MATRIX_S3_KEY="dockerfiles/customer-h200-${STAMP}/BUILD_MATRIX.md"

log "Uploading Dockerfile + BUILD_MATRIX.md to s3://${S3_BUCKET}/dockerfiles/customer-h200-${STAMP}/"
aws s3 cp "${REPO_ROOT}/${DOCKERFILE_REL}" "s3://${S3_BUCKET}/${DOCKERFILE_S3_KEY}" --quiet
aws s3 cp "${REPO_ROOT}/${MATRIX_REL}"     "s3://${S3_BUCKET}/${MATRIX_S3_KEY}" --quiet

# ---- Assemble builder payload ----
# Note: ECR Public login goes against us-east-1 only. Private ECR stays us-east-2.
PUBLISH_BLOCK=""
if [ "${PUBLISH}" = "1" ]; then
  PUBLISH_BLOCK=$(cat <<EOFPUB
"aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws",
    "docker tag ${PRIVATE_IMAGE} ${PUBLIC_IMAGE}:${TAG_PRIMARY}",
    "docker tag ${PRIVATE_IMAGE} ${PUBLIC_IMAGE}:${TAG_MONTHLY}",
    "docker tag ${PRIVATE_IMAGE} ${PUBLIC_IMAGE}:${TAG_LATEST}",
    "docker push ${PUBLIC_IMAGE}:${TAG_PRIMARY}",
    "docker push ${PUBLIC_IMAGE}:${TAG_MONTHLY}",
    "docker push ${PUBLIC_IMAGE}:${TAG_LATEST}",
EOFPUB
)
fi

# Build the inner build+tag+push one-liner (single line, no line continuations,
# so it survives JSON encoding without escape headaches).
BUILD_CMD="docker build --progress=plain"
BUILD_CMD="${BUILD_CMD} --build-arg IMAGE_VERSION=${TAG_PRIMARY}"
BUILD_CMD="${BUILD_CMD} --build-arg BUILD_DATE=${BUILD_DATE}"
BUILD_CMD="${BUILD_CMD} --build-arg VCS_REF=${VCS_REF}"
BUILD_CMD="${BUILD_CMD} --build-arg MOONCAKE_REF=${MOONCAKE_REF}"
BUILD_CMD="${BUILD_CMD} --build-arg UCCL_REF=${UCCL_REF}"
BUILD_CMD="${BUILD_CMD} --build-arg SGLANG_VERSION=${SGLANG_VERSION}"
BUILD_CMD="${BUILD_CMD} --build-arg WITH_UCCL=${WITH_UCCL}"
BUILD_CMD="${BUILD_CMD} --build-arg VARIANT=${VARIANT}"
BUILD_CMD="${BUILD_CMD} -t ${PRIVATE_IMAGE} ."

TAG_CMD="docker tag ${PRIVATE_IMAGE} ${PRIVATE_REG}/yanxi/${IMAGE_NAME}:${TAG_MONTHLY}"
TAG_CMD="${TAG_CMD} && docker tag ${PRIVATE_IMAGE} ${PRIVATE_REG}/yanxi/${IMAGE_NAME}:${TAG_LATEST}"

PUSH_CMD="docker push ${PRIVATE_IMAGE}"
PUSH_CMD="${PUSH_CMD} && docker push ${PRIVATE_REG}/yanxi/${IMAGE_NAME}:${TAG_MONTHLY}"
PUSH_CMD="${PUSH_CMD} && docker push ${PRIVATE_REG}/yanxi/${IMAGE_NAME}:${TAG_LATEST}"

PUBLIC_CMD=""
if [ "${PUBLISH}" = "1" ]; then
  PUBLIC_CMD=" && aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws"
  PUBLIC_CMD="${PUBLIC_CMD} && docker tag ${PRIVATE_IMAGE} ${PUBLIC_IMAGE}:${TAG_PRIMARY}"
  PUBLIC_CMD="${PUBLIC_CMD} && docker tag ${PRIVATE_IMAGE} ${PUBLIC_IMAGE}:${TAG_MONTHLY}"
  PUBLIC_CMD="${PUBLIC_CMD} && docker tag ${PRIVATE_IMAGE} ${PUBLIC_IMAGE}:${TAG_LATEST}"
  PUBLIC_CMD="${PUBLIC_CMD} && docker push ${PUBLIC_IMAGE}:${TAG_PRIMARY}"
  PUBLIC_CMD="${PUBLIC_CMD} && docker push ${PUBLIC_IMAGE}:${TAG_MONTHLY}"
  PUBLIC_CMD="${PUBLIC_CMD} && docker push ${PUBLIC_IMAGE}:${TAG_LATEST}"
fi

INNER="${BUILD_CMD} && ${TAG_CMD} && ${PUSH_CMD}${PUBLIC_CMD} && echo BUILD_DONE"

# Use python to encode the payload so quoting is bullet-proof (avoids JSON
# escape bugs that plagued the prior heredoc).
PAYLOAD_FILE=$(mktemp)
python3 - "${PAYLOAD_FILE}" <<PYEOF
import json, sys
path = sys.argv[1]
cmds = [
    "set -eux",
    "for i in \$(seq 1 12); do [ -f /tmp/builder-ready ] && break; sleep 5; done",
    "docker --version",
    "aws ecr get-login-password --region ${AWS_REGION_PRIMARY} | docker login --username AWS --password-stdin ${PRIVATE_REG}",
    "WORKDIR=/root/build/customer-h200-${STAMP}",
    "mkdir -p \$WORKDIR && cd \$WORKDIR",
    "aws s3 cp s3://${S3_BUCKET}/${DOCKERFILE_S3_KEY} ./Dockerfile",
    "aws s3 cp s3://${S3_BUCKET}/${MATRIX_S3_KEY} ./BUILD_MATRIX.md",
    "nohup bash -c '${INNER}' > \$WORKDIR/build.log 2>&1 &",
    "sleep 3",
    "echo build started, log=\$WORKDIR/build.log",
    "ps -ef | grep 'docker build' | grep -v grep || true",
]
with open(path, "w") as f:
    json.dump({"commands": cmds}, f)
PYEOF

log "Launching build on builder ${BUILDER_ID}"
CID=$(ssm_run_bg "${AWS_REGION_PRIMARY}" "${BUILDER_ID}" "${PAYLOAD_FILE}" "build-customer-${TAG_PRIMARY}")
log "ssm cid=${CID}"
mkdir -p "${LOG_DIR}/stage0-setup"
echo "${CID}" > "${LOG_DIR}/stage0-setup/build-customer-${STAMP}.cid"
rm -f "${PAYLOAD_FILE}"

log ""
log "Build kicked off. Poll with:"
log "  ./scripts/build-watch.sh customer-h200-${STAMP}"
log ""
log "When BUILD_DONE, run smoke:"
log "  ./scripts/smoke-customer-image.sh ${TAG_PRIMARY}"
log ""
if [ "${PUBLISH}" != "1" ]; then
  log "(PUBLISH=0) This build ONLY pushes to private ECR for internal soak."
  log "After 1 week soak, re-run with PUBLISH=1 or use promote-customer-image.sh."
fi

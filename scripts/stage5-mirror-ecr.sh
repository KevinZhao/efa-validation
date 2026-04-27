#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# stage5-mirror-ecr.sh — copy Stage 5 ECR images from Ohio (us-east-2) to
# another region (default us-west-2). Run only if we decide to migrate Stage 5
# runs to the backup region; Ohio is the primary (SPS=8 vs Oregon 6 on
# 2026-04-24).
#
# Strategy: pull → retag → push via docker. We don't use ECR replication rules
# because those only mirror *future* pushes, not existing tags.
#
# Usage:
#   scripts/stage5-mirror-ecr.sh              # mirror all Stage 5 repos to us-west-2
#   scripts/stage5-mirror-ecr.sh us-east-1    # to a different target region
#   scripts/stage5-mirror-ecr.sh us-west-2 sglang-mooncake:v2   # one image
# -----------------------------------------------------------------------------
set -euo pipefail

SRC_REGION="us-east-2"
DST_REGION="${1:-us-west-2}"
SINGLE_IMAGE="${2:-}"
AWS_ACCOUNT_ID="788668107894"

SRC_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${SRC_REGION}.amazonaws.com"
DST_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${DST_REGION}.amazonaws.com"

# Repos + tags we want to mirror. Keep this tight — each v2 image is ~14 GB.
# If we change the image pin, update this list (and the manifests).
declare -a IMAGES=(
  "yanxi/sglang-mooncake:v2"
  "yanxi/sglang-mooncake:v5"
  "yanxi/sglang-mooncake:v5-uccl"
  "yanxi/mooncake-nixl:v5"
  "yanxi/uccl-ep:v2"
  "yanxi/uccl-ep:latest"
  "yanxi/base-cuda-efa:v2"
  "yanxi/nccl-tests:v2"
)

if [ -n "${SINGLE_IMAGE}" ]; then
  # User explicitly asked for one image; allow short form "repo:tag".
  if [[ "${SINGLE_IMAGE}" != yanxi/* ]]; then
    SINGLE_IMAGE="yanxi/${SINGLE_IMAGE}"
  fi
  IMAGES=("${SINGLE_IMAGE}")
fi

echo "[mirror] src=${SRC_REGISTRY} dst=${DST_REGISTRY}"
echo "[mirror] images:"; printf '  - %s\n' "${IMAGES[@]}"

# ECR logins (both regions)
aws ecr get-login-password --region "${SRC_REGION}" | docker login --username AWS --password-stdin "${SRC_REGISTRY}"
aws ecr get-login-password --region "${DST_REGION}" | docker login --username AWS --password-stdin "${DST_REGISTRY}"

for img in "${IMAGES[@]}"; do
  repo="${img%%:*}"
  tag="${img##*:}"
  echo
  echo "[mirror] ===== ${repo}:${tag} ====="

  # Ensure dst repo exists
  if ! aws ecr describe-repositories --region "${DST_REGION}" --repository-names "${repo}" >/dev/null 2>&1; then
    echo "[mirror] creating ${DST_REGION} repo ${repo}"
    aws ecr create-repository --region "${DST_REGION}" --repository-name "${repo}" \
      --image-scanning-configuration scanOnPush=false \
      --image-tag-mutability MUTABLE >/dev/null
  fi

  # Skip if already mirrored
  if aws ecr describe-images --region "${DST_REGION}" --repository-name "${repo}" \
       --image-ids "imageTag=${tag}" >/dev/null 2>&1; then
    echo "[mirror] already present in ${DST_REGION}: ${repo}:${tag} — skipping"
    continue
  fi

  echo "[mirror] pulling ${SRC_REGISTRY}/${img}"
  docker pull "${SRC_REGISTRY}/${img}"
  echo "[mirror] tagging for ${DST_REGISTRY}"
  docker tag "${SRC_REGISTRY}/${img}" "${DST_REGISTRY}/${img}"
  echo "[mirror] pushing to ${DST_REGISTRY}"
  docker push "${DST_REGISTRY}/${img}"

  # Free local disk after each push — these images are 10-15 GB each.
  docker image rm -f "${DST_REGISTRY}/${img}" "${SRC_REGISTRY}/${img}" >/dev/null 2>&1 || true
done

echo
echo "[mirror] done"

#!/usr/bin/env bash
# Build a Docker image on yanxi-builder and push to ECR.
# Usage:
#   ./build-image.sh <dockerfile-rel-path-in-repo> <ecr-repo-short> <tag> [--build-arg=KEY=VAL ...]
# Examples:
#   ./build-image.sh common/Dockerfile.base-cuda-efa base-cuda-efa v1
#   ./build-image.sh common/Dockerfile.nccl-tests-v2 nccl-tests v1 --build-arg=BASE_IMAGE=$ECR_BASE:v1
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DOCKERFILE_REL="$1"; shift
REPO_SHORT="$1"; shift
TAG="$1"; shift
# remaining args: extra docker build flags (e.g. --build-arg=KEY=VAL)

DOCKERFILE_LOCAL="${REPO_ROOT}/${DOCKERFILE_REL}"
[ -f "$DOCKERFILE_LOCAL" ] || { echo "Dockerfile not found: $DOCKERFILE_LOCAL" >&2; exit 1; }

DOCKERFILE_S3_KEY="dockerfiles/$(basename "$DOCKERFILE_REL")-$(ts)"
ECR_IMAGE="${ECR_REG}/yanxi/${REPO_SHORT}"
STAMP="$(ts)"
LOG_S3_KEY="logs/build-${REPO_SHORT}-${STAMP}.log"

log "Uploading Dockerfile to s3://${S3_BUCKET}/${DOCKERFILE_S3_KEY}"
aws s3 cp "$DOCKERFILE_LOCAL" "s3://${S3_BUCKET}/${DOCKERFILE_S3_KEY}" --quiet

BUILD_ARGS_STR=""
for arg in "$@"; do
  # expect --build-arg=K=V
  BUILD_ARGS_STR+=" $arg"
done

PAYLOAD_FILE=$(mktemp)
cat > "$PAYLOAD_FILE" <<EOF
{
  "commands": [
    "set -eux",
    "for i in \$(seq 1 12); do [ -f /tmp/builder-ready ] && break; sleep 5; done",
    "docker --version",
    "aws ecr get-login-password --region ${AWS_REGION_PRIMARY} | docker login --username AWS --password-stdin ${ECR_REG}",
    "WORKDIR=/root/build/${REPO_SHORT}-${STAMP}",
    "mkdir -p \$WORKDIR && cd \$WORKDIR",
    "aws s3 cp s3://${S3_BUCKET}/${DOCKERFILE_S3_KEY} ./Dockerfile",
    "wc -l Dockerfile",
    "cd \$WORKDIR && nohup bash -c 'docker build --progress=plain${BUILD_ARGS_STR} -t ${ECR_IMAGE}:${TAG} . && docker tag ${ECR_IMAGE}:${TAG} ${ECR_IMAGE}:latest && docker push ${ECR_IMAGE}:${TAG} && docker push ${ECR_IMAGE}:latest && echo BUILD_DONE' > \$WORKDIR/build.log 2>&1 &",
    "sleep 3",
    "echo \"build started, log=\$WORKDIR/build.log\"",
    "ps -ef | grep 'docker build' | grep -v grep || true"
  ]
}
EOF

log "Launching build (repo=${REPO_SHORT} tag=${TAG}) on builder ${BUILDER_ID}"
CID=$(ssm_run_bg "${AWS_REGION_PRIMARY}" "${BUILDER_ID}" "$PAYLOAD_FILE" "build-${REPO_SHORT}-${TAG}")
log "ssm cid=${CID}"
echo "$CID" > "${LOG_DIR}/stage0-setup/build-${REPO_SHORT}-${STAMP}.cid"

log "Build kicked off. Poll with: ./build-watch.sh ${REPO_SHORT}-${STAMP}"
rm -f "$PAYLOAD_FILE"

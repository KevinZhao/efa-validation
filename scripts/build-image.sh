#!/usr/bin/env bash
# Build a Docker image on yanxi-builder and push to ECR.
# Usage:
#   ./build-image.sh <dockerfile-rel-path-in-repo> <ecr-repo-short> <tag> [--build-arg=KEY=VAL ...] [--context=FILE_REL_PATH ...]
# Examples (current):
#   ./build-image.sh common/Dockerfile.mooncake-nixl-v6 mooncake-nixl v6 --context=common/patch-mooncake-bench-v6.py
#     -> uploads the patch file into build context alongside Dockerfile so
#        `COPY common/patch-mooncake-bench-v6.py ...` in Dockerfile works.
#   ./build-image.sh common/Dockerfile.uccl-ep uccl-ep v2
#   ./build-image.sh common/Dockerfile.sglang-mooncake-uccl sglang-mooncake v5-uccl
#
# Historical (Stage 1-4) Dockerfiles archived under archive/stage1-4/common/
# (base-cuda-efa, nccl-tests-v2, mooncake-nixl, sglang-mooncake). The frozen
# ECR tags built from them (base-cuda-efa:v1, nccl-tests:v2, mooncake-nixl:v5,
# sglang-mooncake:v5) are still referenced by current images; rebuilding them
# would require restoring the Dockerfile path.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DOCKERFILE_REL="$1"; shift
REPO_SHORT="$1"; shift
TAG="$1"; shift
# remaining args: extra docker build flags OR --context=path entries

DOCKERFILE_LOCAL="${REPO_ROOT}/${DOCKERFILE_REL}"
[ -f "$DOCKERFILE_LOCAL" ] || { echo "Dockerfile not found: $DOCKERFILE_LOCAL" >&2; exit 1; }

DOCKERFILE_S3_KEY="dockerfiles/$(basename "$DOCKERFILE_REL")-$(ts)"
ECR_IMAGE="${ECR_REG}/yanxi/${REPO_SHORT}"
STAMP="$(ts)"
LOG_S3_KEY="logs/build-${REPO_SHORT}-${STAMP}.log"

log "Uploading Dockerfile to s3://${S3_BUCKET}/${DOCKERFILE_S3_KEY}"
aws s3 cp "$DOCKERFILE_LOCAL" "s3://${S3_BUCKET}/${DOCKERFILE_S3_KEY}" --quiet

BUILD_ARGS_STR=""
CONTEXT_FILES=()       # list of repo-rel paths that need to ride along into build context
for arg in "$@"; do
  case "$arg" in
    --context=*)
      ctx_rel="${arg#--context=}"
      CONTEXT_FILES+=("$ctx_rel")
      ;;
    *)
      BUILD_ARGS_STR+=" $arg"
      ;;
  esac
done

# Upload extra context files to S3 under the same build stamp, preserving
# their repo-relative path so `COPY common/foo.py /opt/...` works.
CONTEXT_CMDS=""
for ctx_rel in "${CONTEXT_FILES[@]}"; do
  ctx_local="${REPO_ROOT}/${ctx_rel}"
  [ -f "$ctx_local" ] || { echo "Context file not found: $ctx_local" >&2; exit 1; }
  ctx_s3_key="context/${REPO_SHORT}-${STAMP}/${ctx_rel}"
  log "Uploading context file ${ctx_rel} to s3://${S3_BUCKET}/${ctx_s3_key}"
  aws s3 cp "$ctx_local" "s3://${S3_BUCKET}/${ctx_s3_key}" --quiet
  ctx_dir="$(dirname "$ctx_rel")"
  CONTEXT_CMDS+="mkdir -p \$WORKDIR/${ctx_dir} && aws s3 cp s3://${S3_BUCKET}/${ctx_s3_key} \$WORKDIR/${ctx_rel}; "
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
    "${CONTEXT_CMDS}",
    "wc -l Dockerfile",
    "find \$WORKDIR -type f | head -20",
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

#!/usr/bin/env bash
# =============================================================================
# customer-1p1d-bench.sh — 1P:1D perf comparison between uccl/nccl variants of
# the customer release images (sglang-mooncake-{uccl,nccl}:2026.04.28-h200).
#
# For each variant:
#   1. render manifest (substitute IMAGE + MOE_A2A_BACKEND)
#   2. apply to EKS
#   3. wait for LB /health
#   4. bench_serving.py sharegpt, 256 prompts, ISL=2048 OSL=1024, concurrency=16
#   5. save stats to results/customer-1p1d/<stamp>/<variant>.json
#   6. kubectl delete the manifest, wait for GPU free before switching variant
#
# Usage:
#   ./scripts/customer-1p1d-bench.sh              # runs both uccl and nccl
#   VARIANT=uccl ./scripts/customer-1p1d-bench.sh # only one
#
# Prereqs:
#   - Ohio gpu-p5-48xlarge-spot nodegroup already scaled to 2 (this script
#     does NOT scale; see scripts/spot-placement-score.sh + eks update-nodegroup)
#   - bastion has kubectl + awscli
#   - S3 `yanxi-validation-788668107894-ohio/models/Qwen/Qwen3-Next-80B-A3B-Instruct/`
#     prefetched (sentinel .prefetch-complete present)
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib.sh"

VARIANTS="${VARIANT:-uccl nccl}"
STAMP="$(ts)"
OUT_DIR="${REPO_ROOT}/results/customer-1p1d/${STAMP}"
mkdir -p "${OUT_DIR}"

MANIFEST_SRC="${REPO_ROOT}/manifests/customer-1p1d-qwen3next.yaml"
S3_BUCKET="yanxi-validation-788668107894"
S3_PREFIX="manifests/customer-1p1d-${STAMP}"

log "=== customer 1P:1D bench ==="
log "  stamp    : ${STAMP}"
log "  variants : ${VARIANTS}"
log "  out      : ${OUT_DIR}"
log "  manifest : ${MANIFEST_SRC}"

for V in ${VARIANTS}; do
  case "${V}" in
    uccl) IMAGE_TAG="sglang-mooncake-uccl:2026.04.28-h200"; MOE_BACKEND="deepep" ;;
    nccl) IMAGE_TAG="sglang-mooncake-nccl:2026.04.28-h200"; MOE_BACKEND="none" ;;
    *) echo "unknown variant: ${V}"; exit 2 ;;
  esac

  IMAGE_FULL="${ECR_REG}/yanxi/${IMAGE_TAG}"
  VARIANT_YAML="${OUT_DIR}/manifest-${V}.yaml"

  log ""
  log "=== variant=${V} image=${IMAGE_FULL} MOE_A2A=${MOE_BACKEND} ==="

  # Render: substitute image + MOE_A2A_BACKEND
  sed -e "s|788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/sglang-mooncake-uccl:2026.04.28-h200|${IMAGE_FULL}|g" \
      -e "s|\\\$(MOE_A2A_BACKEND)|${MOE_BACKEND}|g" \
      "${MANIFEST_SRC}" > "${VARIANT_YAML}"
  log "rendered manifest: ${VARIANT_YAML}"

  # Upload rendered manifest + bench script to S3 for bastion to fetch
  aws s3 cp "${VARIANT_YAML}" "s3://${S3_BUCKET}/${S3_PREFIX}/manifest-${V}.yaml" --quiet

  # Apply
  log "applying manifest via bastion..."
  CID=$(aws ssm send-command \
    --region "${AWS_REGION_PRIMARY}" \
    --instance-ids "${OHIO_BASTION}" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[\"aws s3 cp s3://${S3_BUCKET}/${S3_PREFIX}/manifest-${V}.yaml /tmp/manifest.yaml --quiet\",\"kubectl --kubeconfig=/root/.kube/config apply -f /tmp/manifest.yaml 2>&1 | tail -20\"]" \
    --query 'Command.CommandId' --output text)
  for _ in $(seq 1 60); do
    s=$(aws ssm get-command-invocation --region "${AWS_REGION_PRIMARY}" --command-id "${CID}" --instance-id "${OHIO_BASTION}" --query Status --output text 2>/dev/null || echo Pending)
    case "$s" in Success|Failed|Cancelled|TimedOut) break ;; esac
    sleep 5
  done

  # Wait for LB Ready (up to 15 min: pods need s3-prefetch 152 GB ≈ 5 min + weight load 3-5 min)
  log "waiting for c1p1d-lb Ready (up to 15 min)..."
  for i in $(seq 1 90); do
    CID=$(aws ssm send-command --region "${AWS_REGION_PRIMARY}" --instance-ids "${OHIO_BASTION}" \
      --document-name AWS-RunShellScript \
      --parameters 'commands=["kubectl --kubeconfig=/root/.kube/config -n yanxi-validation get deploy c1p1d-lb c1p1d-prefill c1p1d-decode -o jsonpath=\"{range .items[*]}{.metadata.name}={.status.readyReplicas}/{.spec.replicas} {end}\""]' \
      --query 'Command.CommandId' --output text 2>/dev/null)
    sleep 8
    OUT=$(aws ssm get-command-invocation --region "${AWS_REGION_PRIMARY}" --command-id "${CID}" --instance-id "${OHIO_BASTION}" --query 'StandardOutputContent' --output text 2>/dev/null || echo "")
    log "  [$(date -u +%H:%M:%S) i=$i] ${OUT}"
    if echo "${OUT}" | grep -qE "c1p1d-lb=1/1 c1p1d-prefill=1/1 c1p1d-decode=1/1"; then
      log "  all 3 deployments Ready"
      break
    fi
    sleep 2
  done

  # Bench (run from bastion using LB service)
  log "running bench_serving.py (sharegpt-like, ISL=2048 OSL=1024, n=256, concurrency=16)..."
  BENCH_CID=$(aws ssm send-command --region "${AWS_REGION_PRIMARY}" --instance-ids "${OHIO_BASTION}" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[\"kubectl --kubeconfig=/root/.kube/config -n yanxi-validation run bench-${V} --rm --restart=Never --image=${IMAGE_FULL} --overrides='{\\\"spec\\\":{\\\"containers\\\":[{\\\"name\\\":\\\"bench\\\",\\\"image\\\":\\\"${IMAGE_FULL}\\\",\\\"command\\\":[\\\"bash\\\",\\\"-lc\\\",\\\"python3 -m sglang.bench_serving --backend sglang --host c1p1d-lb.yanxi-validation.svc --port 8000 --dataset-name random --random-input-len 2048 --random-output-len 1024 --num-prompts 256 --max-concurrency 16 --output-file /tmp/bench-${V}.json --warmup-requests 8 || echo BENCH_FAIL; cat /tmp/bench-${V}.json 2>/dev/null || true\\\"]}]}}' --timeout=30m 2>&1 | tail -60\"]" \
    --query 'Command.CommandId' --output text)
  for _ in $(seq 1 240); do  # up to 20 min for bench
    s=$(aws ssm get-command-invocation --region "${AWS_REGION_PRIMARY}" --command-id "${BENCH_CID}" --instance-id "${OHIO_BASTION}" --query Status --output text 2>/dev/null || echo Pending)
    case "$s" in Success|Failed|Cancelled|TimedOut) break ;; esac
    sleep 5
  done
  aws ssm get-command-invocation --region "${AWS_REGION_PRIMARY}" --command-id "${BENCH_CID}" --instance-id "${OHIO_BASTION}" --query 'StandardOutputContent' --output text > "${OUT_DIR}/bench-${V}.log" 2>&1 || true
  log "  bench log -> ${OUT_DIR}/bench-${V}.log"

  # Cleanup this variant before next
  log "deleting variant=${V} deployments (keeping nodes)..."
  CID=$(aws ssm send-command --region "${AWS_REGION_PRIMARY}" --instance-ids "${OHIO_BASTION}" \
    --document-name AWS-RunShellScript \
    --parameters 'commands=["kubectl --kubeconfig=/root/.kube/config delete -f /tmp/manifest.yaml --ignore-not-found --timeout=60s 2>&1 | tail -10"]' \
    --query 'Command.CommandId' --output text)
  for _ in $(seq 1 60); do
    s=$(aws ssm get-command-invocation --region "${AWS_REGION_PRIMARY}" --command-id "${CID}" --instance-id "${OHIO_BASTION}" --query Status --output text 2>/dev/null || echo Pending)
    case "$s" in Success|Failed|Cancelled|TimedOut) break ;; esac
    sleep 5
  done
  log "  waiting 30s for GPU to free..."
  sleep 30
done

log ""
log "=== all variants done ==="
log "raw logs: ${OUT_DIR}/bench-*.log"
log ""
log "Next: write ${OUT_DIR}/RESULT.md by hand or call parse-1p1d.py"

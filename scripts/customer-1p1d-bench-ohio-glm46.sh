#!/usr/bin/env bash
# =============================================================================
# customer-1p1d-bench-ohio-glm46.sh — Ohio p5en H200 x 2 run, GLM-4.6 (665 GB)
# 1P:1D perf comparison between uccl/nccl variants.
#
# Why: Qwen3-Next top_k=10 > UCCL-EP kNumMaxTopK=9 (fails). GLM-4.6 top_k=8 ok.
# GLM-4.6 BF16 665 GB needs H200 x 8 (1128 GB), not H100 (640 GB), hence p5en.
# Ohio use2-az2 p5en SPS=9 at 2026-04-27 12:37 UTC (re-checked from 1 earlier).
#
# For each variant:
#   1. render manifest (substitute IMAGE + MOE_A2A_BACKEND)
#   2. apply to EKS via bastion SSM
#   3. wait for c1p1d-lb/prefill/decode Ready
#   4. bench_serving.py random, 128 prompts, ISL=2048 OSL=1024, concurrency=16
#   5. save stats to results/customer-1p1d/<stamp>-ohio-glm46/bench-<variant>.log
#   6. kubectl delete + 30s GPU drain before next variant
#
# Usage:
#   ./scripts/customer-1p1d-bench-ohio-glm46.sh              # both uccl + nccl
#   VARIANT=uccl ./scripts/customer-1p1d-bench-ohio-glm46.sh # only one
#
# Prereqs:
#   - Ohio gpu-p5en-spot-useast2b scaled to desired=2 (pinned to use2-az2 subnet)
#   - Both nodes have /mnt/nvme (LVM stripe of 7 raw NVMe; ~25 TB xfs)
#   - bastion has kubectl + awscli; GPUNodeRole has ReadModelsBucket
#   - S3 yanxi-validation-788668107894-ohio/models/zai-org/GLM-4.6/ prefetched
#     (verified 2026-04-27: 102 objects / 664.6 GiB / .prefetch-complete sentinel)
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib.sh"

REGION="${REGION:-us-east-2}"
BASTION="${BASTION:-${OHIO_BASTION}}"
CLUSTER="${CLUSTER:-${OHIO_CLUSTER}}"

VARIANTS="${VARIANT:-uccl nccl}"
STAMP="$(ts)"
OUT_DIR="${REPO_ROOT}/results/customer-1p1d/${STAMP}-ohio-glm46"
mkdir -p "${OUT_DIR}"

MANIFEST_SRC="${REPO_ROOT}/manifests/customer-1p1d-glm46-ohio.yaml"
# Use Ohio bucket for manifest drops (bastion has access).
S3_BUCKET="yanxi-validation-788668107894-ohio"
S3_PREFIX="manifests/customer-1p1d-${STAMP}-ohio-glm46"

log "=== customer 1P:1D bench ==="
log "  stamp    : ${STAMP}"
log "  variants : ${VARIANTS}"
log "  out      : ${OUT_DIR}"
log "  manifest : ${MANIFEST_SRC}"

for V in ${VARIANTS}; do
  case "${V}" in
    uccl) IMAGE_TAG="sglang-mooncake-uccl:2026.04.28-h200.2"; MOE_BACKEND="deepep" ;;
    nccl) IMAGE_TAG="sglang-mooncake-nccl:2026.04.28-h200.2"; MOE_BACKEND="none" ;;
    *) echo "unknown variant: ${V}"; exit 2 ;;
  esac

  IMAGE_FULL="public.ecr.aws/n3l4x8f3/${IMAGE_TAG}"
  VARIANT_YAML="${OUT_DIR}/manifest-${V}.yaml"

  log ""
  log "=== variant=${V} image=${IMAGE_FULL} MOE_A2A=${MOE_BACKEND} ==="

  # Render: substitute the uccl image placeholder (manifest-usw2 hardcodes the
  # uccl tag) with the per-variant image, then plug MOE_A2A_BACKEND.
  sed -e "s|public.ecr.aws/n3l4x8f3/sglang-mooncake-uccl:2026.04.28-h200.[12]|${IMAGE_FULL}|g" \
      -e "s|\\\$(MOE_A2A_BACKEND)|${MOE_BACKEND}|g" \
      "${MANIFEST_SRC}" > "${VARIANT_YAML}"
  log "rendered manifest: ${VARIANT_YAML}"

  # Upload rendered manifest + bench script to S3 for bastion to fetch
  aws s3 cp "${VARIANT_YAML}" "s3://${S3_BUCKET}/${S3_PREFIX}/manifest-${V}.yaml" --quiet

  # Apply
  log "applying manifest via bastion..."
  CID=$(aws ssm send-command \
    --region "${REGION}" \
    --instance-ids "${BASTION}" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[\"aws s3 cp s3://${S3_BUCKET}/${S3_PREFIX}/manifest-${V}.yaml /tmp/manifest.yaml --quiet\",\"kubectl --kubeconfig=/root/.kube/config apply -f /tmp/manifest.yaml 2>&1 | tail -20\"]" \
    --query 'Command.CommandId' --output text)
  for _ in $(seq 1 60); do
    s=$(aws ssm get-command-invocation --region "${REGION}" --command-id "${CID}" --instance-id "${BASTION}" --query Status --output text 2>/dev/null || echo Pending)
    case "$s" in Success|Failed|Cancelled|TimedOut) break ;; esac
    sleep 5
  done

  # Wait for LB Ready (up to 15 min: pods need s3-prefetch 152 GB ≈ 5 min + weight load 3-5 min)
  log "waiting for c1p1d-lb Ready (up to 15 min)..."
  for i in $(seq 1 90); do
    CID=$(aws ssm send-command --region "${REGION}" --instance-ids "${BASTION}" \
      --document-name AWS-RunShellScript \
      --parameters 'commands=["kubectl --kubeconfig=/root/.kube/config -n yanxi-validation get deploy c1p1d-lb c1p1d-prefill c1p1d-decode -o jsonpath=\"{range .items[*]}{.metadata.name}={.status.readyReplicas}/{.spec.replicas} {end}\""]' \
      --query 'Command.CommandId' --output text 2>/dev/null)
    sleep 8
    OUT=$(aws ssm get-command-invocation --region "${REGION}" --command-id "${CID}" --instance-id "${BASTION}" --query 'StandardOutputContent' --output text 2>/dev/null || echo "")
    log "  [$(date -u +%H:%M:%S) i=$i] ${OUT}"
    if echo "${OUT}" | grep -qE "c1p1d-lb=1/1 c1p1d-prefill=1/1 c1p1d-decode=1/1"; then
      log "  all 3 deployments Ready"
      break
    fi
    sleep 2
  done

  # === Warmup phase (before timed bench) ===
  # User instruction 2026-04-27: "节点起来之后，测试之前，需要 warm up"
  # 3 small requests via curl from bastion to prime Mooncake EFA memory regions
  # and first-KV-transfer path before the timed bench starts.
  log "warming up server with 3 small requests before timed bench..."
  WARMUP_CID=$(aws ssm send-command --region "${REGION}" --instance-ids "${BASTION}" \
    --document-name AWS-RunShellScript \
    --parameters 'commands=["for i in 1 2 3; do kubectl --kubeconfig=/root/.kube/config -n yanxi-validation run warm-$i-'${V}'-'$$' --image=curlimages/curl:8.10.1 --rm -i --restart=Never --quiet --timeout=120s -- curl -sS -m 90 -X POST http://c1p1d-lb.yanxi-validation.svc:8000/generate -H \"Content-Type: application/json\" -d \"{\\\"text\\\":\\\"Hello, please respond with a single word.\\\",\\\"sampling_params\\\":{\\\"max_new_tokens\\\":16,\\\"temperature\\\":0}}\" 2>&1 | head -3 ; sleep 3 ; done ; echo WARMUP_DONE"]' \
    --query 'Command.CommandId' --output text)
  for _ in $(seq 1 60); do
    s=$(aws ssm get-command-invocation --region "${REGION}" --command-id "${WARMUP_CID}" --instance-id "${BASTION}" --query Status --output text 2>/dev/null || echo Pending)
    case "$s" in Success|Failed|Cancelled|TimedOut) break ;; esac
    sleep 5
  done
  aws ssm get-command-invocation --region "${REGION}" --command-id "${WARMUP_CID}" --instance-id "${BASTION}" --query 'StandardOutputContent' --output text | tail -20 > "${OUT_DIR}/warmup-${V}.log" 2>&1 || true
  log "  warmup log -> ${OUT_DIR}/warmup-${V}.log"

  # Bench via K8s Job (SSM 2-min limit requires background + polling).
  # Job uses the same server image (has sglang.bench_serving preinstalled),
  # targets LB service, writes output-file into emptyDir we tail via logs.
  log "running bench_serving.py (sharegpt-like, ISL=2048 OSL=1024, n=128, concurrency=16)..."
  cat > "${OUT_DIR}/bench-job-${V}.yaml" <<BENCHEOF
apiVersion: batch/v1
kind: Job
metadata:
  name: bench-${V}
  namespace: yanxi-validation
spec:
  ttlSecondsAfterFinished: 600
  backoffLimit: 0
  activeDeadlineSeconds: 1800
  template:
    spec:
      restartPolicy: Never
      tolerations:
        - { key: nvidia.com/gpu, operator: Equal, value: "true", effect: NoSchedule }
      containers:
        - name: bench
          image: ${IMAGE_FULL}
          command: ["bash","-lc"]
          args:
            - |
              # sglang 0.5.10 bench_serving 默认拿 model 名当 tokenizer HF repo
              # id；我们 prefill/decode 启动时 --model-path 是 /models/... 本地
              # 路径，LB 报回来的 served_model_name 也是 /models/... 。bench
              # 容器内没挂那个路径，所以必须显式 --tokenizer 走 HF hub 拉
              # (tokenizer 几 MB，不会被限流)。
              python3 -m sglang.bench_serving \\
                --backend sglang \\
                --host c1p1d-lb.yanxi-validation.svc --port 8000 \\
                --tokenizer zai-org/GLM-4.6 \\
                --model zai-org/GLM-4.6 \\
                --dataset-name random \\
                --random-input-len 2048 --random-output-len 1024 \\
                --num-prompts 128 --max-concurrency 16 \\
                --warmup-requests 8 \\
                --output-file /tmp/bench.json 2>&1
              echo "=== bench.json ==="
              cat /tmp/bench.json 2>/dev/null || echo "(no output file)"
              echo "=== BENCH_DONE ==="
BENCHEOF

  # Upload + apply Job
  aws s3 cp "${OUT_DIR}/bench-job-${V}.yaml" "s3://${S3_BUCKET}/${S3_PREFIX}/bench-job-${V}.yaml" --quiet
  cat > /tmp/bench-apply.json <<APEOF
{"commands":[
  "aws s3 cp s3://${S3_BUCKET}/${S3_PREFIX}/bench-job-${V}.yaml /tmp/bench-job.yaml --quiet",
  "kubectl --kubeconfig=/root/.kube/config delete job -n yanxi-validation bench-${V} --ignore-not-found",
  "kubectl --kubeconfig=/root/.kube/config apply -f /tmp/bench-job.yaml"
]}
APEOF
  CID=$(aws ssm send-command --region "${REGION}" --instance-ids "${BASTION}" --document-name AWS-RunShellScript --parameters file:///tmp/bench-apply.json --query 'Command.CommandId' --output text)
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    s=$(aws ssm get-command-invocation --region "${REGION}" --command-id "${CID}" --instance-id "${BASTION}" --query Status --output text 2>/dev/null || echo Pending)
    case "$s" in Success|Failed|Cancelled|TimedOut) break ;; esac
    sleep 3
  done

  # Poll Job completion up to 25 min
  log "waiting for Job bench-${V} to complete (up to 25 min)..."
  for i in $(seq 1 75); do
    CID=$(aws ssm send-command --region "${REGION}" --instance-ids "${BASTION}" \
      --document-name AWS-RunShellScript \
      --parameters "commands=[\"kubectl --kubeconfig=/root/.kube/config -n yanxi-validation get job bench-${V} -o jsonpath='{.status.succeeded}/{.status.failed}/{.status.active}' 2>/dev/null\"]" \
      --query 'Command.CommandId' --output text 2>/dev/null)
    sleep 5
    ST=$(aws ssm get-command-invocation --region "${REGION}" --command-id "${CID}" --instance-id "${BASTION}" --query 'StandardOutputContent' --output text 2>/dev/null || echo "")
    log "  [$(date -u +%H:%M:%S) bench-${V} succ/fail/active=${ST}]"
    if echo "${ST}" | grep -qE '^1/'; then
      log "  bench-${V} SUCCEEDED"
      break
    fi
    if echo "${ST}" | grep -qE '^/1/'; then
      log "  bench-${V} FAILED"
      break
    fi
    sleep 15
  done

  # Grab Job pod logs
  cat > /tmp/bench-logs.json <<LEOF
{"commands":[
  "POD=\$(kubectl --kubeconfig=/root/.kube/config -n yanxi-validation get pod -l job-name=bench-${V} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)",
  "echo POD=\$POD",
  "[ -n \"\$POD\" ] && kubectl --kubeconfig=/root/.kube/config -n yanxi-validation logs \$POD --tail=500 2>&1 || echo '(no pod)'"
]}
LEOF
  CID=$(aws ssm send-command --region "${REGION}" --instance-ids "${BASTION}" --document-name AWS-RunShellScript --parameters file:///tmp/bench-logs.json --query 'Command.CommandId' --output text)
  for _ in 1 2 3 4 5 6 7 8; do
    s=$(aws ssm get-command-invocation --region "${REGION}" --command-id "${CID}" --instance-id "${BASTION}" --query Status --output text 2>/dev/null || echo Pending)
    case "$s" in Success|Failed) break ;; esac
    sleep 3
  done
  aws ssm get-command-invocation --region "${REGION}" --command-id "${CID}" --instance-id "${BASTION}" --query 'StandardOutputContent' --output text > "${OUT_DIR}/bench-${V}.log" 2>&1 || true
  log "  bench log -> ${OUT_DIR}/bench-${V}.log"

  # Cleanup this variant before next
  log "deleting variant=${V} deployments (keeping nodes)..."
  CID=$(aws ssm send-command --region "${REGION}" --instance-ids "${BASTION}" \
    --document-name AWS-RunShellScript \
    --parameters 'commands=["kubectl --kubeconfig=/root/.kube/config delete -f /tmp/manifest.yaml --ignore-not-found --timeout=60s 2>&1 | tail -10"]' \
    --query 'Command.CommandId' --output text)
  for _ in $(seq 1 60); do
    s=$(aws ssm get-command-invocation --region "${REGION}" --command-id "${CID}" --instance-id "${BASTION}" --query Status --output text 2>/dev/null || echo Pending)
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

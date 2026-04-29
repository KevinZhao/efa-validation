#!/usr/bin/env bash
# =============================================================================
# GLM-5.1 HIT-triggered action — fire AFTER SPS watcher writes HIT file.
#
# Prereqs:
#   - scripts/sps-watch-p5en.sh running in background
#   - results/sps/watch-p5en/HIT exists (contains score + region/AZ)
#   - GLM-5.1-FP8 weights already in s3://yanxi-validation-788668107894-ohio/...
#   - p5en nodegroup gpu-p5en-spot-useast2b exists (desired=0 currently)
#
# Flow:
#   1. Read HIT to confirm region/AZ (abort if not us-east-2)
#   2. Scale gpu-p5en-spot-useast2b → 4 desired
#   3. Wait for 4 nodes to register in K8s (up to 20 min)
#   4. Upload manifest + bench Job to S3 (bastion pulls them)
#   5. SSM → bastion → apply manifest + wait for pods Ready (up to 45 min)
#   6. SSM → bastion → apply bench Job + fetch log
#   7. SSM → bastion → kubectl logs glm51-decode-0 > local file
#      (capture avg_spec_accept_length + Mooncake protocol + DeepGEMM state)
#   8. Write RESULT.md skeleton for human interpretation
#
# INVOCATION:
#   bash scripts/glm51-hit-action.sh          # dry-run: print plan, do nothing
#   RUN=1 bash scripts/glm51-hit-action.sh    # execute
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${ROOT}/results/customer-glm51/${STAMP}-ohio-2p2d"
HIT="${ROOT}/results/sps/watch-p5en/HIT"
REGION="us-east-2"
CLUSTER="gpu-cluster-ohio"
NODEGROUP="gpu-p5en-spot-useast2b"
BASTION="i-0341d214635c1ca74"
S3_BUCKET="yanxi-validation-788668107894-ohio"
NAMESPACE="yanxi-validation"
MANIFEST="${ROOT}/manifests/customer-2p2d-glm51-ohio.yaml"
BENCH_JOB="${ROOT}/manifests/customer-2p2d-glm51-ohio-bench.yaml"
DESIRED_NODES=4
RUN="${RUN:-0}"

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
do_or_plan() {
  if [ "${RUN}" = "1" ]; then
    log "EXEC: $*"
    eval "$@"
  else
    log "PLAN: $*"
  fi
}

[ -f "${HIT}" ] || { log "no HIT file yet at ${HIT}"; exit 0; }
log "HIT: $(cat "${HIT}")"
HIT_REGION="$(grep -oE 'where=[a-z0-9-]+/[a-z0-9-]+' "${HIT}" | sed 's|where=||;s|/.*||')"
HIT_SCORE="$(grep -oE 'score=[0-9]+' "${HIT}" | head -n1 | sed 's|score=||')"
[ "${HIT_REGION}" = "${REGION}" ] || { log "HIT region ${HIT_REGION} != ${REGION}, aborting"; exit 1; }
log "proceeding: region=${HIT_REGION} score=${HIT_SCORE}"

mkdir -p "${OUT_DIR}"

# --- 1. scale ASG ---
log "scaling ${NODEGROUP} → desired=${DESIRED_NODES}"
do_or_plan "aws eks update-nodegroup-config --cluster-name ${CLUSTER} \
  --nodegroup-name ${NODEGROUP} --region ${REGION} \
  --scaling-config minSize=0,maxSize=${DESIRED_NODES},desiredSize=${DESIRED_NODES} \
  --query 'update.[id,status]' --output text"

# --- 2. wait for nodes ---
log "waiting for ${DESIRED_NODES} p5en nodes to join K8s (max 20 min)"
if [ "${RUN}" = "1" ]; then
  for _ in $(seq 1 40); do
    CURR=$(aws ssm send-command --region "${REGION}" --instance-ids "${BASTION}" \
      --document-name AWS-RunShellScript \
      --parameters 'commands=["sudo -u ec2-user -i bash -c \"kubectl get nodes -l node.kubernetes.io/instance-type=p5en.48xlarge --no-headers 2>/dev/null | wc -l\""]' \
      --query 'Command.CommandId' --output text)
    sleep 20
    N=$(aws ssm get-command-invocation --region "${REGION}" --instance-id "${BASTION}" \
      --command-id "${CURR}" --query 'StandardOutputContent' --output text 2>/dev/null | tr -d '[:space:]')
    log "p5en nodes in cluster: ${N:-?}"
    [ "${N:-0}" -ge "${DESIRED_NODES}" ] && break
    sleep 10
  done
fi

# --- 3. upload manifests to S3 ---
log "uploading manifest + bench to S3"
do_or_plan "aws s3 cp ${MANIFEST} s3://${S3_BUCKET}/manifests/${STAMP}-glm51/manifest.yaml --region ${REGION}"
do_or_plan "aws s3 cp ${BENCH_JOB} s3://${S3_BUCKET}/manifests/${STAMP}-glm51/bench.yaml --region ${REGION}"

# --- 4. apply via bastion ---
log "applying manifest on bastion"
APPLY_CMD="sudo -u ec2-user -i bash -c \"set -eux; \
  aws s3 cp s3://${S3_BUCKET}/manifests/${STAMP}-glm51/manifest.yaml /tmp/glm51-manifest.yaml; \
  aws s3 cp s3://${S3_BUCKET}/manifests/${STAMP}-glm51/bench.yaml /tmp/glm51-bench.yaml; \
  kubectl -n ${NAMESPACE} delete statefulset glm51-prefill glm51-decode --ignore-not-found; \
  kubectl -n ${NAMESPACE} delete deploy glm51-lb --ignore-not-found; \
  kubectl -n ${NAMESPACE} delete svc glm51-prefill glm51-prefill-headless glm51-decode glm51-decode-headless glm51-lb --ignore-not-found; \
  sleep 5; \
  kubectl apply -f /tmp/glm51-manifest.yaml\""
do_or_plan "aws ssm send-command --region ${REGION} --instance-ids ${BASTION} \
  --document-name AWS-RunShellScript \
  --parameters 'commands=[\"${APPLY_CMD//\"/\\\"}\"]' \
  --query 'Command.CommandId' --output text"

log ""
log "=== HUMAN CHECKPOINT ==="
log "manifest applied. Now WAIT for GLM-5.1 warmup (DeepGEMM JIT ~12-15 min first time)"
log "check progress with:"
log "  aws ssm send-command --region ${REGION} --instance-ids ${BASTION} --document-name AWS-RunShellScript \\"
log "    --parameters 'commands=[\"sudo -u ec2-user -i bash -c \\\"kubectl -n ${NAMESPACE} get pods -o wide\\\"\"]'"
log ""
log "when all 5 pods (2 prefill + 2 decode + 1 lb) are 1/1 Ready, run bench:"
log "  aws ssm send-command --region ${REGION} --instance-ids ${BASTION} --document-name AWS-RunShellScript \\"
log "    --parameters 'commands=[\"sudo -u ec2-user -i bash -c \\\"kubectl -n ${NAMESPACE} delete job glm51-bench-latency --ignore-not-found; kubectl apply -f /tmp/glm51-bench.yaml\\\"\"]'"
log ""
log "fetch results:"
log "  kubectl -n ${NAMESPACE} logs -l job-name=glm51-bench-latency --tail=500"
log ""
log "results dir: ${OUT_DIR}"

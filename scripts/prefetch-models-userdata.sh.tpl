#!/usr/bin/env bash
# EC2 UserData — downloads the Stage-5 model catalog onto a FSx for Lustre
# mount, then self-terminates. Rendered by prefetch-models-launch.sh.
#
# Placeholders (sed-substituted at launch time):
#   __FSX_DNS__       e.g. fs-0abc....fsx.us-east-2.amazonaws.com
#   __FSX_MOUNT__     Lustre MountName (NOT the DNS), e.g. "xc4chb4v"
#   __REGION__        e.g. us-east-2
#   __LOG_BUCKET__    s3 bucket for cloud-init + prefetch logs (optional, leave empty to skip)
#
# The model catalog is hard-coded below to match efa-validation/STAGE5_PLAN.md.
set -eux
exec > >(tee -a /var/log/yanxi-prefetch.log) 2>&1

echo "=== $(date -u -Is) boot start ==="

REGION="__REGION__"
FSX_DNS="__FSX_DNS__"
FSX_MOUNT="__FSX_MOUNT__"
LOG_BUCKET="__LOG_BUCKET__"

# --- base deps ---------------------------------------------------------------
dnf install -y -q lustre-client python3-pip git awscli
modprobe lustre

# --- mount FSx ---------------------------------------------------------------
mkdir -p /fsx
# If an earlier boot added an fstab entry, remove it so retries are idempotent.
sed -i '/\/fsx /d' /etc/fstab || true
echo "${FSX_DNS}@tcp:/${FSX_MOUNT} /fsx lustre defaults,noatime,flock,_netdev 0 0" >> /etc/fstab
for i in $(seq 1 20); do
  if mount /fsx 2>/dev/null; then break; fi
  echo "mount attempt $i failed; sleeping"
  sleep 5
done
mount | grep /fsx
df -h /fsx

# --- python deps -------------------------------------------------------------
# Use a venv so we don't fight the rpm-installed system pip (which refuses
# self-upgrade with "Cannot uninstall pip 21.3.1, RECORD file not found").
# huggingface_hub 1.x retired the "[cli]" extra; the new entrypoint is `hf`.
python3 -m venv /opt/hfvenv
# shellcheck disable=SC1091
source /opt/hfvenv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet "huggingface_hub>=1.0" hf_transfer hf_xet
export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_HOME=/fsx/.hf-cache
mkdir -p "$HF_HOME"

HF_BIN=/opt/hfvenv/bin/hf

# --- download catalog --------------------------------------------------------
# Ordered by size ascending so smaller models are available early in case of
# a Spot interruption on the big Kimi K2 download.
MODELS=(
  "Qwen/Qwen3-Next-80B-A3B-Instruct"
  "Qwen/Qwen3-235B-A22B-Instruct-2507-FP8"
  "zai-org/GLM-4.6"
  "deepseek-ai/DeepSeek-V3.1"
  "moonshotai/Kimi-K2-Instruct-0905"
  "deepseek-ai/DeepSeek-V4-Pro"
)

for MODEL_ID in "${MODELS[@]}"; do
  DEST="/fsx/$(basename "$MODEL_ID")"
  if [ -f "$DEST/.prefetch-complete" ]; then
    echo "=== SKIP ${MODEL_ID} (already complete) ==="
    continue
  fi
  echo "=== $(date -u -Is) BEGIN ${MODEL_ID} ==="
  mkdir -p "$DEST"
  # hf_transfer + 16 workers; retry up to 3 times in case of transient 5xx.
  for attempt in 1 2 3; do
    if "$HF_BIN" download "$MODEL_ID" \
        --local-dir "$DEST" \
        --max-workers 16; then
      break
    fi
    echo "attempt $attempt failed, sleeping 30s"
    sleep 30
  done
  # Minimal sanity check: config.json must exist for all these repos.
  if [ ! -f "$DEST/config.json" ]; then
    echo "!!! ${MODEL_ID}: config.json missing after download; leaving sentinel unwritten"
    continue
  fi
  echo "$MODEL_ID" > "$DEST/.model-id"
  touch "$DEST/.prefetch-complete"
  du -sh "$DEST"
  echo "=== $(date -u -Is) END ${MODEL_ID} ==="
done

# --- report ------------------------------------------------------------------
{
  echo "=== final inventory at $(date -u -Is) ==="
  du -sh /fsx/* 2>/dev/null | sort -h
  echo "=== FSx usage ==="
  df -h /fsx
  echo "=== completion sentinels ==="
  find /fsx -maxdepth 2 -name '.prefetch-complete' -printf '%p\n'
} | tee /fsx/.prefetch-report-"$(date -u +%Y%m%dT%H%M%SZ)".txt

# Only self-terminate if every model in this run's MODELS[] actually completed.
# Keep the instance alive otherwise so the operator can SSM in and retry
# without paying for another full boot cycle.
expected=${#MODELS[@]}
actual=0
for MODEL_ID in "${MODELS[@]}"; do
  DEST="/fsx/$(basename "$MODEL_ID")"
  [ -f "$DEST/.prefetch-complete" ] && actual=$((actual + 1))
done
if [ "$actual" -lt "$expected" ]; then
  echo "!!! ${actual}/${expected} models complete — leaving instance running for inspection"
  exit 0
fi

# Optional: copy cloud-init logs to S3 for post-mortem
if [ -n "${LOG_BUCKET}" ] && [ "${LOG_BUCKET}" != "__LOG_BUCKET__" ]; then
  TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
  IID=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
  aws s3 cp /var/log/yanxi-prefetch.log "s3://${LOG_BUCKET}/prefetch/${REGION}/${IID}.log" || true
fi

echo "=== $(date -u -Is) all ${expected} models complete — shutting down for termination ==="
# Instance launched with InstanceInitiatedShutdownBehavior=terminate so this
# deletes the node.
shutdown -h +1

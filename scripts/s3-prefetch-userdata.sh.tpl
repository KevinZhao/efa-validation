#!/usr/bin/env bash
# Stage-5 model catalog prefetch → S3 (regional authoritative source).
#
# Flow:
#   HF (hf_transfer, 16 workers) → /mnt/stage/<model>/ (EBS gp3)
#   → s5cmd sync --concurrency 256 → s3://<bucket>/models/<model>/
#   → write sentinel → delete local → next model
#   → when all done, self-terminate
#
# Placeholders (sed-substituted at launch time):
#   __REGION__          e.g. us-east-2
#   __S3_BUCKET__       e.g. yanxi-validation-788668107894-ohio
#   __S3_PREFIX__       e.g. models
#   __HF_TOKEN__        HF read token
#   __LOG_BUCKET__      optional s3 bucket for log upload
#
set -eux
exec > >(tee -a /var/log/yanxi-s3-prefetch.log) 2>&1

echo "=== $(date -u -Is) boot start on $(uname -m) ==="

REGION="__REGION__"
S3_BUCKET="__S3_BUCKET__"
S3_PREFIX="__S3_PREFIX__"
HF_TOKEN="__HF_TOKEN__"
LOG_BUCKET="__LOG_BUCKET__"

# --- base deps ---------------------------------------------------------------
dnf install -y -q python3-pip git awscli tar gzip

# --- stage dir (root volume is 2 TB gp3) ------------------------------------
mkdir -p /mnt/stage
# If a separate /dev/nvme1n1 or similar shows up in the future we can mount it
# here; for c8gn we rely on the enlarged root EBS for staging.
df -h /

# --- python deps -------------------------------------------------------------
python3 -m venv /opt/hfvenv
# shellcheck disable=SC1091
source /opt/hfvenv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet "huggingface_hub>=1.0" hf_transfer hf_xet
HF_BIN=/opt/hfvenv/bin/hf

# --- s5cmd (ARM64 binary) ----------------------------------------------------
S5CMD_VER="2.2.2"
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64) S5CMD_ARCH="arm64" ;;
  x86_64)  S5CMD_ARCH="amd64" ;;
  *) echo "unsupported arch $ARCH"; exit 1 ;;
esac
curl -fsSL -o /tmp/s5cmd.tgz \
  "https://github.com/peak/s5cmd/releases/download/v${S5CMD_VER}/s5cmd_${S5CMD_VER}_Linux-${S5CMD_ARCH}.tar.gz"
tar -xzf /tmp/s5cmd.tgz -C /usr/local/bin s5cmd
chmod +x /usr/local/bin/s5cmd
s5cmd version

export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_HOME=/mnt/stage/.hf-cache
export HF_TOKEN="$HF_TOKEN"
export HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"
mkdir -p "$HF_HOME"

# --- download catalog --------------------------------------------------------
# Ordered ascending by size so small models are available early if big ones
# are interrupted. The placeholder below is substituted by the launcher with
# a newline-separated list of "hf-repo-id" entries.
MODELS=(
__MODELS_PLACEHOLDER__
)

S3_BASE="s3://${S3_BUCKET}/${S3_PREFIX}"

for MODEL_ID in "${MODELS[@]}"; do
  MODEL_BASE="$(basename "$MODEL_ID")"
  STAGE_DIR="/mnt/stage/${MODEL_BASE}"
  S3_DEST="${S3_BASE}/${MODEL_ID}"
  SENTINEL_KEY="${S3_PREFIX}/${MODEL_ID}/.prefetch-complete"

  # Resume: if sentinel already in S3, skip.
  if aws s3api head-object --region "$REGION" --bucket "$S3_BUCKET" \
       --key "$SENTINEL_KEY" >/dev/null 2>&1; then
    echo "=== SKIP ${MODEL_ID} — sentinel already in s3 ==="
    continue
  fi

  echo "=== $(date -u -Is) BEGIN ${MODEL_ID} ==="
  mkdir -p "$STAGE_DIR"
  df -h /mnt/stage

  # 1. HF download to local EBS
  for attempt in 1 2 3; do
    if "$HF_BIN" download "$MODEL_ID" \
        --local-dir "$STAGE_DIR" \
        --max-workers 16; then
      break
    fi
    echo "hf attempt $attempt failed, sleeping 30s"
    sleep 30
  done
  if [ ! -f "$STAGE_DIR/config.json" ]; then
    echo "!!! ${MODEL_ID}: config.json missing after HF download — skipping"
    rm -rf "$STAGE_DIR"
    continue
  fi

  # 2. Upload to S3 (s5cmd with 256 concurrency, 64 MB parts)
  echo "=== $(date -u -Is) UPLOAD ${MODEL_ID} -> ${S3_DEST}/ ==="
  /usr/local/bin/s5cmd \
    --log info \
    --numworkers 256 \
    cp --concurrency 16 \
       --part-size 64 \
       "${STAGE_DIR}/" \
       "${S3_DEST}/"

  # 3. Sanity: count objects on S3 vs local
  local_files=$(find "$STAGE_DIR" -type f | wc -l)
  s3_files=$(aws s3 ls --region "$REGION" --recursive "${S3_DEST}/" | wc -l)
  echo "files: local=${local_files} s3=${s3_files}"
  if [ "$s3_files" -lt "$local_files" ]; then
    echo "!!! ${MODEL_ID}: s3 has fewer files than local — leaving sentinel unwritten"
    rm -rf "$STAGE_DIR"
    continue
  fi

  # 4. Write sentinel with metadata
  sentinel_body=$(cat <<EOJ
{
  "model_id": "${MODEL_ID}",
  "completed_at": "$(date -u -Is)",
  "file_count": ${local_files},
  "source": "huggingface-hub",
  "uploader_instance": "$(curl -sH "X-aws-ec2-metadata-token: $(curl -sX PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' http://169.254.169.254/latest/api/token)" http://169.254.169.254/latest/meta-data/instance-id)"
}
EOJ
)
  echo "$sentinel_body" | aws s3 cp --region "$REGION" \
    --content-type application/json - "s3://${S3_BUCKET}/${SENTINEL_KEY}"

  # 5. Free disk before next model
  echo "freeing ${STAGE_DIR}"
  rm -rf "$STAGE_DIR"
  df -h /mnt/stage
  echo "=== $(date -u -Is) END ${MODEL_ID} ==="
done

# --- report ------------------------------------------------------------------
{
  echo "=== final inventory at $(date -u -Is) ==="
  for MODEL_ID in "${MODELS[@]}"; do
    SENTINEL_KEY="${S3_PREFIX}/${MODEL_ID}/.prefetch-complete"
    if aws s3api head-object --region "$REGION" --bucket "$S3_BUCKET" \
         --key "$SENTINEL_KEY" >/dev/null 2>&1; then
      echo "  OK  ${MODEL_ID}"
    else
      echo "  MISS ${MODEL_ID}"
    fi
  done
} | tee /var/log/yanxi-s3-prefetch-report.txt

# Only self-terminate if every model completed.
expected=${#MODELS[@]}
actual=0
for MODEL_ID in "${MODELS[@]}"; do
  SENTINEL_KEY="${S3_PREFIX}/${MODEL_ID}/.prefetch-complete"
  if aws s3api head-object --region "$REGION" --bucket "$S3_BUCKET" \
       --key "$SENTINEL_KEY" >/dev/null 2>&1; then
    actual=$((actual + 1))
  fi
done
if [ "$actual" -lt "$expected" ]; then
  echo "!!! ${actual}/${expected} models complete — leaving instance running for SSM inspection"
  exit 0
fi

# Optional log shipment
if [ -n "${LOG_BUCKET}" ] && [ "${LOG_BUCKET}" != "__LOG_BUCKET__" ]; then
  TOKEN=$(curl -sX PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' http://169.254.169.254/latest/api/token)
  IID=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
  aws s3 cp /var/log/yanxi-s3-prefetch.log \
    "s3://${LOG_BUCKET}/s3-prefetch/${REGION}/${IID}.log" || true
  aws s3 cp /var/log/yanxi-s3-prefetch-report.txt \
    "s3://${LOG_BUCKET}/s3-prefetch/${REGION}/${IID}.report.txt" || true
fi

echo "=== $(date -u -Is) all ${expected} models complete — shutting down ==="
# Instance launched with InstanceInitiatedShutdownBehavior=terminate.
shutdown -h +1

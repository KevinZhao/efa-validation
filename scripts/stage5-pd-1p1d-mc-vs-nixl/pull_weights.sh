#!/bin/bash
# Pull Kimi-K2.5 INT4 weights from Ohio S3 into node-local NVMe (/data/models/Kimi-K2.5).
# Run this on each of the two p5en nodes after they come up (same-AZ in us-east-2).
#
# Env:
#   S3_URI  default s3://yanxi-validation-788668107894-ohio/models/moonshotai/Kimi-K2.5/
#   DEST    default /data/models/Kimi-K2.5
#   WORKERS default 256  (s5cmd concurrency)
#
# Assumes: AWS CLI present, IAM role attached (or env creds), s5cmd installed
# or downloadable at runtime (script auto-installs if missing).
set -euo pipefail

S3_URI="${S3_URI:-s3://yanxi-validation-788668107894-ohio/models/moonshotai/Kimi-K2.5/}"
DEST="${DEST:-/data/models/Kimi-K2.5}"
WORKERS="${WORKERS:-256}"
REGION="${REGION:-us-east-2}"

echo "[pull-weights] s3=$S3_URI dest=$DEST workers=$WORKERS region=$REGION"

# Sentinel check on S3 — refuse to start until prefetch complete.
SENT="${S3_URI}.prefetch-complete"
if ! aws s3 ls --region "$REGION" "$SENT" >/dev/null 2>&1; then
    echo "[pull-weights] FATAL: sentinel missing at $SENT — prefetch not finished" >&2
    exit 1
fi

# Install s5cmd if missing (ARM or x86 auto-detect)
if ! command -v s5cmd >/dev/null 2>&1; then
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64)  S5ARCH=amd64 ;;
        aarch64) S5ARCH=arm64 ;;
        *) echo "unknown arch $ARCH" >&2; exit 1 ;;
    esac
    curl -fsSL "https://github.com/peak/s5cmd/releases/download/v2.2.2/s5cmd_2.2.2_Linux-${S5ARCH}.tar.gz" \
        -o /tmp/s5cmd.tgz
    sudo tar -xzf /tmp/s5cmd.tgz -C /usr/local/bin s5cmd
    sudo chmod +x /usr/local/bin/s5cmd
fi

sudo mkdir -p "$DEST"
sudo chown -R $(id -u):$(id -g) "$DEST" || true

start=$(date -u +%s)
s5cmd --log info --numworkers "$WORKERS" \
    cp --concurrency 16 --part-size 64 \
    "${S3_URI}*" "${DEST}/"
end=$(date -u +%s)
echo "[pull-weights] copied in $((end-start)) seconds"

# Sanity: count files and total bytes
count=$(find "$DEST" -type f | wc -l)
bytes=$(du -sb "$DEST" | awk '{print $1}')
echo "[pull-weights] file_count=$count  total_bytes=$bytes ($(du -sh "$DEST" | awk '{print $1}'))"

# Drop a local sentinel
cat > "${DEST}/.local-ready" <<EOF
{"completed_at": "$(date -u -Is)", "file_count": $count, "bytes": $bytes, "source": "$S3_URI"}
EOF
echo "[pull-weights] DONE"

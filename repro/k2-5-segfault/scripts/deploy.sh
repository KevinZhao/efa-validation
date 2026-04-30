#!/usr/bin/env bash
# Deploy repro compose + entrypoints to 2 p5 nodes + prefetch V4-Flash from S3
#
# Uploads via S3 (manifest/script bucket), SSM pulls them down on each node.
#
# Usage: bash repro/k2-5-segfault/scripts/deploy.sh
set -euo pipefail

REGION=us-west-2
PREFILL_NODE=i-09db88a9ef4b704de   # 10.0.11.5
DECODE_NODE=i-0f93a804d2c034881    # 10.0.11.215
PREFILL_IP=10.0.11.5
DECODE_IP=10.0.11.215

S3_BUCKET=yanxi-validation-788668107894-oregon
S3_PREFIX=repro/k2-5-segfault
S3_MODEL=s3://yanxi-validation-788668107894-oregon/models/deepseek-ai/DeepSeek-V4-Flash/

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
echo "[deploy] stamp=${STAMP} root=${ROOT}"

# 1. Stage files to S3 so SSM can fetch (no inline size limits)
echo "[deploy] stage files to s3://${S3_BUCKET}/${S3_PREFIX}/"
aws s3 cp --quiet "${ROOT}/prefill/docker-compose.yml" "s3://${S3_BUCKET}/${S3_PREFIX}/prefill/docker-compose.yml"
aws s3 cp --quiet "${ROOT}/prefill/prefill_entrypoint.sh" "s3://${S3_BUCKET}/${S3_PREFIX}/prefill/prefill_entrypoint.sh"
aws s3 cp --quiet "${ROOT}/decode/docker-compose.yml" "s3://${S3_BUCKET}/${S3_PREFIX}/decode/docker-compose.yml"
aws s3 cp --quiet "${ROOT}/decode/decode_entrypoint.sh" "s3://${S3_BUCKET}/${S3_PREFIX}/decode/decode_entrypoint.sh"
aws s3 cp --quiet "${ROOT}/router/docker-compose.yml" "s3://${S3_BUCKET}/${S3_PREFIX}/router/docker-compose.yml"
aws s3 cp --quiet "${ROOT}/router/.env" "s3://${S3_BUCKET}/${S3_PREFIX}/router/.env"

echo "[deploy] OK staged to S3"
echo "[deploy] next: bash scripts/install-node.sh prefill|decode"

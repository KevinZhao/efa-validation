#!/usr/bin/env bash
# Watch a background Docker build launched by build-image.sh.
# Usage:
#   ./build-watch.sh <repo-short-TIMESTAMP>      # names a specific build
#   ./build-watch.sh <repo-short>                # watches newest build matching repo
set -euo pipefail
source "$(dirname "$0")/lib.sh"

KEY="${1:?Usage: $0 <repo-short[-timestamp]>}"

WORKDIR="/root/build/${KEY}"

PAYLOAD_FILE=$(mktemp)
cat > "$PAYLOAD_FILE" <<EOF
{
  "commands": [
    "ls -la ${WORKDIR} 2>&1 | head -5",
    "ps -ef | grep 'docker build' | grep -v grep || echo 'no build running'",
    "echo --- tail 50 ---",
    "tail -50 ${WORKDIR}/build.log 2>&1 || true",
    "echo --- BUILD_DONE? ---",
    "grep -c BUILD_DONE ${WORKDIR}/build.log 2>/dev/null || echo 0",
    "echo --- ERRORS ---",
    "grep -E 'ERROR|error:|fatal' ${WORKDIR}/build.log 2>/dev/null | tail -10 || true"
  ]
}
EOF

CID=$(ssm_run_bg "${AWS_REGION_PRIMARY}" "${BUILDER_ID}" "$PAYLOAD_FILE" "watch-${KEY}")
sleep 5
ssm_check "${AWS_REGION_PRIMARY}" "$CID" "${BUILDER_ID}"
rm -f "$PAYLOAD_FILE"

#!/usr/bin/env bash
# Short 1-line status check on the builder. Much cheaper than build-watch.sh.
# Usage: ./build-watch-short.sh <stamp>
set -euo pipefail
source "$(dirname "$0")/lib.sh"
STAMP="${1:?Usage: $0 <stamp>}"

PAYLOAD_FILE=$(mktemp)
python3 - "$PAYLOAD_FILE" <<PYEOF
import json, sys
cmds = [
    "ALIVE=\$(pgrep -cf 'docker build --progress' || true)",
    "STEP=\$(grep -oE '#[0-9]+ \\[builder [0-9]+/[0-9]+\\]|#[0-9]+ \\[runtime [0-9]+/[0-9]+\\]' /root/build/${STAMP}/build.log 2>/dev/null | tail -1)",
    "TAIL=\$(tail -1 /root/build/${STAMP}/build.log 2>/dev/null | cut -c1-120)",
    "PUSHED=\$(grep -cE 'digest: sha256:.*size:' /root/build/${STAMP}/build.log 2>/dev/null || echo 0)",
    "ERR=\$(grep -oE 'ERROR: failed to solve' /root/build/${STAMP}/build.log 2>/dev/null | tail -1)",
    "BUILD_DONE=\$(grep -c '^BUILD_DONE$' /root/build/${STAMP}/build.log 2>/dev/null || echo 0)",
    "DF=\$(df -h / | tail -1 | awk '{print \$3 \"/\" \$2}')",
    "echo alive=\$ALIVE pushes=\$PUSHED done=\$BUILD_DONE disk=\$DF err=\${ERR:-none} step=\${STEP:-?}",
    "echo tail: \$TAIL",
]
json.dump({"commands": cmds}, open(sys.argv[1], "w"))
PYEOF

CID=$(aws ssm send-command --region "${AWS_REGION_PRIMARY}" \
  --instance-ids "${BUILDER_ID}" \
  --document-name AWS-RunShellScript \
  --parameters file://"${PAYLOAD_FILE}" \
  --query 'Command.CommandId' --output text)
rm -f "${PAYLOAD_FILE}"

# Poll until SSM command returns (usually < 5s)
for i in $(seq 1 20); do
  STATUS=$(aws ssm get-command-invocation --region "${AWS_REGION_PRIMARY}" \
    --command-id "${CID}" --instance-id "${BUILDER_ID}" \
    --query 'Status' --output text 2>/dev/null || echo "Pending")
  [ "$STATUS" = "Success" ] && break
  [ "$STATUS" = "Failed" ] && { echo "SSM failed"; exit 1; }
  sleep 2
done

aws ssm get-command-invocation --region "${AWS_REGION_PRIMARY}" \
  --command-id "${CID}" --instance-id "${BUILDER_ID}" \
  --query 'StandardOutputContent' --output text

#!/usr/bin/env bash
# Resize the efa-builder EC2 instance. Run from laptop/bastion with AWS admin creds.
# Usage: ./resize-builder.sh <instance-type>
set -euo pipefail
source "$(dirname "$0")/lib.sh"

TYPE="${1:-m7i.4xlarge}"

log "Stopping builder ${BUILDER_ID}..."
aws ec2 stop-instances --region "${AWS_REGION_PRIMARY}" --instance-ids "${BUILDER_ID}" --output text >/dev/null
aws ec2 wait instance-stopped --region "${AWS_REGION_PRIMARY}" --instance-ids "${BUILDER_ID}"

log "Setting instance type to ${TYPE}..."
aws ec2 modify-instance-attribute --region "${AWS_REGION_PRIMARY}" \
  --instance-id "${BUILDER_ID}" \
  --instance-type "{\"Value\":\"${TYPE}\"}"

log "Starting builder..."
aws ec2 start-instances --region "${AWS_REGION_PRIMARY}" --instance-ids "${BUILDER_ID}" --output text >/dev/null
aws ec2 wait instance-running --region "${AWS_REGION_PRIMARY}" --instance-ids "${BUILDER_ID}"

log "Waiting for SSM to come back online..."
for i in $(seq 1 30); do
  sleep 10
  S=$(aws ssm describe-instance-information --region "${AWS_REGION_PRIMARY}" \
    --filters "Key=InstanceIds,Values=${BUILDER_ID}" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "NotFound")
  log "attempt=$i ssm_status=$S"
  [ "$S" = "Online" ] && break
done
log "Builder ready as ${TYPE}"

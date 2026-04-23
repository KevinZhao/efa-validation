#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Grant cross-account pull-only access to all yanxi/* ECR repositories.
#
# Source:  788668107894 (us-east-2)
# Target:  338295026919 (whole account, pull-only)
#
# Usage:
#   DRY_RUN=1 ./share-ecr-cross-account.sh     # print policies, no apply
#   ./share-ecr-cross-account.sh               # apply repository policies
#   REMOVE=1 ./share-ecr-cross-account.sh      # revoke (delete policies)
# -----------------------------------------------------------------------------
set -euo pipefail

REGION="${REGION:-us-east-2}"
TARGET_ACCOUNT="${TARGET_ACCOUNT:-338295026919}"
REPO_PREFIX="${REPO_PREFIX:-yanxi/}"
SID="AllowCrossAccountPull-${TARGET_ACCOUNT}"
DRY_RUN="${DRY_RUN:-0}"
REMOVE="${REMOVE:-0}"

LOG="$(dirname "$0")/../ECR_SHARING.md"

POLICY_JSON=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "${SID}",
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::${TARGET_ACCOUNT}:root" },
    "Action": [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:ListImages"
    ]
  }]
}
EOF
)

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

ensure_log() {
  if [ ! -f "$LOG" ]; then
    cat > "$LOG" <<EOF
# ECR Cross-Account Sharing Log

Source account: \`788668107894\` (us-east-2)
Target account: \`${TARGET_ACCOUNT}\`
Scope: whole account, pull-only

## Granted actions
- ecr:BatchGetImage
- ecr:GetDownloadUrlForLayer
- ecr:BatchCheckLayerAvailability
- ecr:DescribeImages
- ecr:DescribeRepositories
- ecr:ListImages

## Repositories & events

| Repository | Action | Timestamp (UTC) | Result |
|---|---|---|---|
EOF
  fi
}

list_repos() {
  aws ecr describe-repositories --region "$REGION" \
    --query "repositories[?starts_with(repositoryName, \`${REPO_PREFIX}\`)].repositoryName" \
    --output text
}

apply_policy() {
  local repo="$1"
  log "[apply] $repo"
  if [ "$DRY_RUN" = "1" ]; then
    log "  [DRY_RUN] would set-repository-policy"
    return
  fi
  if aws ecr set-repository-policy \
      --repository-name "$repo" \
      --policy-text "$POLICY_JSON" \
      --region "$REGION" >/dev/null 2>&1; then
    echo "| \`$repo\` | apply | $(date -u +%Y-%m-%dT%H:%MZ) | OK |" >> "$LOG"
    log "  OK"
  else
    echo "| \`$repo\` | apply | $(date -u +%Y-%m-%dT%H:%MZ) | FAILED |" >> "$LOG"
    log "  FAILED"
  fi
}

remove_policy() {
  local repo="$1"
  log "[remove] $repo"
  if [ "$DRY_RUN" = "1" ]; then
    log "  [DRY_RUN] would delete-repository-policy"
    return
  fi
  if aws ecr delete-repository-policy \
      --repository-name "$repo" \
      --region "$REGION" >/dev/null 2>&1; then
    echo "| \`$repo\` | remove | $(date -u +%Y-%m-%dT%H:%MZ) | OK |" >> "$LOG"
    log "  OK"
  else
    echo "| \`$repo\` | remove | $(date -u +%Y-%m-%dT%H:%MZ) | FAILED-or-absent |" >> "$LOG"
    log "  FAILED-or-absent"
  fi
}

main() {
  ensure_log
  local repos
  repos=$(list_repos)
  if [ -z "$repos" ]; then
    log "no repositories found with prefix $REPO_PREFIX"
    exit 1
  fi

  log "region:        $REGION"
  log "target:        $TARGET_ACCOUNT"
  log "prefix:        $REPO_PREFIX"
  log "mode:          $([ "$REMOVE" = 1 ] && echo REMOVE || echo APPLY)"
  log "dry-run:       $DRY_RUN"
  log "repositories:"
  for r in $repos; do log "  - $r"; done

  for r in $repos; do
    if [ "$REMOVE" = "1" ]; then
      remove_policy "$r"
    else
      apply_policy "$r"
    fi
  done

  log "Log: $LOG"
}

main "$@"

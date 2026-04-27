#!/usr/bin/env bash
# Share ECR repositories with peer AWS accounts (read-only pull).
#
# Scope:
#   - All regions with ECR repos in this account.
#   - Skips AWS CDK asset repos (cdk-hnb659fds-container-assets-*).
#   - Overwrites repository policy (single AllowCrossAccountPullShared statement).
#
# Usage:
#   scripts/ecr-share-repos.sh --dry-run         # preview, no changes
#   scripts/ecr-share-repos.sh --apply           # apply policy to all repos
#   scripts/ecr-share-repos.sh --apply --filter yanxi/   # only repos matching prefix
#
# Idempotent: rerunning applies identical policy, no drift.

set -euo pipefail

PEERS=(
  "arn:aws:iam::955513527673:root"
  "arn:aws:iam::338295026919:root"
)

ACTIONS='[
  "ecr:BatchGetImage",
  "ecr:GetDownloadUrlForLayer",
  "ecr:BatchCheckLayerAvailability",
  "ecr:DescribeImages",
  "ecr:DescribeRepositories",
  "ecr:ListImages"
]'

REGIONS=(
  ap-east-1 ap-northeast-1 ap-northeast-2 ap-northeast-3
  ap-south-1 ap-southeast-1 ap-southeast-2
  ca-central-1
  eu-central-1 eu-north-1 eu-west-1 eu-west-2 eu-west-3
  me-central-1 sa-east-1
  us-east-1 us-east-2 us-west-1 us-west-2
)

MODE=""
FILTER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --apply)   MODE="apply"; shift ;;
    --filter)  FILTER="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$MODE" ]] && { echo "must pass --dry-run or --apply" >&2; exit 2; }

policy_json() {
  local principals_json
  principals_json=$(printf '"%s",' "${PEERS[@]}" | sed 's/,$//')
  cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowCrossAccountPullShared",
    "Effect": "Allow",
    "Principal": { "AWS": [${principals_json}] },
    "Action": ${ACTIONS}
  }]
}
EOF
}

total=0
skipped=0
applied=0
errored=0

for region in "${REGIONS[@]}"; do
  repos=$(aws ecr describe-repositories --region "$region" \
    --query 'repositories[].repositoryName' --output text 2>/dev/null || true)
  [[ -z "$repos" ]] && continue

  for repo in $repos; do
    # Skip CDK-managed asset repos
    if [[ "$repo" == cdk-hnb659fds-container-assets-* ]]; then
      echo "[skip-cdk] $region/$repo"
      skipped=$((skipped+1))
      continue
    fi

    # Filter (optional prefix match)
    if [[ -n "$FILTER" && "$repo" != ${FILTER}* ]]; then
      continue
    fi

    total=$((total+1))

    if [[ "$MODE" == "dry-run" ]]; then
      echo "[plan] $region/$repo → set AllowCrossAccountPullShared (2 peers)"
      continue
    fi

    # Apply: write policy
    if aws ecr set-repository-policy --region "$region" \
        --repository-name "$repo" \
        --policy-text "$(policy_json)" \
        --output text --query 'repositoryName' >/dev/null 2>&1; then
      echo "[ok] $region/$repo"
      applied=$((applied+1))
    else
      echo "[ERROR] $region/$repo — failed to set policy" >&2
      errored=$((errored+1))
    fi
  done
done

echo ""
echo "=== Summary ==="
echo "mode:        $MODE"
echo "planned:     $total"
echo "applied:     $applied"
echo "skipped-cdk: $skipped"
echo "errors:      $errored"

[[ "$errored" -gt 0 ]] && exit 1 || exit 0

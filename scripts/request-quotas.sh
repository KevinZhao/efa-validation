#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Request SageMaker HyperPod quotas for JD JoyAI x AWS joint inference POC.
#
# Account: 788668107894
# Region:  us-east-2 (Ohio)
#
# Run with:
#   DRY_RUN=1 ./request-quotas.sh    # print what will be submitted
#   ./request-quotas.sh               # actually submit
#
# Tickets returned are captured in QUOTA_TRACKER.md
# -----------------------------------------------------------------------------
set -euo pipefail

REGION="${REGION:-us-east-2}"
DRY_RUN="${DRY_RUN:-0}"
TRACKER="$(dirname "$0")/../QUOTA_TRACKER.md"

JUSTIFICATION_HYPERPOD='JD x AWS joint inference benchmark for JoyAI-LLM-Flash (750B MoE). Migrating from self-managed EKS (2x p5.48xl, Stage 1-2 PASS: EFA all-reduce 476 GB/s, UCCL-EP correctness validated) to SageMaker HyperPod for 4-node end-to-end 1P:1D disaggregated serving POC. Timeline: 8-week POC starting 2026-W17. Reference: AWS x JD joint paper arXiv:2507.16473.'

JUSTIFICATION_EBS='750B MoE checkpoint ~1.5 TB requires per-instance EBS volume > 1 TB. Current HyperPod default (1024 GB) insufficient for model loading. Requesting 2048 GB to fit model + activation buffers + benchmark artifacts per p5.48xlarge node.'

# Format: quota_code | service | desired_value | reason_var
REQUESTS=(
  "L-8762A75F|sagemaker|4|JUSTIFICATION_HYPERPOD"
  "L-E13DF72A|sagemaker|2048|JUSTIFICATION_EBS"
  # --- Optional Spot quotas (uncomment if needed) ---
  # "L-F742E2D7|sagemaker|2|JUSTIFICATION_HYPERPOD"
  # "L-97A2C724|sagemaker|2|JUSTIFICATION_HYPERPOD"
)

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

ensure_tracker() {
  if [ ! -f "$TRACKER" ]; then
    cat > "$TRACKER" <<'EOF'
# AWS Quota Request Tracker

Account: 788668107894 | Region: us-east-2

| # | Quota Name | Quota Code | Current | Requested | Ticket ID | Submitted (UTC) | Status |
|---|---|---|---|---|---|---|---|
EOF
  fi
}

submit_one() {
  local code="$1" service="$2" desired="$3" reason_var="$4"
  local reason="${!reason_var}"

  local name current
  name=$(aws service-quotas get-service-quota \
    --service-code "$service" --quota-code "$code" --region "$REGION" \
    --query 'Quota.QuotaName' --output text 2>/dev/null || echo "unknown")
  current=$(aws service-quotas get-service-quota \
    --service-code "$service" --quota-code "$code" --region "$REGION" \
    --query 'Quota.Value' --output text 2>/dev/null || echo "?")

  log "--- $code ($name) ---"
  log "  current:   $current"
  log "  requested: $desired"

  if [ "$DRY_RUN" = "1" ]; then
    log "  [DRY_RUN] skipping submission"
    return
  fi

  local out ticket status
  out=$(aws service-quotas request-service-quota-increase \
    --service-code "$service" \
    --quota-code "$code" \
    --desired-value "$desired" \
    --region "$REGION" 2>&1) || {
      log "  FAILED: $out"
      echo "| - | $name | $code | $current | $desired | FAILED | $(date -u +%Y-%m-%dT%H:%MZ) | $out |" >> "$TRACKER"
      return
    }

  ticket=$(echo "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["RequestedQuota"]["Id"])' 2>/dev/null || echo unknown)
  status=$(echo "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["RequestedQuota"]["Status"])' 2>/dev/null || echo unknown)
  log "  ticket:    $ticket"
  log "  status:    $status"

  echo "| - | $name | $code | $current | $desired | \`$ticket\` | $(date -u +%Y-%m-%dT%H:%MZ) | $status |" >> "$TRACKER"
}

main() {
  log "Region: $REGION"
  log "Dry run: $DRY_RUN"
  ensure_tracker

  for entry in "${REQUESTS[@]}"; do
    IFS='|' read -r code service desired reason_var <<< "$entry"
    submit_one "$code" "$service" "$desired" "$reason_var"
  done

  log "Done. Tracker: $TRACKER"
}

main "$@"

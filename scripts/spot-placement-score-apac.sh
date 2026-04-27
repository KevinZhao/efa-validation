#!/usr/bin/env bash
# Spot Placement Score (SPS) probe for APAC regions (opted-in only).
# Targets: p5.48xlarge, p5e.48xlarge, p5en.48xlarge, p6-b200.48xlarge, p6-b300.48xlarge @ capacity=4 instances.
# Notes:
#  - GetSpotPlacementScores only returns scores for regions the account is opted-in to.
#  - Instance→region offer matrix below comes from describe-instance-type-offerings on 2026-04-23;
#    APAC regions that are not-opted-in on this account are excluded.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT}/results/sps-apac/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${OUT_DIR}"
LATEST="${ROOT}/results/sps-apac/latest"
ln -sfn "$(basename "${OUT_DIR}")" "${LATEST}"

TARGET_CAPACITY=4
# Global endpoint, stable choice.
API_REGION="us-east-1"

# APAC offer matrix (opted-in regions on account 788668107894, 2026-04-23):
#   ap-south-1      -> p5, p5en
#   ap-northeast-1  -> p5, p5en
#   ap-northeast-2  -> p5, p5en
#   ap-northeast-3  -> (none of these 5 offered)
#   ap-east-1       -> (none of these 5 offered)
#   ap-southeast-1  -> (none of these 5 offered)
#   ap-southeast-2  -> p5, p5e
declare -A INSTANCE_REGIONS
INSTANCE_REGIONS[p5.48xlarge]="ap-south-1 ap-northeast-1 ap-northeast-2 ap-southeast-2"
INSTANCE_REGIONS[p5e.48xlarge]="ap-southeast-2"
INSTANCE_REGIONS[p5en.48xlarge]="ap-south-1 ap-northeast-1 ap-northeast-2"
# Not offered anywhere in opted-in APAC:
INSTANCE_REGIONS[p6-b200.48xlarge]=""
INSTANCE_REGIONS[p6-b300.48xlarge]=""

run_region_level() {
  local itype="$1"
  local regions="${INSTANCE_REGIONS[$itype]}"
  local out="${OUT_DIR}/${itype}-region.json"
  if [[ -z "${regions}" ]]; then
    echo "[region] ${itype} -> (not offered in any opted-in APAC region)" | tee "${out%.json}.skip"
    return
  fi
  echo "[region] ${itype} -> ${regions}"
  # shellcheck disable=SC2086
  aws ec2 get-spot-placement-scores \
    --region "${API_REGION}" \
    --instance-types "${itype}" \
    --target-capacity "${TARGET_CAPACITY}" \
    --region-names ${regions} \
    --output json > "${out}" 2> "${out%.json}.err" \
    || { echo "  !! region-level call failed; see ${out%.json}.err"; }
}

run_az_level() {
  local itype="$1"
  local regions="${INSTANCE_REGIONS[$itype]}"
  local out="${OUT_DIR}/${itype}-az.json"
  if [[ -z "${regions}" ]]; then
    echo "[az] ${itype} -> (skip)" | tee "${out%.json}.skip"
    return
  fi
  echo "[az] ${itype} -> ${regions}"
  # shellcheck disable=SC2086
  aws ec2 get-spot-placement-scores \
    --region "${API_REGION}" \
    --instance-types "${itype}" \
    --target-capacity "${TARGET_CAPACITY}" \
    --single-availability-zone \
    --region-names ${regions} \
    --output json > "${out}" 2> "${out%.json}.err" \
    || { echo "  !! AZ-level call failed; see ${out%.json}.err"; }
}

for itype in p5.48xlarge p5e.48xlarge p5en.48xlarge p6-b200.48xlarge p6-b300.48xlarge; do
  run_region_level "${itype}"
  run_az_level "${itype}"
done

echo
echo "Results written to: ${OUT_DIR}"
ls -1 "${OUT_DIR}"

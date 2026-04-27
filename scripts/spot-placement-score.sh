#!/usr/bin/env bash
# Spot Placement Score (SPS) probe for US regions.
# Targets: p5.48xlarge, p5e.48xlarge, p5en.48xlarge, p6-b200.48xlarge, p6-b300.48xlarge @ capacity=4 instances.
# Outputs two JSON per (instance, scope) under results/sps/:
#   - <instance>-<scope>-region.json   (region-level scores, all US regions where offered)
#   - <instance>-<scope>-az.json       (AZ-level scores, single-AZ placement)
# "scope" is the EC2 API caller's scope; region-level uses --region-names US-regions-that-offer.
# AZ-level uses --single-availability-zone and iterates per region (SPS API only returns scores
# for regions the caller is opted-in to; we call per-region with that region's --region).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT}/results/sps/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${OUT_DIR}"
LATEST="${ROOT}/results/sps/latest"
ln -sfn "$(basename "${OUT_DIR}")" "${LATEST}"

TARGET_CAPACITY=4
US_REGIONS=(us-east-1 us-east-2 us-west-1 us-west-2)

# Per https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_GetSpotPlacementScores.html
# --region-names filters the returned scores. Empty list = all opted-in regions.
# --single-availability-zone true => scores are per AZ.
# Global endpoint works from any region, but we pin to us-east-1 for stability.
API_REGION="us-east-1"

declare -A INSTANCE_REGIONS
INSTANCE_REGIONS[p5.48xlarge]="us-east-1 us-east-2 us-west-1 us-west-2"
INSTANCE_REGIONS[p5e.48xlarge]="us-east-2 us-west-2"
INSTANCE_REGIONS[p5en.48xlarge]="us-east-1 us-east-2 us-west-1 us-west-2"
INSTANCE_REGIONS[p6-b200.48xlarge]="us-east-1 us-east-2 us-west-2"
INSTANCE_REGIONS[p6-b300.48xlarge]="us-west-2"

run_region_level() {
  local itype="$1"
  local regions="${INSTANCE_REGIONS[$itype]}"
  local out="${OUT_DIR}/${itype}-region.json"
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

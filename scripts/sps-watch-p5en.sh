#!/usr/bin/env bash
# Background SPS watcher for p5en.48xlarge single-AZ at target-capacity=4.
# Polls every 15 min until any AZ scores >= THRESHOLD (default 6), then exits 0.
# Designed to run under `nohup ... &` or tmux — writes progress to stderr + log file.
#
# Usage:
#   bash scripts/sps-watch-p5en.sh [THRESHOLD] [INTERVAL_SEC] [MAX_POLLS]
#   THRESHOLD    default 6 (per feedback_sps_before_launch memory)
#   INTERVAL_SEC default 1800 (30 min)
#   MAX_POLLS    default 48 (24 h total)
#
# Output:
#   results/sps/watch-p5en/YYYYMMDDTHHMMSSZ.log  — full history
#   results/sps/watch-p5en/latest.json           — most recent scan
#   results/sps/watch-p5en/HIT                   — touched when THRESHOLD met
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT}/results/sps/watch-p5en"
mkdir -p "${OUT_DIR}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="${OUT_DIR}/${STAMP}.log"
HIT="${OUT_DIR}/HIT"
rm -f "${HIT}"

THRESHOLD="${1:-6}"
INTERVAL="${2:-1800}"
MAX_POLLS="${3:-48}"
TARGET_CAPACITY=4
INSTANCE="p5en.48xlarge"
REGIONS=(us-east-1 us-east-2 us-west-1 us-west-2)
API_REGION="us-east-1"

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "${LOG}" >&2; }

log "SPS watcher start: instance=${INSTANCE} target=${TARGET_CAPACITY} threshold>=${THRESHOLD} interval=${INTERVAL}s max_polls=${MAX_POLLS}"

for ((i=1; i<=MAX_POLLS; i++)); do
  SNAP="${OUT_DIR}/scan-${STAMP}-${i}.json"
  # shellcheck disable=SC2086
  if aws ec2 get-spot-placement-scores \
      --region "${API_REGION}" \
      --instance-types "${INSTANCE}" \
      --target-capacity "${TARGET_CAPACITY}" \
      --single-availability-zone \
      --region-names "${REGIONS[@]}" \
      --output json > "${SNAP}" 2> "${SNAP%.json}.err"; then
    cp "${SNAP}" "${OUT_DIR}/latest.json"
  else
    log "poll ${i}: API call failed (see ${SNAP%.json}.err); continuing"
    sleep "${INTERVAL}"
    continue
  fi

  BEST=$(python3 - <<PY
import json
with open("${SNAP}") as f: d=json.load(f)
rows = d.get("SpotPlacementScores", [])
rows.sort(key=lambda r: -r.get("Score",0))
if not rows:
    print("NONE 0"); exit()
top = rows[0]
print(f"{top.get('Region','?')}/{top.get('AvailabilityZoneId','?')} {top.get('Score',0)}")
PY
)
  SCORE="${BEST##* }"
  WHERE="${BEST% *}"
  log "poll ${i}/${MAX_POLLS}: best=${WHERE} score=${SCORE}"

  if [ "${SCORE}" -ge "${THRESHOLD}" ] 2>/dev/null; then
    log "THRESHOLD MET: ${WHERE} score=${SCORE} >= ${THRESHOLD}"
    {
      echo "time_utc=$(date -u +%FT%TZ)"
      echo "where=${WHERE}"
      echo "score=${SCORE}"
      echo "snap=${SNAP}"
    } > "${HIT}"
    # Also dump top 5 AZs for operator convenience
    python3 - <<PY | tee -a "${LOG}" >&2
import json
with open("${SNAP}") as f: d=json.load(f)
rows = d.get("SpotPlacementScores", [])
rows.sort(key=lambda r: -r.get("Score",0))
print("Top candidates:")
for r in rows[:5]:
    print(f"  {r.get('Region','?'):12} {r.get('AvailabilityZoneId','?'):16} score={r.get('Score',0)}")
PY
    exit 0
  fi

  sleep "${INTERVAL}"
done

log "Exhausted ${MAX_POLLS} polls without hitting threshold=${THRESHOLD}. Latest scan: ${OUT_DIR}/latest.json"
exit 2

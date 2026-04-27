#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Watcher for yanxi model-prefetch instances.
#
# Polls each region's active prefetcher via SSM every $INTERVAL (default 10m),
# writes one NDJSON sample per tick to logs/prefetch-watch.ndjson, and exits
# when all tracked instances have reached a terminal state (terminated or
# completed all models).
#
#   Usage:
#     ./prefetch-models-watch.sh                 # discover from latest NDJSON
#     ./prefetch-models-watch.sh us-east-2:i-abc us-west-2:i-def   # explicit
#
# Environment:
#   INTERVAL=600  # seconds between polls
#   MAX_TICKS=24  # hard cap on polls (24 × 10 min = 4h) — prevents runaway
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RECORDS="${REPO_ROOT}/logs/prefetch-launches.ndjson"
OUT="${REPO_ROOT}/logs/prefetch-watch.ndjson"
SUMMARY="${REPO_ROOT}/logs/prefetch-watch-latest.txt"

INTERVAL="${INTERVAL:-600}"
MAX_TICKS="${MAX_TICKS:-24}"

mkdir -p "$(dirname "$OUT")"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# --- target discovery -------------------------------------------------------
targets=()
if [ "$#" -gt 0 ]; then
  for arg in "$@"; do targets+=("$arg"); done
else
  if [ ! -s "$RECORDS" ]; then
    echo "no records in $RECORDS and no targets given" >&2
    exit 2
  fi
  # Pick the most recent launch per region so restarted prefetchers supersede
  # old ones that have already terminated.
  while IFS= read -r line; do
    targets+=("$line")
  done < <(
    jq -r 'select(.region and .instance_id) | "\(.launched_at)\t\(.region):\(.instance_id)"' "$RECORDS" \
      | sort -r \
      | awk -F'\t' '!seen[$2 ~ /us-east-2/ ? "oh" : "or"]++ {
          print $2
        }'
  )
fi

if [ "${#targets[@]}" -eq 0 ]; then
  echo "no targets resolved" >&2
  exit 2
fi
log "targets: ${targets[*]}"

# --- one poll cycle ---------------------------------------------------------
poll_one() {
  local region=$1 iid=$2 tick=$3
  local state
  state=$(aws ec2 describe-instances --region "$region" --instance-ids "$iid" \
    --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "missing")

  if [ "$state" != "running" ]; then
    jq -c -n \
      --arg ts "$(date -u -Is)" \
      --argjson tick "$tick" \
      --arg region "$region" \
      --arg iid "$iid" \
      --arg state "$state" \
      '{ts:$ts, tick:$tick, region:$region, instance_id:$iid, state:$state}'
    return
  fi

  local cmd='set -eu
  declare -A expected=( ["Qwen3-Next-80B-A3B-Instruct"]=85 ["Qwen3-235B-A22B-Instruct-2507-FP8"]=240 ["GLM-4.6"]=340 ["DeepSeek-V3.1"]=640 ["Kimi-K2-Instruct-0905"]=959 )
  total_bytes=0
  done_n=0
  echo "MODELS_START"
  for m in Qwen3-Next-80B-A3B-Instruct Qwen3-235B-A22B-Instruct-2507-FP8 GLM-4.6 DeepSeek-V3.1 Kimi-K2-Instruct-0905 DeepSeek-V4-Pro; do
    d=/fsx/$m
    if [ -d "$d" ]; then
      bytes=$(du -sb "$d" 2>/dev/null | awk "{print \$1}")
      files=$(find "$d" -type f 2>/dev/null | wc -l)
      incomplete=$(find "$d" -name "*.incomplete" 2>/dev/null | wc -l)
    else
      bytes=0; files=0; incomplete=0
    fi
    if [ -f "$d/.prefetch-complete" ]; then done=1; done_n=$((done_n+1)); else done=0; fi
    total_bytes=$((total_bytes + bytes))
    printf "%s\t%s\t%s\t%s\t%s\n" "$m" "$bytes" "$files" "$incomplete" "$done"
  done
  echo "MODELS_END"
  echo "TOTAL_BYTES=$total_bytes"
  echo "DONE_COUNT=$done_n"
  cur=$(ps -ef | grep "[h]f download" | head -1 | awk "{for(i=8;i<=NF;i++) printf \"%s \", \$i; print \"\"}")
  echo "CURRENT=${cur:-none}"
  last=$(grep -E "BEGIN |END |error|attempt .* failed" /var/log/yanxi-prefetch.log 2>/dev/null | tail -3 | tr "\n" "|")
  echo "LAST=${last:-}"
'
  local cid out
  cid=$(aws ssm send-command --region "$region" --instance-ids "$iid" \
    --document-name AWS-RunShellScript \
    --parameters "$(python3 -c "import json,sys;print(json.dumps({'commands':[sys.argv[1]]}))" "$cmd")" \
    --output text --query Command.CommandId 2>/dev/null || echo "")
  if [ -z "$cid" ]; then
    jq -c -n --arg ts "$(date -u -Is)" --argjson tick "$tick" --arg region "$region" --arg iid "$iid" \
      '{ts:$ts, tick:$tick, region:$region, instance_id:$iid, state:"ssm_send_failed"}'
    return
  fi
  local st
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 3
    st=$(aws ssm get-command-invocation --region "$region" --instance-id "$iid" --command-id "$cid" --query Status --output text 2>/dev/null || echo unknown)
    if [ "$st" = Success ] || [ "$st" = Failed ]; then break; fi
  done
  out=$(aws ssm get-command-invocation --region "$region" --instance-id "$iid" --command-id "$cid" --query StandardOutputContent --output text 2>/dev/null || echo "")
  if [ "$st" != Success ] || [ -z "$out" ]; then
    jq -c -n --arg ts "$(date -u -Is)" --argjson tick "$tick" --arg region "$region" --arg iid "$iid" --arg status "$st" \
      '{ts:$ts, tick:$tick, region:$region, instance_id:$iid, state:"ssm_probe_failed", ssm_status:$status}'
    return
  fi

  local total_bytes done_count current last models_json
  total_bytes=$(awk -F= '/^TOTAL_BYTES=/{print $2}' <<<"$out")
  done_count=$(awk -F= '/^DONE_COUNT=/{print $2}' <<<"$out")
  current=$(awk -F= '/^CURRENT=/{sub(/^CURRENT=/,""); print; exit}' <<<"$out" | head -c 500)
  last=$(awk -F= '/^LAST=/{sub(/^LAST=/,""); print; exit}' <<<"$out" | head -c 500)
  models_json=$(awk '/^MODELS_START/{flag=1; next} /^MODELS_END/{flag=0} flag' <<<"$out" \
    | jq -Rs 'split("\n")
      | map(select(length>0))
      | map(split("\t"))
      | map({name:.[0], bytes:(.[1]|tonumber), files:(.[2]|tonumber), incomplete:(.[3]|tonumber), complete:((.[4]|tonumber)==1)})')

  jq -c -n \
    --arg ts "$(date -u -Is)" \
    --argjson tick "$tick" \
    --arg region "$region" \
    --arg iid "$iid" \
    --arg state "running" \
    --argjson total_bytes "${total_bytes:-0}" \
    --argjson done_count "${done_count:-0}" \
    --arg current "$current" \
    --arg last "$last" \
    --argjson models "$models_json" \
    '{ts:$ts, tick:$tick, region:$region, instance_id:$iid, state:$state, total_bytes:$total_bytes, done_count:$done_count, current:$current, last:$last, models:$models}'
}

# --- main loop --------------------------------------------------------------
tick=0
while [ "$tick" -lt "$MAX_TICKS" ]; do
  tick=$((tick + 1))
  log "=== tick ${tick}/${MAX_TICKS} ==="

  > "$SUMMARY"
  printf '=== watcher tick %d @ %s ===\n' "$tick" "$(date -u -Is)" >> "$SUMMARY"

  all_done=true
  for t in "${targets[@]}"; do
    region="${t%%:*}"
    iid="${t##*:}"
    row=$(poll_one "$region" "$iid" "$tick")
    echo "$row" >> "$OUT"

    state=$(jq -r '.state' <<<"$row")
    done_count=$(jq -r '.done_count // 0' <<<"$row")
    total_gb=$(jq -r '(.total_bytes // 0) / (1024*1024*1024) | round' <<<"$row" 2>/dev/null || echo "?")
    cur=$(jq -r '.current // ""' <<<"$row" | head -c 80)
    printf '[%s/%s] state=%s done=%s/6 total=%s GiB curr=%s\n' "$region" "$iid" "$state" "$done_count" "$total_gb" "$cur" \
      | tee -a "$SUMMARY"

    case "$state" in
      terminated|stopped|shutting-down|missing)
        : # terminal, leaves all_done true
        ;;
      running)
        if [ "${done_count:-0}" -lt 6 ]; then
          all_done=false
        else
          log "$iid reports all 6 complete — instance should self-terminate shortly"
        fi
        ;;
      *)
        # ssm_send_failed / ssm_probe_failed / unknown — treat as transient,
        # NOT as completion. Past experience: FSx resize IN_PROGRESS made SSM
        # timeout and the watcher exited early.
        all_done=false
        ;;
    esac
  done

  if [ "$all_done" = true ]; then
    log "all targets in terminal/complete state; exiting after tick ${tick}"
    break
  fi
  log "sleeping ${INTERVAL}s until next tick"
  sleep "$INTERVAL"
done

log "watcher finished; final summary:"
cat "$SUMMARY" >&2

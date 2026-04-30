#!/bin/bash
# A/B matrix driver — runs on the Prefill node (where the router lives).
# Alternates A B A B A B per scenario to cancel any slow drift.
#
# Requires on this node:
#   - /data/entrypoints/{prefill_entrypoint.sh,decode_entrypoint.sh}
#   - /data/models/Kimi-K2.5/ (555 GiB INT4 weights)
#   - docker-compose files mounted or referenced by path
#   - SSH key to the decode node ($DECODE_HOST) with docker-compose rights
#   - compose files present on BOTH nodes
#
# Usage:
#   STAMP=$(date -u +%Y%m%dT%H%M%SZ) \
#   DECODE_HOST=10.99.10.X \
#   ROUTER_URL=http://127.0.0.1:38000 \
#   RESULTS_DIR=/data/results/pd-1p1d-mc-vs-nixl-k25-int4/$STAMP \
#   ./run_ab_matrix.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/bench_profile.sh"

: "${STAMP:?STAMP is required}"
: "${DECODE_HOST:?DECODE_HOST is required (ssh-reachable private IP of decode node)}"
: "${ROUTER_URL:=http://127.0.0.1:38000}"
: "${RESULTS_DIR:=/data/results/pd-1p1d-mc-vs-nixl-k25-int4/${STAMP}}"
: "${MODEL_TOKENIZER:=/models/model}"

COMPOSE_DIR_LOCAL="${COMPOSE_DIR_LOCAL:-/data/stage5/compose}"
COMPOSE_DIR_REMOTE="${COMPOSE_DIR_REMOTE:-/data/stage5/compose}"

mkdir -p "$RESULTS_DIR"/{raw,logs,efa_counters}
STEPS="$RESULTS_DIR/STEPS.md"
touch "$STEPS"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$STEPS"; }

# ---- helper: start/stop containers ----
start_variant() {
    local backend="$1"
    log "=== starting variant backend=${backend} ==="

    # Prefill (local)
    KV_BACKEND="$backend" docker compose -f "${COMPOSE_DIR_LOCAL}/prefill-compose.yml" up -d
    # Decode (remote over SSH)
    ssh "$DECODE_HOST" "KV_BACKEND=${backend} docker compose -f ${COMPOSE_DIR_REMOTE}/decode-compose.yml up -d"
    # Router (local)
    docker compose -f "${COMPOSE_DIR_LOCAL}/router-compose.yml" up -d

    log "waiting for /health on prefill + decode + router ..."
    for step in {1..180}; do
        p=$(curl -sf http://127.0.0.1:30081/health >/dev/null 2>&1 && echo OK || echo WAIT)
        d=$(ssh "$DECODE_HOST" 'curl -sf http://127.0.0.1:30082/health >/dev/null 2>&1 && echo OK || echo WAIT')
        r=$(curl -sf "${ROUTER_URL}/health" >/dev/null 2>&1 && echo OK || echo WAIT)
        if [[ "$p" == OK && "$d" == OK && "$r" == OK ]]; then
            log "all healthy after ${step}0s"
            return 0
        fi
        sleep 10
    done
    log "FATAL: variant ${backend} did not become healthy within 30 min"
    return 1
}

stop_variant() {
    log "=== stopping variant ==="
    docker compose -f "${COMPOSE_DIR_LOCAL}/router-compose.yml"  down --remove-orphans || true
    docker compose -f "${COMPOSE_DIR_LOCAL}/prefill-compose.yml" down --remove-orphans || true
    ssh "$DECODE_HOST" "docker compose -f ${COMPOSE_DIR_REMOTE}/decode-compose.yml down --remove-orphans" || true
    sleep 5
}

snapshot_efa_counters() {
    local label="$1"
    local file="$RESULTS_DIR/efa_counters/${label}.json"
    {
        echo "{"
        echo "  \"captured_at\": \"$(date -u -Is)\","
        echo "  \"host_prefill\": {"
        for dev in /sys/class/infiniband/*; do
            name=$(basename "$dev")
            echo "    \"$name\": {"
            for cnt in "$dev/ports/1/hw_counters"/*; do
                [[ -f $cnt ]] || continue
                key=$(basename "$cnt")
                val=$(cat "$cnt" 2>/dev/null || echo null)
                echo "      \"$key\": $val,"
            done | sed '$ s/,$//'
            echo "    },"
        done | sed '$ s/,$//'
        echo "  },"
        echo "  \"host_decode\": $(ssh "$DECODE_HOST" 'python3 -c "
import os, json
out = {}
base = \"/sys/class/infiniband\"
for dev in sorted(os.listdir(base)):
    p = os.path.join(base, dev, \"ports\", \"1\", \"hw_counters\")
    if not os.path.isdir(p): continue
    out[dev] = {}
    for f in sorted(os.listdir(p)):
        try:
            with open(os.path.join(p,f)) as fh:
                out[dev][f] = int(fh.read().strip())
        except: pass
print(json.dumps(out))
"')"
        echo "}"
    } > "$file"
    log "snapshot efa -> $file"
}

bench_one_scenario() {
    local scenario="$1"   # e.g. S1
    local backend="$2"    # mooncake|nixl
    local round="$3"      # 1|2|3

    local inp="${SCENARIO_INPUT_LEN[$scenario]}"
    local out="${SCENARIO_OUTPUT_LEN[$scenario]}"
    local conc="${SCENARIO_CONCURRENCY[$scenario]}"
    local nprom="${SCENARIO_NUM_PROMPTS[$scenario]}"
    local warm="${SCENARIO_WARMUP[$scenario]}"

    local tag="${scenario,,}-${backend}-r${round}"
    local raw="$RESULTS_DIR/raw/${tag}.json"

    log ">>> bench ${tag}: in=${inp} out=${out} conc=${conc} prompts=${nprom} warmup=${warm}"

    snapshot_efa_counters "before-${tag}"

    # warmup (no output file, results discarded)
    python3 -m sglang.bench_serving \
        --backend sglang \
        --base-url "$ROUTER_URL" \
        --dataset-name random \
        --random-input-len "$inp" \
        --random-output-len "$out" \
        --num-prompts "$warm" \
        --max-concurrency "$conc" \
        --model /models/model \
        --tokenizer "$MODEL_TOKENIZER" \
        2>&1 | tail -20 >> "$RESULTS_DIR/logs/${tag}-warmup.log" || true

    # measurement
    python3 -m sglang.bench_serving \
        --backend sglang \
        --base-url "$ROUTER_URL" \
        --dataset-name random \
        --random-input-len "$inp" \
        --random-output-len "$out" \
        --num-prompts "$nprom" \
        --max-concurrency "$conc" \
        --model /models/model \
        --tokenizer "$MODEL_TOKENIZER" \
        --output-file "$raw" \
        2>&1 | tee "$RESULTS_DIR/logs/${tag}.log"

    snapshot_efa_counters "after-${tag}"
    log "<<< bench ${tag} done, raw=$raw"
}

# ---- main ----
log "=== A/B matrix start, stamp=${STAMP} ==="
log "results dir: $RESULTS_DIR"
log "decode host: $DECODE_HOST"
log "router url:  $ROUTER_URL"
log "scenarios:   ${SCENARIOS[*]}  rounds=${ROUNDS}  backends=${BACKENDS[*]}"

# Alternate A B A B A B per scenario (anti-drift)
for scenario in "${SCENARIOS[@]}"; do
    log "### scenario=${scenario}"
    for round in $(seq 1 $ROUNDS); do
        for backend in "${BACKENDS[@]}"; do
            start_variant "$backend"
            bench_one_scenario "$scenario" "$backend" "$round"
            stop_variant
        done
    done
done

log "=== A/B matrix complete ==="
log "run post-processing: python3 scripts/stage5-pd-1p1d-mc-vs-nixl/bench/summarize.py $RESULTS_DIR"

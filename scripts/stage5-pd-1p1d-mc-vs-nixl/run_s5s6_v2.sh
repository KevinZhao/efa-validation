#!/bin/bash
# S5/S6 v2 — adds a 2K/256 smoke warmup AFTER each apply to prime the sglang
# router's prefill-worker selection BEFORE hitting it with 60K/120K long-context
# bench. First v1 run failed because cold router rejected the 60K warmup
# (sglang bench_serving aborts on first failure). Short smoke succeeds and
# primes the PD KV channel so subsequent long-context benches go through.
#
# Re-runs Mooncake + NIXL S5/S6 from scratch, overwriting partial raw JSONs
# from the v1 run. Same STAMP so results merge with S1-S4.

set -u
export KUBECONFIG=/root/.kube/config
export PATH=/usr/local/bin:/usr/bin:/bin

STAMP="${STAMP:-20260501T002853Z}"
RESULTS=/root/results/pd-1p1d-mc-vs-nixl-k25-int4/${STAMP}
MANIFEST=/root/stage5/pd-1p1d-mc-vs-nixl-k25-int4-usw2.yaml
NS=yanxi-validation
S3_RESULTS=s3://yanxi-validation-788668107894-oregon/results/pd-1p1d-mc-vs-nixl-k25-int4/${STAMP}
S3_REGION=us-west-2

mkdir -p "$RESULTS"/{raw,logs,summary}
LOG=$RESULTS/STEPS.md
touch "$LOG"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }
sync_to_s3() { aws s3 sync "$RESULTS" "$S3_RESULTS" --region "$S3_REGION" --quiet 2>&1 | tail -3 >> "$LOG" || true; }

declare -A IN=([S5]=61440  [S6]=122880)
declare -A OUT=([S5]=1024   [S6]=1024)
declare -A CC=([S5]=8      [S6]=4)
declare -A NP=([S5]=60     [S6]=30)
declare -A WU=([S5]=6      [S6]=3)
SCENS=(S5 S6)
ROUNDS=3

get_lb_pod()      { kubectl -n "$NS" get pod -l app=c1p1d-lb -o name 2>/dev/null | head -1; }
get_prefill_pod() { kubectl -n "$NS" get pod -l role=prefill -o name 2>/dev/null | head -1; }

wait_ready() {
    local timeout="${1:-1800}"
    local start=$(date -u +%s)
    log "wait_ready (timeout ${timeout}s)"
    while true; do
        r1=$(kubectl -n "$NS" get deploy c1p1d-prefill -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
        r2=$(kubectl -n "$NS" get deploy c1p1d-decode -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
        r3=$(kubectl -n "$NS" get deploy c1p1d-lb -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
        ts=$(date -u +%H:%M:%SZ)
        log "  [$ts] readiness p=${r1:-0}/1 d=${r2:-0}/1 lb=${r3:-0}/1"
        if [[ "${r1:-0}" == "1" && "${r2:-0}" == "1" && "${r3:-0}" == "1" ]]; then
            lb=$(get_lb_pod)
            if kubectl -n "$NS" exec "$lb" -- python3 -c 'import urllib.request,sys; urllib.request.urlopen("http://localhost:8000/health",timeout=3); sys.exit(0)' >/dev/null 2>&1; then
                log "all Ready + router health ok after $(( $(date -u +%s) - start ))s"
                return 0
            fi
        fi
        if [ $(( $(date -u +%s) - start )) -gt "$timeout" ]; then
            log "TIMEOUT"
            kubectl -n "$NS" get pods -o wide >> "$LOG" 2>&1
            return 1
        fi
        sleep 30
    done
}

run_bench() {
    local tag=$1 inp=$2 out=$3 cc=$4 np=$5 wu=$6
    local runner
    runner=$(get_prefill_pod)
    [[ -z "$runner" ]] && { log "no prefill pod; abort"; return 1; }
    local raw_remote="/tmp/${tag}.json"
    local lg="$RESULTS/logs/${tag}.log"
    log "bench $tag in=$inp out=$out cc=$cc np=$np wu=$wu (runner=$runner)"

    local MODEL_LOCAL=/models/moonshotai/Kimi-K2.5
    local LB_URL="http://c1p1d-lb.${NS}.svc:8000"

    kubectl -n "$NS" exec "$runner" -c server -- env HF_TOKEN="$HF_TOKEN" HUGGING_FACE_HUB_TOKEN="$HF_TOKEN" \
        python3 -m sglang.bench_serving --backend sglang --base-url "$LB_URL" \
        --dataset-name random --random-input-len "$inp" --random-output-len "$out" \
        --num-prompts "$wu" --max-concurrency "$cc" \
        --model "$MODEL_LOCAL" --tokenizer "$MODEL_LOCAL" --disable-tqdm \
        > "$RESULTS/logs/${tag}-warmup.log" 2>&1 || log "warmup $tag non-zero (continuing)"

    kubectl -n "$NS" exec "$runner" -c server -- env HF_TOKEN="$HF_TOKEN" HUGGING_FACE_HUB_TOKEN="$HF_TOKEN" \
        python3 -m sglang.bench_serving --backend sglang --base-url "$LB_URL" \
        --dataset-name random --random-input-len "$inp" --random-output-len "$out" \
        --num-prompts "$np" --max-concurrency "$cc" \
        --model "$MODEL_LOCAL" --tokenizer "$MODEL_LOCAL" --disable-tqdm \
        --output-file "$raw_remote" > "$lg" 2>&1
    ec=$?
    if [[ $ec -ne 0 ]]; then
        log "bench $tag FAILED exit=$ec"
        tail -30 "$lg" >> "$LOG" || true
        return $ec
    fi

    kubectl -n "$NS" cp "${runner#pod/}:$raw_remote" "$RESULTS/raw/${tag}.json" -c server 2>/dev/null \
        || kubectl -n "$NS" exec "$runner" -c server -- cat "$raw_remote" > "$RESULTS/raw/${tag}.json" 2>/dev/null
    if [[ -s "$RESULTS/raw/${tag}.json" ]]; then
        log "bench $tag OK raw=$(stat -c %s "$RESULTS/raw/${tag}.json") bytes"
    else
        log "bench $tag: result file empty — check logs"
    fi
    sync_to_s3
}

# prime_router — short smoke bench that primes the sglang router/PD channel.
# Retries up to 3 times since router's first "detect prefill worker" pass may
# still reject while mooncake/nixl finishes peer bring-up.
prime_router() {
    local backend=$1
    local tag="prime-${backend}-s5s6"
    local attempt=1
    while [[ $attempt -le 3 ]]; do
        log "prime_router attempt=$attempt backend=$backend"
        local runner=$(get_prefill_pod)
        [[ -z "$runner" ]] && { log "no prefill pod; abort prime"; return 1; }
        local MODEL_LOCAL=/models/moonshotai/Kimi-K2.5
        local LB_URL="http://c1p1d-lb.${NS}.svc:8000"
        if kubectl -n "$NS" exec "$runner" -c server -- env HF_TOKEN="$HF_TOKEN" HUGGING_FACE_HUB_TOKEN="$HF_TOKEN" \
            python3 -m sglang.bench_serving --backend sglang --base-url "$LB_URL" \
            --dataset-name random --random-input-len 2048 --random-output-len 256 \
            --num-prompts 6 --max-concurrency 4 \
            --model "$MODEL_LOCAL" --tokenizer "$MODEL_LOCAL" --disable-tqdm \
            > "$RESULTS/logs/${tag}-a${attempt}.log" 2>&1; then
            log "prime_router OK (attempt=$attempt)"
            return 0
        fi
        log "prime_router attempt=$attempt failed; sleep 15 + retry"
        sleep 15
        attempt=$((attempt+1))
    done
    log "prime_router ALL attempts failed; continuing anyway"
    return 0  # don't block the matrix — router may self-recover
}

teardown_wait() {
    log "teardown all deploys"
    kubectl -n "$NS" delete deploy --all --wait=false 2>&1 | tee -a "$LOG"
    local start=$(date -u +%s)
    while true; do
        n=$(kubectl -n "$NS" get pods -l 'app in (c1p1d,c1p1d-lb)' -o name 2>/dev/null | wc -l)
        [[ "$n" == "0" ]] && { log "pods gone in $(( $(date -u +%s) - start ))s"; return 0; }
        if [ $(( $(date -u +%s) - start )) -gt 600 ]; then
            log "force delete"
            kubectl -n "$NS" delete pods --all --force --grace-period=0 2>/dev/null
            sleep 10
            return 0
        fi
        sleep 10
    done
}

apply_variant() {
    local backend=$1
    log "apply variant backend=$backend"
    KV_BACKEND="$backend" envsubst '$KV_BACKEND' < "$MANIFEST" | kubectl apply -f -
    wait_ready 1800
}

run_matrix() {
    local backend=$1
    for sc in "${SCENS[@]}"; do
        for r in $(seq 1 $ROUNDS); do
            local tag="${sc,,}-${backend}-r${r}"
            run_bench "$tag" "${IN[$sc]}" "${OUT[$sc]}" "${CC[$sc]}" "${NP[$sc]}" "${WU[$sc]}" || log "bench $tag failed (continuing)"
        done
    done
}

# ============= MAIN =============
log "=== S5/S6 v2 (router-primed) START stamp=$STAMP ==="

# Clean any lingering partial raw JSONs from v1 so summarize picks up fresh data.
rm -f "$RESULTS"/raw/s5-*.json "$RESULTS"/raw/s6-*.json 2>/dev/null || true
log "cleared v1 partial S5/S6 raw JSONs"

teardown_wait
apply_variant mooncake || { log "APPLY mooncake FAILED"; exit 1; }
prime_router mooncake
log "=== FULL mooncake S5/S6 ==="
run_matrix mooncake

log "=== SWITCH to nixl ==="
teardown_wait
apply_variant nixl || { log "APPLY nixl FAILED"; exit 3; }
prime_router nixl
log "=== FULL nixl S5/S6 ==="
run_matrix nixl

log "=== FINAL teardown ==="
teardown_wait

kubectl -n "$NS" get events --sort-by='.lastTimestamp' > "$RESULTS/logs/events-s5s6-v2.txt" 2>&1 || true

touch "$RESULTS/.complete-s5s6-v2"
log "=== S5/S6 v2 COMPLETE ==="
sync_to_s3

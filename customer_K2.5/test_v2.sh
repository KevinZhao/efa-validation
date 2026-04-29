set -eu
mkdir -p /results
for i in $(seq 1 60); do
CODE=$(curl -o /dev/null -s -w "%{http_code}" http://6.166.123.15:30000/v1/models 2>/dev/null || echo 000)
echo "wait lb attempt=$i code=$CODE"
[ "$CODE" = "200" ] && break
sleep 5
done
# Kimi K2: start with 16 prompts × short rate sweep to avoid multi-hour bench.
for RATE in 1 2 4; do
echo "====== Kimi K2 rate=${RATE} ======"
python3 -m sglang.bench_serving \
    --backend sglang-oai-chat \
    --host "6.166.123.15" --port "30000" \
    --model "/export/models/moonshotai/Kimi-K2.5" \
    --tokenizer "/export/models/moonshotai/Kimi-K2.5" \
    --num-prompts 1000 \
    --max-concurrency 128 \
    --dataset-name random \
    --random-input-len 2048 \
    --random-output-len 1024 \
    --request-rate "${RATE}" \
    --pd-separated \
    --output-file /results/kimi-r${RATE}.json \
    2>&1 | tee /results/kimi-r${RATE}.log
done
echo "=== DONE ==="
echo "========== SUMMARY =========="
for RATE in 1 2 4; do
echo "--- Kimi K2 rate=${RATE} ---"
grep -E "Successful requests|Benchmark duration|Request throughput|Output token throughput|Total token throughput|Mean TTFT|Median TTFT|P99 TTFT|Mean TPOT|Mean ITL" /results/kimi-r${RATE}.log || true
done
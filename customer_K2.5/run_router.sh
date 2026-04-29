python3 -m sglang_router.launch_router \
    --pd-disaggregation \
    --prefill http://6.166.125.145:30081 \
    --decode http://6.166.120.207:30082 \
    --tokenizer-path /export/models/moonshotai/Kimi-K2.5 \
    --host 0.0.0.0 \
    --port 30000
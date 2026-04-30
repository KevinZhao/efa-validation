#!/bin/bash
# Workload matrix (S1-S4). Source this before run_ab_matrix.sh.
# Values are tuples: INPUT_LEN OUTPUT_LEN CONCURRENCY NUM_PROMPTS WARMUP

declare -A SCENARIO_INPUT_LEN=(
    [S1]=2048
    [S2]=8192
    [S3]=32768
    [S4]=4096
)
declare -A SCENARIO_OUTPUT_LEN=(
    [S1]=512
    [S2]=1024
    [S3]=1024
    [S4]=512
)
declare -A SCENARIO_CONCURRENCY=(
    [S1]=32
    [S2]=64
    [S3]=16
    [S4]=128
)
declare -A SCENARIO_NUM_PROMPTS=(
    [S1]=1000
    [S2]=1000
    [S3]=500
    [S4]=1000
)
declare -A SCENARIO_WARMUP=(
    [S1]=100
    [S2]=100
    [S3]=50
    [S4]=100
)
# Order defines run sequence.
SCENARIOS=(S1 S2 S3 S4)
BACKENDS=(mooncake nixl)
ROUNDS=3

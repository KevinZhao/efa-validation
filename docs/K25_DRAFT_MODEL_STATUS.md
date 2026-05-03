# Kimi-K2.5 Draft/EAGLE/MTP model status — as of 2026-05-03

## HuggingFace search
- **`lightseekorg/kimi-k2.5-eagle3`** — EAGLE3 MTP draft model for Kimi-K2.5, 3B params, BF16/F16 safetensors, ~64K downloads/mo. Trained via TorchSpec (not SpecForge) on 4×8×H200. README gives ready sglang command using `--speculative-algorithm EAGLE3 --speculative-draft-model-path lightseekorg/kimi-k2.5-eagle3 --speculative-num-steps 3 --speculative-eagle-topk 1 --speculative-num-draft-tokens 4`. Requires SGLang ≥0.5.8. https://huggingface.co/lightseekorg/kimi-k2.5-eagle3
- **`modularai/kimi-k2.5-eagle3`** — post-trained variant of the lightseekorg draft on open coding data. https://huggingface.co/modularai/kimi-k2.5-eagle3
- **`nvidia/Kimi-K2.5-Thinking-Eagle3`** — NVIDIA Model Optimizer EAGLE head, TensorRT-LLM serving (published 2025-03-03 label but posted in the Kimi-K2.5 release wave). https://huggingface.co/nvidia/Kimi-K2.5-Thinking-Eagle3
- **`ginsongsong/eagle3-kimik2.5-w4a8`** — INT4 Quark-quantized version of the lightseekorg draft (~4.8 GB). https://huggingface.co/ginsongsong/eagle3-kimik2.5-w4a8
- **`k-l-lambda/Kimi-K2.5-MTP` + `modularai/Kimi-K2.5-MTP`** — DeepSeek-V3-style MTP layer-61 weights (14B), but README warns acceptance ~39% because MTP weights not trained on matched base checkpoint. https://huggingface.co/k-l-lambda/Kimi-K2.5-MTP , https://huggingface.co/modularai/Kimi-K2.5-MTP

## GitHub search (SpecForge, sglang, moonshot-ai)
- **sglang PR #18374** (2026-02-06, merged) — adds `set_eagle3_layers_to_capture` + `get_embed_and_head` on `KimiK25ForConditionalGeneration` (required for the draft above to work). https://github.com/sgl-project/sglang/pull/18374
- **sglang PR #21391** (2026-03-25, merged) — fixes Kimi-K2.5 DP-attn + spec-decode crash with multimodal input. https://github.com/sgl-project/sglang/pull/21391
- **sglang issue #22780** (2026-04-14) — EAGLE3 target/draft ServerArgs leak in chunked prefix cache; hotfix PR #22781. https://github.com/sgl-project/sglang/issues/22780
- **sgl-cookbook** ships the canonical `SGLANG_ENABLE_SPEC_V2=1` launch recipe pointing at `lightseekorg/kimi-k2.5-eagle3`. https://github.com/sgl-project/sgl-cookbook/blob/main/docs/autoregressive/Moonshotai/Kimi-K2.5.md
- **vLLM issue #40608** (2026-04-22) — tracks Kimi-K2.5/K2.6 + `lightseekorg/kimi-k2.5-eagle3-mla` on Blackwell with DCP/FP8 KV.

## Community signals
- **Baseten blog, 2026-02-11** — "How we built the fastest Kimi K2.5 on Artificial Analysis" — trained an in-house EAGLE-3 speculator (~1B params) on hidden states from K2.5, achieving 340+ TPS. Custom model, not released.

## Customer-internal hints (from customer_K2.5/run_prefill.sh)
- Only ref is line 204, inside a **doubly-commented** block (`# #`): `/ufs/zxb/SpecForge/examples/kimi_k2.5/1p1d_2x1_nodes/logs/test_prefill_v4.log`. This is only a log path — no indication they trained or ship a SpecForge-produced draft head. The directory name `kimi_k2.5` in SpecForge `examples/` suggests SpecForge upstream has a K2.5 recipe, but no draft weights were wired into the active prefill command.

## Verdict
- [x] **AVAILABLE**: `lightseekorg/kimi-k2.5-eagle3` (primary, ~64K downloads/mo) — compatible with sglang via `--speculative-algorithm EAGLE3`. Alternates: `modularai/kimi-k2.5-eagle3`, `nvidia/Kimi-K2.5-Thinking-Eagle3` (TRT-LLM), `ginsongsong/eagle3-kimik2.5-w4a8` (INT4). SGLang side requires PR #18374 (merged, so ≥0.5.10 is fine) plus #21391 if using DP-attn+MM, plus #22781 hotfix for chunked prefix cache edge case.
- [ ] IN DEVELOPMENT: N/A
- [ ] NOT AVAILABLE: N/A

Note: MTP-layer-61 route (`k-l-lambda`, `modularai/Kimi-K2.5-MTP`) exists but has only ~39% acceptance — not recommended vs EAGLE3.

## Recommendation
Use `lightseekorg/kimi-k2.5-eagle3` directly. No training needed. Match the cookbook recipe (topk=1, num_steps=3, num_draft_tokens=4). Verify sglang image has PR #18374 merged (in 0.5.10+). For K2.5 the EAGLE path is **live and well-supported** — do not train our own, do not fall back to low-acceptance MTP. SpecForge reference in customer script is a historical log path only; ignore for draft-model sourcing.

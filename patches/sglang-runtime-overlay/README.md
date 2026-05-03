# sglang 0.5.10 runtime overlay for `bench_serving.py`

Drop-in replacement for `/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py`
inside `sglang-mooncake-{uccl,nccl,nixl-uccl}:2026.04.28-h200.6` (and older
`.5` / prior 0.5.10-based tags).

## Why

`bench_serving.py` in sglang 0.5.10 has a scope bug in
`async_request_openai_completions` (the `--backend sglang-oai` path).
The `output_len` update from the trailing usage chunk is indented one
level too deep — inside the `if data["choices"][0]["text"]:` block.

sglang streams the final `completion_tokens` in a usage-only chunk where
`choices[0].text == ""`, so the `if` is False and the update is skipped.
`output_len` stays at its fallback (the request's `max_tokens`), which
makes every downstream metric (TPOT, output throughput, retokenized
length) wrong any time actual generation stops before `max_tokens`
(EOS, length-based stop, abort).

The sibling `async_request_openai_chat_completions` (`--backend sglang-oai-chat`)
has the *correct* indentation — which is why chat works and oai does not.

This file ships the three-line dedent fix. Once sglang upstream merges
the corresponding patch we stop needing it.

## Usage

### Bind-mount with `docker run`

```bash
docker run --rm \
  -v $(pwd)/patches/sglang-runtime-overlay/bench_serving.py:/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py:ro \
  788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/sglang-mooncake-uccl:2026.04.28-h200.6 \
  python -m sglang.bench_serving --backend sglang-oai --host <server> ...
```

### Inject into a running K8s pod (no rebuild, no rollout)

```bash
kubectl cp patches/sglang-runtime-overlay/bench_serving.py \
  <namespace>/<pod>:/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py
# pycache invalidates automatically since the overlay is newer
```

### Verify the patch is active

```bash
python -c "
import sglang.bench_serving, inspect
src = inspect.getsource(sglang.bench_serving.async_request_openai_completions)
# Patched version has 'Check for usage info (runs even when text is empty' comment
assert 'usage info (runs even when text is empty' in src, 'still running buggy upstream'
print('overlay active')
"
```

## Provenance

- Extracted from `public.ecr.aws/n3l4x8f3/sglang-mooncake-uccl:2026.04.28-h200.6`
  with `docker run --rm --entrypoint cat IMAGE /usr/local/.../bench_serving.py`
- Original MD5: `81716676ef94390ffa2a10cbeab684e8` (base64'd)
- Applied fix: dedent lines 316-318 (three-line `output_len = data.get("usage")...`
  block) out of the `if data["choices"][0]["text"]:` conditional
- Python `ast.parse` clean

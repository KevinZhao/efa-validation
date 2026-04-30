[2026-04-30T17:42:56Z] === UNATTENDED A/B START stamp=20260430T174252Z ===
[2026-04-30T17:42:56Z] teardown all deploys
deployment.apps "c1p1d-decode" deleted
deployment.apps "c1p1d-lb" deleted
deployment.apps "c1p1d-prefill" deleted
[2026-04-30T17:43:09Z] pods gone in 12s
[2026-04-30T17:43:09Z] apply variant backend=mooncake
[2026-04-30T17:43:12Z] wait_ready (timeout 1500s)
[2026-04-30T17:43:14Z]   [17:43:14Z] readiness p=0/1 d=0/1 lb=0/1
[2026-04-30T17:43:47Z]   [17:43:47Z] readiness p=0/1 d=0/1 lb=1/1
[2026-04-30T17:44:19Z]   [17:44:19Z] readiness p=0/1 d=0/1 lb=1/1
[2026-04-30T17:44:52Z]   [17:44:52Z] readiness p=0/1 d=0/1 lb=1/1
[2026-04-30T17:45:24Z]   [17:45:24Z] readiness p=0/1 d=0/1 lb=1/1
[2026-04-30T17:45:57Z]   [17:45:57Z] readiness p=0/1 d=0/1 lb=1/1
[2026-04-30T17:46:29Z]   [17:46:29Z] readiness p=0/1 d=0/1 lb=1/1
[2026-04-30T17:47:02Z]   [17:47:02Z] readiness p=0/1 d=0/1 lb=1/1
[2026-04-30T17:47:34Z]   [17:47:34Z] readiness p=0/1 d=0/1 lb=1/1
[2026-04-30T17:48:07Z]   [17:48:07Z] readiness p=0/1 d=0/1 lb=1/1
[2026-04-30T17:48:39Z]   [17:48:39Z] readiness p=0/1 d=0/1 lb=1/1
[2026-04-30T17:49:12Z]   [17:49:12Z] readiness p=1/1 d=0/1 lb=1/1
[2026-04-30T17:49:44Z]   [17:49:44Z] readiness p=1/1 d=0/1 lb=1/1
[2026-04-30T17:50:17Z]   [17:50:17Z] readiness p=1/1 d=0/1 lb=1/1
[2026-04-30T17:50:49Z]   [17:50:49Z] readiness p=1/1 d=0/1 lb=1/1
[2026-04-30T17:51:22Z]   [17:51:22Z] readiness p=1/1 d=0/1 lb=1/1
[2026-04-30T17:51:54Z]   [17:51:54Z] readiness p=1/1 d=0/1 lb=1/1
[2026-04-30T17:52:27Z]   [17:52:27Z] readiness p=1/1 d=0/1 lb=1/1
[2026-04-30T17:52:59Z]   [17:52:59Z] readiness p=1/1 d=0/1 lb=1/1
[2026-04-30T17:53:32Z]   [17:53:32Z] readiness p=1/1 d=0/1 lb=1/1
[2026-04-30T17:54:04Z]   [17:54:04Z] readiness p=1/1 d=0/1 lb=1/1
[2026-04-30T17:54:37Z]   [17:54:37Z] readiness p=1/1 d=0/1 lb=1/1
[2026-04-30T17:55:09Z]   [17:55:09Z] readiness p=1/1 d=0/1 lb=1/1
[2026-04-30T17:55:42Z]   [17:55:42Z] readiness p=1/1 d=0/1 lb=1/1
[2026-04-30T17:56:14Z]   [17:56:14Z] readiness p=1/1 d=0/1 lb=1/1
[2026-04-30T17:56:47Z]   [17:56:47Z] readiness p=1/1 d=0/1 lb=1/1
[2026-04-30T17:57:19Z]   [17:57:19Z] readiness p=1/1 d=0/1 lb=1/1
[2026-04-30T17:57:52Z]   [17:57:52Z] readiness p=1/1 d=1/1 lb=1/1
[2026-04-30T17:57:54Z] all Ready + router health ok after 882s
[2026-04-30T17:57:54Z] === SMOKE mooncake ===
[2026-04-30T17:57:54Z] bench smoke-mooncake in=2048 out=256 cc=8 np=15 wu=3 (runner=pod/c1p1d-prefill-68759b55b5-dg6kg)
[2026-04-30T17:58:06Z] warmup smoke-mooncake non-zero (continuing)
[2026-04-30T17:58:17Z] bench smoke-mooncake FAILED exit=1

The above exception was the direct cause of the following exception:

Traceback (most recent call last):
  File "/usr/lib/python3.10/runpy.py", line 196, in _run_module_as_main
    return _run_code(code, main_globals, None,
  File "/usr/lib/python3.10/runpy.py", line 86, in _run_code
    exec(code, run_globals)
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 2352, in <module>
    run_benchmark(args)
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 1848, in run_benchmark
    input_requests = get_dataset(args, tokenizer, model_id)
  File "/usr/local/lib/python3.10/dist-packages/sglang/benchmark/datasets/__init__.py", line 42, in get_dataset
    return dataset.load(tokenizer=tokenizer, model_id=model_id)
  File "/usr/local/lib/python3.10/dist-packages/sglang/benchmark/datasets/random.py", line 45, in load
    return sample_random_requests(
  File "/usr/local/lib/python3.10/dist-packages/sglang/benchmark/datasets/random.py", line 89, in sample_random_requests
    dataset_path = download_and_cache_hf_file(
  File "/usr/local/lib/python3.10/dist-packages/sglang/benchmark/utils.py", line 98, in download_and_cache_hf_file
    return hf_hub_download(repo_id=repo_id, filename=filename, repo_type=repo_type)
  File "/usr/local/lib/python3.10/dist-packages/huggingface_hub/utils/_validators.py", line 88, in _inner_fn
    return fn(*args, **kwargs)
  File "/usr/local/lib/python3.10/dist-packages/huggingface_hub/file_download.py", line 997, in hf_hub_download
    return _hf_hub_download_to_cache_dir(
  File "/usr/local/lib/python3.10/dist-packages/huggingface_hub/file_download.py", line 1148, in _hf_hub_download_to_cache_dir
    _raise_on_head_call_error(head_call_error, force_download, local_files_only)
  File "/usr/local/lib/python3.10/dist-packages/huggingface_hub/file_download.py", line 1785, in _raise_on_head_call_error
    raise LocalEntryNotFoundError(
huggingface_hub.errors.LocalEntryNotFoundError: An error happened while trying to locate the file on the Hub and we cannot find the requested files in the local cache. Please check your connection and try again or make sure your Internet connection is on.
command terminated with exit code 1
[2026-04-30T17:58:17Z] smoke mooncake failed
[2026-04-30T17:58:17Z] === FULL mooncake ===
[2026-04-30T17:58:18Z] bench s1-mooncake-r1 in=2048 out=512 cc=32 np=200 wu=20 (runner=pod/c1p1d-prefill-68759b55b5-dg6kg)
[2026-04-30T17:58:29Z] warmup s1-mooncake-r1 non-zero (continuing)
[2026-04-30T17:58:40Z] bench s1-mooncake-r1 FAILED exit=1

The above exception was the direct cause of the following exception:

Traceback (most recent call last):
  File "/usr/lib/python3.10/runpy.py", line 196, in _run_module_as_main
    return _run_code(code, main_globals, None,
  File "/usr/lib/python3.10/runpy.py", line 86, in _run_code
    exec(code, run_globals)
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 2352, in <module>
    run_benchmark(args)
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 1848, in run_benchmark
    input_requests = get_dataset(args, tokenizer, model_id)
  File "/usr/local/lib/python3.10/dist-packages/sglang/benchmark/datasets/__init__.py", line 42, in get_dataset
    return dataset.load(tokenizer=tokenizer, model_id=model_id)
  File "/usr/local/lib/python3.10/dist-packages/sglang/benchmark/datasets/random.py", line 45, in load
    return sample_random_requests(
  File "/usr/local/lib/python3.10/dist-packages/sglang/benchmark/datasets/random.py", line 89, in sample_random_requests
    dataset_path = download_and_cache_hf_file(
  File "/usr/local/lib/python3.10/dist-packages/sglang/benchmark/utils.py", line 98, in download_and_cache_hf_file
    return hf_hub_download(repo_id=repo_id, filename=filename, repo_type=repo_type)
  File "/usr/local/lib/python3.10/dist-packages/huggingface_hub/utils/_validators.py", line 88, in _inner_fn
    return fn(*args, **kwargs)
  File "/usr/local/lib/python3.10/dist-packages/huggingface_hub/file_download.py", line 997, in hf_hub_download
    return _hf_hub_download_to_cache_dir(
  File "/usr/local/lib/python3.10/dist-packages/huggingface_hub/file_download.py", line 1148, in _hf_hub_download_to_cache_dir
    _raise_on_head_call_error(head_call_error, force_download, local_files_only)
  File "/usr/local/lib/python3.10/dist-packages/huggingface_hub/file_download.py", line 1785, in _raise_on_head_call_error
    raise LocalEntryNotFoundError(
huggingface_hub.errors.LocalEntryNotFoundError: An error happened while trying to locate the file on the Hub and we cannot find the requested files in the local cache. Please check your connection and try again or make sure your Internet connection is on.
command terminated with exit code 1
[2026-04-30T17:58:40Z] bench s1-mooncake-r1 failed (continuing)
[2026-04-30T17:58:41Z] bench s1-mooncake-r2 in=2048 out=512 cc=32 np=200 wu=20 (runner=pod/c1p1d-prefill-68759b55b5-dg6kg)
[2026-04-30T17:58:53Z] warmup s1-mooncake-r2 non-zero (continuing)
[2026-04-30T17:59:04Z] bench s1-mooncake-r2 FAILED exit=1

The above exception was the direct cause of the following exception:

Traceback (most recent call last):
  File "/usr/lib/python3.10/runpy.py", line 196, in _run_module_as_main
    return _run_code(code, main_globals, None,
  File "/usr/lib/python3.10/runpy.py", line 86, in _run_code
    exec(code, run_globals)
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 2352, in <module>
    run_benchmark(args)
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 1848, in run_benchmark
    input_requests = get_dataset(args, tokenizer, model_id)
  File "/usr/local/lib/python3.10/dist-packages/sglang/benchmark/datasets/__init__.py", line 42, in get_dataset
    return dataset.load(tokenizer=tokenizer, model_id=model_id)
  File "/usr/local/lib/python3.10/dist-packages/sglang/benchmark/datasets/random.py", line 45, in load
    return sample_random_requests(
  File "/usr/local/lib/python3.10/dist-packages/sglang/benchmark/datasets/random.py", line 89, in sample_random_requests
    dataset_path = download_and_cache_hf_file(
  File "/usr/local/lib/python3.10/dist-packages/sglang/benchmark/utils.py", line 98, in download_and_cache_hf_file
    return hf_hub_download(repo_id=repo_id, filename=filename, repo_type=repo_type)
  File "/usr/local/lib/python3.10/dist-packages/huggingface_hub/utils/_validators.py", line 88, in _inner_fn
    return fn(*args, **kwargs)
  File "/usr/local/lib/python3.10/dist-packages/huggingface_hub/file_download.py", line 997, in hf_hub_download
    return _hf_hub_download_to_cache_dir(
  File "/usr/local/lib/python3.10/dist-packages/huggingface_hub/file_download.py", line 1148, in _hf_hub_download_to_cache_dir
    _raise_on_head_call_error(head_call_error, force_download, local_files_only)
  File "/usr/local/lib/python3.10/dist-packages/huggingface_hub/file_download.py", line 1785, in _raise_on_head_call_error
    raise LocalEntryNotFoundError(
huggingface_hub.errors.LocalEntryNotFoundError: An error happened while trying to locate the file on the Hub and we cannot find the requested files in the local cache. Please check your connection and try again or make sure your Internet connection is on.
command terminated with exit code 1
[2026-04-30T17:59:04Z] bench s1-mooncake-r2 failed (continuing)
[2026-04-30T17:59:05Z] bench s1-mooncake-r3 in=2048 out=512 cc=32 np=200 wu=20 (runner=pod/c1p1d-prefill-68759b55b5-dg6kg)
[2026-04-30T17:59:16Z] warmup s1-mooncake-r3 non-zero (continuing)
[2026-04-30T17:59:28Z] bench s1-mooncake-r3 FAILED exit=1

The above exception was the direct cause of the following exception:

Traceback (most recent call last):
  File "/usr/lib/python3.10/runpy.py", line 196, in _run_module_as_main
    return _run_code(code, main_globals, None,
  File "/usr/lib/python3.10/runpy.py", line 86, in _run_code
    exec(code, run_globals)
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 2352, in <module>
    run_benchmark(args)
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 1848, in run_benchmark
    input_requests = get_dataset(args, tokenizer, model_id)
  File "/usr/local/lib/python3.10/dist-packages/sglang/benchmark/datasets/__init__.py", line 42, in get_dataset
    return dataset.load(tokenizer=tokenizer, model_id=model_id)
  File "/usr/local/lib/python3.10/dist-packages/sglang/benchmark/datasets/random.py", line 45, in load
    return sample_random_requests(
  File "/usr/local/lib/python3.10/dist-packages/sglang/benchmark/datasets/random.py", line 89, in sample_random_requests
    dataset_path = download_and_cache_hf_file(
  File "/usr/local/lib/python3.10/dist-packages/sglang/benchmark/utils.py", line 98, in download_and_cache_hf_file
    return hf_hub_download(repo_id=repo_id, filename=filename, repo_type=repo_type)
  File "/usr/local/lib/python3.10/dist-packages/huggingface_hub/utils/_validators.py", line 88, in _inner_fn
    return fn(*args, **kwargs)
  File "/usr/local/lib/python3.10/dist-packages/huggingface_hub/file_download.py", line 997, in hf_hub_download
    return _hf_hub_download_to_cache_dir(
  File "/usr/local/lib/python3.10/dist-packages/huggingface_hub/file_download.py", line 1148, in _hf_hub_download_to_cache_dir
    _raise_on_head_call_error(head_call_error, force_download, local_files_only)
  File "/usr/local/lib/python3.10/dist-packages/huggingface_hub/file_download.py", line 1785, in _raise_on_head_call_error
    raise LocalEntryNotFoundError(
huggingface_hub.errors.LocalEntryNotFoundError: An error happened while trying to locate the file on the Hub and we cannot find the requested files in the local cache. Please check your connection and try again or make sure your Internet connection is on.
command terminated with exit code 1
[2026-04-30T17:59:28Z] bench s1-mooncake-r3 failed (continuing)
[2026-04-30T18:00:03Z] === UNATTENDED A/B START stamp=20260430T174252Z ===
[2026-04-30T18:00:04Z] SKIP_INITIAL_APPLY=1; current deployed backend='mooncake'
[2026-04-30T18:00:04Z] wait_ready (timeout 600s)
[2026-04-30T18:00:07Z]   [18:00:07Z] readiness p=1/1 d=1/1 lb=1/1
[2026-04-30T18:00:09Z] all Ready + router health ok after 5s
[2026-04-30T18:00:09Z] === SMOKE mooncake ===
[2026-04-30T18:00:10Z] bench smoke-mooncake in=2048 out=256 cc=8 np=15 wu=3 (runner=pod/c1p1d-prefill-68759b55b5-dg6kg)
[2026-04-30T18:01:15Z] bench smoke-mooncake OK raw=1400 bytes
[2026-04-30T18:01:16Z] === FULL mooncake ===
[2026-04-30T18:01:16Z] bench s1-mooncake-r1 in=2048 out=512 cc=32 np=200 wu=20 (runner=pod/c1p1d-prefill-68759b55b5-dg6kg)
[2026-04-30T18:02:40Z] bench s1-mooncake-r1 OK raw=1408 bytes
[2026-04-30T18:02:42Z] bench s1-mooncake-r2 in=2048 out=512 cc=32 np=200 wu=20 (runner=pod/c1p1d-prefill-68759b55b5-dg6kg)
[2026-04-30T18:04:03Z] bench s1-mooncake-r2 OK raw=1409 bytes
[2026-04-30T18:04:05Z] bench s1-mooncake-r3 in=2048 out=512 cc=32 np=200 wu=20 (runner=pod/c1p1d-prefill-68759b55b5-dg6kg)
[2026-04-30T18:05:24Z] bench s1-mooncake-r3 OK raw=1403 bytes
[2026-04-30T18:05:26Z] bench s2-mooncake-r1 in=8192 out=1024 cc=64 np=200 wu=20 (runner=pod/c1p1d-prefill-68759b55b5-dg6kg)
[2026-04-30T18:09:27Z] bench s2-mooncake-r1 OK raw=1410 bytes
[2026-04-30T18:09:28Z] bench s2-mooncake-r2 in=8192 out=1024 cc=64 np=200 wu=20 (runner=pod/c1p1d-prefill-68759b55b5-dg6kg)
[2026-04-30T18:13:19Z] bench s2-mooncake-r2 OK raw=1410 bytes
[2026-04-30T18:13:21Z] bench s2-mooncake-r3 in=8192 out=1024 cc=64 np=200 wu=20 (runner=pod/c1p1d-prefill-68759b55b5-dg6kg)
[2026-04-30T18:17:16Z] bench s2-mooncake-r3 OK raw=1411 bytes
[2026-04-30T18:17:18Z] bench s3-mooncake-r1 in=32768 out=1024 cc=16 np=100 wu=10 (runner=pod/c1p1d-prefill-68759b55b5-dg6kg)
[2026-04-30T18:19:41Z] bench s3-mooncake-r1 OK raw=1416 bytes
[2026-04-30T18:19:43Z] bench s3-mooncake-r2 in=32768 out=1024 cc=16 np=100 wu=10 (runner=pod/c1p1d-prefill-68759b55b5-dg6kg)
[2026-04-30T18:22:06Z] bench s3-mooncake-r2 OK raw=1417 bytes
[2026-04-30T18:22:08Z] bench s3-mooncake-r3 in=32768 out=1024 cc=16 np=100 wu=10 (runner=pod/c1p1d-prefill-68759b55b5-dg6kg)
[2026-04-30T18:24:31Z] bench s3-mooncake-r3 OK raw=1418 bytes
[2026-04-30T18:24:33Z] bench s4-mooncake-r1 in=4096 out=512 cc=128 np=200 wu=20 (runner=pod/c1p1d-prefill-68759b55b5-dg6kg)
[2026-04-30T18:26:21Z] bench s4-mooncake-r1 OK raw=1411 bytes
[2026-04-30T18:26:23Z] bench s4-mooncake-r2 in=4096 out=512 cc=128 np=200 wu=20 (runner=pod/c1p1d-prefill-68759b55b5-dg6kg)
[2026-04-30T18:28:08Z] bench s4-mooncake-r2 OK raw=1413 bytes
[2026-04-30T18:28:10Z] bench s4-mooncake-r3 in=4096 out=512 cc=128 np=200 wu=20 (runner=pod/c1p1d-prefill-68759b55b5-dg6kg)
[2026-04-30T18:29:56Z] bench s4-mooncake-r3 OK raw=1410 bytes
[2026-04-30T18:29:57Z] === SWITCH to nixl ===
[2026-04-30T18:29:57Z] teardown all deploys
deployment.apps "c1p1d-decode" deleted
deployment.apps "c1p1d-lb" deleted
deployment.apps "c1p1d-prefill" deleted
[2026-04-30T18:30:32Z] pods gone in 34s
[2026-04-30T18:30:32Z] apply variant backend=nixl
[2026-04-30T18:30:34Z] wait_ready (timeout 1500s)
[2026-04-30T18:30:37Z]   [18:30:37Z] readiness p=0/1 d=0/1 lb=0/1
[2026-04-30T18:31:09Z]   [18:31:09Z] readiness p=0/1 d=0/1 lb=1/1
[2026-04-30T18:31:42Z]   [18:31:42Z] readiness p=0/1 d=0/1 lb=1/1
[2026-04-30T18:32:14Z]   [18:32:14Z] readiness p=0/1 d=0/1 lb=1/1
[2026-04-30T18:32:47Z]   [18:32:47Z] readiness p=0/1 d=0/1 lb=1/1
[2026-04-30T18:33:19Z]   [18:33:19Z] readiness p=0/1 d=0/1 lb=1/1
[2026-04-30T18:33:52Z]   [18:33:52Z] readiness p=0/1 d=0/1 lb=1/1
[2026-04-30T18:34:24Z]   [18:34:24Z] readiness p=0/1 d=0/1 lb=1/1
[2026-04-30T18:34:57Z]   [18:34:57Z] readiness p=0/1 d=0/1 lb=1/1
[2026-04-30T18:35:29Z]   [18:35:29Z] readiness p=1/1 d=0/1 lb=1/1
[2026-04-30T18:36:02Z]   [18:36:02Z] readiness p=1/1 d=0/1 lb=1/1
[2026-04-30T18:36:35Z]   [18:36:35Z] readiness p=1/1 d=0/1 lb=1/1
[2026-04-30T18:37:07Z]   [18:37:07Z] readiness p=1/1 d=0/1 lb=1/1
[2026-04-30T18:37:40Z]   [18:37:40Z] readiness p=1/1 d=0/1 lb=1/1
[2026-04-30T18:38:12Z]   [18:38:12Z] readiness p=1/1 d=0/1 lb=1/1
[2026-04-30T18:38:45Z]   [18:38:45Z] readiness p=1/1 d=1/1 lb=1/1
[2026-04-30T18:38:47Z] all Ready + router health ok after 493s
[2026-04-30T18:38:47Z] === SMOKE nixl ===
[2026-04-30T18:38:48Z] bench smoke-nixl in=2048 out=256 cc=8 np=15 wu=3 (runner=pod/c1p1d-prefill-b979967d9-9bxhc)
[2026-04-30T18:39:03Z] warmup smoke-nixl non-zero (continuing)
[2026-04-30T18:39:14Z] bench smoke-nixl FAILED exit=1
benchmark_args=Namespace(backend='sglang', base_url='http://c1p1d-lb.yanxi-validation.svc:8000', host='0.0.0.0', port=None, ready_check_timeout_sec=60, dataset_name='random', dataset_path='', model='/models/moonshotai/Kimi-K2.5', served_model_name=None, tokenizer='/models/moonshotai/Kimi-K2.5', num_prompts=15, sharegpt_output_len=None, sharegpt_context_len=None, random_input_len=2048, random_output_len=256, random_range_ratio=0.0, image_count=1, image_resolution='1080p', random_image_count=False, image_format='jpeg', image_content='random', request_rate=inf, use_trace_timestamps=False, max_concurrency=8, output_file='/tmp/smoke-nixl.json', output_details=False, print_requests=False, disable_tqdm=True, disable_stream=False, return_logprob=False, top_logprobs_num=0, token_ids_logprob=None, logprob_start_len=-1, return_routed_experts=False, seed=1, disable_ignore_eos=False, extra_request_body=None, apply_chat_template=False, profile=False, plot_throughput=False, profile_activities=['CPU', 'GPU'], profile_start_step=None, profile_steps=None, profile_num_steps=None, profile_by_stage=False, profile_stages=None, profile_output_dir=None, profile_prefix=None, lora_name=None, lora_request_distribution='uniform', lora_zipf_alpha=1.5, prompt_suffix='', pd_separated=False, profile_prefill_url=None, profile_decode_url=None, flush_cache=False, warmup_requests=1, tokenize_prompt=False, gsp_num_groups=64, gsp_prompts_per_group=16, gsp_system_prompt_len=2048, gsp_question_len=128, gsp_output_len=256, gsp_range_ratio=1.0, gsp_fast_prepare=False, gsp_send_routing_key=False, gsp_num_turns=1, gsp_ordered=False, mooncake_slowdown_factor=1.0, mooncake_num_rounds=1, mooncake_workload='conversation', tag=None, header=None)
Waiting up to 60s for http://c1p1d-lb.yanxi-validation.svc:8000/v1/models to become ready...
Server ready in 0.0s.
Namespace(backend='sglang', base_url='http://c1p1d-lb.yanxi-validation.svc:8000', host='0.0.0.0', port=30000, ready_check_timeout_sec=60, dataset_name='random', dataset_path='', model='/models/moonshotai/Kimi-K2.5', served_model_name=None, tokenizer='/models/moonshotai/Kimi-K2.5', num_prompts=15, sharegpt_output_len=None, sharegpt_context_len=None, random_input_len=2048, random_output_len=256, random_range_ratio=0.0, image_count=1, image_resolution='1080p', random_image_count=False, image_format='jpeg', image_content='random', request_rate=inf, use_trace_timestamps=False, max_concurrency=8, output_file='/tmp/smoke-nixl.json', output_details=False, print_requests=False, disable_tqdm=True, disable_stream=False, return_logprob=False, top_logprobs_num=0, token_ids_logprob=None, logprob_start_len=-1, return_routed_experts=False, seed=1, disable_ignore_eos=False, extra_request_body=None, apply_chat_template=False, profile=False, plot_throughput=False, profile_activities=['CPU', 'GPU'], profile_start_step=None, profile_steps=None, profile_num_steps=None, profile_by_stage=False, profile_stages=None, profile_output_dir=None, profile_prefix=None, lora_name=None, lora_request_distribution='uniform', lora_zipf_alpha=1.5, prompt_suffix='', pd_separated=False, profile_prefill_url=None, profile_decode_url=None, flush_cache=False, warmup_requests=1, tokenize_prompt=False, gsp_num_groups=64, gsp_prompts_per_group=16, gsp_system_prompt_len=2048, gsp_question_len=128, gsp_output_len=256, gsp_range_ratio=1.0, gsp_fast_prepare=False, gsp_send_routing_key=False, gsp_num_turns=1, gsp_ordered=False, mooncake_slowdown_factor=1.0, mooncake_num_rounds=1, mooncake_workload='conversation', tag=None, header=None)

#Input tokens: 15851
#Output tokens: 2417
Starting warmup with 1 sequences...
Traceback (most recent call last):
  File "/usr/lib/python3.10/runpy.py", line 196, in _run_module_as_main
    return _run_code(code, main_globals, None,
  File "/usr/lib/python3.10/runpy.py", line 86, in _run_code
    exec(code, run_globals)
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 2352, in <module>
    run_benchmark(args)
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 1865, in run_benchmark
    return asyncio.run(
  File "/usr/lib/python3.10/asyncio/runners.py", line 44, in run
    return loop.run_until_complete(main)
  File "/usr/lib/python3.10/asyncio/base_events.py", line 649, in run_until_complete
    return future.result()
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 1275, in benchmark
    raise ValueError(
ValueError: Warmup failed - Please make sure benchmark arguments are correctly specified. Error: Service Unavailable: {"error":{"type":"Service Unavailable","code":"server_selection_failed","message":"No available servers: No prefill workers available. Please check if prefill servers are configured and healthy."}}
command terminated with exit code 1
[2026-04-30T18:39:14Z] smoke nixl failed
[2026-04-30T18:39:14Z] === FULL nixl ===
[2026-04-30T18:39:14Z] bench s1-nixl-r1 in=2048 out=512 cc=32 np=200 wu=20 (runner=pod/c1p1d-prefill-b979967d9-9bxhc)
[2026-04-30T18:39:25Z] warmup s1-nixl-r1 non-zero (continuing)
[2026-04-30T18:39:35Z] bench s1-nixl-r1 FAILED exit=1
benchmark_args=Namespace(backend='sglang', base_url='http://c1p1d-lb.yanxi-validation.svc:8000', host='0.0.0.0', port=None, ready_check_timeout_sec=60, dataset_name='random', dataset_path='', model='/models/moonshotai/Kimi-K2.5', served_model_name=None, tokenizer='/models/moonshotai/Kimi-K2.5', num_prompts=200, sharegpt_output_len=None, sharegpt_context_len=None, random_input_len=2048, random_output_len=512, random_range_ratio=0.0, image_count=1, image_resolution='1080p', random_image_count=False, image_format='jpeg', image_content='random', request_rate=inf, use_trace_timestamps=False, max_concurrency=32, output_file='/tmp/s1-nixl-r1.json', output_details=False, print_requests=False, disable_tqdm=True, disable_stream=False, return_logprob=False, top_logprobs_num=0, token_ids_logprob=None, logprob_start_len=-1, return_routed_experts=False, seed=1, disable_ignore_eos=False, extra_request_body=None, apply_chat_template=False, profile=False, plot_throughput=False, profile_activities=['CPU', 'GPU'], profile_start_step=None, profile_steps=None, profile_num_steps=None, profile_by_stage=False, profile_stages=None, profile_output_dir=None, profile_prefix=None, lora_name=None, lora_request_distribution='uniform', lora_zipf_alpha=1.5, prompt_suffix='', pd_separated=False, profile_prefill_url=None, profile_decode_url=None, flush_cache=False, warmup_requests=1, tokenize_prompt=False, gsp_num_groups=64, gsp_prompts_per_group=16, gsp_system_prompt_len=2048, gsp_question_len=128, gsp_output_len=256, gsp_range_ratio=1.0, gsp_fast_prepare=False, gsp_send_routing_key=False, gsp_num_turns=1, gsp_ordered=False, mooncake_slowdown_factor=1.0, mooncake_num_rounds=1, mooncake_workload='conversation', tag=None, header=None)
Waiting up to 60s for http://c1p1d-lb.yanxi-validation.svc:8000/v1/models to become ready...
Server ready in 0.0s.
Namespace(backend='sglang', base_url='http://c1p1d-lb.yanxi-validation.svc:8000', host='0.0.0.0', port=30000, ready_check_timeout_sec=60, dataset_name='random', dataset_path='', model='/models/moonshotai/Kimi-K2.5', served_model_name=None, tokenizer='/models/moonshotai/Kimi-K2.5', num_prompts=200, sharegpt_output_len=None, sharegpt_context_len=None, random_input_len=2048, random_output_len=512, random_range_ratio=0.0, image_count=1, image_resolution='1080p', random_image_count=False, image_format='jpeg', image_content='random', request_rate=inf, use_trace_timestamps=False, max_concurrency=32, output_file='/tmp/s1-nixl-r1.json', output_details=False, print_requests=False, disable_tqdm=True, disable_stream=False, return_logprob=False, top_logprobs_num=0, token_ids_logprob=None, logprob_start_len=-1, return_routed_experts=False, seed=1, disable_ignore_eos=False, extra_request_body=None, apply_chat_template=False, profile=False, plot_throughput=False, profile_activities=['CPU', 'GPU'], profile_start_step=None, profile_steps=None, profile_num_steps=None, profile_by_stage=False, profile_stages=None, profile_output_dir=None, profile_prefix=None, lora_name=None, lora_request_distribution='uniform', lora_zipf_alpha=1.5, prompt_suffix='', pd_separated=False, profile_prefill_url=None, profile_decode_url=None, flush_cache=False, warmup_requests=1, tokenize_prompt=False, gsp_num_groups=64, gsp_prompts_per_group=16, gsp_system_prompt_len=2048, gsp_question_len=128, gsp_output_len=256, gsp_range_ratio=1.0, gsp_fast_prepare=False, gsp_send_routing_key=False, gsp_num_turns=1, gsp_ordered=False, mooncake_slowdown_factor=1.0, mooncake_num_rounds=1, mooncake_workload='conversation', tag=None, header=None)

#Input tokens: 217693
#Output tokens: 49461
Starting warmup with 1 sequences...
Traceback (most recent call last):
  File "/usr/lib/python3.10/runpy.py", line 196, in _run_module_as_main
    return _run_code(code, main_globals, None,
  File "/usr/lib/python3.10/runpy.py", line 86, in _run_code
    exec(code, run_globals)
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 2352, in <module>
    run_benchmark(args)
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 1865, in run_benchmark
    return asyncio.run(
  File "/usr/lib/python3.10/asyncio/runners.py", line 44, in run
    return loop.run_until_complete(main)
  File "/usr/lib/python3.10/asyncio/base_events.py", line 649, in run_until_complete
    return future.result()
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 1275, in benchmark
    raise ValueError(
ValueError: Warmup failed - Please make sure benchmark arguments are correctly specified. Error: Service Unavailable: {"error":{"type":"Service Unavailable","code":"server_selection_failed","message":"No available servers: No prefill workers available. Please check if prefill servers are configured and healthy."}}
command terminated with exit code 1
[2026-04-30T18:39:35Z] bench s1-nixl-r1 failed (continuing)
[2026-04-30T18:39:36Z] bench s1-nixl-r2 in=2048 out=512 cc=32 np=200 wu=20 (runner=pod/c1p1d-prefill-b979967d9-9bxhc)
[2026-04-30T18:39:47Z] warmup s1-nixl-r2 non-zero (continuing)
[2026-04-30T18:39:57Z] bench s1-nixl-r2 FAILED exit=1
benchmark_args=Namespace(backend='sglang', base_url='http://c1p1d-lb.yanxi-validation.svc:8000', host='0.0.0.0', port=None, ready_check_timeout_sec=60, dataset_name='random', dataset_path='', model='/models/moonshotai/Kimi-K2.5', served_model_name=None, tokenizer='/models/moonshotai/Kimi-K2.5', num_prompts=200, sharegpt_output_len=None, sharegpt_context_len=None, random_input_len=2048, random_output_len=512, random_range_ratio=0.0, image_count=1, image_resolution='1080p', random_image_count=False, image_format='jpeg', image_content='random', request_rate=inf, use_trace_timestamps=False, max_concurrency=32, output_file='/tmp/s1-nixl-r2.json', output_details=False, print_requests=False, disable_tqdm=True, disable_stream=False, return_logprob=False, top_logprobs_num=0, token_ids_logprob=None, logprob_start_len=-1, return_routed_experts=False, seed=1, disable_ignore_eos=False, extra_request_body=None, apply_chat_template=False, profile=False, plot_throughput=False, profile_activities=['CPU', 'GPU'], profile_start_step=None, profile_steps=None, profile_num_steps=None, profile_by_stage=False, profile_stages=None, profile_output_dir=None, profile_prefix=None, lora_name=None, lora_request_distribution='uniform', lora_zipf_alpha=1.5, prompt_suffix='', pd_separated=False, profile_prefill_url=None, profile_decode_url=None, flush_cache=False, warmup_requests=1, tokenize_prompt=False, gsp_num_groups=64, gsp_prompts_per_group=16, gsp_system_prompt_len=2048, gsp_question_len=128, gsp_output_len=256, gsp_range_ratio=1.0, gsp_fast_prepare=False, gsp_send_routing_key=False, gsp_num_turns=1, gsp_ordered=False, mooncake_slowdown_factor=1.0, mooncake_num_rounds=1, mooncake_workload='conversation', tag=None, header=None)
Waiting up to 60s for http://c1p1d-lb.yanxi-validation.svc:8000/v1/models to become ready...
Server ready in 0.0s.
Namespace(backend='sglang', base_url='http://c1p1d-lb.yanxi-validation.svc:8000', host='0.0.0.0', port=30000, ready_check_timeout_sec=60, dataset_name='random', dataset_path='', model='/models/moonshotai/Kimi-K2.5', served_model_name=None, tokenizer='/models/moonshotai/Kimi-K2.5', num_prompts=200, sharegpt_output_len=None, sharegpt_context_len=None, random_input_len=2048, random_output_len=512, random_range_ratio=0.0, image_count=1, image_resolution='1080p', random_image_count=False, image_format='jpeg', image_content='random', request_rate=inf, use_trace_timestamps=False, max_concurrency=32, output_file='/tmp/s1-nixl-r2.json', output_details=False, print_requests=False, disable_tqdm=True, disable_stream=False, return_logprob=False, top_logprobs_num=0, token_ids_logprob=None, logprob_start_len=-1, return_routed_experts=False, seed=1, disable_ignore_eos=False, extra_request_body=None, apply_chat_template=False, profile=False, plot_throughput=False, profile_activities=['CPU', 'GPU'], profile_start_step=None, profile_steps=None, profile_num_steps=None, profile_by_stage=False, profile_stages=None, profile_output_dir=None, profile_prefix=None, lora_name=None, lora_request_distribution='uniform', lora_zipf_alpha=1.5, prompt_suffix='', pd_separated=False, profile_prefill_url=None, profile_decode_url=None, flush_cache=False, warmup_requests=1, tokenize_prompt=False, gsp_num_groups=64, gsp_prompts_per_group=16, gsp_system_prompt_len=2048, gsp_question_len=128, gsp_output_len=256, gsp_range_ratio=1.0, gsp_fast_prepare=False, gsp_send_routing_key=False, gsp_num_turns=1, gsp_ordered=False, mooncake_slowdown_factor=1.0, mooncake_num_rounds=1, mooncake_workload='conversation', tag=None, header=None)

#Input tokens: 217693
#Output tokens: 49461
Starting warmup with 1 sequences...
Traceback (most recent call last):
  File "/usr/lib/python3.10/runpy.py", line 196, in _run_module_as_main
    return _run_code(code, main_globals, None,
  File "/usr/lib/python3.10/runpy.py", line 86, in _run_code
    exec(code, run_globals)
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 2352, in <module>
    run_benchmark(args)
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 1865, in run_benchmark
    return asyncio.run(
  File "/usr/lib/python3.10/asyncio/runners.py", line 44, in run
    return loop.run_until_complete(main)
  File "/usr/lib/python3.10/asyncio/base_events.py", line 649, in run_until_complete
    return future.result()
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 1275, in benchmark
    raise ValueError(
ValueError: Warmup failed - Please make sure benchmark arguments are correctly specified. Error: Service Unavailable: {"error":{"type":"Service Unavailable","code":"server_selection_failed","message":"No available servers: No prefill workers available. Please check if prefill servers are configured and healthy."}}
command terminated with exit code 1
[2026-04-30T18:39:57Z] bench s1-nixl-r2 failed (continuing)
[2026-04-30T18:39:58Z] bench s1-nixl-r3 in=2048 out=512 cc=32 np=200 wu=20 (runner=pod/c1p1d-prefill-b979967d9-9bxhc)
[2026-04-30T18:40:09Z] warmup s1-nixl-r3 non-zero (continuing)
[2026-04-30T18:40:19Z] bench s1-nixl-r3 FAILED exit=1
benchmark_args=Namespace(backend='sglang', base_url='http://c1p1d-lb.yanxi-validation.svc:8000', host='0.0.0.0', port=None, ready_check_timeout_sec=60, dataset_name='random', dataset_path='', model='/models/moonshotai/Kimi-K2.5', served_model_name=None, tokenizer='/models/moonshotai/Kimi-K2.5', num_prompts=200, sharegpt_output_len=None, sharegpt_context_len=None, random_input_len=2048, random_output_len=512, random_range_ratio=0.0, image_count=1, image_resolution='1080p', random_image_count=False, image_format='jpeg', image_content='random', request_rate=inf, use_trace_timestamps=False, max_concurrency=32, output_file='/tmp/s1-nixl-r3.json', output_details=False, print_requests=False, disable_tqdm=True, disable_stream=False, return_logprob=False, top_logprobs_num=0, token_ids_logprob=None, logprob_start_len=-1, return_routed_experts=False, seed=1, disable_ignore_eos=False, extra_request_body=None, apply_chat_template=False, profile=False, plot_throughput=False, profile_activities=['CPU', 'GPU'], profile_start_step=None, profile_steps=None, profile_num_steps=None, profile_by_stage=False, profile_stages=None, profile_output_dir=None, profile_prefix=None, lora_name=None, lora_request_distribution='uniform', lora_zipf_alpha=1.5, prompt_suffix='', pd_separated=False, profile_prefill_url=None, profile_decode_url=None, flush_cache=False, warmup_requests=1, tokenize_prompt=False, gsp_num_groups=64, gsp_prompts_per_group=16, gsp_system_prompt_len=2048, gsp_question_len=128, gsp_output_len=256, gsp_range_ratio=1.0, gsp_fast_prepare=False, gsp_send_routing_key=False, gsp_num_turns=1, gsp_ordered=False, mooncake_slowdown_factor=1.0, mooncake_num_rounds=1, mooncake_workload='conversation', tag=None, header=None)
Waiting up to 60s for http://c1p1d-lb.yanxi-validation.svc:8000/v1/models to become ready...
Server ready in 0.0s.
Namespace(backend='sglang', base_url='http://c1p1d-lb.yanxi-validation.svc:8000', host='0.0.0.0', port=30000, ready_check_timeout_sec=60, dataset_name='random', dataset_path='', model='/models/moonshotai/Kimi-K2.5', served_model_name=None, tokenizer='/models/moonshotai/Kimi-K2.5', num_prompts=200, sharegpt_output_len=None, sharegpt_context_len=None, random_input_len=2048, random_output_len=512, random_range_ratio=0.0, image_count=1, image_resolution='1080p', random_image_count=False, image_format='jpeg', image_content='random', request_rate=inf, use_trace_timestamps=False, max_concurrency=32, output_file='/tmp/s1-nixl-r3.json', output_details=False, print_requests=False, disable_tqdm=True, disable_stream=False, return_logprob=False, top_logprobs_num=0, token_ids_logprob=None, logprob_start_len=-1, return_routed_experts=False, seed=1, disable_ignore_eos=False, extra_request_body=None, apply_chat_template=False, profile=False, plot_throughput=False, profile_activities=['CPU', 'GPU'], profile_start_step=None, profile_steps=None, profile_num_steps=None, profile_by_stage=False, profile_stages=None, profile_output_dir=None, profile_prefix=None, lora_name=None, lora_request_distribution='uniform', lora_zipf_alpha=1.5, prompt_suffix='', pd_separated=False, profile_prefill_url=None, profile_decode_url=None, flush_cache=False, warmup_requests=1, tokenize_prompt=False, gsp_num_groups=64, gsp_prompts_per_group=16, gsp_system_prompt_len=2048, gsp_question_len=128, gsp_output_len=256, gsp_range_ratio=1.0, gsp_fast_prepare=False, gsp_send_routing_key=False, gsp_num_turns=1, gsp_ordered=False, mooncake_slowdown_factor=1.0, mooncake_num_rounds=1, mooncake_workload='conversation', tag=None, header=None)

#Input tokens: 217693
#Output tokens: 49461
Starting warmup with 1 sequences...
Traceback (most recent call last):
  File "/usr/lib/python3.10/runpy.py", line 196, in _run_module_as_main
    return _run_code(code, main_globals, None,
  File "/usr/lib/python3.10/runpy.py", line 86, in _run_code
    exec(code, run_globals)
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 2352, in <module>
    run_benchmark(args)
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 1865, in run_benchmark
    return asyncio.run(
  File "/usr/lib/python3.10/asyncio/runners.py", line 44, in run
    return loop.run_until_complete(main)
  File "/usr/lib/python3.10/asyncio/base_events.py", line 649, in run_until_complete
    return future.result()
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 1275, in benchmark
    raise ValueError(
ValueError: Warmup failed - Please make sure benchmark arguments are correctly specified. Error: Service Unavailable: {"error":{"type":"Service Unavailable","code":"server_selection_failed","message":"No available servers: No prefill workers available. Please check if prefill servers are configured and healthy."}}
command terminated with exit code 1
[2026-04-30T18:40:19Z] bench s1-nixl-r3 failed (continuing)
[2026-04-30T18:40:20Z] bench s2-nixl-r1 in=8192 out=1024 cc=64 np=200 wu=20 (runner=pod/c1p1d-prefill-b979967d9-9bxhc)
[2026-04-30T18:40:31Z] warmup s2-nixl-r1 non-zero (continuing)
[2026-04-30T18:40:42Z] bench s2-nixl-r1 FAILED exit=1
benchmark_args=Namespace(backend='sglang', base_url='http://c1p1d-lb.yanxi-validation.svc:8000', host='0.0.0.0', port=None, ready_check_timeout_sec=60, dataset_name='random', dataset_path='', model='/models/moonshotai/Kimi-K2.5', served_model_name=None, tokenizer='/models/moonshotai/Kimi-K2.5', num_prompts=200, sharegpt_output_len=None, sharegpt_context_len=None, random_input_len=8192, random_output_len=1024, random_range_ratio=0.0, image_count=1, image_resolution='1080p', random_image_count=False, image_format='jpeg', image_content='random', request_rate=inf, use_trace_timestamps=False, max_concurrency=64, output_file='/tmp/s2-nixl-r1.json', output_details=False, print_requests=False, disable_tqdm=True, disable_stream=False, return_logprob=False, top_logprobs_num=0, token_ids_logprob=None, logprob_start_len=-1, return_routed_experts=False, seed=1, disable_ignore_eos=False, extra_request_body=None, apply_chat_template=False, profile=False, plot_throughput=False, profile_activities=['CPU', 'GPU'], profile_start_step=None, profile_steps=None, profile_num_steps=None, profile_by_stage=False, profile_stages=None, profile_output_dir=None, profile_prefix=None, lora_name=None, lora_request_distribution='uniform', lora_zipf_alpha=1.5, prompt_suffix='', pd_separated=False, profile_prefill_url=None, profile_decode_url=None, flush_cache=False, warmup_requests=1, tokenize_prompt=False, gsp_num_groups=64, gsp_prompts_per_group=16, gsp_system_prompt_len=2048, gsp_question_len=128, gsp_output_len=256, gsp_range_ratio=1.0, gsp_fast_prepare=False, gsp_send_routing_key=False, gsp_num_turns=1, gsp_ordered=False, mooncake_slowdown_factor=1.0, mooncake_num_rounds=1, mooncake_workload='conversation', tag=None, header=None)
Waiting up to 60s for http://c1p1d-lb.yanxi-validation.svc:8000/v1/models to become ready...
Server ready in 0.0s.
Namespace(backend='sglang', base_url='http://c1p1d-lb.yanxi-validation.svc:8000', host='0.0.0.0', port=30000, ready_check_timeout_sec=60, dataset_name='random', dataset_path='', model='/models/moonshotai/Kimi-K2.5', served_model_name=None, tokenizer='/models/moonshotai/Kimi-K2.5', num_prompts=200, sharegpt_output_len=None, sharegpt_context_len=None, random_input_len=8192, random_output_len=1024, random_range_ratio=0.0, image_count=1, image_resolution='1080p', random_image_count=False, image_format='jpeg', image_content='random', request_rate=inf, use_trace_timestamps=False, max_concurrency=64, output_file='/tmp/s2-nixl-r1.json', output_details=False, print_requests=False, disable_tqdm=True, disable_stream=False, return_logprob=False, top_logprobs_num=0, token_ids_logprob=None, logprob_start_len=-1, return_routed_experts=False, seed=1, disable_ignore_eos=False, extra_request_body=None, apply_chat_template=False, profile=False, plot_throughput=False, profile_activities=['CPU', 'GPU'], profile_start_step=None, profile_steps=None, profile_num_steps=None, profile_by_stage=False, profile_stages=None, profile_output_dir=None, profile_prefix=None, lora_name=None, lora_request_distribution='uniform', lora_zipf_alpha=1.5, prompt_suffix='', pd_separated=False, profile_prefill_url=None, profile_decode_url=None, flush_cache=False, warmup_requests=1, tokenize_prompt=False, gsp_num_groups=64, gsp_prompts_per_group=16, gsp_system_prompt_len=2048, gsp_question_len=128, gsp_output_len=256, gsp_range_ratio=1.0, gsp_fast_prepare=False, gsp_send_routing_key=False, gsp_num_turns=1, gsp_ordered=False, mooncake_slowdown_factor=1.0, mooncake_num_rounds=1, mooncake_workload='conversation', tag=None, header=None)

#Input tokens: 817757
#Output tokens: 99125
Starting warmup with 1 sequences...
Traceback (most recent call last):
  File "/usr/lib/python3.10/runpy.py", line 196, in _run_module_as_main
    return _run_code(code, main_globals, None,
  File "/usr/lib/python3.10/runpy.py", line 86, in _run_code
    exec(code, run_globals)
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 2352, in <module>
    run_benchmark(args)
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 1865, in run_benchmark
    return asyncio.run(
  File "/usr/lib/python3.10/asyncio/runners.py", line 44, in run
    return loop.run_until_complete(main)
  File "/usr/lib/python3.10/asyncio/base_events.py", line 649, in run_until_complete
    return future.result()
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 1275, in benchmark
    raise ValueError(
ValueError: Warmup failed - Please make sure benchmark arguments are correctly specified. Error: Service Unavailable: {"error":{"type":"Service Unavailable","code":"server_selection_failed","message":"No available servers: No prefill workers available. Please check if prefill servers are configured and healthy."}}
command terminated with exit code 1
[2026-04-30T18:40:42Z] bench s2-nixl-r1 failed (continuing)
[2026-04-30T18:40:42Z] bench s2-nixl-r2 in=8192 out=1024 cc=64 np=200 wu=20 (runner=pod/c1p1d-prefill-b979967d9-9bxhc)
[2026-04-30T18:40:53Z] warmup s2-nixl-r2 non-zero (continuing)
[2026-04-30T18:41:04Z] bench s2-nixl-r2 FAILED exit=1
benchmark_args=Namespace(backend='sglang', base_url='http://c1p1d-lb.yanxi-validation.svc:8000', host='0.0.0.0', port=None, ready_check_timeout_sec=60, dataset_name='random', dataset_path='', model='/models/moonshotai/Kimi-K2.5', served_model_name=None, tokenizer='/models/moonshotai/Kimi-K2.5', num_prompts=200, sharegpt_output_len=None, sharegpt_context_len=None, random_input_len=8192, random_output_len=1024, random_range_ratio=0.0, image_count=1, image_resolution='1080p', random_image_count=False, image_format='jpeg', image_content='random', request_rate=inf, use_trace_timestamps=False, max_concurrency=64, output_file='/tmp/s2-nixl-r2.json', output_details=False, print_requests=False, disable_tqdm=True, disable_stream=False, return_logprob=False, top_logprobs_num=0, token_ids_logprob=None, logprob_start_len=-1, return_routed_experts=False, seed=1, disable_ignore_eos=False, extra_request_body=None, apply_chat_template=False, profile=False, plot_throughput=False, profile_activities=['CPU', 'GPU'], profile_start_step=None, profile_steps=None, profile_num_steps=None, profile_by_stage=False, profile_stages=None, profile_output_dir=None, profile_prefix=None, lora_name=None, lora_request_distribution='uniform', lora_zipf_alpha=1.5, prompt_suffix='', pd_separated=False, profile_prefill_url=None, profile_decode_url=None, flush_cache=False, warmup_requests=1, tokenize_prompt=False, gsp_num_groups=64, gsp_prompts_per_group=16, gsp_system_prompt_len=2048, gsp_question_len=128, gsp_output_len=256, gsp_range_ratio=1.0, gsp_fast_prepare=False, gsp_send_routing_key=False, gsp_num_turns=1, gsp_ordered=False, mooncake_slowdown_factor=1.0, mooncake_num_rounds=1, mooncake_workload='conversation', tag=None, header=None)
Waiting up to 60s for http://c1p1d-lb.yanxi-validation.svc:8000/v1/models to become ready...
Server ready in 0.0s.
Namespace(backend='sglang', base_url='http://c1p1d-lb.yanxi-validation.svc:8000', host='0.0.0.0', port=30000, ready_check_timeout_sec=60, dataset_name='random', dataset_path='', model='/models/moonshotai/Kimi-K2.5', served_model_name=None, tokenizer='/models/moonshotai/Kimi-K2.5', num_prompts=200, sharegpt_output_len=None, sharegpt_context_len=None, random_input_len=8192, random_output_len=1024, random_range_ratio=0.0, image_count=1, image_resolution='1080p', random_image_count=False, image_format='jpeg', image_content='random', request_rate=inf, use_trace_timestamps=False, max_concurrency=64, output_file='/tmp/s2-nixl-r2.json', output_details=False, print_requests=False, disable_tqdm=True, disable_stream=False, return_logprob=False, top_logprobs_num=0, token_ids_logprob=None, logprob_start_len=-1, return_routed_experts=False, seed=1, disable_ignore_eos=False, extra_request_body=None, apply_chat_template=False, profile=False, plot_throughput=False, profile_activities=['CPU', 'GPU'], profile_start_step=None, profile_steps=None, profile_num_steps=None, profile_by_stage=False, profile_stages=None, profile_output_dir=None, profile_prefix=None, lora_name=None, lora_request_distribution='uniform', lora_zipf_alpha=1.5, prompt_suffix='', pd_separated=False, profile_prefill_url=None, profile_decode_url=None, flush_cache=False, warmup_requests=1, tokenize_prompt=False, gsp_num_groups=64, gsp_prompts_per_group=16, gsp_system_prompt_len=2048, gsp_question_len=128, gsp_output_len=256, gsp_range_ratio=1.0, gsp_fast_prepare=False, gsp_send_routing_key=False, gsp_num_turns=1, gsp_ordered=False, mooncake_slowdown_factor=1.0, mooncake_num_rounds=1, mooncake_workload='conversation', tag=None, header=None)

#Input tokens: 817757
#Output tokens: 99125
Starting warmup with 1 sequences...
Traceback (most recent call last):
  File "/usr/lib/python3.10/runpy.py", line 196, in _run_module_as_main
    return _run_code(code, main_globals, None,
  File "/usr/lib/python3.10/runpy.py", line 86, in _run_code
    exec(code, run_globals)
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 2352, in <module>
    run_benchmark(args)
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 1865, in run_benchmark
    return asyncio.run(
  File "/usr/lib/python3.10/asyncio/runners.py", line 44, in run
    return loop.run_until_complete(main)
  File "/usr/lib/python3.10/asyncio/base_events.py", line 649, in run_until_complete
    return future.result()
  File "/usr/local/lib/python3.10/dist-packages/sglang/bench_serving.py", line 1275, in benchmark
    raise ValueError(
ValueError: Warmup failed - Please make sure benchmark arguments are correctly specified. Error: Service Unavailable: {"error":{"type":"Service Unavailable","code":"server_selection_failed","message":"No available servers: No prefill workers available. Please check if prefill servers are configured and healthy."}}
command terminated with exit code 1
[2026-04-30T18:41:04Z] bench s2-nixl-r2 failed (continuing)
[2026-04-30T18:41:04Z] bench s2-nixl-r3 in=8192 out=1024 cc=64 np=200 wu=20 (runner=pod/c1p1d-prefill-b979967d9-9bxhc)
[2026-04-30T18:41:23Z] warmup s2-nixl-r3 non-zero (continuing)
[2026-04-30T18:41:24Z] bench s2-nixl-r3 FAILED exit=1
error: Internal error occurred: Internal error occurred: error executing command in container: failed to exec in container: failed to start exec "27d7d1ad39bfc432c6a09845b1eabbcca3507011a35a27487d5f63440fb855ca": OCI runtime exec failed: exec failed: unable to start container process: error executing setns process: exit status 1
[2026-04-30T18:41:24Z] bench s2-nixl-r3 failed (continuing)
[2026-04-30T18:41:25Z] bench s3-nixl-r1 in=32768 out=1024 cc=16 np=100 wu=10 (runner=pod/c1p1d-prefill-b979967d9-9bxhc)
[2026-04-30T18:41:26Z] warmup s3-nixl-r1 non-zero (continuing)
[2026-04-30T18:41:27Z] bench s3-nixl-r1 FAILED exit=1
error: Internal error occurred: Internal error occurred: error executing command in container: failed to exec in container: failed to start exec "5f2b0810f858efe2d7b55d612d715ed74bb4425a9704426d03ec849fe64dafb4": OCI runtime exec failed: exec failed: unable to start container process: error executing setns process: exit status 1
[2026-04-30T18:41:27Z] bench s3-nixl-r1 failed (continuing)
[2026-04-30T18:41:27Z] bench s3-nixl-r2 in=32768 out=1024 cc=16 np=100 wu=10 (runner=pod/c1p1d-prefill-b979967d9-9bxhc)
[2026-04-30T18:41:28Z] warmup s3-nixl-r2 non-zero (continuing)
[2026-04-30T18:41:29Z] bench s3-nixl-r2 FAILED exit=1
error: Internal error occurred: Internal error occurred: error executing command in container: failed to exec in container: failed to start exec "7e778e848b32aedef25d085ba1e8135f08c51da30e27ee140abb345ea2c3a0c0": OCI runtime exec failed: exec failed: unable to start container process: error executing setns process: exit status 1
[2026-04-30T18:41:29Z] bench s3-nixl-r2 failed (continuing)
[2026-04-30T18:41:30Z] bench s3-nixl-r3 in=32768 out=1024 cc=16 np=100 wu=10 (runner=pod/c1p1d-prefill-b979967d9-9bxhc)
[2026-04-30T18:41:31Z] warmup s3-nixl-r3 non-zero (continuing)
[2026-04-30T18:41:32Z] bench s3-nixl-r3 FAILED exit=1
error: Internal error occurred: Internal error occurred: error executing command in container: failed to exec in container: failed to start exec "0b32b4a6fdcc2571f23642b41cf4f6b4445ed26416731222c8d1afb84cb5c1af": OCI runtime exec failed: exec failed: unable to start container process: error executing setns process: exit status 1
[2026-04-30T18:41:32Z] bench s3-nixl-r3 failed (continuing)
[2026-04-30T18:41:33Z] bench s4-nixl-r1 in=4096 out=512 cc=128 np=200 wu=20 (runner=pod/c1p1d-prefill-b979967d9-9bxhc)
[2026-04-30T18:41:34Z] warmup s4-nixl-r1 non-zero (continuing)
[2026-04-30T18:41:35Z] bench s4-nixl-r1 FAILED exit=1
error: Internal error occurred: Internal error occurred: error executing command in container: failed to exec in container: failed to start exec "cb72ba666637ae7e9660c68f3fede0a338ae38107df98553e858c68d00f8e5e0": OCI runtime exec failed: exec failed: unable to start container process: error executing setns process: exit status 1
[2026-04-30T18:41:35Z] bench s4-nixl-r1 failed (continuing)
[2026-04-30T18:41:36Z] bench s4-nixl-r2 in=4096 out=512 cc=128 np=200 wu=20 (runner=pod/c1p1d-prefill-b979967d9-9bxhc)
[2026-04-30T18:41:36Z] warmup s4-nixl-r2 non-zero (continuing)
[2026-04-30T18:41:37Z] bench s4-nixl-r2 FAILED exit=1
error: Internal error occurred: Internal error occurred: error executing command in container: failed to exec in container: failed to start exec "d4f52674a02d8c847138de75b7874ced66bdca21466f50bd749dd512119acac4": OCI runtime exec failed: exec failed: unable to start container process: error executing setns process: exit status 1
[2026-04-30T18:41:37Z] bench s4-nixl-r2 failed (continuing)
[2026-04-30T18:41:38Z] bench s4-nixl-r3 in=4096 out=512 cc=128 np=200 wu=20 (runner=pod/c1p1d-prefill-b979967d9-9bxhc)
[2026-04-30T18:41:39Z] warmup s4-nixl-r3 non-zero (continuing)
[2026-04-30T18:41:40Z] bench s4-nixl-r3 FAILED exit=1
error: Internal error occurred: Internal error occurred: error executing command in container: failed to exec in container: failed to start exec "6cec23907d2bf516125ed5b92af28833eabdab0143946b687d88bafb8f21b58c": OCI runtime exec failed: exec failed: unable to start container process: error executing setns process: exit status 1
[2026-04-30T18:41:40Z] bench s4-nixl-r3 failed (continuing)
[2026-04-30T18:41:40Z] === FINAL teardown ===
[2026-04-30T18:41:40Z] teardown all deploys
deployment.apps "c1p1d-decode" deleted
deployment.apps "c1p1d-lb" deleted
deployment.apps "c1p1d-prefill" deleted
[2026-04-30T18:46:24Z] pods gone in 283s
[2026-04-30T18:46:25Z] === A/B COMPLETE ===

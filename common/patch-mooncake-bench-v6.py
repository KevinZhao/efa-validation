#!/usr/bin/env python3
"""
Mooncake v6 patch: guard freeMemoryPool's cudaPointerGetAttributes call with
FLAGS_use_vram so that --use_vram=false runs succeed on pods without GPU
device injection.

Applied during docker build of yanxi/mooncake-nixl:v6 to
    /opt/mooncake/mooncake-transfer-engine/example/transfer_engine_bench.cpp

Upstream context (Mooncake commit 634b7097):
  static void freeMemoryPool(void *addr, size_t size) {
      ...
      } else {
  #ifndef USE_UBSHMEM
          // check pointer on GPU
          cudaPointerAttributes attributes;
          checkCudaError(cudaPointerGetAttributes(&attributes, addr),
                         "Failed to get pointer attributes");
          ...

The cudaPointerGetAttributes call fires unconditionally whenever the image has
USE_CUDA and protocol is not nvlink/hip/ubshmem, even with --use_vram=false.
When /dev/nvidia* is not injected (container runtime driver-whitelist
mismatch), this aborts via checkCudaError -> std::exit(1) after a
malloc-corrupted log. In Lane K 2026-04-26 we hit exactly this.

The fix inserts a `if (!FLAGS_use_vram) { numa_free(addr, size); return; }`
short-circuit immediately before the cudaPointer* call. CPU-only benchmarks
(--use_vram=false) become usable.
"""
from __future__ import annotations
import pathlib
import sys

PATH = pathlib.Path(
    "/opt/mooncake/mooncake-transfer-engine/example/transfer_engine_bench.cpp"
)

OLD = (
    "    } else {\n"
    "#ifndef USE_UBSHMEM\n"
    "        // check pointer on GPU\n"
    "        cudaPointerAttributes attributes;\n"
    "        checkCudaError(cudaPointerGetAttributes(&attributes, addr),\n"
    '                       "Failed to get pointer attributes");\n'
)

NEW = (
    "    } else {\n"
    "#ifndef USE_UBSHMEM\n"
    "        // v6 patch: skip CUDA pointer check when use_vram=false (CPU-only DRAM bench)\n"
    "        if (!FLAGS_use_vram) {\n"
    "            numa_free(addr, size);\n"
    "            return;\n"
    "        }\n"
    "        // check pointer on GPU\n"
    "        cudaPointerAttributes attributes;\n"
    "        checkCudaError(cudaPointerGetAttributes(&attributes, addr),\n"
    '                       "Failed to get pointer attributes");\n'
)

SENTINEL = "// v6 patch: skip cuda* when --use_vram=false\n"


def main() -> int:
    if not PATH.exists():
        print(f"FATAL: {PATH} missing", file=sys.stderr)
        return 1

    src = PATH.read_text()

    if SENTINEL in src:
        print("v6 patch already applied (sentinel present), nothing to do")
        return 0

    if OLD not in src:
        print(
            "FATAL: v6 patch target block not found — Mooncake source moved?",
            file=sys.stderr,
        )
        print("---expected block---\n" + OLD, file=sys.stderr)
        return 1

    src = src.replace(OLD, NEW, 1)
    src = SENTINEL + src

    PATH.write_text(src)
    print(f"v6 patch applied: {PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/bin/bash
# Create libcuda.so.1 symlink to the CUDA stub so that nixlbench loads.
# The stub is a no-op library — works fine since we use --initiator_seg_type=DRAM.
# On actual GPU runs, container runtime injects a real one that hides the stub.
for POD in lane-k-target lane-k-initiator; do
  kubectl exec -n yanxi-validation $POD -- bash -c '
    if [ ! -f /usr/lib/x86_64-linux-gnu/libcuda.so.1 ]; then
      if [ -f /usr/local/cuda/lib64/stubs/libcuda.so ]; then
        ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/lib/x86_64-linux-gnu/libcuda.so.1
        echo "Created stub symlink on $(hostname)"
      else
        echo "ERROR: stub not found"
        find / -name libcuda.so 2>/dev/null | head
      fi
    fi
    ls -la /usr/lib/x86_64-linux-gnu/libcuda.so* 2>&1 | head
    echo "=== Test nixlbench loads ==="
    /opt/nixl/bin/nixlbench --help 2>&1 | head -3
  '
done

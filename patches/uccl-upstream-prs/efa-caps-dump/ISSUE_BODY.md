# [EP] AWS EFA device capability dump on p5en (informational)

This issue is **informational only** — no code change requested.

We collected `efadv_query_device()` output on AWS p5en (8× H200 + 16× 200 Gb/s EFA) to help UCCL maintainers understand what EFA actually exposes versus vanilla InfiniBand capabilities. This should unblock discussion about a few optimization knobs that are currently assumed-disabled for EFA.

## Environment

- **Instance**: p5en.48xlarge (8× H200 SXM5, 16× EFA v3 adapters @ 200 Gb/s each)
- **Region/AZ**: us-east-2 (Ohio)
- **amzn-drivers**: `<fill in>` (`modinfo efa | grep ^version`)
- **libefa / rdma-core**: `<fill in>` (`dpkg -l | grep libefa` or `rpm -q libefa`)
- **Kernel**: `<fill in>` (`uname -r`)
- **UCCL commit**: `4bd57b1e` (upstream main 2026-04-28)

## Capture Method

Added a minimal env-gated dump in `ep/src/rdma.cpp` after `ibv_open_device`:

```cpp
if (getenv("UCCL_EP_EFA_CAPS_DUMP")) {
  struct efadv_device_attr efa_attr = {};
  if (efadv_query_device(S.context, &efa_attr, sizeof(efa_attr)) == 0) {
    fprintf(stderr, "[EFA caps] nic=%s gpu=%d max_sq_wr=%u max_rq_wr=%u "
                    "max_sq_sge=%u max_rq_sge=%u inline_buf_size=%u "
                    "max_rdma_size=%u device_caps=0x%x\n", ...);
  }
}
```

Triggered via:
```
UCCL_EP_EFA_CAPS_DUMP=1 torchrun --nnodes=1 --nproc_per_node=8 \
  bench/test_low_latency.py --num-tokens=128 --hidden=7168 \
  --num-topk=8 --num-experts=288
```

## Raw output

<!-- paste actual dump here after running -->

```
<fill in>
```

## Decoded `device_caps` bitmask

<!-- match bits against efadv.h enum values (EFADV_DEVICE_ATTR_CAPS_*) -->

| Bit | Name | p5en value |
|---|---|---|
| `EFADV_DEVICE_ATTR_CAPS_RDMA_READ` | | `<fill>` |
| `EFADV_DEVICE_ATTR_CAPS_RNR_RETRY` | | `<fill>` |
| `EFADV_DEVICE_ATTR_CAPS_CQ_WITH_SGID` | | `<fill>` |
| `EFADV_DEVICE_ATTR_CAPS_UNSOLICITED_WRITE_RECV` | | `<fill>` |
| `EFADV_DEVICE_ATTR_CAPS_DATA_POLLING_128` | | `<fill>` |
| `EFADV_DEVICE_ATTR_CAPS_RDMA_WRITE` | | `<fill>` |
| `EFADV_DEVICE_ATTR_CAPS_MEM_IN_DIRECT_WRITE` | | `<fill>` |

## Happy to extend

If useful, we can:
1. Also dump `efadv_get_max_sq_depth()` (exposes `EFADV_SQ_DEPTH_ATTR_INLINE_WRITE` flag + actual `max_inline_data`)
2. Run the same dump on **p6-b200** (B200 + 8× 400 Gb/s EFA) and **p6-b300** (B300 + 17× 400 Gb/s EFA) as those instances become available to us
3. Turn this into a PR to add a `UCCL_EP_EFA_CAPS_DUMP` env knob upstream (24 lines of `#ifdef EFA` guarded code, no behavior change when env is unset)

Just let us know which would be most useful for the maintainer team.

## Context

Current `ep/src/rdma.cpp:907` hardcodes `qp_attr_ex.cap.max_inline_data = 0`. The `inline_buf_size` field in the dump will confirm whether this is a hardware limit or a software default — which directly affects ACK-path latency optimization opportunities on EFA.

Related public discussions on `ibv_qp_ex` inline behavior for EFA: `<add any relevant links if known>`.

---

cc @MaoZiming @YangZhou1997 — follow-up to our PR #904 conversation.

# p5en/p6 EFA Device Capability Dumps

**Purpose**: Archive of `efadv_query_device()` output across AWS EFA-enabled GPU instances. Used by Phase 0 instrumentation to unblock Sprint A/B/D optimization decisions (see `FINAL_EXECUTION_CHECKLIST.md` §1 in the sibling repo `../../../../uccl-ep-optimization/docs/` — moved out of efa-validation on 2026-05-03).

## File naming

```
<instance>-<YYYY-MM-DD>.txt
```

## How to regenerate

On a GPU node with UCCL fork `instrumentation/efa-caps-dump` branch built:

```bash
UCCL_EP_EFA_CAPS_DUMP=1 \
  torchrun --nnodes=1 --nproc_per_node=8 \
  bench/test_low_latency.py --num-tokens=128 --hidden=7168 \
  --num-topk=8 --num-experts=288 2>&1 | grep '\[EFA caps\]' \
  | tee <instance>-$(date +%Y-%m-%d).txt
```

## Expected dump format (one line per NIC per GPU)

```
[EFA caps] nic=rdmap160s0 gpu=0 max_sq_wr=N max_rq_wr=N max_sq_sge=N max_rq_sge=N inline_buf_size=N max_rdma_size=N device_caps=0xHH
```

## `device_caps` bit reference

From `providers/efa/efadv.h` (rdma-core), bits known at 2026-04:

| Bit | Constant | Meaning |
|---|---|---|
| 0 | `EFADV_DEVICE_ATTR_CAPS_RDMA_READ` | Supports RDMA read WRs |
| 1 | `EFADV_DEVICE_ATTR_CAPS_RNR_RETRY` | Supports RNR retry |
| 2 | `EFADV_DEVICE_ATTR_CAPS_CQ_WITH_SGID` | CQE includes source GID |
| 3 | `EFADV_DEVICE_ATTR_CAPS_UNSOLICITED_WRITE_RECV` | QP flag-opt-in |
| 4 | `EFADV_DEVICE_ATTR_CAPS_DATA_POLLING_128` | 128-byte CQE polling |
| 5 | `EFADV_DEVICE_ATTR_CAPS_RDMA_WRITE` | Supports RDMA write WRs (EFAv3+) |
| 6 | `EFADV_DEVICE_ATTR_CAPS_MEM_IN_DIRECT_WRITE` | Direct host→device write |

Bits 7+ reserved / future. Verify current constant values against the installed `efadv.h` before decoding.

## Instances to cover

- [ ] **p5en.48xlarge** (8× H200 + 16× 200 Gb/s EFAv3) — **priority 1**, used by current Stage 5
- [ ] **p6-b200.48xlarge** (8× B200 + 8× 400 Gb/s EFAv4) — pending SPS stability
- [ ] **p6-b300.24xlarge** (8× B300 + 17× 400 Gb/s EFAv4 with 1 primary ENA) — pending

## Downstream decisions gated on this data

| Caps bit / field | Decides |
|---|---|
| `inline_buf_size` > 0 | L2 lever: `max_inline_data` can move off 0 → ACK path -0.5-1 µs |
| `CAPS_DATA_POLLING_128` | L6 lever feasibility (currently Sprint D demoted) |
| `CAPS_MEM_IN_DIRECT_WRITE` / CQ_WITH_EXT_MEM equivalent | Sprint D L1 GPU-BAR CQ feasibility |
| `CAPS_UNSOLICITED_WRITE_RECV` | Already used via `EFADV_QP_FLAGS_UNSOLICITED_WRITE_RECV` at `rdma.cpp:914` — sanity check |
| `max_rdma_size` | Upper bound on our RDMA write WR payload — confirms `SRD_PROTOCOL_PART2` "1 GB" claim |

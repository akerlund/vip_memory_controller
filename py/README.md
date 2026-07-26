# vip_mc Python Port

This directory is the pyUVM/cocotb port of the SystemVerilog `vip_mc` VIP.

Current status: the simulator-independent controller core and the first AXI4
end-to-end slice are ported:

- owned AXI4 constants and width config types
- shared MC enums, port descriptors, address regions, and status snapshot
- AXI4/CHI/runtime controller config validation
- canonical command entries
- wakeable activity FIFO
- QoS command queue with same-stream ordering, aging promotion, coalescing, and
  inflight tag retirement
- refresh burst bookkeeping
- backend pyUVM lifecycle, front-end ingress FIFOs, DRAM request publishing,
  DRAM response subscription, completion dispatch, and reset flushing
- backend logic for FR-FCFS selection, RD/WR grouping counters, ECC response
  classification, latency/occupancy counters, and DRAM request mapping
- AXI4 front-end driver for `INCR`, `FIXED`, and `WRAP` bursts,
  narrow/unaligned byte mapping, DECERR classification, exclusive reservations,
  B/R response queues, and bus-edge response pacing
- compatibility wrapper for the shared `vip_axi4_agent` bus API
- top-level `vip_mc` component that builds one or more AXI4 front-ends over one
  shared backend and `vip_dram`

The CHI front-end and the broad AXI4 regression are still pending. The immediate
regression for this slice is:

```bash
PYTHONPATH=py:submodules/vip_axi4_agent/py:submodules/vip_dram/py:submodules/vip_memory/py:submodules/vip_gauss/py \
  python3 -m pytest testbench/py/tc/test_mc_core.py
./testbench/py/run_fusesoc.sh --target sim
```

# vip_mc pyUVM Port Testbench

This is the Python testbench for the `vip_mc` pyUVM/cocotb port. It runs the
pure controller-core unit checks plus a Verilator shell over the Python
`vip_mc` top, backend, AXI4 and CHI front-ends, the real Python `vip_axi4_agent`
and `vip_chi_agent` stimulus agents, and the `vip_dram` device model. The AXI4
scoreboard subscribes to the backend grant-order tap and matches agent-monitor
B/R completions to issued entries. The shared testcase catalog is
[../TEST_CASES.md](../TEST_CASES.md).

Run from the repository root:

```bash
python3 testbench/py/check_versions.py
PYTHONPATH=py:submodules/vip_axi4_agent/py:submodules/vip_dram/py:submodules/vip_memory/py:submodules/vip_gauss/py \
  python3 -m pytest testbench/py/tc/test_mc_core.py
./testbench/py/run_fusesoc.sh --target sim
```

The Python status probe is mirrored into the wave-visible HDL scope
`mc_hdl_top.status_if`. GTKWave shows the enum fields as numbers in VCD, so
`status_if` also exposes decoded one-bit helpers such as `complete_page_miss`,
`complete_resp_slverr`, `backend_stall_device_credit_full`, and
`ar_blocked_rsp_buf_full`.

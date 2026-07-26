# vip_mc pyUVM Port Testbench

This is the Python testbench for the `vip_mc` pyUVM/cocotb port. It runs the
pure controller-core unit checks plus a Verilator shell over the Python
`vip_mc` top, backend, AXI4 and CHI front-ends, the real Python `vip_axi4_agent`
and `vip_chi_agent` stimulus agents, and the `vip_dram` device model. The AXI4
scoreboard subscribes to the backend grant-order tap and matches agent-monitor
B/R completions to issued entries.

Run from the repository root:

```bash
python3 testbench/py/check_versions.py
PYTHONPATH=py:submodules/vip_axi4_agent/py:submodules/vip_dram/py:submodules/vip_memory/py:submodules/vip_gauss/py \
  python3 -m pytest testbench/py/tc/test_mc_core.py
./testbench/py/run_fusesoc.sh --target sim
```

The simulator regression covers:

- `tc_mc_core_slice`
- `tc_mc_axi4_single_beat`
- `tc_mc_axi4_burst`
- `tc_mc_axi4_narrow_unaligned`
- `tc_mc_axi4_fixed`
- `tc_mc_axi4_wrap`
- `tc_mc_axi4_user_passthrough`
- `tc_mc_axi4_exclusive`
- `tc_mc_axi4_unsupported_reject`
- `tc_mc_status_probe`
- `tc_mc_axi4_agent`
- `tc_mc_axi4_multi_port`
- `tc_mc_axi4_outstanding_limit`
- `tc_mc_axi4_aw_backpressure`
- `tc_mc_axi4_wready_backpressure`
- `tc_mc_axi4_bresp_backpressure`
- `tc_mc_axi4_rsp_backpressure`
- `tc_mc_axi4_write_coalesce`
- `tc_mc_axi4_fr_fcfs_mixed_rd_wr`
- `tc_mc_axi4_read_pipeline`
- `tc_mc_axi4_read_multi_id`
- `tc_mc_axi4_ooo_inter_id`
- `tc_mc_fr_fcfs_starvation_cap`
- `tc_mc_qos_scheduling`
- `tc_mc_qos_aging`
- `tc_mc_rd_wr_grouping`
- `tc_mc_observability`
- `tc_mc_telemetry_counters`
- `tc_mc_reset_recovery`
- `tc_mc_refresh_collision`
- `tc_mc_narrow_axi4`
- `tc_mc_multi_rank`
- `tc_mc_equiv_axi4`
- `tc_mc_cfg`
- `tc_mc_refresh`
- `tc_mc_refresh_deferred`
- `tc_mc_init_delay`
- `tc_mc_preset_sweep`
- `tc_mc_ecc_slverr`
- `tc_mc_chi_d_read`
- `tc_mc_chi_d_write_read`
- `tc_mc_chi_d_write_ptl`
- `tc_mc_chi_d_decerr`
- `tc_mc_chi_d_combined_write`
- `tc_mc_chi_d_persist`
- `tc_mc_chi_d_unsupported`
- `tc_mc_chi_d_reject`
- `tc_mc_chi_d_narrow`
- `tc_mc_chi_e_write_read`
- `tc_mc_chi_e_write_zero`
- `tc_mc_chi_e_read_sep`
- `tc_mc_equiv_chi_d`
- `tc_mc_equiv_chi_e`
- `tc_mc_mixed_concurrent`

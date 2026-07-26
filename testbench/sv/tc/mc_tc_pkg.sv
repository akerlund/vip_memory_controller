////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2026 Fredrik Åkerlund
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
////////////////////////////////////////////////////////////////////////////////

// -----------------------------------------------------------------------------
// mc_tc_pkg
//
// Test-case package for the executable vip_mc example harness. The suite
// validates config/env wiring and the owned AXI4 front-end behavior against a
// real vip_dram instance.
// -----------------------------------------------------------------------------
`ifndef VIP_MC_TC_PKG
`define VIP_MC_TC_PKG

package mc_tc_pkg;

  `include "uvm_macros.svh"
  import uvm_pkg::*;

  // bool_t/TRUE/FALSE come from vip_mc's own vip_mc_types_pkg (imported below).
  // Peer agents expose vip_mem_types_pkg::bool_t on their cfg, so cross-agent
  // assignments use an explicit vip_mem_types_pkg:: qualifier.
  import report_server_pkg::*;
  import vip_dram_addr_pkg::*;
  import vip_dram_pkg::*;
  import vip_dram_timing_pkg::*;
  import vip_dram_types_pkg::*;
  import vip_axi4_types_pkg::*;
  import vip_axi4_agent_pkg::*;
  import vip_chi_types_pkg::*;
  import vip_chi_agent_pkg::*;
  import clk_rst_pkg::*;
  import vip_mc_axi4_types_pkg::*;
  import vip_mc_types_pkg::*;
  import vip_mc_pkg::*;
  import mc_tb_pkg::*;

  `include "mc_neutral_base_test.sv"
  `include "mc_base_test.sv"
  `include "tc_mc_axi4_agent.sv"
  `include "tc_mc_axi4_exclusive.sv"
  `include "tc_mc_axi4_fixed.sv"
  `include "tc_mc_axi4_read_multi_id.sv"
  `include "tc_mc_preset_sweep.sv"
  `include "tc_mc_axi4_ooo_inter_id.sv"
  `include "tc_mc_axi4_fr_fcfs_mixed_rd_wr.sv"
  `include "tc_mc_axi4_page_hit_streak.sv"
  `include "tc_mc_telemetry_counters.sv"
  `include "tc_mc_status_probe.sv"
  `include "tc_mc_axi4_unsupported_reject.sv"
  `include "tc_mc_axi4_multi_port.sv"
  `include "tc_mc_axi4_outstanding_limit.sv"
  `include "tc_mc_axi4_aw_backpressure.sv"
  `include "tc_mc_axi4_user_passthrough.sv"
  `include "tc_mc_axi4_wready_backpressure.sv"
  `include "tc_mc_axi4_wrap.sv"
  `include "tc_mc_axi4_narrow_unaligned.sv"
  `include "tc_mc_axi4_burst.sv"
  `include "tc_mc_axi4_bresp_backpressure.sv"
  `include "tc_mc_axi4_rsp_backpressure.sv"
  `include "tc_mc_axi4_single_beat.sv"
  `include "tc_mc_axi4_write_coalesce.sv"
  `include "tc_mc_axi4_read_pipeline.sv"
  `include "tc_mc_observability.sv"
  `include "tc_mc_ecc_slverr.sv"
  `include "tc_mc_fr_fcfs_starvation_cap.sv"
  `include "tc_mc_rd_wr_grouping.sv"
  `include "tc_mc_cfg.sv"
  `include "tc_mc_refresh.sv"
  `include "tc_mc_refresh_deferred.sv"
  `include "tc_mc_init_delay.sv"
  `include "tc_mc_reset_recovery.sv"
  `include "tc_mc_multi_rank.sv"
  `include "tc_mc_refresh_collision.sv"
  `include "tc_mc_qos_scheduling.sv"
  `include "tc_mc_qos_aging.sv"

  // CHI slice: a self-contained one-port CHI vip_mc instance driven by a stock
  // vip_chi RN-I manager (env + base + directed tests), mirroring the
  // tc_mc_multi_rank self-contained-env pattern.
  `include "mc_chi_base_test.sv"
  `include "tc_mc_chi_d_write_read.sv"
  `include "tc_mc_chi_d_read.sv"
  `include "tc_mc_chi_d_write_ptl.sv"
  `include "tc_mc_chi_d_decerr.sv"
  `include "tc_mc_chi_d_combined_write.sv"
  `include "tc_mc_chi_d_unsupported.sv"
  `include "tc_mc_chi_d_persist.sv"
  `include "tc_mc_chi_d_reject.sv"

  // CHI-E slice (the D/E matrix): the same self-contained CHI env/base test
  // specialized to the issue=E cfg family, adding a D/E parity/equivalence point
  // plus the two E-only opcodes (WriteNoSnpZero, ReadNoSnpSep).
  `include "tc_mc_chi_e_write_read.sv"
  `include "tc_mc_chi_e_write_zero.sv"
  `include "tc_mc_chi_e_read_sep.sv"

  // Protocol-equivalence suite: three legs replay the shared deterministic
  // program (mc_equiv_program) through AXI4 / CHI-D / CHI-E and check every
  // read against one protocol-neutral golden model (mc_equiv_model). All
  // three passing proves byte-identical device state and read data across them.
  `include "tc_mc_equiv_axi4.sv"
  `include "tc_mc_equiv_chi.sv"

  // Mixed-protocol concurrency: one vip_mc with an AXI4 port and a CHI-D port
  // over one shared backend/device, driven concurrently (see mc_mixed_tb_env).
  `include "tc_mc_mixed_concurrent.sv"

  // Narrow-bus (multi-beat / sub-row) slice: host bus narrower than the DRAM row
  // (WDATA_BYTES < ROW_BYTES) via a 128 B-row device over the stock 64 B ports.
  `include "tc_mc_narrow_axi4.sv"
  `include "tc_mc_chi_d_narrow.sv"

endpackage

`endif

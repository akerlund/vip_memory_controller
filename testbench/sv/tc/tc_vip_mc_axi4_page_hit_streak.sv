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
// tc_vip_mc_axi4_page_hit_streak
//
// Drive one long same-row burst through vip_mc and prove the device-level burst
// span is governed by tCCD_L per column access while the AXI-side completion
// still matches the timing scoreboard.
// -----------------------------------------------------------------------------
class tc_vip_mc_axi4_page_hit_streak extends vip_mc_base_test;

  `uvm_component_utils(tc_vip_mc_axi4_page_hit_streak)

  localparam int              BURST_BEATS_C = 64;
  localparam longint unsigned ADDR_C        = 'h2000;
  localparam realtime         TIME_TOL_NS_C = 0.01;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(input uvm_phase phase);
    uvm_config_db #(int)::set(this, "env", "mc_refresh_enabled", 0);
    super.build_phase(phase);
  endfunction

  task body();
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;
    vip_mc_cmd_entry #(DRAM_CFG_C)                      last_cmd;
    wdata_t                                             write_data_q[];
    wstrb_t                                             write_strb_q[];
    rdata_t                                             read_data_q[];
    resp_t                                              read_resp_q[];
    resp_t                                              bresp;
    int                                                 hit_before;
    int                                                 empty_before;
    realtime                                            actual_span_ns;
    realtime                                            expected_span_ns;

    if (!$cast(fe0, this._tb_env.u_mc.fes[0])) begin
      `uvm_fatal(get_name(), "vip_mc port 0 was not built as an AXI4 front-end")
    end

    this.wait_for_reset_release();

    write_data_q = new[BURST_BEATS_C];
    write_strb_q = new[BURST_BEATS_C];
    for (int beat_idx = 0; beat_idx < BURST_BEATS_C; beat_idx++) begin
      write_data_q[beat_idx] = '0;
      write_strb_q[beat_idx] = '1;
      for (int byte_idx = 0; byte_idx < VIP_MC_AXI4_CFG_C.WDATA_BYTES_P; byte_idx++) begin
        write_data_q[beat_idx][(8 * byte_idx) +: 8] =
          8'h20 + beat_idx[7:0] + byte_idx[7:0];
      end
    end

    hit_before   = this._tb_env.dram.get_page_hit_count();
    empty_before = this._tb_env.dram.get_page_empty_count();

    this.axi4_write_burst(ADDR_C, write_data_q, write_strb_q, bresp);
    if (bresp != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Page-hit streak write burst returned BRESP=%0b instead of OKAY",
        bresp))
    end

    this.axi4_read_burst(ADDR_C, BURST_BEATS_C, read_data_q, read_resp_q);
    foreach (read_resp_q[i]) begin
      if (read_resp_q[i] != VIP_MC_AXI4_RESP_OKAY_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "Page-hit streak read burst beat %0d returned RRESP=%0b instead of OKAY",
          i,
          read_resp_q[i]))
      end
      if (read_data_q[i] !== write_data_q[i]) begin
        `uvm_fatal(get_name(), $sformatf(
          "Page-hit streak readback mismatch on beat %0d",
          i))
      end
    end

    if (this._tb_env.scoreboard.get_timing_checked_count() < 2) begin
      `uvm_fatal(get_name(), "Page-hit streak test did not exercise the timing scoreboard on both burst requests")
    end
    if (this._tb_env.scoreboard.get_timing_error_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "Page-hit streak test saw %0d timing scoreboard errors",
        this._tb_env.scoreboard.get_timing_error_count()))
    end

    if ((this._tb_env.dram.get_page_empty_count() - empty_before) != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Page-hit streak expected exactly one empty access delta, saw %0d",
        this._tb_env.dram.get_page_empty_count() - empty_before))
    end
    if ((this._tb_env.dram.get_page_hit_count() - hit_before) != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Page-hit streak expected exactly one page-hit access delta, saw %0d",
        this._tb_env.dram.get_page_hit_count() - hit_before))
    end

    last_cmd = this._tb_env.u_mc.backend.last_completed_cmd;
    if ((last_cmd.op != VIP_DRAM_OP_RD_E) || (last_cmd.axi_beats != BURST_BEATS_C)) begin
      `uvm_fatal(get_name(), "Page-hit streak did not retain the expected long read as the last completed command")
    end

    actual_span_ns   = last_cmd.last_beat_ready_time - last_cmd.first_beat_ready_time;
    expected_span_ns = realtime'(BURST_BEATS_C - 1) * this._tb_env.dram.cfg.timing.tCCD_L;
    if ((actual_span_ns < (expected_span_ns - TIME_TOL_NS_C)) ||
        (actual_span_ns > (expected_span_ns + TIME_TOL_NS_C))) begin
      `uvm_fatal(get_name(), $sformatf(
        "Page-hit streak burst span=%0.3fns, expected %0.3fns from tCCD_L",
        actual_span_ns,
        expected_span_ns))
    end

    `uvm_info(get_name(), $sformatf(
      "vip_mc AXI4 page-hit streak test passed (burst span=%0.3fns, expected tCCD_L span=%0.3fns)",
      actual_span_ns,
      expected_span_ns), UVM_LOW)
  endtask
endclass
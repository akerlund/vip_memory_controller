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
// tc_mc_axi4_rsp_backpressure
//
// Smoke test for the first response-buffer backpressure slice. It limits the
// MC response buffer to one slot, stalls RREADY, and checks that ARREADY drops
// until the blocked read response is consumed.
// -----------------------------------------------------------------------------
class tc_mc_axi4_rsp_backpressure extends mc_base_test;

  `uvm_component_utils(tc_mc_axi4_rsp_backpressure)

  localparam int OBS_TIMEOUT_CYCLES_C = 512;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Issue one single-beat read without waiting for the returning R response.
  // ---------------------------------------------------------------------------
  protected task issue_read_no_wait(
    input logic [VIP_MC_AXI4_CFG_C.ARID_WIDTH_P - 1 : 0] arid,
    input longint unsigned                               addr
  );
    vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)           rd_seq;
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;

    fe0 = this.get_port_fe(0);

    rd_seq = vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)::type_id::create($sformatf(
      "rsp_bp_rd_seq_%0h_%0h",
      arid,
      addr));
    rd_seq.reset();
    rd_seq.set_arid(arid);
    rd_seq.set_axaddr(addr);
    rd_seq.set_axlen(0);
    rd_seq.set_axsize(this.get_full_width_axi_size());
    rd_seq.set_axburst(VIP_MC_AXI4_BURST_INCR_C);
    rd_seq.set_axqos(4'h3);
    rd_seq.set_requests(1);
    rd_seq.set_get_rd_response(1'b0);
    this.start_seq_or_timeout(
      rd_seq,
      this._tb_env.man_agent[0].sequencer,
      fe0,
      0,
      rd_seq.get_name());
  endtask

  // ---------------------------------------------------------------------------
  // Force a one-slot response buffer so backpressure is easy to observe.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    uvm_config_db #(int)::set(this, "env", "mc_rsp_buf_depth", 1);
    // This test intentionally stalls RREADY to exhaust the response buffer, so
    // observed R timing carries manager-side backpressure latency that
    // dram.predict() (device-only) does not model. The latency-fidelity check
    // does not apply; the ordering/backpressure assertions below still do.
    uvm_config_db #(int)::set(this, "env", "mc_scoreboard_timing_check", 0);
    super.build_phase(phase);
  endfunction

  // ---------------------------------------------------------------------------
  // Stall the first read response and prove that ARREADY stays low meanwhile.
  // ---------------------------------------------------------------------------
  task body();
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;
    bit blocked_rsp_seen;

    if (!$cast(fe0, this._tb_env.u_mc.fes[0])) begin
      `uvm_fatal(get_name(), "vip_mc port 0 was not built as an AXI4 front-end")
    end

    this.wait_for_reset_release();

    this._tb_env.man_cfg[0].rready_delay_enabled    = 1'b1;
    this._tb_env.man_cfg[0].rready_delay_gauss_enabled = 1'b0;
    this._tb_env.man_cfg[0].rready_delay_time_min   = 8;
    this._tb_env.man_cfg[0].rready_delay_time_max   = 8;
    this._tb_env.man_cfg[0].rready_delay_period_min = 1;
    this._tb_env.man_cfg[0].rready_delay_period_max = 1;

    this.clear_manager_observations();

    this.issue_read_no_wait('h2, 'h0300);

    blocked_rsp_seen = 1'b0;
    repeat (OBS_TIMEOUT_CYCLES_C) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if ((this.ar_observations.size() == 1) &&
          (this._tb_env._man_vif[0].rvalid === 1'b1) &&
          (this._tb_env._man_vif[0].rready === 1'b0)) begin
        blocked_rsp_seen = 1'b1;
        break;
      end
    end

    if (this.ar_observations.size() != 1) begin
      `uvm_fatal(get_name(), "RSP backpressure did not observe the first AR handshake")
    end
    if (!blocked_rsp_seen) begin
      `uvm_fatal(get_name(), "RSP backpressure did not observe the first read response blocked on the manager interface")
    end

    this.issue_read_no_wait('h4, 'h0400);

    repeat (OBS_TIMEOUT_CYCLES_C) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if (this.rd_observations.size() >= 1) begin
        break;
      end
    end

    if (this.rd_observations.size() == 0) begin
      `uvm_fatal(get_name(), "RSP backpressure did not observe the first read response complete")
    end

    repeat (OBS_TIMEOUT_CYCLES_C) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if (this.ar_observations.size() >= 2) begin
        break;
      end
    end

    if (this.ar_observations.size() != 2) begin
      `uvm_fatal(get_name(), "RSP backpressure did not observe both AR handshakes")
    end

    repeat (OBS_TIMEOUT_CYCLES_C) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if (this.rd_observations.size() >= 2) begin
        break;
      end
    end

    if (this.rd_observations.size() != 2) begin
      `uvm_fatal(get_name(), "RSP backpressure did not observe both read responses")
    end
    if (this.ar_observation_times[1] < this.rd_observation_times[0]) begin
      `uvm_fatal(get_name(), "ARREADY did not backpressure until the blocked read response was consumed")
    end
    foreach (this.rd_observations[i]) begin
      if (this.rd_observations[i].rresp != VIP_MC_AXI4_RESP_OKAY_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "RSP backpressure test observed RRESP=%0b on response %0d instead of OKAY",
          this.rd_observations[i].rresp,
          i))
      end
    end

    if (fe0.observed_ar_count != 2) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not observe both read-address handshakes")
    end
    if (this._tb_env.u_mc.get_rsp_buf_full_cycles(0) == 0) begin
      `uvm_fatal(get_name(),
        "vip_mc response-buffer backpressure did not advance get_rsp_buf_full_cycles()")
    end

    `uvm_info(get_name(), "vip_mc response-buffer backpressure test passed", UVM_LOW)
  endtask

endclass
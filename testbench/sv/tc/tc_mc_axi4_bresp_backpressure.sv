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
// tc_mc_axi4_bresp_backpressure
//
// Smoke test for write-side response-buffer backpressure. It limits the MC
// response buffer to one slot, stalls BREADY, and checks that AWREADY stays low
// until the blocked BRESP is consumed.
// -----------------------------------------------------------------------------
class tc_mc_axi4_bresp_backpressure extends mc_base_test;

  `uvm_component_utils(tc_mc_axi4_bresp_backpressure)

  localparam int OBS_TIMEOUT_CYCLES_C = 512;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Force a one-slot response buffer so write-side backpressure is observable.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    uvm_config_db #(int)::set(this, "env", "mc_rsp_buf_depth", 1);
    super.build_phase(phase);
  endfunction

  // ---------------------------------------------------------------------------
  // Stall the first BRESP and prove that AWREADY stays low meanwhile.
  // ---------------------------------------------------------------------------
  task body();
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;
    vip_axi4_write_seq #(VIP_AXI4_AGENT_CFG_C)         wr_seq;
    vip_axi4_types #(VIP_AXI4_AGENT_CFG_C)::addr_t     addr_q[];
    vip_axi4_types #(VIP_AXI4_AGENT_CFG_C)::wdata_t    write_q[$];
    vip_axi4_types #(VIP_AXI4_AGENT_CFG_C)::wstrb_t    strb_q[$];

    if (!$cast(fe0, this._tb_env.u_mc.fes[0])) begin
      `uvm_fatal(get_name(), "vip_mc port 0 was not built as an AXI4 front-end")
    end

    this.wait_for_reset_release();

    this._tb_env.man_cfg[0].bready_delay_enabled    = 1'b1;
    this._tb_env.man_cfg[0].bready_delay_gauss_enabled = 1'b0;
    this._tb_env.man_cfg[0].bready_delay_time_min   = 8;
    this._tb_env.man_cfg[0].bready_delay_time_max   = 8;
    this._tb_env.man_cfg[0].bready_delay_period_min = 12;
    this._tb_env.man_cfg[0].bready_delay_period_max = 12;

    addr_q = new[2];
    addr_q[0] = 'h0500;
    addr_q[1] = 'h0600;
    write_q.push_back('h55);
    write_q.push_back('h66);
    strb_q.push_back('1);
    strb_q.push_back('1);

    this.clear_manager_observations();

    wr_seq = vip_axi4_write_seq #(VIP_AXI4_AGENT_CFG_C)::type_id::create("bresp_bp_wr_seq");
    wr_seq.reset();
    wr_seq.set_awid('h1);
    wr_seq.set_axaddrs(addr_q);
    wr_seq.set_axlen(0);
    wr_seq.set_axsize(this.get_full_width_axi_size());
    wr_seq.set_axburst(VIP_AXI4_BURST_INCR_C);
    wr_seq.set_axqos(4'h2);
    wr_seq.set_get_wr_response(1'b0);
    wr_seq.set_wdata_type(VIP_AXI4_DATA_CUSTOM_E);
    wr_seq.set_wstrb_type(VIP_AXI4_STRB_CUSTOM_E);
    wr_seq.set_wdata(write_q);
    wr_seq.set_wstrb(strb_q);
    this.start_seq_or_timeout(
      wr_seq,
      this._tb_env.man_agent[0].sequencer,
      fe0,
      0,
      "bresp_bp_wr_seq");

    repeat (OBS_TIMEOUT_CYCLES_C) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if ((this.aw_observations.size() == 2) && (this.wr_observations.size() == 2)) begin
        break;
      end
    end

    if (this.aw_observations.size() != 2) begin
      `uvm_fatal(get_name(), "BRESP backpressure did not observe both AW handshakes")
    end
    if (this.wr_observations.size() != 2) begin
      `uvm_fatal(get_name(), "BRESP backpressure did not observe both write responses")
    end
    if (this.aw_observation_times[1] < this.wr_observation_times[0]) begin
      `uvm_fatal(get_name(), "AWREADY did not backpressure until the blocked BRESP was consumed")
    end
    foreach (this.wr_observations[i]) begin
      if (this.wr_observations[i].bresp != VIP_MC_AXI4_RESP_OKAY_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "BRESP backpressure test observed BRESP=%0b on response %0d instead of OKAY",
          this.wr_observations[i].bresp,
          i))
      end
    end

    if (fe0.observed_aw_count != 2) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not observe both write-address handshakes")
    end
    if (this._tb_env.u_mc.get_rsp_buf_full_cycles(0) == 0) begin
      `uvm_fatal(get_name(),
        "vip_mc BRESP backpressure did not advance get_rsp_buf_full_cycles()")
    end

    `uvm_info(get_name(), "vip_mc BRESP backpressure test passed", UVM_LOW)
  endtask

endclass

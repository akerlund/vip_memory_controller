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
// tc_vip_mc_axi4_read_multi_id
//
// Concurrent multi-ID reads. Two read bursts with distinct ARIDs are issued
// back-to-back without waiting; both must complete correctly with their
// programmed data. AXI4 has no read-data interleaving, so each burst's beats are
// returned contiguously on the R channel (the front-end keeps at most one read
// burst active at a time); whole-burst completion order across IDs still follows
// device timing. Same-ID beat order stays intact.
// -----------------------------------------------------------------------------
class tc_vip_mc_axi4_read_multi_id extends vip_mc_base_test;

  typedef logic [VIP_MC_AXI4_CFG_C.ARID_WIDTH_P - 1 : 0] rid_t;

  `uvm_component_utils(tc_vip_mc_axi4_read_multi_id)

  localparam int OBS_TIMEOUT_CYCLES_C = 512;
  localparam int BURST_BEATS_C = 2;
  localparam longint unsigned ADDR_A_C = 'h0500;
  localparam longint unsigned ADDR_B_C = 'h0600;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Issue one AR burst without consuming the returning R beats yet.
  // ---------------------------------------------------------------------------
  protected task issue_read_burst_no_wait(
    input rid_t             arid,
    input longint unsigned  addr,
    input int unsigned      beat_count
  );
    vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)           rd_seq;
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;

    fe0 = this.get_port_fe(0);

    rd_seq = vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)::type_id::create($sformatf(
      "rd_issue_%0d_%0h",
      arid,
      addr));
    rd_seq.reset();
    rd_seq.set_arid(arid);
    rd_seq.set_axaddr(addr);
    rd_seq.set_axlen(beat_count - 1);
    rd_seq.set_axsize(this.get_full_width_axi_size());
    rd_seq.set_axburst(VIP_AXI4_BURST_INCR_C);
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
  // Drive two distinct-ID reads through vip_mc and check both complete cleanly.
  // ---------------------------------------------------------------------------
  task body();
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;
    wdata_t                                             write_a_q[];
    wstrb_t                                             write_a_strb_q[];
    wdata_t                                             write_b_q[];
    wstrb_t                                             write_b_strb_q[];
    resp_t                                              bresp;
    int                                                 obs_a_idx;
    int                                                 obs_b_idx;
    int unsigned                                        complete_count_base;

    if (!$cast(fe0, this._tb_env.u_mc.fes[0])) begin
      `uvm_fatal(get_name(), "vip_mc port 0 was not built as an AXI4 front-end")
    end

    this.wait_for_reset_release();

    write_a_q      = new[BURST_BEATS_C];
    write_a_strb_q = new[BURST_BEATS_C];
    write_b_q      = new[BURST_BEATS_C];
    write_b_strb_q = new[BURST_BEATS_C];

    for (int beat_idx = 0; beat_idx < BURST_BEATS_C; beat_idx++) begin
      write_a_q[beat_idx]      = '0;
      write_a_strb_q[beat_idx] = '1;
      write_b_q[beat_idx]      = '0;
      write_b_strb_q[beat_idx] = '1;

      for (int byte_idx = 0; byte_idx < VIP_MC_AXI4_CFG_C.WDATA_BYTES_P; byte_idx++) begin
        write_a_q[beat_idx][(8 * byte_idx) +: 8] = 8'h20 + (beat_idx * 8'h10) + byte_idx;
        write_b_q[beat_idx][(8 * byte_idx) +: 8] = 8'h80 + (beat_idx * 8'h10) + byte_idx;
      end
    end

    this.axi4_write_burst(ADDR_A_C, write_a_q, write_a_strb_q, bresp);
    if (bresp != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), "Multi-ID read: write burst A did not return OKAY")
    end

    this.axi4_write_burst(ADDR_B_C, write_b_q, write_b_strb_q, bresp);
    if (bresp != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), "Multi-ID read: write burst B did not return OKAY")
    end

    complete_count_base = fe0.complete_count;

    this.clear_manager_observations();

    this.issue_read_burst_no_wait('h1, ADDR_A_C, BURST_BEATS_C);
    this.issue_read_burst_no_wait('h2, ADDR_B_C, BURST_BEATS_C);

    repeat (OBS_TIMEOUT_CYCLES_C) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if ((fe0.complete_count >= (complete_count_base + 2)) &&
          (this.rd_observations.size() >= 2)) begin
        break;
      end
    end

    if (this.rd_observations.size() != 2) begin
      `uvm_fatal(get_name(), "Multi-ID read did not observe both read responses on the stock manager monitor")
    end

    obs_a_idx = -1;
    obs_b_idx = -1;
    foreach (this.rd_observations[i]) begin
      if (this.rd_observations[i].rid == 'h1) begin
        obs_a_idx = i;
      end
      else if (this.rd_observations[i].rid == 'h2) begin
        obs_b_idx = i;
      end
    end

    if ((obs_a_idx < 0) || (obs_b_idx < 0)) begin
      `uvm_fatal(get_name(), "Multi-ID read did not retain both distinct read IDs")
    end

    if (this.rd_observations[obs_a_idx].rresp != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), "Burst A did not return OKAY")
    end
    if (this.rd_observations[obs_b_idx].rresp != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), "Burst B did not return OKAY")
    end
    if (this.rd_observations[obs_a_idx].rdata.size() != BURST_BEATS_C) begin
      `uvm_fatal(get_name(), "Burst A did not return the expected number of beats")
    end
    if (this.rd_observations[obs_b_idx].rdata.size() != BURST_BEATS_C) begin
      `uvm_fatal(get_name(), "Burst B did not return the expected number of beats")
    end
    for (int beat_idx = 0; beat_idx < BURST_BEATS_C; beat_idx++) begin
      if (this.flatten_read_beat(this.rd_observations[obs_a_idx], beat_idx) !== write_a_q[beat_idx]) begin
        `uvm_fatal(get_name(), $sformatf(
          "Multi-ID read burst A beat %0d mismatched its programmed data",
          beat_idx))
      end
      if (this.flatten_read_beat(this.rd_observations[obs_b_idx], beat_idx) !== write_b_q[beat_idx]) begin
        `uvm_fatal(get_name(), $sformatf(
          "Multi-ID read burst B beat %0d mismatched its programmed data",
          beat_idx))
      end
    end

    if (fe0.observed_ar_count < 2) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not observe both AR handshakes")
    end

    `uvm_info(get_name(), "vip_mc AXI4 multi-ID read test passed", UVM_LOW)
  endtask

endclass
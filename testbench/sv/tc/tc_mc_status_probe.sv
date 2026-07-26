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
// tc_mc_status_probe
//
// Debug-focused sanity check for the optional vip_mc status probe (§8.8A). It
// exercises the three regimes the probe is meant to make visible in waves and
// confirms the mirrored status_vif fields track them:
//   * queueing / backpressure - a depth-1 response buffer with stalled RREADY
//     drives rsp_buf_full and the new RSP_BUF_FULL front-end block reason, and
//     the drain emits issue/complete pulses;
//   * refresh - a shortened tREFI makes refresh_count advance and emits the
//     refresh pulse;
//   * FE-local reject - an unsupported FIXED burst is rejected locally and
//     surfaces as a reject pulse carrying UNSUPPORTED_AXI_SHAPE.
// -----------------------------------------------------------------------------
class tc_mc_status_probe extends mc_base_test;

  `uvm_component_utils(tc_mc_status_probe)

  localparam int              READ_COUNT_C              = 3;
  localparam int              BLOCK_TIMEOUT_CYCLES_C    = 512;
  localparam int              DRAIN_TIMEOUT_CYCLES_C    = 1024;
  localparam int              REFRESH_TIMEOUT_CYCLES_C  = 512;
  localparam int              RREADY_STALL_CYCLES_C     = 8;
  localparam int              UNSUPPORTED_FIXED_BEATS_C = 17;
  localparam longint unsigned READ_BASE_ADDR_C          = 'h0100;
  localparam longint unsigned READ_ADDR_STRIDE_C        = 'h0100;
  localparam longint unsigned REJECT_ADDR_C             = 'h0400;

  // Accumulated observations sampled from the mirrored status interface.
  protected bit                    _sample_active     = 1'b0;
  protected bit                    _saw_rsp_buf_full  = 1'b0;
  protected bit                    _saw_rsp_buf_block = 1'b0;
  protected int unsigned           _max_rd_outstanding = 0;
  protected int unsigned           _max_peak_depth     = 0;
  protected bit                    _saw_issue_pulse    = 1'b0;
  protected bit                    _saw_complete_pulse = 1'b0;
  protected bit                    _saw_refresh_pulse  = 1'b0;
  protected int unsigned           _max_refresh_count  = 0;
  protected bit                    _saw_reject_pulse   = 1'b0;
  protected vip_mc_status_reject_e _seen_reject_reason = VIP_MC_STATUS_REJECT_NONE_E;
  protected vip_mc_status_op_e     _seen_reject_op     = VIP_MC_STATUS_OP_NONE_E;
  protected int unsigned           _seen_reject_port   = 0;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Constrain the controller so a single response slot backpressures quickly
  // and shorten the refresh cadence so refreshes land inside the test window.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    uvm_config_db #(int)::set(this, "env", "mc_rsp_buf_depth", 1);
    uvm_config_db #(int)::set(this, "env", "mc_max_inflight_to_device", 1);
    uvm_config_db #(int)::set(this, "env", "mc_scoreboard_timing_check", 0);
    uvm_config_db #(real)::set(this, "env", "mc_trefi_override_ns", 50.0);
    super.build_phase(phase);
  endfunction

  // ---------------------------------------------------------------------------
  // Continuously fold the mirrored status_vif fields into the accumulators on
  // the shared controller clock until the test clears _sample_active.
  // ---------------------------------------------------------------------------
  protected task sample_status_probe();
    // Sample on the negedge: the single-owner publisher drives status_vif on the
    // controller posedge, so reading half a cycle later avoids a same-edge race
    // while still catching the full-cycle-wide pulses.
    while (this._sample_active) begin
      @(negedge this._tb_env._man_vif[0].clk);

      if (this._tb_env._status_vif.rsp_buf_full) begin
        this._saw_rsp_buf_full = 1'b1;
      end
      for (int unsigned port_id = 0; port_id < N_PORTS_C; port_id++) begin
        if ((this._tb_env._status_vif.ar_block_reason[port_id] ==
               VIP_MC_STATUS_FE_BLOCK_RSP_BUF_FULL_E) ||
            (this._tb_env._status_vif.aw_block_reason[port_id] ==
               VIP_MC_STATUS_FE_BLOCK_RSP_BUF_FULL_E)) begin
          this._saw_rsp_buf_block = 1'b1;
        end
      end
      if (this._tb_env._status_vif.rd_outstanding_count[0] > this._max_rd_outstanding) begin
        this._max_rd_outstanding = this._tb_env._status_vif.rd_outstanding_count[0];
      end
      if (this._tb_env._status_vif.cmd_queue_peak_depth > this._max_peak_depth) begin
        this._max_peak_depth = this._tb_env._status_vif.cmd_queue_peak_depth;
      end
      if (this._tb_env._status_vif.issue_pulse) begin
        this._saw_issue_pulse = 1'b1;
      end
      if (this._tb_env._status_vif.complete_pulse) begin
        this._saw_complete_pulse = 1'b1;
      end
      if (this._tb_env._status_vif.refresh_emit_pulse) begin
        this._saw_refresh_pulse = 1'b1;
      end
      if (this._tb_env._status_vif.refresh_count > this._max_refresh_count) begin
        this._max_refresh_count = this._tb_env._status_vif.refresh_count;
      end
      if (this._tb_env._status_vif.local_reject_pulse) begin
        this._saw_reject_pulse   = 1'b1;
        this._seen_reject_reason = this._tb_env._status_vif.local_reject_reason;
        this._seen_reject_op     = this._tb_env._status_vif.local_reject_op;
        this._seen_reject_port   = this._tb_env._status_vif.local_reject_port_id;
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Issue one single-beat read without waiting for its R response so several
  // reads can be presented while the response buffer is backpressured.
  // ---------------------------------------------------------------------------
  protected task issue_read_no_wait(
    input logic [VIP_MC_AXI4_CFG_C.ARID_WIDTH_P - 1 : 0] arid,
    input longint unsigned                               addr
  );
    vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)           rd_seq;
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;

    fe0 = this.get_port_fe(0);

    rd_seq = vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)::type_id::create($sformatf(
      "status_probe_rd_%0h_%0h",
      arid,
      addr));
    rd_seq.reset();
    rd_seq.set_arid(arid);
    rd_seq.set_axaddr(addr);
    rd_seq.set_axlen(0);
    rd_seq.set_axsize(this.get_full_width_axi_size());
    rd_seq.set_axburst(VIP_MC_AXI4_BURST_INCR_C);
    rd_seq.set_axqos(4'h5);
    rd_seq.set_requests(1);
    rd_seq.set_get_rd_response(1'b0);
    this.start_seq_or_timeout(
      rd_seq,
      this._tb_env.man_agent[0].sequencer,
      fe0,
      0,
      rd_seq.get_name());
  endtask

  task body();
    logic [2 : 0] axi_size;
    wdata_t       reject_data_q[];
    wstrb_t       reject_strb_q[];
    resp_t        reject_bresp;
    int           refresh_wait;
    bit           blocked_rsp_seen;

    this.wait_for_reset_release();

    this._sample_active = 1'b1;
    // The sampler runs as a sibling branch of the stimulus. The sequence
    // helpers (start_seq_or_timeout) execute `disable fork`, which terminates
    // the calling process's descendant threads - so the sampler must NOT be a
    // descendant of the stimulus, or it would be killed on the first read.
    fork
      this.sample_status_probe();

      begin : stimulus_branch
    // --- Phase A: queueing / response-buffer backpressure -------------------
    // Hold RREADY low for a while so the depth-1 response buffer fills and
    // gates fresh AR acceptance; then let it drain.
    this._tb_env.man_cfg[0].rready_delay_enabled       = 1'b1;
    this._tb_env.man_cfg[0].rready_delay_gauss_enabled = 1'b0;
    this._tb_env.man_cfg[0].rready_delay_time_min      = RREADY_STALL_CYCLES_C;
    this._tb_env.man_cfg[0].rready_delay_time_max      = RREADY_STALL_CYCLES_C;
    this._tb_env.man_cfg[0].rready_delay_period_min    = 1;
    this._tb_env.man_cfg[0].rready_delay_period_max    = 1;

    // Issue one read and wait until its response is parked on stalled RREADY,
    // occupying the single response slot. Issuing the remaining reads then
    // presents ARs that the FE must block on RSP_BUF_FULL.
    this.issue_read_no_wait('0, READ_BASE_ADDR_C);

    blocked_rsp_seen = 1'b0;
    for (int cyc = 0; cyc < BLOCK_TIMEOUT_CYCLES_C; cyc++) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if ((this._tb_env._man_vif[0].rvalid === 1'b1) &&
          (this._tb_env._man_vif[0].rready === 1'b0)) begin
        blocked_rsp_seen = 1'b1;
        break;
      end
    end
    if (!blocked_rsp_seen) begin
      `uvm_fatal(get_name(), "First read response never parked on stalled RREADY")
    end

    for (int rd_idx = 1; rd_idx < READ_COUNT_C; rd_idx++) begin
      this.issue_read_no_wait(
        rd_idx[VIP_MC_AXI4_CFG_C.ARID_WIDTH_P - 1 : 0],
        READ_BASE_ADDR_C + (READ_ADDR_STRIDE_C * rd_idx));
    end

    // Let the stalled responses drain out so the reads complete. The RREADY
    // delay is left enabled: the manager keeps servicing R beats at the slowed
    // cadence, which reliably retires every read.
    for (int cyc = 0; cyc < DRAIN_TIMEOUT_CYCLES_C; cyc++) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if (this.get_port_fe(0).complete_count >= READ_COUNT_C) begin
        break;
      end
    end
    if (this.get_port_fe(0).complete_count < READ_COUNT_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Status-probe reads did not drain: complete_count=%0d expected >= %0d",
        this.get_port_fe(0).complete_count,
        READ_COUNT_C))
    end

    // --- Phase B: FE-local reject -------------------------------------------
    axi_size      = this.get_full_width_axi_size();
    reject_data_q = new[UNSUPPORTED_FIXED_BEATS_C];
    reject_strb_q = new[UNSUPPORTED_FIXED_BEATS_C];
    foreach (reject_data_q[beat_idx]) begin
      reject_data_q[beat_idx] = '0;
      reject_strb_q[beat_idx] = '1;
    end
    this.axi4_write_fixed_custom(
      REJECT_ADDR_C, axi_size, reject_data_q, reject_strb_q, reject_bresp);
    if (reject_bresp != VIP_MC_AXI4_RESP_SLVERR_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Unsupported FIXED write returned BRESP=%0b instead of SLVERR",
        reject_bresp))
    end

    // --- Phase C: refresh ---------------------------------------------------
    refresh_wait = 0;
    while ((this._max_refresh_count == 0) && (refresh_wait < REFRESH_TIMEOUT_CYCLES_C)) begin
      @(posedge this._tb_env._man_vif[0].clk);
      refresh_wait++;
    end

        // Settle one more edge so the reject/refresh pulses are folded in,
        // then stop the sampler; the sibling branch exits and join completes.
        repeat (2) @(posedge this._tb_env._man_vif[0].clk);
        this._sample_active = 1'b0;
      end : stimulus_branch
    join

    // --- Checks -------------------------------------------------------------
    if (!this._saw_rsp_buf_full) begin
      `uvm_fatal(get_name(), "status_vif.rsp_buf_full never asserted under backpressure")
    end
    if (!this._saw_rsp_buf_block) begin
      `uvm_fatal(get_name(),
        "status_vif never reported the RSP_BUF_FULL front-end block reason under backpressure")
    end
    if (this._max_rd_outstanding == 0) begin
      `uvm_fatal(get_name(), "status_vif.rd_outstanding_count[0] never advanced past zero")
    end
    if (!this._saw_issue_pulse) begin
      `uvm_fatal(get_name(), "status_vif.issue_pulse never fired while reads drained")
    end
    if (!this._saw_complete_pulse) begin
      `uvm_fatal(get_name(), "status_vif.complete_pulse never fired while reads drained")
    end
    if (!this._saw_reject_pulse) begin
      `uvm_fatal(get_name(), "status_vif.local_reject_pulse never fired for the unsupported FIXED write")
    end
    if (this._seen_reject_reason != VIP_MC_STATUS_REJECT_UNSUPPORTED_AXI_SHAPE_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "status_vif.local_reject_reason=%s expected VIP_MC_STATUS_REJECT_UNSUPPORTED_AXI_SHAPE_E",
        this._seen_reject_reason.name()))
    end
    if (this._seen_reject_op != VIP_MC_STATUS_OP_WR_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "status_vif.local_reject_op=%s expected VIP_MC_STATUS_OP_WR_E",
        this._seen_reject_op.name()))
    end
    if (this._seen_reject_port != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "status_vif.local_reject_port_id=%0d expected 0",
        this._seen_reject_port))
    end
    if (!this._saw_refresh_pulse) begin
      `uvm_fatal(get_name(), "status_vif.refresh_emit_pulse never fired at the shortened tREFI")
    end
    if (this._max_refresh_count == 0) begin
      `uvm_fatal(get_name(), "status_vif.refresh_count never advanced")
    end

    `uvm_info(get_name(), $sformatf(
      "vip_mc status probe test passed (peak_depth=%0d rd_outstanding=%0d refresh=%0d reject=%s)",
      this._max_peak_depth,
      this._max_rd_outstanding,
      this._max_refresh_count,
      this._seen_reject_reason.name()), UVM_LOW)
  endtask

endclass

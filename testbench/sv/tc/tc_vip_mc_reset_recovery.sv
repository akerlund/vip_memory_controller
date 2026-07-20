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
// tc_vip_mc_reset_recovery (§13.3 #9 / P2-1)
//
// Launch a read, let it reach the device boundary, then force rst_n low before
// the response returns. The cancelled pre-reset response must never appear on
// R, the post-reset read to the same address must complete cleanly, and the
// DRAM must classify that post-reset read as page-empty again.
// -----------------------------------------------------------------------------

class mc_reset_recovery_grant_collector extends uvm_subscriber #(vip_mc_cmd_entry #(DRAM_CFG_C));
  typedef vip_mc_cmd_entry #(DRAM_CFG_C) cmd_t;

  longint unsigned tag_by_id[longint unsigned];

  `uvm_component_utils(mc_reset_recovery_grant_collector)

  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  function void write(input cmd_t t);
    if ((t == null) || (t.op != VIP_DRAM_OP_RD_E)) begin
      return;
    end
    this.tag_by_id[t.axi4_id] = t.tag;
  endfunction

  function bit has_id(input longint unsigned axi4_id);
    return this.tag_by_id.exists(axi4_id);
  endfunction

  function longint unsigned get_tag(input longint unsigned axi4_id);
    if (!this.tag_by_id.exists(axi4_id)) begin
      return '0;
    end
    return this.tag_by_id[axi4_id];
  endfunction

  function void clear();
    this.tag_by_id.delete();
  endfunction
endclass

class mc_reset_recovery_rsp_collector extends uvm_subscriber #(vip_dram_rsp #(DRAM_CFG_C));
  typedef vip_dram_rsp #(DRAM_CFG_C) rsp_t;

  rsp_t rsp_by_tag[longint unsigned];

  `uvm_component_utils(mc_reset_recovery_rsp_collector)

  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  function void write(input rsp_t t);
    rsp_t rsp_copy;

    if (t == null) begin
      return;
    end

    $cast(rsp_copy, t.clone());
    this.rsp_by_tag[t.tag] = rsp_copy;
  endfunction

  function bit has_rsp(input longint unsigned tag);
    return this.rsp_by_tag.exists(tag);
  endfunction

  function rsp_t get_rsp(input longint unsigned tag);
    if (!this.rsp_by_tag.exists(tag)) begin
      return null;
    end
    return this.rsp_by_tag[tag];
  endfunction

  function void clear();
    this.rsp_by_tag.delete();
  endfunction
endclass

class tc_vip_mc_reset_recovery extends vip_mc_base_test;

  `uvm_component_utils(tc_vip_mc_reset_recovery)

  localparam int      OBS_TIMEOUT_CYCLES_C = 2048;
  localparam int      PRE_RESET_BEATS_C    = 16;
  localparam time     RESET_LOW_TIME_C     = 20ns;

  mc_reset_recovery_grant_collector _grant;
  mc_reset_recovery_rsp_collector   _dram_rsp;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(input uvm_phase phase);
    // The reset-recovery test intentionally cancels an in-flight response, so
    // the timing scoreboard's pending prediction bookkeeping does not apply.
    uvm_config_db #(int)::set(this, "env", "mc_scoreboard_enabled", 0);
    super.build_phase(phase);
    this._grant    = mc_reset_recovery_grant_collector::type_id::create("grant", this);
    this._dram_rsp = mc_reset_recovery_rsp_collector::type_id::create("dram_rsp", this);
  endfunction

  function void connect_phase(input uvm_phase phase);
    super.connect_phase(phase);
    this._tb_env.u_mc.backend.issued_port.connect(this._grant.analysis_export);
    this._tb_env.dram.rsp_port.connect(this._dram_rsp.analysis_export);
  endfunction

  protected task issue_read_no_wait(
    input logic [VIP_MC_AXI4_CFG_C.ARID_WIDTH_P - 1 : 0] arid,
    input longint unsigned                               addr,
    input int unsigned                                   beat_count
  );
    vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)           rd_seq;
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;

    fe0 = this.get_port_fe(0);

    rd_seq = vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)::type_id::create($sformatf(
      "reset_recovery_rd_seq_%0h_%0h_%0d",
      arid,
      addr,
      beat_count));
    rd_seq.reset();
    rd_seq.set_arid(arid);
    rd_seq.set_axaddr(addr);
    rd_seq.set_axlen(beat_count - 1);
    rd_seq.set_axsize(this.get_full_width_axi_size());
    rd_seq.set_axburst(VIP_MC_AXI4_BURST_INCR_C);
    rd_seq.set_axqos(4'h4);
    rd_seq.set_requests(1);
    rd_seq.set_get_rd_response(1'b0);
    this.start_seq_or_timeout(
      rd_seq,
      this._tb_env.man_agent[0].sequencer,
      fe0,
      0,
      rd_seq.get_name());
  endtask

  protected task pulse_reset_low(input time low_time = RESET_LOW_TIME_C);
    reset_sequence rst_seq;

    // Drive a mid-test reset pulse through the clk_rst agent; start() blocks
    // until rst_n is released again.
    rst_seq = reset_sequence::type_id::create("mid_test_rst_seq");
    rst_seq.set_rst_time(low_time);
    rst_seq.start(this._tb_env.clk_agent.sequencer);
  endtask

  task body();
    longint unsigned pre_reset_tag;
    longint unsigned post_reset_tag;
    rdata_t          post_reset_data;
    resp_t           post_reset_rresp;
    bit              pre_reset_rsp_seen;
    mc_reset_recovery_rsp_collector::rsp_t post_reset_rsp;

    this.wait_for_reset_release();
    this._grant.clear();
    this._dram_rsp.clear();
    this.clear_manager_observations();

    this.issue_read_no_wait('h1, 'h0400, PRE_RESET_BEATS_C);

    repeat (OBS_TIMEOUT_CYCLES_C) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if (this._grant.has_id('h1)) begin
        break;
      end
    end

    if (!this._grant.has_id('h1)) begin
      `uvm_fatal(get_name(), "Reset-recovery test did not observe the pre-reset read reach DRAM")
    end
    pre_reset_tag = this._grant.get_tag('h1);

    #1ns;
    this.pulse_reset_low();
    this.wait_for_reset_release();

    repeat (2) @(posedge this._tb_env._man_vif[0].clk);
    if ((this.rd_observations.size() != 0) || (this.wr_observations.size() != 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "Reset-recovery test saw %0d read and %0d write responses while resetting in-flight traffic",
        this.rd_observations.size(),
        this.wr_observations.size()))
    end

    this.axi4_read_single_on_port(0, 'h2, 4'h4, 'h0400, post_reset_data, post_reset_rresp);
    if (post_reset_rresp != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Reset-recovery test observed post-reset RRESP=%0b instead of OKAY",
        post_reset_rresp))
    end

    repeat (OBS_TIMEOUT_CYCLES_C) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if (this._grant.has_id('h2)) begin
        break;
      end
    end
    if (!this._grant.has_id('h2)) begin
      `uvm_fatal(get_name(), "Reset-recovery test did not observe the post-reset read reach DRAM")
    end
    post_reset_tag = this._grant.get_tag('h2);

    repeat (OBS_TIMEOUT_CYCLES_C) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if (this._dram_rsp.has_rsp(post_reset_tag)) begin
        break;
      end
    end
    if (!this._dram_rsp.has_rsp(post_reset_tag)) begin
      `uvm_fatal(get_name(), "Reset-recovery test did not capture the post-reset DRAM response")
    end

    pre_reset_rsp_seen = this._dram_rsp.has_rsp(pre_reset_tag);
    if (pre_reset_rsp_seen) begin
      `uvm_fatal(get_name(),
        "Reset-recovery test observed the cancelled pre-reset DRAM response after reset")
    end

    if (this.rd_observations.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Reset-recovery test observed %0d read responses instead of exactly 1 post-reset response",
        this.rd_observations.size()))
    end
    if (this.rd_observations[0].rid != 'h2) begin
      `uvm_fatal(get_name(), $sformatf(
        "Reset-recovery test observed RID=0x%0h instead of the post-reset RID=0x2",
        this.rd_observations[0].rid))
    end

    post_reset_rsp = this._dram_rsp.get_rsp(post_reset_tag);
    if (post_reset_rsp == null) begin
      `uvm_fatal(get_name(), "Reset-recovery test lost the captured post-reset DRAM response handle")
    end
    if ((post_reset_rsp.op != VIP_DRAM_OP_RD_E) ||
        !post_reset_rsp.was_page_empty ||
        post_reset_rsp.was_page_hit ||
        post_reset_rsp.was_page_miss) begin
      `uvm_fatal(get_name(),
        "Reset-recovery test expected the post-reset same-address read to be page-empty")
    end

    `uvm_info(get_name(),
      "vip_mc reset-recovery test passed (pre-reset response cancelled, post-reset same-address read re-opened an empty page)",
      UVM_LOW)
  endtask
endclass
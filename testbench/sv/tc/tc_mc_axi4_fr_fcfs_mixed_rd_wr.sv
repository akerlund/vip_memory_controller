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
// tc_mc_axi4_fr_fcfs_mixed_rd_wr
//
// Exercise the op-agnostic FR-FCFS selector with one older read miss and one
// younger write hit queued behind a one-entry device window held by a long
// dummy read. The write must be granted first when its predicted completion is
// earlier.
// -----------------------------------------------------------------------------

class mc_fr_fcfs_mixed_grant_collector extends uvm_subscriber #(vip_mc_cmd_entry #(DRAM_CFG_C));
  typedef vip_mc_cmd_entry #(DRAM_CFG_C) cmd_t;

  int              grant_op[$];
  longint unsigned grant_id[$];
  longint unsigned tag_by_id[longint unsigned];

  `uvm_component_utils(mc_fr_fcfs_mixed_grant_collector)

  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  function void write(input cmd_t t);
    if ((t == null) || ((t.op != VIP_DRAM_OP_RD_E) && (t.op != VIP_DRAM_OP_WR_E))) begin
      return;
    end

    this.grant_op.push_back(int'(t.op));
    this.grant_id.push_back(t.axi4_id);
    this.tag_by_id[t.axi4_id] = t.tag;
  endfunction

  function longint unsigned get_tag(input longint unsigned axi4_id);
    if (!this.tag_by_id.exists(axi4_id)) begin
      return '0;
    end
    return this.tag_by_id[axi4_id];
  endfunction

  function void clear();
    this.grant_op.delete();
    this.grant_id.delete();
    this.tag_by_id.delete();
  endfunction
endclass

class mc_fr_fcfs_mixed_rsp_collector extends uvm_subscriber #(vip_dram_rsp #(DRAM_CFG_C));
  typedef vip_dram_rsp #(DRAM_CFG_C) rsp_t;

  rsp_t rsp_by_tag[longint unsigned];

  `uvm_component_utils(mc_fr_fcfs_mixed_rsp_collector)

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

class tc_mc_axi4_fr_fcfs_mixed_rd_wr extends mc_base_test;

  `uvm_component_utils(tc_mc_axi4_fr_fcfs_mixed_rd_wr)

  localparam int              OBS_TIMEOUT_CYCLES_C = 1024;
  localparam int              DUMMY_BEATS_C        = 32;
  localparam longint unsigned DUMMY_ID_C           = 'h3;
  localparam longint unsigned MISS_RD_ID_C         = 'h1;
  localparam longint unsigned HIT_WR_ID_C          = 'h2;

  mc_fr_fcfs_mixed_grant_collector _grant;
  mc_fr_fcfs_mixed_rsp_collector   _dram_rsp;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(input uvm_phase phase);
    uvm_config_db #(int)::set(this, "env", "mc_refresh_enabled", 0);
    uvm_config_db #(int)::set(this, "env", "mc_honor_beat_timing", 0);
    uvm_config_db #(int)::set(this, "env", "mc_max_inflight_to_device", 1);
    uvm_config_db #(int)::set(this, "env", "mc_scoreboard_timing_check", 0);
    super.build_phase(phase);
    this._grant    = mc_fr_fcfs_mixed_grant_collector::type_id::create("grant", this);
    this._dram_rsp = mc_fr_fcfs_mixed_rsp_collector::type_id::create("dram_rsp", this);
  endfunction

  function void connect_phase(input uvm_phase phase);
    super.connect_phase(phase);
    this._tb_env.u_mc.backend.issued_port.connect(this._grant.analysis_export);
    this._tb_env.dram.rsp_port.connect(this._dram_rsp.analysis_export);
  endfunction

  protected function longint unsigned encode_addr(
    input int row,
    input int bg,
    input int bank,
    input int col = 0,
    input int byte_in_col = 0
  );
    vip_dram_dec_t dec;

    dec = '{default: 0};
    dec.rank        = 0;
    dec.row         = row;
    dec.bg          = bg;
    dec.bank        = bank;
    dec.col         = col;
    dec.byte_in_col = byte_in_col;
    return vip_dram_encode_addr(dec, DRAM_CFG_C, this._tb_env.u_mc.cfg.addr_map_policy);
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
      "frfcfs_mixed_rd_%0h_%0h_%0d",
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

  protected task issue_write_no_wait(
    input logic [VIP_MC_AXI4_CFG_C.AWID_WIDTH_P - 1 : 0] awid,
    input longint unsigned                               addr,
    input wdata_t                                        data_q[],
    input wstrb_t                                        strb_q[]
  );
    vip_axi4_write_seq #(VIP_AXI4_AGENT_CFG_C)          wr_seq;
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;
    vip_axi4_types #(VIP_AXI4_AGENT_CFG_C)::wdata_t      man_data_q[$];
    vip_axi4_types #(VIP_AXI4_AGENT_CFG_C)::wstrb_t      man_strb_q[$];

    fe0 = this.get_port_fe(0);

    foreach (data_q[beat_idx]) begin
      man_data_q.push_back(data_q[beat_idx]);
      man_strb_q.push_back(strb_q[beat_idx]);
    end

    wr_seq = vip_axi4_write_seq #(VIP_AXI4_AGENT_CFG_C)::type_id::create($sformatf(
      "frfcfs_mixed_wr_%0h_%0h_%0d",
      awid,
      addr,
      data_q.size()));
    wr_seq.reset();
    wr_seq.set_awid(awid);
    wr_seq.set_axaddr(addr);
    wr_seq.set_axlen(data_q.size() - 1);
    wr_seq.set_axsize(this.get_full_width_axi_size());
    wr_seq.set_axburst(VIP_AXI4_BURST_INCR_C);
    wr_seq.set_axqos(4'h4);
    wr_seq.set_requests(1);
    wr_seq.set_get_wr_response(1'b0);
    wr_seq.set_wdata_type(VIP_AXI4_DATA_CUSTOM_E);
    wr_seq.set_wstrb_type(VIP_AXI4_STRB_CUSTOM_E);
    wr_seq.set_wdata(man_data_q);
    wr_seq.set_wstrb(man_strb_q);
    this.start_seq_or_timeout(
      wr_seq,
      this._tb_env.man_agent[0].sequencer,
      fe0,
      0,
      wr_seq.get_name());
  endtask

  task body();
    longint unsigned dummy_addr;
    longint unsigned miss_seed_addr;
    longint unsigned miss_open_addr;
    longint unsigned hit_wr_addr;
    rdata_t          readback_data;
    wdata_t          hit_wr_data_q[];
    wstrb_t          hit_wr_strb_q[];
    wdata_t          miss_seed_data;
    wdata_t          miss_open_data;
    wdata_t          hit_seed_data;
    resp_t           bresp;
    resp_t           rresp;
    int              hit_wr_obs_idx;
    int              miss_obs_idx;
    mc_fr_fcfs_mixed_rsp_collector::rsp_t miss_rsp;
    mc_fr_fcfs_mixed_rsp_collector::rsp_t hit_wr_rsp;
    vip_dram_types #(DRAM_CFG_C)::data_t backdoor_data;

    this.wait_for_reset_release();
    this._tb_env.u_mc.cfg.fr_fcfs_enable = TRUE;

    dummy_addr     = this.encode_addr(.row(0), .bg(3), .bank(0));
    miss_seed_addr = this.encode_addr(.row(1), .bg(0), .bank(0));
    miss_open_addr = this.encode_addr(.row(0), .bg(0), .bank(0));
    hit_wr_addr    = this.encode_addr(.row(0), .bg(1), .bank(0));

    miss_seed_data = '0;
    miss_open_data = '0;
    hit_seed_data  = '0;
    for (int byte_idx = 0; byte_idx < VIP_MC_AXI4_CFG_C.WDATA_BYTES_P; byte_idx++) begin
      miss_seed_data[(8 * byte_idx) +: 8] = 8'h31 + byte_idx[7:0];
      miss_open_data[(8 * byte_idx) +: 8] = 8'h61 + byte_idx[7:0];
      hit_seed_data[(8 * byte_idx) +: 8]  = 8'h91 + byte_idx[7:0];
    end

    hit_wr_data_q = new[1];
    hit_wr_strb_q = new[1];
    hit_wr_data_q[0] = '0;
    hit_wr_strb_q[0] = '1;
    for (int byte_idx = 0; byte_idx < VIP_MC_AXI4_CFG_C.WDATA_BYTES_P; byte_idx++) begin
      hit_wr_data_q[0][(8 * byte_idx) +: 8] = 8'hD0 + byte_idx[7:0];
    end

    // Seed rows without turnaround history, then use reads to open the future
    // miss bank (row 0 active, row 1 seeded) and the future write-hit row.
    this._tb_env.dram.backdoor_write(miss_seed_addr, miss_seed_data);
    this._tb_env.dram.backdoor_write(miss_open_addr, miss_open_data);
    this._tb_env.dram.backdoor_write(hit_wr_addr, hit_seed_data);

    this.axi4_read_single(miss_open_addr, readback_data, rresp);
    if ((rresp != VIP_MC_AXI4_RESP_OKAY_C) || (readback_data !== miss_open_data)) begin
      `uvm_fatal(get_name(), "Mixed FR-FCFS setup read to open the future miss bank row failed")
    end
    this.axi4_read_single(hit_wr_addr, readback_data, rresp);
    if ((rresp != VIP_MC_AXI4_RESP_OKAY_C) || (readback_data !== hit_seed_data)) begin
      `uvm_fatal(get_name(), "Mixed FR-FCFS setup read to open the future write-hit row failed")
    end

    this._grant.clear();
    this._dram_rsp.clear();
    this.clear_manager_observations();

    // Occupy the one-deep device window with a long read, then queue an older
    // read miss and a younger write hit behind it.
    this.issue_read_no_wait(DUMMY_ID_C, dummy_addr, DUMMY_BEATS_C);
    this.issue_read_no_wait(MISS_RD_ID_C, miss_seed_addr, 1);
    this.issue_write_no_wait(HIT_WR_ID_C, hit_wr_addr, hit_wr_data_q, hit_wr_strb_q);

    repeat (OBS_TIMEOUT_CYCLES_C) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if ((this.wr_observations.size() >= 1) &&
          (this.rd_observations.size() >= 2) &&
          (this._grant.grant_id.size() >= 3)) begin
        break;
      end
    end

    if ((this.wr_observations.size() != 1) || (this.rd_observations.size() != 2)) begin
      `uvm_fatal(get_name(), "Mixed FR-FCFS test did not observe the expected write/read responses")
    end
    foreach (this.wr_observations[i]) begin
      if (this.wr_observations[i].bresp != VIP_MC_AXI4_RESP_OKAY_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "Mixed FR-FCFS test observed BRESP=%0b on write response %0d instead of OKAY",
          this.wr_observations[i].bresp,
          i))
      end
    end
    if (this.rd_observations[0].rresp != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Mixed FR-FCFS test observed RRESP=%0b instead of OKAY",
        this.rd_observations[0].rresp))
    end

    if ((this._grant.grant_id.size() < 3) ||
        (this._grant.grant_op[0] != int'(VIP_DRAM_OP_RD_E)) ||
        (this._grant.grant_op[1] != int'(VIP_DRAM_OP_WR_E)) ||
        (this._grant.grant_op[2] != int'(VIP_DRAM_OP_RD_E)) ||
        (this._grant.grant_id[0] != DUMMY_ID_C) ||
        (this._grant.grant_id[1] != HIT_WR_ID_C) ||
        (this._grant.grant_id[2] != MISS_RD_ID_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "Mixed FR-FCFS test expected grant order {RD:%0h, WR:%0h, RD:%0h}, saw first three {op=%0d id=%0h, op=%0d id=%0h, op=%0d id=%0h}",
        DUMMY_ID_C,
        HIT_WR_ID_C,
        MISS_RD_ID_C,
        (this._grant.grant_op.size() > 0) ? this._grant.grant_op[0] : -1,
        (this._grant.grant_id.size() > 0) ? this._grant.grant_id[0] : '1,
        (this._grant.grant_op.size() > 1) ? this._grant.grant_op[1] : -1,
        (this._grant.grant_id.size() > 1) ? this._grant.grant_id[1] : '1,
        (this._grant.grant_op.size() > 2) ? this._grant.grant_op[2] : -1,
        (this._grant.grant_id.size() > 2) ? this._grant.grant_id[2] : '1))
    end

    hit_wr_obs_idx = -1;
    miss_obs_idx   = -1;
    foreach (this.wr_observations[i]) begin
      if ((hit_wr_obs_idx < 0) && (this.wr_observations[i].bid == HIT_WR_ID_C)) begin
        hit_wr_obs_idx = i;
      end
    end
    foreach (this.rd_observations[i]) begin
      if ((miss_obs_idx < 0) && (this.rd_observations[i].rid == MISS_RD_ID_C)) begin
        miss_obs_idx = i;
      end
    end
    if (hit_wr_obs_idx < 0) begin
      `uvm_fatal(get_name(), "Mixed FR-FCFS test did not observe the hit-write BRESP")
    end
    if (miss_obs_idx < 0) begin
      `uvm_fatal(get_name(), "Mixed FR-FCFS test did not observe the miss read response")
    end
    if (this.wr_observation_times[hit_wr_obs_idx] >= this.rd_observation_times[miss_obs_idx]) begin
      `uvm_fatal(get_name(), $sformatf(
        "Mixed FR-FCFS test expected write-hit BRESP before read-miss R completion, saw B at %0t and R at %0t",
        this.wr_observation_times[hit_wr_obs_idx],
        this.rd_observation_times[miss_obs_idx]))
    end

    miss_rsp   = this._dram_rsp.get_rsp(this._grant.get_tag(MISS_RD_ID_C));
    hit_wr_rsp = this._dram_rsp.get_rsp(this._grant.get_tag(HIT_WR_ID_C));
    if ((miss_rsp == null) || (hit_wr_rsp == null)) begin
      `uvm_fatal(get_name(), "Mixed FR-FCFS test did not capture the miss/hit DRAM responses")
    end
    if ((hit_wr_rsp.op != VIP_DRAM_OP_WR_E) ||
        !hit_wr_rsp.was_page_hit || hit_wr_rsp.was_page_miss || hit_wr_rsp.was_page_empty) begin
      `uvm_fatal(get_name(), "Mixed FR-FCFS test expected the younger write to be a page hit")
    end
    if ((miss_rsp.op != VIP_DRAM_OP_RD_E) ||
        !miss_rsp.was_page_miss || miss_rsp.was_page_hit || miss_rsp.was_page_empty) begin
      `uvm_fatal(get_name(), "Mixed FR-FCFS test expected the older read to be a page miss")
    end
    if (hit_wr_rsp.last_beat_ready_time >= miss_rsp.last_beat_ready_time) begin
      `uvm_fatal(get_name(), $sformatf(
        "Mixed FR-FCFS test expected write-hit completion (%0.3fns) before read-miss completion (%0.3fns)",
        hit_wr_rsp.last_beat_ready_time,
        miss_rsp.last_beat_ready_time))
    end

    backdoor_data = this._tb_env.dram.backdoor_read(hit_wr_addr);
    if (backdoor_data !== hit_wr_data_q[0]) begin
      `uvm_fatal(get_name(), "Mixed FR-FCFS test hit write did not update memory as expected")
    end

    `uvm_info(get_name(),
      "vip_mc AXI4 mixed RD/WR FR-FCFS test passed (younger write hit granted ahead of older read miss)",
      UVM_LOW)
  endtask
endclass
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
// tc_vip_mc_axi4_ooo_inter_id
//
// Exercise the backend's FR-FCFS tie-break by holding the device window full
// with one in-flight read, queueing an older page miss and a younger page hit
// behind it, then proving the hit is granted and completed first once issue
// credit returns.
// -----------------------------------------------------------------------------

class mc_ooo_inter_id_grant_collector extends uvm_subscriber #(vip_mc_cmd_entry #(DRAM_CFG_C));
  typedef vip_mc_cmd_entry #(DRAM_CFG_C) cmd_t;

  longint unsigned grant_id_q[$];
  longint unsigned tag_by_id[longint unsigned];

  `uvm_component_utils(mc_ooo_inter_id_grant_collector)

  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  function void write(input cmd_t t);
    if ((t == null) || (t.op != VIP_DRAM_OP_RD_E)) begin
      return;
    end

    this.grant_id_q.push_back(t.axi4_id);
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
    this.grant_id_q.delete();
    this.tag_by_id.delete();
  endfunction
endclass

class mc_ooo_inter_id_rsp_collector extends uvm_subscriber #(vip_dram_rsp #(DRAM_CFG_C));
  typedef vip_dram_rsp #(DRAM_CFG_C) rsp_t;

  rsp_t rsp_by_tag[longint unsigned];

  `uvm_component_utils(mc_ooo_inter_id_rsp_collector)

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

class tc_vip_mc_axi4_ooo_inter_id extends vip_mc_base_test;

  `uvm_component_utils(tc_vip_mc_axi4_ooo_inter_id)

  localparam int              OBS_TIMEOUT_CYCLES_C = 1024;
  localparam int              DUMMY_BEATS_C        = 16;
  localparam longint unsigned DUMMY_ID_C           = 'h3;
  localparam longint unsigned MISS_ID_C            = 'h1;
  localparam longint unsigned HIT_ID_C             = 'h2;

  mc_ooo_inter_id_grant_collector _grant;
  mc_ooo_inter_id_rsp_collector   _dram_rsp;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(input uvm_phase phase);
    uvm_config_db #(int)::set(this, "env", "mc_refresh_enabled", 0);
    uvm_config_db #(int)::set(this, "env", "mc_honor_beat_timing", 0);
    uvm_config_db #(int)::set(this, "env", "mc_max_inflight_to_device", 1);
    uvm_config_db #(int)::set(this, "env", "mc_scoreboard_timing_check", 0);
    super.build_phase(phase);
    this._grant    = mc_ooo_inter_id_grant_collector::type_id::create("grant", this);
    this._dram_rsp = mc_ooo_inter_id_rsp_collector::type_id::create("dram_rsp", this);
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
      "ooo_inter_id_rd_%0h_%0h_%0d",
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

  task body();
    longint unsigned dummy_addr;
    longint unsigned miss_seed_addr;
    longint unsigned miss_open_addr;
    longint unsigned hit_addr;
    rdata_t          readback_data;
    wdata_t          miss_seed_data;
    wdata_t          miss_open_data;
    wdata_t          hit_seed_data;
    resp_t           bresp;
    resp_t           rresp;
    int              miss_obs_idx;
    int              hit_obs_idx;
    mc_ooo_inter_id_rsp_collector::rsp_t miss_rsp;
    mc_ooo_inter_id_rsp_collector::rsp_t hit_rsp;

    this.wait_for_reset_release();
    this._tb_env.u_mc.cfg.fr_fcfs_enable = TRUE;

    dummy_addr     = this.encode_addr(.row(0), .bg(3), .bank(0));
    miss_seed_addr = this.encode_addr(.row(1), .bg(0), .bank(0));
    miss_open_addr = this.encode_addr(.row(0), .bg(0), .bank(0));
    hit_addr       = this.encode_addr(.row(0), .bg(1), .bank(0));

    miss_seed_data = '0;
    miss_open_data = '0;
    hit_seed_data  = '0;
    for (int byte_idx = 0; byte_idx < VIP_MC_AXI4_CFG_C.WDATA_BYTES_P; byte_idx++) begin
      miss_seed_data[(8 * byte_idx) +: 8] = 8'h31 + byte_idx[7:0];
      miss_open_data[(8 * byte_idx) +: 8] = 8'h61 + byte_idx[7:0];
      hit_seed_data[(8 * byte_idx) +: 8]  = 8'h91 + byte_idx[7:0];
    end

    // Seed the rows without creating bus-turnaround history, then use reads to
    // establish one open row for the future miss bank and one open row for the
    // future hit bank.
    this._tb_env.dram.backdoor_write(miss_seed_addr, miss_seed_data);
    this._tb_env.dram.backdoor_write(miss_open_addr, miss_open_data);
    this._tb_env.dram.backdoor_write(hit_addr, hit_seed_data);

    this.axi4_read_single(miss_open_addr, readback_data, rresp);
    if ((rresp != VIP_MC_AXI4_RESP_OKAY_C) || (readback_data !== miss_open_data)) begin
      `uvm_fatal(get_name(), "OoO inter-ID setup read to open the future miss bank row failed")
    end
    this.axi4_read_single(hit_addr, readback_data, rresp);
    if ((rresp != VIP_MC_AXI4_RESP_OKAY_C) || (readback_data !== hit_seed_data)) begin
      `uvm_fatal(get_name(), "OoO inter-ID setup read to open the future hit row failed")
    end

    this._grant.clear();
    this._dram_rsp.clear();
    this.clear_manager_observations();

    // Occupy the one-deep device window, then queue the miss and hit behind it.
    this.issue_read_no_wait(DUMMY_ID_C, dummy_addr, DUMMY_BEATS_C);
    this.issue_read_no_wait(MISS_ID_C, miss_seed_addr, 1);
    this.issue_read_no_wait(HIT_ID_C, hit_addr, 1);

    repeat (OBS_TIMEOUT_CYCLES_C) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if ((this.rd_observations.size() >= 3) &&
          this._grant.has_id(MISS_ID_C) &&
          this._grant.has_id(HIT_ID_C)  &&
          this._grant.has_id(DUMMY_ID_C)) begin
        break;
      end
    end

    if (this.rd_observations.size() != 3) begin
      `uvm_fatal(get_name(), "OoO inter-ID test did not observe all three read responses")
    end
    foreach (this.rd_observations[i]) begin
      if (this.rd_observations[i].rresp != VIP_MC_AXI4_RESP_OKAY_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "OoO inter-ID test observed RRESP=%0b on response %0d instead of OKAY",
          this.rd_observations[i].rresp,
          i))
      end
    end

    if ((this._grant.grant_id_q.size() < 3) ||
        (this._grant.grant_id_q[0] != DUMMY_ID_C) ||
        (this._grant.grant_id_q[1] != HIT_ID_C) ||
        (this._grant.grant_id_q[2] != MISS_ID_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "OoO inter-ID test expected grant order {%0h,%0h,%0h}, saw first three {%0h,%0h,%0h}",
        DUMMY_ID_C,
        HIT_ID_C,
        MISS_ID_C,
        (this._grant.grant_id_q.size() > 0) ? this._grant.grant_id_q[0] : '1,
        (this._grant.grant_id_q.size() > 1) ? this._grant.grant_id_q[1] : '1,
        (this._grant.grant_id_q.size() > 2) ? this._grant.grant_id_q[2] : '1))
    end

    hit_obs_idx  = -1;
    miss_obs_idx = -1;
    foreach (this.rd_observations[i]) begin
      if ((hit_obs_idx < 0) && (this.rd_observations[i].rid == HIT_ID_C)) begin
        hit_obs_idx = i;
      end
      if ((miss_obs_idx < 0) && (this.rd_observations[i].rid == MISS_ID_C)) begin
        miss_obs_idx = i;
      end
    end
    if ((hit_obs_idx < 0) || (miss_obs_idx < 0)) begin
      `uvm_fatal(get_name(), "OoO inter-ID test did not observe both miss and hit IDs on the R channel")
    end
    if (hit_obs_idx >= miss_obs_idx) begin
      `uvm_fatal(get_name(), $sformatf(
        "OoO inter-ID test expected the hit response before the miss response, saw hit index %0d miss index %0d",
        hit_obs_idx,
        miss_obs_idx))
    end

    miss_rsp = this._dram_rsp.get_rsp(this._grant.get_tag(MISS_ID_C));
    hit_rsp  = this._dram_rsp.get_rsp(this._grant.get_tag(HIT_ID_C));
    if ((miss_rsp == null) || (hit_rsp == null)) begin
      `uvm_fatal(get_name(), "OoO inter-ID test did not capture the miss/hit DRAM responses")
    end
    if (!miss_rsp.was_page_miss || miss_rsp.was_page_hit || miss_rsp.was_page_empty) begin
      `uvm_fatal(get_name(), "OoO inter-ID test expected ARID 0x1 to be a page miss")
    end
    if (!hit_rsp.was_page_hit || hit_rsp.was_page_miss || hit_rsp.was_page_empty) begin
      `uvm_fatal(get_name(), "OoO inter-ID test expected ARID 0x2 to be a page hit")
    end
    if (hit_rsp.last_beat_ready_time >= miss_rsp.last_beat_ready_time) begin
      `uvm_fatal(get_name(), $sformatf(
        "OoO inter-ID test expected hit completion (%0.3fns) before miss completion (%0.3fns)",
        hit_rsp.last_beat_ready_time,
        miss_rsp.last_beat_ready_time))
    end

    // The younger hit retired before the older miss, so the §11 observed-OoO
    // counter must have recorded at least one out-of-order retirement.
    if (this._tb_env.u_mc.get_observed_reorder_count() < 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "OoO inter-ID test expected observed_reorder_count >= 1, got %0d",
        this._tb_env.u_mc.get_observed_reorder_count()))
    end

    `uvm_info(get_name(), $sformatf(
      "vip_mc AXI4 OoO inter-ID test passed (FR-FCFS granted the later hit ahead of the older miss, observed_reorder_count=%0d)",
      this._tb_env.u_mc.get_observed_reorder_count()),
      UVM_LOW)
  endtask
endclass
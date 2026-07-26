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
// tc_mc_fr_fcfs_starvation_cap
//
// Exercises the §11 item-1 FR-FCFS starvation cap. Pure FR-FCFS is readiness
// first, so an older page miss queued behind a stream of younger page hits to an
// open row is reordered past indefinitely (the tc_mc_axi4_page_hit_streak
// weakness). With cfg.fr_fcfs_starvation_cap = CAP, an eligible entry may be
// bypassed at most CAP times before the backend force-serves it.
//
// The device window is held to one in-flight request with a long dummy read;
// behind it an OLD miss and several YOUNGER hits are queued. Once credit returns
// the selector grants exactly CAP hits, then is forced to grant the old miss
// (before the remaining hits), and get_fr_fcfs_forced_count() advances.
// -----------------------------------------------------------------------------
class tc_mc_fr_fcfs_starvation_cap extends mc_base_test;

  `uvm_component_utils(tc_mc_fr_fcfs_starvation_cap)

  localparam int              OBS_TIMEOUT_CYCLES_C = 2048;
  localparam int              DUMMY_BEATS_C        = 32;
  localparam int              CAP_C                = 2;
  localparam int              N_HITS_C             = 5;   // > CAP so starvation is real
  localparam longint unsigned DUMMY_ID_C           = 'h3;
  localparam longint unsigned MISS_ID_C            = 'h1;
  localparam longint unsigned HIT_ID_BASE_C        = 'h10;

  mc_ooo_inter_id_grant_collector _grant;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(input uvm_phase phase);
    uvm_config_db #(int)::set(this, "env", "mc_refresh_enabled", 0);
    uvm_config_db #(int)::set(this, "env", "mc_honor_beat_timing", 0);
    uvm_config_db #(int)::set(this, "env", "mc_max_inflight_to_device", 1);
    uvm_config_db #(int)::set(this, "env", "mc_scoreboard_timing_check", 0);
    super.build_phase(phase);
    this._grant = mc_ooo_inter_id_grant_collector::type_id::create("grant", this);
  endfunction

  function void connect_phase(input uvm_phase phase);
    super.connect_phase(phase);
    this._tb_env.u_mc.backend.issued_port.connect(this._grant.analysis_export);
  endfunction

  protected function longint unsigned encode_addr(
    input int row,
    input int bg,
    input int bank,
    input int col = 0
  );
    vip_dram_dec_t dec;
    dec = '{default: 0};
    dec.row  = row;
    dec.bg   = bg;
    dec.bank = bank;
    dec.col  = col;
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
      "cap_rd_%0h_%0h", arid, addr));
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
      rd_seq, this._tb_env.man_agent[0].sequencer, fe0, 0, rd_seq.get_name());
  endtask

  task body();
    longint unsigned dummy_addr;
    longint unsigned miss_seed_addr;
    longint unsigned miss_open_addr;
    longint unsigned hit_open_addr;
    longint unsigned hit_addr[N_HITS_C];
    rdata_t          readback_data;
    resp_t           rresp;
    int              expected_grants;
    int              miss_pos;
    int              hits_before_miss;

    this.wait_for_reset_release();
    this._tb_env.u_mc.cfg.fr_fcfs_enable         = TRUE;
    this._tb_env.u_mc.cfg.fr_fcfs_starvation_cap = CAP_C;

    dummy_addr     = this.encode_addr(.row(0), .bg(3), .bank(0));
    miss_seed_addr = this.encode_addr(.row(1), .bg(0), .bank(0));
    miss_open_addr = this.encode_addr(.row(0), .bg(0), .bank(0));
    hit_open_addr  = this.encode_addr(.row(0), .bg(1), .bank(0), .col(0));
    for (int i = 0; i < N_HITS_C; i++) begin
      hit_addr[i] = this.encode_addr(.row(0), .bg(1), .bank(0), .col(i));
    end

    // Open the future-miss bank on row 0 (so a later read to row 1 misses), and
    // open the hit row so every hit read is a page hit.
    this.axi4_read_single(miss_open_addr, readback_data, rresp);
    this.axi4_read_single(hit_open_addr,  readback_data, rresp);

    this._grant.clear();
    this.clear_manager_observations();

    // Hold the one-deep device window with a long dummy, then queue the old miss
    // and the younger hit streak behind it.
    this.issue_read_no_wait(DUMMY_ID_C, dummy_addr, DUMMY_BEATS_C);
    this.issue_read_no_wait(MISS_ID_C, miss_seed_addr, 1);
    for (int i = 0; i < N_HITS_C; i++) begin
      this.issue_read_no_wait(HIT_ID_BASE_C + i, hit_addr[i], 1);
    end

    expected_grants = 1 /*dummy*/ + 1 /*miss*/ + N_HITS_C;
    repeat (OBS_TIMEOUT_CYCLES_C) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if (this._grant.grant_id_q.size() >= expected_grants) begin
        break;
      end
    end

    if (this._grant.grant_id_q.size() < expected_grants) begin
      `uvm_fatal(get_name(), $sformatf(
        "Starvation-cap test saw only %0d of %0d grants",
        this._grant.grant_id_q.size(), expected_grants))
    end

    // The dummy is granted first (it occupied the window before the backlog).
    if (this._grant.grant_id_q[0] != DUMMY_ID_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Starvation-cap test expected the dummy granted first, saw 0x%0h",
        this._grant.grant_id_q[0]))
    end

    // Locate the old miss in the grant order and count how many hits preceded it.
    miss_pos         = -1;
    hits_before_miss = 0;
    foreach (this._grant.grant_id_q[i]) begin
      if (i == 0) continue;  // skip the dummy
      if (this._grant.grant_id_q[i] == MISS_ID_C) begin
        miss_pos = i;
        break;
      end
      hits_before_miss++;
    end

    if (miss_pos < 0) begin
      `uvm_fatal(get_name(), "Starvation-cap test never granted the old miss")
    end
    // Pure FR-FCFS would let all N_HITS precede the miss; the cap must bound it to
    // exactly CAP hits before the miss is force-served.
    if (hits_before_miss != CAP_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Starvation-cap test expected exactly %0d hits before the forced miss, saw %0d",
        CAP_C, hits_before_miss))
    end
    if (this._tb_env.u_mc.get_fr_fcfs_forced_count() < 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Starvation-cap test expected fr_fcfs_forced_count >= 1, got %0d",
        this._tb_env.u_mc.get_fr_fcfs_forced_count()))
    end

    // Drain: let every fire-and-forget read return on the R channel before the
    // test ends, else the manager monitor flags outstanding responses.
    repeat (OBS_TIMEOUT_CYCLES_C) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if (this.rd_observations.size() >= expected_grants) begin
        break;
      end
    end
    if (this.rd_observations.size() < expected_grants) begin
      `uvm_fatal(get_name(), $sformatf(
        "Starvation-cap test: only %0d of %0d reads drained on R",
        this.rd_observations.size(), expected_grants))
    end

    `uvm_info(get_name(), $sformatf(
      "vip_mc FR-FCFS starvation-cap test passed (cap=%0d, %0d hits before the forced miss, forced_count=%0d)",
      CAP_C, hits_before_miss, this._tb_env.u_mc.get_fr_fcfs_forced_count()), UVM_LOW)
  endtask
endclass

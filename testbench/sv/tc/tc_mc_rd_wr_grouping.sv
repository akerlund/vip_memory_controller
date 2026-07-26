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
// tc_mc_rd_wr_grouping
//
// Turnaround-aware read/write grouping (§11 item 1). With cfg.rd_wr_grouping_enable
// the within-class FR-FCFS selector prefers the eligible candidate whose bus
// direction matches the last issued command's, so reads and writes issue in runs
// that amortize the device read/write turnaround bubble (tWTR/tRTW) instead of
// paying it on every RD<->WR flip.
//
// The proof is constructed so pure FR-FCFS and grouping provably DISAGREE: with a
// read as the last issued command, the backlog holds two cheap WRITE page-hits (a
// pre-opened row, ~tRTW+tWL) and four expensive READ page-misses (fresh banks
// needing an ACT, ~tRCD+tCL). Pure readiness-first would grant the cheaper writes
// FIRST (flipping direction); grouping instead keeps draining the reads — the more
// expensive but same-direction work — before either write. Observing every read
// granted before any write therefore cannot be produced by the baseline selector;
// only grouping yields it.
//
// A window-holding read holds the depth-1 device window while the whole backlog is
// admitted (one pipelined vip_axi4 sequence, so the writes stay outstanding at the
// manager). Asserts: reads form a contiguous prefix of the grant order (no read
// after the first write), get_rd_wr_grouped_count() advanced (grouping overrode the
// readiness winner), and exactly one RD->WR bus turnaround occurred.
// -----------------------------------------------------------------------------

// Records the RD/WR direction of every non-REF device grant in issue order.
class mc_rd_wr_grant_collector extends uvm_subscriber #(vip_mc_cmd_entry #(DRAM_CFG_C));
  typedef vip_mc_cmd_entry #(DRAM_CFG_C) cmd_t;

  bit dir_is_read_q[$];   // grant order: 1 = RD, 0 = WR (REF excluded)

  `uvm_component_utils(mc_rd_wr_grant_collector)

  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  function void write(input cmd_t t);
    if ((t == null) || (t.op == VIP_DRAM_OP_REF_E)) begin
      return;
    end
    this.dir_is_read_q.push_back(t.op == VIP_DRAM_OP_RD_E);
  endfunction

  function void clear();
    this.dir_is_read_q.delete();
  endfunction
endclass

class tc_mc_rd_wr_grouping extends mc_base_test;

  `uvm_component_utils(tc_mc_rd_wr_grouping)

  localparam int              N_RD_C           = 4;    // expensive read page-misses (same dir)
  localparam int              N_WR_C           = 2;    // cheap write page-hits (opposite dir)
  localparam int              DUMMY_BEATS_C    = 32;   // window-holding read (admit-time budget)
  localparam int              WR_OUTSTANDING_C = 16;   // manager pipelined rd/wr depth
  localparam int              DRAIN_CYCLES_C   = 8192;
  localparam longint unsigned HOLD_ID_C        = 'h3F;
  localparam longint unsigned RD_ID_BASE_C     = 'h10;
  localparam longint unsigned WR_ID_BASE_C     = 'h20;

  typedef vip_axi4_item          #(VIP_AXI4_AGENT_CFG_C) man_item_t;
  typedef vip_axi4_pipelined_seq #(VIP_AXI4_AGENT_CFG_C) pl_seq_t;

  mc_rd_wr_grant_collector _grant;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(input uvm_phase phase);
    uvm_config_db #(int)::set(this, "env", "mc_refresh_enabled", 0);
    uvm_config_db #(int)::set(this, "env", "mc_honor_beat_timing", 0);
    uvm_config_db #(int)::set(this, "env", "mc_max_inflight_to_device", 1);
    uvm_config_db #(int)::set(this, "env", "mc_scoreboard_enabled", 0);
    // Widen the write-data staging so the whole write backlog can sit admitted in
    // the cmd queue at once (default 4 is too shallow for N_C co-resident writes).
    uvm_config_db #(int)::set(this, "env", "mc_w_data_buf_depth", 32);
    // Let the stock manager keep the whole mixed backlog outstanding (pipelined
    // read AND write paths) so every request is co-resident in the cmd queue when
    // the selector picks — otherwise requests trickle in and grouping only sees a
    // couple of candidates at a time.
    uvm_config_db #(int)::set(this, "env", "man_wr_outstanding_max", WR_OUTSTANDING_C);
    uvm_config_db #(int)::set(this, "env", "man_rd_outstanding_max", WR_OUTSTANDING_C);
    super.build_phase(phase);
    this._grant = mc_rd_wr_grant_collector::type_id::create("grant", this);
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
    dec.rank = 0;
    dec.row  = row;
    dec.bg   = bg;
    dec.bank = bank;
    dec.col  = col;
    return vip_dram_encode_addr(dec, DRAM_CFG_C, this._tb_env.u_mc.cfg.addr_map_policy);
  endfunction

  // Fire-and-forget read item (no R-channel wait) at addr for beat_count beats.
  protected function man_item_t make_read(
    input string           name,
    input longint unsigned arid,
    input longint unsigned addr,
    input int              beat_count
  );
    man_item_t rd;
    rd = man_item_t::type_id::create(name);
    rd.set_access(VIP_AXI4_RD_REQUEST_E);
    rd.set_rd_rsp(vip_mem_types_pkg::FALSE);
    rd.arid    = arid;
    rd.araddr  = addr;
    rd.arlen   = beat_count - 1;
    rd.arsize  = this.get_full_width_axi_size();
    rd.arburst = VIP_MC_AXI4_BURST_INCR_C;
    return rd;
  endfunction

  // Single-beat full-line write item (collect BRESP) at addr.
  protected function man_item_t make_write(
    input string           name,
    input longint unsigned awid,
    input longint unsigned addr
  );
    man_item_t wr;
    wr = man_item_t::type_id::create(name);
    wr.set_access(VIP_AXI4_WR_REQUEST_E);
    wr.set_wr_rsp(vip_mem_types_pkg::TRUE);
    wr.awid    = awid;
    wr.awaddr  = addr;
    wr.awlen   = 0;
    wr.awsize  = this.get_full_width_axi_size();
    wr.awburst = VIP_MC_AXI4_BURST_INCR_C;
    wr.wdata   = new[1];
    wr.wstrb   = new[1];
    wr.wdata[0] = '0;
    wr.wstrb[0] = '1;
    return wr;
  endfunction

  task body();
    pl_seq_t         seq;
    man_item_t       wr_rsps[$];
    longint unsigned wr_row_addr;
    rdata_t          readback;
    resp_t           rresp;
    bit              seen_write;
    bit              reads_grouped_ahead;
    int              n_rd;
    int              n_wr;

    this.wait_for_reset_release();
    // Grouping is a refinement OF FR-FCFS, so both must be on.
    this._tb_env.u_mc.cfg.fr_fcfs_enable        = TRUE;
    this._tb_env.u_mc.cfg.rd_wr_grouping_enable = TRUE;

    // Pre-open the write-hit row (bg1,bank0,row0) with a blocking read; this also
    // establishes the last issued direction as READ before the backlog is picked.
    wr_row_addr = this.encode_addr(.row(0), .bg(1), .bank(0));
    this.axi4_read_single(wr_row_addr, readback, rresp);

    this._grant.clear();
    this.clear_manager_observations();

    // One pipelined sequence carries the whole backlog behind a window-holding
    // read. The cheap write page-hits are admitted BEFORE the expensive read
    // page-misses, so "all reads before all writes" in GRANT order is a genuine
    // reorder against both admit order and readiness (writes are cheaper).
    seq = pl_seq_t::type_id::create("grouping_pl_seq");
    seq.add_item(this.make_read("hold_rd", HOLD_ID_C,
      this.encode_addr(.row(0), .bg(3), .bank(0)), DUMMY_BEATS_C));
    for (int i = 0; i < N_WR_C; i++) begin
      // Cheap write page-hit: pre-opened bg1/bank0/row0, distinct column + AWID.
      seq.add_item(this.make_write($sformatf("wr_%0d", i), WR_ID_BASE_C + i,
        this.encode_addr(.row(0), .bg(1), .bank(0), .col(i))));
    end
    for (int i = 0; i < N_RD_C; i++) begin
      // Expensive read page-miss: a fresh (never-opened) bank in bg2 needing an ACT.
      seq.add_item(this.make_read($sformatf("rd_%0d", i), RD_ID_BASE_C + i,
        this.encode_addr(.row(0), .bg(2), .bank(i)), 1));
    end
    seq.set_pipelined_send(vip_mem_types_pkg::TRUE);
    seq.set_collect_wr_responses(vip_mem_types_pkg::TRUE);
    seq.start(this._tb_env.man_agent[0].sequencer);

    // Let the device drain the whole backlog and the R beats finish on the bus.
    for (int c = 0; c < DRAIN_CYCLES_C; c++) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if ((this._tb_env.u_mc.backend.get_inflight_to_device() == 0) &&
          (this._tb_env.u_mc.backend.get_cmd_queue_depth() == 0)) begin
        break;
      end
    end
    repeat (DUMMY_BEATS_C + 64) @(posedge this._tb_env._man_vif[0].clk);

    // Every write must complete OKAY (fan-out to the host).
    wr_rsps = seq.wr_responses;
    if (wr_rsps.size() != N_WR_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Expected %0d write completions, got %0d", N_WR_C, wr_rsps.size()))
    end
    foreach (wr_rsps[i]) begin
      if (wr_rsps[i].bresp != VIP_MC_AXI4_RESP_OKAY_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "Grouping write %0d returned BRESP=%0b instead of OKAY", i, wr_rsps[i].bresp))
      end
    end

    // Grant-order proof: reads form a contiguous prefix (no read after the first
    // write). Under pure FR-FCFS the cheaper write hits would have been granted
    // before the read misses, so this ordering is only achievable via grouping.
    seen_write          = 1'b0;
    reads_grouped_ahead = 1'b1;
    n_rd                = 0;
    n_wr                = 0;
    foreach (this._grant.dir_is_read_q[i]) begin
      if (this._grant.dir_is_read_q[i]) begin
        n_rd++;
        if (seen_write) begin
          reads_grouped_ahead = 1'b0;   // a read was granted after a write => not grouped
        end
      end
      else begin
        n_wr++;
        seen_write = 1'b1;
      end
    end

    if (this._grant.dir_is_read_q.size() != (N_RD_C + N_WR_C + 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "Expected %0d device grants (1 hold + %0d reads + %0d writes), saw %0d",
        N_RD_C + N_WR_C + 1, N_RD_C, N_WR_C, this._grant.dir_is_read_q.size()))
    end
    if ((n_rd != (N_RD_C + 1)) || (n_wr != N_WR_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "Grant mix off: reads=%0d (exp %0d) writes=%0d (exp %0d)",
        n_rd, N_RD_C + 1, n_wr, N_WR_C))
    end
    if (!reads_grouped_ahead) begin
      `uvm_fatal(get_name(),
        "Grouping failed: a read was granted after a write (directions not grouped)")
    end

    // Grouping must have actually overridden the readiness winner at least once
    // (each deferred write-hit was the cheaper candidate), and the whole run must
    // show exactly one RD->WR bus turnaround.
    if (this._tb_env.u_mc.get_rd_wr_grouped_count() < 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Expected rd_wr_grouped_count >= 1, got %0d",
        this._tb_env.u_mc.get_rd_wr_grouped_count()))
    end
    if (this._tb_env.u_mc.get_bus_turnaround_count() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Expected exactly 1 RD<->WR bus turnaround, got %0d",
        this._tb_env.u_mc.get_bus_turnaround_count()))
    end

    `uvm_info(get_name(), $sformatf(
      {"vip_mc read/write grouping test passed (%0d reads drained before %0d writes; ",
       "grouped_count=%0d, bus_turnaround_count=%0d)"},
      N_RD_C, N_WR_C, this._tb_env.u_mc.get_rd_wr_grouped_count(),
      this._tb_env.u_mc.get_bus_turnaround_count()), UVM_LOW)
  endtask
endclass

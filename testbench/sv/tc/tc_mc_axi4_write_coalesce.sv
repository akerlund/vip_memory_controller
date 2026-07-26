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
// tc_mc_axi4_write_coalesce
//
// Write coalescing (§11). Two host writes on the SAME AXI4 stream ({port, AWID})
// to the SAME row-word address are merged into ONE device access when
// cfg.write_coalescing_enable is set. This needs two writes co-pending in the
// cmd queue, which needs a manager that can hold >1 write outstanding — so this
// test sets man_wr_outstanding_max > 1 (the pipelined vip_axi4 write path) and
// drives everything from one vip_axi4_pipelined_seq: a short chain of page-miss
// reads holds the depth-1 device window while the two writes are admitted and
// coalesced, then the merged write issues once. The test proves:
//   * exactly one WR reaches the device (one write grant on issued_port),
//   * both host writes still get their own OKAY BRESP (completion fan-out),
//   * the merged line is the correct per-byte overlay (older bytes kept where the
//     newer write did not strobe, newer bytes where it did),
//   * the backend's coalesced-write counter advanced by exactly one.
// The timing scoreboard is coalescing-unaware (one device access, two host
// completions), so it is disabled for this test.
// -----------------------------------------------------------------------------

class mc_write_coalesce_grant_collector extends uvm_subscriber #(vip_mc_cmd_entry #(DRAM_CFG_C));
  typedef vip_mc_cmd_entry #(DRAM_CFG_C) cmd_t;

  int rd_grants = 0;
  int wr_grants = 0;

  `uvm_component_utils(mc_write_coalesce_grant_collector)

  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  function void write(input cmd_t t);
    if (t == null) begin
      return;
    end
    if (t.op == VIP_DRAM_OP_RD_E) begin
      this.rd_grants++;
    end
    else if (t.op == VIP_DRAM_OP_WR_E) begin
      this.wr_grants++;
    end
  endfunction

  function void clear();
    this.rd_grants = 0;
    this.wr_grants = 0;
  endfunction
endclass

class tc_mc_axi4_write_coalesce extends mc_base_test;

  `uvm_component_utils(tc_mc_axi4_write_coalesce)

  localparam int              DUMMY_BEATS_C   = 16;
  localparam int              N_HOLD_C        = 4;   // chained window-holding reads
  localparam int              WR_OUTSTANDING_C = 4;
  localparam longint unsigned DUMMY_ID_C      = 'h3;
  localparam longint unsigned WR_ID_C         = 'h2;

  typedef vip_axi4_item         #(VIP_AXI4_AGENT_CFG_C) man_item_t;
  typedef vip_axi4_pipelined_seq #(VIP_AXI4_AGENT_CFG_C) pl_seq_t;

  mc_write_coalesce_grant_collector _grant;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(input uvm_phase phase);
    uvm_config_db #(int)::set(this, "env", "mc_refresh_enabled", 0);
    uvm_config_db #(int)::set(this, "env", "mc_honor_beat_timing", 0);
    uvm_config_db #(int)::set(this, "env", "mc_max_inflight_to_device", 1);
    uvm_config_db #(int)::set(this, "env", "mc_scoreboard_enabled", 0);
    // Let the stock manager keep several writes outstanding (pipelined write path).
    uvm_config_db #(int)::set(this, "env", "man_wr_outstanding_max", WR_OUTSTANDING_C);
    super.build_phase(phase);
    this._grant = mc_write_coalesce_grant_collector::type_id::create("grant", this);
  endfunction

  function void connect_phase(input uvm_phase phase);
    super.connect_phase(phase);
    this._tb_env.u_mc.backend.issued_port.connect(this._grant.analysis_export);
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

  // Build a page-miss read item that only holds the device window (no response).
  protected function man_item_t make_hold_read(input int idx);
    man_item_t rd;
    rd = man_item_t::type_id::create($sformatf("hold_rd_%0d", idx));
    rd.set_access(VIP_AXI4_RD_REQUEST_E);
    rd.set_rd_rsp(vip_mem_types_pkg::FALSE);
    rd.arid    = DUMMY_ID_C + idx[3:0];
    rd.araddr  = this.encode_addr(.row(idx + 1), .bg(3), .bank(0));
    rd.arlen   = DUMMY_BEATS_C - 1;
    rd.arsize  = this.get_full_width_axi_size();
    rd.arburst = VIP_MC_AXI4_BURST_INCR_C;
    return rd;
  endfunction

  // Build one single-beat write item to line_addr with the given data/strobe.
  protected function man_item_t make_write(
    input string           name,
    input longint unsigned addr,
    input logic [(8 * VIP_MC_AXI4_CFG_C.WDATA_BYTES_P) - 1 : 0] data,
    input logic [VIP_MC_AXI4_CFG_C.WDATA_BYTES_P - 1 : 0]       strb
  );
    man_item_t wr;
    wr = man_item_t::type_id::create(name);
    wr.set_access(VIP_AXI4_WR_REQUEST_E);
    wr.set_wr_rsp(vip_mem_types_pkg::TRUE);
    wr.awid    = WR_ID_C;
    wr.awaddr  = addr;
    wr.awlen   = 0;
    wr.awsize  = this.get_full_width_axi_size();
    wr.awburst = VIP_MC_AXI4_BURST_INCR_C;
    wr.wdata   = new[1];
    wr.wstrb   = new[1];
    for (int b = 0; b < VIP_MC_AXI4_CFG_C.WDATA_BYTES_P; b++) begin
      wr.wdata[0][b] = data[(8 * b) +: 8];
      wr.wstrb[0][b] = strb[b];
    end
    return wr;
  endfunction

  task body();
    localparam int unsigned HALF_C = VIP_MC_AXI4_CFG_C.WDATA_BYTES_P / 2;
    pl_seq_t         seq;
    man_item_t       wr_rsps[$];
    longint unsigned line_addr;
    logic [(8 * VIP_MC_AXI4_CFG_C.WDATA_BYTES_P) - 1 : 0] data_a;
    logic [(8 * VIP_MC_AXI4_CFG_C.WDATA_BYTES_P) - 1 : 0] data_b;
    logic [VIP_MC_AXI4_CFG_C.WDATA_BYTES_P - 1 : 0]       strb_a;
    logic [VIP_MC_AXI4_CFG_C.WDATA_BYTES_P - 1 : 0]       strb_b;
    vip_dram_types #(DRAM_CFG_C)::data_t backdoor_line;

    this.wait_for_reset_release();
    this._tb_env.u_mc.cfg.write_coalescing_enable = TRUE;

    line_addr = this.encode_addr(.row(0), .bg(1), .bank(0));

    // Older write A: whole line, pattern 0xA0+idx. Newer write B: low half only,
    // pattern 0x50+idx. After the merge the low half must show B, high half A.
    data_a = '0; data_b = '0; strb_a = '1; strb_b = '0;
    for (int b = 0; b < VIP_MC_AXI4_CFG_C.WDATA_BYTES_P; b++) begin
      data_a[(8 * b) +: 8] = 8'hA0 + b[7:0];
      if (b < HALF_C) begin
        data_b[(8 * b) +: 8] = 8'h50 + b[7:0];
        strb_b[b] = 1'b1;
      end
    end

    this._tb_env.dram.backdoor_write(line_addr, '0);
    this._grant.clear();

    // One pipelined sequence: page-miss reads hold the depth-1 device window while
    // the two same-line writes are admitted (and coalesced), then drain.
    seq = pl_seq_t::type_id::create("coalesce_pl_seq");
    for (int i = 0; i < N_HOLD_C; i++) begin
      seq.add_item(this.make_hold_read(i));
    end
    seq.add_item(this.make_write("coalesce_wr_a", line_addr, data_a, strb_a));
    seq.add_item(this.make_write("coalesce_wr_b", line_addr, data_b, strb_b));
    seq.set_pipelined_send(vip_mem_types_pkg::TRUE);
    seq.set_collect_wr_responses(vip_mem_types_pkg::TRUE);
    seq.start(this._tb_env.man_agent[0].sequencer);

    // The window-holding reads outlive the (coalesced) writes; let the device
    // drain and their R beats finish on the bus so the monitor does not flag
    // still-outstanding reads at end of test.
    for (int c = 0; c < 4096; c++) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if ((this._tb_env.u_mc.backend.get_inflight_to_device() == 0) &&
          (this._tb_env.u_mc.backend.get_cmd_queue_depth() == 0)) begin
        break;
      end
    end
    repeat (N_HOLD_C * DUMMY_BEATS_C + 64) @(posedge this._tb_env._man_vif[0].clk);

    // Both host writes must complete with OKAY.
    wr_rsps = seq.wr_responses;
    if (wr_rsps.size() != 2) begin
      `uvm_fatal(get_name(), $sformatf(
        "Expected 2 write completions (fan-out), got %0d", wr_rsps.size()))
    end
    foreach (wr_rsps[i]) begin
      if (wr_rsps[i].bresp != VIP_MC_AXI4_RESP_OKAY_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "Coalesced write %0d returned BRESP=%0b instead of OKAY", i, wr_rsps[i].bresp))
      end
    end

    // Exactly one WR reached the device (the two host writes coalesced).
    if (this._grant.wr_grants != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Expected exactly 1 device write grant after coalescing, saw %0d", this._grant.wr_grants))
    end
    if (this._tb_env.u_mc.backend.get_coalesced_write_count() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Expected coalesced_write_count == 1, got %0d",
        this._tb_env.u_mc.backend.get_coalesced_write_count()))
    end

    // The merged line: low half = B (newer won its strobed lanes), high half = A.
    backdoor_line = this._tb_env.dram.backdoor_read(line_addr);
    for (int b = 0; b < VIP_MC_AXI4_CFG_C.WDATA_BYTES_P; b++) begin
      logic [7 : 0] got;
      logic [7 : 0] exp;
      got = backdoor_line[(8 * b) +: 8];
      exp = (b < HALF_C) ? (8'h50 + b[7:0]) : (8'hA0 + b[7:0]);
      if (got !== exp) begin
        `uvm_fatal(get_name(), $sformatf(
          "Coalesced line byte %0d = 0x%0h, expected 0x%0h (overlay wrong)", b, got, exp))
      end
    end

    `uvm_info(get_name(),
      "vip_mc AXI4 write-coalescing test passed (two pipelined same-line writes merged into one device access, both completed, byte-lane overlay correct)",
      UVM_LOW)
  endtask
endclass

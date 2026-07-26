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
// tc_mc_narrow_axi4
//
// Narrow-bus AXI4 (WDATA_BYTES 64 < ROW_BYTES 128). Two scenarios:
//  1. Multi-beat gather: a 2-beat 64 B INCR burst fills one 128 B row; the read
//     back returns both beats correctly (beat 0 -> row lanes 0-63, beat 1 -> 64-
//     127).
//  2. Sub-row scatter + lane correctness: after seeding a full row, a single 64 B
//     beat written at row+64 must land in row lanes 64-127 (upper half) and leave
//     the lower half intact. The pre-fix driver would have placed it in lanes
//     0-63, so this scenario specifically distinguishes the bus-lane/row-lane fix.
// -----------------------------------------------------------------------------
class tc_mc_narrow_axi4 extends mc_neutral_base_test;

  `uvm_component_utils(tc_mc_narrow_axi4)

  mc_narrow_axi4_tb_env _env;

  typedef vip_axi4_types #(VIP_AXI4_AGENT_CFG_C)::wdata_t bus_word_t;
  typedef vip_axi4_types #(VIP_AXI4_AGENT_CFG_C)::wstrb_t bus_strb_t;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // Build the narrow-bus env on top of the neutral base's shared plumbing (phase
  // timeout, report server, clk_rst agent config).
  function void build_phase(input uvm_phase phase);
    super.build_phase(phase);
    this._env = mc_narrow_axi4_tb_env::type_id::create("env", this);
  endfunction

  // Neutral-base hooks: clk_rst sequencer for the shared reset drive + telemetry.
  protected function uvm_sequencer_base get_clk_sequencer();
    return this._env.clk_agent.sequencer;
  endfunction

  protected function void report_telemetry(input string tag);
    if ((this._env == null) || (this._env.u_mc == null)) begin
      return;
    end
    `uvm_info(tag, this._env.u_mc.sprint_telemetry(), UVM_LOW)
  endfunction

  task body();
    int unsigned     nb;
    int unsigned     row;
    logic [2 : 0]    sz;
    longint unsigned a;
    bus_word_t       rdq [$];

    wait (this._env._man_vif.rst_n === 1'b1);
    repeat (4) @(negedge this._env._man_vif.clk);

    nb  = VIP_MC_AXI4_CFG_C.WDATA_BYTES_P;   // 64
    row = NARROW_DRAM_CFG_C.ROW_BYTES_P;     // 128
    sz  = 3'($clog2(nb));

    // --- Scenario 1: multi-beat gather at a row-aligned address. ---------------
    a = NARROW_AXI4_ADDR_C;
    this.write_burst(a, sz, '{ this.pat(8'h10), this.pat(8'h80) });
    this.read_burst(a, sz, 2, rdq);
    this.check_beat("gather beat0", rdq[0], 8'h10);
    this.check_beat("gather beat1", rdq[1], 8'h80);

    // --- Scenario 2: seed a second row, then sub-row overwrite its upper half. --
    a = NARROW_AXI4_ADDR_C + row;
    this.write_burst(a, sz, '{ this.pat(8'h20), this.pat(8'h90) });   // lower=0x20.., upper=0x90..
    this.write_burst(a + nb, sz, '{ this.pat(8'hC0) });               // single beat at row+64
    this.read_burst(a, sz, 2, rdq);
    this.check_beat("subrow lower untouched", rdq[0], 8'h20);         // must stay 0x20..
    this.check_beat("subrow upper overwritten", rdq[1], 8'hC0);       // must be 0xC0.., not 0x90

    `uvm_info(get_name(),
      "Narrow-bus AXI4 multi-beat gather + sub-row lane placement verified (WDATA 64 < ROW 128)",
      UVM_LOW)
  endtask

  // ---------------------------------------------------------------------------
  // Build a 64 B beat word whose byte i = base + i.
  // ---------------------------------------------------------------------------
  protected function bus_word_t pat(input byte unsigned base);
    bus_word_t w;
    w = '0;
    for (int i = 0; i < VIP_MC_AXI4_CFG_C.WDATA_BYTES_P; i++) w[(8 * i) +: 8] = base + i;
    return w;
  endfunction

  // ---------------------------------------------------------------------------
  // Issue an INCR write burst of the supplied full-width beats (all lanes on).
  // ---------------------------------------------------------------------------
  protected task write_burst(
    input longint unsigned addr,
    input logic [2 : 0]    sz,
    input bus_word_t       beats []
  );
    vip_axi4_write_seq #(VIP_AXI4_AGENT_CFG_C) wr;
    vip_axi4_item      #(VIP_AXI4_AGENT_CFG_C) wrsp [$];
    bus_word_t                                 wq [$];
    bus_strb_t                                 sq [$];

    wq = {};
    sq = {};
    foreach (beats[i]) begin
      wq.push_back(beats[i]);
      sq.push_back('1);
    end

    wr = vip_axi4_write_seq #(VIP_AXI4_AGENT_CFG_C)::type_id::create("nwr");
    wr.set_awid('h3);
    wr.set_axaddr(addr);
    wr.set_axlen(beats.size() - 1);
    wr.set_axsize(sz);
    wr.set_axburst(VIP_MC_AXI4_BURST_INCR_C);
    wr.set_axqos(4'h0);
    wr.set_requests(1);
    wr.set_get_wr_response(1'b1);
    wr.set_wdata_type(VIP_AXI4_DATA_CUSTOM_E);
    wr.set_wstrb_type(VIP_AXI4_STRB_CUSTOM_E);
    wr.set_wdata(wq);
    wr.set_wstrb(sq);
    wr.start(this._env.man_agent.sequencer);
    wrsp = wr.get_wr_responses();
    if ((wrsp.size() != 1) || (wrsp[0].bresp !== 2'b00)) begin
      `uvm_error(get_name(), $sformatf(
        "Narrow AXI4 write at 0x%0h failed (n=%0d)", addr, wrsp.size()))
    end
  endtask

  // ---------------------------------------------------------------------------
  // Issue an INCR read burst and return each beat flattened to a 64 B word.
  // ---------------------------------------------------------------------------
  protected task read_burst(
    input  longint unsigned addr,
    input  logic [2 : 0]    sz,
    input  int unsigned     beat_count,
    output bus_word_t       rdq []
  );
    vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C) rd;
    vip_axi4_item     #(VIP_AXI4_AGENT_CFG_C) rrsp [$];

    rd = vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)::type_id::create("nrd");
    rd.set_arid('h5);
    rd.set_axaddr(addr);
    rd.set_axlen(beat_count - 1);
    rd.set_axsize(sz);
    rd.set_axburst(VIP_MC_AXI4_BURST_INCR_C);
    rd.set_axqos(4'h0);
    rd.set_requests(1);
    rd.set_get_rd_response(1'b1);
    rd.start(this._env.man_agent.sequencer);
    rrsp = rd.get_rd_responses();
    if ((rrsp.size() != 1) || (rrsp[0].rdata.size() != beat_count)) begin
      `uvm_fatal(get_name(), $sformatf(
        "Narrow AXI4 read at 0x%0h returned %0d responses / %0d beats",
        addr, rrsp.size(), (rrsp.size() > 0) ? rrsp[0].rdata.size() : 0))
    end
    rdq = new[beat_count];
    for (int b = 0; b < beat_count; b++) begin
      bus_word_t w;
      w = '0;
      for (int i = 0; i < VIP_MC_AXI4_CFG_C.RDATA_BYTES_P; i++) begin
        w[(8 * i) +: 8] = rrsp[0].rdata[b][i];
      end
      rdq[b] = w;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Check one flattened 64 B beat against the byte-ramp base + i.
  // ---------------------------------------------------------------------------
  protected function void check_beat(
    input string     ctx,
    input bus_word_t w,
    input byte unsigned base
  );
    byte unsigned got;
    byte unsigned exp;
    for (int i = 0; i < VIP_MC_AXI4_CFG_C.WDATA_BYTES_P; i++) begin
      got = w[(8 * i) +: 8];
      exp = base + i;
      if (got !== exp) begin
        `uvm_error(get_name(), $sformatf(
          "%s: byte %0d got 0x%02h expected 0x%02h", ctx, i, got, exp))
      end
    end
  endfunction

endclass

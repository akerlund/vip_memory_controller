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
// mc_mixed_soak_gen
//
// Reproducible randomized stimulus for tc_mc_mixed_soak. The protocol is fixed
// by the destination port (AXI4 on port 0, CHI-D on port 1). AXI4 request
// direction, burst type, beat size, burst length, sub-line address, ID, QoS,
// inter-request gap, and write payload are generated. CHI-D remains a full-line
// transfer, but its direction, line address, QoS, gap, and write payload are
// generated. Both flows use the same explicit LCG and draw order, so a seed
// reproduces the same two request streams in SystemVerilog and Python.
//
// CHI-D requests are full-line and line-aligned. AXI4 requests cover the legal
// INCR/WRAP/FIXED shapes supported by the manager agent. Each protocol has a
// separate address window and model, so the cross-protocol check stays
// byte-addressed while AXI4 burst-shape and shared-backend arbitration are both
// exercised.
// -----------------------------------------------------------------------------

typedef struct {
  int unsigned     port_id;
  bit              is_write;
  int unsigned     line;
  longint unsigned addr;
  logic [1 : 0]    burst;
  int unsigned     beats;
  int unsigned     size_bytes;
  int unsigned     axi_id;
  logic [3 : 0]    qos;
  int unsigned     gap_cycles;
  byte unsigned    payload [];
} mc_mixed_soak_txn_t;

class mc_mixed_soak_gen extends uvm_object;

  localparam longint unsigned LCG_MUL_C = 64'd6364136223846793005;
  localparam longint unsigned LCG_INC_C = 64'd1442695040888963407;

  localparam longint unsigned AXI4_BASE_C = 'h0001_0000;
  localparam longint unsigned CHI_BASE_C  = 'h0002_0000;

  int unsigned line_count   = 64;
  int unsigned line_bytes   = 64;
  int unsigned qos_count    = 16;
  int unsigned id_count     = 4;
  int unsigned max_gap      = 9;

  int unsigned incr_percent = 70;
  int unsigned wrap_percent = 15;

  protected longint unsigned state = 64'd1;

  `uvm_object_utils(mc_mixed_soak_gen)

  function new(input string name = "mc_mixed_soak_gen");
    super.new(name);
  endfunction

  function void set_seed(input longint unsigned seed);
    this.state = seed;
  endfunction

  protected function int unsigned next_u32();
    this.state = (this.state * LCG_MUL_C) + LCG_INC_C;
    return int'(this.state >> 32);
  endfunction

  protected function int unsigned next_below(input int unsigned n);
    if (n <= 1) begin
      return 0;
    end
    return this.next_u32() % n;
  endfunction

  static function longint unsigned beat_addr(
    input mc_mixed_soak_txn_t t,
    input int unsigned        idx
  );
    longint unsigned total;
    longint unsigned base;

    if (t.burst == VIP_MC_AXI4_BURST_FIXED_C) begin
      return t.addr;
    end
    if (t.burst == VIP_MC_AXI4_BURST_WRAP_C) begin
      total = t.beats * t.size_bytes;
      base  = t.addr & ~(total - 1);
      return base + (((t.addr - base) + (idx * t.size_bytes)) % total);
    end
    return t.addr + (idx * t.size_bytes);
  endfunction

  // The draw order is the cross-flow contract with mc_mixed_soak_gen.py.
  function void next_txn(
    input  int unsigned    port_id,
    output mc_mixed_soak_txn_t t
  );
    int unsigned burst_sel;
    int unsigned size_log;
    int unsigned line_offset;
    int unsigned total_bytes;
    longint unsigned base;

    t.port_id    = port_id;
    t.is_write   = (this.next_below(100) < 50);

    if (port_id == 0) begin
      burst_sel = this.next_below(100);
      if (burst_sel < this.incr_percent) begin
        t.burst = VIP_MC_AXI4_BURST_INCR_C;
      end
      else if (burst_sel < (this.incr_percent + this.wrap_percent)) begin
        t.burst = VIP_MC_AXI4_BURST_WRAP_C;
      end
      else begin
        t.burst = VIP_MC_AXI4_BURST_FIXED_C;
      end

      size_log = this.next_below($clog2(this.line_bytes) + 1);
      t.size_bytes = 1 << size_log;
      if (t.burst == VIP_MC_AXI4_BURST_WRAP_C) begin
        t.beats = 2 << this.next_below(4);
      end
      else begin
        t.beats = 1 + this.next_below(16);
      end
    end
    else begin
      t.burst      = VIP_MC_AXI4_BURST_INCR_C;
      t.beats      = 1;
      t.size_bytes = this.line_bytes;
    end

    t.line       = this.next_below(this.line_count);
    t.axi_id     = this.next_below(this.id_count);
    t.qos        = this.next_below(this.qos_count);
    t.gap_cycles = this.next_below(this.max_gap);

    base = (port_id == 0) ? AXI4_BASE_C : CHI_BASE_C;
    line_offset = (port_id == 0)
                ? this.next_below(this.line_bytes / t.size_bytes) * t.size_bytes
                : 0;
    t.addr = base + (longint'(t.line) * this.line_bytes) + line_offset;

    total_bytes = t.beats * t.size_bytes;
    if ((port_id == 0) && (t.burst != VIP_MC_AXI4_BURST_WRAP_C) &&
        (((t.addr - AXI4_BASE_C) & 64'h0000_0FFF) + total_bytes > 4096)) begin
      t.addr = base + ((t.addr - base) & ~64'h0000_0FFF);
    end

    if (t.is_write) begin
      t.payload = new[total_bytes];
      for (int i = 0; i < total_bytes; i++) begin
        t.payload[i] = byte'(this.next_u32() & 32'hFF);
      end
    end
    else begin
      t.payload = new[0];
    end
  endfunction

  // Generate one stream for each protocol in an interleaved, single-threaded
  // pass. The test splits the streams and replays them concurrently.
  function void generate_program(
    input  int unsigned      count_per_port,
    output mc_mixed_soak_txn_t axi_txns [$],
    output mc_mixed_soak_txn_t chi_txns [$]
  );
    mc_mixed_soak_txn_t txn;

    axi_txns.delete();
    chi_txns.delete();
    for (int i = 0; i < count_per_port; i++) begin
      this.next_txn(0, txn);
      axi_txns.push_back(txn);
      this.next_txn(1, txn);
      chi_txns.push_back(txn);
    end
  endfunction

endclass

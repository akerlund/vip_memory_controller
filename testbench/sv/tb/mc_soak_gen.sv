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
// mc_soak_gen
//
// Constrained-random AXI4 stimulus generator for tc_mc_axi4_soak. It is the
// first randomized stimulus in this VIP; everything else in the suite is
// directed.
//
// Why a hand-rolled LCG instead of SV constraints. The catalog in
// testbench/TEST_CASES.md promises that the SystemVerilog and pyUVM flows run
// the *same* test. SV `$urandom`/`randomize()` and Python's `random` cannot be
// made to agree, so a solver-based generator would silently break that promise:
// a soak failure would reproduce in one flow and not the other. This generator
// is therefore an explicit 64-bit LCG (the MMIX constants) with a fixed draw
// order, byte-identical in mc_soak_gen.sv and mc_soak_gen.py. Same seed, same
// transactions, same payload, in both flows.
//
// Determinism also survives the concurrency: the whole txn_list is generated up
// front, single-threaded, then split per port. The forked driver threads replay
// a fixed list rather than racing for draws.
//
// Legality is enforced by construction rather than by constraint solving:
//   - address fields are drawn per device dimension (rank/bg/bank/row/col) and
//     encoded through the device's live address map, so every bank and bank
//     group is reachable;
//   - the start address is aligned down to the transfer size, so no beat ever
//     straddles a bus lane boundary;
//   - INCR bursts that would cross a 4 KB page are pulled back to the page base
//     (AXI4 forbids the crossing);
//   - WRAP bursts get a legal power-of-two length and keep their unaligned
//     start, so the wrap actually happens.
//
// Ports get disjoint row ranges. Cross-port aliasing would make the expected
// data depend on inter-port arbitration order, which is exactly the thing under
// test - the golden model must not have to predict it.
// -----------------------------------------------------------------------------

// One generated transaction, fully resolved (no randomization left at drive
// time).
typedef struct {
  int unsigned     port_id;
  bit              is_write;
  longint unsigned addr;         // byte address of beat 0
  logic [1 : 0]    burst;
  int unsigned     beats;        // AXI4 beat count (AWLEN + 1)
  int unsigned     size_bytes;   // bytes per beat, power of two
  int unsigned     axi_id;
  logic [3 : 0]    qos;
  int unsigned     gap_cycles;   // idle clocks before this transaction
  byte unsigned    payload [];   // beats * size_bytes bytes, writes only
} mc_soak_txn_t;

class mc_soak_gen extends uvm_object;

  // MMIX LCG. 64-bit state, output taken from the high half where the period is
  // long; the low bits of a power-of-two-modulus LCG are notoriously short.
  localparam longint unsigned LCG_MUL_C = 64'd6364136223846793005;
  localparam longint unsigned LCG_INC_C = 64'd1442695040888963407;

  // Device geometry / map, handed over by the test so addresses are encoded the
  // way the device actually decodes them.
  vip_dram_cfg_t      geom;
  vip_dram_addr_map_t addr_map;

  int unsigned n_ports        = 2;
  int unsigned bus_bytes      = 64;
  int unsigned rows_per_port  = 8;
  int unsigned qos_max        = 15;

  // Burst-type mix, in percent. INCR first, then WRAP, remainder FIXED. INCR
  // dominates because it is what real traffic looks like; WRAP and FIXED are
  // kept at a steady minority share so every run crosses both corners.
  int unsigned incr_percent   = 70;
  int unsigned wrap_percent   = 15;
  // Share of draws that reuse one of the hot pages, which is what generates
  // page hits and bank conflicts rather than a uniform address sweep.
  int unsigned hot_percent    = 80;
  int unsigned hot_page_count = 4;

  protected longint unsigned state = 64'd1;

  `uvm_object_utils(mc_soak_gen)

  function new(input string name = "mc_soak_gen");
    super.new(name);
  endfunction

  // ---------------------------------------------------------------------------
  // Seed the stream. Any 64-bit value works; the LCG has full period.
  // ---------------------------------------------------------------------------
  function void set_seed(input longint unsigned s);
    this.state = s;
  endfunction

  // ---------------------------------------------------------------------------
  // Raw 32-bit draw. Every random decision below goes through this, so the draw
  // order is the contract between the two flows.
  // ---------------------------------------------------------------------------
  protected function int unsigned next_u32();
    this.state = (this.state * LCG_MUL_C) + LCG_INC_C;
    return int'(this.state >> 32);
  endfunction

  // ---------------------------------------------------------------------------
  // Uniform draw in [0, n). Modulo bias is irrelevant here - the ranges are all
  // tiny next to 2^32, and reproducibility matters more than perfect uniformity.
  // ---------------------------------------------------------------------------
  protected function int unsigned next_below(input int unsigned n);
    if (n <= 1) begin
      return 0;
    end
    return this.next_u32() % n;
  endfunction

  // ---------------------------------------------------------------------------
  // Encode a device coordinate into a byte address through the live map.
  // ---------------------------------------------------------------------------
  protected function longint unsigned encode(
    input int unsigned row,
    input int unsigned bg,
    input int unsigned bank,
    input int unsigned col,
    input int unsigned byte_in_col
  );
    vip_dram_dec_t dec;

    dec             = '{default: 0};
    dec.rank        = 0;
    dec.row         = row;
    dec.bg          = bg;
    dec.bank        = bank;
    dec.col         = col;
    dec.byte_in_col = byte_in_col;
    return vip_dram_encode_addr(dec, this.geom, this.addr_map);
  endfunction

  // ---------------------------------------------------------------------------
  // Address of beat `idx` for a transaction. AXI4 burst arithmetic; shared by
  // the driver (lane placement) and the golden model (byte placement), so the
  // two can never disagree about where a beat landed.
  // ---------------------------------------------------------------------------
  static function longint unsigned beat_addr(
    input mc_soak_txn_t t,
    input int unsigned  idx
  );
    longint unsigned total;
    longint unsigned base;

    case (t.burst)
      VIP_MC_AXI4_BURST_FIXED_C: begin
        return t.addr;
      end
      VIP_MC_AXI4_BURST_WRAP_C: begin
        total = t.beats * t.size_bytes;
        base  = t.addr & ~(total - 1);
        return base + (((t.addr - base) + (idx * t.size_bytes)) % total);
      end
      default: begin
        // INCR, per AXI4 A3.4.1: only the first beat sits at the start address;
        // every later beat is measured from the size-aligned address. next_txn()
        // aligns every start it generates, so the two coincide today - but
        // vip_mc's front-end implements the spec rule, and this model must agree
        // with the front-end rather than with the stimulus generator's own
        // convenience if that alignment is ever relaxed.
        if (idx == 0) begin
          return t.addr;
        end
        return (t.addr - (t.addr % t.size_bytes)) + (idx * t.size_bytes);
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Generate one transaction. The draw order below is the cross-flow contract -
  // mc_soak_gen.py performs exactly these draws, in exactly this sequence.
  // ---------------------------------------------------------------------------
  function void next_txn(output mc_soak_txn_t t);
    int unsigned burst_sel;
    int unsigned size_log;
    int unsigned max_size_log;
    int unsigned wrap_sel;
    int unsigned row;
    int unsigned bg;
    int unsigned bank;
    int unsigned col;
    int unsigned byte_in_col;
    int unsigned hot_sel;
    int unsigned total_bytes;
    int unsigned n_cols;
    longint unsigned page_base;
    longint unsigned size_mask;

    // 1. port
    t.port_id = this.next_below(this.n_ports);

    // 2. direction
    t.is_write = (this.next_below(100) < 50);

    // 3. burst type: INCR dominant, WRAP and FIXED as the corners. One draw
    //    regardless of the mix, so changing the percentages does not shift the
    //    rest of the stream.
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

    // 4. transfer size (bytes per beat), 1 .. bus width
    max_size_log = $clog2(this.bus_bytes);
    size_log     = this.next_below(max_size_log + 1);
    t.size_bytes = 1 << size_log;

    // 5. beat count. WRAP is only legal at 2/4/8/16 beats.
    if (t.burst == VIP_MC_AXI4_BURST_WRAP_C) begin
      wrap_sel = this.next_below(4);
      t.beats  = 2 << wrap_sel;
    end
    else begin
      t.beats = 1 + this.next_below(16);
    end

    // 6. AXI4 id - a small pool so same-id ordering and inter-id reordering
    //    both get exercised
    t.axi_id = this.next_below(4);

    // 7. QoS across the full 4-bit field
    t.qos = this.next_below(this.qos_max + 1);

    // 8. inter-transaction gap: 0 saturates the port, 8 lets the queue drain
    t.gap_cycles = this.next_below(9);

    // 9. address. Each port owns a disjoint row range so the golden model never
    //    has to predict inter-port arbitration order.
    n_cols  = 1 << this.geom.COL_BITS_P;
    hot_sel = this.next_below(100);
    if (hot_sel < this.hot_percent) begin
      // Hot page: a small recurring (row, bg, bank) set, column varying. This
      // is what produces page hits, bank conflicts and coalescable writes.
      row  = (t.port_id * this.rows_per_port)
             + this.next_below(this.hot_page_count);
      bg   = this.next_below(this.geom.N_BANK_GROUPS_P);
      bank = this.next_below(this.geom.BANKS_PER_BG_P);
    end
    else begin
      row  = (t.port_id * this.rows_per_port)
             + this.next_below(this.rows_per_port);
      bg   = this.next_below(this.geom.N_BANK_GROUPS_P);
      bank = this.next_below(this.geom.BANKS_PER_BG_P);
    end
    col         = this.next_below(n_cols);
    byte_in_col = this.next_below(this.bus_bytes);

    // Align the start down to the transfer size: every beat then stays inside
    // one bus lane window, which is what lets one strobe describe it.
    byte_in_col = byte_in_col & ~(t.size_bytes - 1);
    size_mask   = t.size_bytes - 1;
    t.addr      = this.encode(row, bg, bank, col, byte_in_col);
    t.addr      = t.addr & ~size_mask;

    total_bytes = t.beats * t.size_bytes;

    // AXI4 forbids a burst crossing a 4 KB page. The stock vip_axi4 manager
    // enforces this with the FULL bus width per beat rather than 1 << axsize
    // (vip_axi4_item con_awaddr / con_araddr), so a narrow burst is held to the
    // same reservation - match that, or the agent's randomize() fails on the
    // pinned address. WRAP is exempt: it never leaves its wrap window.
    if (t.burst != VIP_MC_AXI4_BURST_WRAP_C) begin
      if (((t.addr & 64'h0000_0FFF) + (t.beats * this.bus_bytes)) > 4096) begin
        page_base = t.addr & ~64'h0000_0FFF;
        t.addr    = page_base;
      end
    end

    // 10. payload, one byte per written byte. Generated here (not at drive
    //     time) so the forked port threads never draw.
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

  // ---------------------------------------------------------------------------
  // Generate the whole txn_list up front. Single-threaded and deterministic;
  // the test then splits it per port and replays the slices concurrently.
  // ---------------------------------------------------------------------------
  function void generate_program(
    input  int unsigned   count,
    output mc_soak_txn_t  txn_list []
  );
    txn_list = new[count];
    for (int i = 0; i < count; i++) begin
      this.next_txn(txn_list[i]);
    end
  endfunction

endclass

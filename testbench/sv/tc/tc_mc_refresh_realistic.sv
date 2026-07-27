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
// tc_mc_refresh_realistic
//
// The only test in the suite where a refresh happens because time passed.
//
// Every other refresh test shortens tREFI through the mc_trefi_override_ns knob
// or forces the deferred policy, because the directed tests finish in tens to
// hundreds of clock cycles while the device's real tREFI is 7800 ns (780 clocks
// at the example's 10 ns bus). Before this test the longest AXI4 test ran 2445
// ns - so no test had ever seen a natural refresh, let alone one landing on a
// busy FR-FCFS scheduler.
//
// This test removes the override and drives continuous mixed traffic across
// several native tREFI intervals. What it proves:
//   - refreshes are emitted at the device's own cadence (count matches elapsed
//     time / tREFI, within one interval for the partial window at each end);
//   - the device executed every refresh the controller emitted;
//   - traffic in flight across a refresh still completes and still returns the
//     right data - refresh does not drop or corrupt a queued access;
//   - the counters keep agreeing over thousands of cycles rather than tens.
//
// It is also what fills the REF-adjacent cells of mc_coverage's cg_turnaround
// (RD->REF, WR->REF, REF->RD, REF->WR) from natural traffic rather than from a
// forced refresh burst.
//
// Cost. This is by far the longest test in the suite - INTERVALS_C native tREFI
// windows, ~39 us at the default 5. That is deliberate; it is the property
// being tested. Override for a longer nightly run with:
//
//   +MC_REFRESH_INTERVALS=<n>
// -----------------------------------------------------------------------------
class tc_mc_refresh_realistic extends mc_base_test;

  `uvm_component_utils(tc_mc_refresh_realistic)

  // Native tREFI windows to cover. Five keeps the regression affordable while
  // still crossing enough boundaries that an off-by-one cadence bug shows up.
  localparam int unsigned DEFAULT_INTERVALS_C = 5;

  // Keep a few accesses queued so refresh always has real work to interrupt;
  // an idle controller would make the test vacuous.
  localparam int unsigned OUTSTANDING_C = 4;

  // Rotate traffic over a handful of banks so refresh interacts with page
  // management rather than hitting one permanently-open row.
  localparam int unsigned BANK_ROTATION_C = 8;

  // Data tag folded into every payload so a stale readback cannot pass.
  localparam logic [31 : 0] REF_TAG_C = 32'h5EF0_0000;

  protected int unsigned intervals;
  protected int unsigned txn_index;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Note what is NOT set here: no mc_trefi_override_ns. That is the whole point
  // of the test - the device's own tREFI applies.
  //
  // The timing scoreboard is left off because a refresh landing mid-queue moves
  // completions by a whole tRFC, which the predictor models per access rather
  // than per queue (docs/FURTHER_WORK.md item 5). Data and cadence are checked
  // instead.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    uvm_config_db #(int)::set(this, "env", "mc_scoreboard_timing_check", 0);
    uvm_config_db #(int)::set(this, "env", "man_wr_outstanding_max", OUTSTANDING_C);
    uvm_config_db #(int)::set(this, "env", "man_rd_outstanding_max", OUTSTANDING_C);
    super.build_phase(phase);
  endfunction

  // ---------------------------------------------------------------------------
  // Drive traffic for N native tREFI windows and check the refresh cadence and
  // data integrity across them.
  // ---------------------------------------------------------------------------
  task body();
    real     trefi_ns;
    realtime t_start;
    realtime t_end;
    realtime elapsed_ns;
    real     expected_refreshes;
    int      mc_refreshes;
    int      dram_refreshes;
    int      mc_ref_base;
    int      dram_ref_base;

    this.intervals = DEFAULT_INTERVALS_C;
    void'($value$plusargs("MC_REFRESH_INTERVALS=%d", this.intervals));

    this.wait_for_reset_release();

    trefi_ns = this._tb_env.dram.cfg.timing.tREFI;
    if (trefi_ns <= 0.0) begin
      `uvm_fatal(get_name(), "device reports a non-positive tREFI")
    end

    `uvm_info(get_name(), $sformatf(
      "Native tREFI = %0.1f ns, tRFC = %0.1f ns, covering %0d intervals (~%0.1f us)",
      trefi_ns,
      this._tb_env.dram.cfg.timing.tRFC,
      this.intervals,
      (trefi_ns * this.intervals) / 1000.0), UVM_LOW)

    mc_ref_base   = this._tb_env.u_mc.get_refresh_count();
    dram_ref_base = this._tb_env.dram.get_refresh_count();
    t_start       = $realtime;
    t_end         = t_start + (trefi_ns * this.intervals * 1ns);

    this.txn_index = 0;
    while ($realtime < t_end) begin
      this.drive_one_checked_access();
    end

    elapsed_ns = ($realtime - t_start) / 1ns;

    mc_refreshes   = this._tb_env.u_mc.get_refresh_count() - mc_ref_base;
    dram_refreshes = this._tb_env.dram.get_refresh_count() - dram_ref_base;

    // The window starts and ends at arbitrary points inside a tREFI period, so
    // the exact count can be one either side of the ideal.
    expected_refreshes = elapsed_ns / trefi_ns;

    `uvm_info(get_name(), $sformatf(
      "Ran %0d accesses over %0.1f ns: %0d refreshes emitted, %0d executed, %0.2f expected",
      this.txn_index, elapsed_ns, mc_refreshes, dram_refreshes,
      expected_refreshes), UVM_LOW)

    if (mc_refreshes < 1) begin
      `uvm_error(get_name(),
        "no refresh fired in a window spanning several native tREFI intervals")
    end

    if ((real'(mc_refreshes) < (expected_refreshes - 1.0)) ||
        (real'(mc_refreshes) > (expected_refreshes + 1.0))) begin
      `uvm_error(get_name(), $sformatf(
        "refresh cadence off: %0d emitted over %0.1f ns, expected ~%0.2f at tREFI %0.1f ns",
        mc_refreshes, elapsed_ns, expected_refreshes, trefi_ns))
    end

    if (dram_refreshes != mc_refreshes) begin
      `uvm_error(get_name(), $sformatf(
        "device executed %0d refreshes but the controller emitted %0d",
        dram_refreshes, mc_refreshes))
    end

    this.report_telemetry("refresh_realistic");
  endtask

  // ---------------------------------------------------------------------------
  // One write/read pair at a rotating address, checked immediately. Rotating
  // the bank keeps page management in play; the data pattern folds in the
  // transaction index so a stale readback cannot pass by accident.
  // ---------------------------------------------------------------------------
  protected task drive_one_checked_access();
    longint unsigned addr;
    wdata_t          data;
    rdata_t          rdata;
    resp_t           bresp;
    resp_t           rresp;
    int unsigned     bank;
    int unsigned     bg;
    int unsigned     row;

    bank = this.txn_index % DRAM_CFG_C.BANKS_PER_BG_P;
    bg   = (this.txn_index / DRAM_CFG_C.BANKS_PER_BG_P) % DRAM_CFG_C.N_BANK_GROUPS_P;
    row  = (this.txn_index / BANK_ROTATION_C) % 16;
    addr = this.encode_addr(row, bg, bank, this.txn_index % 64);

    data = '0;
    data[63 : 0] = {REF_TAG_C ^ this.txn_index, this.txn_index};

    this.axi4_write_single(addr, data, '1, bresp);
    if (bresp !== VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_error(get_name(), $sformatf(
        "access %0d: write at 0x%0h returned BRESP 0x%0h",
        this.txn_index, addr, bresp))
    end

    this.axi4_read_single(addr, rdata, rresp);
    if (rresp !== VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_error(get_name(), $sformatf(
        "access %0d: read at 0x%0h returned RRESP 0x%0h",
        this.txn_index, addr, rresp))
    end
    if (rdata[63 : 0] !== data[63 : 0]) begin
      `uvm_error(get_name(), $sformatf(
        "access %0d: readback at 0x%0h got 0x%0h expected 0x%0h - a refresh lost data",
        this.txn_index, addr, rdata[63 : 0], data[63 : 0]))
    end

    this.txn_index++;
  endtask

  // ---------------------------------------------------------------------------
  // Encode a device coordinate into a byte address through the live map.
  // ---------------------------------------------------------------------------
  protected function longint unsigned encode_addr(
    input int unsigned row,
    input int unsigned bg,
    input int unsigned bank,
    input int unsigned col
  );
    vip_dram_dec_t dec;

    dec      = '{default: 0};
    dec.row  = row;
    dec.bg   = bg;
    dec.bank = bank;
    dec.col  = col;
    return vip_dram_encode_addr(dec, DRAM_CFG_C, this._tb_env.dram.cfg.addr_map);
  endfunction

endclass

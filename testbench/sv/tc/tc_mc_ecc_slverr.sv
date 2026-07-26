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
// tc_mc_ecc_slverr
//
// Exercises the §11 item-5 ECC / SECDED read-error path. A device fault is
// injected on specific rows via vip_dram::inject_fault (deterministic and
// addressable — not probabilistic bus injection). The device physically
// corrupts a faulted beat (CORRECTABLE = 1 bit flipped, UNCORRECTABLE = 2), and
// the controller's 64+8 SECDED layer (cfg.ecc_enable) repairs and classifies
// each completed read:
//   * a clean row                -> OKAY, data intact;
//   * a CORRECTABLE (1-bit) row   -> the SECDED layer un-flips the bad bit, so
//     the read is OKAY with data restored byte-for-byte (real correction, not a
//     tag), get_ecc_corrected_count() advances;
//   * an UNCORRECTABLE (2-bit) row -> unrepairable: bus SLVERR and the delivered
//     data stays poisoned, get_ecc_uncorrectable_count() advances.
// A final leg disables cfg.ecc_enable and re-reads the uncorrectable row: the
// device corruption still happened, so with no controller ECC the read returns
// OKAY carrying the corrupted bytes (silent data corruption) and the counters
// stay frozen — proving the correction/classification is gated on the knob.
// -----------------------------------------------------------------------------
class tc_mc_ecc_slverr extends mc_base_test;

  `uvm_component_utils(tc_mc_ecc_slverr)

  localparam wdata_t DATA_CLEAN_C  = 'h1111_2222_3333_4444;
  localparam wdata_t DATA_CORR_C   = 'h5555_6666_7777_8888;
  localparam wdata_t DATA_UNCORR_C = 'h9999_aaaa_bbbb_cccc;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(input uvm_phase phase);
    uvm_config_db #(int)::set(this, "env", "mc_refresh_enabled", 0);
    // The timing/data scoreboard is ECC-unaware (an injected fault has no bearing
    // on device timing, and a SLVERR read carries device data it must not check),
    // so run this directed test with the scoreboard off.
    uvm_config_db #(int)::set(this, "env", "mc_scoreboard_enabled", 0);
    super.build_phase(phase);
  endfunction

  protected function longint unsigned encode_addr(
    input int row,
    input int bg,
    input int bank
  );
    vip_dram_dec_t dec;
    dec = '{default: 0};
    dec.row  = row;
    dec.bg   = bg;
    dec.bank = bank;
    return vip_dram_encode_addr(dec, DRAM_CFG_C, this._tb_env.u_mc.cfg.addr_map_policy);
  endfunction

  task body();
    longint unsigned clean_addr;
    longint unsigned corr_addr;
    longint unsigned uncorr_addr;
    rdata_t          rdata;
    resp_t           rresp;
    resp_t           bresp;

    this.wait_for_reset_release();
    this._tb_env.u_mc.cfg.ecc_enable = TRUE;

    clean_addr  = this.encode_addr(.row(1), .bg(0), .bank(0));
    corr_addr   = this.encode_addr(.row(2), .bg(1), .bank(0));
    uncorr_addr = this.encode_addr(.row(3), .bg(2), .bank(0));

    // Seed the three rows with distinct data.
    this.axi4_write_single(clean_addr,  DATA_CLEAN_C,  '1, bresp);
    this.axi4_write_single(corr_addr,   DATA_CORR_C,   '1, bresp);
    this.axi4_write_single(uncorr_addr, DATA_UNCORR_C, '1, bresp);

    // Inject device read faults of each severity.
    this._tb_env.dram.inject_fault(corr_addr,   VIP_DRAM_FAULT_CORRECTABLE_E);
    this._tb_env.dram.inject_fault(uncorr_addr, VIP_DRAM_FAULT_UNCORRECTABLE_E);

    // Clean row: OKAY, data intact.
    this.axi4_read_single(clean_addr, rdata, rresp);
    if ((rresp != VIP_MC_AXI4_RESP_OKAY_C) || (rdata !== DATA_CLEAN_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "ECC clean read expected OKAY/0x%0h, got RRESP=%0b data=0x%0h",
        DATA_CLEAN_C, rresp, rdata))
    end

    // Correctable row: corrected -> still OKAY, data intact.
    this.axi4_read_single(corr_addr, rdata, rresp);
    if ((rresp != VIP_MC_AXI4_RESP_OKAY_C) || (rdata !== DATA_CORR_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "ECC correctable read expected corrected OKAY/0x%0h, got RRESP=%0b data=0x%0h",
        DATA_CORR_C, rresp, rdata))
    end

    // Uncorrectable row: double-bit DUE -> SLVERR, and the delivered data stays
    // poisoned (the SECDED layer cannot repair a two-bit flip).
    this.axi4_read_single(uncorr_addr, rdata, rresp);
    if (rresp != VIP_MC_AXI4_RESP_SLVERR_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "ECC uncorrectable read expected SLVERR, got RRESP=%0b", rresp))
    end
    if (rdata === DATA_UNCORR_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "ECC uncorrectable read expected poisoned data (!= 0x%0h), got intact 0x%0h",
        DATA_UNCORR_C, rdata))
    end

    if (this._tb_env.u_mc.get_ecc_corrected_count() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "ECC corrected count = %0d, expected 1",
        this._tb_env.u_mc.get_ecc_corrected_count()))
    end
    if (this._tb_env.u_mc.get_ecc_uncorrectable_count() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "ECC uncorrectable count = %0d, expected 1",
        this._tb_env.u_mc.get_ecc_uncorrectable_count()))
    end

    // Gating: with ECC disabled the controller applies no correction or
    // classification, so the same faulted row reads back OKAY but carries the
    // device's corrupted bytes (silent data corruption); neither counter moves.
    this._tb_env.u_mc.cfg.ecc_enable = FALSE;
    this.axi4_read_single(uncorr_addr, rdata, rresp);
    if (rresp != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "ECC-disabled read expected OKAY (no classification), got RRESP=%0b", rresp))
    end
    if (rdata === DATA_UNCORR_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "ECC-disabled read expected silently-corrupted data (!= 0x%0h), got intact 0x%0h",
        DATA_UNCORR_C, rdata))
    end
    if (this._tb_env.u_mc.get_ecc_uncorrectable_count() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "ECC uncorrectable count changed to %0d with ECC disabled (expected 1)",
        this._tb_env.u_mc.get_ecc_uncorrectable_count()))
    end
    if (this._tb_env.u_mc.get_ecc_corrected_count() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "ECC corrected count changed to %0d with ECC disabled (expected 1)",
        this._tb_env.u_mc.get_ecc_corrected_count()))
    end

    `uvm_info(get_name(),
      "vip_mc ECC/SLVERR test passed (clean OKAY, 1-bit corrected OKAY, 2-bit SLVERR, gating verified)",
      UVM_LOW)
  endtask
endclass

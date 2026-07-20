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
// tc_vip_mc_refresh_deferred
//
// Deferred refresh policy (VIP_MC_REFRESH_DEFERRED_E). With a shortened tREFI and
// a max-deferred limit of 4, refreshes are postponed (debt accrues one per tREFI)
// until the debt hits the limit, then drained in a forced catch-up burst. Over a
// timed window the test checks that: at least one catch-up occurred (refresh was
// actually deferred), the debt never exceeded the configured limit, every emitted
// REF was executed by the device, and the emitted count equals
// catch-ups * limit * N_RANKS (bursty, not one-per-tREFI).
// -----------------------------------------------------------------------------
class tc_vip_mc_refresh_deferred extends vip_mc_base_test;

  `uvm_component_utils(tc_vip_mc_refresh_deferred)

  localparam int MAX_DEFERRED_C = 4;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(input uvm_phase phase);
    uvm_config_db #(real)::set(this, "env", "mc_trefi_override_ns", 50.0);
    uvm_config_db #(int)::set(this, "env", "mc_refresh_policy", 1);   // deferred
    uvm_config_db #(int)::set(this, "env", "mc_refresh_max_deferred", MAX_DEFERRED_C);
    super.build_phase(phase);
  endfunction

  task body();
    vip_mc_refresh #(DRAM_CFG_C) rf;
    int mc_cnt;
    int dram_cnt;
    int peak;
    int catchups;
    int expected;

    rf = this._tb_env.u_mc.refresh;
    if (rf == null) begin
      `uvm_fatal(get_name(), "vip_mc refresh component was not built")
    end

    this.wait_for_reset_release();

    // ~24 tREFI intervals -> several forced catch-up bursts of MAX_DEFERRED_C.
    #1200ns;

    peak     = rf.get_peak_deferred_debt();
    catchups = rf.get_deferred_catchup_count();
    mc_cnt   = this._tb_env.u_mc.get_refresh_count();
    dram_cnt = this._tb_env.dram.get_refresh_count();

    if (catchups < 1) begin
      `uvm_fatal(get_name(), "deferred policy never emitted a catch-up burst")
    end
    if ((peak < 1) || (peak > MAX_DEFERRED_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "peak deferred debt %0d outside [1, %0d]", peak, MAX_DEFERRED_C))
    end
    if (mc_cnt != dram_cnt) begin
      `uvm_fatal(get_name(), $sformatf(
        "emitted REF count %0d != device-executed %0d", mc_cnt, dram_cnt))
    end

    // Each catch-up drains exactly MAX_DEFERRED_C bursts, each of N_RANKS REFs;
    // the trailing partial debt is still deferred and not yet emitted.
    expected = catchups * MAX_DEFERRED_C * DRAM_CFG_C.N_RANKS_P;
    if (mc_cnt != expected) begin
      `uvm_fatal(get_name(), $sformatf(
        "emitted REF count %0d != catchups(%0d) * limit(%0d) * ranks(%0d) = %0d",
        mc_cnt, catchups, MAX_DEFERRED_C, DRAM_CFG_C.N_RANKS_P, expected))
    end

    `uvm_info(get_name(), $sformatf(
      "Deferred refresh verified: %0d catch-up burst(s), peak debt %0d, %0d REFs executed",
      catchups, peak, mc_cnt), UVM_LOW)
  endtask

endclass

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
// tc_vip_mc_refresh
//
// Smoke test for the first vip_mc refresh slice. It shortens tREFI through the
// example env override path and checks that controller-emitted refreshes match
// the device-observed refresh count.
// -----------------------------------------------------------------------------
class tc_vip_mc_refresh extends vip_mc_base_test;

  `uvm_component_utils(tc_vip_mc_refresh)

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Override the refresh cadence so the test completes quickly.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    uvm_config_db #(real)::set(this, "env", "mc_trefi_override_ns", 50.0);
    super.build_phase(phase);
  endfunction

  // ---------------------------------------------------------------------------
  // Observe controller/device refresh counts over a short timed window.
  // ---------------------------------------------------------------------------
  task body();
    int mc_before;
    int mc_after;
    int dram_before;
    int dram_after;

    if (this._tb_env.u_mc.refresh == null) begin
      `uvm_fatal(get_name(), "vip_mc refresh component was not built")
    end

    this.wait_for_reset_release();

    mc_before   = this._tb_env.u_mc.get_refresh_count();
    dram_before = this._tb_env.dram.get_refresh_count();

    #130ns;

    mc_after   = this._tb_env.u_mc.get_refresh_count();
    dram_after = this._tb_env.dram.get_refresh_count();

    if ((mc_after - mc_before) < (2 * DRAM_CFG_C.N_RANKS_P)) begin
      `uvm_fatal(get_name(), "vip_mc did not emit refreshes at the shortened cadence")
    end

    if ((mc_after - mc_before) != (dram_after - dram_before)) begin
      `uvm_fatal(get_name(), "vip_mc emitted refresh count diverged from vip_dram executed refresh count")
    end

    `uvm_info(get_name(), "vip_mc refresh test passed", UVM_LOW)
  endtask

endclass
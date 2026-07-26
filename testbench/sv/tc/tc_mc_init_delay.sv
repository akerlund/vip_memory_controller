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
// tc_mc_init_delay
//
// Controller bring-up hold-off (init_delay_enabled + init_delay_ns). With a
// 300 ns bring-up delay, the backend must not service any device traffic until
// 300 ns after reset deasserts. The first write issued right after reset is
// therefore held off (its B completes only once bring-up finishes), while a
// second write issued afterwards completes promptly -- proving the gate is a
// one-time bring-up that opens after tINIT and stays open.
// -----------------------------------------------------------------------------
class tc_mc_init_delay extends mc_base_test;

  `uvm_component_utils(tc_mc_init_delay)

  localparam real INIT_DELAY_NS_C = 300.0;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(input uvm_phase phase);
    uvm_config_db #(int)::set(this, "env", "mc_init_delay_enabled", 1);
    uvm_config_db #(real)::set(this, "env", "mc_init_delay_ns", INIT_DELAY_NS_C);
    // Keep refresh out of the picture so timing reflects the bring-off gate only.
    uvm_config_db #(int)::set(this, "env", "mc_refresh_enabled", 0);
    super.build_phase(phase);
  endfunction

  task body();
    logic [1 : 0] bresp;
    time          t0;
    time          t1;
    time          first_elapsed;
    time          second_elapsed;

    this.wait_for_reset_release();

    // First write, issued immediately after reset: must be held off by the gate.
    t0 = $realtime;
    this.axi4_write_single('h0000_2000, {DRAM_CFG_C.ROW_BYTES_P{8'hA5}}, '1, bresp);
    t1 = $realtime;
    first_elapsed = t1 - t0;
    if (bresp !== 2'b00) begin
      `uvm_error(get_name(), $sformatf("first write returned BRESP 0x%0h", bresp))
    end
    if (first_elapsed < 200ns) begin
      `uvm_fatal(get_name(), $sformatf(
        "bring-up hold-off not observed: first write completed in %0t (< 200 ns)",
        first_elapsed))
    end

    // Second write, after bring-up: the gate is open, so it completes promptly.
    t0 = $realtime;
    this.axi4_write_single('h0000_2040, {DRAM_CFG_C.ROW_BYTES_P{8'h5A}}, '1, bresp);
    t1 = $realtime;
    second_elapsed = t1 - t0;
    if (second_elapsed > 150ns) begin
      `uvm_fatal(get_name(), $sformatf(
        "post-bring-up write should not be gated, but took %0t", second_elapsed))
    end

    `uvm_info(get_name(), $sformatf(
      "init-delay bring-up verified: first write held %0t, second write %0t",
      first_elapsed, second_elapsed), UVM_LOW)
  endtask

endclass

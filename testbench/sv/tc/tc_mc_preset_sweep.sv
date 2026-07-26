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
// tc_mc_preset_sweep
//
// Consistency sweep across every vip_dram timing preset. For each preset the
// test reapplies the device timing, validates it, resets the device state, then
// runs one write+read through vip_mc. The existing timing scoreboard is
// the oracle: the observed bus timing must keep matching dram.predict() under
// every preset, without hard-coding per-preset latencies.
// -----------------------------------------------------------------------------
class tc_mc_preset_sweep extends mc_base_test;

  `uvm_component_utils(tc_mc_preset_sweep)

  localparam longint unsigned ADDR_C = 'h0000;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(input uvm_phase phase);
    uvm_config_db #(int)::set(this, "env", "mc_refresh_enabled", 0);
    super.build_phase(phase);
  endfunction

  task body();
    vip_dram_preset_t presets [6];
    wdata_t write_data;
    rdata_t read_data;
    resp_t  bresp;
    resp_t  rresp;
    int     timing_checked_before;
    int     timing_errors_before;

    presets = '{
      VIP_DRAM_PRESET_DDR4_3200_CL22_E,
      VIP_DRAM_PRESET_DDR4_2400_CL17_E,
      VIP_DRAM_PRESET_DDR3_1600_CL11_E,
      VIP_DRAM_PRESET_LPDDR4_3200_E,
      VIP_DRAM_PRESET_DDR5_4800_E,
      VIP_DRAM_PRESET_IDEAL_E
    };

    this.wait_for_reset_release();

    foreach (presets[i]) begin
      // Retune the shared device to this timing bin, revalidate its config, and
      // clear the bank state so the traffic below sees a fresh device.
      this._tb_env.dram.cfg.apply_preset(presets[i]);
      this._tb_env.dram.cfg.validate();
      this._tb_env.dram.reset();

      timing_checked_before = this._tb_env.scoreboard.get_timing_checked_count();
      timing_errors_before  = this._tb_env.scoreboard.get_timing_error_count();

      write_data = '0;
      for (int byte_idx = 0; byte_idx < VIP_MC_AXI4_CFG_C.WDATA_BYTES_P; byte_idx++) begin
        write_data[(8 * byte_idx) +: 8] = 8'h10 + i[7:0] + byte_idx[7:0];
      end

      this.axi4_write_single(ADDR_C, write_data, '1, bresp);
      if (bresp != VIP_MC_AXI4_RESP_OKAY_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "Preset %s write returned BRESP=%0b instead of OKAY",
          presets[i].name(),
          bresp))
      end

      this.axi4_read_single(ADDR_C, read_data, rresp);
      if (rresp != VIP_MC_AXI4_RESP_OKAY_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "Preset %s read returned RRESP=%0b instead of OKAY",
          presets[i].name(),
          rresp))
      end
      if (read_data !== write_data) begin
        `uvm_fatal(get_name(), $sformatf(
          "Preset %s readback did not match the preceding write",
          presets[i].name()))
      end

      if ((this._tb_env.scoreboard.get_timing_checked_count() - timing_checked_before) < 2) begin
        `uvm_fatal(get_name(), $sformatf(
          "Preset %s did not exercise the timing scoreboard on both requests",
          presets[i].name()))
      end
      if (this._tb_env.scoreboard.get_timing_error_count() != timing_errors_before) begin
        `uvm_fatal(get_name(), $sformatf(
          "Preset %s introduced timing scoreboard errors (before=%0d after=%0d)",
          presets[i].name(),
          timing_errors_before,
          this._tb_env.scoreboard.get_timing_error_count()))
      end

      `uvm_info(get_name(), $sformatf(
        "vip_mc preset sweep: preset %s ok",
        presets[i].name()), UVM_LOW)
    end
  endtask

endclass
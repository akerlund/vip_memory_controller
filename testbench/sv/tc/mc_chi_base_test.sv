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
// mc_chi_base_test
//
// Shared base for the CHI slice of the vip_mc example. It builds the
// self-contained CHI environment, owns the RN-I write/read sequence handles and
// the reset sequence, drives the initial reset from the clk_rst agent (so the
// shared clk_rst interface is owned exactly as in the AXI4 slice), and offers a
// reset-settle helper. Like mc_multirank_base_test, it extends uvm_test
// directly rather than the AXI4 base, so it builds only the CHI env.
//
// It is parameterized over the (vip_chi, vip_mc) CHI cfg pair so the same base
// serves the D/E matrix. The parameters default to the CHI-D family, so the
// CHI-D tests extend it with no parameters; the CHI-E tests specialize it with
// VIP_CHI_CFG_E_C / VIP_MC_CHI_CFG_E_C.
// -----------------------------------------------------------------------------
class mc_chi_base_test #(
  vip_chi_cfg_t    CHI_CFG_P    = VIP_CHI_CFG_C,
  vip_mc_chi_cfg_t MC_CHI_CFG_P = VIP_MC_CHI_CFG_C
  ) extends mc_neutral_base_test;

  `uvm_component_param_utils(mc_chi_base_test #(CHI_CFG_P, MC_CHI_CFG_P))

  typedef mc_chi_tb_env #(CHI_CFG_P, MC_CHI_CFG_P) env_l_t;

  env_l_t                                 _env;
  vip_chi_write_seq      #(CHI_CFG_P)      _wr_seq;
  vip_chi_read_seq       #(CHI_CFG_P)      _rd_seq;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Build the environment and shared reporting, and configure the clk_rst agent.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    // super.build_phase configures the phase timeout, report server, and the
    // clk_rst agent (10 ns) shared by every vip_mc example test.
    super.build_phase(phase);
    this._env = env_l_t::type_id::create("env", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Create the shared reset + RN-I sequence handles.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);
    // super.start_of_simulation_phase creates the shared reset sequence.
    super.start_of_simulation_phase(phase);
    this._wr_seq  = vip_chi_write_seq      #(CHI_CFG_P)::type_id::create("wr_seq");
    this._rd_seq  = vip_chi_read_seq       #(CHI_CFG_P)::type_id::create("rd_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Return the built CHI SN front-end handle for telemetry assertions
  // (decerr_count / unsupported_count / read_count / write_count).
  // ---------------------------------------------------------------------------
  protected function vip_mc_chi_driver #(MC_CHI_CFG_P, DRAM_CFG_C) get_chi_fe();
    vip_mc_chi_driver #(MC_CHI_CFG_P, DRAM_CFG_C) fe;

    if ((this._env == null) ||
        (this._env.u_mc == null) ||
        !$cast(fe, this._env.u_mc.fes[0])) begin
      `uvm_fatal(get_name(), "vip_mc CHI port 0 was not built as a CHI front-end")
    end
    return fe;
  endfunction

  // ---------------------------------------------------------------------------
  // Test-specific behavior hook, run after the initial reset has been driven.
  // ---------------------------------------------------------------------------
  virtual task body();
  endtask

  // ---------------------------------------------------------------------------
  // Neutral-base hooks: supply the clk_rst sequencer for the shared reset drive
  // and dump this env's controller telemetry (formatted by vip_mc itself).
  // ---------------------------------------------------------------------------
  protected function uvm_sequencer_base get_clk_sequencer();
    return this._env.clk_agent.sequencer;
  endfunction

  protected function void report_telemetry(input string tag);
    if ((this._env == null) || (this._env.u_mc == null)) begin
      return;
    end
    `uvm_info(tag, this._env.u_mc.sprint_telemetry(), UVM_LOW)
  endfunction

  // ---------------------------------------------------------------------------
  // Wait until reset deasserts, then settle for a few clocks so link activation
  // and initial credit exchange complete before the first request.
  // ---------------------------------------------------------------------------
  protected task wait_reset_and_settle();
    if (this._env.rni_agent.vif.rst_n !== 1'b1) begin
      @(posedge this._env.rni_agent.vif.rst_n);
    end
    repeat (20) @(posedge this._env.rni_agent.vif.clk);
  endtask

endclass

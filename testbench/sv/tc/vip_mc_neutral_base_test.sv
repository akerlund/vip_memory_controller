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
// vip_mc_neutral_base_test
//
// Protocol-neutral base for every vip_mc example test. It owns the plumbing that
// is identical across the AXI4 and CHI slices: the shared report server, the
// clk_rst agent configuration, the reset sequence, a phase timeout, the
// run-phase skeleton (own the initial reset, run the body, then dump telemetry),
// and the end-of-test report summary.
//
// Protocol-specific bases (vip_mc_base_test for AXI4, vip_mc_chi_base_test for
// CHI) extend this and fill three hooks: build their own env, return their
// clk_rst sequencer for the reset drive, and report telemetry from their own
// vip_mc handle. Telemetry itself is formatted by vip_mc::sprint_telemetry(), so
// both slices share one formatter regardless of vip_mc's parameterization.
// -----------------------------------------------------------------------------
class vip_mc_neutral_base_test extends uvm_test;

  `uvm_component_utils(vip_mc_neutral_base_test)

  report_server  _report_server;
  clk_rst_config _clk_cfg;
  reset_sequence _rst_seq;
  time           _phase_timeout = 5ms;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Shared build: phase timeout, report server, and clk_rst agent config (10 ns).
  // Subclasses call super.build_phase() then build their own env / protocol wiring.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    super.build_phase(phase);

    uvm_top.set_timeout(this._phase_timeout, 1);

    this._report_server = new("report_server0");
    uvm_report_server::set_server(this._report_server);

    this._clk_cfg = clk_rst_config::type_id::create("clk_cfg", this);
    this._clk_cfg.clock_period = 10.0;
    uvm_config_db #(clk_rst_config)::set(this, "env.clk_agent*", "cfg", this._clk_cfg);
  endfunction

  // ---------------------------------------------------------------------------
  // Shared: create the reset sequence. Subclasses super + create protocol seqs.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this._rst_seq = reset_sequence::type_id::create("rst_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Hooks a protocol-specific base fills in.
  // ---------------------------------------------------------------------------
  virtual task body();
  endtask

  // Return the clk_rst agent's sequencer for the initial reset drive.
  protected virtual function uvm_sequencer_base get_clk_sequencer();
    return null;
  endfunction

  // Emit this test's controller telemetry (default no-op; overridden to log
  // <env>.u_mc.sprint_telemetry()).
  protected virtual function void report_telemetry(input string tag);
  endfunction

  // ---------------------------------------------------------------------------
  // Shared run: own the initial reset, run the test body, then dump telemetry.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);
    uvm_sequencer_base clk_seqr;

    super.run_phase(phase);
    phase.raise_objection(this);

    clk_seqr = this.get_clk_sequencer();
    if (clk_seqr == null) begin
      `uvm_fatal(get_name(), "vip_mc_neutral_base_test.get_clk_sequencer() returned null")
    end

    // Own the initial reset from the clk_rst agent: start() blocks until reset
    // deasserts, so the body runs against a released DUT.
    this._rst_seq.start(clk_seqr);

    this.body();
    this.report_telemetry(this.get_name());
    phase.drop_objection(this);
  endtask

  // ---------------------------------------------------------------------------
  // Shared: print the report-server summary at end of test.
  // ---------------------------------------------------------------------------
  function void report_phase(input uvm_phase phase);
    super.report_phase(phase);
    if (this._report_server != null) begin
      this._report_server.test_report();
    end
  endfunction

endclass

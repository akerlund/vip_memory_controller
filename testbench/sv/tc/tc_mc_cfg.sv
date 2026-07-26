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
// tc_mc_cfg
//
// Minimal runtime test for the new vip_mc package slice. It validates the
// owned AXI4 config object, the per-port runtime map, and the env_cfg holder /
// device-handle path against a real vip_dram instance.
// -----------------------------------------------------------------------------
class tc_mc_cfg extends mc_base_test;

  `uvm_component_utils(tc_mc_cfg)

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Validate the built vip_mc topology and the propagated config/env bindings.
  // ---------------------------------------------------------------------------
  task body();
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;

    if (this._tb_env.u_mc == null) begin
      `uvm_fatal(get_name(), "vip_mc example env did not build u_mc")
    end

    if (this._tb_env.u_mc.dram != this._tb_env.dram) begin
      `uvm_fatal(get_name(), "vip_mc did not bind the shared vip_dram instance")
    end

    if (this._tb_env.u_mc.backend == null) begin
      `uvm_fatal(get_name(), "vip_mc backend was not created")
    end

    if (this._tb_env.u_mc.backend.get_registered_port_count() != N_PORTS_C) begin
      `uvm_fatal(get_name(), "vip_mc backend did not register the expected number of ports")
    end

    if (!$cast(fe0, this._tb_env.u_mc.fes[0])) begin
      `uvm_fatal(get_name(), "vip_mc port 0 was not built as an AXI4 front-end")
    end

    if (fe0.cfg != this._tb_env.u_mc.cfg.axi4) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not receive the shared axi4 cfg handle")
    end

    if (fe0.mc_cfg != this._tb_env.u_mc.cfg) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not receive the shared MC cfg handle")
    end

    if (fe0.vif == null) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end vif handle is null")
    end

    if (this._tb_env.u_mc.cfg.axi4.aw_outstanding_limit != this._tb_env.u_mc.cfg.max_outstanding_wr) begin
      `uvm_fatal(get_name(), "vip_mc did not mirror max_outstanding_wr into axi4.aw_outstanding_limit")
    end

    if (this._tb_env.u_mc.cfg.axi4.ar_outstanding_limit != this._tb_env.u_mc.cfg.max_outstanding_rd) begin
      `uvm_fatal(get_name(), "vip_mc did not mirror max_outstanding_rd into axi4.ar_outstanding_limit")
    end

    if (this._tb_env.u_mc.cfg.axi4.qos_to_class(15) != 3) begin
      `uvm_fatal(get_name(), "qos_to_class(15) did not return the configured class")
    end

    if (!this._tb_env.u_mc.cfg.axi4.is_decerr_addr('h1800)) begin
      `uvm_fatal(get_name(), "DECERR range lookup failed inside the configured region")
    end

    if (this._tb_env.u_mc.cfg.axi4.is_decerr_addr('h2000)) begin
      `uvm_fatal(get_name(), "DECERR range lookup matched an address outside the configured region")
    end

    if (!this._tb_env.u_mc.cfg.ports[0].allows_addr(this.get_max_addr())) begin
      `uvm_fatal(get_name(), "Per-port region map rejected the top of the device address range")
    end

    if (this._tb_env.dram.cfg.addr_map != this._tb_env.u_mc.cfg.addr_map_policy) begin
      `uvm_fatal(get_name(), "vip_mc did not push addr_map_policy into vip_dram_config.addr_map")
    end

    `uvm_info(get_name(), "vip_mc config/env test passed", UVM_LOW)
  endtask

endclass
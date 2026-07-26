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
// mc_narrow_axi4_tb_env
//
// Self-contained environment for the narrow-bus (multi-beat / sub-row) AXI4
// slice: one AXI4 port at the stock 64 B host width over a device whose row is
// 128 B (NARROW_DRAM_CFG_C), so WDATA_BYTES_P (64) < ROW_BYTES_P (128). Two 64 B
// host beats gather into one 128 B row word; a single 64 B beat scatters into
// half a row. It reuses tb_top's existing 64 B AXI4 port-0 interfaces (mc_vif0 /
// man_vif0 bridged by connect0) -- only the device geometry changes -- so no new
// tb_top interfaces are needed. Mirrors the mixed-env self-contained pattern.
// -----------------------------------------------------------------------------
class mc_narrow_axi4_tb_env extends uvm_env;

  virtual clk_rst_if                          _clk_rst_vif;
  virtual vip_mc_axi4_if #(VIP_MC_AXI4_CFG_C) _mc_axi4_vif;
  virtual vip_axi4_if #(VIP_AXI4_AGENT_CFG_C, VIP_AXI4_ROLE_MANAGER_E) _man_vif;

  narrow_axi4_env_cfg_t                                 env_cfg;
  vip_dram #(NARROW_DRAM_CFG_C)                         dram;
  vip_mc   #(NARROW_DRAM_CFG_C, N_NARROW_PORTS_C, NARROW_AXI4_PORTS_C) u_mc;
  clk_rst_agent                                        clk_agent;

  vip_axi4_cfg_agent                                             man_cfg;
  vip_axi4_agent #(VIP_AXI4_AGENT_CFG_C, VIP_AXI4_ROLE_MANAGER_E) man_agent;

  `uvm_component_utils(mc_narrow_axi4_tb_env)

  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(input uvm_phase phase);
    axi4_vif_holder_t axi4_holder;

    super.build_phase(phase);

    if (!uvm_config_db #(virtual clk_rst_if)::get(this, "", "clk_rst_vif", this._clk_rst_vif)) begin
      `uvm_fatal(get_name(), "vip_mc narrow-AXI4 env requires clk_rst_vif from mc_tb_top")
    end
    uvm_config_db #(virtual clk_rst_if)::set(this, "clk_agent*", "vif", this._clk_rst_vif);
    this.clk_agent = clk_rst_agent::type_id::create("clk_agent", this);

    if (!uvm_config_db #(virtual vip_mc_axi4_if #(VIP_MC_AXI4_CFG_C))::get(
      this, "", "vif_port0", this._mc_axi4_vif)) begin
      `uvm_fatal(get_name(), "vip_mc narrow-AXI4 env requires the owned AXI4 SN vif 'vif_port0'")
    end

    this.dram = vip_dram #(NARROW_DRAM_CFG_C)::type_id::create("dram", this);

    this.env_cfg      = new("env_cfg");
    this.env_cfg.dram = this.dram;
    this.env_cfg.cfg.addr_map_policy = vip_dram_default_addr_map(NARROW_DRAM_CFG_C);
    this.env_cfg.cfg.ports[0].add_region(0, this.get_max_addr());

    axi4_holder     = new("axi4_holder");
    axi4_holder.vif = this._mc_axi4_vif;
    this.env_cfg.register_vif(0, axi4_holder);
    this.env_cfg.apply(this, "u_mc*");

    this.u_mc = vip_mc #(NARROW_DRAM_CFG_C, N_NARROW_PORTS_C, NARROW_AXI4_PORTS_C)::type_id::create(
      "u_mc", this);

    if (!uvm_config_db #(virtual vip_axi4_if #(VIP_AXI4_AGENT_CFG_C, VIP_AXI4_ROLE_MANAGER_E))::get(
      this, "", "man_vif_port0", this._man_vif)) begin
      `uvm_fatal(get_name(), "vip_mc narrow-AXI4 env requires the stock manager vif 'man_vif_port0'")
    end
    this.man_cfg = vip_axi4_cfg_agent::type_id::create("man_cfg");
    this.man_cfg.is_active             = UVM_ACTIVE;
    this.man_cfg.awvalid_delay_enabled = vip_mem_types_pkg::FALSE;
    this.man_cfg.wvalid_delay_enabled  = vip_mem_types_pkg::FALSE;
    this.man_cfg.bready_delay_enabled  = vip_mem_types_pkg::FALSE;
    this.man_cfg.rready_delay_enabled  = vip_mem_types_pkg::FALSE;
    uvm_config_db #(vip_axi4_cfg_agent)::set(this, "man_agent*", "cfg", this.man_cfg);
    uvm_config_db #(virtual vip_axi4_if #(VIP_AXI4_AGENT_CFG_C, VIP_AXI4_ROLE_MANAGER_E))::set(
      this, "man_agent*", "vif", this._man_vif);
    this.man_agent = vip_axi4_agent #(VIP_AXI4_AGENT_CFG_C, VIP_AXI4_ROLE_MANAGER_E)::type_id::create(
      "man_agent", this);
  endfunction

  protected function longint unsigned get_max_addr();
    if (NARROW_DRAM_CFG_C.ADDR_WIDTH_P >= 64) begin
      return '1;
    end
    return ((64'd1) << NARROW_DRAM_CFG_C.ADDR_WIDTH_P) - 1;
  endfunction

endclass

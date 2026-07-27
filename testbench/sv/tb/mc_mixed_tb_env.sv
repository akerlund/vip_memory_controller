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
// mc_mixed_tb_env
//
// Self-contained environment for the mixed-protocol concurrent slice: ONE vip_mc
// instance with port 0 = AXI4 and port 1 = CHI-D, over one shared backend and one
// shared vip_dram. It builds a stock vip_axi4 MANAGER agent (bridged to the AXI4
// SN port by tb_top's connect0) and a stock vip_chi RN-I agent (bridged to the
// CHI SN port by tb_top's u_chi_connect), plus a clk_rst agent so a reset_sequence
// owns clk/rst -- exactly as the single-protocol envs do. No tb_top changes are
// needed: the AXI4 port-0 interfaces (mc_vif0 / man_vif0) and the CHI-D interfaces
// (mc_chi_vif / rni_vif) already exist there and are already bridged.
//
// Only one test runs per simv, so reusing those shared interfaces is safe (the
// all-AXI4 and all-CHI envs are never built in the same run as this one).
// -----------------------------------------------------------------------------
class mc_mixed_tb_env extends uvm_env;

  virtual clk_rst_if                          _clk_rst_vif;
  virtual vip_mc_axi4_if #(VIP_MC_AXI4_CFG_C) _mc_axi4_vif;   // port 0 SN (AXI4)
  virtual vip_mc_chi_if  #(VIP_MC_CHI_CFG_C)  _mc_chi_vif;    // port 1 SN (CHI)
  virtual vip_axi4_if #(VIP_AXI4_AGENT_CFG_C, VIP_AXI4_ROLE_MANAGER_E) _man_vif;

  mixed_env_cfg_t                                       env_cfg;
  vip_dram #(DRAM_CFG_C)                                dram;
  vip_mc   #(DRAM_CFG_C, N_MIXED_PORTS_C, MIXED_PORTS_C) u_mc;
  clk_rst_agent                                        clk_agent;

  vip_axi4_cfg_agent                                             man_cfg;
  vip_axi4_agent #(VIP_AXI4_AGENT_CFG_C, VIP_AXI4_ROLE_MANAGER_E) man_agent;
  vip_chi_cfg_agent                                              rni_cfg;
  vip_chi_agent #(VIP_CHI_CFG_C, chi_types_t, VIP_CHI_ROLE_RNI_E) rni_agent;
  vip_axi4_coverage #(VIP_AXI4_AGENT_CFG_C)                       axi4_coverage;
  vip_chi_coverage  #(VIP_CHI_CFG_C)                              chi_coverage;

  `uvm_component_utils(mc_mixed_tb_env)

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Build the clk_rst agent, the shared device, the mixed vip_mc, and both the
  // AXI4 manager and CHI RN-I stimulus agents.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    axi4_vif_holder_t axi4_holder;
    chi_vif_holder_t  chi_holder;

    super.build_phase(phase);

    // Clock/reset agent drives the shared clk_rst interface.
    if (!uvm_config_db #(virtual clk_rst_if)::get(this, "", "clk_rst_vif", this._clk_rst_vif)) begin
      `uvm_fatal(get_name(), "vip_mc mixed env requires clk_rst_vif from mc_tb_top")
    end
    uvm_config_db #(virtual clk_rst_if)::set(this, "clk_agent*", "vif", this._clk_rst_vif);
    this.clk_agent = clk_rst_agent::type_id::create("clk_agent", this);

    // SN interfaces: port 0 AXI4 (vif_port0), port 1 CHI (mc_chi_vif).
    if (!uvm_config_db #(virtual vip_mc_axi4_if #(VIP_MC_AXI4_CFG_C))::get(
      this, "", "vif_port0", this._mc_axi4_vif)) begin
      `uvm_fatal(get_name(), "vip_mc mixed env requires the owned AXI4 SN vif 'vif_port0'")
    end
    if (!uvm_config_db #(virtual vip_mc_chi_if #(VIP_MC_CHI_CFG_C))::get(
      this, "", "mc_chi_vif", this._mc_chi_vif)) begin
      `uvm_fatal(get_name(), "vip_mc mixed env requires the owned CHI SN vif 'mc_chi_vif'")
    end

    // Shared device model (both front-ends target it).
    this.dram = vip_dram #(DRAM_CFG_C)::type_id::create("dram", this);

    // env_cfg: one shared vip_mc_config, both ports own the full device.
    this.env_cfg      = new("env_cfg");
    this.env_cfg.dram = this.dram;
    this.env_cfg.cfg.addr_map_policy = vip_dram_default_addr_map(DRAM_CFG_C);
    for (int p = 0; p < N_MIXED_PORTS_C; p++) begin
      this.env_cfg.cfg.ports[p].add_region(0, this.get_max_addr());
    end

    axi4_holder     = new("axi4_holder");
    axi4_holder.vif = this._mc_axi4_vif;
    this.env_cfg.register_vif(0, axi4_holder);

    chi_holder      = chi_vif_holder_t::type_id::create("chi_holder");
    chi_holder.vif  = this._mc_chi_vif;
    this.env_cfg.register_vif(1, chi_holder);

    this.env_cfg.apply(this, "u_mc*");

    this.u_mc = vip_mc #(DRAM_CFG_C, N_MIXED_PORTS_C, MIXED_PORTS_C)::type_id::create("u_mc", this);

    // AXI4 MANAGER agent on port 0's manager interface.
    if (!uvm_config_db #(virtual vip_axi4_if #(VIP_AXI4_AGENT_CFG_C, VIP_AXI4_ROLE_MANAGER_E))::get(
      this, "", "man_vif_port0", this._man_vif)) begin
      `uvm_fatal(get_name(), "vip_mc mixed env requires the stock manager vif 'man_vif_port0'")
    end
    this.man_cfg = vip_axi4_cfg_agent::type_id::create("man_cfg");
    this.man_cfg.is_active            = UVM_ACTIVE;
    this.man_cfg.awvalid_delay_enabled = vip_mem_types_pkg::FALSE;
    this.man_cfg.wvalid_delay_enabled  = vip_mem_types_pkg::FALSE;
    this.man_cfg.bready_delay_enabled  = vip_mem_types_pkg::FALSE;
    this.man_cfg.rready_delay_enabled  = vip_mem_types_pkg::FALSE;
    uvm_config_db #(vip_axi4_cfg_agent)::set(this, "man_agent*", "cfg", this.man_cfg);
    uvm_config_db #(virtual vip_axi4_if #(VIP_AXI4_AGENT_CFG_C, VIP_AXI4_ROLE_MANAGER_E))::set(
      this, "man_agent*", "vif", this._man_vif);
    this.man_agent = vip_axi4_agent #(VIP_AXI4_AGENT_CFG_C, VIP_AXI4_ROLE_MANAGER_E)::type_id::create(
      "man_agent", this);

    // CHI RN-I manager agent on the CHI-D manager interface (tb_top sets its vif
    // at uvm_test_top.env.rni_agent, matching this component's path).
    this.rni_cfg = vip_chi_cfg_agent::type_id::create("rni_cfg");
    this.rni_cfg.role      = VIP_CHI_ROLE_RNI_E;
    this.rni_cfg.is_active = UVM_ACTIVE;
    uvm_config_db #(vip_chi_cfg_agent)::set(this, "rni_agent", "cfg", this.rni_cfg);
    this.rni_agent = vip_chi_agent #(VIP_CHI_CFG_C, chi_types_t, VIP_CHI_ROLE_RNI_E)::type_id::create(
      "rni_agent", this);

    this.build_coverage();
  endfunction

  // ---------------------------------------------------------------------------
  // Protocol coverage on both host legs of the mixed topology. Opt out with
  // mc_coverage_enabled = 0.
  // ---------------------------------------------------------------------------
  protected function void build_coverage();
    int cov_enabled;

    cov_enabled = 1;
    void'(uvm_config_db #(int)::get(this, "", "mc_coverage_enabled", cov_enabled));
    if (cov_enabled == 0) begin
      return;
    end

    uvm_config_db #(
      virtual vip_axi4_if #(VIP_AXI4_AGENT_CFG_C, VIP_AXI4_ROLE_MANAGER_E)
    )::set(this, "axi4_coverage", "vif", this._man_vif);
    this.axi4_coverage = vip_axi4_coverage #(
      VIP_AXI4_AGENT_CFG_C)::type_id::create("axi4_coverage", this);
    this.chi_coverage = vip_chi_coverage #(
      VIP_CHI_CFG_C)::type_id::create("chi_coverage", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Connect both host legs to their coverage collectors.
  // ---------------------------------------------------------------------------
  function void connect_phase(input uvm_phase phase);
    super.connect_phase(phase);

    if (this.axi4_coverage != null) begin
      this.man_agent.monitor.bresp_port.connect(this.axi4_coverage.wr_cov_port);
      this.man_agent.monitor.rdata_port.connect(this.axi4_coverage.rd_cov_port);
    end

    if (this.chi_coverage != null) begin
      this.rni_agent.req_port.connect(this.chi_coverage.rni_req_cov_port);
      this.rni_agent.rsp_port.connect(this.chi_coverage.rni_rsp_cov_port);
      this.rni_agent.dat_port.connect(this.chi_coverage.rni_dat_cov_port);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Return the highest byte address representable by DRAM_CFG_C.
  // ---------------------------------------------------------------------------
  protected function longint unsigned get_max_addr();
    if (DRAM_CFG_C.ADDR_WIDTH_P >= 64) begin
      return '1;
    end
    return ((64'd1) << DRAM_CFG_C.ADDR_WIDTH_P) - 1;
  endfunction

endclass

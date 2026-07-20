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
// vip_mc_chi_tb_env
//
// Self-contained environment for the CHI slice of the vip_mc example. It owns a
// shared vip_dram device, a stock vip_chi RN-I manager agent for stimulus, a
// clk_rst agent (so a reset_sequence owns clk/rst on the shared clk_rst
// interface, exactly as the AXI4 slice does), and a one-port CHI vip_mc
// instance. The RN-I interface and vip_mc's SN interface are bridged by the
// vip_mc_chi_connect that lives in vip_mc_tb_top; here we only build components
// and publish the env_cfg that hands vip_mc its device handle and SN vif.
//
// This mirrors the tc_vip_mc_multi_rank self-contained-env pattern: it reuses
// the shared tb_top interfaces but builds its own device/mc/agents, so the
// default two-port AXI4 topology and its tests are left completely untouched.
//
// The env is parameterized over the (vip_chi, vip_mc) CHI cfg pair so the same
// class serves the D/E matrix: a CHI-D test builds it with the default D cfgs,
// a CHI-E test with VIP_CHI_CFG_E_C / VIP_MC_CHI_CFG_E_C. Since only one test
// runs per simv, both families can share the same config_db keys published by
// tb_top (uvm_config_db separates entries by their parameterized vif type).
// -----------------------------------------------------------------------------
class vip_mc_chi_tb_env #(
  vip_chi_cfg_t    CHI_CFG_P    = VIP_CHI_CFG_C,
  vip_mc_chi_cfg_t MC_CHI_CFG_P = VIP_MC_CHI_CFG_C
  ) extends uvm_env;

  // One CHI port, derived from the selected vip_mc CHI cfg.
  localparam int N_CHI_PORTS_L = 1;
  localparam vip_mc_port_cfg_t CHI_PORTS_L [N_CHI_PORTS_L] = '{
    '{proto: VIP_MC_PROTO_CHI_E, axi4: '0, chi: MC_CHI_CFG_P}
  };

  typedef vip_chi_types   #(CHI_CFG_P)                                chi_types_l_t;
  typedef vip_mc_env_cfg  #(DRAM_CFG_C, N_CHI_PORTS_L, CHI_PORTS_L)   env_cfg_l_t;
  typedef vip_mc_chi_vif_holder #(MC_CHI_CFG_P)                       holder_l_t;

  virtual vip_mc_chi_if #(MC_CHI_CFG_P) _mc_vif;
  virtual clk_rst_if                    _clk_rst_vif;

  env_cfg_l_t                           env_cfg;
  vip_dram #(DRAM_CFG_C)                dram;
  vip_mc   #(DRAM_CFG_C, N_CHI_PORTS_L, CHI_PORTS_L) u_mc;
  clk_rst_agent                         clk_agent;

  vip_chi_cfg_agent                                                rni_cfg;
  vip_chi_agent #(CHI_CFG_P, chi_types_l_t, VIP_CHI_ROLE_RNI_E)    rni_agent;

  `uvm_component_param_utils(vip_mc_chi_tb_env #(CHI_CFG_P, MC_CHI_CFG_P))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Build the clk_rst agent, the device, the RN-I manager, and the vip_mc top.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    holder_l_t holder;
    int        chi_split_write_rsp;

    super.build_phase(phase);

    // Clock/reset agent drives the shared clk_rst interface (same as the AXI4
    // slice) so a reset_sequence owns clk and rst_n.
    if (!uvm_config_db #(virtual clk_rst_if)::get(this, "", "clk_rst_vif", this._clk_rst_vif)) begin
      `uvm_fatal(get_name(), "vip_mc CHI example env requires clk_rst_vif from vip_mc_tb_top")
    end
    uvm_config_db #(virtual clk_rst_if)::set(this, "clk_agent*", "vif", this._clk_rst_vif);
    this.clk_agent = clk_rst_agent::type_id::create("clk_agent", this);

    if (!uvm_config_db #(virtual vip_mc_chi_if #(MC_CHI_CFG_P))::get(
      this, "", "mc_chi_vif", this._mc_vif)) begin
      `uvm_fatal(get_name(), "vip_mc CHI example env requires mc_chi_vif from vip_mc_tb_top")
    end

    // Device model (TB-owned; passed to vip_mc via env_cfg).
    this.dram = vip_dram #(DRAM_CFG_C)::type_id::create("dram", this);

    // Stock vip_chi RN-I manager for stimulus.
    this.rni_cfg = vip_chi_cfg_agent::type_id::create("rni_cfg");
    this.rni_cfg.role      = VIP_CHI_ROLE_RNI_E;
    this.rni_cfg.is_active = UVM_ACTIVE;
    uvm_config_db #(vip_chi_cfg_agent)::set(this, "rni_agent", "cfg", this.rni_cfg);
    this.rni_agent = vip_chi_agent #(CHI_CFG_P, chi_types_l_t, VIP_CHI_ROLE_RNI_E)::type_id::create(
      "rni_agent", this);

    // One env_cfg hands vip_mc its device handle + SN vif holder.
    this.env_cfg      = env_cfg_l_t::type_id::create("env_cfg");
    this.env_cfg.dram = this.dram;

    // MC-native CHI knobs (vip_mc_chi_cfg): the split-write style is test-
    // selectable (default 1 = DBIDResp+deferred Comp; 0 = combined CompDBIDResp);
    // credits/node id keep their defaults.
    chi_split_write_rsp = 1;
    void'(uvm_config_db #(int)::get(this, "", "mc_chi_split_write_rsp", chi_split_write_rsp));
    this.env_cfg.cfg.chi.split_write_rsp = (chi_split_write_rsp != 0);

    // Install the MC-owned DECERR window used by the decerr test (the CHI driver
    // reuses the shared axi4 DECERR map, exactly as the AXI4 front-end does).
    this.env_cfg.cfg.axi4.add_decerr_range(CHI_DECERR_LO_C, CHI_DECERR_HI_C);

    holder            = holder_l_t::type_id::create("mc_chi_holder");
    holder.vif        = this._mc_vif;
    this.env_cfg.register_vif(0, holder);
    this.env_cfg.apply(this, "u_mc*");

    this.u_mc = vip_mc #(DRAM_CFG_C, N_CHI_PORTS_L, CHI_PORTS_L)::type_id::create("u_mc", this);
  endfunction

endclass

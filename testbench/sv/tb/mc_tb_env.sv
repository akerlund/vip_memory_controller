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
// mc_tb_env
//
// Executable environment for the vip_mc example harness. It instantiates the
// shared vip_dram model, binds the homogeneous AXI4 host interfaces, and
// publishes one env_cfg object to the vip_mc top.
// -----------------------------------------------------------------------------
class mc_tb_env extends uvm_env;

  virtual vip_mc_axi4_if #(VIP_MC_AXI4_CFG_C) _mc_vif[N_PORTS_C];
  virtual vip_axi4_if #(VIP_AXI4_AGENT_CFG_C, VIP_AXI4_ROLE_MANAGER_E) _man_vif[N_PORTS_C];
  virtual vip_mc_status_if #(N_PORTS_C) _status_vif;
  virtual clk_rst_if                    _clk_rst_vif;

  env_cfg_t                                env_cfg;
  vip_dram #(DRAM_CFG_C) dram;
  vip_mc   #(DRAM_CFG_C, N_PORTS_C, PORTS_C) u_mc;
  vip_axi4_cfg_agent                                        man_cfg[N_PORTS_C];
  vip_axi4_agent #(VIP_AXI4_AGENT_CFG_C, VIP_AXI4_ROLE_MANAGER_E) man_agent[N_PORTS_C];
  clk_rst_agent                                             clk_agent;
  mc_scoreboard                                             scoreboard;

  `uvm_component_utils(mc_tb_env)

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Build the DRAM device model used by the config test.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    axi4_vif_holder_t vif_holder;
    vip_dram_addr_map_t default_map;
    real mc_trefi_override_ns;
    int  mc_refresh_enabled;
    int  mc_refresh_policy;
    int  mc_refresh_max_deferred;
    int  mc_init_delay_enabled;
    real mc_init_delay_ns;
    int  mc_rsp_buf_depth;
    int  mc_w_data_buf_depth;
    int  mc_honor_beat_timing;
    int  mc_max_inflight_to_device;
    int  manager_agents_active;
    int  man_wr_outstanding_max;
    int  man_rd_outstanding_max;
    string vif_key;
    string man_vif_key;
    string agent_name;

    super.build_phase(phase);

    // Clock/reset agent: resolve the shared clk_rst interface from tb_top and
    // hand it to the agent's driver/monitor so a reset_sequence (started by the
    // base test) owns clk and rst_n instead of hand-rolled tb_top logic.
    if (!uvm_config_db #(virtual clk_rst_if)::get(this, "", "clk_rst_vif", this._clk_rst_vif)) begin
      `uvm_fatal(get_name(), "vip_mc example env requires clk_rst_vif from mc_tb_top")
    end
    uvm_config_db #(virtual clk_rst_if)::set(this, "clk_agent*", "vif", this._clk_rst_vif);
    this.clk_agent = clk_rst_agent::type_id::create("clk_agent", this);

    for (int port_id = 0; port_id < N_PORTS_C; port_id++) begin
      vif_key = $sformatf("vif_port%0d", port_id);
      if (!uvm_config_db #(virtual vip_mc_axi4_if #(VIP_MC_AXI4_CFG_C))::get(
        this,
        "",
        vif_key,
        this._mc_vif[port_id]
      )) begin
        `uvm_fatal(get_name(), $sformatf(
          "vip_mc example env requires the owned AXI4 vif under key '%s'",
          vif_key))
      end
    end

    void'(uvm_config_db #(virtual vip_mc_status_if #(N_PORTS_C))::get(
      this,
      "",
      "status_vif",
      this._status_vif));

    this.dram = vip_dram #(DRAM_CFG_C)::type_id::create("dram", this);

    this.env_cfg = new("env_cfg");
    default_map = vip_dram_default_addr_map(DRAM_CFG_C);
    this.env_cfg.cfg.qos_class_count         = 4;
    this.env_cfg.cfg.qos_aging_ns            = 25.0;
    this.env_cfg.cfg.max_outstanding_rd      = 8;
    this.env_cfg.cfg.max_outstanding_wr      = 8;
    this.env_cfg.cfg.rsp_buf_depth           = 2;
    this.env_cfg.cfg.axi4.aw_pending_depth   = 2;
    this.env_cfg.cfg.axi4.w_data_buf_depth   = 4;
    this.env_cfg.cfg.axi4.qos_class_map[15]  = 3;
    this.env_cfg.cfg.axi4.add_decerr_range('h1000, 'h1FFF);
    this.env_cfg.cfg.addr_map_policy = default_map;
    this.env_cfg.cfg.addr_map_policy.bank_lsb = default_map.bg_lsb;
    this.env_cfg.cfg.addr_map_policy.bg_lsb   = default_map.bank_lsb;
    for (int port_id = 0; port_id < N_PORTS_C; port_id++) begin
      this.env_cfg.cfg.ports[port_id].add_region(0, this.get_max_addr());
    end

    if (uvm_config_db #(real)::get(this, "", "mc_trefi_override_ns", mc_trefi_override_ns)) begin
      this.env_cfg.cfg.tREFI_override = mc_trefi_override_ns;
    end

    if (uvm_config_db #(int)::get(this, "", "mc_refresh_enabled", mc_refresh_enabled)) begin
      this.env_cfg.cfg.refresh_enabled = mc_refresh_enabled ? TRUE : FALSE;
    end

    if (uvm_config_db #(int)::get(this, "", "mc_refresh_policy", mc_refresh_policy)) begin
      this.env_cfg.cfg.refresh_policy =
        (mc_refresh_policy != 0) ? VIP_MC_REFRESH_DEFERRED_E : VIP_MC_REFRESH_PERIODIC_E;
    end

    if (uvm_config_db #(int)::get(this, "", "mc_refresh_max_deferred", mc_refresh_max_deferred)) begin
      this.env_cfg.cfg.refresh_max_deferred = mc_refresh_max_deferred;
    end

    if (uvm_config_db #(int)::get(this, "", "mc_init_delay_enabled", mc_init_delay_enabled)) begin
      this.env_cfg.cfg.init_delay_enabled = mc_init_delay_enabled ? TRUE : FALSE;
    end

    if (uvm_config_db #(real)::get(this, "", "mc_init_delay_ns", mc_init_delay_ns)) begin
      this.env_cfg.cfg.init_delay_ns = mc_init_delay_ns;
    end

    if (uvm_config_db #(int)::get(this, "", "mc_rsp_buf_depth", mc_rsp_buf_depth)) begin
      this.env_cfg.cfg.rsp_buf_depth = mc_rsp_buf_depth;
    end

    if (uvm_config_db #(int)::get(this, "", "mc_w_data_buf_depth", mc_w_data_buf_depth)) begin
      this.env_cfg.cfg.axi4.w_data_buf_depth = mc_w_data_buf_depth;
    end

    if (uvm_config_db #(int)::get(this, "", "mc_honor_beat_timing", mc_honor_beat_timing)) begin
      this.env_cfg.cfg.honor_beat_timing = mc_honor_beat_timing ? TRUE : FALSE;
    end

    if (uvm_config_db #(int)::get(this, "", "mc_max_inflight_to_device", mc_max_inflight_to_device)) begin
      this.env_cfg.cfg.max_inflight_to_device = mc_max_inflight_to_device;
    end

    manager_agents_active = 0;
    void'(uvm_config_db #(int)::get(this, "", "manager_agents_active", manager_agents_active));

    // Manager write / read pipelining depth (default 1 = serial). A test sets
    // these > 1 to let the stock manager hold multiple writes / reads outstanding
    // (e.g. write coalescing needs two same-line writes co-pending).
    man_wr_outstanding_max = 1;
    void'(uvm_config_db #(int)::get(this, "", "man_wr_outstanding_max", man_wr_outstanding_max));
    man_rd_outstanding_max = 1;
    void'(uvm_config_db #(int)::get(this, "", "man_rd_outstanding_max", man_rd_outstanding_max));

    this.env_cfg.dram = this.dram;
    this.env_cfg.status_vif = this._status_vif;

    for (int port_id = 0; port_id < N_PORTS_C; port_id++) begin
      vif_holder = new($sformatf("vif_holder_%0d", port_id));
      vif_holder.vif = this._mc_vif[port_id];
      this.env_cfg.register_vif(port_id, vif_holder);
    end
    this.env_cfg.apply(this, "u_mc");

    this.u_mc = vip_mc #(DRAM_CFG_C, N_PORTS_C, PORTS_C)::type_id::create(
      "u_mc",
      this);

    if (manager_agents_active != 0) begin
      for (int port_id = 0; port_id < N_PORTS_C; port_id++) begin
        man_vif_key = $sformatf("man_vif_port%0d", port_id);
        if (!uvm_config_db #(
          virtual vip_axi4_if #(VIP_AXI4_AGENT_CFG_C, VIP_AXI4_ROLE_MANAGER_E)
        )::get(
          this,
          "",
          man_vif_key,
          this._man_vif[port_id]
        )) begin
          `uvm_fatal(get_name(), $sformatf(
            "vip_mc example env requires the stock manager vif under key '%s'",
            man_vif_key))
        end

        agent_name = $sformatf("man_agent_%0d", port_id);
        this.man_cfg[port_id] = vip_axi4_cfg_agent::type_id::create(
          $sformatf("man_cfg_%0d", port_id));
        this.man_cfg[port_id].is_active = UVM_ACTIVE;
        this.man_cfg[port_id].awvalid_delay_enabled = vip_mem_types_pkg::FALSE;
        this.man_cfg[port_id].wvalid_delay_enabled  = vip_mem_types_pkg::FALSE;
        this.man_cfg[port_id].bready_delay_enabled  = vip_mem_types_pkg::FALSE;
        this.man_cfg[port_id].rready_delay_enabled  = vip_mem_types_pkg::FALSE;
        this.man_cfg[port_id].wr_outstanding_max    = man_wr_outstanding_max;
        this.man_cfg[port_id].rd_outstanding_max    = man_rd_outstanding_max;

        uvm_config_db #(vip_axi4_cfg_agent)::set(
          this,
          {agent_name, "*"},
          "cfg",
          this.man_cfg[port_id]);
        uvm_config_db #(
          virtual vip_axi4_if #(VIP_AXI4_AGENT_CFG_C, VIP_AXI4_ROLE_MANAGER_E)
        )::set(
          this,
          {agent_name, "*"},
          "vif",
          this._man_vif[port_id]);
        this.man_agent[port_id] = vip_axi4_agent #(
          VIP_AXI4_AGENT_CFG_C,
          VIP_AXI4_ROLE_MANAGER_E
        )::type_id::create(agent_name, this);
      end
    end

    this.build_timing_scoreboard();
  endfunction

  // ---------------------------------------------------------------------------
  // Build the latency scoreboard (§13.2 / P0-2b). Enabled by default; a test
  // can disable it or relax the timing check via config_db.
  // ---------------------------------------------------------------------------
  protected function void build_timing_scoreboard();
    int  sb_enabled;
    int  sb_timing_check;
    real sb_tol_ns;

    sb_enabled = 1;
    void'(uvm_config_db #(int)::get(this, "", "mc_scoreboard_enabled", sb_enabled));
    if (sb_enabled == 0) begin
      return;
    end

    this.scoreboard      = mc_scoreboard::type_id::create("scoreboard", this);
    this.scoreboard.dram = this.dram;

    sb_timing_check = 1;
    if (uvm_config_db #(int)::get(this, "", "mc_scoreboard_timing_check", sb_timing_check)) begin
      this.scoreboard.timing_check_enabled = (sb_timing_check != 0);
    end

    if (uvm_config_db #(real)::get(this, "", "mc_scoreboard_tol_ns", sb_tol_ns)) begin
      this.scoreboard.timing_tol_ns = sb_tol_ns;
    end

    if (uvm_config_db #(real)::get(this, "", "mc_scoreboard_beat_period_ns", sb_tol_ns)) begin
      this.scoreboard.beat_period_ns = sb_tol_ns;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Connect the scoreboard to the backend grant tap and the manager B/R taps.
  // ---------------------------------------------------------------------------
  function void connect_phase(input uvm_phase phase);
    super.connect_phase(phase);

    if (this.scoreboard == null) begin
      return;
    end

    this.u_mc.backend.issued_port.connect(this.scoreboard.issued_export);

    for (int port_id = 0; port_id < N_PORTS_C; port_id++) begin
      if (this.man_agent[port_id] != null) begin
        this.man_agent[port_id].monitor.bresp_port.connect(
          this.scoreboard.b_collector[port_id].analysis_export);
        this.man_agent[port_id].monitor.rdata_port.connect(
          this.scoreboard.r_collector[port_id].analysis_export);
      end
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
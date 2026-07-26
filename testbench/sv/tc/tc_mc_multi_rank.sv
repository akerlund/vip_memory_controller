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
// tc_mc_multi_rank  (§13.3 #13 / P1-3)
//
// Multi-rank sanity for the vip_mc example. This test uses a 2-rank DRAM
// geometry (same AXI widths as the default harness), proves both ranks accept
// traffic, and observes REF for both ranks off backend.issued_port.
// -----------------------------------------------------------------------------

localparam vip_dram_cfg_t DRAM_CFG_2R_C = '{
  ROW_BYTES_P          : 64,
  ADDR_WIDTH_P         : 33,
  N_RANKS_P            : 2,
  N_BANK_GROUPS_P      : 4,
  BANKS_PER_BG_P       : 4,
  ROW_BITS_P           : 12,
  COL_BITS_P           : 10,
  DEVICE_WIDTH_P       : 8,
  N_DEVICES_PER_RANK_P : 8
};

typedef vip_mc_env_cfg #(DRAM_CFG_2R_C, N_PORTS_C, PORTS_C) env_cfg_2r_t;

class mc_multirank_grant_collector extends uvm_subscriber #(vip_mc_cmd_entry #(DRAM_CFG_2R_C));
  vip_dram_addr_map_t addr_map;
  int                 grant_op[$];
  int                 grant_rank[$];
  int                 grant_port[$];
  longint unsigned    grant_id[$];

  `uvm_component_utils(mc_multirank_grant_collector)

  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  function void write(input vip_mc_cmd_entry #(DRAM_CFG_2R_C) t);
    vip_dram_dec_t dec;
    int            rank;

    if (t == null) begin
      return;
    end

    if (t.op == VIP_DRAM_OP_REF_E) begin
      rank = t.rank;
    end
    else begin
      dec  = vip_dram_decode_addr(t.addr, DRAM_CFG_2R_C, this.addr_map);
      rank = dec.rank;
    end

    this.grant_op.push_back(int'(t.op));
    this.grant_rank.push_back(rank);
    this.grant_port.push_back(t.port_id);
    this.grant_id.push_back(t.axi4_id);
  endfunction

  function void clear();
    this.grant_op.delete();
    this.grant_rank.delete();
    this.grant_port.delete();
    this.grant_id.delete();
  endfunction
endclass

class mc_multirank_tb_env extends uvm_env;

  virtual vip_mc_axi4_if #(VIP_MC_AXI4_CFG_C) _mc_vif[N_PORTS_C];
  virtual vip_axi4_if #(VIP_AXI4_AGENT_CFG_C, VIP_AXI4_ROLE_MANAGER_E) _man_vif[N_PORTS_C];
  virtual clk_rst_if                          _clk_rst_vif;

  env_cfg_2r_t                               env_cfg;
  vip_dram #(DRAM_CFG_2R_C)                  dram;
  vip_mc   #(DRAM_CFG_2R_C, N_PORTS_C, PORTS_C) u_mc;
  vip_axi4_cfg_agent                                        man_cfg[N_PORTS_C];
  vip_axi4_agent #(VIP_AXI4_AGENT_CFG_C, VIP_AXI4_ROLE_MANAGER_E) man_agent[N_PORTS_C];
  clk_rst_agent                                             clk_agent;

  `uvm_component_utils(mc_multirank_tb_env)

  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(input uvm_phase phase);
    axi4_vif_holder_t   vif_holder;
    vip_dram_addr_map_t default_map;
    real                mc_trefi_override_ns;
    int                 mc_refresh_enabled;
    int                 mc_rsp_buf_depth;
    int                 mc_w_data_buf_depth;
    int                 mc_max_inflight_to_device;
    string              vif_key;
    string              man_vif_key;
    string              agent_name;

    super.build_phase(phase);

    // Clock/reset agent drives the shared clk_rst interface (same as the base
    // example env) so a reset_sequence owns clk and rst_n.
    if (!uvm_config_db #(virtual clk_rst_if)::get(this, "", "clk_rst_vif", this._clk_rst_vif)) begin
      `uvm_fatal(get_name(), "vip_mc multi-rank env requires clk_rst_vif from mc_tb_top")
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
          "vip_mc multi-rank env requires the owned AXI4 vif under key '%s'",
          vif_key))
      end
    end

    this.dram = vip_dram #(DRAM_CFG_2R_C)::type_id::create("dram", this);

    this.env_cfg = new("env_cfg");
    default_map = vip_dram_default_addr_map(DRAM_CFG_2R_C);
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
    if (uvm_config_db #(int)::get(this, "", "mc_rsp_buf_depth", mc_rsp_buf_depth)) begin
      this.env_cfg.cfg.rsp_buf_depth = mc_rsp_buf_depth;
    end
    if (uvm_config_db #(int)::get(this, "", "mc_w_data_buf_depth", mc_w_data_buf_depth)) begin
      this.env_cfg.cfg.axi4.w_data_buf_depth = mc_w_data_buf_depth;
    end
    if (uvm_config_db #(int)::get(this, "", "mc_max_inflight_to_device", mc_max_inflight_to_device)) begin
      this.env_cfg.cfg.max_inflight_to_device = mc_max_inflight_to_device;
    end

    this.env_cfg.dram = this.dram;

    for (int port_id = 0; port_id < N_PORTS_C; port_id++) begin
      vif_holder = new($sformatf("vif_holder_%0d", port_id));
      vif_holder.vif = this._mc_vif[port_id];
      this.env_cfg.register_vif(port_id, vif_holder);
    end
    this.env_cfg.apply(this, "u_mc");

    this.u_mc = vip_mc #(DRAM_CFG_2R_C, N_PORTS_C, PORTS_C)::type_id::create(
      "u_mc",
      this);

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
          "vip_mc multi-rank env requires the stock manager vif under key '%s'",
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
  endfunction

  protected function longint unsigned get_max_addr();
    if (DRAM_CFG_2R_C.ADDR_WIDTH_P >= 64) begin
      return '1;
    end
    return ((64'd1) << DRAM_CFG_2R_C.ADDR_WIDTH_P) - 1;
  endfunction
endclass

class mc_multirank_base_test extends mc_neutral_base_test;

  `uvm_component_utils(mc_multirank_base_test)

  localparam int unsigned SEQ_TIMEOUT_CYCLES_C = 256;

  typedef vip_axi4_item #(VIP_AXI4_AGENT_CFG_C) axi4_item_t;
  typedef logic [(8 * VIP_MC_AXI4_CFG_C.WDATA_BYTES_P) - 1 : 0] wdata_t;
  typedef logic [VIP_MC_AXI4_CFG_C.WDATA_BYTES_P - 1 : 0]       wstrb_t;
  typedef logic [(8 * VIP_MC_AXI4_CFG_C.RDATA_BYTES_P) - 1 : 0] rdata_t;
  typedef logic [1 : 0]                                          resp_t;

  mc_multirank_tb_env _tb_env;

  // Manager traffic sequences declared + created once (start_of_simulation);
  // the helpers only configure + start them per transaction.
  vip_axi4_write_seq #(VIP_AXI4_AGENT_CFG_C) _man_wr_seq;
  vip_axi4_read_seq  #(VIP_AXI4_AGENT_CFG_C) _man_rd_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(input uvm_phase phase);
    // super.build_phase configures the phase timeout, report server, and the
    // clk_rst agent (10 ns) shared by every vip_mc example test.
    super.build_phase(phase);
    this._tb_env = mc_multirank_tb_env::type_id::create("env", this);
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    // super.start_of_simulation_phase creates the shared reset sequence.
    super.start_of_simulation_phase(phase);
    this._man_wr_seq = vip_axi4_write_seq #(VIP_AXI4_AGENT_CFG_C)::type_id::create("man_wr_seq");
    this._man_rd_seq = vip_axi4_read_seq  #(VIP_AXI4_AGENT_CFG_C)::type_id::create("man_rd_seq");
  endfunction

  // Neutral-base hooks: clk_rst sequencer for the shared reset drive + telemetry.
  protected function uvm_sequencer_base get_clk_sequencer();
    return this._tb_env.clk_agent.sequencer;
  endfunction

  protected function void report_telemetry(input string tag);
    if ((this._tb_env == null) || (this._tb_env.u_mc == null)) begin
      return;
    end
    `uvm_info(tag, this._tb_env.u_mc.sprint_telemetry(), UVM_LOW)
  endfunction

  protected task wait_for_reset_release_on_port(input int unsigned port_id);
    wait (this._tb_env._man_vif[port_id].rst_n === 1'b1);
    repeat (2) @(negedge this._tb_env._man_vif[port_id].clk);
  endtask

  protected task wait_for_reset_release();
    this.wait_for_reset_release_on_port(0);
  endtask

  protected function logic [2 : 0] get_full_width_axi_size();
    logic [2 : 0] size;
    size = $clog2(VIP_MC_AXI4_CFG_C.WDATA_BYTES_P);
    return size;
  endfunction

  protected function vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_2R_C) get_port_fe(
    input int unsigned port_id
  );
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_2R_C) fe;

    if ((this._tb_env == null) ||
        (this._tb_env.u_mc == null) ||
        (port_id >= N_PORTS_C) ||
        !$cast(fe, this._tb_env.u_mc.fes[port_id])) begin
      `uvm_fatal(get_name(), $sformatf(
        "vip_mc multi-rank port %0d was not built as an AXI4 front-end",
        port_id))
    end

    return fe;
  endfunction

  protected function rdata_t flatten_read_beat(
    input axi4_item_t   rsp,
    input int unsigned  beat_idx
  );
    rdata_t flat_rdata;

    flat_rdata = '0;
    if (rsp.rdata.size() <= beat_idx) begin
      return flat_rdata;
    end

    for (int byte_idx = 0; byte_idx < VIP_AXI4_AGENT_CFG_C.RDATA_BYTES_P; byte_idx++) begin
      flat_rdata[(8 * byte_idx) +: 8] = rsp.rdata[beat_idx][byte_idx];
    end

    return flat_rdata;
  endfunction

  protected task start_seq_or_timeout(
    input uvm_sequence_base                                  seq,
    input uvm_sequencer_base                                 sequencer,
    input vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_2R_C) fe,
    input int unsigned                                       port_id,
    input string                                             seq_name
  );
    bit seq_done;

    seq_done = 1'b0;
    fork
      begin
        seq.start(sequencer);
        seq_done = 1'b1;
      end
      begin
        repeat (SEQ_TIMEOUT_CYCLES_C) @(posedge this._tb_env._man_vif[port_id].clk);
        if (!seq_done) begin
          `uvm_fatal(get_name(), $sformatf(
            "%s timed out on port %0d after %0d cycles man{awv=%0b awr=%0b wv=%0b wr=%0b bv=%0b br=%0b arv=%0b arr=%0b rv=%0b rr=%0b} mc{awv=%0b awr=%0b wv=%0b wr=%0b bv=%0b br=%0b arv=%0b arr=%0b rv=%0b rr=%0b} fe{obs_aw=%0d obs_w=%0d obs_ar=%0d inflight_wr=%0d inflight_rd=%0d complete=%0d decerr=%0d 4k=%0d}",
            seq_name,
            port_id,
            SEQ_TIMEOUT_CYCLES_C,
            this._tb_env._man_vif[port_id].awvalid,
            this._tb_env._man_vif[port_id].awready,
            this._tb_env._man_vif[port_id].wvalid,
            this._tb_env._man_vif[port_id].wready,
            this._tb_env._man_vif[port_id].bvalid,
            this._tb_env._man_vif[port_id].bready,
            this._tb_env._man_vif[port_id].arvalid,
            this._tb_env._man_vif[port_id].arready,
            this._tb_env._man_vif[port_id].rvalid,
            this._tb_env._man_vif[port_id].rready,
            this._tb_env._mc_vif[port_id].awvalid,
            this._tb_env._mc_vif[port_id].awready,
            this._tb_env._mc_vif[port_id].wvalid,
            this._tb_env._mc_vif[port_id].wready,
            this._tb_env._mc_vif[port_id].bvalid,
            this._tb_env._mc_vif[port_id].bready,
            this._tb_env._mc_vif[port_id].arvalid,
            this._tb_env._mc_vif[port_id].arready,
            this._tb_env._mc_vif[port_id].rvalid,
            this._tb_env._mc_vif[port_id].rready,
            fe.observed_aw_count,
            fe.observed_w_count,
            fe.observed_ar_count,
            fe.inflight_wr_count,
            fe.inflight_rd_count,
            fe.complete_count,
            fe.get_decerr_count(),
            fe.get_4k_violation_count()))
        end
      end
    join_any
    disable fork;
  endtask

  protected task axi4_write_single_on_port(
    input int unsigned                                    port_id,
    input logic [VIP_MC_AXI4_CFG_C.AWID_WIDTH_P - 1 : 0] awid,
    input logic [3 : 0]                                   awqos,
    input longint unsigned                                addr,
    input wdata_t                                         data,
    input wstrb_t                                         strb,
    output resp_t                                         bresp
  );
    vip_axi4_write_seq #(VIP_AXI4_AGENT_CFG_C)           wr_seq;
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_2R_C) fe;
    axi4_item_t                                           wr_rsp_q[$];
    vip_axi4_types #(VIP_AXI4_AGENT_CFG_C)::wdata_t       man_data_q[$];
    vip_axi4_types #(VIP_AXI4_AGENT_CFG_C)::wstrb_t       man_strb_q[$];

    fe = this.get_port_fe(port_id);
    man_data_q.push_back(data);
    man_strb_q.push_back(strb);

    // Configure + start the base-test-owned write sequence for this transaction.
    wr_seq = this._man_wr_seq;
    wr_seq.reset();
    wr_seq.set_awid(awid);
    wr_seq.set_axaddr(addr);
    wr_seq.set_axlen(0);
    wr_seq.set_axsize(this.get_full_width_axi_size());
    wr_seq.set_axburst(VIP_AXI4_BURST_INCR_C);
    wr_seq.set_axqos(awqos);
    wr_seq.set_requests(1);
    wr_seq.set_get_wr_response(1'b1);
    wr_seq.set_wdata_type(VIP_AXI4_DATA_CUSTOM_E);
    wr_seq.set_wstrb_type(VIP_AXI4_STRB_CUSTOM_E);
    wr_seq.set_wdata(man_data_q);
    wr_seq.set_wstrb(man_strb_q);
    this.start_seq_or_timeout(
      wr_seq,
      this._tb_env.man_agent[port_id].sequencer,
      fe,
      port_id,
      wr_seq.get_name());

    wr_rsp_q = wr_seq.get_wr_responses();
    if (wr_rsp_q.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Multi-rank manager write on port %0d returned %0d responses instead of 1",
        port_id,
        wr_rsp_q.size()))
    end

    bresp = wr_rsp_q[0].bresp;
    @(negedge this._tb_env._man_vif[port_id].clk);
  endtask

  protected task axi4_read_single_on_port(
    input int unsigned                                    port_id,
    input logic [VIP_MC_AXI4_CFG_C.ARID_WIDTH_P - 1 : 0] arid,
    input logic [3 : 0]                                   arqos,
    input longint unsigned                                addr,
    output rdata_t                                        data,
    output resp_t                                         rresp
  );
    vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)            rd_seq;
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_2R_C) fe;
    axi4_item_t                                           rd_rsp_q[$];

    fe = this.get_port_fe(port_id);

    // Configure + start the base-test-owned read sequence for this transaction.
    rd_seq = this._man_rd_seq;

    rd_seq.reset();
    rd_seq.set_arid(arid);
    rd_seq.set_axaddr(addr);
    rd_seq.set_axlen(0);
    rd_seq.set_axsize(this.get_full_width_axi_size());
    rd_seq.set_axburst(VIP_AXI4_BURST_INCR_C);
    rd_seq.set_axqos(arqos);
    rd_seq.set_requests(1);
    rd_seq.set_get_rd_response(1'b1);
    this.start_seq_or_timeout(
      rd_seq,
      this._tb_env.man_agent[port_id].sequencer,
      fe,
      port_id,
      rd_seq.get_name());

    rd_rsp_q = rd_seq.get_rd_responses();
    if (rd_rsp_q.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Multi-rank manager read on port %0d returned %0d responses instead of 1",
        port_id,
        rd_rsp_q.size()))
    end

    data  = this.flatten_read_beat(rd_rsp_q[0], 0);
    rresp = rd_rsp_q[0].rresp;
    @(negedge this._tb_env._man_vif[port_id].clk);
  endtask

  protected function longint unsigned encode_addr(
    input int rank,
    input int row,
    input int bg,
    input int bank,
    input int col = 0,
    input int byte_in_col = 0
  );
    vip_dram_dec_t dec;

    dec = '{default: 0};
    dec.rank        = rank;
    dec.row         = row;
    dec.bg          = bg;
    dec.bank        = bank;
    dec.col         = col;
    dec.byte_in_col = byte_in_col;
    return vip_dram_encode_addr(dec, DRAM_CFG_2R_C, this._tb_env.u_mc.cfg.addr_map_policy);
  endfunction
endclass

class tc_mc_multi_rank extends mc_multirank_base_test;

  `uvm_component_utils(tc_mc_multi_rank)

  mc_multirank_grant_collector _grant;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(input uvm_phase phase);
    // Two refresh bursts in a short wall-clock window, without making refresh
    // dominate the whole test now that tRFC drops with the 2-rank geometry.
    uvm_config_db #(real)::set(this, "env", "mc_trefi_override_ns", 100.0);
    super.build_phase(phase);
    this._grant = mc_multirank_grant_collector::type_id::create("grant", this);
  endfunction

  function void connect_phase(input uvm_phase phase);
    super.connect_phase(phase);
    this._grant.addr_map = this._tb_env.u_mc.cfg.addr_map_policy;
    this._tb_env.u_mc.backend.issued_port.connect(this._grant.analysis_export);
  endfunction

  task body();
    wdata_t            rank0_data;
    wdata_t            rank1_data;
    resp_t             bresp;
    resp_t             rresp;
    rdata_t            rdata;
    longint unsigned   rank0_addr;
    longint unsigned   rank1_addr;
    int                mc_before;
    int                mc_after;
    int                dram_before;
    int                dram_after;
    bit                saw_ref[DRAM_CFG_2R_C.N_RANKS_P];
    bit                saw_traffic[DRAM_CFG_2R_C.N_RANKS_P];

    this.wait_for_reset_release();

    rank0_data = '0;
    rank1_data = '0;
    rank0_data[63 : 0] = 64'h1122_3344_5566_7788;
    rank1_data[63 : 0] = 64'h99aa_bbcc_ddee_ff00;

    rank0_addr = this.encode_addr(0, 3, 0, 1, 4, 0);
    rank1_addr = this.encode_addr(1, 5, 1, 2, 7, 0);

    mc_before   = this._tb_env.u_mc.get_refresh_count();
    dram_before = this._tb_env.dram.get_refresh_count();
    this._grant.clear();

    this.axi4_write_single_on_port(0, 'h1, 4'h1, rank0_addr, rank0_data, '1, bresp);
    if (bresp != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Multi-rank rank0 write returned BRESP=%0b instead of OKAY",
        bresp))
    end

    this.axi4_write_single_on_port(1, 'h2, 4'h2, rank1_addr, rank1_data, '1, bresp);
    if (bresp != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Multi-rank rank1 write returned BRESP=%0b instead of OKAY",
        bresp))
    end

    this.axi4_read_single_on_port(0, 'h3, 4'h1, rank0_addr, rdata, rresp);
    if ((rresp != VIP_MC_AXI4_RESP_OKAY_C) || (rdata != rank0_data)) begin
      `uvm_fatal(get_name(), $sformatf(
        "Multi-rank rank0 read mismatch: resp=%0b data=0x%0h expected=0x%0h",
        rresp,
        rdata,
        rank0_data))
    end

    this.axi4_read_single_on_port(1, 'h4, 4'h2, rank1_addr, rdata, rresp);
    if ((rresp != VIP_MC_AXI4_RESP_OKAY_C) || (rdata != rank1_data)) begin
      `uvm_fatal(get_name(), $sformatf(
        "Multi-rank rank1 read mismatch: resp=%0b data=0x%0h expected=0x%0h",
        rresp,
        rdata,
        rank1_data))
    end

    #230ns;

    mc_after   = this._tb_env.u_mc.get_refresh_count();
    dram_after = this._tb_env.dram.get_refresh_count();

    foreach (this._grant.grant_op[i]) begin
      if (this._grant.grant_op[i] == int'(VIP_DRAM_OP_REF_E)) begin
        saw_ref[this._grant.grant_rank[i]] = 1'b1;
      end
      else begin
        saw_traffic[this._grant.grant_rank[i]] = 1'b1;
      end
    end

    for (int rank = 0; rank < DRAM_CFG_2R_C.N_RANKS_P; rank++) begin
      if (!saw_traffic[rank]) begin
        `uvm_fatal(get_name(), $sformatf(
          "Multi-rank test did not observe any traffic issued to rank %0d",
          rank))
      end
      if (!saw_ref[rank]) begin
        `uvm_fatal(get_name(), $sformatf(
          "Multi-rank test did not observe REF issued to rank %0d",
          rank))
      end
    end

    if ((mc_after - mc_before) < (2 * DRAM_CFG_2R_C.N_RANKS_P)) begin
      `uvm_fatal(get_name(),
        "Multi-rank test did not observe at least two refresh bursts across both ranks")
    end
    if ((mc_after - mc_before) != (dram_after - dram_before)) begin
      `uvm_fatal(get_name(),
        "Multi-rank test saw vip_mc emitted refresh count diverge from vip_dram executed refresh count")
    end

    `uvm_info(get_name(), "vip_mc multi-rank test passed", UVM_LOW)
  endtask
endclass
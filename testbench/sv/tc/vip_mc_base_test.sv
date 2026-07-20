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
// vip_mc_base_test
//
// Base test for the minimal vip_mc example harness. It creates the DRAM-backed
// environment, fetches the published owned AXI4 virtual interface, and provides
// helpers shared by the tests.
// -----------------------------------------------------------------------------
`uvm_analysis_imp_decl(_aw_obs)
`uvm_analysis_imp_decl(_ar_obs)
`uvm_analysis_imp_decl(_wr_obs)
`uvm_analysis_imp_decl(_rd_obs)

class vip_mc_base_test extends vip_mc_neutral_base_test;

  `uvm_component_utils(vip_mc_base_test)

  localparam int unsigned SEQ_TIMEOUT_CYCLES_C = 256;

  typedef vip_axi4_item #(VIP_AXI4_AGENT_CFG_C) axi4_item_t;
  typedef logic [(8 * VIP_MC_AXI4_CFG_C.WDATA_BYTES_P) - 1 : 0] wdata_t;
  typedef logic [VIP_MC_AXI4_CFG_C.WDATA_BYTES_P - 1 : 0]       wstrb_t;
  typedef logic [(8 * VIP_MC_AXI4_CFG_C.RDATA_BYTES_P) - 1 : 0] rdata_t;
  typedef logic [1 : 0]                                          resp_t;
  typedef logic [((VIP_MC_AXI4_CFG_C.AWUSER_WIDTH_P > 0) ? VIP_MC_AXI4_CFG_C.AWUSER_WIDTH_P : 1) - 1 : 0] awuser_t;
  typedef logic [((VIP_MC_AXI4_CFG_C.WUSER_WIDTH_P  > 0) ? VIP_MC_AXI4_CFG_C.WUSER_WIDTH_P  : 1) - 1 : 0] wuser_t;
  typedef logic [((VIP_MC_AXI4_CFG_C.BUSER_WIDTH_P  > 0) ? VIP_MC_AXI4_CFG_C.BUSER_WIDTH_P  : 1) - 1 : 0] buser_t;
  typedef logic [((VIP_MC_AXI4_CFG_C.ARUSER_WIDTH_P > 0) ? VIP_MC_AXI4_CFG_C.ARUSER_WIDTH_P : 1) - 1 : 0] aruser_t;
  typedef logic [((VIP_MC_AXI4_CFG_C.RUSER_WIDTH_P  > 0) ? VIP_MC_AXI4_CFG_C.RUSER_WIDTH_P  : 1) - 1 : 0] ruser_t;

  vip_mc_tb_env _tb_env;

  uvm_table_printer _uvm_table_printer;
  string            _tc_name;

  uvm_analysis_imp_aw_obs #(axi4_item_t, vip_mc_base_test) aw_collector;
  uvm_analysis_imp_ar_obs #(axi4_item_t, vip_mc_base_test) ar_collector;
  uvm_analysis_imp_wr_obs #(axi4_item_t, vip_mc_base_test) wr_collector;
  uvm_analysis_imp_rd_obs #(axi4_item_t, vip_mc_base_test) rd_collector;

  axi4_item_t aw_observations[$];
  axi4_item_t ar_observations[$];
  axi4_item_t wr_observations[$];
  axi4_item_t rd_observations[$];
  time        aw_observation_times[$];
  time        ar_observation_times[$];
  time        wr_observation_times[$];
  time        rd_observation_times[$];

  virtual vip_mc_axi4_if #(VIP_MC_AXI4_CFG_C) _mc_vif;

  // Manager traffic sequences are declared + created once in the base test
  // (start_of_simulation_phase). The response-returning helpers below only
  // configure and start these handles per transaction.
  vip_axi4_write_seq #(VIP_AXI4_AGENT_CFG_C) _man_wr_seq;
  vip_axi4_read_seq  #(VIP_AXI4_AGENT_CFG_C) _man_rd_seq;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
    void'($value$plusargs("UVM_TESTNAME=%s", this._tc_name));
  endfunction

  // ---------------------------------------------------------------------------
  // Build the shared harness and fetch the published owned AXI4 interface.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    // super.build_phase configures the phase timeout, report server, and the
    // clk_rst agent (10 ns) shared by every vip_mc example test.
    super.build_phase(phase);

    uvm_config_db #(int)::set(this, "env", "manager_agents_active", 1);

    this._uvm_table_printer                     = new();
    this._uvm_table_printer.knobs.depth         = 4;
    this._uvm_table_printer.knobs.default_radix = UVM_HEX;

    this.aw_collector = new("aw_collector", this);
    this.ar_collector = new("ar_collector", this);
    this.wr_collector = new("wr_collector", this);
    this.rd_collector = new("rd_collector", this);

    this._tb_env = vip_mc_tb_env::type_id::create("env", this);

    if (!uvm_config_db #(virtual vip_mc_axi4_if #(VIP_MC_AXI4_CFG_C))::get(
      this,
      "",
      "vif_port0",
      this._mc_vif
    )) begin
      `uvm_fatal(get_name(), "vip_mc example requires the owned AXI4 vif under key 'vif_port0'")
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Declare + create the shared reset and manager traffic sequences once, before
  // run_phase. TCs configure them (through the response-returning helpers, or
  // directly for bespoke traffic) rather than constructing sequences themselves.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);
    // super.start_of_simulation_phase creates the shared reset sequence.
    super.start_of_simulation_phase(phase);
    this._man_wr_seq = vip_axi4_write_seq #(VIP_AXI4_AGENT_CFG_C)::type_id::create("man_wr_seq");
    this._man_rd_seq = vip_axi4_read_seq  #(VIP_AXI4_AGENT_CFG_C)::type_id::create("man_rd_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Bind stock manager monitor ports used by the sequence-drivens.
  // ---------------------------------------------------------------------------
  function void connect_phase(input uvm_phase phase);
    super.connect_phase(phase);

    if (this._tb_env.man_agent[0] == null) begin
      `uvm_fatal(get_name(), "vip_mc example requires stock manager agent 0 in the shared base test")
    end

    this._tb_env.man_agent[0].monitor.awaddr_port.connect(this.aw_collector);
    this._tb_env.man_agent[0].monitor.araddr_port.connect(this.ar_collector);
    this._tb_env.man_agent[0].monitor.bresp_port.connect(this.wr_collector);
    this._tb_env.man_agent[0].monitor.rdata_port.connect(this.rd_collector);
  endfunction

  // ---------------------------------------------------------------------------
  // Test-specific behavior hook.
  // ---------------------------------------------------------------------------
  virtual task body();
  endtask

  // ---------------------------------------------------------------------------
  // Capture one monitored AW handshake observation and its simulation time.
  // ---------------------------------------------------------------------------
  virtual function void write_aw_obs(input axi4_item_t trans);
    axi4_item_t trans_copy;

    $cast(trans_copy, trans.clone());
    this.aw_observations.push_back(trans_copy);
    this.aw_observation_times.push_back($time);
  endfunction

  // ---------------------------------------------------------------------------
  // Capture one monitored AR handshake observation and its simulation time.
  // ---------------------------------------------------------------------------
  virtual function void write_ar_obs(input axi4_item_t trans);
    axi4_item_t trans_copy;

    $cast(trans_copy, trans.clone());
    this.ar_observations.push_back(trans_copy);
    this.ar_observation_times.push_back($time);
  endfunction

  // ---------------------------------------------------------------------------
  // Capture one monitored write-response observation and its time.
  // ---------------------------------------------------------------------------
  virtual function void write_wr_obs(input axi4_item_t trans);
    axi4_item_t trans_copy;

    $cast(trans_copy, trans.clone());
    this.wr_observations.push_back(trans_copy);
    this.wr_observation_times.push_back($time);
  endfunction

  // ---------------------------------------------------------------------------
  // Capture one monitored read-response observation and its time.
  // ---------------------------------------------------------------------------
  virtual function void write_rd_obs(input axi4_item_t trans);
    axi4_item_t trans_copy;

    $cast(trans_copy, trans.clone());
    this.rd_observations.push_back(trans_copy);
    this.rd_observation_times.push_back($time);
  endfunction

  // ---------------------------------------------------------------------------
  // Reset manager monitor observations before a new measured sequence slice.
  // ---------------------------------------------------------------------------
  protected function void clear_manager_observations();
    this.aw_observations.delete();
    this.ar_observations.delete();
    this.wr_observations.delete();
    this.rd_observations.delete();
    this.aw_observation_times.delete();
    this.ar_observation_times.delete();
    this.wr_observation_times.delete();
    this.rd_observation_times.delete();
  endfunction

  // ---------------------------------------------------------------------------
  // Neutral-base hooks: supply the clk_rst sequencer for the shared reset drive
  // and dump this env's controller telemetry (formatted by vip_mc itself).
  // ---------------------------------------------------------------------------
  protected function uvm_sequencer_base get_clk_sequencer();
    return this._tb_env.clk_agent.sequencer;
  endfunction

  protected function void report_telemetry(input string tag);
    if ((this._tb_env == null) || (this._tb_env.u_mc == null)) begin
      return;
    end
    `uvm_info(tag, this._tb_env.u_mc.sprint_telemetry(), UVM_LOW)
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


  // ---------------------------------------------------------------------------
  // Return the AXI4 AxSIZE encoding for one full interface beat.
  // ---------------------------------------------------------------------------
  protected function logic [2 : 0] get_full_width_axi_size();
    logic [2 : 0] size;

    size = $clog2(VIP_MC_AXI4_CFG_C.WDATA_BYTES_P);
    return size;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the AXI4 AxSIZE encoding for the requested byte count.
  // ---------------------------------------------------------------------------
  protected function logic [2 : 0] get_axi_size_for_bytes(input int unsigned byte_count);
    case (byte_count)
      1:   return VIP_MC_AXI4_SIZE_1B_C;
      2:   return VIP_MC_AXI4_SIZE_2B_C;
      4:   return VIP_MC_AXI4_SIZE_4B_C;
      8:   return VIP_MC_AXI4_SIZE_8B_C;
      16:  return VIP_MC_AXI4_SIZE_16B_C;
      32:  return VIP_MC_AXI4_SIZE_32B_C;
      64:  return VIP_MC_AXI4_SIZE_64B_C;
      128: return VIP_MC_AXI4_SIZE_128B_C;
      default: begin
        `uvm_fatal(get_name(), $sformatf(
          "Unsupported AXI4 byte_count=%0d for AxSIZE encoding",
          byte_count))
        return '0;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Return the built AXI4 front-end handle for one vip_mc port.
  // ---------------------------------------------------------------------------
  protected function vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) get_port_fe(
    input int unsigned port_id
  );
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe;

    if ((this._tb_env == null) ||
        (this._tb_env.u_mc == null) ||
        (port_id >= N_PORTS_C) ||
        !$cast(fe, this._tb_env.u_mc.fes[port_id])) begin
      `uvm_fatal(get_name(), $sformatf(
        "vip_mc port %0d was not built as an AXI4 front-end",
        port_id))
    end

    return fe;
  endfunction

  // ---------------------------------------------------------------------------
  // Flatten one sequence-returned R beat into the local packed beat alias.
  // ---------------------------------------------------------------------------
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

  // ---------------------------------------------------------------------------
  // Start one stock AXI4 sequence and fail fast with local handshake state if
  // the bus stalls.
  // ---------------------------------------------------------------------------
  protected task start_seq_or_timeout(
    input uvm_sequence_base                               seq,
    input uvm_sequencer_base                              sequencer,
    input vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe,
    input int unsigned                                    port_id,
    input string                                          seq_name
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

  // ---------------------------------------------------------------------------
  // Wait for reset release on one stock AXI4 manager interface.
  // ---------------------------------------------------------------------------
  protected task wait_for_reset_release_on_port(input int unsigned port_id);
    wait (this._tb_env._man_vif[port_id].rst_n === 1'b1);
    repeat (2) @(negedge this._tb_env._man_vif[port_id].clk);
  endtask

  // ---------------------------------------------------------------------------
  // Wait for reset release and settle before starting manager sequences.
  // ---------------------------------------------------------------------------
  protected task wait_for_reset_release();
    this.wait_for_reset_release_on_port(0);
  endtask

  // ---------------------------------------------------------------------------
  // Issue one aligned, full-width AXI4 write beat on the selected port.
  // ---------------------------------------------------------------------------
  protected task axi4_write_single_on_port(
    input int unsigned                                    port_id,
    input logic [VIP_MC_AXI4_CFG_C.AWID_WIDTH_P - 1 : 0] awid,
    input logic [3 : 0]                                   awqos,
    input longint unsigned                                addr,
    input wdata_t                                         data,
    input wstrb_t                                         strb,
    output resp_t                                         bresp
  );
    wdata_t write_q[];
    wstrb_t strb_q[];
    buser_t buser;

    write_q = new[1];
    strb_q  = new[1];
    write_q[0] = data;
    strb_q[0]  = strb;

    this.axi4_write_custom_user_on_port(
      port_id,
      awid,
      awqos,
      1'b0,
      addr,
      this.get_full_width_axi_size(),
      VIP_MC_AXI4_BURST_INCR_C,
      '0,
      '0,
      write_q,
      strb_q,
      bresp,
      buser);
  endtask

  // ---------------------------------------------------------------------------
  // Issue one aligned, full-width AXI4 read beat on the selected port.
  // ---------------------------------------------------------------------------
  protected task axi4_read_single_on_port(
    input int unsigned                                    port_id,
    input logic [VIP_MC_AXI4_CFG_C.ARID_WIDTH_P - 1 : 0] arid,
    input logic [3 : 0]                                   arqos,
    input longint unsigned                                addr,
    output rdata_t                                        data,
    output resp_t                                         rresp
  );
    rdata_t read_q[];
    resp_t  resp_q[];
    ruser_t ruser_q[];

    this.axi4_read_custom_user_on_port(
      port_id,
      arid,
      arqos,
      1'b0,
      addr,
      this.get_full_width_axi_size(),
      VIP_MC_AXI4_BURST_INCR_C,
      '0,
      1,
      read_q,
      resp_q,
      ruser_q);

    data  = read_q[0];
    rresp = resp_q[0];
  endtask

  // ---------------------------------------------------------------------------
  // Issue one AXI4 burst on the selected stock manager port.
  // ---------------------------------------------------------------------------
  protected task axi4_write_custom_user_on_port(
    input int unsigned                                    port_id,
    input logic [VIP_MC_AXI4_CFG_C.AWID_WIDTH_P - 1 : 0] awid,
    input logic [3 : 0]                                   awqos,
    input logic                                           awlock,
    input longint unsigned                                addr,
    input logic [2 : 0]                                   axi_size,
    input logic [1 : 0]                                   axi_burst,
    input awuser_t                                        awuser,
    input wuser_t                                         wuser,
    input wdata_t                                         data_q[],
    input wstrb_t                                         strb_q[],
    output resp_t                                         bresp,
    output buser_t                                        buser
  );
    vip_axi4_write_seq #(VIP_AXI4_AGENT_CFG_C)          wr_seq;
    vip_axi4_driver #(VIP_AXI4_AGENT_CFG_C, VIP_AXI4_ROLE_MANAGER_E) dummy;
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe;
    axi4_item_t                                          wr_rsp_q[$];
    vip_axi4_types #(VIP_AXI4_AGENT_CFG_C)::wdata_t      man_data_q[$];
    vip_axi4_types #(VIP_AXI4_AGENT_CFG_C)::wstrb_t      man_strb_q[$];
    vip_axi4_types #(VIP_AXI4_AGENT_CFG_C)::wuser_t      man_wuser_q[$];
    int                                                  beat_count;

    bresp = '0;
    buser = '0;
    beat_count = data_q.size();

    if ((beat_count == 0) || (strb_q.size() != beat_count)) begin
      `uvm_fatal(get_name(), "axi4_write_custom_user_on_port requires non-empty data_q and matching strb_q size")
    end

    fe = this.get_port_fe(port_id);

    foreach (data_q[beat_idx]) begin
      man_data_q.push_back(data_q[beat_idx]);
      man_strb_q.push_back(strb_q[beat_idx]);
      man_wuser_q.push_back(wuser);
    end

    // Configure + start the base-test-owned write sequence for this transaction.
    wr_seq = this._man_wr_seq;
    wr_seq.reset();
    wr_seq.set_awid(awid);
    wr_seq.set_axaddr(addr);
    wr_seq.set_axlen(beat_count - 1);
    wr_seq.set_axsize(axi_size);
    wr_seq.set_axburst(axi_burst);
    wr_seq.set_axlock(awlock);
    wr_seq.set_axqos(awqos);
    wr_seq.set_awuser(awuser);
    wr_seq.set_requests(1);
    wr_seq.set_get_wr_response(1'b1);
    wr_seq.set_wdata_type(VIP_AXI4_DATA_CUSTOM_E);
    wr_seq.set_wstrb_type(VIP_AXI4_STRB_CUSTOM_E);
    wr_seq.set_wuser_type(VIP_AXI4_DATA_CUSTOM_E);
    wr_seq.set_wdata(man_data_q);
    wr_seq.set_wstrb(man_strb_q);
    wr_seq.set_wuser(man_wuser_q);
    this.start_seq_or_timeout(
      wr_seq,
      this._tb_env.man_agent[port_id].sequencer,
      fe,
      port_id,
      wr_seq.get_name());

    wr_rsp_q = wr_seq.get_wr_responses();
    if (wr_rsp_q.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Stock manager write on port %0d returned %0d responses instead of 1",
        port_id,
        wr_rsp_q.size()))
    end

    bresp = wr_rsp_q[0].bresp;
    buser = wr_rsp_q[0].buser;

    @(negedge this._tb_env._man_vif[port_id].clk);
  endtask

  // ---------------------------------------------------------------------------
  // Issue one AXI4 read burst on the selected stock manager port.
  // ---------------------------------------------------------------------------
  protected task axi4_read_custom_user_on_port(
    input int unsigned                                    port_id,
    input logic [VIP_MC_AXI4_CFG_C.ARID_WIDTH_P - 1 : 0] arid,
    input logic [3 : 0]                                   arqos,
    input logic                                           arlock,
    input longint unsigned                                addr,
    input logic [2 : 0]                                   axi_size,
    input logic [1 : 0]                                   axi_burst,
    input aruser_t                                        aruser,
    input int unsigned                                    beat_count,
    output rdata_t                                        data_q[],
    output resp_t                                         rresp_q[],
    output ruser_t                                        ruser_q[]
  );
    vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)           rd_seq;
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe;
    axi4_item_t                                          rd_rsp_q[$];

    if (beat_count == 0) begin
      `uvm_fatal(get_name(), "axi4_read_custom_user_on_port requires beat_count >= 1")
    end

    fe = this.get_port_fe(port_id);

    // Configure + start the base-test-owned read sequence for this transaction.
    rd_seq = this._man_rd_seq;
    rd_seq.reset();
    rd_seq.set_arid(arid);
    rd_seq.set_axaddr(addr);
    rd_seq.set_axlen(beat_count - 1);
    rd_seq.set_axsize(axi_size);
    rd_seq.set_axburst(axi_burst);
    rd_seq.set_axlock(arlock);
    rd_seq.set_axqos(arqos);
    rd_seq.set_aruser(aruser);
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
        "Stock manager read on port %0d returned %0d responses instead of 1",
        port_id,
        rd_rsp_q.size()))
    end
    if (rd_rsp_q[0].rdata.size() != beat_count) begin
      `uvm_fatal(get_name(), $sformatf(
        "Stock manager read on port %0d returned %0d beats instead of %0d",
        port_id,
        rd_rsp_q[0].rdata.size(),
        beat_count))
    end

    data_q  = new[beat_count];
    rresp_q = new[beat_count];
    ruser_q = new[beat_count];
    for (int beat_idx = 0; beat_idx < beat_count; beat_idx++) begin
      data_q[beat_idx]  = this.flatten_read_beat(rd_rsp_q[0], beat_idx);
      rresp_q[beat_idx] = rd_rsp_q[0].rresp;
      if (rd_rsp_q[0].ruser.size() > beat_idx) begin
        ruser_q[beat_idx] = rd_rsp_q[0].ruser[beat_idx];
      end
      else begin
        ruser_q[beat_idx] = '0;
      end
    end

    @(negedge this._tb_env._man_vif[port_id].clk);
  endtask

  // ---------------------------------------------------------------------------
  // Issue one aligned, full-width AXI4 write beat and return BRESP.
  // ---------------------------------------------------------------------------
  protected task axi4_write_single(
    input longint unsigned addr,
    input wdata_t          data,
    input wstrb_t          strb,
    output logic [1 : 0]   bresp
  );
    wdata_t write_q[];
    wstrb_t strb_q[];
    buser_t buser;

    write_q = new[1];
    strb_q  = new[1];
    write_q[0] = data;
    strb_q[0]  = strb;

    this.axi4_write_custom_user_on_port(
      0,
      'h3,
      4'hf,
      1'b0,
      addr,
      this.get_full_width_axi_size(),
      VIP_MC_AXI4_BURST_INCR_C,
      '0,
      '0,
      write_q,
      strb_q,
      bresp,
      buser);
  endtask

  // ---------------------------------------------------------------------------
  // Issue one aligned, full-width AXI4 read beat and return RDATA/RRESP.
  // ---------------------------------------------------------------------------
  protected task axi4_read_single(
    input longint unsigned addr,
    output rdata_t         data,
    output logic [1 : 0]   rresp
  );
    rdata_t read_q[];
    resp_t  resp_q[];
    ruser_t ruser_q[];

    this.axi4_read_custom_user_on_port(
      0,
      'h5,
      4'hf,
      1'b0,
      addr,
      this.get_full_width_axi_size(),
      VIP_MC_AXI4_BURST_INCR_C,
      '0,
      1,
      read_q,
      resp_q,
      ruser_q);

    data  = read_q[0];
    rresp = resp_q[0];
  endtask

  // ---------------------------------------------------------------------------
  // Issue one aligned, full-width AXI4 write burst and return BRESP.
  // ---------------------------------------------------------------------------
  protected task axi4_write_burst(
    input longint unsigned addr,
    input wdata_t          data_q[],
    input wstrb_t          strb_q[],
    output resp_t          bresp
  );
    buser_t buser;

    this.axi4_write_custom_user_on_port(
      0,
      'h7,
      4'hc,
      1'b0,
      addr,
      this.get_full_width_axi_size(),
      VIP_MC_AXI4_BURST_INCR_C,
      '0,
      '0,
      data_q,
      strb_q,
      bresp,
      buser);
  endtask

  // ---------------------------------------------------------------------------
  // Issue one aligned, full-width AXI4 read burst and collect every R beat.
  // ---------------------------------------------------------------------------
  protected task axi4_read_burst(
    input  longint unsigned addr,
    input  int unsigned     beat_count,
    output rdata_t          data_q[],
    output resp_t           rresp_q[]
  );
    ruser_t ruser_q[];

    this.axi4_read_custom_user_on_port(
      0,
      'h9,
      4'hc,
      1'b0,
      addr,
      this.get_full_width_axi_size(),
      VIP_MC_AXI4_BURST_INCR_C,
      '0,
      beat_count,
      data_q,
      rresp_q,
      ruser_q);
  endtask

  // ---------------------------------------------------------------------------
  // Issue one AXI4 INCR write burst using the supplied AxSIZE and return BRESP.
  // ---------------------------------------------------------------------------
  protected task axi4_write_incr_custom(
    input longint unsigned addr,
    input logic [2 : 0]    axi_size,
    input wdata_t          data_q[],
    input wstrb_t          strb_q[],
    output resp_t          bresp
  );
    this.axi4_write_custom(addr, axi_size, VIP_MC_AXI4_BURST_INCR_C, data_q, strb_q, bresp);
  endtask

  // ---------------------------------------------------------------------------
  // Issue one AXI4 burst using the supplied AxSIZE/AxBURST and return BRESP.
  // ---------------------------------------------------------------------------
  protected task axi4_write_custom(
    input longint unsigned addr,
    input logic [2 : 0]    axi_size,
    input logic [1 : 0]    axi_burst,
    input wdata_t          data_q[],
    input wstrb_t          strb_q[],
    output resp_t          bresp
  );
    awuser_t awuser;
    wuser_t  wuser;
    buser_t  buser;

    awuser = '0;
    wuser  = '0;
    buser  = '0;
    this.axi4_write_custom_user(
      addr,
      axi_size,
      axi_burst,
      awuser,
      wuser,
      data_q,
      strb_q,
      bresp,
      buser);
  endtask

  // ---------------------------------------------------------------------------
  // Issue one AXI4 burst using the supplied AxSIZE/AxBURST/AxUSER values.
  // ---------------------------------------------------------------------------
  protected task axi4_write_custom_user(
    input longint unsigned addr,
    input logic [2 : 0]    axi_size,
    input logic [1 : 0]    axi_burst,
    input awuser_t         awuser,
    input wuser_t          wuser,
    input wdata_t          data_q[],
    input wstrb_t          strb_q[],
    output resp_t          bresp,
    output buser_t         buser
  );
    this.axi4_write_custom_user_on_port(
      0,
      'hb,
      4'h9,
      1'b0,
      addr,
      axi_size,
      axi_burst,
      awuser,
      wuser,
      data_q,
      strb_q,
      bresp,
      buser);
  endtask

  // ---------------------------------------------------------------------------
  // Issue one AXI4 INCR read burst using the supplied AxSIZE.
  // ---------------------------------------------------------------------------
  protected task axi4_read_incr_custom(
    input  longint unsigned addr,
    input  logic [2 : 0]    axi_size,
    input  int unsigned     beat_count,
    output rdata_t          data_q[],
    output resp_t           rresp_q[]
  );
    this.axi4_read_custom(addr, axi_size, VIP_MC_AXI4_BURST_INCR_C, beat_count, data_q, rresp_q);
  endtask

  // ---------------------------------------------------------------------------
  // Issue one AXI4 burst using the supplied AxSIZE/AxBURST.
  // ---------------------------------------------------------------------------
  protected task axi4_read_custom(
    input  longint unsigned addr,
    input  logic [2 : 0]    axi_size,
    input  logic [1 : 0]    axi_burst,
    input  int unsigned     beat_count,
    output rdata_t          data_q[],
    output resp_t           rresp_q[]
  );
    aruser_t aruser;
    ruser_t  ruser_q[];

    aruser = '0;
    this.axi4_read_custom_user(
      addr,
      axi_size,
      axi_burst,
      aruser,
      beat_count,
      data_q,
      rresp_q,
      ruser_q);
  endtask

  // ---------------------------------------------------------------------------
  // Issue one AXI4 burst using the supplied AxSIZE/AxBURST/AxUSER values.
  // ---------------------------------------------------------------------------
  protected task axi4_read_custom_user(
    input  longint unsigned addr,
    input  logic [2 : 0]    axi_size,
    input  logic [1 : 0]    axi_burst,
    input  aruser_t         aruser,
    input  int unsigned     beat_count,
    output rdata_t          data_q[],
    output resp_t           rresp_q[],
    output ruser_t          ruser_q[]
  );
    this.axi4_read_custom_user_on_port(
      0,
      'hd,
      4'h9,
      1'b0,
      addr,
      axi_size,
      axi_burst,
      aruser,
      beat_count,
      data_q,
      rresp_q,
      ruser_q);
  endtask

  // ---------------------------------------------------------------------------
  // Issue one AXI4 FIXED write burst using the supplied AxSIZE.
  // ---------------------------------------------------------------------------
  protected task axi4_write_fixed_custom(
    input longint unsigned addr,
    input logic [2 : 0]    axi_size,
    input wdata_t          data_q[],
    input wstrb_t          strb_q[],
    output resp_t          bresp
  );
    this.axi4_write_custom(addr, axi_size, VIP_MC_AXI4_BURST_FIXED_C, data_q, strb_q, bresp);
  endtask

  // ---------------------------------------------------------------------------
  // Issue one AXI4 FIXED read burst using the supplied AxSIZE.
  // ---------------------------------------------------------------------------
  protected task axi4_read_fixed_custom(
    input  longint unsigned addr,
    input  logic [2 : 0]    axi_size,
    input  int unsigned     beat_count,
    output rdata_t          data_q[],
    output resp_t           rresp_q[]
  );
    this.axi4_read_custom(addr, axi_size, VIP_MC_AXI4_BURST_FIXED_C, beat_count, data_q, rresp_q);
  endtask

endclass
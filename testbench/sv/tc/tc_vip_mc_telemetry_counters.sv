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
// tc_vip_mc_telemetry_counters
//
// Drives a small mixed empty/hit/miss read stream while stalling RREADY so the
// response buffer backpressures. The test cross-checks the new §8.8 telemetry
// getters against an independent issued_port + dram.rsp_port observation path.
// -----------------------------------------------------------------------------
`uvm_analysis_imp_decl(_mc_tel_issued)
`uvm_analysis_imp_decl(_mc_tel_rsp)

class mc_telemetry_collector extends uvm_component;

  typedef vip_mc_cmd_entry #(DRAM_CFG_C) cmd_t;
  typedef vip_dram_req     #(DRAM_CFG_C) req_t;
  typedef vip_dram_rsp     #(DRAM_CFG_C) rsp_t;

  typedef struct {
    int unsigned beats;
    realtime     pred_last_ns;
  } pred_t;

  vip_dram #(DRAM_CFG_C) dram;
  uvm_analysis_imp_mc_tel_issued #(cmd_t, mc_telemetry_collector) issued_export;
  uvm_analysis_imp_mc_tel_rsp    #(rsp_t, mc_telemetry_collector) rsp_export;

  protected pred_t               pred_by_tag[longint unsigned];
  protected int unsigned         page_hit_count = 0;
  protected int unsigned         page_miss_count = 0;
  protected int unsigned         page_empty_count = 0;
  protected int unsigned         predict_samples = 0;
  protected realtime             predict_error_ns = 0.0;
  protected longint unsigned     data_bytes = 0;
  protected realtime             busy_time_ns = 0.0;
  protected realtime             first_data_ns = 0.0;
  protected realtime             last_burst_end_ns = 0.0;
  protected bit                  window_valid = 1'b0;

  `uvm_component_utils(mc_telemetry_collector)

  function new(input string name, input uvm_component parent);
    super.new(name, parent);
    this.issued_export = new("issued_export", this);
    this.rsp_export    = new("rsp_export", this);
  endfunction

  function void clear();
    this.pred_by_tag.delete();
    this.page_hit_count = 0;
    this.page_miss_count = 0;
    this.page_empty_count = 0;
    this.predict_samples = 0;
    this.predict_error_ns = 0.0;
    this.data_bytes = 0;
    this.busy_time_ns = 0.0;
    this.first_data_ns = 0.0;
    this.last_burst_end_ns = 0.0;
    this.window_valid = 1'b0;
  endfunction

  function void write_mc_tel_issued(input cmd_t t);
    req_t    req;
    realtime pred_first_ns;
    realtime pred_last_ns;
    pred_t   pred;

    if ((t == null) || (t.op == VIP_DRAM_OP_REF_E) || (this.dram == null)) begin
      return;
    end

    req = req_t::type_id::create("telemetry_predict_req");
    req.addr              = t.addr;
    req.op                = t.op;
    req.beats             = t.beats;
    req.has_explicit_rank = t.has_explicit_rank;
    req.rank              = t.rank;
    req.tag               = t.tag;
    this.dram.predict(req, pred_first_ns, pred_last_ns);

    pred.beats        = t.beats;
    pred.pred_last_ns = pred_last_ns;
    this.pred_by_tag[t.tag] = pred;
  endfunction

  function void write_mc_tel_rsp(input rsp_t t);
    pred_t   pred;
    realtime burst_end_ns;
    realtime busy_span_ns;
    realtime predict_delta_ns;

    if ((t == null) || !this.pred_by_tag.exists(t.tag) || (this.dram == null)) begin
      return;
    end

    pred = this.pred_by_tag[t.tag];
    this.pred_by_tag.delete(t.tag);

    if (t.was_page_hit) begin
      this.page_hit_count++;
    end
    else if (t.was_page_miss) begin
      this.page_miss_count++;
    end
    else if (t.was_page_empty) begin
      this.page_empty_count++;
    end

    predict_delta_ns = t.last_beat_ready_time - pred.pred_last_ns;
    if (predict_delta_ns < 0.0) begin
      predict_delta_ns = -predict_delta_ns;
    end
    this.predict_error_ns += predict_delta_ns;
    this.predict_samples++;

    this.data_bytes += longint'(pred.beats) * longint'(DRAM_CFG_C.ROW_BYTES_P);
    burst_end_ns = t.last_beat_ready_time + this.dram.cfg.timing.tBL;
    busy_span_ns = burst_end_ns - t.first_beat_ready_time;
    if (busy_span_ns < 0.0) begin
      busy_span_ns = 0.0;
    end
    this.busy_time_ns += busy_span_ns;

    if (!this.window_valid || (t.first_beat_ready_time < this.first_data_ns)) begin
      this.first_data_ns = t.first_beat_ready_time;
    end
    if (!this.window_valid || (burst_end_ns > this.last_burst_end_ns)) begin
      this.last_burst_end_ns = burst_end_ns;
    end
    this.window_valid = 1'b1;
  endfunction

  function real get_row_hit_rate();
    int total_count;

    total_count = this.page_hit_count + this.page_miss_count + this.page_empty_count;
    if (total_count == 0) begin
      return 0.0;
    end
    return real'(this.page_hit_count) / real'(total_count);
  endfunction

  function real get_predict_accuracy();
    if (this.predict_samples == 0) begin
      return 0.0;
    end
    return this.predict_error_ns / real'(this.predict_samples);
  endfunction

  function real get_effective_bandwidth();
    realtime window_ns;

    if (!this.window_valid) begin
      return 0.0;
    end
    window_ns = this.last_burst_end_ns - this.first_data_ns;
    if (window_ns <= 0.0) begin
      return 0.0;
    end
    return real'(this.data_bytes) / window_ns;
  endfunction

  function real get_bus_utilization();
    realtime window_ns;

    if (!this.window_valid) begin
      return 0.0;
    end
    window_ns = this.last_burst_end_ns - this.first_data_ns;
    if (window_ns <= 0.0) begin
      return 0.0;
    end
    return this.busy_time_ns / window_ns;
  endfunction

endclass

class tc_vip_mc_telemetry_counters extends vip_mc_base_test;

  `uvm_component_utils(tc_vip_mc_telemetry_counters)

  localparam int      OBS_TIMEOUT_CYCLES_C = 1024;
  localparam realtime REAL_TOL_C           = 0.001;
  localparam longint unsigned EMPTY_ID_C   = 'h1;
  localparam longint unsigned HIT_ID_C     = 'h2;
  localparam longint unsigned MISS_ID_C    = 'h3;

  mc_telemetry_collector _telemetry;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(input uvm_phase phase);
    uvm_config_db #(int)::set(this, "env", "mc_refresh_enabled", 0);
    uvm_config_db #(int)::set(this, "env", "mc_rsp_buf_depth", 1);
    uvm_config_db #(int)::set(this, "env", "mc_max_inflight_to_device", 1);
    uvm_config_db #(int)::set(this, "env", "mc_scoreboard_timing_check", 0);
    super.build_phase(phase);
    this._telemetry = mc_telemetry_collector::type_id::create("telemetry", this);
  endfunction

  function void connect_phase(input uvm_phase phase);
    super.connect_phase(phase);
    this._telemetry.dram = this._tb_env.dram;
    this._tb_env.u_mc.backend.issued_port.connect(this._telemetry.issued_export);
    this._tb_env.dram.rsp_port.connect(this._telemetry.rsp_export);
  endfunction

  protected function longint unsigned encode_addr(
    input int row,
    input int bg,
    input int bank,
    input int col = 0,
    input int byte_in_col = 0
  );
    vip_dram_dec_t dec;

    dec = '{default: 0};
    dec.rank        = 0;
    dec.row         = row;
    dec.bg          = bg;
    dec.bank        = bank;
    dec.col         = col;
    dec.byte_in_col = byte_in_col;
    return vip_dram_encode_addr(dec, DRAM_CFG_C, this._tb_env.u_mc.cfg.addr_map_policy);
  endfunction

  protected task issue_read_no_wait(
    input logic [VIP_MC_AXI4_CFG_C.ARID_WIDTH_P - 1 : 0] arid,
    input longint unsigned                               addr
  );
    vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)           rd_seq;
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;

    fe0 = this.get_port_fe(0);

    rd_seq = vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)::type_id::create($sformatf(
      "telemetry_rd_%0h_%0h",
      arid,
      addr));
    rd_seq.reset();
    rd_seq.set_arid(arid);
    rd_seq.set_axaddr(addr);
    rd_seq.set_axlen(0);
    rd_seq.set_axsize(this.get_full_width_axi_size());
    rd_seq.set_axburst(VIP_MC_AXI4_BURST_INCR_C);
    rd_seq.set_axqos(4'h5);
    rd_seq.set_requests(1);
    rd_seq.set_get_rd_response(1'b0);
    this.start_seq_or_timeout(
      rd_seq,
      this._tb_env.man_agent[0].sequencer,
      fe0,
      0,
      rd_seq.get_name());
  endtask

  protected function void assert_real_close(
    input string name,
    input real   actual,
    input real   expected,
    input real   tol
  );
    if ((actual < (expected - tol)) || (actual > (expected + tol))) begin
      `uvm_fatal(get_name(), $sformatf(
        "%s mismatch: actual=%0.6f expected=%0.6f tol=%0.6f",
        name,
        actual,
        expected,
        tol))
    end
  endfunction

  task body();
    longint unsigned empty_hit_addr;
    longint unsigned miss_addr;
    wdata_t          empty_hit_data;
    wdata_t          miss_data;
    rdata_t          obs_data;
    real             actual_row_hit_rate;
    real             actual_predict_accuracy;
    real             actual_effective_bandwidth;
    real             actual_bus_utilization;
    bit              blocked_rsp_seen;

    this.wait_for_reset_release();
    this._telemetry.clear();
    this.clear_manager_observations();

    this._tb_env.man_cfg[0].rready_delay_enabled       = 1'b1;
    this._tb_env.man_cfg[0].rready_delay_gauss_enabled = 1'b0;
    this._tb_env.man_cfg[0].rready_delay_time_min      = 8;
    this._tb_env.man_cfg[0].rready_delay_time_max      = 8;
    this._tb_env.man_cfg[0].rready_delay_period_min    = 1;
    this._tb_env.man_cfg[0].rready_delay_period_max    = 1;

    empty_hit_addr = this.encode_addr(.row(0), .bg(0), .bank(0));
    miss_addr      = this.encode_addr(.row(1), .bg(0), .bank(0));

    empty_hit_data = '0;
    miss_data      = '0;
    for (int byte_idx = 0; byte_idx < VIP_MC_AXI4_CFG_C.WDATA_BYTES_P; byte_idx++) begin
      empty_hit_data[(8 * byte_idx) +: 8] = 8'h20 + byte_idx[7:0];
      miss_data[(8 * byte_idx) +: 8]      = 8'h80 + byte_idx[7:0];
    end

    this._tb_env.dram.backdoor_write(empty_hit_addr, empty_hit_data);
    this._tb_env.dram.backdoor_write(miss_addr, miss_data);

    this.issue_read_no_wait(EMPTY_ID_C, empty_hit_addr);

    blocked_rsp_seen = 1'b0;
    repeat (OBS_TIMEOUT_CYCLES_C) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if ((this._tb_env._man_vif[0].rvalid === 1'b1) &&
          (this._tb_env._man_vif[0].rready === 1'b0)) begin
        blocked_rsp_seen = 1'b1;
        break;
      end
    end
    if (!blocked_rsp_seen) begin
      `uvm_fatal(get_name(), "Telemetry test did not observe the first response blocked on RREADY")
    end

    this.issue_read_no_wait(HIT_ID_C, empty_hit_addr);
    this.issue_read_no_wait(MISS_ID_C, miss_addr);

    repeat (OBS_TIMEOUT_CYCLES_C) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if (this.rd_observations.size() >= 3) begin
        break;
      end
    end

    if (this.rd_observations.size() != 3) begin
      `uvm_fatal(get_name(), $sformatf(
        "Telemetry test expected 3 read observations, saw %0d",
        this.rd_observations.size()))
    end

    obs_data = this.flatten_read_beat(this.rd_observations[0], 0);
    if ((this.rd_observations[0].rresp != VIP_MC_AXI4_RESP_OKAY_C) ||
        (obs_data !== empty_hit_data)) begin
      `uvm_fatal(get_name(), "Telemetry test first read did not return the expected page-empty data")
    end

    obs_data = this.flatten_read_beat(this.rd_observations[1], 0);
    if ((this.rd_observations[1].rresp != VIP_MC_AXI4_RESP_OKAY_C) ||
        (obs_data !== empty_hit_data)) begin
      `uvm_fatal(get_name(), "Telemetry test second read did not return the expected page-hit data")
    end

    obs_data = this.flatten_read_beat(this.rd_observations[2], 0);
    if ((this.rd_observations[2].rresp != VIP_MC_AXI4_RESP_OKAY_C) ||
        (obs_data !== miss_data)) begin
      `uvm_fatal(get_name(), "Telemetry test third read did not return the expected page-miss data")
    end

    if (this._tb_env.u_mc.get_rsp_buf_full_cycles(0) == 0) begin
      `uvm_fatal(get_name(),
        "Telemetry test did not drive response-buffer backpressure")
    end

    actual_row_hit_rate        = this._tb_env.u_mc.get_row_hit_rate();
    actual_predict_accuracy    = this._tb_env.u_mc.get_predict_accuracy();
    actual_effective_bandwidth = this._tb_env.u_mc.get_effective_bandwidth();
    actual_bus_utilization     = this._tb_env.u_mc.get_bus_utilization();

    this.assert_real_close(
      "row_hit_rate",
      actual_row_hit_rate,
      this._telemetry.get_row_hit_rate(),
      REAL_TOL_C);
    this.assert_real_close(
      "predict_accuracy",
      actual_predict_accuracy,
      this._telemetry.get_predict_accuracy(),
      REAL_TOL_C);
    this.assert_real_close(
      "effective_bandwidth",
      actual_effective_bandwidth,
      this._telemetry.get_effective_bandwidth(),
      REAL_TOL_C);
    this.assert_real_close(
      "bus_utilization",
      actual_bus_utilization,
      this._telemetry.get_bus_utilization(),
      REAL_TOL_C);

    if ((actual_row_hit_rate <= 0.0) || (actual_row_hit_rate >= 1.0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "Telemetry row-hit rate should be strictly between 0 and 1, got %0.6f",
        actual_row_hit_rate))
    end
    if (actual_effective_bandwidth <= 0.0) begin
      `uvm_fatal(get_name(), "Telemetry effective bandwidth did not advance")
    end
    if ((actual_bus_utilization <= 0.0) || (actual_bus_utilization > (1.0 + REAL_TOL_C))) begin
      `uvm_fatal(get_name(), $sformatf(
        "Telemetry bus utilization out of range: %0.6f",
        actual_bus_utilization))
    end

    `uvm_info(get_name(), $sformatf(
      "vip_mc telemetry counters test passed (row_hit_rate=%0.3f predict_err=%0.3fns bw=%0.3fB/ns util=%0.3f)",
      actual_row_hit_rate,
      actual_predict_accuracy,
      actual_effective_bandwidth,
      actual_bus_utilization), UVM_LOW)
  endtask

endclass

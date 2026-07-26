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
// tc_mc_refresh_collision  (§13.3 #14 / P1-3)
//
// Force a refresh to land between two reads by combining a shortened tREFI with
// a 1-deep device command window. The first read is long enough that REF is
// pending by the time the window re-opens; the second read must then issue only
// after REF and pick up the device's tRFC delay.
// -----------------------------------------------------------------------------

class mc_refresh_collision_grant_collector extends uvm_subscriber #(vip_mc_cmd_entry #(DRAM_CFG_C));
  typedef vip_dram_req #(DRAM_CFG_C) req_t;

  typedef struct {
    int              op;
    longint unsigned axi4_id;
    longint unsigned tag;
    int unsigned     beats;
    realtime         grant_time;
    realtime         pred_first;
    realtime         pred_last;
  } grant_info_t;

  vip_dram #(DRAM_CFG_C) dram;
  grant_info_t           grants[$];

  `uvm_component_utils(mc_refresh_collision_grant_collector)

  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  function void write(input vip_mc_cmd_entry #(DRAM_CFG_C) t);
    grant_info_t info;
    req_t        req;

    if (t == null) begin
      return;
    end

    info.op         = int'(t.op);
    info.axi4_id    = t.axi4_id;
    info.tag        = t.tag;
    info.beats      = t.beats;
    info.grant_time = $realtime;
    info.pred_first = 0.0;
    info.pred_last  = 0.0;

    if (this.dram != null) begin
      req = req_t::type_id::create($sformatf("predict_req_%0h", t.tag));
      req.addr              = t.addr;
      req.op                = t.op;
      req.beats             = t.beats;
      req.has_explicit_rank = t.has_explicit_rank;
      req.rank              = t.rank;
      req.tag               = t.tag;
      req.wdata             = new[t.wdata.size()];
      req.wstrb             = new[t.wstrb.size()];

      foreach (t.wdata[i]) begin
        req.wdata[i] = t.wdata[i];
      end
      foreach (t.wstrb[i]) begin
        req.wstrb[i] = t.wstrb[i];
      end

      this.dram.predict(req, info.pred_first, info.pred_last);
    end

    this.grants.push_back(info);
  endfunction

  function void clear();
    this.grants.delete();
  endfunction
endclass

class mc_refresh_collision_rsp_collector extends uvm_subscriber #(vip_dram_rsp #(DRAM_CFG_C));
  typedef vip_dram_rsp #(DRAM_CFG_C) rsp_t;

  rsp_t rsp_by_tag[longint unsigned];

  `uvm_component_utils(mc_refresh_collision_rsp_collector)

  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  function void write(input rsp_t t);
    rsp_t rsp_copy;

    if (t == null) begin
      return;
    end

    $cast(rsp_copy, t.clone());
    this.rsp_by_tag[t.tag] = rsp_copy;
  endfunction

  function bit has_rsp(input longint unsigned tag);
    return this.rsp_by_tag.exists(tag);
  endfunction

  function rsp_t get_rsp(input longint unsigned tag);
    if (!this.rsp_by_tag.exists(tag)) begin
      return null;
    end
    return this.rsp_by_tag[tag];
  endfunction

  function void clear();
    this.rsp_by_tag.delete();
  endfunction
endclass

class tc_mc_refresh_collision extends mc_base_test;

  `uvm_component_utils(tc_mc_refresh_collision)

  localparam int OBS_TIMEOUT_CYCLES_C = 2048;
  localparam int LONG_READ_BEATS_C    = 16;
  localparam realtime AXI_BEAT_PERIOD_NS_C   = 10.0;
  localparam realtime AXI_TIMING_TOL_NS_C    = 30.0;
  localparam realtime AXI_EARLY_SLACK_NS_C   = -2.0;
  localparam realtime REFRESH_PICKUP_MIN_NS_C = 40.0;

  typedef vip_dram_rsp #(DRAM_CFG_C) dram_rsp_t;

  mc_refresh_collision_grant_collector _grant;
  mc_refresh_collision_rsp_collector   _dram_rsp;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(input uvm_phase phase);
    uvm_config_db #(real)::set(this, "env", "mc_trefi_override_ns", 80.0);
    uvm_config_db #(int)::set(this, "env", "mc_honor_beat_timing", 0);
    uvm_config_db #(int)::set(this, "env", "mc_max_inflight_to_device", 1);
    // This test intentionally forces refresh to interleave with read service,
    // so the generic device-only timing prediction is expected to be violated.
    // The checks below validate the intended REF ordering and tRFC pickup.
    uvm_config_db #(int)::set(this, "env", "mc_scoreboard_timing_check", 0);
    super.build_phase(phase);
    this._grant    = mc_refresh_collision_grant_collector::type_id::create("grant", this);
    this._dram_rsp = mc_refresh_collision_rsp_collector::type_id::create("dram_rsp", this);
  endfunction

  function void connect_phase(input uvm_phase phase);
    super.connect_phase(phase);
    this._grant.dram = this._tb_env.dram;
    this._tb_env.u_mc.backend.issued_port.connect(this._grant.analysis_export);
    this._tb_env.dram.rsp_port.connect(this._dram_rsp.analysis_export);
  endfunction

  protected function realtime expected_axi_last(
    input realtime     first_ready,
    input realtime     last_ready,
    input int unsigned beat_count
  );
    realtime deliver_ready;
    realtime expected_last;

    deliver_ready = this._tb_env.dram.cfg.deliver_at_first_beat ? first_ready : last_ready;
    expected_last = deliver_ready + (realtime'(beat_count) - 1.0) * AXI_BEAT_PERIOD_NS_C;
    if (last_ready > expected_last) begin
      expected_last = last_ready;
    end
    return expected_last;
  endfunction

  protected task issue_read_no_wait(
    input logic [VIP_MC_AXI4_CFG_C.ARID_WIDTH_P - 1 : 0] arid,
    input longint unsigned                               addr,
    input int unsigned                                   beat_count
  );
    vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)           rd_seq;
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;

    fe0 = this.get_port_fe(0);

    rd_seq = vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)::type_id::create($sformatf(
      "refresh_collision_rd_seq_%0h_%0h_%0d",
      arid,
      addr,
      beat_count));
    rd_seq.reset();
    rd_seq.set_arid(arid);
    rd_seq.set_axaddr(addr);
    rd_seq.set_axlen(beat_count - 1);
    rd_seq.set_axsize(this.get_full_width_axi_size());
    rd_seq.set_axburst(VIP_MC_AXI4_BURST_INCR_C);
    rd_seq.set_axqos(4'h4);
    rd_seq.set_requests(1);
    rd_seq.set_get_rd_response(1'b0);
    this.start_seq_or_timeout(
      rd_seq,
      this._tb_env.man_agent[0].sequencer,
      fe0,
      0,
      rd_seq.get_name());
  endtask

  task body();
    int        mc_before;
    int        mc_after;
    int        dram_before;
    int        dram_after;
    int        first_idx;
    int        ref_idx;
    int        second_idx;
    int        first_obs_idx;
    int        second_obs_idx;
    realtime   trfc_ns;
    realtime   ref_latency_ns;
    realtime   first_actual_axi_last_ns;
    realtime   second_actual_axi_last_ns;
    realtime   first_obs_delta_ns;
    realtime   second_obs_delta_ns;
    dram_rsp_t first_rsp;
    dram_rsp_t ref_rsp;
    dram_rsp_t second_rsp;

    this.wait_for_reset_release();
    this._grant.clear();
    this._dram_rsp.clear();
    this.clear_manager_observations();

    // Keep the first long read occupying the device window until its final
    // beat is ready, so the periodic REF can interleave before the second read
    // is granted.
    this._tb_env.u_mc.cfg.honor_beat_timing = FALSE;
    this._tb_env.dram.cfg.deliver_at_first_beat = 1'b0;

    mc_before   = this._tb_env.u_mc.get_refresh_count();
    dram_before = this._tb_env.dram.get_refresh_count();

    this.issue_read_no_wait('h1, 'h0400, LONG_READ_BEATS_C);
    this.issue_read_no_wait('h2, 'h2400, 1);

    repeat (OBS_TIMEOUT_CYCLES_C) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if ((this._grant.grants.size() >= 3) && (this.rd_observations.size() >= 2)) begin
        break;
      end
    end

    if (this.rd_observations.size() != 2) begin
      `uvm_fatal(get_name(), $sformatf(
        "Refresh-collision test expected 2 read responses, saw %0d",
        this.rd_observations.size()))
    end
    first_obs_idx  = -1;
    second_obs_idx = -1;
    foreach (this.rd_observations[i]) begin
      if ((first_obs_idx < 0) && (this.rd_observations[i].rid == 'h1)) begin
        first_obs_idx = i;
      end
      else if ((second_obs_idx < 0) && (this.rd_observations[i].rid == 'h2)) begin
        second_obs_idx = i;
      end

      if (this.rd_observations[i].rresp != VIP_MC_AXI4_RESP_OKAY_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "Refresh-collision test observed RRESP=%0b on response %0d instead of OKAY",
          this.rd_observations[i].rresp,
          i))
      end
    end
    if ((first_obs_idx < 0) || (second_obs_idx < 0)) begin
      `uvm_fatal(get_name(),
        "Refresh-collision test did not observe both read IDs on the returning R channel")
    end

    first_idx  = -1;
    ref_idx    = -1;
    second_idx = -1;
    foreach (this._grant.grants[i]) begin
      if ((first_idx < 0) &&
          (this._grant.grants[i].op == int'(VIP_DRAM_OP_RD_E)) &&
          (this._grant.grants[i].axi4_id == 'h1)) begin
        first_idx = i;
      end
      else if ((first_idx >= 0) &&
               (ref_idx < 0) &&
               (this._grant.grants[i].op == int'(VIP_DRAM_OP_REF_E))) begin
        ref_idx = i;
      end
      else if ((ref_idx >= 0) &&
               (this._grant.grants[i].op == int'(VIP_DRAM_OP_RD_E)) &&
               (this._grant.grants[i].axi4_id == 'h2)) begin
        second_idx = i;
        break;
      end
    end

    if ((first_idx < 0) || (ref_idx < 0) || (second_idx < 0)) begin
      `uvm_fatal(get_name(),
        "Refresh-collision test did not observe grant order READ0 -> REF -> READ1")
    end

    if (!this._dram_rsp.has_rsp(this._grant.grants[first_idx].tag) ||
        !this._dram_rsp.has_rsp(this._grant.grants[ref_idx].tag)   ||
        !this._dram_rsp.has_rsp(this._grant.grants[second_idx].tag)) begin
      `uvm_fatal(get_name(),
        "Refresh-collision test did not capture the expected DRAM responses for READ0 / REF / READ1")
    end

    first_rsp  = this._dram_rsp.get_rsp(this._grant.grants[first_idx].tag);
    ref_rsp    = this._dram_rsp.get_rsp(this._grant.grants[ref_idx].tag);
    second_rsp = this._dram_rsp.get_rsp(this._grant.grants[second_idx].tag);

    if ((first_rsp == null) || (ref_rsp == null) || (second_rsp == null)) begin
      `uvm_fatal(get_name(),
        "Refresh-collision test lost one of the captured DRAM response handles")
    end
    if ((first_rsp.op != VIP_DRAM_OP_RD_E) ||
        (ref_rsp.op != VIP_DRAM_OP_REF_E)  ||
        (second_rsp.op != VIP_DRAM_OP_RD_E)) begin
      `uvm_fatal(get_name(),
        "Refresh-collision test captured unexpected DRAM response opcodes for READ0 / REF / READ1")
    end

    mc_after   = this._tb_env.u_mc.get_refresh_count();
    dram_after = this._tb_env.dram.get_refresh_count();
    if ((mc_after - mc_before) == 0) begin
      `uvm_fatal(get_name(), "Refresh-collision test did not emit any refreshes")
    end
    if ((mc_after - mc_before) != (dram_after - dram_before)) begin
      `uvm_fatal(get_name(),
        "Refresh-collision test saw vip_mc emitted refresh count diverge from vip_dram executed refresh count")
    end

    trfc_ns        = this._tb_env.dram.cfg.timing.tRFC;
    ref_latency_ns = ref_rsp.first_beat_ready_time - this._grant.grants[ref_idx].grant_time;
    if (ref_latency_ns < (trfc_ns - 1.0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "Refresh-collision test observed REF latency=%0.1fns, expected at least tRFC=%0.1fns",
        ref_latency_ns,
        trfc_ns))
    end

    first_actual_axi_last_ns = this.expected_axi_last(
      first_rsp.first_beat_ready_time,
      first_rsp.last_beat_ready_time,
      this._grant.grants[first_idx].beats);
    second_actual_axi_last_ns = this.expected_axi_last(
      second_rsp.first_beat_ready_time,
      second_rsp.last_beat_ready_time,
      this._grant.grants[second_idx].beats);

    if (second_rsp.first_beat_ready_time < ref_rsp.first_beat_ready_time) begin
      `uvm_fatal(get_name(), $sformatf(
        "Refresh-collision test saw READ1 first-beat readiness=%0.1fns before REF completed at %0.1fns",
        second_rsp.first_beat_ready_time,
        ref_rsp.first_beat_ready_time))
    end
    if (this._grant.grants[second_idx].grant_time >= ref_rsp.first_beat_ready_time) begin
      `uvm_fatal(get_name(), $sformatf(
        "Refresh-collision test expected READ1 to be accepted by DRAM before REF completed: READ1 grant=%0.1fns REF done=%0.1fns",
        this._grant.grants[second_idx].grant_time,
        ref_rsp.first_beat_ready_time))
    end

    first_obs_delta_ns = realtime'(this.rd_observation_times[first_obs_idx]) - first_actual_axi_last_ns;
    if ((first_obs_delta_ns < AXI_EARLY_SLACK_NS_C) || (first_obs_delta_ns > AXI_TIMING_TOL_NS_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "Refresh-collision test saw READ0 AXI timing diverge from DRAM timing: observed=%0t expected=%0.1fns delta=%0.1fns",
        this.rd_observation_times[first_obs_idx],
        first_actual_axi_last_ns,
        first_obs_delta_ns))
    end

    second_obs_delta_ns = realtime'(this.rd_observation_times[second_obs_idx]) - second_actual_axi_last_ns;
    if ((second_obs_delta_ns < AXI_EARLY_SLACK_NS_C) || (second_obs_delta_ns > AXI_TIMING_TOL_NS_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "Refresh-collision test saw READ1 AXI timing diverge from DRAM timing: observed=%0t expected=%0.1fns delta=%0.1fns",
        this.rd_observation_times[second_obs_idx],
        second_actual_axi_last_ns,
        second_obs_delta_ns))
    end

    `uvm_info(get_name(), $sformatf(
      "vip_mc refresh collision test passed (grant order READ0->REF->READ1, REF latency=%0.1fns, READ1 ready=%0.1fns, tRFC=%0.1fns)",
      ref_latency_ns,
      second_rsp.first_beat_ready_time,
      trfc_ns), UVM_LOW)
  endtask
endclass
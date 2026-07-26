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
// tc_mc_qos_aging  (§13.3 #17 / P1-2)
//
// Anti-starvation: a single low-class request queued behind a saturating stream
// of high-class requests must be promoted by aging and issued within roughly
// (qos_class_count-1) * qos_aging_ns, rather than being starved indefinitely.
// Grant order/time are observed off backend.issued_port; the device command
// window is bounded to 1 so the backlog persists long enough for aging to act.
// -----------------------------------------------------------------------------
class tc_mc_qos_aging extends mc_base_test;

  `uvm_component_utils(tc_mc_qos_aging)

  localparam int OBS_TIMEOUT_CYCLES_C = 2048;
  localparam int N_HIGH_BEFORE_C = 4;   // high-class reads queued AHEAD of the low one
  localparam int N_HIGH_AFTER_C  = 8;   // high-class reads issued AFTER the low one
  localparam int LOW_ID_C        = 'h1; // the starved low-class request

  mc_qos_grant_collector _grant;
  realtime               _low_arrival_time = 0.0;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(input uvm_phase phase);
    uvm_config_db #(int)::set(this, "env", "mc_max_inflight_to_device", 1);
    uvm_config_db #(int)::set(this, "env", "mc_scoreboard_timing_check", 0);
    super.build_phase(phase);
    this._grant = mc_qos_grant_collector::type_id::create("grant", this);
  endfunction

  function void connect_phase(input uvm_phase phase);
    super.connect_phase(phase);
    this._tb_env.u_mc.backend.issued_port.connect(this._grant.analysis_export);
  endfunction

  protected task issue_read_no_wait_qos(
    input logic [VIP_MC_AXI4_CFG_C.ARID_WIDTH_P - 1 : 0] arid,
    input logic [3 : 0]                                  arqos,
    input longint unsigned                               addr
  );
    vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)           rd_seq;
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;

    fe0 = this.get_port_fe(0);
    rd_seq = vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)::type_id::create($sformatf(
      "aging_rd_seq_%0h_%0h", arid, addr));
    rd_seq.reset();
    rd_seq.set_arid(arid);
    rd_seq.set_axaddr(addr);
    rd_seq.set_axlen(0);
    rd_seq.set_axsize(this.get_full_width_axi_size());
    rd_seq.set_axburst(VIP_MC_AXI4_BURST_INCR_C);
    rd_seq.set_axqos(arqos);
    rd_seq.set_requests(1);
    rd_seq.set_get_rd_response(1'b0);
    this.start_seq_or_timeout(
      rd_seq, this._tb_env.man_agent[0].sequencer, fe0, 0, rd_seq.get_name());
  endtask

  task body();
    int total;
    int next_id;
    int slot;
    this.wait_for_reset_release();
    this._grant.clear();
    this.clear_manager_observations();

    total   = N_HIGH_BEFORE_C + N_HIGH_AFTER_C + 1;
    next_id = 2;
    slot    = 0;

    // 1) A run of high-class reads: the first occupies the 1-deep device window,
    //    the rest queue ahead of the low request so it is genuinely starved.
    for (int i = 0; i < N_HIGH_BEFORE_C; i++) begin
      this.issue_read_no_wait_qos(next_id, 4'hf, 'h0400 + (slot * 'h10000));
      next_id++; slot++;
    end
    // 2) The starved low-class read (older than every high-class read that
    //    follows, so once aging lifts it to the top class it wins on FCFS).
    this.issue_read_no_wait_qos(LOW_ID_C, 4'h0, 'h0400 + (slot * 'h10000));
    this._low_arrival_time = $realtime;
    slot++;
    // 3) Keep the high-class backlog saturated while the low request ages up.
    for (int i = 0; i < N_HIGH_AFTER_C; i++) begin
      this.issue_read_no_wait_qos(next_id, 4'hf, 'h0400 + (slot * 'h10000));
      next_id++; slot++;
    end

    // Wait for all grants, then for all R responses to drain off the bus.
    repeat (OBS_TIMEOUT_CYCLES_C) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if (this._grant.size() >= total) break;
    end
    repeat (OBS_TIMEOUT_CYCLES_C) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if (this.rd_observations.size() >= total) break;
    end

    `uvm_info(get_name(), $sformatf("grant order (n=%0d, peak_depth=%0d):",
      this._grant.size(), this._tb_env.u_mc.get_cmd_queue_peak_depth()), UVM_LOW)
    foreach (this._grant.grant_tag[i]) begin
      `uvm_info(get_name(), $sformatf("  grant[%0d] class=%0d id=0x%0h t=%0t",
        i, this._grant.grant_qos[i], this._grant.grant_id[i], this._grant.grant_time[i]), UVM_LOW)
    end

    this.check_aging(total);
  endtask

  protected function void check_aging(input int total);
    int      low_idx;
    int      highs_before_low;
    int      highs_after_low;
    realtime grant_delay;
    realtime aging_bound;

    if (this._grant.size() != total) begin
      `uvm_fatal(get_name(), $sformatf(
        "aging test expected %0d grants, saw %0d", total, this._grant.size()))
    end
    if (this._tb_env.u_mc.get_cmd_queue_peak_depth() < 2) begin
      `uvm_fatal(get_name(),
        "aging test did not build a backlog (peak<2); no contention for aging to resolve")
    end

    low_idx = this._grant.index_of_id(LOW_ID_C);

    // (1) Not starved: the low-class request was eventually granted.
    if (low_idx < 0) begin
      `uvm_error(get_name(), "starvation: low-class request was never granted")
      return;
    end

    // (2) Aging signature: the low request lands in the MIDDLE of the high
    //     stream — preempted by older high-class requests (granted before it),
    //     then promoted past later high-class requests (granted after it).
    //     Without aging it would drain dead-last (no highs after it).
    highs_before_low = 0;
    highs_after_low  = 0;
    foreach (this._grant.grant_qos[i]) begin
      if (this._grant.grant_qos[i] == 3) begin
        if (i < low_idx) highs_before_low++;
        if (i > low_idx) highs_after_low++;
      end
    end
    if (highs_before_low == 0) begin
      `uvm_error(get_name(),
        "low-class request was not preempted by any high-class request; priority not applied")
    end
    if (highs_after_low == 0) begin
      `uvm_error(get_name(),
        "low-class request drained last (no high-class granted after it); aging did not promote it")
    end

    // (3) Bounded latency: promotion to the top class takes
    //     (qos_class_count-1) * qos_aging_ns; allow slack for the admit delay
    //     and one device service to actually issue after promotion.
    grant_delay = this._grant.grant_time[low_idx] - this._low_arrival_time;
    aging_bound = (real'(this._tb_env.u_mc.cfg.qos_class_count) - 1.0) *
                  this._tb_env.u_mc.cfg.qos_aging_ns + 100.0;
    if (grant_delay > aging_bound) begin
      `uvm_error(get_name(), $sformatf(
        "aging too slow: low-class granted %0.1fns after arrival (bound %0.1fns)",
        grant_delay, aging_bound))
    end

    `uvm_info(get_name(), $sformatf(
      "QoS aging verified: low-class granted at index %0d, %0.1fns after arrival (bound %0.1fns); %0d high-class before it, %0d after it",
      low_idx, grant_delay, aging_bound, highs_before_low, highs_after_low), UVM_LOW)
  endfunction

endclass

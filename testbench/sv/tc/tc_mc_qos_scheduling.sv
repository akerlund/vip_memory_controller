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
// tc_mc_qos_scheduling  (§13.3 #16 / P1-2)
//
// Exercises the backend QoS-class arbiter: with several mixed-AxQOS requests in
// flight, a higher class should be granted ahead of older lower-class requests,
// while same-stream (same {port,id,op}) order is preserved. The grant order is
// observed directly off backend.issued_port (§8.9). qos_class_count == 1 must
// revert to pure FCFS (arrival order).
// -----------------------------------------------------------------------------

// Records the grant-ordered stream from backend.issued_port.
class mc_qos_grant_collector extends uvm_subscriber #(vip_mc_cmd_entry #(DRAM_CFG_C));
  longint unsigned grant_tag[$];
  int              grant_qos[$];
  longint unsigned grant_id[$];
  int              grant_op[$];
  realtime         grant_time[$];

  `uvm_component_utils(mc_qos_grant_collector)

  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  function void write(input vip_mc_cmd_entry #(DRAM_CFG_C) t);
    if (t.op == VIP_DRAM_OP_REF_E) begin
      return;  // refresh bypasses cmd_queue; not part of the QoS order
    end
    this.grant_tag.push_back(t.tag);
    this.grant_qos.push_back(t.qos_class);
    this.grant_id.push_back(t.axi4_id);
    this.grant_op.push_back(int'(t.op));
    this.grant_time.push_back($realtime);
  endfunction

  function int size(); return this.grant_tag.size(); endfunction

  // Return the grant index of the first entry with the given id, or -1.
  function int index_of_id(input longint unsigned id);
    foreach (this.grant_id[i]) begin
      if (this.grant_id[i] == id) begin
        return i;
      end
    end
    return -1;
  endfunction

  function void clear();
    this.grant_tag.delete();
    this.grant_qos.delete();
    this.grant_id.delete();
    this.grant_op.delete();
    this.grant_time.delete();
  endfunction
endclass

class tc_mc_qos_scheduling extends mc_base_test;

  `uvm_component_utils(tc_mc_qos_scheduling)

  localparam int OBS_TIMEOUT_CYCLES_C = 1024;

  mc_qos_grant_collector _grant;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(input uvm_phase phase);
    // Bound the device command window to 1 so a multi-class backlog forms at the
    // QoS arbiter. This test checks issue ORDER, not latency, so the scoreboard
    // timing check (which assumes in-order predict lock-step) is disabled.
    uvm_config_db #(int)::set(this, "env", "mc_max_inflight_to_device", 1);
    uvm_config_db #(int)::set(this, "env", "mc_scoreboard_timing_check", 0);
    super.build_phase(phase);
    this._grant = mc_qos_grant_collector::type_id::create("grant", this);
  endfunction

  function void connect_phase(input uvm_phase phase);
    super.connect_phase(phase);
    this._tb_env.u_mc.backend.issued_port.connect(this._grant.analysis_export);
  endfunction

  // Issue one single-beat read without waiting for the R response.
  protected task issue_read_no_wait_qos(
    input logic [VIP_MC_AXI4_CFG_C.ARID_WIDTH_P - 1 : 0] arid,
    input logic [3 : 0]                                  arqos,
    input longint unsigned                               addr
  );
    vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)           rd_seq;
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;

    fe0 = this.get_port_fe(0);

    rd_seq = vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)::type_id::create($sformatf(
      "qos_rd_seq_%0h_%0h", arid, addr));
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

  localparam int N_READS_C    = 12;
  localparam int HI_ARRIVAL_C = 8;   // 0-based arrival index of the high-class read

  task body();
    this.wait_for_reset_release();
    this._grant.clear();
    this.clear_manager_observations();

    // Fire a back-to-back stream of distinct-ID low-class reads to build a
    // backlog behind the 1-deep device window, then one high-class read late in
    // the stream (ARQOS 15 -> class 3), then more low-class reads.
    for (int i = 0; i < N_READS_C; i++) begin
      logic [3 : 0] qos;
      qos = (i == HI_ARRIVAL_C) ? 4'hf : 4'h0;
      // Large stride -> different DRAM rows -> page misses -> longer device
      // latency than the AR arrival rate, so the 1-deep window backs up.
      this.issue_read_no_wait_qos(i + 1, qos, 'h0400 + (i * 'h10000));
    end

    // Wait for all reads to be granted (issued to the device)...
    repeat (OBS_TIMEOUT_CYCLES_C) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if (this._grant.size() >= N_READS_C) begin
        break;
      end
    end

    // ...and for every R response to drain on the bus, so no transaction is left
    // outstanding when the test ends.
    repeat (OBS_TIMEOUT_CYCLES_C) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if (this.rd_observations.size() >= N_READS_C) begin
        break;
      end
    end

    `uvm_info(get_name(), $sformatf("grant order (n=%0d, peak_depth=%0d):",
      this._grant.size(), this._tb_env.u_mc.get_cmd_queue_peak_depth()), UVM_LOW)
    foreach (this._grant.grant_tag[i]) begin
      `uvm_info(get_name(), $sformatf(
        "  grant[%0d] tag=%0d class=%0d id=0x%0h",
        i, this._grant.grant_tag[i], this._grant.grant_qos[i], this._grant.grant_id[i]), UVM_LOW)
    end

    this.check_qos_scheduling();
  endtask

  // ---------------------------------------------------------------------------
  // Assert the §13.3 #16 QoS-scheduling properties on the observed grant order.
  // ---------------------------------------------------------------------------
  protected function void check_qos_scheduling();
    int hi_grant_idx;
    int hi_arrival_idx;
    int preempted_older_low;
    int prev_low_arrival;

    if (this._grant.size() != N_READS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "QoS test expected %0d grants, saw %0d", N_READS_C, this._grant.size()))
    end

    // Contention precondition: the 1-deep device window must have produced a
    // multi-entry backlog, else the arbiter never had a choice to make.
    if (this._tb_env.u_mc.get_cmd_queue_peak_depth() < 2) begin
      `uvm_fatal(get_name(),
        "QoS test did not build a cmd_queue backlog (peak<2); arbiter had no contention")
    end

    // Locate the single high-class (class 3) request and its arrival index.
    hi_grant_idx   = -1;
    hi_arrival_idx = HI_ARRIVAL_C;
    foreach (this._grant.grant_qos[i]) begin
      if (this._grant.grant_qos[i] == 3) begin
        hi_grant_idx = i;
      end
    end
    if (hi_grant_idx < 0) begin
      `uvm_fatal(get_name(), "QoS test never observed the high-class request granted")
    end

    // (1) Priority: the high-class request must be granted earlier than its
    // arrival position (it preempted older lower-class requests still queued).
    if (!(hi_grant_idx < hi_arrival_idx)) begin
      `uvm_error(get_name(), $sformatf(
        "QoS priority not honored: class-3 request granted at index %0d but arrived at index %0d (no preemption)",
        hi_grant_idx, hi_arrival_idx))
    end

    // ...and concretely, at least one older (earlier-arriving) low-class request
    // must be granted after it.
    preempted_older_low = 0;
    foreach (this._grant.grant_id[i]) begin
      if ((i > hi_grant_idx) && (this._grant.grant_qos[i] == 0) &&
          ((this._grant.grant_id[i] - 1) < hi_arrival_idx)) begin
        preempted_older_low++;
      end
    end
    if (preempted_older_low == 0) begin
      `uvm_error(get_name(),
        "QoS priority not honored: no older low-class request was preempted by the high-class request")
    end

    // (2) FCFS within a class: the low-class (class 0) requests must remain in
    // arrival order relative to each other (id encodes arrival: id == arrival+1).
    prev_low_arrival = -1;
    foreach (this._grant.grant_qos[i]) begin
      if (this._grant.grant_qos[i] == 0) begin
        int arrival;
        arrival = this._grant.grant_id[i] - 1;
        if (arrival <= prev_low_arrival) begin
          `uvm_error(get_name(), $sformatf(
            "FCFS-within-class violated: low-class arrival %0d granted after arrival %0d",
            arrival, prev_low_arrival))
        end
        prev_low_arrival = arrival;
      end
    end

    `uvm_info(get_name(), $sformatf(
      "QoS scheduling verified: class-3 granted at index %0d (arrived %0d), preempted %0d older low-class request(s); low-class FCFS preserved",
      hi_grant_idx, hi_arrival_idx, preempted_older_low), UVM_LOW)
  endfunction

endclass

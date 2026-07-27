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
// vip_mc_backend
//
// Shared backend skeleton for the first instantiable vip_mc slice. It owns the
// front-end ingress FIFOs, the single device-bound req_port, and the DRAM rsp
// subscriber used by the top-level wiring.
// -----------------------------------------------------------------------------
class vip_mc_backend #(
  vip_dram_cfg_t DRAM_CFG_P = VIP_DRAM_CFG_DEFAULT_C,
  int            N_PORTS    = 1
  ) extends uvm_component;

  typedef vip_mc_cmd_entry #(DRAM_CFG_P) cmd_t;
  typedef vip_dram_req     #(DRAM_CFG_P) req_t;
  typedef vip_dram_rsp     #(DRAM_CFG_P) rsp_t;

  vip_mc_config                              mc_cfg;
  vip_dram #(DRAM_CFG_P)                     dram;
  vip_mc_fe_base #(DRAM_CFG_P)               fes[N_PORTS];
  vip_mc_cmd_queue #(DRAM_CFG_P)             cmd_queue;
  vip_mc_activity_fifo #(cmd_t)              fe_fifo[N_PORTS];
  vip_mc_activity_fifo #(cmd_t)              ref_fifo;
  uvm_analysis_port #(req_t)                 req_port;
  uvm_analysis_port #(cmd_t)                 issued_port;
  uvm_analysis_imp #(rsp_t, vip_mc_backend #(DRAM_CFG_P, N_PORTS)) rsp_subscriber;

  protected cmd_t                            inflight_ref_by_tag[longint unsigned];
  protected int                              next_fe_port_rr = 0;
  protected int                              current_fe_port_grants_left = 0;
  protected int                              inflight_to_device = 0;
  protected uvm_event                        state_changed_ev;

  // Controller bring-up (tINIT) gate: while closed, no device issue happens.
  // Opened init_delay_ns after each reset deassert (or immediately when the
  // init delay is disabled). Armed by vip_mc on posedge rst_n.
  protected bit                              init_gate_open = 1'b1;
  protected process                          init_proc;

  cmd_t         last_issued_cmd;
  req_t         last_issued_req;
  rsp_t         last_rsp;
  cmd_t         last_completed_cmd;
  int unsigned  issued_req_count   = 0;
  int unsigned  observed_rsp_count = 0;
  int unsigned  completed_cmd_count = 0;
  protected realtime         predicted_last_by_tag[longint unsigned];
  protected longint unsigned telemetry_data_bytes        = 0;
  protected realtime         telemetry_predict_error_ns  = 0.0;
  protected int unsigned     telemetry_predict_samples   = 0;
  protected realtime         telemetry_busy_time_ns      = 0.0;
  protected realtime         telemetry_first_data_ns     = 0.0;
  protected realtime         telemetry_last_burst_end_ns = 0.0;
  protected bit              telemetry_window_valid      = 1'b0;

  // Residual observability (§11). All guarded by perf_counters_enabled and reset
  // by clear_perf_counters(); accumulated per completed host request (primary and
  // every coalesced secondary).
  //  - Completion latency (admit -> last device beat): running sum/min/max plus a
  //    coarse log2-ns histogram (bucket b spans [2^b, 2^(b+1)) ns; bucket 0 also
  //    absorbs sub-1 ns).
  //  - Observed out-of-order retirements: completions whose admit_order is older
  //    than one already retired (quantifies the emergent inter-ID reorder, §4.3).
  //  - Per-port utilization: completed request count and delivered payload bytes.
  protected realtime         telemetry_latency_sum_ns    = 0.0;
  protected int unsigned     telemetry_latency_samples   = 0;
  protected realtime         telemetry_latency_min_ns    = 0.0;
  protected realtime         telemetry_latency_max_ns    = 0.0;
  protected longint unsigned latency_hist[int];
  protected int unsigned     observed_reorder_count      = 0;
  protected longint unsigned max_completed_admit_order   = 0;
  protected longint unsigned port_completed_count[N_PORTS];
  protected longint unsigned port_data_bytes[N_PORTS];

  // ECC / SECDED read-error tallies (§11 item 5). Correctable reads are corrected
  // to OKAY; uncorrectable reads are mapped to a bus SLVERR. Only meaningful when
  // cfg.ecc_enable is set; reset by clear_perf_counters().
  protected int unsigned     ecc_corrected_count     = 0;
  protected int unsigned     ecc_uncorrectable_count = 0;

  // FR-FCFS starvation-cap forced overrides (§11 item 1): times the cap forced
  // the oldest bypassed entry ahead of the readiness winner. Reset per epoch.
  protected int unsigned     fr_fcfs_forced_count    = 0;

  // Read/write grouping state (§11 item 1, turnaround-aware). last_issued_is_read
  // is the bus direction of the most recent RD/WR issued to the device (REF is
  // rank-level, not a DQ transfer, so it does not count); same_dir_run_len counts
  // consecutive same-direction issues (drives the rd_wr_grouping_max cap). These
  // are operational state, reset by handle_reset. bus_turnaround_count tallies
  // issued RD<->WR direction flips (the bubble-inducing events grouping minimizes)
  // and rd_wr_grouped_count tallies picks where grouping overrode the readiness
  // winner — telemetry, cleared per epoch by clear_perf_counters().
  protected bit              last_issued_dir_valid   = 1'b0;
  protected bit              last_issued_is_read     = 1'b0;
  protected int unsigned     same_dir_run_len        = 0;
  protected int unsigned     bus_turnaround_count    = 0;
  protected int unsigned     rd_wr_grouped_count     = 0;

  localparam realtime PREDICT_EPS_C     = 0.001;
  localparam int      LAT_HIST_MAX_BUCKET_C = 24;  // caps at [2^24, ...) ns

  `uvm_component_param_utils(vip_mc_backend #(DRAM_CFG_P, N_PORTS))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
    this.req_port       = new("req_port", this);
    this.issued_port    = new("issued_port", this);
    this.rsp_subscriber = new("rsp_subscriber", this);
    this.state_changed_ev = new("state_changed_ev");
  endfunction

  // ---------------------------------------------------------------------------
  // Build the per-port ingress FIFOs.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    super.build_phase(phase);

    if (this.mc_cfg == null) begin
      `uvm_fatal(get_name(), "vip_mc_backend requires a non-null mc_cfg handle")
    end
    if ((this.mc_cfg.fr_fcfs_enable == TRUE) && (this.dram == null)) begin
      `uvm_fatal(get_name(), "vip_mc_backend requires a dram handle when fr_fcfs_enable is TRUE")
    end

    this.ref_fifo = new("ref_fifo", this);
    this.ref_fifo.state_changed_ev = this.state_changed_ev;
    this.cmd_queue = vip_mc_cmd_queue #(DRAM_CFG_P)::type_id::create(
      "cmd_queue",
      this);
    this.cmd_queue.cfg = this.mc_cfg;
    this.cmd_queue.state_changed_ev = this.state_changed_ev;

    for (int port_id = 0; port_id < N_PORTS; port_id++) begin
      this.fe_fifo[port_id] = new($sformatf("fe_fifo_%0d", port_id), this);
      this.fe_fifo[port_id].state_changed_ev = this.state_changed_ev;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Register one front-end with its fixed port id.
  // ---------------------------------------------------------------------------
  function void register_port(
    input int                           port_id,
    input vip_mc_fe_base #(DRAM_CFG_P)  fe
  );
    if (port_id < 0 || port_id >= N_PORTS) begin
      `uvm_fatal(get_name(), $sformatf(
        "Port id %0d out of range 0..%0d", port_id, N_PORTS - 1))
    end

    if (fe == null) begin
      `uvm_fatal(get_name(), $sformatf(
        "register_port(%0d) received a null front-end", port_id))
    end

    this.fes[port_id] = fe;
  endfunction

  // ---------------------------------------------------------------------------
  // Connect every registered front-end into its ingress FIFO.
  // ---------------------------------------------------------------------------
  function void connect_phase(input uvm_phase phase);
    super.connect_phase(phase);

    for (int port_id = 0; port_id < N_PORTS; port_id++) begin
      if (this.fes[port_id] == null) begin
        `uvm_fatal(get_name(), $sformatf(
          "Front-end for port %0d was not registered", port_id))
      end
      this.fes[port_id].req_port.connect(this.fe_fifo[port_id].analysis_export);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Serialize refresh and FE traffic into the single device-bound req_port.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);
    cmd_t entry;

    super.run_phase(phase);

    forever begin
      if (!this.init_gate_open) begin
        // Bring-up hold-off: admit/queue continues elsewhere, but issue nothing
        // to the device until the gate opens (the arming timer triggers the ev).
        this.state_changed_ev.reset();
        if (!this.init_gate_open) begin
          this.state_changed_ev.wait_ptrigger();
        end
      end
      else if (this.ref_fifo.try_get(entry)) begin
        this.issue_one(entry);
      end
      else begin
        this.admit_one_ready_fe_entry();

        // Issue a queued request only while the device command window has room.
        // When it is full the entry stays in cmd_queue, so under load a multi-
        // class backlog forms and the QoS arbiter (pick) chooses among it.
        if (this.device_has_issue_credit() && this.pick_next_entry(entry)) begin
          this.cmd_queue.enqueue(entry);
          this.issue_one(entry);
          this.inflight_to_device++;
        end
        else begin
          this.state_changed_ev.reset();
          if (!this.has_buffered_input() &&
              !(this.device_has_issue_credit() && this.cmd_queue.has_issuable_entry())) begin
            this.state_changed_ev.wait_ptrigger();
          end
        end
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Observe one DRAM response on the shared completion path.
  // ---------------------------------------------------------------------------
  function void write(input rsp_t rsp);
    cmd_t entry;
    realtime burst_end_ns;
    realtime busy_span_ns;
    realtime pred_error_ns;

    this.last_rsp = rsp;
    this.observed_rsp_count++;

    if (this.inflight_ref_by_tag.exists(rsp.tag)) begin
      this.inflight_ref_by_tag.delete(rsp.tag);
      return;
    end

    if (!this.cmd_queue.complete_by_rsp(rsp, entry)) begin
      `uvm_error(get_name(), $sformatf(
        "Received DRAM rsp for unknown tag 0x%0h", rsp.tag))
      return;
    end

    // Release one device command-window slot (complete_by_rsp already pulsed
    // state_changed_ev, so the arbiter re-evaluates and may issue the next).
    if (this.inflight_to_device > 0) begin
      this.inflight_to_device--;
    end

    entry.resp                  = entry.is_exclusive ? VIP_MC_AXI4_RESP_EXOKAY_C
                                                     : VIP_MC_AXI4_RESP_OKAY_C;
    entry.first_beat_ready_time = rsp.first_beat_ready_time;
    entry.last_beat_ready_time  = rsp.last_beat_ready_time;
    entry.completed             = 1'b1;

    // ECC / SECDED read-error mapping (§11 item 5): the device physically
    // corrupted every faulted beat. The SECDED layer repairs each correctable
    // beat by un-flipping the bit the device flagged in rsp.corrupt_mask (a
    // double-bit beat carries a zero mask, so it stays poisoned), then classifies
    // the response by the worst severity: a corrected read stays successful, an
    // uncorrectable double-bit error becomes a bus SLVERR (overriding OKAY/EXOKAY
    // above). With ECC disabled the corrupted bytes flow through untouched
    // (silent data corruption), matching a controller with no ECC.
    if ((this.mc_cfg != null) && (this.mc_cfg.ecc_enable == TRUE) &&
        (entry.op == VIP_DRAM_OP_RD_E)) begin
      if (rsp.corrupt_mask.size() == rsp.rdata.size()) begin
        foreach (rsp.rdata[i]) begin
          rsp.rdata[i] ^= rsp.corrupt_mask[i];
        end
      end
      // Functional classification: an uncorrectable beat poisons the response
      // with SLVERR regardless of the perf gate.
      if (rsp.injected_fault == VIP_DRAM_FAULT_UNCORRECTABLE_E) begin
        entry.resp = VIP_MC_AXI4_RESP_SLVERR_C;
      end
      // Telemetry tallies are perf-gated like every other accumulator so a
      // perf off->on toggle never surfaces counts accrued while "off". Note the
      // count keys off the worst severity across beats; in mixed multi-beat
      // reads a correctable beat is still repaired above but not tallied here.
      if (this.mc_cfg.perf_counters_enabled == TRUE) begin
        case (rsp.injected_fault)
          VIP_DRAM_FAULT_CORRECTABLE_E:   this.ecc_corrected_count++;
          VIP_DRAM_FAULT_UNCORRECTABLE_E: this.ecc_uncorrectable_count++;
          default: ;  // VIP_DRAM_FAULT_NONE_E: no change
        endcase
      end
    end

    entry.rdata = new[rsp.rdata.size()];
    foreach (rsp.rdata[i]) begin
      entry.rdata[i] = rsp.rdata[i];
    end

    if ((this.mc_cfg != null) &&
        (this.mc_cfg.perf_counters_enabled == TRUE) &&
        (this.dram != null)) begin
      burst_end_ns = rsp.last_beat_ready_time + this.dram.cfg.timing.tBL;
      busy_span_ns = burst_end_ns - rsp.first_beat_ready_time;
      if (busy_span_ns < 0.0) begin
        busy_span_ns = 0.0;
      end

      this.telemetry_data_bytes += (entry.beats * DRAM_CFG_P.ROW_BYTES_P);
      this.telemetry_busy_time_ns += busy_span_ns;

      if (!this.telemetry_window_valid ||
          (rsp.first_beat_ready_time < this.telemetry_first_data_ns)) begin
        this.telemetry_first_data_ns = rsp.first_beat_ready_time;
      end
      if (!this.telemetry_window_valid ||
          (burst_end_ns > this.telemetry_last_burst_end_ns)) begin
        this.telemetry_last_burst_end_ns = burst_end_ns;
      end
      this.telemetry_window_valid = 1'b1;

      if (this.predicted_last_by_tag.exists(rsp.tag)) begin
        pred_error_ns = rsp.last_beat_ready_time - this.predicted_last_by_tag[rsp.tag];
        if (pred_error_ns < 0.0) begin
          pred_error_ns = -pred_error_ns;
        end
        this.telemetry_predict_error_ns += pred_error_ns;
        this.telemetry_predict_samples++;
        this.predicted_last_by_tag.delete(rsp.tag);
      end
    end

    this.last_completed_cmd = entry;
    this.completed_cmd_count++;
    this.note_completion_observability(entry);
    if (entry.port_id >= 0) begin
      this.fes[entry.port_id].complete(entry);
    end

    // Write-coalescing fan-out (§11): the one device response also completes every
    // host write merged into this primary. The merged writes all map to the same
    // physical device access, so each secondary inherits the primary's response
    // (normally OKAY; the same error if the shared access failed) and the same
    // device timing, and is completed in arrival order, after the primary, so
    // same-id B order holds. (A secondary is never exclusive — try_coalesce_write
    // refuses exclusive and pre-resolved writes — so this never propagates EXOKAY.)
    foreach (entry.merged_writes[i]) begin
      cmd_t secondary;

      secondary = entry.merged_writes[i];
      if (secondary == null) begin
        continue;
      end
      secondary.resp                  = entry.resp;
      secondary.first_beat_ready_time = rsp.first_beat_ready_time;
      secondary.last_beat_ready_time  = rsp.last_beat_ready_time;
      secondary.completed             = 1'b1;
      this.completed_cmd_count++;
      this.note_completion_observability(secondary);
      if (secondary.port_id >= 0) begin
        this.fes[secondary.port_id].complete(secondary);
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Return how many ports are currently registered.
  // ---------------------------------------------------------------------------
  function int get_registered_port_count();
    int count;

    count = 0;
    for (int port_id = 0; port_id < N_PORTS; port_id++) begin
      if (this.fes[port_id] != null) begin
        count++;
      end
    end
    return count;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the queued command-queue peak depth when counters are enabled.
  // ---------------------------------------------------------------------------
  function int get_cmd_queue_peak_depth();
    if ((this.mc_cfg == null) ||
        (this.mc_cfg.perf_counters_enabled == FALSE) ||
        (this.cmd_queue == null)) begin
      return 0;
    end

    return this.cmd_queue.get_peak_depth();
  endfunction

  // ---------------------------------------------------------------------------
  // Return the mean absolute last-beat prediction error in nanoseconds.
  // ---------------------------------------------------------------------------
  function real get_predict_accuracy();
    if ((this.mc_cfg == null) ||
        (this.mc_cfg.perf_counters_enabled == FALSE) ||
        (this.telemetry_predict_samples == 0)) begin
      return 0.0;
    end

    return this.telemetry_predict_error_ns / real'(this.telemetry_predict_samples);
  endfunction

  // ---------------------------------------------------------------------------
  // Return the effective payload bandwidth in bytes/ns over the observed data
  // window [first data beat start, last burst end].
  // ---------------------------------------------------------------------------
  function real get_effective_bandwidth();
    realtime window_ns;

    if ((this.mc_cfg == null) ||
        (this.mc_cfg.perf_counters_enabled == FALSE) ||
        !this.telemetry_window_valid) begin
      return 0.0;
    end

    window_ns = this.telemetry_last_burst_end_ns - this.telemetry_first_data_ns;
    if (window_ns <= 0.0) begin
      return 0.0;
    end

    return real'(this.telemetry_data_bytes) / window_ns;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the fraction of the observed data window during which the channel
  // carried read/write burst data.
  // ---------------------------------------------------------------------------
  function real get_bus_utilization();
    realtime window_ns;

    if ((this.mc_cfg == null) ||
        (this.mc_cfg.perf_counters_enabled == FALSE) ||
        !this.telemetry_window_valid) begin
      return 0.0;
    end

    window_ns = this.telemetry_last_burst_end_ns - this.telemetry_first_data_ns;
    if (window_ns <= 0.0) begin
      return 0.0;
    end

    return this.telemetry_busy_time_ns / window_ns;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the lifetime count of host writes folded into a coalesced primary
  // (§11 write coalescing). Zero unless cfg.write_coalescing_enable is set.
  // ---------------------------------------------------------------------------
  function int unsigned get_coalesced_write_count();
    if (this.cmd_queue == null) begin
      return 0;
    end
    return this.cmd_queue.get_coalesced_write_count();
  endfunction

  // ---------------------------------------------------------------------------
  // Residual observability (§11): fold one completed host request into the
  // latency / reorder / per-port accumulators. No-op unless perf_counters_enabled.
  // ---------------------------------------------------------------------------
  protected function void note_completion_observability(input cmd_t entry);
    realtime lat_ns;
    int      bucket;

    if ((entry == null) ||
        (this.mc_cfg == null) ||
        (this.mc_cfg.perf_counters_enabled != TRUE)) begin
      return;
    end

    // Completion latency: admit -> last device beat.
    lat_ns = entry.last_beat_ready_time - entry.admit_time;
    if (lat_ns < 0.0) begin
      lat_ns = 0.0;
    end
    this.telemetry_latency_sum_ns += lat_ns;
    if ((this.telemetry_latency_samples == 0) ||
        (lat_ns < this.telemetry_latency_min_ns)) begin
      this.telemetry_latency_min_ns = lat_ns;
    end
    if ((this.telemetry_latency_samples == 0) ||
        (lat_ns > this.telemetry_latency_max_ns)) begin
      this.telemetry_latency_max_ns = lat_ns;
    end
    this.telemetry_latency_samples++;

    bucket = this.latency_bucket(lat_ns);
    if (this.latency_hist.exists(bucket)) begin
      this.latency_hist[bucket]++;
    end
    else begin
      this.latency_hist[bucket] = 1;
    end

    // Observed out-of-order retirement: an older-admitted request completing
    // after a younger one already retired.
    if (entry.admit_order < this.max_completed_admit_order) begin
      this.observed_reorder_count++;
    end
    else begin
      this.max_completed_admit_order = entry.admit_order;
    end

    // Per-port utilization.
    if ((entry.port_id >= 0) && (entry.port_id < N_PORTS)) begin
      this.port_completed_count[entry.port_id]++;
      this.port_data_bytes[entry.port_id] +=
        longint'(entry.beats) * longint'(DRAM_CFG_P.ROW_BYTES_P);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Map a latency in ns to its coarse log2 histogram bucket. Bucket b spans
  // [2^b, 2^(b+1)) ns; bucket 0 also absorbs sub-1 ns, and the top bucket is
  // saturating.
  // ---------------------------------------------------------------------------
  protected function int latency_bucket(input realtime lat_ns);
    int  bucket;
    real value;

    value  = lat_ns;
    bucket = 0;
    if (value < 1.0) begin
      return 0;
    end
    while ((value >= 2.0) && (bucket < LAT_HIST_MAX_BUCKET_C)) begin
      value = value / 2.0;
      bucket++;
    end
    return bucket;
  endfunction

  // ---------------------------------------------------------------------------
  // Residual-observability getters (§11). Each returns 0 unless counters are on.
  // ---------------------------------------------------------------------------
  function int unsigned get_observed_reorder_count();
    if ((this.mc_cfg == null) || (this.mc_cfg.perf_counters_enabled == FALSE)) begin
      return 0;
    end
    return this.observed_reorder_count;
  endfunction

  function real get_mean_latency_ns();
    if ((this.mc_cfg == null) ||
        (this.mc_cfg.perf_counters_enabled == FALSE) ||
        (this.telemetry_latency_samples == 0)) begin
      return 0.0;
    end
    return this.telemetry_latency_sum_ns / real'(this.telemetry_latency_samples);
  endfunction

  function real get_min_latency_ns();
    if ((this.mc_cfg == null) ||
        (this.mc_cfg.perf_counters_enabled == FALSE) ||
        (this.telemetry_latency_samples == 0)) begin
      return 0.0;
    end
    return this.telemetry_latency_min_ns;
  endfunction

  function real get_max_latency_ns();
    if ((this.mc_cfg == null) ||
        (this.mc_cfg.perf_counters_enabled == FALSE) ||
        (this.telemetry_latency_samples == 0)) begin
      return 0.0;
    end
    return this.telemetry_latency_max_ns;
  endfunction

  function int unsigned get_latency_sample_count();
    if ((this.mc_cfg == null) || (this.mc_cfg.perf_counters_enabled == FALSE)) begin
      return 0;
    end
    return this.telemetry_latency_samples;
  endfunction

  function longint unsigned get_latency_hist_count(input int bucket);
    if ((this.mc_cfg == null) ||
        (this.mc_cfg.perf_counters_enabled == FALSE) ||
        (!this.latency_hist.exists(bucket))) begin
      return 0;
    end
    return this.latency_hist[bucket];
  endfunction

  function longint unsigned get_port_completed_count(input int port_id);
    if ((this.mc_cfg == null) ||
        (this.mc_cfg.perf_counters_enabled == FALSE) ||
        (port_id < 0) || (port_id >= N_PORTS)) begin
      return 0;
    end
    return this.port_completed_count[port_id];
  endfunction

  function longint unsigned get_port_data_bytes(input int port_id);
    if ((this.mc_cfg == null) ||
        (this.mc_cfg.perf_counters_enabled == FALSE) ||
        (port_id < 0) || (port_id >= N_PORTS)) begin
      return 0;
    end
    return this.port_data_bytes[port_id];
  endfunction

  function longint unsigned get_occupancy_hist_count(input int depth);
    if ((this.mc_cfg == null) ||
        (this.mc_cfg.perf_counters_enabled == FALSE) ||
        (this.cmd_queue == null)) begin
      return 0;
    end
    return this.cmd_queue.get_occupancy_hist_count(depth);
  endfunction

  function longint unsigned get_occupancy_sample_count();
    if ((this.mc_cfg == null) ||
        (this.mc_cfg.perf_counters_enabled == FALSE) ||
        (this.cmd_queue == null)) begin
      return 0;
    end
    return this.cmd_queue.get_occupancy_sample_count();
  endfunction

  // ---------------------------------------------------------------------------
  // ECC / SECDED read-error tallies (§11 item 5).
  // ---------------------------------------------------------------------------
  function int unsigned get_ecc_corrected_count();
    if ((this.mc_cfg == null) || (this.mc_cfg.perf_counters_enabled == FALSE)) begin
      return 0;
    end
    return this.ecc_corrected_count;
  endfunction

  function int unsigned get_ecc_uncorrectable_count();
    if ((this.mc_cfg == null) || (this.mc_cfg.perf_counters_enabled == FALSE)) begin
      return 0;
    end
    return this.ecc_uncorrectable_count;
  endfunction

  // ---------------------------------------------------------------------------
  // FR-FCFS starvation-cap forced overrides (§11 item 1).
  // ---------------------------------------------------------------------------
  function int unsigned get_fr_fcfs_forced_count();
    if ((this.mc_cfg == null) || (this.mc_cfg.perf_counters_enabled == FALSE)) begin
      return 0;
    end
    return this.fr_fcfs_forced_count;
  endfunction

  // ---------------------------------------------------------------------------
  // Issued RD<->WR bus-direction turnarounds (§11 item 1) — the event read/write
  // grouping minimizes. At equal throughput a lower count means the device
  // turnaround bubble was amortized over longer same-direction runs. Counts
  // regardless of rd_wr_grouping_enable, so a baseline run can be compared.
  // ---------------------------------------------------------------------------
  function int unsigned get_bus_turnaround_count();
    if ((this.mc_cfg == null) || (this.mc_cfg.perf_counters_enabled == FALSE)) begin
      return 0;
    end
    return this.bus_turnaround_count;
  endfunction

  // ---------------------------------------------------------------------------
  // Picks where read/write grouping (§11 item 1) served a same-direction candidate
  // instead of the pure readiness-first winner. 0 when rd_wr_grouping_enable is
  // FALSE (grouping never overrides).
  // ---------------------------------------------------------------------------
  function int unsigned get_rd_wr_grouped_count();
    if ((this.mc_cfg == null) || (this.mc_cfg.perf_counters_enabled == FALSE)) begin
      return 0;
    end
    return this.rd_wr_grouped_count;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the current queued command depth.
  // ---------------------------------------------------------------------------
  function int get_cmd_queue_depth();
    if (this.cmd_queue == null) begin
      return 0;
    end
    return this.cmd_queue.get_pending_count();
  endfunction

  // ---------------------------------------------------------------------------
  // Return the current number of device-backed requests in flight.
  // ---------------------------------------------------------------------------
  function int get_inflight_to_device();
    return this.inflight_to_device;
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether the backend has device issue credit right now.
  // ---------------------------------------------------------------------------
  function bit get_device_issue_credit_avail();
    return this.device_has_issue_credit();
  endfunction

  // ---------------------------------------------------------------------------
  // Return a best-effort backend stall reason for the optional status probe.
  // ---------------------------------------------------------------------------
  function vip_mc_status_stall_e get_status_stall_reason();
    if (!this.ref_fifo.is_empty()) begin
      return VIP_MC_STATUS_STALL_REF_STRICT_PRIORITY_E;
    end
    if (!this.device_has_issue_credit()) begin
      return VIP_MC_STATUS_STALL_DEVICE_CREDIT_FULL_E;
    end
    if (this.cmd_queue.has_issuable_entry()) begin
      return VIP_MC_STATUS_STALL_NONE_E;
    end
    if (this.cmd_queue.get_pending_count() > 0) begin
      return VIP_MC_STATUS_STALL_SAME_STREAM_BLOCKED_E;
    end
    if (this.has_buffered_input()) begin
      return VIP_MC_STATUS_STALL_CMD_QUEUE_EMPTY_E;
    end
    return VIP_MC_STATUS_STALL_NO_BUFFERED_INPUT_E;
  endfunction

  // ---------------------------------------------------------------------------
  // Drain all ingress, reset arbitration, and flush the owned cmd_queue (reset
  // choreography, §9). The arbiter run_phase is not killed: with every producer
  // FIFO emptied and the cmd_queue cleared it simply re-parks on the wakeup
  // event triggered here. No new producer feeds the FIFOs while rst_n is low
  // (the front-ends self-reset and refresh is flushed), so the backend stays
  // quiescent until traffic resumes after reset.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Arm the controller bring-up (tINIT) gate. vip_mc calls this on every posedge
  // rst_n. With init_delay disabled (or a non-positive delay) the gate opens
  // immediately; otherwise it closes now and a forked timer reopens it
  // init_delay_ns later, re-evaluating the issue loop via state_changed_ev. The
  // timer process is stored so flush() (reset assert) can kill it.
  // ---------------------------------------------------------------------------
  function void init_gate_arm();
    if ((this.mc_cfg == null) ||
        (this.mc_cfg.init_delay_enabled != TRUE) ||
        (this.mc_cfg.init_delay_ns <= 0.0)) begin
      this.init_gate_open = 1'b1;
      this.state_changed_ev.trigger();   // wake the issue loop if it was gated
      return;
    end

    this.init_gate_open = 1'b0;
    fork
      begin
        this.init_proc = process::self();
        #(this.mc_cfg.init_delay_ns * 1ns);
        this.init_gate_open = 1'b1;
        this.state_changed_ev.trigger();
      end
    join_none
  endfunction

  function void flush();
    // Kill any pending bring-up timer; init_gate_arm() (next posedge rst_n) sets
    // the gate state. The gate is not forced closed here so a delay-disabled
    // backend never strands the issue loop during the reset window.
    if (this.init_proc != null) begin
      this.init_proc.kill();
      this.init_proc = null;
    end
    this.ref_fifo.flush();
    for (int port_id = 0; port_id < N_PORTS; port_id++) begin
      this.fe_fifo[port_id].flush();
    end
    this.inflight_ref_by_tag.delete();
    this.next_fe_port_rr             = 0;
    this.current_fe_port_grants_left = 0;
    this.inflight_to_device          = 0;
    // Read/write grouping run state starts fresh each epoch so the first post-reset
    // issue never counts a turnaround across the reset boundary (§11 item 1).
    this.last_issued_dir_valid       = 1'b0;
    this.last_issued_is_read         = 1'b0;
    this.same_dir_run_len            = 0;
    this.cmd_queue.flush();
    this.state_changed_ev.trigger();
  endfunction

  // ---------------------------------------------------------------------------
  // Clear the backend's §8.8 counters for a fresh post-reset epoch.
  // ---------------------------------------------------------------------------
  function void clear_perf_counters();
    this.issued_req_count   = 0;
    this.observed_rsp_count = 0;
    this.completed_cmd_count = 0;
    this.predicted_last_by_tag.delete();
    this.telemetry_data_bytes        = 0;
    this.telemetry_predict_error_ns  = 0.0;
    this.telemetry_predict_samples   = 0;
    this.telemetry_busy_time_ns      = 0.0;
    this.telemetry_first_data_ns     = 0.0;
    this.telemetry_last_burst_end_ns = 0.0;
    this.telemetry_window_valid      = 1'b0;
    this.telemetry_latency_sum_ns    = 0.0;
    this.telemetry_latency_samples   = 0;
    this.telemetry_latency_min_ns    = 0.0;
    this.telemetry_latency_max_ns    = 0.0;
    this.latency_hist.delete();
    this.observed_reorder_count      = 0;
    this.max_completed_admit_order   = 0;
    for (int port_id = 0; port_id < N_PORTS; port_id++) begin
      this.port_completed_count[port_id] = 0;
      this.port_data_bytes[port_id]      = 0;
    end
    this.ecc_corrected_count         = 0;
    this.ecc_uncorrectable_count     = 0;
    this.fr_fcfs_forced_count        = 0;
    this.bus_turnaround_count        = 0;
    this.rd_wr_grouped_count         = 0;
    this.cmd_queue.clear_perf_counters();
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether the device command window has room for one more issue.
  // ---------------------------------------------------------------------------
  protected function bit device_has_issue_credit();
    if (this.mc_cfg.max_inflight_to_device <= 0) begin
      return 1'b1;  // unbounded
    end
    return (this.inflight_to_device < this.mc_cfg.max_inflight_to_device);
  endfunction

  // ---------------------------------------------------------------------------
  // Pick the next queued entry using either the legacy FCFS policy or the
  // FR-FCFS tie-break when enabled.
  // ---------------------------------------------------------------------------
  protected function bit pick_next_entry(output cmd_t entry);
    entry = null;

    if ((this.mc_cfg != null) && (this.mc_cfg.fr_fcfs_enable == TRUE)) begin
      return this.pick_next_entry_fr_fcfs(entry);
    end

    return this.cmd_queue.pick(entry);
  endfunction

  // ---------------------------------------------------------------------------
  // FR-FCFS selection within the highest currently effective QoS class.
  // ---------------------------------------------------------------------------
  protected function bit pick_next_entry_fr_fcfs(output cmd_t entry);
    int               selected_effective_class;
    int               winner_list_idx;
    longint unsigned  winner_admit_order;
    realtime          winner_last_ready;
    int               forced_list_idx;
    longint unsigned  forced_admit_order;
    int               class_idx_q[$];
    int               entry_idx_q[$];

    entry = null;
    if ((this.cmd_queue == null) || (this.dram == null)) begin
      return 1'b0;
    end

    selected_effective_class = this.cmd_queue.get_highest_effective_class();
    if (selected_effective_class < 0) begin
      return 1'b0;
    end

    this.cmd_queue.get_eligible_entries_in_effective_class(
      selected_effective_class,
      class_idx_q,
      entry_idx_q);
    if (class_idx_q.size() == 0) begin
      return 1'b0;
    end

    // Pass 1: readiness-first winner (earliest predicted last beat; tie -> oldest).
    winner_list_idx    = -1;
    winner_admit_order = '1;
    winner_last_ready  = 0.0;

    foreach (class_idx_q[i]) begin
      cmd_t    candidate;
      realtime first_ready;
      realtime last_ready;

      if (!this.cmd_queue.peek_entry(class_idx_q[i], entry_idx_q[i], candidate)) begin
        continue;
      end

      this.predict_candidate_ready_times(candidate, first_ready, last_ready);
      if ((winner_list_idx < 0) ||
          (last_ready < (winner_last_ready - PREDICT_EPS_C)) ||
          (((last_ready >= (winner_last_ready - PREDICT_EPS_C)) &&
            (last_ready <= (winner_last_ready + PREDICT_EPS_C))) &&
           (candidate.admit_order < winner_admit_order))) begin
        winner_list_idx    = i;
        winner_admit_order = candidate.admit_order;
        winner_last_ready  = last_ready;
      end
    end

    if (winner_list_idx < 0) begin
      return 1'b0;
    end

    // Turnaround-aware grouping (§11 item 1): once a bus direction is established,
    // prefer serving more of the SAME direction so reads/writes issue in runs and
    // the device turnaround bubble (tWTR/tRTW) is amortized instead of paid on every
    // flip. Among same-direction candidates the readiness key still decides (earliest
    // predicted last beat, then oldest). The rd_wr_grouping_max cap inverts the
    // preferred direction after a run of that length so the other direction cannot
    // starve; the readiness winner above is the fallback when no candidate of the
    // preferred direction is eligible (a flip is then unavoidable). Composes with the
    // starvation cap below, which still bounds within-direction reordering.
    if ((this.mc_cfg.rd_wr_grouping_enable == TRUE) && this.last_issued_dir_valid) begin
      bit              prefer_read;
      int              group_list_idx;
      longint unsigned group_admit_order;
      realtime         group_last_ready;

      prefer_read = this.last_issued_is_read;
      if ((this.mc_cfg.rd_wr_grouping_max > 0) &&
          (this.same_dir_run_len >= this.mc_cfg.rd_wr_grouping_max)) begin
        prefer_read = !this.last_issued_is_read;   // forced turnaround (anti-starvation)
      end

      group_list_idx    = -1;
      group_admit_order = '1;
      group_last_ready  = 0.0;

      foreach (class_idx_q[i]) begin
        cmd_t    candidate;
        realtime first_ready;
        realtime last_ready;

        if (!this.cmd_queue.peek_entry(class_idx_q[i], entry_idx_q[i], candidate)) begin
          continue;
        end
        if (((candidate.op == VIP_DRAM_OP_RD_E)) != prefer_read) begin
          continue;                                // wrong direction this round
        end
        this.predict_candidate_ready_times(candidate, first_ready, last_ready);
        if ((group_list_idx < 0) ||
            (last_ready < (group_last_ready - PREDICT_EPS_C)) ||
            (((last_ready >= (group_last_ready - PREDICT_EPS_C)) &&
              (last_ready <= (group_last_ready + PREDICT_EPS_C))) &&
             (candidate.admit_order < group_admit_order))) begin
          group_list_idx    = i;
          group_admit_order = candidate.admit_order;
          group_last_ready  = last_ready;
        end
      end

      // A same-(preferred-)direction candidate exists: serve it. When it differs
      // from the readiness winner the grouping preference actually changed the pick.
      if (group_list_idx >= 0) begin
        if (group_list_idx != winner_list_idx) begin
          this.rd_wr_grouped_count++;
        end
        winner_list_idx    = group_list_idx;
        winner_admit_order = group_admit_order;
        winner_last_ready  = group_last_ready;
      end
    end

    // Starvation cap (§11 item 1): bound how far an older request can be reordered
    // past. Disabled (0) leaves pure FR-FCFS. When enabled, an eligible entry that
    // has already been bypassed cfg.fr_fcfs_starvation_cap times is force-served
    // (oldest first) instead of the readiness winner; otherwise the winner is
    // served and every older eligible entry is charged one bypass this round.
    if (this.mc_cfg.fr_fcfs_starvation_cap > 0) begin
      forced_list_idx    = -1;
      forced_admit_order = '1;

      foreach (class_idx_q[i]) begin
        cmd_t candidate;

        if (!this.cmd_queue.peek_entry(class_idx_q[i], entry_idx_q[i], candidate)) begin
          continue;
        end
        if ((candidate.bypass_count >= this.mc_cfg.fr_fcfs_starvation_cap) &&
            (candidate.admit_order < forced_admit_order)) begin
          forced_list_idx    = i;
          forced_admit_order = candidate.admit_order;
        end
      end

      if (forced_list_idx >= 0) begin
        this.fr_fcfs_forced_count++;
        return this.cmd_queue.take_entry(
          class_idx_q[forced_list_idx],
          entry_idx_q[forced_list_idx],
          entry);
      end

      foreach (class_idx_q[i]) begin
        cmd_t candidate;

        if (i == winner_list_idx) begin
          continue;
        end
        if (!this.cmd_queue.peek_entry(class_idx_q[i], entry_idx_q[i], candidate)) begin
          continue;
        end
        if (candidate.admit_order < winner_admit_order) begin
          candidate.bypass_count++;
        end
      end
    end

    return this.cmd_queue.take_entry(
      class_idx_q[winner_list_idx],
      entry_idx_q[winner_list_idx],
      entry);
  endfunction

  // ---------------------------------------------------------------------------
  // Predict the device-ready times for one queued entry without mutating state.
  // ---------------------------------------------------------------------------
  protected function void predict_candidate_ready_times(
    input  cmd_t    entry,
    output realtime first_ready,
    output realtime last_ready
  );
    req_t req;

    if (entry.pre_resolved) begin
      first_ready = $realtime;
      last_ready  = $realtime;
      return;
    end

    req = req_t::type_id::create("fr_fcfs_predict_req");
    req.addr              = entry.get_dev_addr();
    req.op                = entry.op;
    req.beats             = entry.beats;
    req.has_explicit_rank = entry.has_explicit_rank;
    req.rank              = entry.rank;
    // entry.tag is still 0 here (the tag is stamped later in cmd_queue.enqueue),
    // but dram.predict() is stateless timing and ignores the tag, so it is moot.
    req.tag               = entry.tag;
    this.dram.predict(req, first_ready, last_ready);
  endfunction

  // ---------------------------------------------------------------------------
  // Admit one buffered FE entry in weighted round-robin port order.
  // ---------------------------------------------------------------------------
  protected function void admit_one_ready_fe_entry();
    cmd_t entry;

    for (int rr_offset = 0; rr_offset < N_PORTS; rr_offset++) begin
      int port_id;

      port_id = (this.next_fe_port_rr + rr_offset) % N_PORTS;
      if (this.fe_fifo[port_id].try_get(entry)) begin
        // Write coalescing (§11): if this write merges into an already pending
        // same-stream write to the same row-word, it is folded there instead of
        // being admitted as a separate device access.
        if (!this.cmd_queue.try_coalesce_write(entry)) begin
          this.cmd_queue.admit(entry);
        end
        this.update_fe_rr_after_grant(port_id);
        return;
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Return the configured arbitration weight for one port.
  // ---------------------------------------------------------------------------
  protected function int get_port_weight(input int port_id);
    if (this.mc_cfg.ports[port_id].arb_weight <= 0) begin
      return 1;
    end
    return this.mc_cfg.ports[port_id].arb_weight;
  endfunction

  // ---------------------------------------------------------------------------
  // Advance the weighted round-robin state after one FE grant.
  // ---------------------------------------------------------------------------
  protected function void update_fe_rr_after_grant(input int port_id);
    int port_weight;

    port_weight = this.get_port_weight(port_id);
    if ((port_id != this.next_fe_port_rr) || (this.current_fe_port_grants_left == 0)) begin
      this.next_fe_port_rr = port_id;
      this.current_fe_port_grants_left = port_weight;
    end

    if (this.current_fe_port_grants_left > 0) begin
      this.current_fe_port_grants_left--;
    end

    if (this.current_fe_port_grants_left == 0) begin
      this.next_fe_port_rr = (port_id + 1) % N_PORTS;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether any producer FIFO currently holds a buffered entry.
  // ---------------------------------------------------------------------------
  protected function bit has_buffered_input();
    if (!this.ref_fifo.is_empty()) begin
      return 1'b1;
    end

    for (int port_id = 0; port_id < N_PORTS; port_id++) begin
      if (!this.fe_fifo[port_id].is_empty()) begin
        return 1'b1;
      end
    end

    return 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // Translate one tagged entry to vip_dram_req and issue it to the device.
  // ---------------------------------------------------------------------------
  protected function void issue_one(input cmd_t entry);
    req_t req;

    // Grant-order tap (§8.9 / B7). Every granted entry — FE and REF — passes
    // through here exactly once, in grant order, with its final tag already
    // assigned (FE: cmd_queue.enqueue; REF: pre-set bit-63 tag). This is the
    // only place device-ingress order is observable with the AXI4 IDs still
    // attached, so a timing scoreboard subscribes here to drive predict() in
    // the exact order (and REF interleaving) the device sees. Diagnostic only:
    // no device coupling, left unconnected when timing is not checked.
    this.last_issued_cmd = entry;
    this.issued_port.write(entry);

    if ((entry.op == VIP_DRAM_OP_REF_E) && entry.tag[63]) begin
      this.inflight_ref_by_tag[entry.tag] = entry;
    end
    else if (entry.tag == '0) begin
      `uvm_fatal(get_name(), "issue_one() received a non-refresh entry without a flat tag")
    end

    // Read/write grouping bookkeeping (§11 item 1): track the issued bus direction
    // and count RD<->WR turnarounds in device-issue (== bus) order. REF is a
    // rank-level command, not a DQ data transfer, so it neither breaks nor extends
    // the read/write run.
    if (entry.op != VIP_DRAM_OP_REF_E) begin
      bit issued_is_read = (entry.op == VIP_DRAM_OP_RD_E);

      if (this.last_issued_dir_valid && (issued_is_read != this.last_issued_is_read)) begin
        this.bus_turnaround_count++;
        this.same_dir_run_len = 1;
      end
      else begin
        this.same_dir_run_len++;
      end
      this.last_issued_is_read   = issued_is_read;
      this.last_issued_dir_valid = 1'b1;
    end

    req = req_t::type_id::create($sformatf("req_%0d", this.issued_req_count));
    // Burst window base, not the protocol start address - see get_dev_addr().
    req.addr              = entry.get_dev_addr();
    req.op                = entry.op;
    req.beats             = entry.beats;
    req.has_explicit_rank = entry.has_explicit_rank;
    req.rank              = entry.rank;
    req.tag               = entry.tag;
    req.wdata             = new[entry.wdata.size()];
    req.wstrb             = new[entry.wstrb.size()];

    foreach (entry.wdata[i]) begin
      req.wdata[i] = entry.wdata[i];
    end
    foreach (entry.wstrb[i]) begin
      req.wstrb[i] = entry.wstrb[i];
    end

    if ((this.mc_cfg != null) &&
        (this.mc_cfg.perf_counters_enabled == TRUE) &&
        (entry.op != VIP_DRAM_OP_REF_E) &&
        (this.dram != null)) begin
      realtime pred_first_ready;
      realtime pred_last_ready;

      this.dram.predict(req, pred_first_ready, pred_last_ready);
      this.predicted_last_by_tag[entry.tag] = pred_last_ready;
    end

    this.last_issued_req = req;
    this.issued_req_count++;
    this.req_port.write(req);
  endfunction

endclass
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
// vip_mc
//
// Top-level vip_mc component skeleton. This slice builds the shared backend and
// one or more homogeneous AXI4 front-ends from the env_cfg / discrete config
// path and wires them to the shared vip_dram device boundary.
// -----------------------------------------------------------------------------
class vip_mc #(
  vip_dram_cfg_t    DRAM_CFG_P = VIP_DRAM_CFG_DEFAULT_C,
  int               N_PORTS    = 1,
  vip_mc_port_cfg_t PORTS [N_PORTS]
  ) extends uvm_component;

  vip_mc_config                         cfg;
  vip_dram #(DRAM_CFG_P)                dram;
  virtual vip_mc_status_if #(N_PORTS)   status_vif;
  vip_mc_backend #(DRAM_CFG_P, N_PORTS) backend;
  vip_mc_refresh #(DRAM_CFG_P)          refresh;
  vip_mc_fe_base #(DRAM_CFG_P)          fes[N_PORTS];
  vip_mc_status_snapshot #(N_PORTS)     status_snapshot;
  protected int unsigned                last_status_issued_count    = 0;
  protected int unsigned                last_status_completed_count = 0;
  protected int unsigned                last_status_refresh_count   = 0;
  protected int unsigned                last_status_reject_count[N_PORTS];

  // Per-protocol representative width cfgs. Each protocol is homogeneous across
  // its ports (§2.1, enforced by require_supported_ports), so the FE/vif types
  // elaborate against a single representative cfg per protocol, taken from
  // PORTS[0]. Convention: every PORTS[] entry carries BOTH the AXI4 and CHI
  // representative in its .axi4/.chi fields (only the field matching .proto
  // drives that port's FE, but the representatives must be table-consistent),
  // so a mixed "AXI4 + CHI" table works regardless of which port is which.
  //
  // Width fields are clamped to >= 1 so the *unused* protocol's front-end (which
  // is always elaborated, never created) yields a legal type even when its cfg
  // is left '0 -- e.g. a CHI-only table with .axi4 = '0 must not produce a
  // zero-width AXI4 driver ([-1:0] selects = Error-[SIOB]). For a protocol that
  // is actually used, its widths are already >= 1 so the clamp is a no-op and
  // the homogeneity check against PORTS[k] still holds. (A scanning constant-
  // function was avoided: VCS crashes elaborating an open-array constant
  // function in a localparam.)
  localparam vip_mc_axi4_cfg_t AXI4_CFG_C = '{
    AWID_WIDTH_P   : (PORTS[0].axi4.AWID_WIDTH_P   > 0) ? PORTS[0].axi4.AWID_WIDTH_P   : 1,
    ARID_WIDTH_P   : (PORTS[0].axi4.ARID_WIDTH_P   > 0) ? PORTS[0].axi4.ARID_WIDTH_P   : 1,
    ADDR_WIDTH_P   : (PORTS[0].axi4.ADDR_WIDTH_P   > 0) ? PORTS[0].axi4.ADDR_WIDTH_P   : 1,
    WDATA_BYTES_P  : (PORTS[0].axi4.WDATA_BYTES_P  > 0) ? PORTS[0].axi4.WDATA_BYTES_P  : 1,
    RDATA_BYTES_P  : (PORTS[0].axi4.RDATA_BYTES_P  > 0) ? PORTS[0].axi4.RDATA_BYTES_P  : 1,
    AWUSER_WIDTH_P : (PORTS[0].axi4.AWUSER_WIDTH_P > 0) ? PORTS[0].axi4.AWUSER_WIDTH_P : 1,
    WUSER_WIDTH_P  : (PORTS[0].axi4.WUSER_WIDTH_P  > 0) ? PORTS[0].axi4.WUSER_WIDTH_P  : 1,
    BUSER_WIDTH_P  : (PORTS[0].axi4.BUSER_WIDTH_P  > 0) ? PORTS[0].axi4.BUSER_WIDTH_P  : 1,
    ARUSER_WIDTH_P : (PORTS[0].axi4.ARUSER_WIDTH_P > 0) ? PORTS[0].axi4.ARUSER_WIDTH_P : 1,
    RUSER_WIDTH_P  : (PORTS[0].axi4.RUSER_WIDTH_P  > 0) ? PORTS[0].axi4.RUSER_WIDTH_P  : 1
  };
`ifdef VIP_MC_ENABLE_CHI
  localparam vip_mc_chi_cfg_t  CHI_CFG_C  = '{
    issue           : PORTS[0].chi.issue,
    NODE_ID_WIDTH_P : (PORTS[0].chi.NODE_ID_WIDTH_P > 0) ? PORTS[0].chi.NODE_ID_WIDTH_P : 1,
    ADDR_WIDTH_P    : (PORTS[0].chi.ADDR_WIDTH_P    > 0) ? PORTS[0].chi.ADDR_WIDTH_P    : 1,
    DATA_BYTES_P    : (PORTS[0].chi.DATA_BYTES_P    > 0) ? PORTS[0].chi.DATA_BYTES_P    : 1,
    DATACHECK_EN_P  : PORTS[0].chi.DATACHECK_EN_P,
    POISON_EN_P     : PORTS[0].chi.POISON_EN_P,
    MPAM_EN_P       : PORTS[0].chi.MPAM_EN_P,
    PARITY_EN_P     : PORTS[0].chi.PARITY_EN_P
  };
`endif

  `uvm_component_param_utils(vip_mc #(DRAM_CFG_P, N_PORTS, PORTS))


  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Build the backend and bind the supported homogeneous AXI4 front-ends.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    vip_mc_env_cfg #(DRAM_CFG_P, N_PORTS, PORTS) env_cfg;
    bit                                           cfg_was_default_created;

    super.build_phase(phase);

    this.require_supported_ports();
    this.resolve_config_and_handles(env_cfg, cfg_was_default_created);
    this.status_snapshot = vip_mc_status_snapshot #(N_PORTS)::type_id::create(
      "status_snapshot");

    this.cfg.ensure_port_count(N_PORTS);
    if (cfg_was_default_created) begin
      this.cfg.addr_map_policy = vip_dram_default_addr_map(DRAM_CFG_P);
    end
    this.cfg.validate(DRAM_CFG_P);

    this.cfg.axi4.aw_outstanding_limit = this.cfg.max_outstanding_wr;
    this.cfg.axi4.ar_outstanding_limit = this.cfg.max_outstanding_rd;

    this.backend = vip_mc_backend #(DRAM_CFG_P, N_PORTS)::type_id::create(
      "backend",
      this);
    this.backend.mc_cfg = this.cfg;
    this.backend.dram   = this.dram;

    if (this.cfg.refresh_enabled == TRUE) begin
      this.refresh = vip_mc_refresh #(DRAM_CFG_P)::type_id::create(
        "refresh",
        this);
      this.refresh.cfg = this.cfg;
    end

    this.build_frontends(env_cfg);
  endfunction

  // ---------------------------------------------------------------------------
  // Wire the shared backend to the single DRAM device boundary.
  // ---------------------------------------------------------------------------
  function void connect_phase(input uvm_phase phase);
    super.connect_phase(phase);
    this.backend.req_port.connect(this.dram.req_fifo.analysis_export);
    this.dram.rsp_port.connect(this.backend.rsp_subscriber);

    if (this.refresh != null) begin
      this.refresh.req_port.connect(this.backend.ref_fifo.analysis_export);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Push the MC-owned address-map policy into the shared DRAM device config.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);
    real refresh_interval_ns;

    super.start_of_simulation_phase(phase);
    this.dram.cfg.addr_map = this.cfg.addr_map_policy;

    // §5.4: take the device response when the first beat is ready so the AXI4
    // driver can pace R beats first->last. The driver mirrors this knob.
    // vip_dram types this field as a plain bit; vip_mc's own bool_t enum
    // converts to it numerically.
    this.dram.cfg.deliver_at_first_beat = bit'(this.cfg.honor_beat_timing);

    // init_delay_enabled bring-up hold-off is armed on each posedge rst_n via
    // backend.init_gate_arm() (see the reset-choreography waiters below).

    if (this.refresh != null) begin
      refresh_interval_ns = this.cfg.tREFI_override;
      if (refresh_interval_ns < 0.0) begin
        refresh_interval_ns = this.dram.cfg.timing.tREFI;
      end
      this.refresh.cache_trefi_ns(refresh_interval_ns);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Reset choreography (§9). Watch rst_n on the canonical AXI4 interface: on
  // deassertion (re-)arm the refresh emitter; on assertion run the blocking
  // handle_reset(). The forked posedge waiter mirrors the vip_axi4_agent
  // watcher — the outer loop only waits on negedge so a TB that starts with
  // rst_n already low re-enters with rst_n known low. handle_reset() returns in
  // zero time (dram.reset() drains in the same delta), so the next iteration's
  // posedge waiter is always armed before rst_n can deassert again.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);
    super.run_phase(phase);

`ifdef VIP_MC_ENABLE_CHI
    // A CHI-fronted port 0 has no AXI4 vif to watch rst_n on; use the CHI vif.
    // The optional AXI4-centric status publisher is not run in that case (it is
    // debug-only, §8.8A). A mixed table with an AXI4 port 0 still takes the AXI4
    // path below and its status publisher zeroes any CHI port fields.
    if (PORTS[0].proto == VIP_MC_PROTO_CHI_E) begin
      this.run_chi_reset_loop();
      return;
    end
`endif

    this.run_axi4_reset_and_status();
  endtask

  // ---------------------------------------------------------------------------
  // AXI4-port-0 reset choreography + optional waveform status publisher.
  // ---------------------------------------------------------------------------
  protected task run_axi4_reset_and_status();
    virtual vip_mc_axi4_if #(AXI4_CFG_C) reset_vif;

    reset_vif = this.get_reset_vif();
    if (reset_vif == null) begin
      `uvm_warning(get_name(),
        "No AXI4 reset interface resolved; vip_mc reset choreography disabled")
      return;
    end

    if (this.status_vif != null) begin
      this.status_snapshot.clear();
      this.status_snapshot.rst_active = (reset_vif.rst_n !== 1'b1);
      this.drive_status_vif();
      fork
        this.run_status_publisher(reset_vif);
      join_none
    end

    forever begin
      fork
        begin
          @(posedge reset_vif.rst_n);
          this.backend.init_gate_arm();
          if (this.refresh != null) begin
            this.refresh.arm();
          end
        end
      join_none

      @(negedge reset_vif.rst_n);
      this.handle_reset();
    end
  endtask

`ifdef VIP_MC_ENABLE_CHI
  // ---------------------------------------------------------------------------
  // CHI-port-0 reset choreography (same shape as the AXI4 path, watching rst_n
  // on the CHI vif). No status publisher.
  // ---------------------------------------------------------------------------
  protected task run_chi_reset_loop();
    vip_mc_chi_driver #(CHI_CFG_C, DRAM_CFG_P) chi_fe;
    virtual vip_mc_chi_if #(CHI_CFG_C)         reset_vif;

    if (($size(this.fes) < 1) || !$cast(chi_fe, this.fes[0])) begin
      `uvm_warning(get_name(),
        "No CHI reset interface resolved; vip_mc reset choreography disabled")
      return;
    end
    reset_vif = chi_fe.vif;

    forever begin
      fork
        begin
          @(posedge reset_vif.rst_n);
          this.backend.init_gate_arm();
          if (this.refresh != null) begin
            this.refresh.arm();
          end
        end
      join_none

      @(negedge reset_vif.rst_n);
      this.handle_reset();
    end
  endtask
`endif

  // ---------------------------------------------------------------------------
  // Blocking reset handler (§9): flush every front-end, quiesce the backend,
  // kill the refresh emitter, clear perf counters, then block on the device's
  // own drain via the blocking dram.reset(). The refresh emitter is re-armed by
  // run_phase on the next posedge rst_n, not here.
  // ---------------------------------------------------------------------------
  task handle_reset();
    foreach (this.fes[port_id]) begin
      if (this.fes[port_id] != null) begin
        this.fes[port_id].handle_reset();
      end
    end

    this.backend.flush();

    if (this.refresh != null) begin
      this.refresh.flush();
    end

    this.backend.clear_perf_counters();

    this.dram.reset();

    if (this.status_snapshot != null) begin
      this.status_snapshot.clear();
      this.status_snapshot.rst_active = 1'b1;
      this.last_status_issued_count    = 0;
      this.last_status_completed_count = 0;
      this.last_status_refresh_count   = 0;
      foreach (this.last_status_reject_count[port_id]) begin
        this.last_status_reject_count[port_id] = 0;
      end
      if (this.status_vif != null) begin
        this.drive_status_vif();
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Resolve the canonical AXI4 interface used to watch rst_n (port 0). Returns
  // null if no AXI4 front-end is present (reset choreography then disabled).
  // ---------------------------------------------------------------------------
  protected function virtual vip_mc_axi4_if #(AXI4_CFG_C) get_reset_vif();
    vip_mc_axi4_driver #(AXI4_CFG_C, DRAM_CFG_P) axi4_fe;

    if ($size(this.fes) < 1) begin
      return null;
    end
    if (!$cast(axi4_fe, this.fes[0])) begin
      return null;
    end
    return axi4_fe.vif;
  endfunction

  // ---------------------------------------------------------------------------
  // Return how many REF requests this controller has emitted.
  // ---------------------------------------------------------------------------
  function int get_refresh_count();
    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE)) begin
      return 0;
    end
    if (this.refresh == null) begin
      return 0;
    end
    return this.refresh.get_refresh_count();
  endfunction

  // ---------------------------------------------------------------------------
  // Return the queued command-queue peak depth when counters are enabled.
  // ---------------------------------------------------------------------------
  function int get_cmd_queue_peak_depth();
    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE)) begin
      return 0;
    end
    if (this.backend == null) begin
      return 0;
    end
    return this.backend.get_cmd_queue_peak_depth();
  endfunction

  // ---------------------------------------------------------------------------
  // Return the fraction of completed device accesses that were page hits.
  // ---------------------------------------------------------------------------
  function real get_row_hit_rate();
    int hit_count;
    int miss_count;
    int empty_count;
    int total_count;

    if ((this.cfg == null) ||
        (this.cfg.perf_counters_enabled == FALSE) ||
        (this.dram == null)) begin
      return 0.0;
    end

    hit_count   = this.dram.get_page_hit_count();
    miss_count  = this.dram.get_page_miss_count();
    empty_count = this.dram.get_page_empty_count();
    total_count = hit_count + miss_count + empty_count;
    if (total_count == 0) begin
      return 0.0;
    end

    return real'(hit_count) / real'(total_count);
  endfunction

  // ---------------------------------------------------------------------------
  // Return the mean absolute device last-beat prediction error in ns.
  // ---------------------------------------------------------------------------
  function real get_predict_accuracy();
    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE)) begin
      return 0.0;
    end
    if (this.backend == null) begin
      return 0.0;
    end
    return this.backend.get_predict_accuracy();
  endfunction

  // ---------------------------------------------------------------------------
  // Return the effective payload bandwidth in bytes/ns.
  // ---------------------------------------------------------------------------
  function real get_effective_bandwidth();
    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE)) begin
      return 0.0;
    end
    if (this.backend == null) begin
      return 0.0;
    end
    return this.backend.get_effective_bandwidth();
  endfunction

  // ---------------------------------------------------------------------------
  // Return the channel data-bus utilization fraction over the observed window.
  // ---------------------------------------------------------------------------
  function real get_bus_utilization();
    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE)) begin
      return 0.0;
    end
    if (this.backend == null) begin
      return 0.0;
    end
    return this.backend.get_bus_utilization();
  endfunction

  // ---------------------------------------------------------------------------
  // Residual observability (§11): out-of-order retirements, completion-latency
  // stats + coarse log2-ns histogram, pending-depth occupancy histogram, and
  // per-port utilization. All return 0 unless perf_counters_enabled.
  // ---------------------------------------------------------------------------
  function int unsigned get_observed_reorder_count();
    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE) ||
        (this.backend == null)) begin
      return 0;
    end
    return this.backend.get_observed_reorder_count();
  endfunction

  function real get_mean_latency_ns();
    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE) ||
        (this.backend == null)) begin
      return 0.0;
    end
    return this.backend.get_mean_latency_ns();
  endfunction

  function real get_min_latency_ns();
    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE) ||
        (this.backend == null)) begin
      return 0.0;
    end
    return this.backend.get_min_latency_ns();
  endfunction

  function real get_max_latency_ns();
    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE) ||
        (this.backend == null)) begin
      return 0.0;
    end
    return this.backend.get_max_latency_ns();
  endfunction

  function int unsigned get_latency_sample_count();
    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE) ||
        (this.backend == null)) begin
      return 0;
    end
    return this.backend.get_latency_sample_count();
  endfunction

  function longint unsigned get_latency_hist_count(input int bucket);
    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE) ||
        (this.backend == null)) begin
      return 0;
    end
    return this.backend.get_latency_hist_count(bucket);
  endfunction

  function longint unsigned get_occupancy_hist_count(input int depth);
    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE) ||
        (this.backend == null)) begin
      return 0;
    end
    return this.backend.get_occupancy_hist_count(depth);
  endfunction

  function longint unsigned get_occupancy_sample_count();
    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE) ||
        (this.backend == null)) begin
      return 0;
    end
    return this.backend.get_occupancy_sample_count();
  endfunction

  function longint unsigned get_port_completed_count(input int port_id = 0);
    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE) ||
        (this.backend == null)) begin
      return 0;
    end
    return this.backend.get_port_completed_count(port_id);
  endfunction

  function longint unsigned get_port_data_bytes(input int port_id = 0);
    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE) ||
        (this.backend == null)) begin
      return 0;
    end
    return this.backend.get_port_data_bytes(port_id);
  endfunction

  // ---------------------------------------------------------------------------
  // ECC / SECDED read-error tallies (§11 item 5): single-bit reads corrected to
  // OKAY, and double-bit reads mapped to a bus SLVERR. Meaningful only with
  // cfg.ecc_enable; both return 0 unless perf_counters_enabled.
  // ---------------------------------------------------------------------------
  function int unsigned get_ecc_corrected_count();
    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE) ||
        (this.backend == null)) begin
      return 0;
    end
    return this.backend.get_ecc_corrected_count();
  endfunction

  function int unsigned get_ecc_uncorrectable_count();
    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE) ||
        (this.backend == null)) begin
      return 0;
    end
    return this.backend.get_ecc_uncorrectable_count();
  endfunction

  // ---------------------------------------------------------------------------
  // FR-FCFS starvation-cap forced overrides (§11 item 1): times the cap forced an
  // over-bypassed request ahead of the readiness winner. 0 unless perf counters on.
  // ---------------------------------------------------------------------------
  function int unsigned get_fr_fcfs_forced_count();
    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE) ||
        (this.backend == null)) begin
      return 0;
    end
    return this.backend.get_fr_fcfs_forced_count();
  endfunction

  // ---------------------------------------------------------------------------
  // Issued RD<->WR bus-direction turnarounds (§11 item 1) — the event read/write
  // grouping (cfg.rd_wr_grouping_enable) minimizes. Counted regardless of the knob
  // so a baseline vs grouped run can be compared. 0 unless perf counters on.
  // ---------------------------------------------------------------------------
  function int unsigned get_bus_turnaround_count();
    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE) ||
        (this.backend == null)) begin
      return 0;
    end
    return this.backend.get_bus_turnaround_count();
  endfunction

  // ---------------------------------------------------------------------------
  // Picks where read/write grouping (§11 item 1) served a same-direction candidate
  // over the pure readiness-first winner. 0 unless rd_wr_grouping_enable and perf
  // counters are on.
  // ---------------------------------------------------------------------------
  function int unsigned get_rd_wr_grouped_count();
    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE) ||
        (this.backend == null)) begin
      return 0;
    end
    return this.backend.get_rd_wr_grouped_count();
  endfunction

  // ---------------------------------------------------------------------------
  // Format every telemetry / observability counter into one multi-line string
  // (global scalars + per-registered-port breakdown). Protocol-agnostic — the
  // getters are the same for any front-end — so both the AXI4 and CHI example
  // bases dump telemetry through this one formatter. Returns "" when the config
  // handle is missing; zeros when perf counters are disabled.
  // ---------------------------------------------------------------------------
  function string sprint_telemetry();
    string s;
    int    n_ports;

    if (this.cfg == null) begin
      return "";
    end

    n_ports = (this.backend != null) ? this.backend.get_registered_port_count() : 0;

    s = "\n---------------- vip_mc telemetry ----------------\n";
    s = {s, $sformatf("  refresh_count           = %0d\n", this.get_refresh_count())};
    s = {s, $sformatf("  cmd_queue_peak_depth    = %0d\n", this.get_cmd_queue_peak_depth())};
    s = {s, $sformatf("  row_hit_rate            = %0.4f\n", this.get_row_hit_rate())};
    s = {s, $sformatf("  predict_accuracy_ns     = %0.4f\n", this.get_predict_accuracy())};
    s = {s, $sformatf("  effective_bw_B_per_ns   = %0.4f\n", this.get_effective_bandwidth())};
    s = {s, $sformatf("  bus_utilization         = %0.4f\n", this.get_bus_utilization())};
    s = {s, $sformatf("  observed_reorder_count  = %0d\n", this.get_observed_reorder_count())};
    s = {s, $sformatf("  latency n/min/mean/max ns= %0d / %0.2f / %0.2f / %0.2f\n",
            this.get_latency_sample_count(), this.get_min_latency_ns(),
            this.get_mean_latency_ns(), this.get_max_latency_ns())};
    s = {s, $sformatf("  occupancy_samples       = %0d\n", this.get_occupancy_sample_count())};
    s = {s, $sformatf("  ecc corrected/uncorrect = %0d / %0d\n",
            this.get_ecc_corrected_count(), this.get_ecc_uncorrectable_count())};
    s = {s, $sformatf("  fr_fcfs_forced_count    = %0d\n", this.get_fr_fcfs_forced_count())};
    s = {s, $sformatf("  bus_turnaround_count    = %0d\n", this.get_bus_turnaround_count())};
    s = {s, $sformatf("  rd_wr_grouped_count     = %0d\n", this.get_rd_wr_grouped_count())};
    if (this.backend != null) begin
      s = {s, $sformatf("  coalesced_write_count   = %0d\n",
              this.backend.get_coalesced_write_count())};
    end
    for (int p = 0; p < n_ports; p++) begin
      s = {s, $sformatf(
        {"  port %0d: completed=%0d bytes=%0d decerr=%0d 4k=%0d wready_stall=%0d ",
         "rsp_late=%0d exokay=%0d excl_fail=%0d rsp_buf_full=%0d\n"},
        p, this.get_port_completed_count(p), this.get_port_data_bytes(p),
        this.get_decerr_count(p), this.get_4k_violation_count(p),
        this.get_wready_stall_cycles(p), this.get_rsp_late_count(p),
        this.get_exokay_count(p), this.get_excl_fail_count(p),
        this.get_rsp_buf_full_cycles(p))};
    end
    s = {s, "--------------------------------------------------"};
    return s;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the front-end DECERR count for one AXI4 port.
  // ---------------------------------------------------------------------------
  function int get_decerr_count(input int port_id = 0);
    vip_mc_axi4_driver #(AXI4_CFG_C, DRAM_CFG_P) axi4_fe;

    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE)) begin
      return 0;
    end
    if ((port_id < 0) || (port_id >= $size(this.fes))) begin
      return 0;
    end
    if (!$cast(axi4_fe, this.fes[port_id])) begin
      return 0;
    end
    return axi4_fe.get_decerr_count();
  endfunction

  // ---------------------------------------------------------------------------
  // Return the front-end 4 KB violation count for one AXI4 port.
  // ---------------------------------------------------------------------------
  function int get_4k_violation_count(input int port_id = 0);
    vip_mc_axi4_driver #(AXI4_CFG_C, DRAM_CFG_P) axi4_fe;

    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE)) begin
      return 0;
    end
    if ((port_id < 0) || (port_id >= $size(this.fes))) begin
      return 0;
    end
    if (!$cast(axi4_fe, this.fes[port_id])) begin
      return 0;
    end
    return axi4_fe.get_4k_violation_count();
  endfunction

  // ---------------------------------------------------------------------------
  // Return the front-end WREADY stall-cycle count for one AXI4 port.
  // ---------------------------------------------------------------------------
  function int get_wready_stall_cycles(input int port_id = 0);
    vip_mc_axi4_driver #(AXI4_CFG_C, DRAM_CFG_P) axi4_fe;

    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE)) begin
      return 0;
    end
    if ((port_id < 0) || (port_id >= $size(this.fes))) begin
      return 0;
    end
    if (!$cast(axi4_fe, this.fes[port_id])) begin
      return 0;
    end
    return axi4_fe.get_wready_stall_cycles();
  endfunction

  // ---------------------------------------------------------------------------
  // Return the front-end late-response count for one AXI4 port (§5.4 / §8.8).
  // ---------------------------------------------------------------------------
  function int get_rsp_late_count(input int port_id = 0);
    vip_mc_axi4_driver #(AXI4_CFG_C, DRAM_CFG_P) axi4_fe;

    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE)) begin
      return 0;
    end
    if ((port_id < 0) || (port_id >= $size(this.fes))) begin
      return 0;
    end
    if (!$cast(axi4_fe, this.fes[port_id])) begin
      return 0;
    end
    return axi4_fe.get_rsp_late_count();
  endfunction

  // ---------------------------------------------------------------------------
  // Return the number of exclusive responses that completed with EXOKAY.
  // ---------------------------------------------------------------------------
  function int get_exokay_count(input int port_id = 0);
    vip_mc_axi4_driver #(AXI4_CFG_C, DRAM_CFG_P) axi4_fe;

    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE)) begin
      return 0;
    end
    if ((port_id < 0) || (port_id >= $size(this.fes))) begin
      return 0;
    end
    if (!$cast(axi4_fe, this.fes[port_id])) begin
      return 0;
    end
    return axi4_fe.get_exokay_count();
  endfunction

  // ---------------------------------------------------------------------------
  // Return the number of exclusive writes that failed their reservation check.
  // ---------------------------------------------------------------------------
  function int get_excl_fail_count(input int port_id = 0);
    vip_mc_axi4_driver #(AXI4_CFG_C, DRAM_CFG_P) axi4_fe;

    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE)) begin
      return 0;
    end
    if ((port_id < 0) || (port_id >= $size(this.fes))) begin
      return 0;
    end
    if (!$cast(axi4_fe, this.fes[port_id])) begin
      return 0;
    end
    return axi4_fe.get_excl_fail_count();
  endfunction

  // ---------------------------------------------------------------------------
  // Return the front-end response-buffer-full cycle count for one AXI4 port.
  // ---------------------------------------------------------------------------
  function int get_rsp_buf_full_cycles(input int port_id = 0);
    vip_mc_axi4_driver #(AXI4_CFG_C, DRAM_CFG_P) axi4_fe;

    if ((this.cfg == null) || (this.cfg.perf_counters_enabled == FALSE)) begin
      return 0;
    end
    if ((port_id < 0) || (port_id >= $size(this.fes))) begin
      return 0;
    end
    if (!$cast(axi4_fe, this.fes[port_id])) begin
      return 0;
    end
    return axi4_fe.get_rsp_buf_full_cycles();
  endfunction

  // ---------------------------------------------------------------------------
  // Enforce the supported topology: any mix of AXI4 and CHI ports, but each
  // protocol homogeneous across its ports (§2.1). CHI ports require the opt-in
  // VIP_MC_ENABLE_CHI compile path (CHI decision 7).
  // ---------------------------------------------------------------------------
  protected function void require_supported_ports();
    if (N_PORTS < 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "vip_mc requires at least one host port (N_PORTS=%0d)",
        N_PORTS))
    end

    for (int port_id = 0; port_id < N_PORTS; port_id++) begin
      case (PORTS[port_id].proto)
        VIP_MC_PROTO_AXI4_E: begin
          if (PORTS[port_id].axi4 != AXI4_CFG_C) begin
            `uvm_fatal(get_name(), $sformatf(
              "vip_mc requires homogeneous AXI4 cfg across ports (port %0d differs)",
              port_id))
          end
        end
        VIP_MC_PROTO_CHI_E: begin
`ifdef VIP_MC_ENABLE_CHI
          if (PORTS[port_id].chi != CHI_CFG_C) begin
            `uvm_fatal(get_name(), $sformatf(
              "vip_mc requires homogeneous CHI cfg across ports (port %0d differs)",
              port_id))
          end
`else
          `uvm_fatal(get_name(), $sformatf(
            "CHI port %0d requires compiling vip_mc with +define+VIP_MC_ENABLE_CHI",
            port_id))
`endif
        end
        default: begin
          `uvm_fatal(get_name(), $sformatf(
            "vip_mc port %0d has an unsupported protocol (%s)",
            port_id, PORTS[port_id].proto.name()))
        end
      endcase
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Resolve cfg/dram from env_cfg first, then from discrete config keys.
  // ---------------------------------------------------------------------------
  protected function void resolve_config_and_handles(
    output vip_mc_env_cfg #(DRAM_CFG_P, N_PORTS, PORTS) env_cfg,
    output bit                                          cfg_was_default_created
  );
    env_cfg = null;
    cfg_was_default_created = 1'b0;

    if (uvm_config_db #(vip_mc_env_cfg #(DRAM_CFG_P, N_PORTS, PORTS))::get(
      this,
      "",
      "env_cfg",
      env_cfg
    )) begin
      this.cfg        = env_cfg.cfg;
      this.dram       = env_cfg.dram;
      this.status_vif = env_cfg.status_vif;
      return;
    end

    if (!uvm_config_db #(vip_mc_config)::get(this, "", "config", this.cfg)) begin
      this.cfg = vip_mc_config::type_id::create("cfg");
      cfg_was_default_created = 1'b1;
    end

    if (!uvm_config_db #(vip_dram #(DRAM_CFG_P))::get(this, "", "dram", this.dram)) begin
      `uvm_fatal(get_name(), "vip_mc requires a vip_dram handle under key 'dram'")
    end

    void'(uvm_config_db #(virtual vip_mc_status_if #(N_PORTS))::get(
      this,
      "",
      "status_vif",
      this.status_vif));
  endfunction

  // ---------------------------------------------------------------------------
  // Resolve one homogeneous AXI4 vif from env_cfg or the discrete config path.
  // ---------------------------------------------------------------------------
  protected function void resolve_axi4_vif(
    input  int                                          port_id,
    input  vip_mc_env_cfg #(DRAM_CFG_P, N_PORTS, PORTS) env_cfg,
    output virtual vip_mc_axi4_if #(AXI4_CFG_C)     port_vif
  );
    vip_mc_axi4_vif_holder #(AXI4_CFG_C) port_holder;

    port_vif = null;

    if (env_cfg != null) begin
      if (!$cast(port_holder, env_cfg.vif_h[port_id])) begin
        `uvm_fatal(get_name(), $sformatf(
          "env_cfg.vif_h[%0d] is not an AXI4 vif holder",
          port_id))
      end

      port_vif = port_holder.vif;
      return;
    end

    if (!uvm_config_db #(virtual vip_mc_axi4_if #(AXI4_CFG_C))::get(
      this,
      "",
      this.cfg.ports[port_id].vif_key,
      port_vif
    )) begin
      `uvm_fatal(get_name(), $sformatf(
        "vip_mc requires AXI4 port %0d vif under key '%s'",
        port_id,
        this.cfg.ports[port_id].vif_key))
    end
  endfunction

`ifdef VIP_MC_ENABLE_CHI
  // ---------------------------------------------------------------------------
  // Resolve one homogeneous CHI vif from env_cfg or the discrete config path.
  // ---------------------------------------------------------------------------
  protected function void resolve_chi_vif(
    input  int                                          port_id,
    input  vip_mc_env_cfg #(DRAM_CFG_P, N_PORTS, PORTS) env_cfg,
    output virtual vip_mc_chi_if #(CHI_CFG_C)           port_vif
  );
    vip_mc_chi_vif_holder #(CHI_CFG_C) port_holder;

    port_vif = null;

    if (env_cfg != null) begin
      if (!$cast(port_holder, env_cfg.vif_h[port_id])) begin
        `uvm_fatal(get_name(), $sformatf(
          "env_cfg.vif_h[%0d] is not a CHI vif holder", port_id))
      end
      port_vif = port_holder.vif;
      return;
    end

    if (!uvm_config_db #(virtual vip_mc_chi_if #(CHI_CFG_C))::get(
      this,
      "",
      this.cfg.ports[port_id].vif_key,
      port_vif
    )) begin
      `uvm_fatal(get_name(), $sformatf(
        "vip_mc requires CHI port %0d vif under key '%s'",
        port_id, this.cfg.ports[port_id].vif_key))
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Build, bind, and register one CHI front-end for the given port.
  // ---------------------------------------------------------------------------
  protected function void build_chi_frontend(
    input int                                          port_id,
    input vip_mc_env_cfg #(DRAM_CFG_P, N_PORTS, PORTS) env_cfg
  );
    vip_mc_chi_driver #(CHI_CFG_C, DRAM_CFG_P) fe;
    virtual vip_mc_chi_if #(CHI_CFG_C)         port_vif;

    this.resolve_chi_vif(port_id, env_cfg, port_vif);

    fe = vip_mc_chi_driver #(CHI_CFG_C, DRAM_CFG_P)::type_id::create(
      $sformatf("fe%0d", port_id),
      this);
    fe.mc_cfg  = this.cfg;
    fe.chi_cfg = this.cfg.chi;
    fe.vif     = port_vif;
    fe.port_id = port_id;

    this.fes[port_id] = fe;
    this.backend.register_port(port_id, fe);
  endfunction
`endif

  // ---------------------------------------------------------------------------
  // Build, bind, and register one AXI4 front-end for the given port.
  // ---------------------------------------------------------------------------
  protected function void build_axi4_frontend(
    input int                                          port_id,
    input vip_mc_env_cfg #(DRAM_CFG_P, N_PORTS, PORTS) env_cfg
  );
    vip_mc_axi4_driver #(AXI4_CFG_C, DRAM_CFG_P) fe;
    virtual vip_mc_axi4_if #(AXI4_CFG_C)         port_vif;

    this.resolve_axi4_vif(port_id, env_cfg, port_vif);

    fe = vip_mc_axi4_driver #(AXI4_CFG_C, DRAM_CFG_P)::type_id::create(
      $sformatf("fe%0d", port_id),
      this);
    fe.cfg     = this.cfg.axi4;
    fe.mc_cfg  = this.cfg;
    fe.vif     = port_vif;
    fe.port_id = port_id;

    this.fes[port_id] = fe;
    this.backend.register_port(port_id, fe);
  endfunction

  // ---------------------------------------------------------------------------
  // Build every front-end, dispatching each port to its protocol adapter. The
  // back-end holds them uniformly as vip_mc_fe_base handles, so everything
  // downstream of the FE is protocol-agnostic (§2.1).
  // ---------------------------------------------------------------------------
  protected function void build_frontends(
    input vip_mc_env_cfg #(DRAM_CFG_P, N_PORTS, PORTS) env_cfg
  );
    for (int port_id = 0; port_id < N_PORTS; port_id++) begin
      if (PORTS[port_id].proto == VIP_MC_PROTO_AXI4_E) begin
        this.build_axi4_frontend(port_id, env_cfg);
      end
`ifdef VIP_MC_ENABLE_CHI
      else if (PORTS[port_id].proto == VIP_MC_PROTO_CHI_E) begin
        this.build_chi_frontend(port_id, env_cfg);
      end
`endif
      else begin
        `uvm_fatal(get_name(), $sformatf(
          "vip_mc port %0d protocol not buildable in this compile", port_id))
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Optional waveform-status publisher (§8.8A). Sample live controller state
  // on the canonical controller clock, update one software snapshot, and mirror
  // it onto the physical interface from this single owner.
  // ---------------------------------------------------------------------------
  protected task run_status_publisher(
    input virtual vip_mc_axi4_if #(AXI4_CFG_C) reset_vif
  );
    forever begin
      @(posedge reset_vif.clk);
      this.update_status_snapshot(reset_vif);
      this.drive_status_vif();
      this.status_snapshot.clear_pulses();
    end
  endtask

  // ---------------------------------------------------------------------------
  // Refresh the software snapshot from the currently visible runtime state.
  // ---------------------------------------------------------------------------
  protected function void update_status_snapshot(
    input virtual vip_mc_axi4_if #(AXI4_CFG_C) reset_vif
  );
    int unsigned current_refresh_count;

    this.status_snapshot.rst_active                = (reset_vif.rst_n !== 1'b1);
    this.status_snapshot.cmd_queue_depth           = this.backend.get_cmd_queue_depth();
    this.status_snapshot.cmd_queue_peak_depth      = this.get_cmd_queue_peak_depth();
    this.status_snapshot.inflight_to_device        = this.backend.get_inflight_to_device();
    this.status_snapshot.device_issue_credit_avail = this.backend.get_device_issue_credit_avail();
    this.status_snapshot.backend_stall_reason      = this.status_snapshot.rst_active
                                                  ? VIP_MC_STATUS_STALL_IN_RESET_E
                                                  : this.backend.get_status_stall_reason();
    this.status_snapshot.refresh_count             = this.get_refresh_count();

    this.update_status_per_port_levels();
    this.update_status_rsp_buf_summary();
    this.update_status_issue_pulse();
    this.update_status_complete_pulse();
    this.update_status_reject_pulse();

    current_refresh_count = this.status_snapshot.refresh_count;
    if (current_refresh_count != this.last_status_refresh_count) begin
      this.status_snapshot.refresh_emit_pulse = 1'b1;
      if (DRAM_CFG_P.N_RANKS_P > 0) begin
        this.status_snapshot.refresh_emit_rank =
          (current_refresh_count - 1) % DRAM_CFG_P.N_RANKS_P;
      end
      else begin
        this.status_snapshot.refresh_emit_rank = 0;
      end
      this.last_status_refresh_count = current_refresh_count;
    end
    else begin
      this.status_snapshot.refresh_emit_pulse = 1'b0;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Update the controller-wide response-buffer usage summary from the FE ports.
  // ---------------------------------------------------------------------------
  protected function void update_status_rsp_buf_summary();
    int used_slots;
    vip_mc_axi4_driver #(AXI4_CFG_C, DRAM_CFG_P) axi4_fe;

    used_slots = 0;
    foreach (this.fes[port_id]) begin
      if ($cast(axi4_fe, this.fes[port_id])) begin
        used_slots += axi4_fe.get_rsp_slots_used_count();
      end
    end

    this.status_snapshot.rsp_buf_used = used_slots;
    if (this.cfg.rsp_buf_depth > 0) begin
      this.status_snapshot.rsp_buf_full = (used_slots >= this.cfg.rsp_buf_depth);
    end
    else begin
      this.status_snapshot.rsp_buf_full = 1'b0;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Update the per-port FE occupancy and throttle mirrors.
  // ---------------------------------------------------------------------------
  protected function void update_status_per_port_levels();
    vip_mc_axi4_driver #(AXI4_CFG_C, DRAM_CFG_P) axi4_fe;

    foreach (this.fes[port_id]) begin
      if ($cast(axi4_fe, this.fes[port_id])) begin
        this.status_snapshot.rd_outstanding_count[port_id] = axi4_fe.get_rd_outstanding_count();
        this.status_snapshot.wr_outstanding_count[port_id] = axi4_fe.get_wr_outstanding_count();
        this.status_snapshot.aw_pending_depth[port_id]     = axi4_fe.get_aw_pending_depth();
        this.status_snapshot.pending_b_depth[port_id]      = axi4_fe.get_pending_b_depth();
        this.status_snapshot.pending_r_depth[port_id]      = axi4_fe.get_pending_r_depth();
        this.status_snapshot.active_r_slots_used[port_id]  = axi4_fe.get_active_r_slots_used();
        this.status_snapshot.w_data_buf_occupancy[port_id] = axi4_fe.get_w_data_buf_occupancy();
        this.status_snapshot.aw_block_reason[port_id]      = axi4_fe.get_aw_block_reason();
        this.status_snapshot.ar_block_reason[port_id]      = axi4_fe.get_ar_block_reason();
        this.status_snapshot.w_block_reason[port_id]       = axi4_fe.get_w_block_reason();
      end
      else begin
        this.status_snapshot.rd_outstanding_count[port_id] = 0;
        this.status_snapshot.wr_outstanding_count[port_id] = 0;
        this.status_snapshot.aw_pending_depth[port_id]     = 0;
        this.status_snapshot.pending_b_depth[port_id]      = 0;
        this.status_snapshot.pending_r_depth[port_id]      = 0;
        this.status_snapshot.active_r_slots_used[port_id]  = 0;
        this.status_snapshot.w_data_buf_occupancy[port_id] = 0;
        this.status_snapshot.aw_block_reason[port_id]      = VIP_MC_STATUS_FE_BLOCK_NONE_E;
        this.status_snapshot.ar_block_reason[port_id]      = VIP_MC_STATUS_FE_BLOCK_NONE_E;
        this.status_snapshot.w_block_reason[port_id]       = VIP_MC_STATUS_FE_BLOCK_NONE_E;
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Emit an issue pulse when the backend grant counter advances.
  // ---------------------------------------------------------------------------
  protected function void update_status_issue_pulse();
    if (this.backend.issued_req_count != this.last_status_issued_count) begin
      this.status_snapshot.issue_pulse        = 1'b1;
      this.status_snapshot.issue_port_id      = this.backend.last_issued_cmd.port_id;
      this.status_snapshot.issue_tag          = this.backend.last_issued_cmd.tag;
      this.status_snapshot.issue_op           = this.map_status_op(this.backend.last_issued_cmd.op);
      this.status_snapshot.issue_qos_class    = this.backend.last_issued_cmd.qos_class;
      this.status_snapshot.issue_pre_resolved = this.backend.last_issued_cmd.pre_resolved;
      this.last_status_issued_count           = this.backend.issued_req_count;
    end
    else begin
      this.status_snapshot.issue_pulse = 1'b0;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Emit a completion pulse when the backend retires one non-REF command.
  // ---------------------------------------------------------------------------
  protected function void update_status_complete_pulse();
    if (this.backend.completed_cmd_count != this.last_status_completed_count) begin
      this.status_snapshot.complete_pulse        = 1'b1;
      this.status_snapshot.complete_port_id      = this.backend.last_completed_cmd.port_id;
      this.status_snapshot.complete_tag          = this.backend.last_completed_cmd.tag;
      this.status_snapshot.complete_op           = this.map_status_op(this.backend.last_completed_cmd.op);
      this.status_snapshot.complete_resp         = this.map_status_resp(this.backend.last_completed_cmd.resp);
      this.status_snapshot.complete_page         = this.map_status_page(this.backend.last_rsp);
      this.status_snapshot.complete_pre_resolved = this.backend.last_completed_cmd.pre_resolved;
      this.last_status_completed_count           = this.backend.completed_cmd_count;
    end
    else begin
      this.status_snapshot.complete_pulse = 1'b0;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Emit a reject pulse when any AXI4 front-end advances its FE-local reject
  // counter. At most one port is reported per controller edge; a second port
  // that also advanced keeps its stale last-count so it pulses on a later edge
  // rather than being silently dropped.
  // ---------------------------------------------------------------------------
  protected function void update_status_reject_pulse();
    vip_mc_axi4_driver #(AXI4_CFG_C, DRAM_CFG_P) axi4_fe;
    int unsigned current_count;
    bit          pulse_set;

    pulse_set = 1'b0;
    this.status_snapshot.local_reject_pulse   = 1'b0;
    this.status_snapshot.local_reject_port_id = 0;
    this.status_snapshot.local_reject_op      = VIP_MC_STATUS_OP_NONE_E;
    this.status_snapshot.local_reject_reason  = VIP_MC_STATUS_REJECT_NONE_E;

    foreach (this.fes[port_id]) begin
      if ($cast(axi4_fe, this.fes[port_id])) begin
        current_count = axi4_fe.get_local_reject_count();
        if (current_count != this.last_status_reject_count[port_id]) begin
          if (!pulse_set) begin
            this.status_snapshot.local_reject_pulse   = 1'b1;
            this.status_snapshot.local_reject_port_id = port_id;
            this.status_snapshot.local_reject_op      = axi4_fe.get_last_reject_op();
            this.status_snapshot.local_reject_reason  = axi4_fe.get_last_reject_reason();
            pulse_set = 1'b1;
            this.last_status_reject_count[port_id] = current_count;
          end
        end
      end
      else begin
        this.last_status_reject_count[port_id] = 0;
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Mirror the current snapshot onto the optional physical status interface.
  // ---------------------------------------------------------------------------
  protected function void drive_status_vif();
    if (this.status_vif == null) begin
      return;
    end

    this.status_vif.rst_active                = this.status_snapshot.rst_active;
    this.status_vif.cmd_queue_depth           = this.status_snapshot.cmd_queue_depth;
    this.status_vif.cmd_queue_peak_depth      = this.status_snapshot.cmd_queue_peak_depth;
    this.status_vif.inflight_to_device        = this.status_snapshot.inflight_to_device;
    this.status_vif.rsp_buf_used              = this.status_snapshot.rsp_buf_used;
    this.status_vif.rsp_buf_full              = this.status_snapshot.rsp_buf_full;
    this.status_vif.device_issue_credit_avail = this.status_snapshot.device_issue_credit_avail;
    this.status_vif.backend_stall_reason      = this.status_snapshot.backend_stall_reason;
    this.status_vif.refresh_count             = this.status_snapshot.refresh_count;

    this.status_vif.issue_pulse        = this.status_snapshot.issue_pulse;
    this.status_vif.issue_port_id      = this.status_snapshot.issue_port_id;
    this.status_vif.issue_tag          = this.status_snapshot.issue_tag;
    this.status_vif.issue_op           = this.status_snapshot.issue_op;
    this.status_vif.issue_qos_class    = this.status_snapshot.issue_qos_class;
    this.status_vif.issue_pre_resolved = this.status_snapshot.issue_pre_resolved;

    this.status_vif.complete_pulse        = this.status_snapshot.complete_pulse;
    this.status_vif.complete_port_id      = this.status_snapshot.complete_port_id;
    this.status_vif.complete_tag          = this.status_snapshot.complete_tag;
    this.status_vif.complete_op           = this.status_snapshot.complete_op;
    this.status_vif.complete_resp         = this.status_snapshot.complete_resp;
    this.status_vif.complete_page         = this.status_snapshot.complete_page;
    this.status_vif.complete_pre_resolved = this.status_snapshot.complete_pre_resolved;

    this.status_vif.refresh_emit_pulse = this.status_snapshot.refresh_emit_pulse;
    this.status_vif.refresh_emit_rank  = this.status_snapshot.refresh_emit_rank;

    this.status_vif.local_reject_pulse   = this.status_snapshot.local_reject_pulse;
    this.status_vif.local_reject_port_id = this.status_snapshot.local_reject_port_id;
    this.status_vif.local_reject_op      = this.status_snapshot.local_reject_op;
    this.status_vif.local_reject_reason  = this.status_snapshot.local_reject_reason;

    foreach (this.status_snapshot.rd_outstanding_count[port_id]) begin
      this.status_vif.rd_outstanding_count[port_id] = this.status_snapshot.rd_outstanding_count[port_id];
      this.status_vif.wr_outstanding_count[port_id] = this.status_snapshot.wr_outstanding_count[port_id];
      this.status_vif.aw_pending_depth[port_id]     = this.status_snapshot.aw_pending_depth[port_id];
      this.status_vif.pending_b_depth[port_id]      = this.status_snapshot.pending_b_depth[port_id];
      this.status_vif.pending_r_depth[port_id]      = this.status_snapshot.pending_r_depth[port_id];
      this.status_vif.active_r_slots_used[port_id]  = this.status_snapshot.active_r_slots_used[port_id];
      this.status_vif.w_data_buf_occupancy[port_id] = this.status_snapshot.w_data_buf_occupancy[port_id];
      this.status_vif.aw_block_reason[port_id]      = this.status_snapshot.aw_block_reason[port_id];
      this.status_vif.ar_block_reason[port_id]      = this.status_snapshot.ar_block_reason[port_id];
      this.status_vif.w_block_reason[port_id]       = this.status_snapshot.w_block_reason[port_id];
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Map one DRAM op into the status-probe enum space.
  // ---------------------------------------------------------------------------
  protected function vip_mc_status_op_e map_status_op(input vip_dram_op_t op);
    case (op)
      VIP_DRAM_OP_RD_E:  return VIP_MC_STATUS_OP_RD_E;
      VIP_DRAM_OP_WR_E:  return VIP_MC_STATUS_OP_WR_E;
      VIP_DRAM_OP_REF_E: return VIP_MC_STATUS_OP_REF_E;
      default:           return VIP_MC_STATUS_OP_NONE_E;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Map one AXI response code into the status-probe enum space.
  // ---------------------------------------------------------------------------
  protected function vip_mc_status_rsp_e map_status_resp(input logic [1:0] resp);
    case (resp)
      VIP_MC_AXI4_RESP_OKAY_C:   return VIP_MC_STATUS_RSP_OKAY_E;
      VIP_MC_AXI4_RESP_EXOKAY_C: return VIP_MC_STATUS_RSP_EXOKAY_E;
      VIP_MC_AXI4_RESP_SLVERR_C: return VIP_MC_STATUS_RSP_SLVERR_E;
      VIP_MC_AXI4_RESP_DECERR_C: return VIP_MC_STATUS_RSP_DECERR_E;
      default:                   return VIP_MC_STATUS_RSP_NONE_E;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Map one DRAM page classification into the status-probe enum space.
  // ---------------------------------------------------------------------------
  protected function vip_mc_status_page_e map_status_page(
    input vip_dram_rsp #(DRAM_CFG_P) rsp
  );
    if (rsp.was_page_hit) begin
      return VIP_MC_STATUS_PAGE_HIT_E;
    end
    if (rsp.was_page_miss) begin
      return VIP_MC_STATUS_PAGE_MISS_E;
    end
    if (rsp.was_page_empty) begin
      return VIP_MC_STATUS_PAGE_EMPTY_E;
    end
    return VIP_MC_STATUS_PAGE_UNKNOWN_E;
  endfunction

endclass
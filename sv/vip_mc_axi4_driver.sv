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
// vip_mc_axi4_driver
//
// AXI4 front-end for the first executable vip_mc slice. It implements the
// minimal owned-interface behavior needed to prove end-to-end MC activity:
// INCR bursts, including narrow and unaligned cases, are packed into the
// row-granular vip_dram request shape.
// -----------------------------------------------------------------------------
class vip_mc_axi4_driver #(
  vip_mc_axi4_cfg_t AXI4_CFG_P = '{default: '0},
  vip_dram_cfg_t    DRAM_CFG_P = VIP_DRAM_CFG_DEFAULT_C
  ) extends vip_mc_fe_base #(DRAM_CFG_P);

  typedef vip_mc_cmd_entry #(DRAM_CFG_P) cmd_t;
  typedef logic [(8 * AXI4_CFG_P.WDATA_BYTES_P) - 1 : 0] axi_wdata_t;
  typedef logic [AXI4_CFG_P.WDATA_BYTES_P - 1 : 0]       axi_wstrb_t;
  typedef logic [(8 * AXI4_CFG_P.RDATA_BYTES_P) - 1 : 0] axi_rdata_t;

  vip_mc_axi4_cfg                    cfg;
  vip_mc_config                      mc_cfg;
  virtual vip_mc_axi4_if #(AXI4_CFG_P) vif;

  protected cmd_t pending_aw_q[$];
  protected cmd_t pending_b_q[$];
  protected cmd_t pending_r_q[$];
  protected cmd_t active_b;
  protected cmd_t active_r_q[$];
  protected int unsigned active_r_beat_idx_q[$];
  protected int active_r_slot_idx = -1;
  protected int unsigned w_data_buf_occupancy = 0;
  protected int unsigned exclusive_reservations[longint unsigned][longint unsigned];

  cmd_t         last_issued;
  cmd_t         last_completed;
  int unsigned  issued_req_count  = 0;
  int unsigned  complete_count    = 0;
  int unsigned  observed_aw_count = 0;
  int unsigned  observed_w_count  = 0;
  int unsigned  observed_ar_count = 0;
  int unsigned  inflight_rd_count = 0;
  int unsigned  inflight_wr_count = 0;
  int unsigned  decerr_count = 0;
  int unsigned  four_k_violation_count = 0;
  int unsigned  wready_stall_cycles = 0;
  int unsigned  rsp_buf_full_cycles = 0;
  int unsigned  rsp_late_count = 0;
  int unsigned  exokay_count = 0;
  int unsigned  excl_fail_count = 0;

  // FE-local reject telemetry: a monotonically-increasing count of locally
  // resolved rejects plus the op/reason of the most recent one. The optional
  // status probe samples these to publish a per-port reject pulse.
  int unsigned           local_reject_count = 0;
  vip_mc_status_op_e     last_reject_op     = VIP_MC_STATUS_OP_NONE_E;
  vip_mc_status_reject_e last_reject_reason = VIP_MC_STATUS_REJECT_NONE_E;

  // Timestamp of the previous controller_cb edge; used to detect a beat/B that
  // became eligible at an earlier edge but could only be driven later (§5.4
  // late-response accounting).
  protected realtime prev_cb_time = -1.0;

  // Realtime-compare slack (ns) when snapping device ready times to bus edges.
  localparam realtime BEAT_EPS_C = 0.001;

  `uvm_component_param_utils(vip_mc_axi4_driver #(AXI4_CFG_P, DRAM_CFG_P))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Validate the parent-assigned config and virtual interface handles.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    super.build_phase(phase);

    if (this.cfg == null) begin
      `uvm_fatal(get_name(), "AXI4 front-end cfg handle is null")
    end

    if (this.mc_cfg == null) begin
      `uvm_fatal(get_name(), "AXI4 front-end MC cfg handle is null")
    end

    if (this.vif == null) begin
      `uvm_fatal(get_name(), "AXI4 front-end vif handle is null")
    end

    if (this.port_id < 0 || this.port_id >= this.mc_cfg.ports.size()) begin
      `uvm_fatal(get_name(), $sformatf(
        "AXI4 front-end port_id %0d outside mc_cfg.ports[0:%0d]",
        this.port_id, this.mc_cfg.ports.size() - 1))
    end

    // Host bus width may be at most one DRAM row and must divide it evenly, so a
    // beat's byte lanes always sit inside a single row word (multi-beat gather /
    // sub-row scatter). Equal widths are the common case; a narrower bus packs
    // several beats into one row. pack_write_beat / unpack_read_beat keep the AXI
    // bus lane (addr % WDATA) distinct from the DRAM row lane (addr % ROW_BYTES).
    if ((AXI4_CFG_P.WDATA_BYTES_P > DRAM_CFG_P.ROW_BYTES_P) ||
        ((DRAM_CFG_P.ROW_BYTES_P % AXI4_CFG_P.WDATA_BYTES_P) != 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "AXI4 write slice requires WDATA_BYTES_P (%0d) <= and evenly dividing DRAM ROW_BYTES_P (%0d)",
        AXI4_CFG_P.WDATA_BYTES_P, DRAM_CFG_P.ROW_BYTES_P))
    end

    if ((AXI4_CFG_P.RDATA_BYTES_P > DRAM_CFG_P.ROW_BYTES_P) ||
        ((DRAM_CFG_P.ROW_BYTES_P % AXI4_CFG_P.RDATA_BYTES_P) != 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "AXI4 read slice requires RDATA_BYTES_P (%0d) <= and evenly dividing DRAM ROW_BYTES_P (%0d)",
        AXI4_CFG_P.RDATA_BYTES_P, DRAM_CFG_P.ROW_BYTES_P))
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Sample the owned AXI4 interface and drive the aligned burst response paths.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);
    bit w_accepted;
    bit w_burst_completed;

    super.run_phase(phase);

    this.reset_runtime_state();

    forever begin
      @(this.vif.controller_cb);

      if (!this.vif.rst_n) begin
        this.reset_runtime_state();
        continue;
      end

      w_accepted        = this.vif.controller_cb.wvalid && this.vif.wready;
      w_burst_completed = 1'b0;

      if ((this.mc_cfg.perf_counters_enabled == TRUE) &&
          (this.pending_aw_q.size() > 0) &&
          !this.can_accept_w()) begin
        this.wready_stall_cycles++;
      end

      if ((this.mc_cfg.perf_counters_enabled == TRUE) &&
          (this.mc_cfg.rsp_buf_depth > 0) &&
          !this.rsp_buffer_has_credit()) begin
        this.rsp_buf_full_cycles++;
      end

      this.advance_write_rsp_channel();
      this.advance_read_rsp_channel();

      if (this.vif.controller_cb.awvalid && this.vif.awready) begin
        this.capture_aw();
      end
      if (w_accepted) begin
        w_burst_completed = this.capture_w();
      end
      if (this.vif.controller_cb.arvalid && this.vif.arready) begin
        this.capture_ar();
      end

      this.advance_w_data_buffer_model(w_accepted, w_burst_completed);

      this.drive_accept_outputs();

      this.prev_cb_time = $realtime;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Capture one completed backend entry for the owning AXI4 port.
  // ---------------------------------------------------------------------------
  function void complete(input cmd_t entry);
    if ((entry.op == VIP_DRAM_OP_RD_E) && entry.is_exclusive && !entry.pre_resolved) begin
      this.register_exclusive_reservation(entry);
    end

    if ((this.mc_cfg.perf_counters_enabled == TRUE) &&
        entry.is_exclusive &&
        (entry.resp == VIP_MC_AXI4_RESP_EXOKAY_C)) begin
      this.exokay_count++;
    end

    this.last_completed = entry;
    this.complete_count++;

    if (entry.op == VIP_DRAM_OP_RD_E) begin
      this.pending_r_q.push_back(entry);
    end
    else begin
      this.pending_b_q.push_back(entry);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Reset choreography hook (§9): drop all in-flight AXI4 state and drive the
  // owned responder outputs low. Idempotent with the driver's own !rst_n
  // self-reset in run_phase, so calling it from vip_mc::handle_reset at negedge
  // is safe.
  // ---------------------------------------------------------------------------
  function void handle_reset();
    this.reset_runtime_state();
  endfunction

  // ---------------------------------------------------------------------------
  // Reset the owned responder outputs and clear runtime state.
  // ---------------------------------------------------------------------------
  protected function void reset_runtime_state();
    this.pending_aw_q.delete();
    this.pending_b_q.delete();
    this.pending_r_q.delete();
    this.active_r_q.delete();
    this.active_r_beat_idx_q.delete();
    this.active_b         = null;
    this.active_r_slot_idx = -1;
    this.w_data_buf_occupancy = 0;
    this.inflight_rd_count = 0;
    this.inflight_wr_count = 0;
    this.decerr_count = 0;
    this.four_k_violation_count = 0;
    this.wready_stall_cycles = 0;
    this.rsp_buf_full_cycles = 0;
    this.rsp_late_count = 0;
    this.exokay_count = 0;
    this.excl_fail_count = 0;
    this.local_reject_count = 0;
    this.last_reject_op     = VIP_MC_STATUS_OP_NONE_E;
    this.last_reject_reason = VIP_MC_STATUS_REJECT_NONE_E;
    this.prev_cb_time = -1.0;
    this.exclusive_reservations.delete();

    this.vif.awready = 1'b0;
    this.vif.wready  = 1'b0;
    this.vif.bid     = '0;
    this.vif.bresp   = VIP_MC_AXI4_RESP_OKAY_C;
    this.vif.buser   = '0;
    this.vif.bvalid  = 1'b0;
    this.vif.arready = 1'b0;
    this.vif.rid     = '0;
    this.vif.rdata   = '0;
    this.vif.rresp   = VIP_MC_AXI4_RESP_OKAY_C;
    this.vif.rlast   = 1'b0;
    this.vif.ruser   = '0;
    this.vif.rvalid  = 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // Drive AW/W/AR acceptance for the next AXI4 cycle.
  // ---------------------------------------------------------------------------
  protected function void drive_accept_outputs();
    this.vif.controller_cb.awready <= this.can_accept_aw();
    this.vif.controller_cb.wready  <= this.can_accept_w();
    this.vif.controller_cb.arready <= this.can_accept_ar();
  endfunction

  // ---------------------------------------------------------------------------
  // Return the number of DECERR responses this front-end classified.
  // ---------------------------------------------------------------------------
  function int get_decerr_count();
    if (this.mc_cfg.perf_counters_enabled == FALSE) begin
      return 0;
    end
    return this.decerr_count;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the number of 4 KB boundary violations this front-end saw.
  // ---------------------------------------------------------------------------
  function int get_4k_violation_count();
    if (this.mc_cfg.perf_counters_enabled == FALSE) begin
      return 0;
    end
    return this.four_k_violation_count;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the number of cycles WREADY was held low with pending AW work.
  // ---------------------------------------------------------------------------
  function int get_wready_stall_cycles();
    if (this.mc_cfg.perf_counters_enabled == FALSE) begin
      return 0;
    end
    return this.wready_stall_cycles;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the number of B/R responses driven later than their §5.4 ready time
  // (bus busy or backpressured when the target edge arrived).
  // ---------------------------------------------------------------------------
  function int get_rsp_late_count();
    if (this.mc_cfg.perf_counters_enabled == FALSE) begin
      return 0;
    end
    return this.rsp_late_count;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the number of EXOKAY responses on the exclusive path.
  // ---------------------------------------------------------------------------
  function int get_exokay_count();
    if (this.mc_cfg.perf_counters_enabled == FALSE) begin
      return 0;
    end
    return this.exokay_count;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the number of exclusive writes that failed their reservation check.
  // ---------------------------------------------------------------------------
  function int get_excl_fail_count();
    if (this.mc_cfg.perf_counters_enabled == FALSE) begin
      return 0;
    end
    return this.excl_fail_count;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the number of cycles the finite response buffer was fully occupied.
  // ---------------------------------------------------------------------------
  function int get_rsp_buf_full_cycles();
    if (this.mc_cfg.perf_counters_enabled == FALSE) begin
      return 0;
    end
    return this.rsp_buf_full_cycles;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the current number of outstanding read bursts tracked by this port.
  // ---------------------------------------------------------------------------
  function int get_rd_outstanding_count();
    return this.inflight_rd_count + this.pending_r_q.size() + this.active_r_q.size();
  endfunction

  // ---------------------------------------------------------------------------
  // Return the current number of outstanding write bursts tracked by this port.
  // ---------------------------------------------------------------------------
  function int get_wr_outstanding_count();
    int wr_count;

    wr_count = this.inflight_wr_count + this.pending_aw_q.size() + this.pending_b_q.size();
    if (this.active_b != null) begin
      wr_count++;
    end
    return wr_count;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the number of AW bursts still assembling W data.
  // ---------------------------------------------------------------------------
  function int get_aw_pending_depth();
    return this.pending_aw_q.size();
  endfunction

  // ---------------------------------------------------------------------------
  // Return the current queued/active B depth.
  // ---------------------------------------------------------------------------
  function int get_pending_b_depth();
    int pending_b_depth;

    pending_b_depth = this.pending_b_q.size();
    if (this.active_b != null) begin
      pending_b_depth++;
    end
    return pending_b_depth;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the current queued (not yet active) R depth.
  // ---------------------------------------------------------------------------
  function int get_pending_r_depth();
    return this.pending_r_q.size();
  endfunction

  // ---------------------------------------------------------------------------
  // Return the number of active R interleave slots in use.
  // ---------------------------------------------------------------------------
  function int get_active_r_slots_used();
    return this.active_r_q.size();
  endfunction

  // ---------------------------------------------------------------------------
  // Return the current W-data buffer occupancy.
  // ---------------------------------------------------------------------------
  function int get_w_data_buf_occupancy();
    return this.w_data_buf_occupancy;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the current response-slot usage for this port.
  // ---------------------------------------------------------------------------
  function int get_rsp_slots_used_count();
    return this.get_rsp_slots_used();
  endfunction

  // ---------------------------------------------------------------------------
  // Return the current AW throttle reason for this port.
  // ---------------------------------------------------------------------------
  function vip_mc_status_fe_block_e get_aw_block_reason();
    int outstanding_writes;

    if (!this.vif.rst_n) begin
      return VIP_MC_STATUS_FE_BLOCK_IN_RESET_E;
    end

    // Match can_accept_aw() precedence: the shared response buffer is checked
    // before the per-port outstanding/pending limits, so surface it explicitly
    // instead of leaving response-buffer gating to the controller-global stall.
    if (!this.rsp_buffer_has_credit()) begin
      return VIP_MC_STATUS_FE_BLOCK_RSP_BUF_FULL_E;
    end

    outstanding_writes = this.pending_aw_q.size() + this.inflight_wr_count;
    if (!this.limit_allows(outstanding_writes, this.cfg.aw_outstanding_limit)) begin
      return VIP_MC_STATUS_FE_BLOCK_AW_OUTSTANDING_FULL_E;
    end
    if (!this.depth_allows(this.pending_aw_q.size(), this.cfg.aw_pending_depth)) begin
      return VIP_MC_STATUS_FE_BLOCK_AW_PENDING_FULL_E;
    end

    return VIP_MC_STATUS_FE_BLOCK_NONE_E;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the current AR throttle reason for this port.
  // ---------------------------------------------------------------------------
  function vip_mc_status_fe_block_e get_ar_block_reason();
    if (!this.vif.rst_n) begin
      return VIP_MC_STATUS_FE_BLOCK_IN_RESET_E;
    end
    // Match can_accept_ar() precedence: the shared response buffer gates AR
    // acceptance ahead of the per-port outstanding limit.
    if (!this.rsp_buffer_has_credit()) begin
      return VIP_MC_STATUS_FE_BLOCK_RSP_BUF_FULL_E;
    end
    if (!this.limit_allows(this.inflight_rd_count, this.cfg.ar_outstanding_limit)) begin
      return VIP_MC_STATUS_FE_BLOCK_AR_OUTSTANDING_FULL_E;
    end

    return VIP_MC_STATUS_FE_BLOCK_NONE_E;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the running count of FE-local rejects this port has classified.
  // ---------------------------------------------------------------------------
  function int get_local_reject_count();
    return this.local_reject_count;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the op of the most recent FE-local reject.
  // ---------------------------------------------------------------------------
  function vip_mc_status_op_e get_last_reject_op();
    return this.last_reject_op;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the reason of the most recent FE-local reject.
  // ---------------------------------------------------------------------------
  function vip_mc_status_reject_e get_last_reject_reason();
    return this.last_reject_reason;
  endfunction

  // ---------------------------------------------------------------------------
  // Record one FE-local reject (a locally resolved error or exclusive-fail
  // completion that never reaches the backend) so the optional status probe can
  // publish a per-port reject pulse on the next controller edge.
  // ---------------------------------------------------------------------------
  protected function void record_local_reject(
    input vip_mc_status_op_e     op,
    input vip_mc_status_reject_e reason
  );
    this.local_reject_count++;
    this.last_reject_op     = op;
    this.last_reject_reason = reason;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the current W throttle reason for this port.
  // ---------------------------------------------------------------------------
  function vip_mc_status_fe_block_e get_w_block_reason();
    if (!this.vif.rst_n) begin
      return VIP_MC_STATUS_FE_BLOCK_IN_RESET_E;
    end
    if (this.pending_aw_q.size() == 0) begin
      return VIP_MC_STATUS_FE_BLOCK_NO_WRITE_IN_FLIGHT_E;
    end
    if (!this.depth_allows(this.w_data_buf_occupancy, this.cfg.w_data_buf_depth)) begin
      return VIP_MC_STATUS_FE_BLOCK_WBUF_FULL_E;
    end

    return VIP_MC_STATUS_FE_BLOCK_NONE_E;
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether one more AW can be accepted in the current first slice.
  // ---------------------------------------------------------------------------
  protected function bit can_accept_aw();
    int outstanding_writes;

    if (!this.rsp_buffer_has_credit()) begin
      return 1'b0;
    end

    outstanding_writes = this.pending_aw_q.size() + this.inflight_wr_count;
    if (!this.limit_allows(outstanding_writes, this.cfg.aw_outstanding_limit)) begin
      return 1'b0;
    end

    if (!this.depth_allows(this.pending_aw_q.size(), this.cfg.aw_pending_depth)) begin
      return 1'b0;
    end

    return 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether one more AR can be accepted in the current first slice.
  // ---------------------------------------------------------------------------
  protected function bit can_accept_ar();
    if (!this.rsp_buffer_has_credit()) begin
      return 1'b0;
    end

    return this.limit_allows(this.inflight_rd_count, this.cfg.ar_outstanding_limit);
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether one more W beat can be accepted into the bounded ingress
  // model for the oldest pending write burst.
  // ---------------------------------------------------------------------------
  protected function bit can_accept_w();
    if (this.pending_aw_q.size() == 0) begin
      return 1'b0;
    end

    return this.depth_allows(this.w_data_buf_occupancy, this.cfg.w_data_buf_depth);
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether the configured response buffer still has one free slot.
  // ---------------------------------------------------------------------------
  protected function bit rsp_buffer_has_credit();
    if (this.mc_cfg.rsp_buf_depth <= 0) begin
      return 1'b1;
    end

    return (this.get_rsp_slots_used() < this.mc_cfg.rsp_buf_depth);
  endfunction

  // ---------------------------------------------------------------------------
  // Return the number of response slots currently occupied for this port.
  // ---------------------------------------------------------------------------
  protected function int get_rsp_slots_used();
    int used_slots;

    used_slots = this.pending_b_q.size() + this.pending_r_q.size();
    if (this.active_b != null) begin
      used_slots++;
    end
    used_slots += this.active_r_q.size();

    return used_slots;
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether a finite limit still allows one more accepted request.
  // ---------------------------------------------------------------------------
  protected function bit limit_allows(input int current_count, input int limit);
    if (limit <= 0) begin
      return 1'b1;
    end
    return (current_count < limit);
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether a finite queue depth still allows one more entry.
  // ---------------------------------------------------------------------------
  protected function bit depth_allows(input int current_depth, input int max_depth);
    if (max_depth <= 0) begin
      return 1'b1;
    end
    return (current_depth < max_depth);
  endfunction

  // ---------------------------------------------------------------------------
  // Capture one AW beat and queue it until the matching W beat arrives.
  // ---------------------------------------------------------------------------
  protected function void capture_aw();
    cmd_t                  entry;
    int unsigned           beats;
    int unsigned           size_bytes;
    logic [1 : 0]          resp;
    vip_mc_status_reject_e reject_reason;

    this.observed_aw_count++;

    entry = cmd_t::type_id::create($sformatf("aw_cmd_%0d", this.observed_aw_count));
    beats = this.vif.controller_cb.awlen + 1;
    size_bytes = vip_mc_axi4_size_bytes(this.vif.controller_cb.awsize);

    entry.port_id      = this.port_id;
    entry.axi4_id      = this.vif.controller_cb.awid;
    entry.op           = VIP_DRAM_OP_WR_E;
    entry.addr         = this.vif.controller_cb.awaddr;
    entry.axi_beats    = beats;
    entry.axi_size_bytes = size_bytes;
    entry.axi_burst    = this.vif.controller_cb.awburst;
    entry.beats        = this.get_dram_req_beats(
      entry.addr,
      entry.axi_size_bytes,
      entry.axi_beats,
      entry.axi_burst);
    entry.qos          = this.vif.controller_cb.awqos;
    entry.qos_class    = this.cfg.qos_to_class(this.vif.controller_cb.awqos);
    entry.is_exclusive = this.vif.controller_cb.awlock;
    entry.auser        = this.vif.controller_cb.awuser;
    entry.enqueue_time = $realtime;

    resp = this.classify_request(
      this.vif.controller_cb.awaddr,
      size_bytes,
      beats,
      this.vif.controller_cb.awburst,
      reject_reason);
    if (resp != VIP_MC_AXI4_RESP_OKAY_C) begin
      entry.pre_resolved = 1'b1;
      entry.resp         = resp;
      this.record_local_reject(VIP_MC_STATUS_OP_WR_E, reject_reason);
    end
    else if (!this.supports_axi_burst(
      this.vif.awaddr,
      this.vif.awlen,
      this.vif.awsize,
      this.vif.awburst
    )) begin
      entry.pre_resolved = 1'b1;
      entry.resp         = VIP_MC_AXI4_RESP_SLVERR_C;
      this.record_local_reject(
        VIP_MC_STATUS_OP_WR_E, VIP_MC_STATUS_REJECT_UNSUPPORTED_AXI_SHAPE_E);
    end
    else if (this.vif.controller_cb.awlock && !this.supports_exclusive_request(
      this.vif.controller_cb.awaddr,
      size_bytes,
      beats,
      this.vif.controller_cb.awcache
    )) begin
      entry.pre_resolved = 1'b1;
      entry.resp         = VIP_MC_AXI4_RESP_SLVERR_C;
      this.record_local_reject(
        VIP_MC_STATUS_OP_WR_E, VIP_MC_STATUS_REJECT_EXCLUSIVE_FAIL_LOCAL_E);
    end

    if (!entry.pre_resolved) begin
      entry.wdata = new[entry.beats];
      entry.wstrb = new[entry.beats];
      foreach (entry.wdata[i]) begin
        entry.wdata[i] = '0;
      end
      foreach (entry.wstrb[i]) begin
        entry.wstrb[i] = '0;
      end
    end

    this.pending_aw_q.push_back(entry);
  endfunction

  // ---------------------------------------------------------------------------
  // Capture one W beat and complete or issue the matching AW burst entry.
  // ---------------------------------------------------------------------------
  protected function bit capture_w();
    cmd_t entry;
    int   beat_count;

    capture_w = 1'b0;
    this.observed_w_count++;

    if (this.pending_aw_q.size() == 0) begin
      `uvm_error(get_name(), "Observed W handshake with no pending AW entry")
      return capture_w;
    end

    entry = this.pending_aw_q[0];
    entry.wuser = this.vif.controller_cb.wuser;
    entry.captured_w_beats++;
    beat_count = entry.captured_w_beats;

    if (!entry.pre_resolved) begin
      this.pack_write_beat(
        entry,
        beat_count - 1,
        this.vif.controller_cb.wdata,
        this.vif.controller_cb.wstrb);
    end

    if (this.vif.controller_cb.wlast && (beat_count < entry.axi_beats)) begin
      if (!entry.pre_resolved) begin
        this.record_local_reject(
          VIP_MC_STATUS_OP_WR_E, VIP_MC_STATUS_REJECT_SLVERR_LOCAL_E);
      end
      entry.pre_resolved = 1'b1;
      entry.resp         = VIP_MC_AXI4_RESP_SLVERR_C;
      entry.axi_beats    = beat_count;
      entry.beats        = this.get_dram_req_beats(
        entry.addr,
        entry.axi_size_bytes,
        beat_count,
        entry.axi_burst);
    end
    else if (!this.vif.controller_cb.wlast && (beat_count == entry.axi_beats)) begin
      if (!entry.pre_resolved) begin
        this.record_local_reject(
          VIP_MC_STATUS_OP_WR_E, VIP_MC_STATUS_REJECT_SLVERR_LOCAL_E);
      end
      entry.pre_resolved = 1'b1;
      entry.resp         = VIP_MC_AXI4_RESP_SLVERR_C;
    end

    // A write burst ends only when WLAST is seen. Keep absorbing (and, once
    // pre_resolved above, discarding) beats until then — including an over-long
    // burst that already hit axi_beats without WLAST — so its stray beats never
    // spill onto the next AW entry.
    if (!this.vif.controller_cb.wlast) begin
      return capture_w;
    end

    void'(this.pending_aw_q.pop_front());

    if (!entry.pre_resolved) begin
      if (entry.is_exclusive) begin
        if (!this.check_and_clear_exclusive_reservation(entry)) begin
          entry.pre_resolved = 1'b1;
          entry.resp         = VIP_MC_AXI4_RESP_OKAY_C;
          if (this.mc_cfg.perf_counters_enabled == TRUE) begin
            this.excl_fail_count++;
          end
          this.record_local_reject(
            VIP_MC_STATUS_OP_WR_E, VIP_MC_STATUS_REJECT_EXCLUSIVE_FAIL_LOCAL_E);
        end
        else begin
          this.invalidate_exclusive_reservations_for_write(entry);
        end
      end
      else begin
        this.invalidate_exclusive_reservations_for_write(entry);
      end
    end

    if (entry.pre_resolved) begin
      entry.completed = 1'b1;
      this.complete(entry);
      capture_w = 1'b1;
      return capture_w;
    end

    this.issue_request(entry);
    capture_w = 1'b1;
    return capture_w;
  endfunction

  // ---------------------------------------------------------------------------
  // Model bounded W-data staging: accepted beats consume one slot until the
  // buffer drains on stall cycles, and the buffer clears when the burst closes.
  // ---------------------------------------------------------------------------
  protected function void advance_w_data_buffer_model(
    input bit w_accepted,
    input bit w_burst_completed
  );
    if (w_burst_completed) begin
      this.w_data_buf_occupancy = 0;
      return;
    end

    if (w_accepted) begin
      this.w_data_buf_occupancy++;
    end
    else if (this.w_data_buf_occupancy > 0) begin
      this.w_data_buf_occupancy--;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Capture one AR beat and either issue it or return an immediate error.
  // ---------------------------------------------------------------------------
  protected function void capture_ar();
    cmd_t                  entry;
    int unsigned           beats;
    int unsigned           size_bytes;
    logic [1 : 0]          resp;
    vip_mc_status_reject_e reject_reason;

    this.observed_ar_count++;

    entry = cmd_t::type_id::create($sformatf("ar_cmd_%0d", this.observed_ar_count));
    beats = this.vif.controller_cb.arlen + 1;
    size_bytes = vip_mc_axi4_size_bytes(this.vif.controller_cb.arsize);

    entry.port_id      = this.port_id;
    entry.axi4_id      = this.vif.controller_cb.arid;
    entry.op           = VIP_DRAM_OP_RD_E;
    entry.addr         = this.vif.controller_cb.araddr;
    entry.axi_beats    = beats;
    entry.axi_size_bytes = size_bytes;
    entry.axi_burst    = this.vif.controller_cb.arburst;
    entry.beats        = this.get_dram_req_beats(
      entry.addr,
      entry.axi_size_bytes,
      entry.axi_beats,
      entry.axi_burst);
    entry.qos          = this.vif.controller_cb.arqos;
    entry.qos_class    = this.cfg.qos_to_class(this.vif.controller_cb.arqos);
    entry.is_exclusive = this.vif.controller_cb.arlock;
    entry.auser        = this.vif.controller_cb.aruser;
    entry.enqueue_time = $realtime;

    resp = this.classify_request(
      this.vif.controller_cb.araddr,
      size_bytes,
      beats,
      this.vif.controller_cb.arburst,
      reject_reason);
    if (resp != VIP_MC_AXI4_RESP_OKAY_C) begin
      entry.pre_resolved = 1'b1;
      entry.resp         = resp;
      this.record_local_reject(VIP_MC_STATUS_OP_RD_E, reject_reason);
    end
    else if (!this.supports_axi_burst(
      this.vif.araddr,
      this.vif.arlen,
      this.vif.arsize,
      this.vif.arburst
    )) begin
      entry.pre_resolved = 1'b1;
      entry.resp         = VIP_MC_AXI4_RESP_SLVERR_C;
      this.record_local_reject(
        VIP_MC_STATUS_OP_RD_E, VIP_MC_STATUS_REJECT_UNSUPPORTED_AXI_SHAPE_E);
    end
    else if (this.vif.controller_cb.arlock && !this.supports_exclusive_request(
      this.vif.controller_cb.araddr,
      size_bytes,
      beats,
      this.vif.controller_cb.arcache
    )) begin
      entry.pre_resolved = 1'b1;
      entry.resp         = VIP_MC_AXI4_RESP_SLVERR_C;
      this.record_local_reject(
        VIP_MC_STATUS_OP_RD_E, VIP_MC_STATUS_REJECT_EXCLUSIVE_FAIL_LOCAL_E);
    end

    if (entry.pre_resolved) begin
      entry.rdata = new[entry.axi_beats];
      foreach (entry.rdata[i]) begin
        entry.rdata[i] = '0;
      end
      entry.completed = 1'b1;
      this.complete(entry);
      return;
    end

    this.issue_request(entry);
  endfunction

  // ---------------------------------------------------------------------------
  // Publish one MC-internal request toward the shared backend.
  // ---------------------------------------------------------------------------
  protected function void issue_request(input cmd_t entry);
    this.last_issued = entry;
    this.issued_req_count++;

    if (entry.op == VIP_DRAM_OP_RD_E) begin
      this.inflight_rd_count++;
    end
    else begin
      this.inflight_wr_count++;
    end

    this.req_port.write(entry);
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether the current first slice supports this AXI4 transfer shape.
  // ---------------------------------------------------------------------------
  protected function bit supports_axi_burst(
    input longint unsigned addr,
    input logic [7 : 0]    axlen,
    input logic [2 : 0]    axsize,
    input logic [1 : 0]    axburst
  );
    int unsigned size_bytes;
    int unsigned beats;

    size_bytes = vip_mc_axi4_size_bytes(axsize);
    beats      = axlen + 1;

    if ((beats < 1) ||
        (size_bytes < 1) ||
        (size_bytes > DRAM_CFG_P.ROW_BYTES_P)) begin
      return 1'b0;
    end

    case (axburst)
      VIP_MC_AXI4_BURST_INCR_C: begin
        return 1'b1;
      end
      VIP_MC_AXI4_BURST_FIXED_C: begin
        return (beats <= 16);
      end
      VIP_MC_AXI4_BURST_WRAP_C: begin
        return this.is_wrap_burst_length_supported(beats) &&
               ((addr % size_bytes) == 0);
      end
      default: begin
        return 1'b0;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether this AXI4 exclusive request satisfies the supported rules.
  // ---------------------------------------------------------------------------
  protected function bit supports_exclusive_request(
    input longint unsigned addr,
    input int unsigned     size_bytes,
    input int unsigned     beats,
    input logic [3 : 0]    axcache
  );
    int unsigned total_bytes;

    if (!this.cfg.exclusive_enabled) begin
      return 1'b0;
    end

    total_bytes = this.get_total_axi_transfer_bytes(size_bytes, beats);
    return this.is_legal_exclusive_granule(total_bytes) &&
           ((addr & (total_bytes - 1)) == 0) &&
           (axcache[3 : 2] == 2'b00);
  endfunction

  // ---------------------------------------------------------------------------
  // Return the total byte count of one AXI transfer.
  // ---------------------------------------------------------------------------
  protected function int unsigned get_total_axi_transfer_bytes(
    input int unsigned size_bytes,
    input int unsigned beats
  );
    return size_bytes * beats;
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether n_bytes is a legal exclusive reservation granule.
  // ---------------------------------------------------------------------------
  protected function bit is_legal_exclusive_granule(input int unsigned n_bytes);
    return (n_bytes >= 1) &&
           (n_bytes <= 128) &&
           ((n_bytes & (n_bytes - 1)) == 0);
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether this AXI4 WRAP burst length is one of the legal values.
  // ---------------------------------------------------------------------------
  protected function bit is_wrap_burst_length_supported(input int unsigned beats);
    return ((beats == 2) ||
            (beats == 4) ||
            (beats == 8) ||
            (beats == 16));
  endfunction

  // ---------------------------------------------------------------------------
  // Return the AXI response for the supplied address/length classification.
  // ---------------------------------------------------------------------------
  protected function logic [1 : 0] classify_request(
    input  longint unsigned       addr,
    input  int unsigned           size_bytes,
    input  int unsigned           beats,
    input  logic [1 : 0]          axburst,
    output vip_mc_status_reject_e reject_reason
  );
    longint unsigned first_addr;
    longint unsigned last_addr;

    reject_reason = VIP_MC_STATUS_REJECT_NONE_E;
    first_addr = this.get_burst_window_first_addr(addr, size_bytes, beats, axburst);
    last_addr = this.last_byte_addr(addr, size_bytes, beats, axburst);
    if (!this.port_owns_range(first_addr, last_addr)) begin
      if (this.mc_cfg.perf_counters_enabled == TRUE) begin
        this.decerr_count++;
      end
      reject_reason = VIP_MC_STATUS_REJECT_DECERR_REGION_E;
      return VIP_MC_AXI4_RESP_DECERR_C;
    end

    if (this.range_hits_decerr(first_addr, last_addr)) begin
      if (this.mc_cfg.perf_counters_enabled == TRUE) begin
        this.decerr_count++;
      end
      reject_reason = VIP_MC_STATUS_REJECT_DECERR_REGION_E;
      return VIP_MC_AXI4_RESP_DECERR_C;
    end

    if (this.crosses_4k_boundary(first_addr, last_addr)) begin
      if (this.mc_cfg.perf_counters_enabled == TRUE) begin
        this.decerr_count++;
        this.four_k_violation_count++;
      end
      reject_reason = VIP_MC_STATUS_REJECT_DECERR_4K_E;
      return VIP_MC_AXI4_RESP_DECERR_C;
    end

    return VIP_MC_AXI4_RESP_OKAY_C;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the lowest byte address covered by the AXI4 burst window.
  // ---------------------------------------------------------------------------
  protected function longint unsigned get_burst_window_first_addr(
    input longint unsigned addr,
    input int unsigned     size_bytes,
    input int unsigned     beats,
    input logic [1 : 0]    axburst
  );
    if (axburst == VIP_MC_AXI4_BURST_WRAP_C) begin
      return this.get_wrap_region_base_addr(addr, size_bytes, beats);
    end

    return addr;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the aligned base address of the AXI4 WRAP region.
  // ---------------------------------------------------------------------------
  protected function longint unsigned get_wrap_region_base_addr(
    input longint unsigned addr,
    input int unsigned     size_bytes,
    input int unsigned     beats
  );
    longint unsigned region_bytes;

    if ((beats == 0) || (size_bytes == 0)) begin
      return addr;
    end

    region_bytes = size_bytes;
    region_bytes = region_bytes * beats;
    return (addr / region_bytes) * region_bytes;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the inclusive last valid byte address of an AXI4 transfer window.
  // ---------------------------------------------------------------------------
  protected function longint unsigned last_byte_addr(
    input longint unsigned addr,
    input int unsigned     size_bytes,
    input int unsigned     beats,
    input logic [1 : 0]    axburst
  );
    longint unsigned total_bytes;
    longint unsigned unaligned_bytes;
    longint unsigned valid_bytes;
    longint unsigned region_bytes;

    if ((beats == 0) || (size_bytes == 0)) begin
      return addr;
    end

    unaligned_bytes = addr % size_bytes;

    if (axburst == VIP_MC_AXI4_BURST_FIXED_C) begin
      valid_bytes = size_bytes - unaligned_bytes;
      if (valid_bytes == 0) begin
        valid_bytes = size_bytes;
      end
      return addr + valid_bytes - 1;
    end

    if (axburst == VIP_MC_AXI4_BURST_WRAP_C) begin
      region_bytes = size_bytes;
      region_bytes = region_bytes * beats;
      return this.get_wrap_region_base_addr(addr, size_bytes, beats) + region_bytes - 1;
    end

    total_bytes = size_bytes;
    total_bytes = total_bytes * beats;
    total_bytes = total_bytes - unaligned_bytes;
    return addr + total_bytes - 1;
  endfunction

  // ---------------------------------------------------------------------------
  // Return how many leading bytes of beat 0 are dropped by an unaligned start.
  // ---------------------------------------------------------------------------
  protected function int unsigned get_axi_unaligned_byte_shift(input cmd_t entry);
    return int'(entry.addr % entry.axi_size_bytes);
  endfunction

  // ---------------------------------------------------------------------------
  // Return the valid-byte count for one AXI beat.
  // ---------------------------------------------------------------------------
  protected function int unsigned get_axi_valid_byte_count(
    input cmd_t         entry,
    input int unsigned  axi_beat_idx
  );
    if ((entry.axi_burst == VIP_MC_AXI4_BURST_FIXED_C) ||
        (axi_beat_idx == 0)) begin
      return entry.axi_size_bytes - this.get_axi_unaligned_byte_shift(entry);
    end
    return entry.axi_size_bytes;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the first valid byte address of one AXI beat.
  // ---------------------------------------------------------------------------
  protected function longint unsigned get_axi_first_valid_byte_addr(
    input cmd_t         entry,
    input int unsigned  axi_beat_idx
  );
    longint unsigned base_addr;
    longint unsigned region_bytes;
    longint unsigned beat_offset;

    if (entry.axi_burst == VIP_MC_AXI4_BURST_FIXED_C) begin
      return entry.addr;
    end

    if (entry.axi_burst == VIP_MC_AXI4_BURST_WRAP_C) begin
      base_addr = this.get_burst_window_first_addr(
        entry.addr,
        entry.axi_size_bytes,
        entry.axi_beats,
        entry.axi_burst);
      region_bytes = entry.axi_size_bytes;
      region_bytes = region_bytes * entry.axi_beats;
      beat_offset  = axi_beat_idx;
      beat_offset  = beat_offset * entry.axi_size_bytes;
      return base_addr + ((entry.addr - base_addr + beat_offset) % region_bytes);
    end

    if (axi_beat_idx == 0) begin
      return entry.addr;
    end

    return entry.addr + (axi_beat_idx * entry.axi_size_bytes) -
           this.get_axi_unaligned_byte_shift(entry);
  endfunction

  // ---------------------------------------------------------------------------
  // Return how many DRAM row words this AXI request touches.
  // ---------------------------------------------------------------------------
  protected function int unsigned get_dram_req_beats(
    input longint unsigned addr,
    input int unsigned     size_bytes,
    input int unsigned     axi_beats,
    input logic [1 : 0]    axburst
  );
    longint unsigned first_addr;
    longint unsigned last_addr;

    if (axi_beats == 0) begin
      return 0;
    end

    if (axburst == VIP_MC_AXI4_BURST_FIXED_C) begin
      return 1;
    end

        first_addr = this.get_burst_window_first_addr(addr, size_bytes, axi_beats, axburst);
    last_addr = this.last_byte_addr(addr, size_bytes, axi_beats, axburst);
    return int'((last_addr / DRAM_CFG_P.ROW_BYTES_P) -
          (first_addr / DRAM_CFG_P.ROW_BYTES_P) + 1);
  endfunction

  // ---------------------------------------------------------------------------
  // Register one successful exclusive read reservation.
  // ---------------------------------------------------------------------------
  protected function void register_exclusive_reservation(input cmd_t entry);
    int unsigned total_bytes;

    total_bytes = this.get_total_axi_transfer_bytes(entry.axi_size_bytes, entry.axi_beats);
    if (!this.is_legal_exclusive_granule(total_bytes)) begin
      return;
    end

    this.exclusive_reservations[entry.addr][entry.axi4_id] = total_bytes;
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether the exclusive write matched a still-valid reservation.
  // Always clears the requester's own reservation if it existed.
  // ---------------------------------------------------------------------------
  protected function bit check_and_clear_exclusive_reservation(input cmd_t entry);
    int unsigned total_bytes;
    bit          ok;

    total_bytes = this.get_total_axi_transfer_bytes(entry.axi_size_bytes, entry.axi_beats);
    ok = this.exclusive_reservations.exists(entry.addr) &&
         this.exclusive_reservations[entry.addr].exists(entry.axi4_id) &&
         (this.exclusive_reservations[entry.addr][entry.axi4_id] == total_bytes);

    if (this.exclusive_reservations.exists(entry.addr) &&
        this.exclusive_reservations[entry.addr].exists(entry.axi4_id)) begin
      this.exclusive_reservations[entry.addr].delete(entry.axi4_id);
      if (this.exclusive_reservations[entry.addr].num() == 0) begin
        this.exclusive_reservations.delete(entry.addr);
      end
    end

    return ok;
  endfunction

  // ---------------------------------------------------------------------------
  // Invalidate every reservation whose granule overlaps this write window.
  // ---------------------------------------------------------------------------
  protected function void invalidate_exclusive_reservations_for_write(input cmd_t entry);
    longint unsigned first_addr;
    longint unsigned last_addr;

    first_addr = this.get_burst_window_first_addr(
      entry.addr,
      entry.axi_size_bytes,
      entry.axi_beats,
      entry.axi_burst);
    last_addr = this.last_byte_addr(
      entry.addr,
      entry.axi_size_bytes,
      entry.axi_beats,
      entry.axi_burst);

    this.invalidate_exclusive_reservations(first_addr, (last_addr - first_addr + 1));
  endfunction

  // ---------------------------------------------------------------------------
  // Invalidate every reservation overlapping the supplied write byte range.
  // ---------------------------------------------------------------------------
  protected function void invalidate_exclusive_reservations(
    input longint unsigned addr,
    input longint unsigned n_bytes
  );
    longint unsigned wr_lo;
    longint unsigned wr_hi;
    longint unsigned victim_base_q[$];
    longint unsigned victim_id_q[$];

    if (n_bytes == 0) begin
      return;
    end

    wr_lo = addr;
    wr_hi = addr + n_bytes - 1;

    foreach (this.exclusive_reservations[base]) begin
      foreach (this.exclusive_reservations[base][id]) begin
        longint unsigned res_lo;
        longint unsigned res_hi;
        int unsigned     res_bytes;

        res_lo    = base;
        res_bytes = this.exclusive_reservations[base][id];
        res_hi    = res_lo + res_bytes - 1;
        if (this.ranges_overlap(wr_lo, wr_hi, res_lo, res_hi)) begin
          victim_base_q.push_back(base);
          victim_id_q.push_back(id);
        end
      end
    end

    foreach (victim_base_q[i]) begin
      if (this.exclusive_reservations.exists(victim_base_q[i]) &&
          this.exclusive_reservations[victim_base_q[i]].exists(victim_id_q[i])) begin
        this.exclusive_reservations[victim_base_q[i]].delete(victim_id_q[i]);
        if (this.exclusive_reservations[victim_base_q[i]].num() == 0) begin
          this.exclusive_reservations.delete(victim_base_q[i]);
        end
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether the two inclusive byte ranges overlap.
  // ---------------------------------------------------------------------------
  protected function bit ranges_overlap(
    input longint unsigned a_lo,
    input longint unsigned a_hi,
    input longint unsigned b_lo,
    input longint unsigned b_hi
  );
    return (a_lo <= b_hi) && (b_lo <= a_hi);
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether one active read stream already uses the supplied ARID.
  // ---------------------------------------------------------------------------
  protected function bit is_read_id_active(input longint unsigned axi4_id);
    foreach (this.active_r_q[i]) begin
      if (this.active_r_q[i].axi4_id == axi4_id) begin
        return 1'b1;
      end
    end

    return 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether pending_r_q[idx] is the oldest queued burst for its ARID.
  // ---------------------------------------------------------------------------
  protected function bit is_pending_r_oldest_for_id(input int idx);
    for (int older_idx = 0; older_idx < idx; older_idx++) begin
      if (this.pending_r_q[older_idx].axi4_id == this.pending_r_q[idx].axi4_id) begin
        return 1'b0;
      end
    end

    return 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Promote the next completed read burst onto the R channel. AXI4 has no
  // read-data interleaving, so at most one burst is active at a time and all of
  // its beats are driven contiguously. Whole-burst reordering across ARIDs still
  // occurs: pending_r_q is filled in device-completion order and we promote the
  // oldest queued burst for its ID once the channel is free.
  // ---------------------------------------------------------------------------
  protected function void fill_active_r_streams();
    if (this.active_r_q.size() >= 1) begin
      return;
    end

    for (int pending_idx = 0; pending_idx < this.pending_r_q.size(); pending_idx++) begin
      if (this.is_read_id_active(this.pending_r_q[pending_idx].axi4_id)) begin
        continue;
      end
      if (!this.is_pending_r_oldest_for_id(pending_idx)) begin
        continue;
      end

      this.active_r_q.push_back(this.pending_r_q[pending_idx]);
      this.active_r_beat_idx_q.push_back(0);
      this.pending_r_q.delete(pending_idx);
      return;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Merge one accepted AXI W beat into the row-granular DRAM payload arrays.
  // ---------------------------------------------------------------------------
  protected function void pack_write_beat(
    input cmd_t         entry,
    input int unsigned  axi_beat_idx,
    input axi_wdata_t   wdata,
    input axi_wstrb_t   wstrb
  );
    longint unsigned burst_base_addr;
    longint unsigned first_valid_addr;
    longint unsigned base_row_idx;
    int unsigned     row_idx;
    int unsigned     row_lane_offset;
    int unsigned     bus_lane_offset;
    int unsigned     valid_bytes;

    burst_base_addr = this.get_burst_window_first_addr(
      entry.addr,
      entry.axi_size_bytes,
      entry.axi_beats,
      entry.axi_burst);
    first_valid_addr = this.get_axi_first_valid_byte_addr(entry, axi_beat_idx);
    valid_bytes      = this.get_axi_valid_byte_count(entry, axi_beat_idx);
    base_row_idx     = burst_base_addr / DRAM_CFG_P.ROW_BYTES_P;
    row_idx          = int'((first_valid_addr / DRAM_CFG_P.ROW_BYTES_P) - base_row_idx);
    // Two distinct lane spaces: the DRAM row lane (addr within the ROW_BYTES-wide
    // row word) and the AXI bus lane (addr within the WDATA_BYTES-wide data bus).
    // They coincide only when WDATA_BYTES == ROW_BYTES.
    row_lane_offset = int'(first_valid_addr % DRAM_CFG_P.ROW_BYTES_P);
    bus_lane_offset = int'(first_valid_addr % AXI4_CFG_P.WDATA_BYTES_P);

    if (row_idx >= entry.wdata.size()) begin
      `uvm_error(get_name(), $sformatf(
        "Computed write row index %0d outside wdata.size=%0d",
        row_idx, entry.wdata.size()))
      return;
    end

    for (int byte_idx = 0; byte_idx < valid_bytes; byte_idx++) begin
      int unsigned row_lane;
      int unsigned bus_lane;

      row_lane = row_lane_offset + byte_idx;
      bus_lane = bus_lane_offset + byte_idx;
      if (row_lane >= DRAM_CFG_P.ROW_BYTES_P) begin
        `uvm_error(get_name(), $sformatf(
          "Computed write row lane %0d outside ROW_BYTES_P=%0d",
          row_lane, DRAM_CFG_P.ROW_BYTES_P))
        return;
      end
      if (bus_lane >= AXI4_CFG_P.WDATA_BYTES_P) begin
        `uvm_error(get_name(), $sformatf(
          "Computed write bus lane %0d outside WDATA_BYTES_P=%0d",
          bus_lane, AXI4_CFG_P.WDATA_BYTES_P))
        return;
      end

      if (wstrb[bus_lane]) begin
        entry.wdata[row_idx][(8 * row_lane) +: 8] = wdata[(8 * bus_lane) +: 8];
        entry.wstrb[row_idx][row_lane]            = 1'b1;
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Slice one AXI R beat back out of the returned DRAM row-granular payload.
  // ---------------------------------------------------------------------------
  protected function axi_rdata_t unpack_read_beat(
    input cmd_t         entry,
    input int unsigned  axi_beat_idx
  );
    axi_rdata_t         beat_rdata;
    longint unsigned    burst_base_addr;
    longint unsigned    first_valid_addr;
    longint unsigned    base_row_idx;
    int unsigned        row_idx;
    int unsigned        row_lane_offset;
    int unsigned        bus_lane_offset;
    int unsigned        valid_bytes;

    beat_rdata       = '0;
    burst_base_addr  = this.get_burst_window_first_addr(
      entry.addr,
      entry.axi_size_bytes,
      entry.axi_beats,
      entry.axi_burst);
    first_valid_addr = this.get_axi_first_valid_byte_addr(entry, axi_beat_idx);
    valid_bytes      = this.get_axi_valid_byte_count(entry, axi_beat_idx);
    base_row_idx     = burst_base_addr / DRAM_CFG_P.ROW_BYTES_P;
    row_idx          = int'((first_valid_addr / DRAM_CFG_P.ROW_BYTES_P) - base_row_idx);
    // DRAM row lane vs AXI read-data bus lane (see pack_write_beat); they coincide
    // only when RDATA_BYTES == ROW_BYTES.
    row_lane_offset  = int'(first_valid_addr % DRAM_CFG_P.ROW_BYTES_P);
    bus_lane_offset  = int'(first_valid_addr % AXI4_CFG_P.RDATA_BYTES_P);

    if (row_idx >= entry.rdata.size()) begin
      `uvm_error(get_name(), $sformatf(
        "Computed read row index %0d outside rdata.size=%0d",
        row_idx, entry.rdata.size()))
      return beat_rdata;
    end

    for (int byte_idx = 0; byte_idx < valid_bytes; byte_idx++) begin
      int unsigned row_lane;
      int unsigned bus_lane;

      row_lane = row_lane_offset + byte_idx;
      bus_lane = bus_lane_offset + byte_idx;
      if (row_lane >= DRAM_CFG_P.ROW_BYTES_P) begin
        `uvm_error(get_name(), $sformatf(
          "Computed read row lane %0d outside ROW_BYTES_P=%0d",
          row_lane, DRAM_CFG_P.ROW_BYTES_P))
        return beat_rdata;
      end
      if (bus_lane >= AXI4_CFG_P.RDATA_BYTES_P) begin
        `uvm_error(get_name(), $sformatf(
          "Computed read bus lane %0d outside RDATA_BYTES_P=%0d",
          bus_lane, AXI4_CFG_P.RDATA_BYTES_P))
        return beat_rdata;
      end

      beat_rdata[(8 * bus_lane) +: 8] = entry.rdata[row_idx][(8 * row_lane) +: 8];
    end

    return beat_rdata;
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether the access crosses the AXI4 4 KB boundary.
  // ---------------------------------------------------------------------------
  protected function bit crosses_4k_boundary(
    input longint unsigned addr,
    input longint unsigned last_addr
  );
    return ((addr / VIP_MC_AXI4_4K_ADDRESS_BOUNDARY_C) !=
            (last_addr / VIP_MC_AXI4_4K_ADDRESS_BOUNDARY_C));
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether this port owns the full requested address window.
  // ---------------------------------------------------------------------------
  protected function bit port_owns_range(
    input longint unsigned addr,
    input longint unsigned last_addr
  );
    if (this.mc_cfg.ports[this.port_id].regions.size() == 0) begin
      return 1'b1;
    end

    foreach (this.mc_cfg.ports[this.port_id].regions[i]) begin
      if ((addr >= this.mc_cfg.ports[this.port_id].regions[i].lo) &&
          (last_addr <= this.mc_cfg.ports[this.port_id].regions[i].hi)) begin
        return 1'b1;
      end
    end

    return 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether the request overlaps any configured DECERR window.
  // ---------------------------------------------------------------------------
  protected function bit range_hits_decerr(
    input longint unsigned addr,
    input longint unsigned last_addr
  );
    foreach (this.cfg.decerr_addr_lo[i]) begin
      if ((addr <= this.cfg.decerr_addr_hi[i]) &&
          (last_addr >= this.cfg.decerr_addr_lo[i])) begin
        return 1'b1;
      end
    end

    return 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // Retire and optionally launch the next write response on B.
  // ---------------------------------------------------------------------------
  protected function void advance_write_rsp_channel();
    if (this.vif.bvalid && this.vif.controller_cb.bready) begin
      if ((this.active_b != null) && !this.active_b.pre_resolved && (this.inflight_wr_count > 0)) begin
        this.inflight_wr_count--;
      end
      this.active_b = null;
      this.clear_b_channel();
    end

    if ((this.active_b == null) && (this.pending_b_q.size() > 0)) begin
      cmd_t head;

      head = this.pending_b_q[0];

      // §5.4: B is driven on the first bus edge at-or-after last_beat_ready_time.
      // A pre_resolved (DECERR) completion has MC-chosen timing and is driven
      // immediately; when beat timing is off, the old immediate launch applies.
      if (!this.mc_cfg.honor_beat_timing || head.pre_resolved ||
          (($realtime + BEAT_EPS_C) >= head.last_beat_ready_time)) begin
        if (this.mc_cfg.honor_beat_timing && !head.pre_resolved &&
            (this.prev_cb_time >= 0.0) &&
            ((this.prev_cb_time + BEAT_EPS_C) >= head.last_beat_ready_time)) begin
          this.rsp_late_count++;
        end

        this.active_b = this.pending_b_q.pop_front();
        this.vif.controller_cb.bid    <= this.active_b.axi4_id[AXI4_CFG_P.AWID_WIDTH_P-1 : 0];
        this.vif.controller_cb.bresp  <= this.active_b.resp;
        this.vif.controller_cb.buser  <= this.active_b.auser[AXI4_CFG_P.BUSER_WIDTH_P-1 : 0];
        this.vif.controller_cb.bvalid <= 1'b1;
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Retire and optionally launch the next read response on R.
  // ---------------------------------------------------------------------------
  protected function void advance_read_rsp_channel();
    if (this.vif.rvalid && this.vif.controller_cb.rready) begin
      if ((this.active_r_slot_idx >= 0) &&
          (this.active_r_slot_idx < this.active_r_q.size())) begin
        if ((this.active_r_beat_idx_q[this.active_r_slot_idx] + 1) >=
            this.active_r_q[this.active_r_slot_idx].axi_beats) begin
          if (!this.active_r_q[this.active_r_slot_idx].pre_resolved &&
              (this.inflight_rd_count > 0)) begin
            this.inflight_rd_count--;
          end
          this.active_r_q.delete(this.active_r_slot_idx);
          this.active_r_beat_idx_q.delete(this.active_r_slot_idx);
        end
        else begin
          this.active_r_beat_idx_q[this.active_r_slot_idx]++;
        end
      end

      this.active_r_slot_idx = -1;
      this.clear_r_channel();
    end
    else if (this.vif.rvalid && !this.vif.controller_cb.rready) begin
      this.fill_active_r_streams();
      return;
    end

    this.fill_active_r_streams();

    if (this.active_r_q.size() == 0) begin
      this.active_r_slot_idx = -1;
      return;
    end

    this.active_r_slot_idx = this.choose_next_ready_r_slot();

    // §5.4: the active stream has not reached its next beat's ready time yet —
    // hold RVALID low until it does (paced inter-beat spacing).
    if (this.active_r_slot_idx < 0) begin
      this.clear_r_channel();
      return;
    end

    this.drive_active_r_beat();
  endfunction

  // ---------------------------------------------------------------------------
  // Choose the active read stream to drive, gated on its current beat having
  // reached its §5.4 ready time. AXI4 has no read-data interleaving, so there is
  // at most one active stream (slot 0).
  // ---------------------------------------------------------------------------
  protected function int choose_next_ready_r_slot();
    if (this.active_r_q.size() == 0) begin
      return -1;
    end

    return this.r_slot_beat_ready(0) ? 0 : -1;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the §5.4 ready time for one R beat of an active read stream. Single-
  // beat reads (and the n_rbeats==1 guard, M10) return first_beat_ready_time;
  // multi-beat reads spread evenly: first + i*(last-first)/(n_rbeats-1).
  // ---------------------------------------------------------------------------
  protected function realtime r_beat_target(input cmd_t entry, input int unsigned beat_idx);
    realtime span;
    realtime step;

    if (entry.axi_beats <= 1) begin
      return entry.first_beat_ready_time;
    end

    span = entry.last_beat_ready_time - entry.first_beat_ready_time;
    step = span / real'(entry.axi_beats - 1);
    return entry.first_beat_ready_time + (real'(beat_idx) * step);
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether one active read stream's current beat has reached its ready
  // time. Pacing is bypassed when beat timing is off or for MC-timed DECERR.
  // ---------------------------------------------------------------------------
  protected function bit r_slot_beat_ready(input int slot);
    cmd_t entry;

    if ((slot < 0) || (slot >= this.active_r_q.size())) begin
      return 1'b0;
    end
    if (!this.mc_cfg.honor_beat_timing) begin
      return 1'b1;
    end

    entry = this.active_r_q[slot];
    if (entry.pre_resolved) begin
      return 1'b1;
    end

    return (($realtime + BEAT_EPS_C) >=
            this.r_beat_target(entry, this.active_r_beat_idx_q[slot]));
  endfunction

  // ---------------------------------------------------------------------------
  // Drive the current beat of the selected active read response.
  // ---------------------------------------------------------------------------
  protected function void drive_active_r_beat();
    cmd_t       active_entry;
    axi_rdata_t rdata;
    int unsigned beat_idx;

    if ((this.active_r_slot_idx < 0) ||
        (this.active_r_slot_idx >= this.active_r_q.size())) begin
      this.clear_r_channel();
      return;
    end

    active_entry = this.active_r_q[this.active_r_slot_idx];
    beat_idx     = this.active_r_beat_idx_q[this.active_r_slot_idx];

    // §5.4 late-response accounting: beat[0] is driven once per read; if a prior
    // bus edge had already reached first_beat_ready_time the response was held
    // off (bus busy / backpressured) and is counted late.
    if (this.mc_cfg.honor_beat_timing && !active_entry.pre_resolved &&
        (beat_idx == 0) && (this.prev_cb_time >= 0.0) &&
        ((this.prev_cb_time + BEAT_EPS_C) >= active_entry.first_beat_ready_time)) begin
      this.rsp_late_count++;
    end

    rdata = '0;
    if (!active_entry.pre_resolved) begin
      rdata = this.unpack_read_beat(active_entry, beat_idx);
    end
    else if (active_entry.rdata.size() > beat_idx) begin
      rdata = active_entry.rdata[beat_idx];
    end

    `uvm_info(get_name(), $sformatf(
      "drive R beat[%0d/%0d] id=0x%0h at %0t (first=%0t last=%0t target=%0t)",
      beat_idx, active_entry.axi_beats, active_entry.axi4_id, $realtime,
      active_entry.first_beat_ready_time, active_entry.last_beat_ready_time,
      this.r_beat_target(active_entry, beat_idx)), UVM_HIGH)

    this.vif.controller_cb.rid    <= active_entry.axi4_id[AXI4_CFG_P.ARID_WIDTH_P-1 : 0];
    this.vif.controller_cb.rdata  <= rdata;
    this.vif.controller_cb.rresp  <= active_entry.resp;
    this.vif.controller_cb.rlast  <= ((beat_idx + 1) == active_entry.axi_beats);
    this.vif.controller_cb.ruser  <= active_entry.auser[AXI4_CFG_P.RUSER_WIDTH_P-1 : 0];
    this.vif.controller_cb.rvalid <= 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Clear the B-channel outputs.
  // ---------------------------------------------------------------------------
  protected function void clear_b_channel();
    this.vif.controller_cb.bid    <= '0;
    this.vif.controller_cb.bresp  <= VIP_MC_AXI4_RESP_OKAY_C;
    this.vif.controller_cb.buser  <= '0;
    this.vif.controller_cb.bvalid <= 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // Clear the R-channel outputs.
  // ---------------------------------------------------------------------------
  protected function void clear_r_channel();
    this.vif.controller_cb.rid    <= '0;
    this.vif.controller_cb.rdata  <= '0;
    this.vif.controller_cb.rresp  <= VIP_MC_AXI4_RESP_OKAY_C;
    this.vif.controller_cb.rlast  <= 1'b0;
    this.vif.controller_cb.ruser  <= '0;
    this.vif.controller_cb.rvalid <= 1'b0;
  endfunction

endclass
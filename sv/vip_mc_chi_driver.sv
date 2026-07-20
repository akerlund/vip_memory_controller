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
// vip_mc_chi_driver
//
// CHI SN (memory-target) front-end for vip_mc. It implements the controller-side
// CHI subordinate protocol directly against vip_mc's own vip_mc_chi_if, reusing
// vip_chi_driver_snf's flit-handling as ALGORITHMS (lifted and re-implemented,
// never imported/instantiated -- CHI decision 5). Unlike vip_chi_driver_snf,
// which owns a vip_mem, this front-end converts each REQ into a neutral
// vip_mc_cmd_entry, feeds the shared protocol-agnostic backend (which drives
// vip_dram and predicts timing), and paces the CHI completion flits
// (Comp / CompDBIDResp / CompData) onto the bus using the backend's per-request
// ready times -- exactly the §5.4 pacing the AXI4 front-end applies to B/R.
//
// First functional subset (CHI decision 6): link activation, credit exchange,
// ReadNoSnp / ReadNoSnpSep, WriteNoSnp{Full,Ptl,Zero}, Comp / CompDBIDResp /
// DBIDResp / CompData / DataSepResp / ReadReceipt, DECERR + unsupported-op
// rejection. Same source elaborates for CHI-D or CHI-E (CFG_P.issue).
//
// Compiled only on the CHI path (VIP_MC_ENABLE_CHI); see vip_mc_pkg.sv.
// -----------------------------------------------------------------------------
class vip_mc_chi_driver #(
  vip_mc_chi_cfg_t CHI_CFG_P = '{default: '0},
  vip_dram_cfg_t   DRAM_CFG_P = VIP_DRAM_CFG_DEFAULT_C
  ) extends vip_mc_fe_base #(DRAM_CFG_P);

  typedef vip_mc_chi_cmd_entry #(DRAM_CFG_P) chi_cmd_t;

  // Map the thin selector to vip_chi_cfg_t so vip_chi_types derives every width
  // (identical mapping to vip_mc_chi_if).
  localparam vip_chi_cfg_t CHI_CFG_C = '{
    ISSUE_P         : (CHI_CFG_P.issue == VIP_MC_CHI_ISSUE_E_E) ?
                        VIP_CHI_ISSUE_E_E : VIP_CHI_ISSUE_D_E,
    NODE_ID_WIDTH_P : CHI_CFG_P.NODE_ID_WIDTH_P,
    ADDR_WIDTH_P    : CHI_CFG_P.ADDR_WIDTH_P,
    DATA_BYTES_P    : CHI_CFG_P.DATA_BYTES_P,
    DATACHECK_EN_P  : CHI_CFG_P.DATACHECK_EN_P,
    POISON_EN_P     : CHI_CFG_P.POISON_EN_P,
    MPAM_EN_P       : CHI_CFG_P.MPAM_EN_P,
    PARITY_EN_P     : CHI_CFG_P.PARITY_EN_P
  };

  typedef vip_chi_types #(CHI_CFG_C)         flit_types_t;
  typedef flit_types_t::vip_chi_req_flit_t   req_flit_t;
  typedef flit_types_t::vip_chi_rsp_flit_t   rsp_flit_t;
  typedef flit_types_t::vip_chi_dat_flit_t   dat_flit_t;
  typedef flit_types_t::req_opcode_t         req_opcode_t;
  typedef flit_types_t::rsp_opcode_t         rsp_opcode_t;
  typedef flit_types_t::dat_opcode_t         dat_opcode_t;
  typedef flit_types_t::size_t               size_t;
  typedef flit_types_t::node_id_t            node_id_t;
  typedef flit_types_t::txn_id_t             txn_id_t;
  typedef flit_types_t::data_id_t            data_id_t;

  vip_mc_config                      mc_cfg;
  vip_mc_chi_cfg                     chi_cfg;
  virtual vip_mc_chi_if #(CHI_CFG_P) vif;

  // Configured SN node id (from chi_cfg, default 0). Completions echo the
  // requester's addressed tgtid into srcid/HomeNID (see build_rsp_flit /
  // build_dat_flit) so routing stays consistent even in a multi-node topology;
  // this field is retained as the SN's declared identity for introspection.
  int unsigned sn_node_id = 0;

  // CHI runtime knobs (re-implemented locally; NOT vip_chi_cfg_agent). Sourced
  // from the MC-native vip_mc_chi_cfg at build time -- generous defaults here are
  // the fallback if no cfg is attached, so the link never starves.
  int unsigned initial_req_credits = 16;
  int unsigned initial_rsp_credits = 16;
  int unsigned initial_dat_credits = 16;
  bit          split_write_rsp     = 1'b1;  // DBIDResp early + deferred Comp

  // Inbound receive-credit grant pulses queued toward the RN (one pulse/cycle).
  protected int unsigned req_grant_pending = 0;
  protected int unsigned rsp_grant_pending = 0;
  protected int unsigned dat_grant_pending = 0;

  // Outbound send credits granted to us by the RN (rx*lcrdv), spent per flit.
  protected int unsigned rsp_send_credits = 0;
  protected int unsigned dat_send_credits = 0;

  protected bit link_active = 1'b0;

  // Writes awaiting their NCBWrData beats, matched by granted DBID == flit.txnid.
  protected chi_cmd_t wr_await_q[$];

  // Outbound RSP send queue (DBIDResp / Comp / ReadReceipt), paced by ready time.
  protected rsp_flit_t rsp_send_flit_q[$];
  protected realtime   rsp_send_time_q[$];

  // Outbound DAT send queue (CompData / DataSepResp), one beat per element.
  protected dat_flit_t dat_send_flit_q[$];
  protected realtime   dat_send_time_q[$];
  protected bit        dat_send_last_q[$];   // last beat of its data message

  // Telemetry (mirrors the AXI4 front-end's observable set where meaningful).
  int unsigned  observed_req_count = 0;
  int unsigned  issued_req_count   = 0;
  int unsigned  complete_count     = 0;
  int unsigned  decerr_count       = 0;
  int unsigned  unsupported_count  = 0;
  int unsigned  persist_count      = 0;
  int unsigned  read_count         = 0;
  int unsigned  write_count        = 0;
  chi_cmd_t     last_issued;
  chi_cmd_t     last_completed;

  localparam realtime BEAT_EPS_C = 0.001;

  `uvm_component_param_utils(vip_mc_chi_driver #(CHI_CFG_P, DRAM_CFG_P))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Validate the parent-assigned config/vif handles and the width contract.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    super.build_phase(phase);

    if (this.mc_cfg == null) begin
      `uvm_fatal(get_name(), "CHI front-end MC cfg handle is null")
    end
    if (this.vif == null) begin
      `uvm_fatal(get_name(), "CHI front-end vif handle is null")
    end

    // Adopt the MC-native CHI knobs (credits / split-write / node id). Keep the
    // generous member defaults if the top attached no cfg.
    if (this.chi_cfg != null) begin
      this.sn_node_id          = this.chi_cfg.sn_node_id;
      this.initial_req_credits = this.chi_cfg.initial_req_credits;
      this.initial_rsp_credits = this.chi_cfg.initial_rsp_credits;
      this.initial_dat_credits = this.chi_cfg.initial_dat_credits;
      this.split_write_rsp     = this.chi_cfg.split_write_rsp;
    end
    if (this.port_id < 0 || this.port_id >= this.mc_cfg.ports.size()) begin
      `uvm_fatal(get_name(), $sformatf(
        "CHI front-end port_id %0d outside mc_cfg.ports[0:%0d]",
        this.port_id, this.mc_cfg.ports.size() - 1))
    end
    // A CHI DAT flit may be at most one DRAM row and must divide it evenly, so a
    // beat's bytes always sit inside a single row word. Equal widths are the 1:1
    // common case; a narrower DAT width gathers several beats into one row word
    // (pack_chi_write_beat / read slice keep the DAT beat lane distinct from the
    // DRAM row lane).
    if ((CHI_CFG_P.DATA_BYTES_P > DRAM_CFG_P.ROW_BYTES_P) ||
        ((DRAM_CFG_P.ROW_BYTES_P % CHI_CFG_P.DATA_BYTES_P) != 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "CHI slice requires DATA_BYTES_P (%0d) <= and evenly dividing DRAM ROW_BYTES_P (%0d)",
        CHI_CFG_P.DATA_BYTES_P, DRAM_CFG_P.ROW_BYTES_P))
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Single per-cycle SN state machine (synchronous to controller_cb), mirroring
  // the AXI4 front-end's single-loop style: receive REQ/write-DAT, exchange
  // credits, and pace outbound RSP/DAT completions in one place. complete() only
  // enqueues, so the backend's async completion is drained here on the next edge.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);
    super.run_phase(phase);

    this.reset_runtime_state();

    forever begin
      @(this.vif.controller_cb);

      if (!this.vif.rst_n) begin
        this.reset_runtime_state();
        continue;
      end

      // Link activation: mirror rxlinkactivereq onto txlinkactiveack; once the
      // RN raises its request, advertise the initial receive-credit budgets.
      this.vif.controller_cb.txlinkactiveack <= this.vif.controller_cb.rxlinkactivereq;
      if (!this.link_active) begin
        if (this.vif.controller_cb.rxlinkactivereq) begin
          this.link_active = 1'b1;
          this.schedule_initial_credit_grants();
        end
      end

      // Absorb outbound send-credit grants from the RN.
      if (this.vif.controller_cb.rxrsplcrdv) begin
        this.rsp_send_credits++;
      end
      if (this.vif.controller_cb.rxdatlcrdv) begin
        this.dat_send_credits++;
      end

      // Consume one inbound REQ, if any.
      if (this.link_active && this.vif.controller_cb.rxreqflitv) begin
        this.handle_req(this.vif.controller_cb.rxreqflit);
        this.req_grant_pending++;   // return the consumed REQ credit
      end

      // Consume one inbound write-data (or CompAck-bearing RSP) flit, if any.
      if (this.link_active && this.vif.controller_cb.rxdatflitv) begin
        this.handle_write_data(this.vif.controller_cb.rxdatflit);
        this.dat_grant_pending++;   // return the consumed DAT credit
      end
      if (this.link_active && this.vif.controller_cb.rxrspflitv) begin
        // CompAck / other inbound RSP: consume purely to return the credit. As a
        // passive memory target (like the stock SN-F) we do NOT block on or
        // validate the RN's CompAck against entries that set ExpCompAck; the
        // opcode is not checked here. A missing/malformed CompAck is therefore
        // undetectable at this node -- a deliberate VIP-wide simplification, not a
        // vip_mc regression (C5).
        this.rsp_grant_pending++;
      end

      // Drive one inbound credit-grant pulse per channel this cycle.
      this.drive_credit_grants();

      // Drive one outbound RSP and one outbound DAT beat this cycle (paced).
      this.drive_sends();
    end
  endtask

  // ---------------------------------------------------------------------------
  // Deliver one completed backend entry back to this CHI port and queue the
  // matching completion flits (paced by the backend's ready times).
  // ---------------------------------------------------------------------------
  function void complete(input cmd_t entry);
    chi_cmd_t chi_entry;

    if (!$cast(chi_entry, entry)) begin
      `uvm_error(get_name(), "complete() received a non-CHI cmd entry")
      return;
    end

    this.last_completed = chi_entry;
    this.complete_count++;

    if (chi_entry.op == VIP_DRAM_OP_RD_E) begin
      this.enqueue_read_completion(chi_entry);
    end
    else begin
      this.enqueue_write_completion(chi_entry);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Reset choreography hook (§9): drop all in-flight CHI state and drive the
  // owned tx outputs low. Idempotent with the run_phase !rst_n self-reset.
  // ---------------------------------------------------------------------------
  function void handle_reset();
    this.reset_runtime_state();
  endfunction

  // ---------------------------------------------------------------------------
  // Clear runtime state and drive the owned SN tx outputs to their reset values.
  // ---------------------------------------------------------------------------
  protected function void reset_runtime_state();
    this.wr_await_q.delete();
    this.rsp_send_flit_q.delete();
    this.rsp_send_time_q.delete();
    this.dat_send_flit_q.delete();
    this.dat_send_time_q.delete();
    this.dat_send_last_q.delete();

    this.req_grant_pending = 0;
    this.rsp_grant_pending = 0;
    this.dat_grant_pending = 0;
    this.rsp_send_credits  = 0;
    this.dat_send_credits  = 0;
    this.link_active       = 1'b0;

    this.observed_req_count = 0;
    this.issued_req_count   = 0;
    this.complete_count     = 0;
    this.decerr_count       = 0;
    this.unsupported_count  = 0;
    this.persist_count      = 0;
    this.read_count         = 0;
    this.write_count        = 0;

    this.vif.txlinkactivereq = 1'b0;
    this.vif.txlinkactiveack = 1'b0;
    this.vif.txsactive       = 1'b0;
    this.vif.txreqlcrdv      = 1'b0;
    this.vif.txrsplcrdv      = 1'b0;
    this.vif.txdatlcrdv      = 1'b0;
    this.vif.txreqflitpend   = 1'b0;
    this.vif.txreqflitv      = 1'b0;
    this.vif.txrspflitpend   = 1'b0;
    this.vif.txrspflitv      = 1'b0;
    this.vif.txrspflit       = '0;
    this.vif.txdatflitpend   = 1'b0;
    this.vif.txdatflitv      = 1'b0;
    this.vif.txdatflit       = '0;
  endfunction

  // ---------------------------------------------------------------------------
  // Advertise the initial inbound receive-credit budgets after activation.
  // ---------------------------------------------------------------------------
  protected function void schedule_initial_credit_grants();
    this.req_grant_pending += this.initial_req_credits;
    this.rsp_grant_pending += this.initial_rsp_credits;
    this.dat_grant_pending += this.initial_dat_credits;
  endfunction

  // ---------------------------------------------------------------------------
  // Emit one queued inbound credit pulse per channel this cycle.
  // ---------------------------------------------------------------------------
  protected function void drive_credit_grants();
    this.vif.controller_cb.txreqlcrdv <= (this.req_grant_pending != 0);
    this.vif.controller_cb.txrsplcrdv <= (this.rsp_grant_pending != 0);
    this.vif.controller_cb.txdatlcrdv <= (this.dat_grant_pending != 0);

    if (this.req_grant_pending != 0) begin
      this.req_grant_pending--;
    end
    if (this.rsp_grant_pending != 0) begin
      this.rsp_grant_pending--;
    end
    if (this.dat_grant_pending != 0) begin
      this.dat_grant_pending--;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Decode one inbound REQ flit and start the matching completer flow.
  // ---------------------------------------------------------------------------
  protected function void handle_req(input req_flit_t req);
    logic [6 : 0] op7;

    this.observed_req_count++;
    op7 = req.opcode;

    case (op7)
      VIP_CHI_REQ_READ_NO_SNP_E,
      VIP_CHI_REQ_READ_NO_SNP_SEP_E: begin
        this.handle_read_req(req, (op7 == VIP_CHI_REQ_READ_NO_SNP_SEP_E));
      end
      VIP_CHI_REQ_WRITE_NO_SNP_FULL_E,
      VIP_CHI_REQ_WRITE_NO_SNP_PTL_E: begin
        this.handle_write_req(req);
      end
      VIP_CHI_REQ_WRITE_NO_SNP_ZERO_E: begin
        this.handle_write_zero_req(req);
      end
      VIP_CHI_REQ_CLEAN_SHARED_PERSIST_E,
      VIP_CHI_REQ_CLEAN_SHARED_PERSIST_SEP_E: begin
        this.handle_persist_req(req, (op7 == VIP_CHI_REQ_CLEAN_SHARED_PERSIST_SEP_E));
      end
      default: begin
        this.handle_unsupported_req(req);
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Build the common CHI request context onto a fresh entry.
  // ---------------------------------------------------------------------------
  protected function chi_cmd_t new_entry_from_req(input req_flit_t req, input vip_dram_op_t op);
    chi_cmd_t entry;

    entry = chi_cmd_t::type_id::create($sformatf("chi_cmd_%0d", this.observed_req_count));
    entry.port_id      = this.port_id;
    entry.op           = op;
    entry.addr         = req.addr;
    entry.axi4_id      = req.txnid;          // generic id field carries TxnID
    // `beats` is the DRAM-row-granular count the backend stores/issues; the CHI
    // link may present more (narrower) DAT beats that gather into those rows.
    entry.beats        = vip_chi_types_pkg::chi_xfer_dat_beats(
                           size_t'(req.size), DRAM_CFG_P.ROW_BYTES_P);
    entry.chi_dat_beats = vip_chi_types_pkg::chi_xfer_dat_beats(
                           size_t'(req.size), CHI_CFG_P.DATA_BYTES_P);
    entry.chi_size_bytes = vip_chi_types_pkg::chi_size_bytes(size_t'(req.size));
    entry.qos          = req.qos;
    entry.qos_class    = this.mc_cfg.axi4.qos_to_class(req.qos);
    entry.enqueue_time = $realtime;

    entry.chi_srcid    = req.srcid;
    entry.chi_tgtid    = req.tgtid;
    entry.chi_txnid    = req.txnid;
    entry.chi_dbid     = req.txnid;          // grant DBID == requester TxnID
    entry.chi_qos      = req.qos;
    entry.chi_exp_comp_ack = req.expcompack;
    return entry;
  endfunction

  // ---------------------------------------------------------------------------
  // ReadNoSnp / ReadNoSnpSep: issue a RD to the backend (or complete locally on
  // DECERR); ordered reads get a ReadReceipt queued up front.
  // ---------------------------------------------------------------------------
  protected function void handle_read_req(input req_flit_t req, input bit is_sep);
    chi_cmd_t entry;

    entry = this.new_entry_from_req(req, VIP_DRAM_OP_RD_E);
    entry.chi_is_sep_read = is_sep;
    if (is_sep) begin
      entry.chi_return_nid = req.returnnid;
      entry.chi_return_txn = req.returntxnid;
    end
    // Ordered reads acknowledge request receipt before data.
    entry.chi_needs_receipt = this.req_has_ordering(req);
    if (entry.chi_needs_receipt) begin
      this.queue_read_receipt(entry);
    end

    if (this.classify_decerr(entry)) begin
      entry.chi_resp_err = VIP_CHI_RESP_ERR_NONDATA_ERROR_E;
      this.enqueue_read_completion(entry);   // local DECERR completion, no device
      return;
    end

    this.read_count++;
    this.issue_request(entry);
  endfunction

  // ---------------------------------------------------------------------------
  // WriteNoSnp{Full,Ptl}: send the DBID grant now, collect NCBWrData beats, then
  // issue the WR to the backend when the last beat lands.
  // ---------------------------------------------------------------------------
  protected function void handle_write_req(input req_flit_t req);
    chi_cmd_t entry;

    entry = this.new_entry_from_req(req, VIP_DRAM_OP_WR_E);
    entry.chi_is_write        = 1'b1;
    entry.chi_split_write_rsp = this.split_write_rsp;

    entry.wdata = new[entry.beats];
    entry.wstrb = new[entry.beats];
    foreach (entry.wdata[i]) entry.wdata[i] = '0;
    foreach (entry.wstrb[i]) entry.wstrb[i] = '0;

    if (this.classify_decerr(entry)) begin
      entry.chi_resp_err = VIP_CHI_RESP_ERR_NONDATA_ERROR_E;
    end

    // Grant the write buffer: DBIDResp (split) or CompDBIDResp (combined). Even
    // on DECERR the RN must be given a DBID to release its write data.
    this.queue_write_grant(entry);

    // Await the data beats keyed by the granted DBID.
    this.wr_await_q.push_back(entry);
  endfunction

  // ---------------------------------------------------------------------------
  // WriteNoSnpZero: no data phase. Issue a full-strobe zero write (or classify
  // DECERR) and complete with Comp.
  // ---------------------------------------------------------------------------
  protected function void handle_write_zero_req(input req_flit_t req);
    chi_cmd_t entry;

    entry = this.new_entry_from_req(req, VIP_DRAM_OP_WR_E);
    entry.chi_is_write        = 1'b1;
    entry.chi_is_write_zero   = 1'b1;
    entry.chi_split_write_rsp = 1'b1;         // no combined grant makes sense

    entry.wdata = new[entry.beats];
    entry.wstrb = new[entry.beats];
    foreach (entry.wdata[i]) entry.wdata[i] = '0;
    foreach (entry.wstrb[i]) entry.wstrb[i] = '1;   // full strobe = write zeros

    if (this.classify_decerr(entry)) begin
      entry.chi_resp_err = VIP_CHI_RESP_ERR_NONDATA_ERROR_E;
      this.enqueue_write_completion(entry);   // local Comp(NONDATA_ERROR)
      return;
    end

    this.write_count++;
    this.issue_request(entry);
  endfunction

  // ---------------------------------------------------------------------------
  // Unsupported opcode: best-effort defined rejection with Comp(NONDATA_ERROR).
  // ---------------------------------------------------------------------------
  protected function void handle_unsupported_req(input req_flit_t req);
    chi_cmd_t entry;

    this.unsupported_count++;
    `uvm_warning(get_name(), $sformatf(
      "Unsupported CHI REQ opcode 0x%0h (txnid=0x%0h) -> Comp(NONDATA_ERROR)",
      req.opcode, req.txnid))

    entry = this.new_entry_from_req(req, VIP_DRAM_OP_WR_E);
    entry.chi_is_write        = 1'b1;
    entry.chi_split_write_rsp = 1'b1;   // no prior grant -> standalone Comp
    entry.chi_resp_err        = VIP_CHI_RESP_ERR_NONDATA_ERROR_E;
    this.enqueue_write_completion(entry);
  endfunction

  // ---------------------------------------------------------------------------
  // CleanSharedPersist{,Sep}: a persist-to-memory CMO. For an SN memory target
  // the data is already at the point of persistence, so there is no device access
  // and no data phase -- the SN simply acknowledges. Non-separated form returns a
  // single Comp; the separated form returns Persist followed by CompPersist (the
  // two-part completion the stock vip_chi RN-I manager expects for PersistSep).
  // ---------------------------------------------------------------------------
  protected function void handle_persist_req(input req_flit_t req, input bit is_sep);
    chi_cmd_t  entry;
    rsp_flit_t f;

    this.persist_count++;

    // Entry is used only for response routing (srcid/txnid/qos); no device issue.
    entry = this.new_entry_from_req(req, VIP_DRAM_OP_RD_E);
    entry.chi_resp_err = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;

    if (is_sep) begin
      f = this.build_rsp_flit(entry, VIP_CHI_RSP_PERSIST_E);
      this.push_rsp(f, $realtime);
      f = this.build_rsp_flit(entry, VIP_CHI_RSP_COMP_PERSIST_E);
      this.push_rsp(f, $realtime);
    end
    else begin
      f = this.build_rsp_flit(entry, VIP_CHI_RSP_COMP_E);
      this.push_rsp(f, $realtime);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Consume one inbound write-data beat and match it to its awaiting write.
  // ---------------------------------------------------------------------------
  protected function void handle_write_data(input dat_flit_t dat);
    chi_cmd_t entry;
    int       match_idx;

    match_idx = -1;
    foreach (this.wr_await_q[i]) begin
      if (this.wr_await_q[i].chi_dbid == longint'(dat.txnid)) begin
        match_idx = i;
        break;
      end
    end

    if (match_idx < 0) begin
      `uvm_error(get_name(), $sformatf(
        "Write DAT beat with unmatched txnid/dbid 0x%0h", dat.txnid))
      return;
    end

    entry = this.wr_await_q[match_idx];

    if (entry.chi_wr_beats_seen < entry.chi_dat_beats) begin
      this.pack_chi_write_beat(entry, entry.chi_wr_beats_seen, dat.data, dat.be);
    end
    entry.chi_wr_beats_seen++;

    if (entry.chi_wr_beats_seen < entry.chi_dat_beats) begin
      return;   // more beats to come
    end

    this.wr_await_q.delete(match_idx);

    if (entry.chi_resp_err == VIP_CHI_RESP_ERR_NONDATA_ERROR_E) begin
      // DECERR write: data drained, do not touch the device; complete locally.
      this.enqueue_write_completion(entry);
      return;
    end

    this.write_count++;
    this.issue_request(entry);
  endfunction

  // ---------------------------------------------------------------------------
  // Publish one MC-internal request toward the shared backend.
  // ---------------------------------------------------------------------------
  protected function void issue_request(input chi_cmd_t entry);
    this.last_issued = entry;
    this.issued_req_count++;
    this.req_port.write(entry);
  endfunction

  // ---------------------------------------------------------------------------
  // Map one CHI DAT beat to the DRAM row word it lives in and the byte lane it
  // starts at within that row. A DATA_BYTES_P-wide beat sits at a DATA_BYTES_P-
  // aligned sub-block of a ROW_BYTES_P row, so several narrower beats gather into
  // one row word. row_lane_offset == 0 (beat == row) when DATA_BYTES_P ==
  // ROW_BYTES_P, preserving the 1:1 behavior.
  // ---------------------------------------------------------------------------
  protected function void chi_beat_row_map(
    input  chi_cmd_t     entry,
    input  int unsigned  dat_beat_idx,
    output int unsigned  row_idx,
    output int unsigned  row_lane_offset
  );
    longint unsigned base_data_addr;
    longint unsigned beat_base;
    longint unsigned base_row;

    base_data_addr  = entry.addr - (entry.addr % CHI_CFG_P.DATA_BYTES_P);
    beat_base       = base_data_addr + (dat_beat_idx * CHI_CFG_P.DATA_BYTES_P);
    base_row        = entry.addr / DRAM_CFG_P.ROW_BYTES_P;
    row_idx         = int'((beat_base / DRAM_CFG_P.ROW_BYTES_P) - base_row);
    row_lane_offset = int'(beat_base % DRAM_CFG_P.ROW_BYTES_P);
  endfunction

  // ---------------------------------------------------------------------------
  // Merge one inbound write DAT beat into the row-granular payload at its row
  // lane, honoring the per-byte enables (the CHI counterpart of the AXI4 front-
  // end's pack_write_beat).
  // ---------------------------------------------------------------------------
  protected function void pack_chi_write_beat(
    input chi_cmd_t                                    entry,
    input int unsigned                                 dat_beat_idx,
    input logic [(8 * CHI_CFG_P.DATA_BYTES_P) - 1 : 0] data,
    input logic [CHI_CFG_P.DATA_BYTES_P - 1 : 0]       be
  );
    int unsigned row_idx;
    int unsigned row_lane_offset;

    this.chi_beat_row_map(entry, dat_beat_idx, row_idx, row_lane_offset);

    if (row_idx >= entry.wdata.size()) begin
      `uvm_error(get_name(), $sformatf(
        "CHI write DAT beat %0d -> row %0d outside wdata.size=%0d",
        dat_beat_idx, row_idx, entry.wdata.size()))
      return;
    end

    for (int k = 0; k < CHI_CFG_P.DATA_BYTES_P; k++) begin
      int unsigned row_lane;

      row_lane = row_lane_offset + k;
      if (row_lane >= DRAM_CFG_P.ROW_BYTES_P) begin
        `uvm_error(get_name(), $sformatf(
          "CHI write row lane %0d outside ROW_BYTES_P=%0d",
          row_lane, DRAM_CFG_P.ROW_BYTES_P))
        return;
      end
      if (be[k]) begin
        entry.wdata[row_idx][(8 * row_lane) +: 8] = data[(8 * k) +: 8];
        entry.wstrb[row_idx][row_lane]            = 1'b1;
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether the request carries ordering (needs a ReadReceipt).
  // ---------------------------------------------------------------------------
  protected function bit req_has_ordering(input req_flit_t req);
    return (req.order != VIP_CHI_ORDER_NONE_E);
  endfunction

  // ---------------------------------------------------------------------------
  // Classify a decode error against this port's owned regions and the DECERR
  // window map (mirrors the AXI4 front-end's region/DECERR checks).
  // ---------------------------------------------------------------------------
  protected function bit classify_decerr(input chi_cmd_t entry);
    longint unsigned first_addr;
    longint unsigned last_addr;
    int unsigned     total_bytes;

    // Byte-accurate span: use the exact transfer size (1 << req.size), not the
    // row-rounded beat count, so a sub-row access is not spuriously widened to a
    // full ROW_BYTES window (which could falsely cross into a neighbouring DECERR
    // window or past a region hi). Matches the AXI4 front-end's byte-accurate
    // last_byte_addr.
    total_bytes = (entry.chi_size_bytes == 0) ? 1 : entry.chi_size_bytes;
    first_addr = entry.addr;
    last_addr  = entry.addr + total_bytes - 1;

    if (!this.port_owns_range(first_addr, last_addr) ||
        this.range_hits_decerr(first_addr, last_addr)) begin
      if (this.mc_cfg.perf_counters_enabled == TRUE) begin
        this.decerr_count++;
      end
      return 1'b1;
    end
    return 1'b0;
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
    foreach (this.mc_cfg.axi4.decerr_addr_lo[i]) begin
      if ((addr <= this.mc_cfg.axi4.decerr_addr_hi[i]) &&
          (last_addr >= this.mc_cfg.axi4.decerr_addr_lo[i])) begin
        return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // Queue the write grant flit: DBIDResp (split, deferred Comp) or CompDBIDResp
  // (combined completion). Ready immediately -- the RN needs the DBID to send
  // its write data.
  // ---------------------------------------------------------------------------
  protected function void queue_write_grant(input chi_cmd_t entry);
    rsp_flit_t f;
    logic [4 : 0] grant_op;

    grant_op = entry.chi_split_write_rsp ? VIP_CHI_RSP_DBID_RESP_E
                                         : VIP_CHI_RSP_COMP_DBID_RESP_E;
    f = this.build_rsp_flit(entry, grant_op);
    this.push_rsp(f, $realtime);
  endfunction

  // ---------------------------------------------------------------------------
  // Queue a ReadReceipt for an ordered read (ready immediately).
  // ---------------------------------------------------------------------------
  protected function void queue_read_receipt(input chi_cmd_t entry);
    rsp_flit_t f;

    f = this.build_rsp_flit(entry, VIP_CHI_RSP_READ_RECEIPT_E);
    this.push_rsp(f, $realtime);
  endfunction

  // ---------------------------------------------------------------------------
  // On backend completion of a read, queue the CompData / DataSepResp beats,
  // paced first..last (mirrors the AXI4 R-beat pacing, §5.4).
  // ---------------------------------------------------------------------------
  protected function void enqueue_read_completion(input chi_cmd_t entry);
    dat_flit_t   f;
    rsp_flit_t   rf;
    logic [3 : 0] dat_op;
    int unsigned n_beats;
    realtime     target;

    dat_op  = entry.chi_is_sep_read ? VIP_CHI_DAT_DATA_SEP_RESP_E
                                    : VIP_CHI_DAT_COMP_DATA_E;
    n_beats = entry.chi_dat_beats;   // link DAT beats (may exceed the row count)
    if (n_beats == 0) begin
      n_beats = 1;
    end

    // A separated read (ReadNoSnpSep) splits its completion into two legs: the
    // response leg RespSepData on RSP -- returned to the requester (SrcID /
    // request TxnID, which build_rsp_flit already sets) -- ahead of the
    // DataSepResp data leg on DAT (routed to ReturnNID / ReturnTxnID, see
    // build_dat_flit). Emit the RSP leg here; the requester
    // (vip_chi_driver_rni::collect_resp_sep_data) blocks on it before collecting
    // the data beats, so omitting it hangs the read. A non-separated read returns
    // CompData on DAT only and needs no RSP leg.
    if (entry.chi_is_sep_read) begin
      rf = this.build_rsp_flit(entry, VIP_CHI_RSP_RESP_SEP_DATA_E);
      this.push_rsp(rf, this.beat_target(entry, 0, n_beats));
    end

    for (int i = 0; i < n_beats; i++) begin
      f = this.build_dat_flit(entry, dat_op, i);
      target = this.beat_target(entry, i, n_beats);
      this.push_dat(f, target, (i == (n_beats - 1)));
    end
  endfunction

  // ---------------------------------------------------------------------------
  // On backend completion of a write, queue the deferred Comp (split path) at
  // last_beat_ready_time. Combined CompDBIDResp already completed, so a device-
  // routed combined write only retires here.
  // ---------------------------------------------------------------------------
  protected function void enqueue_write_completion(input chi_cmd_t entry);
    rsp_flit_t f;
    realtime   target;

    // A combined write (chi_split_write_rsp == 0) already retired its host-visible
    // completion via the CompDBIDResp grant, so it must NEVER emit a second Comp
    // here -- gate on the grant invariant itself, not on pre_resolved. Only the
    // split path (deferred Comp) and a pre_resolved fast-path entry fall through.
    if (!entry.chi_split_write_rsp) begin
      if (entry.pre_resolved) begin
        `uvm_error(get_name(), $sformatf(
          "combined write (txnid=0x%0h) reached enqueue_write_completion pre_resolved -- CompDBIDResp already sent, refusing to double-complete",
          entry.chi_txnid))
      end
      return;   // combined write: completion already sent via CompDBIDResp
    end

    f      = this.build_rsp_flit(entry, VIP_CHI_RSP_COMP_E);
    target = entry.pre_resolved ? $realtime : entry.last_beat_ready_time;
    if (!this.mc_cfg.honor_beat_timing) begin
      target = $realtime;
    end
    this.push_rsp(f, target);
  endfunction

  // ---------------------------------------------------------------------------
  // Build a RSP flit for one entry with the supplied opcode.
  // ---------------------------------------------------------------------------
  protected function rsp_flit_t build_rsp_flit(input chi_cmd_t entry, input logic [4 : 0] opcode);
    rsp_flit_t f;

    f          = '0;
    f.opcode   = rsp_opcode_t'(opcode);
    f.tgtid    = node_id_t'(entry.chi_srcid);   // back to the requester
    f.srcid    = node_id_t'(entry.chi_tgtid);   // echo the requester's target id
    f.txnid    = txn_id_t'(entry.chi_txnid);
    f.dbid     = txn_id_t'(entry.chi_dbid);
    f.resp     = VIP_CHI_RESP_STATE_I_E;
    f.resperr  = vip_chi_resp_err_t'(entry.chi_resp_err);
    f.qos      = entry.chi_qos[3 : 0];
    return f;
  endfunction

  // ---------------------------------------------------------------------------
  // Build one CompData / DataSepResp beat for a completed read.
  // ---------------------------------------------------------------------------
  protected function dat_flit_t build_dat_flit(
    input chi_cmd_t     entry,
    input logic [3 : 0] opcode,
    input int unsigned  beat_idx
  );
    dat_flit_t       f;
    longint unsigned rsp_txnid;
    longint unsigned rsp_tgtid;

    rsp_txnid = entry.chi_is_sep_read ? entry.chi_return_txn : entry.chi_txnid;
    rsp_tgtid = entry.chi_is_sep_read ? entry.chi_return_nid : entry.chi_srcid;

    f          = '0;
    f.opcode   = dat_opcode_t'(opcode);
    f.tgtid    = node_id_t'(rsp_tgtid);
    f.srcid    = node_id_t'(entry.chi_tgtid);   // echo the requester's target id
    f.homenid  = node_id_t'(entry.chi_tgtid);
    f.txnid    = txn_id_t'(rsp_txnid);
    f.dbid     = txn_id_t'(rsp_txnid);
    f.dataid   = data_id_t'(beat_idx);
    f.resp     = VIP_CHI_RESP_STATE_I_E;
    f.resperr  = vip_chi_resp_err_t'(entry.chi_resp_err);
    f.qos      = entry.chi_qos[3 : 0];

    if (entry.chi_resp_err == VIP_CHI_RESP_ERR_NONDATA_ERROR_E) begin
      f.data = '0;
      f.be   = '0;
    end
    else begin
      int unsigned row_idx;
      int unsigned row_lane_offset;

      this.chi_beat_row_map(entry, beat_idx, row_idx, row_lane_offset);
      f.data = '0;
      f.be   = '1;
      if (row_idx < entry.rdata.size()) begin
        // Slice this DAT beat's DATA_BYTES out of its row word at the row lane
        // (row lane == bus lane only when DATA_BYTES_P == ROW_BYTES_P).
        for (int k = 0; k < CHI_CFG_P.DATA_BYTES_P; k++) begin
          f.data[(8 * k) +: 8] = entry.rdata[row_idx][(8 * (row_lane_offset + k)) +: 8];
        end
      end
    end
    return f;
  endfunction

  // ---------------------------------------------------------------------------
  // §5.4-style ready time for read beat i: single-beat returns first; multi-beat
  // spreads first..last evenly.
  // ---------------------------------------------------------------------------
  protected function realtime beat_target(
    input chi_cmd_t    entry,
    input int unsigned beat_idx,
    input int unsigned n_beats
  );
    realtime span;
    realtime step;

    if (entry.pre_resolved) begin
      return $realtime;
    end
    if (n_beats <= 1) begin
      return entry.first_beat_ready_time;
    end
    span = entry.last_beat_ready_time - entry.first_beat_ready_time;
    step = span / real'(n_beats - 1);
    return entry.first_beat_ready_time + (real'(beat_idx) * step);
  endfunction

  // ---------------------------------------------------------------------------
  // Enqueue helpers for the paced outbound flit queues.
  // ---------------------------------------------------------------------------
  protected function void push_rsp(input rsp_flit_t f, input realtime ready_time);
    this.rsp_send_flit_q.push_back(f);
    this.rsp_send_time_q.push_back(ready_time);
  endfunction

  protected function void push_dat(input dat_flit_t f, input realtime ready_time, input bit is_last);
    this.dat_send_flit_q.push_back(f);
    this.dat_send_time_q.push_back(ready_time);
    this.dat_send_last_q.push_back(is_last);
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether a queued flit whose head ready time is `t` may be driven now.
  // ---------------------------------------------------------------------------
  protected function bit send_time_reached(input realtime t);
    if (!this.mc_cfg.honor_beat_timing) begin
      return 1'b1;
    end
    return (($realtime + BEAT_EPS_C) >= t);
  endfunction

  // ---------------------------------------------------------------------------
  // Drive at most one RSP and one DAT beat this cycle, subject to send credits
  // and per-flit ready-time pacing. RSP and DAT are independent channels.
  // ---------------------------------------------------------------------------
  protected function void drive_sends();
    bit sending;
    bit sending_resp_sep;

    sending          = 1'b0;
    sending_resp_sep = 1'b0;

    // Response channel.
    if ((this.rsp_send_flit_q.size() > 0) &&
        (this.rsp_send_credits > 0) &&
        this.send_time_reached(this.rsp_send_time_q[0])) begin
      rsp_flit_t f;
      f = this.rsp_send_flit_q.pop_front();
      void'(this.rsp_send_time_q.pop_front());
      this.rsp_send_credits--;
      this.vif.controller_cb.txrspflit    <= f;
      this.vif.controller_cb.txrspflitpend <= 1'b0;
      this.vif.controller_cb.txrspflitv   <= 1'b1;
      sending = 1'b1;
      // A separated read's RespSepData response leg is going out this cycle.
      if (rsp_opcode_t'(f.opcode) == rsp_opcode_t'(VIP_CHI_RSP_RESP_SEP_DATA_E)) begin
        sending_resp_sep = 1'b1;
      end
    end
    else begin
      this.vif.controller_cb.txrspflitv <= 1'b0;
    end

    // Data channel. Hold a separated read's DataSepResp for one cycle when its
    // RespSepData response leg is driven this same cycle. The requester
    // (vip_chi_driver_rni::collect_resp_sep_data) consumes the RSP leg first and
    // only then begins polling DAT; because both channels drive single-cycle
    // valids, a DataSepResp pulsed in the same cycle as the RespSepData would be
    // missed and the read would stall. Deferring the data leg one cycle
    // guarantees the requester is already waiting on DAT when it is driven.
    // (Assumes the RSP leg is not itself credit-starved in that cycle, which
    // holds for the granted initial RSP credit budget.)
    if ((this.dat_send_flit_q.size() > 0) &&
        (this.dat_send_credits > 0) &&
        this.send_time_reached(this.dat_send_time_q[0]) &&
        !(sending_resp_sep &&
          (dat_opcode_t'(this.dat_send_flit_q[0].opcode) ==
           dat_opcode_t'(VIP_CHI_DAT_DATA_SEP_RESP_E)))) begin
      dat_flit_t f;
      bit        is_last;
      f       = this.dat_send_flit_q.pop_front();
      void'(this.dat_send_time_q.pop_front());
      is_last = this.dat_send_last_q.pop_front();
      this.dat_send_credits--;
      this.vif.controller_cb.txdatflit    <= f;
      this.vif.controller_cb.txdatflitpend <= !is_last;
      this.vif.controller_cb.txdatflitv   <= 1'b1;
      sending = 1'b1;
    end
    else begin
      this.vif.controller_cb.txdatflitv <= 1'b0;
    end

    this.vif.controller_cb.txsactive <= sending;
  endfunction

  // ---------------------------------------------------------------------------
  // Observability accessors.
  // ---------------------------------------------------------------------------
  function int get_decerr_count();
    if (this.mc_cfg.perf_counters_enabled == FALSE) begin
      return 0;
    end
    return this.decerr_count;
  endfunction

  function int get_read_count();
    return this.read_count;
  endfunction

  function int get_write_count();
    return this.write_count;
  endfunction

  function int get_unsupported_count();
    return this.unsupported_count;
  endfunction

  function int get_persist_count();
    return this.persist_count;
  endfunction

endclass

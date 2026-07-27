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
// mc_coverage
//
// Controller-specific functional coverage for the vip_mc example. AXI4 and CHI
// protocol coverage already ship with their agents (vip_axi4_coverage /
// vip_chi_coverage, instantiated alongside this component); what only the
// example can see is how the controller *scheduled* that traffic, so this
// collector covers the decisions rather than the bus.
//
// Three taps:
//   1. backend.issued_port - the grant-ordered vip_mc_cmd_entry stream. Gives
//      the scheduling decision: op, burst shape, QoS class, starvation bypass
//      count, coalesce fan-out, and grant order across ports.
//   2. dram.rsp_port       - the device response. Gives the outcome the entry
//      could not know at grant time: page hit/miss/empty and ECC fault
//      severity. Correlated back to its entry by `tag`.
//   3. manager B/R monitors - host-visible completion responses, crossed with
//      the originating port.
//
// The interesting groups are the crosses. `cx_op_page` answers "did we ever
// serve a write to a closed page?", `cx_qos_page` answers "did a low-priority
// request ever win a page hit?", and cg_turnaround answers "did we exercise
// every bus-direction transition, including the refresh-adjacent ones?" - none
// of which the per-agent protocol coverage can express.
// -----------------------------------------------------------------------------

typedef class mc_coverage;

// -----------------------------------------------------------------------------
// Per-port B-response tap.
// -----------------------------------------------------------------------------
class mc_cov_b_collector extends uvm_subscriber #(vip_axi4_item #(VIP_AXI4_AGENT_CFG_C));
  mc_coverage cov;
  int         port_id = 0;

  `uvm_component_utils(mc_cov_b_collector)

  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  function void write(input vip_axi4_item #(VIP_AXI4_AGENT_CFG_C) t);
    if (this.cov != null) begin
      this.cov.observe_b(this.port_id, t);
    end
  endfunction
endclass

// -----------------------------------------------------------------------------
// Per-port R-response tap.
// -----------------------------------------------------------------------------
class mc_cov_r_collector extends uvm_subscriber #(vip_axi4_item #(VIP_AXI4_AGENT_CFG_C));
  mc_coverage cov;
  int         port_id = 0;

  `uvm_component_utils(mc_cov_r_collector)

  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  function void write(input vip_axi4_item #(VIP_AXI4_AGENT_CFG_C) t);
    if (this.cov != null) begin
      this.cov.observe_r(this.port_id, t);
    end
  endfunction
endclass

`uvm_analysis_imp_decl(_cov_issued)
`uvm_analysis_imp_decl(_cov_dram_rsp)

class mc_coverage extends uvm_component;

  typedef vip_mc_cmd_entry #(DRAM_CFG_C)           cmd_t;
  typedef vip_dram_rsp     #(DRAM_CFG_C)           rsp_t;
  typedef vip_axi4_item    #(VIP_AXI4_AGENT_CFG_C) axi4_item_t;

  vip_dram #(DRAM_CFG_C)                     dram;
  vip_mc   #(DRAM_CFG_C, N_PORTS_C, PORTS_C) u_mc;

  uvm_analysis_imp_cov_issued   #(cmd_t, mc_coverage) issued_export;
  uvm_analysis_imp_cov_dram_rsp #(rsp_t, mc_coverage) dram_rsp_export;
  mc_cov_b_collector                                  b_collector[N_PORTS_C];
  mc_cov_r_collector                                  r_collector[N_PORTS_C];

  // Entries awaiting their device response, keyed by tag, so the response's
  // page-hit / fault outcome can be crossed with the scheduling decision that
  // produced it.
  protected cmd_t inflight[longint unsigned];

  // ---------------------------------------------------------------------------
  // Sampling scratch. SystemVerilog covergroups sample class properties via the
  // no-arg sample(); these hold the current transaction for the duration of one
  // sample call.
  // ---------------------------------------------------------------------------
  protected int unsigned cp_port;
  protected int unsigned cp_op;
  protected int unsigned cp_qos_class;
  protected int unsigned cp_burst;
  protected int unsigned cp_beats;
  protected int unsigned cp_size_bytes;
  protected int unsigned cp_bypass;
  protected int unsigned cp_coalesce;
  protected bit          cp_exclusive;
  protected bit          cp_pre_resolved;
  protected int unsigned cp_rank;
  protected int unsigned cp_bg;
  protected int unsigned cp_bank;
  protected int unsigned cp_page;      // 0 = hit, 1 = miss, 2 = empty
  protected int unsigned cp_fault;
  protected int unsigned cp_resp;
  protected int unsigned cp_prev_op;

  // Grant-order history for the turnaround group.
  protected int unsigned prev_issued_op = 32'hFFFF_FFFF;
  protected int unsigned prev_issued_port = 32'hFFFF_FFFF;
  protected bit          prev_valid = 1'b0;

  protected int unsigned issued_samples   = 0;
  protected int unsigned rsp_samples      = 0;
  protected int unsigned resp_samples     = 0;
  protected int unsigned orphan_responses = 0;

  `uvm_component_utils(mc_coverage)

  // ---------------------------------------------------------------------------
  // Scheduling decision, sampled once per granted backend entry.
  // ---------------------------------------------------------------------------
  covergroup cg_issue;
    option.per_instance = 1;
    option.name         = "cg_issue";

    cp_op_pt: coverpoint cp_op {
      bins rd  = {VIP_DRAM_OP_RD_E};
      bins wr  = {VIP_DRAM_OP_WR_E};
      bins ref_op = {VIP_DRAM_OP_REF_E};
    }

    cp_port_pt: coverpoint cp_port {
      bins ports[] = {[0 : N_PORTS_C - 1]};
    }

    cp_qos_class_pt: coverpoint cp_qos_class {
      bins low    = {0};
      bins mid    = {1};
      bins high   = {2};
      bins other  = {[3 : 15]};
    }

    cp_burst_pt: coverpoint cp_burst {
      bins fixed = {VIP_MC_AXI4_BURST_FIXED_C};
      bins incr  = {VIP_MC_AXI4_BURST_INCR_C};
      bins wrap  = {VIP_MC_AXI4_BURST_WRAP_C};
      ignore_bins reserved = {2'b11};
    }

    // Device-side column accesses per entry. A refresh carries one.
    cp_beats_pt: coverpoint cp_beats {
      bins single = {1};
      bins pair   = {2};
      bins quad   = {[3 : 4]};
      bins mid    = {[5 : 8]};
      bins big    = {[9 : 16]};
      bins huge   = {[17 : $]};
    }

    // FR-FCFS starvation pressure: how many younger readiness-winners this
    // entry was reordered past before it was granted.
    cp_bypass_pt: coverpoint cp_bypass {
      bins none    = {0};
      bins few     = {[1 : 3]};
      bins several = {[4 : 7]};
      bins capped  = {[8 : $]};
    }

    // Write coalescing fan-out: secondaries merged into this primary.
    cp_coalesce_pt: coverpoint cp_coalesce {
      bins none = {0};
      bins one  = {1};
      bins many = {[2 : $]};
    }

    cp_exclusive_pt: coverpoint cp_exclusive {
      bins normal    = {1'b0};
      bins exclusive = {1'b1};
    }

    // A DECERR resolved in the front-end never reaches the device.
    cp_pre_resolved_pt: coverpoint cp_pre_resolved {
      bins scheduled    = {1'b0};
      bins pre_resolved = {1'b1};
    }

    cp_rank_pt: coverpoint cp_rank {
      bins ranks[] = {[0 : DRAM_CFG_C.N_RANKS_P - 1]};
    }

    cp_bg_pt: coverpoint cp_bg {
      bins bgs[] = {[0 : DRAM_CFG_C.N_BANK_GROUPS_P - 1]};
    }

    cp_bank_pt: coverpoint cp_bank {
      bins banks[] = {[0 : DRAM_CFG_C.BANKS_PER_BG_P - 1]};
    }

    // Did every port get to issue both directions?
    cx_port_op:    cross cp_port_pt, cp_op_pt;
    // Did every QoS class actually reach the device, in both directions?
    cx_qos_op:     cross cp_qos_class_pt, cp_op_pt;
    // Burst shape against direction - WRAP writes are the rare corner.
    cx_op_burst:   cross cp_op_pt, cp_burst_pt;
    // Was a starved entry ever force-served in both directions?
    cx_op_bypass:  cross cp_op_pt, cp_bypass_pt;
    // Coalescing only applies to writes; the RD column is an ignore.
    cx_op_coalesce: cross cp_op_pt, cp_coalesce_pt {
      ignore_bins rd_coalesce =
        binsof(cp_op_pt.rd) || binsof(cp_op_pt.ref_op);
    }
  endgroup

  // ---------------------------------------------------------------------------
  // Device outcome, sampled once per DRAM response and joined back to the entry
  // that produced it.
  // ---------------------------------------------------------------------------
  covergroup cg_device;
    option.per_instance = 1;
    option.name         = "cg_device";

    cp_op_pt: coverpoint cp_op {
      bins rd  = {VIP_DRAM_OP_RD_E};
      bins wr  = {VIP_DRAM_OP_WR_E};
      bins ref_op = {VIP_DRAM_OP_REF_E};
    }

    cp_page_pt: coverpoint cp_page {
      bins hit   = {0};
      bins miss  = {1};
      bins empty = {2};
      bins none  = {3};   // refresh - no column access classification
    }

    cp_qos_class_pt: coverpoint cp_qos_class {
      bins low    = {0};
      bins mid    = {1};
      bins high   = {2};
      bins other  = {[3 : 15]};
    }

    cp_bank_pt: coverpoint cp_bank {
      bins banks[] = {[0 : DRAM_CFG_C.BANKS_PER_BG_P - 1]};
    }

    cp_fault_pt: coverpoint cp_fault {
      bins none          = {VIP_DRAM_FAULT_NONE_E};
      bins correctable   = {VIP_DRAM_FAULT_CORRECTABLE_E};
      bins uncorrectable = {VIP_DRAM_FAULT_UNCORRECTABLE_E};
    }

    // The headline scheduling question: reads and writes against every page
    // state. A REF has no page classification, so those cells are ignored.
    cx_op_page: cross cp_op_pt, cp_page_pt {
      ignore_bins ref_pages =
        binsof(cp_op_pt.ref_op) && !binsof(cp_page_pt.none);
      ignore_bins non_ref_none =
        !binsof(cp_op_pt.ref_op) && binsof(cp_page_pt.none);
    }

    // Did a low-priority request ever win a page hit, and did a high-priority
    // one ever eat a miss? That cross is where FR-FCFS-vs-QoS bugs live.
    cx_qos_page: cross cp_qos_class_pt, cp_page_pt {
      ignore_bins no_page = binsof(cp_page_pt.none);
    }

    // ECC severity only classifies on reads.
    cx_op_fault: cross cp_op_pt, cp_fault_pt {
      ignore_bins non_rd_fault =
        !binsof(cp_op_pt.rd) && !binsof(cp_fault_pt.none);
    }
  endgroup

  // ---------------------------------------------------------------------------
  // Bus turnaround: the transition between consecutive granted operations.
  // Read-write grouping and refresh insertion both show up here.
  // ---------------------------------------------------------------------------
  covergroup cg_turnaround;
    option.per_instance = 1;
    option.name         = "cg_turnaround";

    cp_prev_op_pt: coverpoint cp_prev_op {
      bins rd  = {VIP_DRAM_OP_RD_E};
      bins wr  = {VIP_DRAM_OP_WR_E};
      bins ref_op = {VIP_DRAM_OP_REF_E};
    }

    cp_op_pt: coverpoint cp_op {
      bins rd  = {VIP_DRAM_OP_RD_E};
      bins wr  = {VIP_DRAM_OP_WR_E};
      bins ref_op = {VIP_DRAM_OP_REF_E};
    }

    // All nine transitions, including refresh entering and leaving a busy bus.
    cx_turnaround: cross cp_prev_op_pt, cp_op_pt;
  endgroup

  // ---------------------------------------------------------------------------
  // Host-visible completion, sampled per B / R response.
  // ---------------------------------------------------------------------------
  covergroup cg_response;
    option.per_instance = 1;
    option.name         = "cg_response";

    cp_port_pt: coverpoint cp_port {
      bins ports[] = {[0 : N_PORTS_C - 1]};
    }

    cp_op_pt: coverpoint cp_op {
      bins rd = {VIP_DRAM_OP_RD_E};
      bins wr = {VIP_DRAM_OP_WR_E};
      ignore_bins no_ref = {VIP_DRAM_OP_REF_E};
    }

    cp_resp_pt: coverpoint cp_resp {
      bins okay   = {VIP_MC_AXI4_RESP_OKAY_C};
      bins exokay = {VIP_MC_AXI4_RESP_EXOKAY_C};
      bins slverr = {VIP_MC_AXI4_RESP_SLVERR_C};
      bins decerr = {VIP_MC_AXI4_RESP_DECERR_C};
    }

    // Every port should have seen a clean completion; error responses per port
    // are the multi-port error-isolation question.
    cx_port_resp: cross cp_port_pt, cp_resp_pt;
    cx_op_resp:   cross cp_op_pt, cp_resp_pt;
  endgroup

  // ---------------------------------------------------------------------------
  // Constructor. Covergroups must be constructed here, not in build_phase, or
  // the implicit sample() bindings resolve against an uninitialized object.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
    this.issued_export   = new("issued_export", this);
    this.dram_rsp_export = new("dram_rsp_export", this);
    this.cg_issue        = new();
    this.cg_device       = new();
    this.cg_turnaround   = new();
    this.cg_response     = new();
  endfunction

  // ---------------------------------------------------------------------------
  // Build the per-port B/R taps and bind them back to this collector.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    super.build_phase(phase);

    for (int port_id = 0; port_id < N_PORTS_C; port_id++) begin
      this.b_collector[port_id] = mc_cov_b_collector::type_id::create(
        $sformatf("cov_b_collector_%0d", port_id), this);
      this.b_collector[port_id].cov     = this;
      this.b_collector[port_id].port_id = port_id;

      this.r_collector[port_id] = mc_cov_r_collector::type_id::create(
        $sformatf("cov_r_collector_%0d", port_id), this);
      this.r_collector[port_id].cov     = this;
      this.r_collector[port_id].port_id = port_id;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Backend grant tap. Samples the scheduling decision and the turnaround from
  // the previous grant, then parks the entry until its device response returns.
  // ---------------------------------------------------------------------------
  function void write_cov_issued(input cmd_t e);
    vip_dram_dec_t dec;

    if (e == null) begin
      return;
    end

    this.cp_port         = e.port_id;
    this.cp_op           = e.op;
    this.cp_qos_class    = e.qos_class;
    this.cp_burst        = e.axi_burst;
    this.cp_beats        = e.beats;
    this.cp_size_bytes   = e.axi_size_bytes;
    this.cp_bypass       = e.bypass_count;
    this.cp_coalesce     = e.merged_writes.size();
    this.cp_exclusive    = e.is_exclusive;
    this.cp_pre_resolved = e.pre_resolved;

    // Device address, not the protocol start address: these coverpoints describe
    // where the access lands on the device (they differ for a WRAP burst).
    dec = this.decode(e.get_dev_addr());
    this.cp_rank = e.has_explicit_rank ? e.rank : dec.rank;
    this.cp_bg   = dec.bg;
    this.cp_bank = dec.bank;

    this.cg_issue.sample();
    this.issued_samples++;

    if (this.prev_valid) begin
      this.cp_prev_op = this.prev_issued_op;
      this.cg_turnaround.sample();
    end
    this.prev_issued_op   = e.op;
    this.prev_issued_port = e.port_id;
    this.prev_valid       = 1'b1;

    // A pre-resolved entry (front-end DECERR) never reaches the device, so it
    // would otherwise leak into the inflight map forever.
    if (!e.pre_resolved) begin
      this.inflight[e.tag] = e;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Device response tap. Joins the outcome back to its granted entry by tag.
  // ---------------------------------------------------------------------------
  function void write_cov_dram_rsp(input rsp_t r);
    cmd_t          e;
    vip_dram_dec_t dec;

    if (r == null) begin
      return;
    end

    if (!this.inflight.exists(r.tag)) begin
      // A response with no matching grant: refresh issued directly by the
      // refresh engine, or traffic from a slice this collector does not tap.
      this.orphan_responses++;
      this.cp_qos_class = 0;
      this.cp_bank      = 0;
    end
    else begin
      e = this.inflight[r.tag];
      this.inflight.delete(r.tag);
      this.cp_qos_class = e.qos_class;
      dec               = this.decode(e.get_dev_addr());
      this.cp_bank      = dec.bank;
    end

    this.cp_op = r.op;

    if (r.op == VIP_DRAM_OP_REF_E) begin
      this.cp_page = 3;
    end
    else if (r.was_page_hit) begin
      this.cp_page = 0;
    end
    else if (r.was_page_miss) begin
      this.cp_page = 1;
    end
    else if (r.was_page_empty) begin
      this.cp_page = 2;
    end
    else begin
      this.cp_page = 3;
    end

    this.cp_fault = r.injected_fault;

    this.cg_device.sample();
    this.rsp_samples++;
  endfunction

  // ---------------------------------------------------------------------------
  // Host write completion.
  // ---------------------------------------------------------------------------
  function void observe_b(input int port_id, input axi4_item_t t);
    if (t == null) begin
      return;
    end
    this.cp_port = port_id;
    this.cp_op   = VIP_DRAM_OP_WR_E;
    this.cp_resp = t.bresp;
    this.cg_response.sample();
    this.resp_samples++;
  endfunction

  // ---------------------------------------------------------------------------
  // Host read completion. vip_axi4_item carries one rresp for the whole burst
  // (the monitor collapses the beats), so it is sampled directly.
  // ---------------------------------------------------------------------------
  function void observe_r(input int port_id, input axi4_item_t t);
    if (t == null) begin
      return;
    end

    this.cp_port = port_id;
    this.cp_op   = VIP_DRAM_OP_RD_E;
    this.cp_resp = t.rresp;
    this.cg_response.sample();
    this.resp_samples++;
  endfunction

  // ---------------------------------------------------------------------------
  // Decode a byte address into the device geometry using the DRAM's live map.
  // ---------------------------------------------------------------------------
  protected function vip_dram_dec_t decode(input longint unsigned addr);
    vip_dram_dec_t dec;

    if (this.dram == null) begin
      dec = '{default: 0};
      return dec;
    end
    return vip_dram_decode_addr(addr, DRAM_CFG_C, this.dram.cfg.addr_map);
  endfunction

  // ---------------------------------------------------------------------------
  // Report the four group scores. Coverage is informational - this component
  // never fails a test, so an unpopulated group is a gap to close in the
  // stimulus, not a regression error.
  // ---------------------------------------------------------------------------
  function void report_phase(input uvm_phase phase);
    super.report_phase(phase);

    `uvm_info(get_name(), $sformatf(
      "[COV] issue %0.1f%%  device %0.1f%%  turnaround %0.1f%%  response %0.1f%%",
      this.cg_issue.get_inst_coverage(),
      this.cg_device.get_inst_coverage(),
      this.cg_turnaround.get_inst_coverage(),
      this.cg_response.get_inst_coverage()), UVM_LOW)

    `uvm_info(get_name(), $sformatf(
      "[COV] samples: issued %0d, device %0d, response %0d, unmatched device %0d",
      this.issued_samples,
      this.rsp_samples,
      this.resp_samples,
      this.orphan_responses), UVM_LOW)
  endfunction

  // ---------------------------------------------------------------------------
  // Accessors for a test that wants to assert on its own coverage.
  // ---------------------------------------------------------------------------
  function real get_issue_coverage();
    return this.cg_issue.get_inst_coverage();
  endfunction

  function real get_device_coverage();
    return this.cg_device.get_inst_coverage();
  endfunction

  function real get_turnaround_coverage();
    return this.cg_turnaround.get_inst_coverage();
  endfunction

  function real get_response_coverage();
    return this.cg_response.get_inst_coverage();
  endfunction

endclass

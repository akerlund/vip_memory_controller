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
// tc_mc_chi_d_reject
//
// Reject-coverage across the atomic opcode families. Atomics (AtomicStore,
// AtomicLoad, AtomicSwap, AtomicCompare) are executed by a home node, never by a
// memory subordinate, so the SN front-end must reject each with a defined
// Comp(NONDATA_ERROR) and never touch the device. (Snoop / DVM are not receivable
// by an SN at all -- an SN-F has no SNP channel -- so there is no reject path to
// exercise for them.)
// -----------------------------------------------------------------------------
class tc_mc_chi_d_reject extends mc_chi_base_test;

  `uvm_component_utils(tc_mc_chi_d_reject)

  // Snoop the RN-side RSP channel to prove each rejection Comp reached the RN.
  uvm_tlm_analysis_fifo #(chi_item_t) _rsp_fifo;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(input uvm_phase phase);
    super.build_phase(phase);
    this._rsp_fifo = new("_rsp_fifo", this);
  endfunction

  function void connect_phase(input uvm_phase phase);
    super.connect_phase(phase);
    this._env.rni_agent.rsp_port.connect(this._rsp_fifo.analysis_export);
  endfunction

  task body();
    vip_mc_chi_driver #(VIP_MC_CHI_CFG_C, DRAM_CFG_C) chi_fe;
    chi_types_t::req_flit_t                           req;
    chi_item_t                                        rsp;
    logic [6 : 0]                                     ops [];
    int unsigned                                      issued_before;
    int unsigned                                      unsup_before;
    bit                                               comp_err_by_txnid [int];

    this.wait_reset_and_settle();
    chi_fe = this.get_chi_fe();
    issued_before = chi_fe.issued_req_count;
    unsup_before  = chi_fe.get_unsupported_count();

    // One representative from each atomic family (all fit the CHI-D 6-bit opcode).
    ops = '{
      VIP_CHI_REQ_ATOMIC_STORE_0_C,
      VIP_CHI_REQ_ATOMIC_LOAD_0_C,
      VIP_CHI_REQ_ATOMIC_SWAP_C,
      VIP_CHI_REQ_ATOMIC_COMPARE_C
    };

    foreach (ops[i]) begin
      vip_chi_raw_seq #(VIP_CHI_CFG_C) raw_seq;

      req        = '0;
      req.opcode = chi_types_t::req_opcode_t'(ops[i]);
      req.addr   = CHI_WRITE_READ_ADDR_C;
      req.size   = 3'd6;
      req.txnid  = 'h10 + i;
      req.srcid  = 'h1;
      raw_seq = vip_chi_raw_seq #(VIP_CHI_CFG_C)::type_id::create($sformatf("raw_atomic_%0d", i));
      raw_seq.set_get_response(1'b0);
      raw_seq.add_raw_req(req);
      raw_seq.start(this._env.rni_agent.sequencer);
      repeat (20) @(posedge this._env.rni_agent.vif.clk);
    end

    if (chi_fe.get_unsupported_count() != (unsup_before + ops.size())) begin
      `uvm_fatal(get_name(), $sformatf(
        "Expected %0d atomic rejections, unsupported_count moved %0d -> %0d",
        ops.size(), unsup_before, chi_fe.get_unsupported_count()))
    end
    if (chi_fe.get_persist_count() != 0) begin
      `uvm_fatal(get_name(), "atomic op was misrouted to the persist path")
    end
    if (chi_fe.issued_req_count != issued_before) begin
      `uvm_fatal(get_name(), $sformatf(
        "atomic op leaked to the device: issued_req_count moved %0d -> %0d",
        issued_before, chi_fe.issued_req_count))
    end

    // Every rejected atomic must have received its own Comp(NONDATA_ERROR).
    while (this._rsp_fifo.try_get(rsp)) begin
      if ((rsp.rsp_opcode   == chi_item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) &&
          (rsp.rsp_resp_err == VIP_CHI_RESP_ERR_NONDATA_ERROR_E)) begin
        comp_err_by_txnid[int'(rsp.txn_id)] = 1'b1;
      end
    end
    foreach (ops[i]) begin
      if (!comp_err_by_txnid.exists(int'('h10 + i))) begin
        `uvm_fatal(get_name(), $sformatf(
          "Rejected atomic (txnid=0x%0h) never received a Comp(NONDATA_ERROR)", 'h10 + i))
      end
    end

    `uvm_info(get_name(),
      "CHI atomic families (Store/Load/Swap/Compare) each rejected with Comp(NONDATA_ERROR), device untouched",
      UVM_LOW)
  endtask

endclass

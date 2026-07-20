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
// tc_vip_mc_chi_d_unsupported
//
// Unsupported-opcode rejection. A raw REQ flit carrying an op the SN memory
// target does not implement (AtomicStore0 -- atomics are executed by a home node,
// not a memory subordinate) is injected on the link; the CHI front-end must
// reject it with a defined Comp(NONDATA_ERROR) and bump its unsupported_count,
// never forwarding it to the device. (CleanSharedPersist is now a handled op --
// see tc_vip_mc_chi_persist -- so it is no longer a valid reject example.)
// -----------------------------------------------------------------------------
class tc_vip_mc_chi_d_unsupported extends vip_mc_chi_base_test;

  `uvm_component_utils(tc_vip_mc_chi_d_unsupported)

  // Snoop the RN-side RSP channel so we can prove the rejection Comp actually
  // reached the requester -- not just that telemetry was bumped.
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
    vip_chi_raw_seq #(VIP_CHI_CFG_C)                  raw_seq;
    chi_types_t::req_flit_t                           req;
    chi_item_t                                        rsp;
    int unsigned                                      issued_before;
    int unsigned                                      comp_err_seen;

    this.wait_reset_and_settle();
    chi_fe = this.get_chi_fe();

    issued_before = chi_fe.issued_req_count;

    // Hand-build a REQ flit with an opcode outside the SN's supported set.
    req        = '0;
    req.opcode = chi_types_t::req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_0_C);
    req.addr   = CHI_WRITE_READ_ADDR_C;
    req.size   = 3'd6;
    req.txnid  = 'h7;
    req.srcid  = 'h1;
    req.tgtid  = '0;
    req.qos    = '0;

    raw_seq = vip_chi_raw_seq #(VIP_CHI_CFG_C)::type_id::create("raw_seq");
    raw_seq.set_get_response(1'b0);
    raw_seq.add_raw_req(req);
    raw_seq.start(this._env.rni_agent.sequencer);

    // Let the front-end decode + emit its rejection.
    repeat (20) @(posedge this._env.rni_agent.vif.clk);

    if (chi_fe.get_unsupported_count() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Expected unsupported_count == 1, got %0d", chi_fe.get_unsupported_count()))
    end
    if (chi_fe.issued_req_count != issued_before) begin
      `uvm_fatal(get_name(), $sformatf(
        "Unsupported REQ leaked to the device: issued_req_count moved %0d -> %0d",
        issued_before, chi_fe.issued_req_count))
    end

    // A defined rejection is only useful if the RN actually receives it: assert
    // exactly one Comp(NONDATA_ERROR) carrying the injected TxnID came back.
    comp_err_seen = 0;
    while (this._rsp_fifo.try_get(rsp)) begin
      if ((rsp.rsp_opcode   == chi_item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) &&
          (rsp.txn_id       == req.txnid) &&
          (rsp.rsp_resp_err == VIP_CHI_RESP_ERR_NONDATA_ERROR_E)) begin
        comp_err_seen++;
      end
    end
    if (comp_err_seen != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Expected exactly 1 Comp(NONDATA_ERROR) for the rejected REQ (txnid=0x%0h), saw %0d",
        req.txnid, comp_err_seen))
    end

    `uvm_info(get_name(), "CHI unsupported opcode was rejected with Comp(NONDATA_ERROR), device untouched", UVM_LOW)
  endtask

endclass

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
// tc_vip_mc_chi_d_persist
//
// Persist-to-memory CMOs at the SN. CleanSharedPersist and CleanSharedPersistSep
// are the one "broader" CHI opcode family a memory subordinate can meaningfully
// complete: the data is already at the point of persistence, so the SN just
// acknowledges (Comp for the plain form; Persist + CompPersist for the separated
// form) without any device access. Both raw-injected forms must bump persist_count,
// leave unsupported_count at zero, and never issue to the device.
// -----------------------------------------------------------------------------
class tc_vip_mc_chi_d_persist extends vip_mc_chi_base_test;

  `uvm_component_utils(tc_vip_mc_chi_d_persist)

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task body();
    vip_mc_chi_driver #(VIP_MC_CHI_CFG_C, DRAM_CFG_C) chi_fe;
    vip_chi_raw_seq #(VIP_CHI_CFG_C)                  raw_seq;
    chi_types_t::req_flit_t                           req;
    int unsigned                                      issued_before;

    this.wait_reset_and_settle();
    chi_fe = this.get_chi_fe();
    issued_before = chi_fe.issued_req_count;

    // CleanSharedPersist -> Comp.
    req        = '0;
    req.opcode = chi_types_t::req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_C);
    req.addr   = CHI_WRITE_READ_ADDR_C;
    req.size   = 3'd6;
    req.txnid  = 'h5;
    req.srcid  = 'h1;
    raw_seq = vip_chi_raw_seq #(VIP_CHI_CFG_C)::type_id::create("raw_persist");
    raw_seq.set_get_response(1'b0);
    raw_seq.add_raw_req(req);
    raw_seq.start(this._env.rni_agent.sequencer);
    repeat (20) @(posedge this._env.rni_agent.vif.clk);

    // CleanSharedPersistSep -> Persist then CompPersist.
    req        = '0;
    req.opcode = chi_types_t::req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_SEP_C);
    req.addr   = CHI_WRITE_READ_ADDR_C;
    req.size   = 3'd6;
    req.txnid  = 'h6;
    req.srcid  = 'h1;
    raw_seq = vip_chi_raw_seq #(VIP_CHI_CFG_C)::type_id::create("raw_persist_sep");
    raw_seq.set_get_response(1'b0);
    raw_seq.add_raw_req(req);
    raw_seq.start(this._env.rni_agent.sequencer);
    repeat (20) @(posedge this._env.rni_agent.vif.clk);

    if (chi_fe.get_persist_count() != 2) begin
      `uvm_fatal(get_name(), $sformatf(
        "Expected persist_count == 2, got %0d", chi_fe.get_persist_count()))
    end
    if (chi_fe.get_unsupported_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "Persist CMO was misrouted to the unsupported path (unsupported_count=%0d)",
        chi_fe.get_unsupported_count()))
    end
    if (chi_fe.issued_req_count != issued_before) begin
      `uvm_fatal(get_name(), $sformatf(
        "Persist CMO leaked to the device: issued_req_count moved %0d -> %0d",
        issued_before, chi_fe.issued_req_count))
    end

    `uvm_info(get_name(),
      "CHI persist CMOs (Persist + PersistSep) acknowledged without touching the device", UVM_LOW)
  endtask

endclass

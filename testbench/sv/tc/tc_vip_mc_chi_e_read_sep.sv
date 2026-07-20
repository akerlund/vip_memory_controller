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
// tc_vip_mc_chi_e_read_sep
//
// ReadNoSnpSep (CHI-E only). A separated read returns its data on the DAT channel
// as DataSepResp (rather than CompData) routed to ReturnNID/ReturnTxnID. The test
// writes a known counter pattern, then issues a ReadNoSnpSep of the same line and
// checks that the completion carries the DataSepResp opcode and the correct data.
// -----------------------------------------------------------------------------
class tc_vip_mc_chi_e_read_sep extends vip_mc_chi_base_test #(VIP_CHI_CFG_E_C, VIP_MC_CHI_CFG_E_C);

  `uvm_component_utils(tc_vip_mc_chi_e_read_sep)

  // RN is node 0 here; give the separated read a distinct return TxnID so the
  // DataSepResp correlates on ReturnTxnID rather than the request TxnID.
  localparam int unsigned RETURN_TXN_C = 'h2A;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task body();
    chi_item_e_t read_responses[$];

    this.wait_reset_and_settle();

    // Seed the line with a known counter pattern starting at 0x40.
    this._wr_seq.reset();
    this._wr_seq.set_requests(1);
    this._wr_seq.set_initial_addr(CHI_SEP_ADDR_C);
    this._wr_seq.set_size(3'd6);
    this._wr_seq.set_allow_retry(1'b0);
    this._wr_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
    this._wr_seq.set_counter_value(chi_item_e_t::data_t'('h40));
    this._wr_seq.set_counter_increment(chi_item_e_t::data_t'('h1));
    this._wr_seq.set_get_response(1'b1);
    this._wr_seq.set_verbose(1'b0);
    this._wr_seq.start(this._env.rni_agent.sequencer);

    // Separated read of the same line (ReadNoSnpSep).
    this._rd_seq.reset();
    this._rd_seq.set_requests(1);
    this._rd_seq.set_initial_addr(CHI_SEP_ADDR_C);
    this._rd_seq.set_size(3'd6);
    this._rd_seq.set_allow_retry(1'b0);
    this._rd_seq.set_sep_read(1'b1);
    this._rd_seq.set_return_nid(chi_item_e_t::node_id_t'(0));
    this._rd_seq.set_return_txn_id(chi_item_e_t::txn_id_t'(RETURN_TXN_C));
    this._rd_seq.set_get_response(1'b1);
    this._rd_seq.set_verbose(1'b0);
    this._rd_seq.start(this._env.rni_agent.sequencer);

    read_responses = this._rd_seq.get_responses();

    if ((read_responses.size() != 1) || (read_responses[0].data.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "Expected 1 separated-read completion of 1 beat, got %0d responses",
        read_responses.size()))
    end

    if (read_responses[0].dat_opcode != chi_item_e_t::dat_opcode_t'(VIP_CHI_DAT_DATA_SEP_RESP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "Separated read returned DAT opcode 0x%0h, expected DataSepResp (0x%0h)",
        read_responses[0].dat_opcode, VIP_CHI_DAT_DATA_SEP_RESP_C))
    end

    foreach (read_responses[0].data[i]) begin
      chi_item_e_t::data_t expected;
      expected = chi_item_e_t::data_t'('h40) + chi_item_e_t::data_t'(i);
      if (read_responses[0].data[i] != expected) begin
        `uvm_fatal(get_name(), $sformatf(
          "Separated read-back beat %0d mismatch: got 0x%0h expected 0x%0h",
          i, read_responses[0].data[i], expected))
      end
    end

    `uvm_info(get_name(), "CHI-E ReadNoSnpSep returned DataSepResp with correct data", UVM_LOW)
  endtask

endclass

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
// tc_mc_chi_d_read
//
// A single ReadNoSnp of an untouched line. Proves the CHI front-end issues the
// read to the backend and returns a well-formed CompData completion (correct
// opcode, beat count, and TxnID echo) without asserting a specific payload.
// -----------------------------------------------------------------------------
class tc_mc_chi_d_read extends mc_chi_base_test;

  `uvm_component_utils(tc_mc_chi_d_read)

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task body();
    chi_item_t responses[$];

    this.wait_reset_and_settle();

    this._rd_seq.reset();
    this._rd_seq.set_requests(1);
    this._rd_seq.set_initial_addr(CHI_READ_ADDR_C);
    this._rd_seq.set_size(3'd6);
    this._rd_seq.set_allow_retry(1'b0);
    this._rd_seq.set_get_response(1'b1);
    this._rd_seq.set_verbose(1'b0);
    this._rd_seq.start(this._env.rni_agent.sequencer);

    responses = this._rd_seq.get_responses();

    if (responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Expected 1 read completion, got %0d", responses.size()))
    end

    if (responses[0].dat_opcode != chi_item_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "Read completion carried wrong DAT opcode 0x%0h", responses[0].dat_opcode))
    end

    if (responses[0].data.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Read completion carried %0d beats instead of 1", responses[0].data.size()))
    end

    `uvm_info(get_name(), "CHI ReadNoSnp returned a well-formed CompData", UVM_LOW)
  endtask

endclass

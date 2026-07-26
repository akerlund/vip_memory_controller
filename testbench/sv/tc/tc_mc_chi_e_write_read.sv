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
// tc_mc_chi_e_write_read
//
// CHI-E point of the D/E matrix, and the AXI4<->CHI-D<->CHI-E equivalence data
// point. The RN-I manager runs under issue = E and drives the exact same logical
// access as tc_mc_chi_write_read (WriteNoSnp of one 64-byte line with a
// counter payload starting at 0x90 to CHI_WRITE_READ_ADDR_C, then ReadNoSnp of
// the same line). The read-back data must match byte-for-byte, proving the CHI-E
// front-end lands identical device state as CHI-D for the same operation.
// -----------------------------------------------------------------------------
class tc_mc_chi_e_write_read extends mc_chi_base_test #(VIP_CHI_CFG_E_C, VIP_MC_CHI_CFG_E_C);

  `uvm_component_utils(tc_mc_chi_e_write_read)

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task body();
    chi_item_e_t write_responses[$];
    chi_item_e_t read_responses[$];

    this.wait_reset_and_settle();

    // WriteNoSnpFull of one 64-byte line, counter payload starting at 0x90.
    this._wr_seq.reset();
    this._wr_seq.set_requests(1);
    this._wr_seq.set_initial_addr(CHI_WRITE_READ_ADDR_C);
    this._wr_seq.set_size(3'd6);
    this._wr_seq.set_allow_retry(1'b0);
    this._wr_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
    this._wr_seq.set_counter_value(chi_item_e_t::data_t'('h90));
    this._wr_seq.set_counter_increment(chi_item_e_t::data_t'('h1));
    this._wr_seq.set_get_response(1'b1);
    this._wr_seq.set_verbose(1'b0);
    this._wr_seq.start(this._env.rni_agent.sequencer);

    // ReadNoSnp of the same line.
    this._rd_seq.reset();
    this._rd_seq.set_requests(1);
    this._rd_seq.set_initial_addr(CHI_WRITE_READ_ADDR_C);
    this._rd_seq.set_size(3'd6);
    this._rd_seq.set_allow_retry(1'b0);
    this._rd_seq.set_get_response(1'b1);
    this._rd_seq.set_verbose(1'b0);
    this._rd_seq.start(this._env.rni_agent.sequencer);

    write_responses = this._wr_seq.get_responses();
    read_responses  = this._rd_seq.get_responses();

    if (write_responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Expected 1 write completion, got %0d", write_responses.size()))
    end

    if (read_responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Expected 1 read completion, got %0d", read_responses.size()))
    end

    if (read_responses[0].dat_opcode != chi_item_e_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "Read completion carried wrong DAT opcode 0x%0h", read_responses[0].dat_opcode))
    end

    if (read_responses[0].data.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Read completion carried %0d beats instead of 1", read_responses[0].data.size()))
    end

    // The read-back payload must equal the written counter payload -- identical
    // to what tc_mc_chi_write_read observes under CHI-D.
    foreach (read_responses[0].data[i]) begin
      chi_item_e_t::data_t expected;
      expected = chi_item_e_t::data_t'('h90) + chi_item_e_t::data_t'(i);
      if (read_responses[0].data[i] != expected) begin
        `uvm_fatal(get_name(), $sformatf(
          "Read-back beat %0d mismatch: got 0x%0h expected 0x%0h",
          i, read_responses[0].data[i], expected))
      end
    end

    `uvm_info(get_name(), "CHI-E write/read-back matched through vip_mc + vip_dram (D/E parity)", UVM_LOW)
  endtask

endclass

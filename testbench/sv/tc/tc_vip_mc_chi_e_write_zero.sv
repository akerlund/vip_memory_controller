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
// tc_vip_mc_chi_e_write_zero
//
// WriteNoSnpZero (CHI-E only). The op carries no data phase: the SN must write a
// full line of zeros to the device and complete with Comp. The test first seeds
// the line with a non-zero counter pattern (WriteNoSnpFull) and confirms it, then
// issues WriteNoSnpZero to the same line and reads it back -- every byte must be
// zero, and the front-end's write_count must advance for both writes.
// -----------------------------------------------------------------------------
class tc_vip_mc_chi_e_write_zero extends vip_mc_chi_base_test #(VIP_CHI_CFG_E_C, VIP_MC_CHI_CFG_E_C);

  `uvm_component_utils(tc_vip_mc_chi_e_write_zero)

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task body();
    vip_mc_chi_driver #(VIP_MC_CHI_CFG_E_C, DRAM_CFG_C) chi_fe;
    vip_chi_write_zero_seq #(VIP_CHI_CFG_E_C)           wz_seq;
    chi_item_e_t                                        read_responses[$];
    int unsigned                                        writes_before;

    this.wait_reset_and_settle();
    chi_fe = this.get_chi_fe();

    // Seed the line with a non-zero counter pattern (WriteNoSnpFull).
    this._wr_seq.reset();
    this._wr_seq.set_requests(1);
    this._wr_seq.set_initial_addr(CHI_ZERO_ADDR_C);
    this._wr_seq.set_size(3'd6);
    this._wr_seq.set_allow_retry(1'b0);
    this._wr_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
    this._wr_seq.set_counter_value(chi_item_e_t::data_t'('h11));
    this._wr_seq.set_counter_increment(chi_item_e_t::data_t'('h1));
    this._wr_seq.set_get_response(1'b1);
    this._wr_seq.set_verbose(1'b0);
    this._wr_seq.start(this._env.rni_agent.sequencer);

    // Confirm the seed landed non-zero before we zero it.
    this._rd_seq.reset();
    this._rd_seq.set_requests(1);
    this._rd_seq.set_initial_addr(CHI_ZERO_ADDR_C);
    this._rd_seq.set_size(3'd6);
    this._rd_seq.set_allow_retry(1'b0);
    this._rd_seq.set_get_response(1'b1);
    this._rd_seq.set_verbose(1'b0);
    this._rd_seq.start(this._env.rni_agent.sequencer);
    read_responses = this._rd_seq.get_responses();
    if ((read_responses.size() != 1) || (read_responses[0].data[0] == '0)) begin
      `uvm_fatal(get_name(), "Seed write did not land a non-zero line before WriteNoSnpZero")
    end

    writes_before = chi_fe.get_write_count();

    // WriteNoSnpZero of the same line (no data phase; seq needs no payload).
    wz_seq = vip_chi_write_zero_seq #(VIP_CHI_CFG_E_C)::type_id::create("wz_seq");
    wz_seq.set_requests(1);
    wz_seq.set_initial_addr(CHI_ZERO_ADDR_C);
    wz_seq.set_size(3'd6);
    wz_seq.set_allow_retry(1'b0);
    wz_seq.set_get_response(1'b1);
    wz_seq.set_verbose(1'b0);
    wz_seq.start(this._env.rni_agent.sequencer);

    // Read the line back -- every byte must now be zero.
    this._rd_seq.reset();
    this._rd_seq.set_requests(1);
    this._rd_seq.set_initial_addr(CHI_ZERO_ADDR_C);
    this._rd_seq.set_size(3'd6);
    this._rd_seq.set_allow_retry(1'b0);
    this._rd_seq.set_get_response(1'b1);
    this._rd_seq.set_verbose(1'b0);
    this._rd_seq.start(this._env.rni_agent.sequencer);
    read_responses = this._rd_seq.get_responses();

    if ((read_responses.size() != 1) || (read_responses[0].data.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "Expected 1 read completion of 1 beat, got %0d responses", read_responses.size()))
    end
    if (read_responses[0].data[0] != '0) begin
      `uvm_fatal(get_name(), $sformatf(
        "WriteNoSnpZero left non-zero data: 0x%0h", read_responses[0].data[0]))
    end

    if (chi_fe.get_write_count() != (writes_before + 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "WriteNoSnpZero did not advance write_count: %0d -> %0d",
        writes_before, chi_fe.get_write_count()))
    end

    `uvm_info(get_name(), "CHI-E WriteNoSnpZero zeroed the line through vip_mc + vip_dram", UVM_LOW)
  endtask

endclass

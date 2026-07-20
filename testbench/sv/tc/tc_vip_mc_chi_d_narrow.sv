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
// tc_vip_mc_chi_d_narrow
//
// Narrow-DAT CHI (DATA_BYTES 32 < ROW_BYTES 64): a 64 B WriteNoSnp is carried as
// two 32 B DAT beats that must gather into one 64 B DRAM row word (beat 0 -> row
// lanes 0-31, beat 1 -> 32-63), and a ReadNoSnp of the line must scatter that row
// word back into two 32 B DataResp beats. The per-beat counter payload lets the
// read-back check that each beat landed in and returned from the correct row half.
// -----------------------------------------------------------------------------
class tc_vip_mc_chi_d_narrow extends vip_mc_chi_base_test #(VIP_CHI_CFG_N32_C, VIP_MC_CHI_CFG_N32_C);

  `uvm_component_utils(tc_vip_mc_chi_d_narrow)

  localparam byte unsigned BASE_C = 8'h90;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task body();
    chi_item_n32_t read_responses [$];

    this.wait_reset_and_settle();

    // WriteNoSnpFull of one 64 B line -> two 32 B DAT beats (counter per beat:
    // beat 0 = 0x90, beat 1 = 0x91).
    this._wr_seq.reset();
    this._wr_seq.set_requests(1);
    this._wr_seq.set_initial_addr(CHI_NARROW_ADDR_C);
    this._wr_seq.set_size(3'd6);   // 64 bytes
    this._wr_seq.set_allow_retry(1'b0);
    this._wr_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
    this._wr_seq.set_counter_value(chi_item_n32_t::data_t'(BASE_C));
    this._wr_seq.set_counter_increment(chi_item_n32_t::data_t'('h1));
    this._wr_seq.set_get_response(1'b1);
    this._wr_seq.set_verbose(1'b0);
    this._wr_seq.start(this._env.rni_agent.sequencer);

    // ReadNoSnp of the same line -> two 32 B DAT beats scattered back out.
    this._rd_seq.reset();
    this._rd_seq.set_requests(1);
    this._rd_seq.set_initial_addr(CHI_NARROW_ADDR_C);
    this._rd_seq.set_size(3'd6);
    this._rd_seq.set_allow_retry(1'b0);
    this._rd_seq.set_get_response(1'b1);
    this._rd_seq.set_verbose(1'b0);
    this._rd_seq.start(this._env.rni_agent.sequencer);

    read_responses = this._rd_seq.get_responses();
    if (read_responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Expected 1 read completion, got %0d", read_responses.size()))
    end
    if (read_responses[0].data.size() != 2) begin
      `uvm_fatal(get_name(), $sformatf(
        "Narrow-DAT read expected 2 DAT beats (32 B over a 64 B row), got %0d",
        read_responses[0].data.size()))
    end

    // Each 32 B beat must read back its own counter value in the low byte,
    // proving the gather/scatter mapped beats to the correct row halves.
    foreach (read_responses[0].data[i]) begin
      byte unsigned got;
      byte unsigned exp;
      got = read_responses[0].data[i][7 : 0];
      exp = BASE_C + i;
      if (got !== exp) begin
        `uvm_fatal(get_name(), $sformatf(
          "Narrow-DAT read beat %0d low byte got 0x%02h expected 0x%02h", i, got, exp))
      end
    end

    `uvm_info(get_name(),
      "Narrow-DAT CHI multi-beat gather/scatter verified (2x 32 B DAT <-> one 64 B row)",
      UVM_LOW)
  endtask

endclass

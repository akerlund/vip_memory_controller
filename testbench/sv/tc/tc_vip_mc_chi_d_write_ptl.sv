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
// tc_vip_mc_chi_d_write_ptl
//
// WriteNoSnpPtl byte-enable correctness. A full line is written (all bytes
// 0xC3), then a partial write (WriteNoSnpPtl, auto-selected because a custom BE
// is set) overwrites only the low 8 bytes with 0x5A. The read-back must show the
// enabled bytes updated and every disabled byte unchanged -- proving the CHI
// front-end forwards per-byte strobes to the backend/device.
// -----------------------------------------------------------------------------
class tc_vip_mc_chi_d_write_ptl extends vip_mc_chi_base_test;

  `uvm_component_utils(tc_vip_mc_chi_d_write_ptl)

  localparam byte unsigned FULL_BYTE_C = 8'hC3;
  localparam byte unsigned PTL_BYTE_C  = 8'h5A;
  localparam int unsigned  PTL_BYTES_C = 8;   // low 8 bytes enabled

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task body();
    chi_item_t::data_t full_data;
    chi_item_t::data_t ptl_data;
    chi_item_t::be_t   ptl_be;
    chi_item_t::data_t data_q[$];
    chi_item_t::be_t   be_q[$];
    chi_item_t         read_responses[$];
    byte unsigned      got;
    byte unsigned      exp;

    this.wait_reset_and_settle();

    full_data = {64{FULL_BYTE_C}};
    ptl_data  = {64{PTL_BYTE_C}};
    ptl_be    = '0;
    for (int i = 0; i < PTL_BYTES_C; i++) begin
      ptl_be[i] = 1'b1;   // enable byte i
    end

    // Full-line baseline write (WriteNoSnpFull: no custom BE).
    this._wr_seq.reset();
    this._wr_seq.set_requests(1);
    this._wr_seq.set_initial_addr(CHI_PTL_ADDR_C);
    this._wr_seq.set_size(3'd6);
    this._wr_seq.set_allow_retry(1'b0);
    this._wr_seq.set_data_type(VIP_CHI_DATA_CUSTOM_E);
    data_q = '{full_data};
    this._wr_seq.set_data(data_q);
    this._wr_seq.set_get_response(1'b1);
    this._wr_seq.set_verbose(1'b0);
    this._wr_seq.start(this._env.rni_agent.sequencer);

    // Partial overwrite of the low bytes (custom BE => WriteNoSnpPtl).
    this._wr_seq.reset();
    this._wr_seq.set_requests(1);
    this._wr_seq.set_initial_addr(CHI_PTL_ADDR_C);
    this._wr_seq.set_size(3'd6);
    this._wr_seq.set_allow_retry(1'b0);
    this._wr_seq.set_data_type(VIP_CHI_DATA_CUSTOM_E);
    data_q = '{ptl_data};
    be_q   = '{ptl_be};
    this._wr_seq.set_data(data_q);
    this._wr_seq.set_be(be_q);
    this._wr_seq.set_get_response(1'b1);
    this._wr_seq.set_verbose(1'b0);
    this._wr_seq.start(this._env.rni_agent.sequencer);

    // Read the merged line back.
    this._rd_seq.reset();
    this._rd_seq.set_requests(1);
    this._rd_seq.set_initial_addr(CHI_PTL_ADDR_C);
    this._rd_seq.set_size(3'd6);
    this._rd_seq.set_allow_retry(1'b0);
    this._rd_seq.set_get_response(1'b1);
    this._rd_seq.set_verbose(1'b0);
    this._rd_seq.start(this._env.rni_agent.sequencer);

    read_responses = this._rd_seq.get_responses();

    if ((read_responses.size() != 1) || (read_responses[0].data.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "Expected 1 read completion of 1 beat, got %0d responses",
        read_responses.size()))
    end

    for (int i = 0; i < 64; i++) begin
      got = read_responses[0].data[0][(8 * i) +: 8];
      exp = (i < PTL_BYTES_C) ? PTL_BYTE_C : FULL_BYTE_C;
      if (got != exp) begin
        `uvm_fatal(get_name(), $sformatf(
          "WriteNoSnpPtl merge wrong at byte %0d: got 0x%0h expected 0x%0h", i, got, exp))
      end
    end

    `uvm_info(get_name(), "CHI WriteNoSnpPtl merged enabled bytes and preserved the rest", UVM_LOW)
  endtask

endclass

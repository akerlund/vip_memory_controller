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
// tc_vip_mc_chi_d_decerr
//
// DECERR handling for the CHI front-end. The env installs a DECERR window; a
// ReadNoSnp into it must return CompData carrying NONDATA_ERROR (no device
// access), and a WriteNoSnp into it must drain its data and return Comp carrying
// NONDATA_ERROR. The front-end's decerr_count corroborates both.
// -----------------------------------------------------------------------------
class tc_vip_mc_chi_d_decerr extends vip_mc_chi_base_test;

  `uvm_component_utils(tc_vip_mc_chi_d_decerr)

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task body();
    vip_mc_chi_driver #(VIP_MC_CHI_CFG_C, DRAM_CFG_C) chi_fe;
    chi_item_t::data_t data_q[$];
    chi_item_t         read_responses[$];
    chi_item_t         write_responses[$];

    this.wait_reset_and_settle();
    chi_fe = this.get_chi_fe();

    // ReadNoSnp of a DECERR-mapped line: CompData with NONDATA_ERROR, no device.
    this._rd_seq.reset();
    this._rd_seq.set_requests(1);
    this._rd_seq.set_initial_addr(CHI_DECERR_ADDR_C);
    this._rd_seq.set_size(3'd6);
    this._rd_seq.set_allow_retry(1'b0);
    this._rd_seq.set_get_response(1'b1);
    this._rd_seq.set_verbose(1'b0);
    this._rd_seq.start(this._env.rni_agent.sequencer);

    read_responses = this._rd_seq.get_responses();
    if ((read_responses.size() != 1) || (read_responses[0].dat_resp_err.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "Expected 1 read completion of 1 beat, got %0d responses", read_responses.size()))
    end
    if (read_responses[0].dat_resp_err[0] != VIP_CHI_RESP_ERR_NONDATA_ERROR_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "DECERR read did not return NONDATA_ERROR (got 0x%0h)",
        read_responses[0].dat_resp_err[0]))
    end

    // WriteNoSnp of a DECERR-mapped line: data drained, Comp with NONDATA_ERROR.
    this._wr_seq.reset();
    this._wr_seq.set_requests(1);
    this._wr_seq.set_initial_addr(CHI_DECERR_ADDR_C);
    this._wr_seq.set_size(3'd6);
    this._wr_seq.set_allow_retry(1'b0);
    this._wr_seq.set_data_type(VIP_CHI_DATA_CUSTOM_E);
    data_q = '{ {64{8'hC3}} };
    this._wr_seq.set_data(data_q);
    this._wr_seq.set_get_response(1'b1);
    this._wr_seq.set_verbose(1'b0);
    this._wr_seq.start(this._env.rni_agent.sequencer);

    write_responses = this._wr_seq.get_responses();
    if (write_responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Expected 1 write completion, got %0d", write_responses.size()))
    end
    if (write_responses[0].rsp_resp_err != VIP_CHI_RESP_ERR_NONDATA_ERROR_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "DECERR write did not return NONDATA_ERROR (got 0x%0h)",
        write_responses[0].rsp_resp_err))
    end

    if (chi_fe.get_decerr_count() != 2) begin
      `uvm_fatal(get_name(), $sformatf(
        "Expected front-end decerr_count == 2, got %0d", chi_fe.get_decerr_count()))
    end

    `uvm_info(get_name(), "CHI DECERR read+write both returned NONDATA_ERROR", UVM_LOW)
  endtask

endclass

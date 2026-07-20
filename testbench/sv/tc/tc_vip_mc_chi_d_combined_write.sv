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
// tc_vip_mc_chi_d_combined_write
//
// Exercises the MC-native vip_mc_chi_cfg.split_write_rsp knob. With split-write
// disabled (0), the front-end grants the write buffer and completes in a single
// CompDBIDResp instead of DBIDResp + a deferred Comp. The write must still land
// in the device: a combined write followed by a read-back must match.
// -----------------------------------------------------------------------------
class tc_vip_mc_chi_d_combined_write extends vip_mc_chi_base_test;

  `uvm_component_utils(tc_vip_mc_chi_d_combined_write)

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // Select combined (non-split) write responses before the env builds vip_mc.
  function void build_phase(input uvm_phase phase);
    uvm_config_db #(int)::set(this, "env", "mc_chi_split_write_rsp", 0);
    super.build_phase(phase);
  endfunction

  task body();
    chi_item_t::data_t wdata;
    chi_item_t::data_t data_q[$];
    chi_item_t         write_responses[$];
    chi_item_t         read_responses[$];

    this.wait_reset_and_settle();

    wdata = {64{8'h3C}};

    this._wr_seq.reset();
    this._wr_seq.set_requests(1);
    this._wr_seq.set_initial_addr(CHI_COMBINED_ADDR_C);
    this._wr_seq.set_size(3'd6);
    this._wr_seq.set_allow_retry(1'b0);
    this._wr_seq.set_data_type(VIP_CHI_DATA_CUSTOM_E);
    data_q = '{wdata};
    this._wr_seq.set_data(data_q);
    this._wr_seq.set_get_response(1'b1);
    this._wr_seq.set_verbose(1'b0);
    this._wr_seq.start(this._env.rni_agent.sequencer);

    write_responses = this._wr_seq.get_responses();
    if (write_responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Expected 1 write completion, got %0d", write_responses.size()))
    end
    if (write_responses[0].rsp_resp_err != VIP_CHI_RESP_ERR_NORMAL_OKAY_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "Combined write returned an error resp (0x%0h)", write_responses[0].rsp_resp_err))
    end

    this._rd_seq.reset();
    this._rd_seq.set_requests(1);
    this._rd_seq.set_initial_addr(CHI_COMBINED_ADDR_C);
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
    if (read_responses[0].data[0] != wdata) begin
      `uvm_fatal(get_name(), $sformatf(
        "Combined-write read-back mismatch: got 0x%0h expected 0x%0h",
        read_responses[0].data[0], wdata))
    end

    `uvm_info(get_name(), "CHI combined (CompDBIDResp) write landed and read back correctly", UVM_LOW)
  endtask

endclass

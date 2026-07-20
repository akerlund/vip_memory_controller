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
// tc_vip_mc_axi4_single_beat
//
// Active test for the first executable vip_mc datapath slice. It drives
// the owned AXI4 interface directly, proves write-then-read traffic reaches the
// shared vip_dram backend, and checks that DECERR short-circuits at the FE.
// -----------------------------------------------------------------------------
class tc_vip_mc_axi4_single_beat extends vip_mc_base_test;

  `uvm_component_utils(tc_vip_mc_axi4_single_beat)

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Drive one-beat AXI4 write/read traffic through vip_mc and check responses.
  // ---------------------------------------------------------------------------
  task body();
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;
    logic [1 : 0] bresp;
    logic [1 : 0] rresp;
    logic [1 : 0] decerr_resp;
    wdata_t       write_data;
    rdata_t       read_data;
    rdata_t       decerr_data;
    int unsigned  issued_before_decerr;

    if (!$cast(fe0, this._tb_env.u_mc.fes[0])) begin
      `uvm_fatal(get_name(), "vip_mc port 0 was not built as an AXI4 front-end")
    end

    this.wait_for_reset_release();

    write_data = '0;
    for (int byte_idx = 0; byte_idx < VIP_MC_AXI4_CFG_C.WDATA_BYTES_P; byte_idx++) begin
      write_data[(8 * byte_idx) +: 8] = (8'hA0 + byte_idx[7:0]);
    end

    this.axi4_write_single('h0000, write_data, '1, bresp);
    if (bresp != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Aligned full-width AXI4 write returned BRESP=%0b instead of OKAY",
        bresp))
    end

    this.axi4_read_single('h0000, read_data, rresp);
    if (rresp != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Aligned full-width AXI4 read returned RRESP=%0b instead of OKAY",
        rresp))
    end

    if (read_data !== write_data) begin
      `uvm_fatal(get_name(), "vip_mc readback data did not match the preceding write")
    end

    issued_before_decerr = this._tb_env.u_mc.backend.issued_req_count;
    this.axi4_read_single('h1800, decerr_data, decerr_resp);
    if (decerr_resp != VIP_MC_AXI4_RESP_DECERR_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Configured DECERR window read returned RRESP=%0b instead of DECERR",
        decerr_resp))
    end

    if (decerr_data !== '0) begin
      `uvm_fatal(get_name(), "Immediate DECERR read returned non-zero data")
    end

    if (this._tb_env.u_mc.backend.issued_req_count != issued_before_decerr) begin
      `uvm_fatal(get_name(), "DECERR read should not have been forwarded into vip_dram")
    end

    if (this._tb_env.u_mc.backend.issued_req_count != 2) begin
      `uvm_fatal(get_name(), $sformatf(
        "vip_mc backend issued_req_count=%0d observed_rsp_count=%0d fe{issued=%0d complete=%0d obs_aw=%0d obs_w=%0d obs_ar=%0d} instead of the expected 2 DRAM requests",
        this._tb_env.u_mc.backend.issued_req_count,
        this._tb_env.u_mc.backend.observed_rsp_count,
        fe0.issued_req_count,
        fe0.complete_count,
        fe0.observed_aw_count,
        fe0.observed_w_count,
        fe0.observed_ar_count))
    end

    if (this._tb_env.u_mc.backend.observed_rsp_count != 2) begin
      `uvm_fatal(get_name(), "vip_mc backend did not observe the expected number of DRAM responses")
    end

    if (fe0.issued_req_count != 2) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not issue the expected number of backend requests")
    end

    if (fe0.complete_count != 3) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not observe the expected number of completions")
    end

    if ((fe0.observed_aw_count != 1) || (fe0.observed_w_count != 1) || (fe0.observed_ar_count != 2)) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not count the expected channel handshakes")
    end

    if (!fe0.last_completed.pre_resolved || (fe0.last_completed.resp != VIP_MC_AXI4_RESP_DECERR_C)) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not retain the expected DECERR completion")
    end

    if (this._tb_env.u_mc.backend.last_completed_cmd.op != VIP_DRAM_OP_RD_E) begin
      `uvm_fatal(get_name(), "vip_mc backend last completed command was not the successful read")
    end

    `uvm_info(get_name(), "vip_mc AXI4 single-beat test passed", UVM_LOW)
  endtask

endclass
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
// tc_mc_axi4_fixed
//
// Active test for AXI4 FIXED support. It drives a narrow unaligned FIXED
// write burst where later beats overwrite the same addressed lanes, then checks
// that vip_mc packs the request into one DRAM row access and replays repeated
// FIXED reads from the final stored bytes.
// -----------------------------------------------------------------------------
class tc_mc_axi4_fixed extends mc_base_test;

  `uvm_component_utils(tc_mc_axi4_fixed)

  localparam int BURST_BEATS_C = 2;
  localparam int AXI_SIZE_BYTES_C = 4;
  localparam longint unsigned BASE_ADDR_C = 'h0001;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Drive one narrow unaligned FIXED burst through vip_mc and check replay.
  // ---------------------------------------------------------------------------
  task body();
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;
    logic [2 : 0]                                       axi_size;
    wdata_t                                             write_data_q[];
    wstrb_t                                             write_strb_q[];
    rdata_t                                             read_data_q[];
    resp_t                                              read_resp_q[];
    resp_t                                              bresp;
    wdata_t                                             expected_packed_data;
    wstrb_t                                             expected_packed_strb;
    rdata_t                                             expected_read_beat;

    if (!$cast(fe0, this._tb_env.u_mc.fes[0])) begin
      `uvm_fatal(get_name(), "vip_mc port 0 was not built as an AXI4 front-end")
    end

    this.wait_for_reset_release();

    axi_size = this.get_axi_size_for_bytes(AXI_SIZE_BYTES_C);
    write_data_q = new[BURST_BEATS_C];
    write_strb_q = new[BURST_BEATS_C];
    foreach (write_data_q[i]) begin
      write_data_q[i] = '0;
      write_strb_q[i] = '0;
    end

    write_strb_q[0][1 +: 3] = 3'b111;
    write_data_q[0][(8 * 1) +: 8] = 8'hC1;
    write_data_q[0][(8 * 2) +: 8] = 8'hC2;
    write_data_q[0][(8 * 3) +: 8] = 8'hC3;

    write_strb_q[1][1 +: 3] = 3'b111;
    write_data_q[1][(8 * 1) +: 8] = 8'hD1;
    write_data_q[1][(8 * 2) +: 8] = 8'hD2;
    write_data_q[1][(8 * 3) +: 8] = 8'hD3;

    expected_packed_data = write_data_q[1];
    expected_packed_strb = write_strb_q[1];
    expected_read_beat   = write_data_q[1];

    this.axi4_write_fixed_custom(BASE_ADDR_C, axi_size, write_data_q, write_strb_q, bresp);
    if (bresp != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "AXI4 FIXED write burst returned BRESP=%0b instead of OKAY",
        bresp))
    end

    if (this._tb_env.u_mc.backend.last_issued_req.beats != 1) begin
      `uvm_fatal(get_name(), "vip_mc backend did not collapse the FIXED burst into one DRAM row access")
    end
    if (this._tb_env.u_mc.backend.last_issued_req.wdata[0] !== expected_packed_data) begin
      `uvm_fatal(get_name(), "vip_mc backend FIXED write row data did not preserve the latest beat bytes")
    end
    if (this._tb_env.u_mc.backend.last_issued_req.wstrb[0] !== expected_packed_strb) begin
      `uvm_fatal(get_name(), "vip_mc backend FIXED write row strobe did not preserve the expected lane mask")
    end

    this.axi4_read_fixed_custom(BASE_ADDR_C, axi_size, BURST_BEATS_C, read_data_q, read_resp_q);
    foreach (read_resp_q[i]) begin
      if (read_resp_q[i] != VIP_MC_AXI4_RESP_OKAY_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "AXI4 FIXED read beat %0d returned RRESP=%0b instead of OKAY",
          i, read_resp_q[i]))
      end
      if (read_data_q[i] !== expected_read_beat) begin
        `uvm_fatal(get_name(), $sformatf(
          "AXI4 FIXED readback mismatch on beat %0d", i))
      end
    end

    if (this._tb_env.u_mc.backend.last_issued_req.beats != 1) begin
      `uvm_fatal(get_name(), "vip_mc backend FIXED read request did not preserve the single DRAM beat")
    end
    if (this._tb_env.u_mc.backend.last_completed_cmd.rdata.size() != 1) begin
      `uvm_fatal(get_name(), "vip_mc backend FIXED read completion did not preserve one DRAM row")
    end
    if (this._tb_env.u_mc.backend.last_completed_cmd.rdata[0] !== expected_packed_data) begin
      `uvm_fatal(get_name(), "vip_mc backend FIXED read returned unexpected packed row data")
    end

    if (fe0.issued_req_count != 2) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not issue the expected number of FIXED requests")
    end
    if ((fe0.last_issued.axi_beats != BURST_BEATS_C) || (fe0.last_issued.beats != 1)) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not preserve the FIXED AXI-to-DRAM beat mapping")
    end
    if (fe0.complete_count != 2) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not observe the expected FIXED completions")
    end

    `uvm_info(get_name(), "vip_mc AXI4 FIXED test passed", UVM_LOW)
  endtask

endclass
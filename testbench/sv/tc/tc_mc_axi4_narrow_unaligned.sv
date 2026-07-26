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
// tc_mc_axi4_narrow_unaligned
//
// Active test for the AXI4 FE narrow/unaligned slice. It drives a
// 2-beat, 4-byte INCR burst with an unaligned base address, checks that vip_mc
// packs both beats into one DRAM row access, and verifies readback unpacking.
// -----------------------------------------------------------------------------
class tc_mc_axi4_narrow_unaligned extends mc_base_test;

  `uvm_component_utils(tc_mc_axi4_narrow_unaligned)

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
  // Drive one narrow unaligned burst through vip_mc and check packing.
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
    write_data_q[0][(8 * 1) +: 8] = 8'hA1;
    write_data_q[0][(8 * 2) +: 8] = 8'hA2;
    write_data_q[0][(8 * 3) +: 8] = 8'hA3;

    write_strb_q[1][4 +: 4] = 4'hF;
    write_data_q[1][(8 * 4) +: 8] = 8'hB4;
    write_data_q[1][(8 * 5) +: 8] = 8'hB5;
    write_data_q[1][(8 * 6) +: 8] = 8'hB6;
    write_data_q[1][(8 * 7) +: 8] = 8'hB7;

    expected_packed_data = write_data_q[0] | write_data_q[1];
    expected_packed_strb = write_strb_q[0] | write_strb_q[1];

    this.axi4_write_incr_custom(BASE_ADDR_C, axi_size, write_data_q, write_strb_q, bresp);
    if (bresp != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Narrow unaligned AXI4 write burst returned BRESP=%0b instead of OKAY",
        bresp))
    end

    if (this._tb_env.u_mc.backend.last_issued_req.beats != 1) begin
      `uvm_fatal(get_name(), "vip_mc backend did not pack the narrow burst into one DRAM row access")
    end
    if ((this._tb_env.u_mc.backend.last_issued_req.wdata.size() != 1) ||
        (this._tb_env.u_mc.backend.last_issued_req.wstrb.size() != 1)) begin
      `uvm_fatal(get_name(), "vip_mc backend write request did not preserve the packed row payload shape")
    end
    if (this._tb_env.u_mc.backend.last_issued_req.wdata[0] !== expected_packed_data) begin
      `uvm_fatal(get_name(), "vip_mc backend packed write row data did not match the expected merged payload")
    end
    if (this._tb_env.u_mc.backend.last_issued_req.wstrb[0] !== expected_packed_strb) begin
      `uvm_fatal(get_name(), "vip_mc backend packed write row strobe did not match the expected merged mask")
    end

    this.axi4_read_incr_custom(BASE_ADDR_C, axi_size, BURST_BEATS_C, read_data_q, read_resp_q);
    foreach (read_resp_q[i]) begin
      if (read_resp_q[i] != VIP_MC_AXI4_RESP_OKAY_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "Narrow unaligned AXI4 read beat %0d returned RRESP=%0b instead of OKAY",
          i, read_resp_q[i]))
      end
      if (read_data_q[i] !== write_data_q[i]) begin
        `uvm_fatal(get_name(), $sformatf(
          "Narrow unaligned AXI4 readback mismatch on beat %0d", i))
      end
    end

    if (this._tb_env.u_mc.backend.last_issued_req.beats != 1) begin
      `uvm_fatal(get_name(), "vip_mc backend did not preserve the packed DRAM beat count on the read request")
    end
    if (this._tb_env.u_mc.backend.last_completed_cmd.rdata.size() != 1) begin
      `uvm_fatal(get_name(), "vip_mc backend did not complete the narrow read with one packed DRAM row")
    end
    if (this._tb_env.u_mc.backend.last_completed_cmd.rdata[0] !== expected_packed_data) begin
      `uvm_fatal(get_name(), "vip_mc backend returned packed row data that does not match the merged write payload")
    end

    if (fe0.issued_req_count != 2) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not issue the expected number of narrow requests")
    end
    if (fe0.last_issued.axi_beats != BURST_BEATS_C) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not preserve the original AXI beat count")
    end
    if (fe0.last_issued.beats != 1) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not translate the narrow burst into one DRAM beat")
    end
    if (fe0.complete_count != 2) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not observe the expected narrow completions")
    end
    if ((fe0.last_completed.axi_beats != BURST_BEATS_C) || (fe0.last_completed.rdata.size() != 1)) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not retain the AXI-beat to DRAM-beat mapping metadata")
    end

    `uvm_info(get_name(), "vip_mc AXI4 narrow/unaligned test passed", UVM_LOW)
  endtask

endclass
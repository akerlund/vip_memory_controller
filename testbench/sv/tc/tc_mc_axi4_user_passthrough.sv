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
// tc_mc_axi4_user_passthrough
//
// Active test for AXI4 USER passthrough. It drives one write and one read
// with non-zero USER values and checks that BUSER/RUSER echo AUSER while WUSER
// is preserved inside the front-end command entry.
// -----------------------------------------------------------------------------
class tc_mc_axi4_user_passthrough extends mc_base_test;

  `uvm_component_utils(tc_mc_axi4_user_passthrough)

  localparam longint unsigned WRITE_ADDR_C = 'h0340;
  localparam longint unsigned READ_ADDR_C  = 'h0380;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Drive USER-tagged write/read traffic through vip_mc and check passthrough.
  // ---------------------------------------------------------------------------
  task body();
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;
    logic [2 : 0]                                       axi_size;
    awuser_t                                            awuser;
    wuser_t                                             wuser;
    buser_t                                             buser;
    aruser_t                                            aruser;
    ruser_t                                             ruser_q[];
    wdata_t                                             write_data_q[];
    wstrb_t                                             write_strb_q[];
    rdata_t                                             read_data_q[];
    resp_t                                              read_resp_q[];
    resp_t                                              bresp;

    if (!$cast(fe0, this._tb_env.u_mc.fes[0])) begin
      `uvm_fatal(get_name(), "vip_mc port 0 was not built as an AXI4 front-end")
    end

    this.wait_for_reset_release();

    axi_size = this.get_full_width_axi_size();
    awuser   = '1;
    wuser    = '1;
    aruser   = '1;
    buser    = '0;

    write_data_q = new[1];
    write_strb_q = new[1];
    write_data_q[0] = '0;
    write_strb_q[0] = '1;
    for (int byte_idx = 0; byte_idx < VIP_MC_AXI4_CFG_C.WDATA_BYTES_P; byte_idx++) begin
      write_data_q[0][(8 * byte_idx) +: 8] = (8'hC0 + byte_idx[7:0]);
    end

    this.axi4_write_custom_user(
      WRITE_ADDR_C,
      axi_size,
      VIP_MC_AXI4_BURST_INCR_C,
      awuser,
      wuser,
      write_data_q,
      write_strb_q,
      bresp,
      buser);
    if (bresp != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "AXI4 USER write returned BRESP=%0b instead of OKAY",
        bresp))
    end
    if (buser !== awuser) begin
      `uvm_fatal(get_name(), "vip_mc did not echo AWUSER on BUSER")
    end
    if (fe0.last_issued.auser !== awuser) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not preserve AWUSER in the command entry")
    end
    if (fe0.last_issued.wuser !== wuser) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not preserve WUSER in the command entry")
    end

    this.axi4_read_custom_user(
      WRITE_ADDR_C,
      axi_size,
      VIP_MC_AXI4_BURST_INCR_C,
      aruser,
      1,
      read_data_q,
      read_resp_q,
      ruser_q);
    if (read_resp_q[0] != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "AXI4 USER read returned RRESP=%0b instead of OKAY",
        read_resp_q[0]))
    end
    if (read_data_q[0] !== write_data_q[0]) begin
      `uvm_fatal(get_name(), "vip_mc USER readback data did not match the previous write")
    end
    if (ruser_q[0] !== aruser) begin
      `uvm_fatal(get_name(), "vip_mc did not echo ARUSER on RUSER")
    end
    if (fe0.last_issued.auser !== aruser) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not preserve ARUSER in the command entry")
    end

    if (fe0.issued_req_count != 2) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not issue the expected number of USER-tagged requests")
    end
    if (fe0.complete_count != 2) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not observe the expected number of USER-tagged completions")
    end

    `uvm_info(get_name(), "vip_mc AXI4 USER passthrough test passed", UVM_LOW)
  endtask

endclass
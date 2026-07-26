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
// tc_mc_axi4_multi_port
//
// Focused for the first homogeneous two-port AXI4 vip_mc slice. It
// proves that both front-ends register, issue through the shared backend, and
// return data on the correct port.
// -----------------------------------------------------------------------------
class tc_mc_axi4_multi_port extends mc_base_test;

  `uvm_component_utils(tc_mc_axi4_multi_port)

  localparam longint unsigned ADDR0_C = 'h0700;
  localparam longint unsigned ADDR1_C = 'h0800;
  localparam wdata_t          DATA0_C = 'h0123_4567_89ab_cdef;
  localparam wdata_t          DATA1_C = 'hfedc_ba98_7654_3210;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Drive traffic on both ports and prove the shared backend routes it back.
  // ---------------------------------------------------------------------------
  task body();
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe1;
    resp_t                                              bresp0;
    resp_t                                              bresp1;
    rdata_t                                             rdata0;
    rdata_t                                             rdata1;
    resp_t                                              rresp0;
    resp_t                                              rresp1;
    int unsigned                                        issued_base;
    int unsigned                                        rsp_base;

    if (this._tb_env.u_mc.backend.get_registered_port_count() != 2) begin
      `uvm_fatal(get_name(), "vip_mc backend did not register both AXI4 ports")
    end

    if (!$cast(fe0, this._tb_env.u_mc.fes[0])) begin
      `uvm_fatal(get_name(), "vip_mc port 0 was not built as an AXI4 front-end")
    end
    if (!$cast(fe1, this._tb_env.u_mc.fes[1])) begin
      `uvm_fatal(get_name(), "vip_mc port 1 was not built as an AXI4 front-end")
    end

    this.wait_for_reset_release();
    this.wait_for_reset_release_on_port(1);

    issued_base = this._tb_env.u_mc.backend.issued_req_count;
    rsp_base    = this._tb_env.u_mc.backend.observed_rsp_count;

    this.axi4_write_single(ADDR0_C, DATA0_C, '1, bresp0);
    this.axi4_write_single_on_port(1, 'h2, 4'he, ADDR1_C, DATA1_C, '1, bresp1);

    if (bresp0 != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), "Port 0 multi-port write did not return OKAY")
    end
    if (bresp1 != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), "Port 1 multi-port write did not return OKAY")
    end

    this.axi4_read_single(ADDR0_C, rdata0, rresp0);
  this.axi4_read_single_on_port(1, 'h4, 4'he, ADDR1_C, rdata1, rresp1);

    if (rresp0 != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), "Port 0 multi-port read did not return OKAY")
    end
    if (rresp1 != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), "Port 1 multi-port read did not return OKAY")
    end
    if (rdata0 !== DATA0_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Port 0 readback mismatch exp=0x%0h got=0x%0h",
        DATA0_C,
        rdata0))
    end
    if (rdata1 !== DATA1_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Port 1 readback mismatch exp=0x%0h got=0x%0h",
        DATA1_C,
        rdata1))
    end

    if ((this._tb_env.u_mc.backend.issued_req_count - issued_base) != 4) begin
      `uvm_fatal(get_name(), "Shared backend did not issue four device requests for the two-port")
    end
    if ((this._tb_env.u_mc.backend.observed_rsp_count - rsp_base) != 4) begin
      `uvm_fatal(get_name(), "Shared backend did not observe four device responses for the two-port")
    end
    if ((fe0.observed_aw_count < 1) || (fe0.observed_ar_count < 1)) begin
      `uvm_fatal(get_name(), "Port 0 front-end did not observe both write and read traffic")
    end
    if ((fe1.observed_aw_count < 1) || (fe1.observed_ar_count < 1)) begin
      `uvm_fatal(get_name(), "Port 1 front-end did not observe both write and read traffic")
    end

    `uvm_info(get_name(), "vip_mc AXI4 multi-port test passed", UVM_LOW)
  endtask

endclass
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
// tc_mc_axi4_exclusive
//
// Active test for AXI4 exclusive access support. It checks the success
// path (exclusive read then matching exclusive write -> EXOKAY + memory update)
// and the fail path (intervening normal write -> exclusive write returns OKAY
// and does not modify memory).
// -----------------------------------------------------------------------------
class tc_mc_axi4_exclusive extends mc_base_test;

  `uvm_component_utils(tc_mc_axi4_exclusive)

  localparam longint unsigned ADDR_C = 'h03c0;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Issue one single-beat exclusive write and return BRESP.
  // ---------------------------------------------------------------------------
  protected task axi4_write_exclusive_single(
    input  longint unsigned addr,
    input  wdata_t          data,
    input  wstrb_t          strb,
    output resp_t           bresp
  );
    wdata_t write_q[];
    wstrb_t strb_q[];
    buser_t buser;

    write_q = new[1];
    strb_q  = new[1];
    write_q[0] = data;
    strb_q[0]  = strb;

    this.axi4_write_custom_user_on_port(
      0,
      'h5,
      '0,
      1'b1,
      addr,
      this.get_full_width_axi_size(),
      VIP_MC_AXI4_BURST_INCR_C,
      '0,
      '0,
      write_q,
      strb_q,
      bresp,
      buser);
  endtask

  // ---------------------------------------------------------------------------
  // Issue one single-beat exclusive read and return RDATA/RRESP.
  // ---------------------------------------------------------------------------
  protected task axi4_read_exclusive_single(
    input  longint unsigned addr,
    output rdata_t          data,
    output resp_t           rresp
  );
    rdata_t read_q[];
    resp_t  rresp_q[];
    ruser_t ruser_q[];

    this.axi4_read_custom_user_on_port(
      0,
      'h5,
      '0,
      1'b1,
      addr,
      this.get_full_width_axi_size(),
      VIP_MC_AXI4_BURST_INCR_C,
      '0,
      1,
      read_q,
      rresp_q,
      ruser_q);

    data  = read_q[0];
    rresp = rresp_q[0];
  endtask

  // ---------------------------------------------------------------------------
  // Drive exclusive traffic through vip_mc and check success/fail semantics.
  // ---------------------------------------------------------------------------
  task body();
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;
    wdata_t                                             init_data;
    wdata_t                                             success_data;
    wdata_t                                             interfering_data;
    wdata_t                                             failed_excl_data;
    rdata_t                                             read_data;
    resp_t                                              read_resp;
    resp_t                                              write_resp;
    int unsigned                                        issued_before_failed_write;

    if (!$cast(fe0, this._tb_env.u_mc.fes[0])) begin
      `uvm_fatal(get_name(), "vip_mc port 0 was not built as an AXI4 front-end")
    end

    this.wait_for_reset_release();

    init_data          = '0;
    success_data       = '0;
    interfering_data   = '0;
    failed_excl_data   = '0;
    for (int byte_idx = 0; byte_idx < VIP_MC_AXI4_CFG_C.WDATA_BYTES_P; byte_idx++) begin
      init_data[(8 * byte_idx) +: 8]        = (8'h10 + byte_idx[7:0]);
      success_data[(8 * byte_idx) +: 8]     = (8'h40 + byte_idx[7:0]);
      interfering_data[(8 * byte_idx) +: 8] = (8'h70 + byte_idx[7:0]);
      failed_excl_data[(8 * byte_idx) +: 8] = (8'hA0 + byte_idx[7:0]);
    end

    this.axi4_write_single(ADDR_C, init_data, '1, write_resp);
    if (write_resp != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), "Initial write for exclusive did not return OKAY")
    end

    this.axi4_read_exclusive_single(ADDR_C, read_data, read_resp);
    if (read_resp != VIP_MC_AXI4_RESP_EXOKAY_C) begin
      `uvm_fatal(get_name(), "Exclusive read did not return EXOKAY")
    end
    if (read_data !== init_data) begin
      `uvm_fatal(get_name(), "Exclusive read did not return the initial memory value")
    end

    this.axi4_write_exclusive_single(ADDR_C, success_data, '1, write_resp);
    if (write_resp != VIP_MC_AXI4_RESP_EXOKAY_C) begin
      `uvm_fatal(get_name(), "Successful exclusive write did not return EXOKAY")
    end

    this.axi4_read_single(ADDR_C, read_data, read_resp);
    if ((read_resp != VIP_MC_AXI4_RESP_OKAY_C) || (read_data !== success_data)) begin
      `uvm_fatal(get_name(), "Successful exclusive write did not update memory")
    end

    this.axi4_read_exclusive_single(ADDR_C, read_data, read_resp);
    if ((read_resp != VIP_MC_AXI4_RESP_EXOKAY_C) || (read_data !== success_data)) begin
      `uvm_fatal(get_name(), "Second exclusive read did not refresh the reservation")
    end

    this.axi4_write_single(ADDR_C, interfering_data, '1, write_resp);
    if (write_resp != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), "Intervening normal write did not return OKAY")
    end

    issued_before_failed_write = this._tb_env.u_mc.backend.issued_req_count;
    this.axi4_write_exclusive_single(ADDR_C, failed_excl_data, '1, write_resp);
    if (write_resp != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), "Failed exclusive write did not return OKAY")
    end
    if (this._tb_env.u_mc.backend.issued_req_count != issued_before_failed_write) begin
      `uvm_fatal(get_name(), "Failed exclusive write should not have issued a backend request")
    end

    this.axi4_read_single(ADDR_C, read_data, read_resp);
    if ((read_resp != VIP_MC_AXI4_RESP_OKAY_C) || (read_data !== interfering_data)) begin
      `uvm_fatal(get_name(), "Failed exclusive write modified memory unexpectedly")
    end

    if (this._tb_env.u_mc.get_exokay_count(0) != 3) begin
      `uvm_fatal(get_name(), $sformatf(
        "Exclusive expected 3 EXOKAY completions, saw %0d",
        this._tb_env.u_mc.get_exokay_count(0)))
    end
    if (this._tb_env.u_mc.get_excl_fail_count(0) != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Exclusive expected 1 failed exclusive write, saw %0d",
        this._tb_env.u_mc.get_excl_fail_count(0)))
    end

    `uvm_info(get_name(), "vip_mc AXI4 exclusive test passed", UVM_LOW)
  endtask

endclass
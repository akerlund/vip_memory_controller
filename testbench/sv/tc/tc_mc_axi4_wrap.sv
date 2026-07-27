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
// tc_mc_axi4_wrap
//
// Active test for AXI4 WRAP support. It drives one aligned full-width
// WRAP write/read burst through the owned interface and checks that the FE
// preserves wrapped beat order while the backend stores rows in wrap-region
// address order.
//
// The burst deliberately starts mid-region (START_BEAT_INDEX_C), so the AXI
// start address and the wrap-region base differ. Both the row order AND the
// device address are checked: the rows are indexed from the region base, so an
// access issued at the start address would place every row rotated by the start
// offset and push the last one past the region. That defect is invisible to a
// WRAP read-back - it rotates identically - which is why the address check
// below has to be explicit.
// -----------------------------------------------------------------------------
class tc_mc_axi4_wrap extends mc_base_test;

  `uvm_component_utils(tc_mc_axi4_wrap)

  localparam int BURST_BEATS_C = 4;
  localparam int START_BEAT_INDEX_C = 2;
  localparam int BEAT_BYTES_C = VIP_MC_AXI4_CFG_C.WDATA_BYTES_P;
  localparam longint unsigned WRAP_BASE_ADDR_C = 'h0200;
  localparam longint unsigned START_ADDR_C = WRAP_BASE_ADDR_C +
                                             (START_BEAT_INDEX_C * BEAT_BYTES_C);

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Drive one aligned full-width WRAP burst through vip_mc and check replay.
  // ---------------------------------------------------------------------------
  task body();
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;
    logic [2 : 0]                                       axi_size;
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
    write_data_q = new[BURST_BEATS_C];
    write_strb_q = new[BURST_BEATS_C];
    for (int beat_idx = 0; beat_idx < BURST_BEATS_C; beat_idx++) begin
      write_data_q[beat_idx] = '0;
      write_strb_q[beat_idx] = '1;
      for (int byte_idx = 0; byte_idx < VIP_MC_AXI4_CFG_C.WDATA_BYTES_P; byte_idx++) begin
        write_data_q[beat_idx][(8 * byte_idx) +: 8] = (8'h80 + (beat_idx * 8'h10) + byte_idx[7:0]);
      end
    end

    this.axi4_write_custom(
      START_ADDR_C,
      axi_size,
      VIP_MC_AXI4_BURST_WRAP_C,
      write_data_q,
      write_strb_q,
      bresp);
    if (bresp != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "AXI4 WRAP write burst returned BRESP=%0b instead of OKAY",
        bresp))
    end

    if (this._tb_env.u_mc.backend.last_issued_req.beats != BURST_BEATS_C) begin
      `uvm_fatal(get_name(), "vip_mc backend WRAP write did not preserve the expected DRAM beat count")
    end
    if (this._tb_env.u_mc.backend.last_issued_req.wdata.size() != BURST_BEATS_C) begin
      `uvm_fatal(get_name(), "vip_mc backend WRAP write did not preserve every wrapped row payload")
    end
    if (this._tb_env.u_mc.backend.last_issued_req.wdata[0] !== write_data_q[2]) begin
      `uvm_fatal(get_name(), "vip_mc backend WRAP write row 0 did not land at the wrap base")
    end
    if (this._tb_env.u_mc.backend.last_issued_req.wdata[1] !== write_data_q[3]) begin
      `uvm_fatal(get_name(), "vip_mc backend WRAP write row 1 did not land at the second wrapped address")
    end
    if (this._tb_env.u_mc.backend.last_issued_req.wdata[2] !== write_data_q[0]) begin
      `uvm_fatal(get_name(), "vip_mc backend WRAP write row 2 did not preserve the first post-start beat")
    end
    if (this._tb_env.u_mc.backend.last_issued_req.wdata[3] !== write_data_q[1]) begin
      `uvm_fatal(get_name(), "vip_mc backend WRAP write row 3 did not preserve the second post-start beat")
    end
    if (this._tb_env.u_mc.backend.last_issued_req.addr !== WRAP_BASE_ADDR_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "vip_mc backend issued the WRAP write at 0x%0h instead of the wrap-region base 0x%0h",
        this._tb_env.u_mc.backend.last_issued_req.addr, WRAP_BASE_ADDR_C))
    end

    this.axi4_read_custom(
      START_ADDR_C,
      axi_size,
      VIP_MC_AXI4_BURST_WRAP_C,
      BURST_BEATS_C,
      read_data_q,
      read_resp_q);
    foreach (read_resp_q[i]) begin
      if (read_resp_q[i] != VIP_MC_AXI4_RESP_OKAY_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "AXI4 WRAP read beat %0d returned RRESP=%0b instead of OKAY",
          i, read_resp_q[i]))
      end
      if (read_data_q[i] !== write_data_q[i]) begin
        `uvm_fatal(get_name(), $sformatf(
          "AXI4 WRAP readback mismatch on beat %0d", i))
      end
    end

    if (this._tb_env.u_mc.backend.issued_req_count != 2) begin
      `uvm_fatal(get_name(), "vip_mc backend did not issue the expected number of WRAP requests")
    end
    if (this._tb_env.u_mc.backend.observed_rsp_count != 2) begin
      `uvm_fatal(get_name(), "vip_mc backend did not observe the expected number of WRAP responses")
    end
    if (this._tb_env.u_mc.backend.last_completed_cmd.rdata.size() != BURST_BEATS_C) begin
      `uvm_fatal(get_name(), "vip_mc backend WRAP read completion did not preserve every wrapped row payload")
    end
    if (this._tb_env.u_mc.backend.last_completed_cmd.rdata[0] !== write_data_q[2]) begin
      `uvm_fatal(get_name(), "vip_mc backend WRAP read row 0 did not match the wrapped address order")
    end
    if (this._tb_env.u_mc.backend.last_completed_cmd.rdata[1] !== write_data_q[3]) begin
      `uvm_fatal(get_name(), "vip_mc backend WRAP read row 1 did not match the wrapped address order")
    end
    if (this._tb_env.u_mc.backend.last_completed_cmd.rdata[2] !== write_data_q[0]) begin
      `uvm_fatal(get_name(), "vip_mc backend WRAP read row 2 did not match the wrapped address order")
    end
    if (this._tb_env.u_mc.backend.last_completed_cmd.rdata[3] !== write_data_q[1]) begin
      `uvm_fatal(get_name(), "vip_mc backend WRAP read row 3 did not match the wrapped address order")
    end
    if (this._tb_env.u_mc.backend.last_issued_req.addr !== WRAP_BASE_ADDR_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "vip_mc backend issued the WRAP read at 0x%0h instead of the wrap-region base 0x%0h",
        this._tb_env.u_mc.backend.last_issued_req.addr, WRAP_BASE_ADDR_C))
    end

    if (fe0.issued_req_count != 2) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not issue the expected number of WRAP requests")
    end
    if ((fe0.last_issued.axi_beats != BURST_BEATS_C) || (fe0.last_issued.beats != BURST_BEATS_C)) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not preserve the WRAP AXI-to-DRAM beat mapping")
    end
    if (fe0.complete_count != 2) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not observe the expected number of WRAP completions")
    end
    if ((fe0.observed_aw_count != 1) || (fe0.observed_w_count != BURST_BEATS_C) || (fe0.observed_ar_count != 1)) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not count the expected WRAP channel handshakes")
    end

    `uvm_info(get_name(), "vip_mc AXI4 WRAP test passed", UVM_LOW)
  endtask

endclass
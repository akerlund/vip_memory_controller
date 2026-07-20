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
// tc_vip_mc_axi4_burst
//
// Active test for the widened vip_mc AXI4 datapath slice. It drives one
// aligned, full-width INCR write burst and one matching read burst through the
// owned interface and checks beat-for-beat data replay plus FE/backend counters.
// -----------------------------------------------------------------------------
class tc_vip_mc_axi4_burst extends vip_mc_base_test;

  `uvm_component_utils(tc_vip_mc_axi4_burst)

  localparam int BURST_BEATS_C = 4;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Drive one aligned full-width INCR burst through vip_mc and check replay.
  // ---------------------------------------------------------------------------
  task body();
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;
    wdata_t write_data_q[];
    wstrb_t write_strb_q[];
    rdata_t read_data_q[];
    resp_t  read_resp_q[];
    resp_t  bresp;

    if (!$cast(fe0, this._tb_env.u_mc.fes[0])) begin
      `uvm_fatal(get_name(), "vip_mc port 0 was not built as an AXI4 front-end")
    end

    this.wait_for_reset_release();

    write_data_q = new[BURST_BEATS_C];
    write_strb_q = new[BURST_BEATS_C];
    for (int beat_idx = 0; beat_idx < BURST_BEATS_C; beat_idx++) begin
      write_data_q[beat_idx] = '0;
      write_strb_q[beat_idx] = '1;
      for (int byte_idx = 0; byte_idx < VIP_MC_AXI4_CFG_C.WDATA_BYTES_P; byte_idx++) begin
        write_data_q[beat_idx][(8 * byte_idx) +: 8] = (8'h40 + (beat_idx * 8'h10) + byte_idx[7:0]);
      end
    end

    this.axi4_write_burst('h0200, write_data_q, write_strb_q, bresp);
    if (bresp != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Aligned AXI4 write burst returned BRESP=%0b instead of OKAY",
        bresp))
    end

    this.axi4_read_burst('h0200, BURST_BEATS_C, read_data_q, read_resp_q);
    foreach (read_resp_q[i]) begin
      if (read_resp_q[i] != VIP_MC_AXI4_RESP_OKAY_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "Aligned AXI4 read burst beat %0d returned RRESP=%0b instead of OKAY",
          i, read_resp_q[i]))
      end
      if (read_data_q[i] !== write_data_q[i]) begin
        `uvm_fatal(get_name(), $sformatf(
          "AXI4 burst readback mismatch on beat %0d", i))
      end
    end

    if (this._tb_env.u_mc.backend.issued_req_count != 2) begin
      `uvm_fatal(get_name(), "vip_mc backend did not issue the expected number of burst requests")
    end

    if (this._tb_env.u_mc.backend.last_issued_req.beats != BURST_BEATS_C) begin
      `uvm_fatal(get_name(), "vip_mc backend last request did not preserve the burst beat count")
    end

    if (this._tb_env.u_mc.backend.observed_rsp_count != 2) begin
      `uvm_fatal(get_name(), "vip_mc backend did not observe the expected number of burst responses")
    end

    if (this._tb_env.u_mc.backend.last_completed_cmd.rdata.size() != BURST_BEATS_C) begin
      `uvm_fatal(get_name(), "vip_mc backend last completed read did not preserve every burst beat")
    end

    if (fe0.issued_req_count != 2) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not issue the expected number of burst requests")
    end

    if (fe0.last_issued.beats != BURST_BEATS_C) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end last issued request did not preserve the burst beat count")
    end

    if (fe0.complete_count != 2) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not observe the expected number of burst completions")
    end

    if ((fe0.observed_aw_count != 1) || (fe0.observed_w_count != BURST_BEATS_C) || (fe0.observed_ar_count != 1)) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not count the expected burst-channel handshakes")
    end

    `uvm_info(get_name(), "vip_mc AXI4 burst test passed", UVM_LOW)
  endtask

endclass
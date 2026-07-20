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
// tc_vip_mc_axi4_wready_backpressure
//
// Smoke test for bounded W-data ingress backpressure. It constrains the model
// to one W-buffer slot, drives a 2-beat burst, and proves that WREADY drops
// between beats before the burst completes.
// -----------------------------------------------------------------------------
class tc_vip_mc_axi4_wready_backpressure extends vip_mc_base_test;

  `uvm_component_utils(tc_vip_mc_axi4_wready_backpressure)

  localparam longint unsigned BASE_ADDR_C = 'h0900;
  localparam int BURST_BEATS_C = 2;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Force a one-slot W buffer so WREADY backpressure is observable.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    uvm_config_db #(int)::set(this, "env", "mc_w_data_buf_depth", 1);
    super.build_phase(phase);
  endfunction

  // ---------------------------------------------------------------------------
  // Stall between two write beats via the bounded W ingress and verify data.
  // ---------------------------------------------------------------------------
  task body();
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;
    wdata_t                                             write_q[];
    wstrb_t                                             strb_q[];
    rdata_t                                             read_q[];
    resp_t                                              read_resp_q[];
    resp_t                                              bresp;
    int unsigned                                        stall_base;

    if (!$cast(fe0, this._tb_env.u_mc.fes[0])) begin
      `uvm_fatal(get_name(), "vip_mc port 0 was not built as an AXI4 front-end")
    end

    this.wait_for_reset_release();
    stall_base = fe0.get_wready_stall_cycles();

    write_q = new[BURST_BEATS_C];
    strb_q  = new[BURST_BEATS_C];
    write_q[0] = 'h1111_2222_3333_4444;
    write_q[1] = 'h5555_6666_7777_8888;
    strb_q[0]  = '1;
    strb_q[1]  = '1;

    this.axi4_write_burst(BASE_ADDR_C, write_q, strb_q, bresp);

    if (bresp != VIP_MC_AXI4_RESP_OKAY_C) begin
      `uvm_fatal(get_name(), "WREADY backpressure test write burst did not return OKAY")
    end

    if (fe0.get_wready_stall_cycles() <= stall_base) begin
      `uvm_fatal(get_name(), "WREADY never backpressured the stock manager burst with mc_w_data_buf_depth=1")
    end

    this.axi4_read_burst(BASE_ADDR_C, BURST_BEATS_C, read_q, read_resp_q);

    if (read_q.size() != BURST_BEATS_C) begin
      `uvm_fatal(get_name(), "WREADY backpressure test readback did not return the full burst")
    end
    for (int beat_idx = 0; beat_idx < BURST_BEATS_C; beat_idx++) begin
      if (read_resp_q[beat_idx] != VIP_MC_AXI4_RESP_OKAY_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "Readback beat %0d returned RRESP=%0b instead of OKAY",
          beat_idx,
          read_resp_q[beat_idx]))
      end
      if (read_q[beat_idx] !== write_q[beat_idx]) begin
        `uvm_fatal(get_name(), $sformatf(
          "Readback beat %0d mismatch exp=0x%0h got=0x%0h",
          beat_idx,
          write_q[beat_idx],
          read_q[beat_idx]))
      end
    end

    if (fe0.observed_w_count != BURST_BEATS_C) begin
      `uvm_fatal(get_name(), "vip_mc AXI4 front-end did not observe both W handshakes")
    end

    `uvm_info(get_name(), "vip_mc WREADY backpressure test passed", UVM_LOW)
  endtask

endclass
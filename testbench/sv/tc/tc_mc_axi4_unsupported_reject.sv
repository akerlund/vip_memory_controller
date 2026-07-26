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
// tc_mc_axi4_unsupported_reject
//
// Explicit reject coverage for AXI4 transfer shapes the current slice does not
// support. The frontend must terminate them locally with SLVERR and must not
// forward any request into the backend or vip_dram.
// -----------------------------------------------------------------------------
class tc_mc_axi4_unsupported_reject extends mc_base_test;

  `uvm_component_utils(tc_mc_axi4_unsupported_reject)

  localparam int              UNSUPPORTED_FIXED_BEATS_C = 17;
  localparam logic [3 : 0]    BAD_EXCL_ARCACHE_C       = 4'b1111;
  localparam longint unsigned WRITE_ADDR_C             = 'h0400;
  localparam longint unsigned READ_ADDR_C              = 'h0800;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Issue one single-beat exclusive read with an unsupported ARCACHE encoding.
  // ---------------------------------------------------------------------------
  protected task axi4_read_exclusive_bad_cache_single(
    input  longint unsigned addr,
    output rdata_t          data,
    output resp_t           rresp
  );
    vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)           rd_seq;
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;
    axi4_item_t                                          rd_rsp_q[$];

    fe0 = this.get_port_fe(0);

    rd_seq = vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)::type_id::create(
      "unsupported_excl_bad_cache_rd");
    rd_seq.reset();
    rd_seq.set_arid('he);
    rd_seq.set_axaddr(addr);
    rd_seq.set_axlen(0);
    rd_seq.set_axsize(this.get_full_width_axi_size());
    rd_seq.set_axburst(VIP_MC_AXI4_BURST_INCR_C);
    rd_seq.set_axlock(1'b1);
    rd_seq.set_arcache(BAD_EXCL_ARCACHE_C);
    rd_seq.set_axqos(4'h2);
    rd_seq.set_requests(1);
    rd_seq.set_get_rd_response(1'b1);
    this.start_seq_or_timeout(
      rd_seq,
      this._tb_env.man_agent[0].sequencer,
      fe0,
      0,
      rd_seq.get_name());

    rd_rsp_q = rd_seq.get_rd_responses();
    if (rd_rsp_q.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Unsupported exclusive read returned %0d responses instead of 1",
        rd_rsp_q.size()))
    end
    if (rd_rsp_q[0].rdata.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Unsupported exclusive read returned %0d beats instead of 1",
        rd_rsp_q[0].rdata.size()))
    end

    data  = this.flatten_read_beat(rd_rsp_q[0], 0);
    rresp = rd_rsp_q[0].rresp;
  endtask

  task body();
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;
    logic [2 : 0]                                       axi_size;
    wdata_t                                             write_data_q[];
    wstrb_t                                             write_strb_q[];
    rdata_t                                             read_data;
    resp_t                                              bresp;
    resp_t                                              rresp;
    int unsigned                                        issued_before_write;
    int unsigned                                        issued_before_read;
    int unsigned                                        fe_issued_before_write;
    int unsigned                                        fe_issued_before_read;

    if (!$cast(fe0, this._tb_env.u_mc.fes[0])) begin
      `uvm_fatal(get_name(), "vip_mc port 0 was not built as an AXI4 front-end")
    end

    this.wait_for_reset_release();

    axi_size = this.get_full_width_axi_size();
    write_data_q = new[UNSUPPORTED_FIXED_BEATS_C];
    write_strb_q = new[UNSUPPORTED_FIXED_BEATS_C];
    for (int beat_idx = 0; beat_idx < UNSUPPORTED_FIXED_BEATS_C; beat_idx++) begin
      write_data_q[beat_idx] = '0;
      write_strb_q[beat_idx] = '1;
      for (int byte_idx = 0; byte_idx < VIP_MC_AXI4_CFG_C.WDATA_BYTES_P; byte_idx++) begin
        write_data_q[beat_idx][(8 * byte_idx) +: 8] =
          8'h40 + beat_idx[7:0] + byte_idx[7:0];
      end
    end

    issued_before_write    = this._tb_env.u_mc.backend.issued_req_count;
    fe_issued_before_write = fe0.issued_req_count;
    this.axi4_write_fixed_custom(WRITE_ADDR_C, axi_size, write_data_q, write_strb_q, bresp);
    if (bresp != VIP_MC_AXI4_RESP_SLVERR_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Unsupported FIXED write returned BRESP=%0b instead of SLVERR",
        bresp))
    end
    if (this._tb_env.u_mc.backend.issued_req_count != issued_before_write) begin
      `uvm_fatal(get_name(), "Unsupported FIXED write should not have been forwarded into vip_dram")
    end
    if (fe0.issued_req_count != fe_issued_before_write) begin
      `uvm_fatal(get_name(), "Unsupported FIXED write should not have incremented the FE-issued request count")
    end
    if (!fe0.last_completed.pre_resolved ||
        (fe0.last_completed.resp != VIP_MC_AXI4_RESP_SLVERR_C)) begin
      `uvm_fatal(get_name(), "Unsupported FIXED write did not complete as a pre-resolved SLVERR")
    end

    issued_before_read    = this._tb_env.u_mc.backend.issued_req_count;
    fe_issued_before_read = fe0.issued_req_count;
    this.axi4_read_exclusive_bad_cache_single(READ_ADDR_C, read_data, rresp);
    if (rresp != VIP_MC_AXI4_RESP_SLVERR_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Unsupported exclusive read returned RRESP=%0b instead of SLVERR",
        rresp))
    end
    if (read_data !== '0) begin
      `uvm_fatal(get_name(), "Unsupported exclusive read returned non-zero data")
    end
    if (this._tb_env.u_mc.backend.issued_req_count != issued_before_read) begin
      `uvm_fatal(get_name(), "Unsupported exclusive read should not have been forwarded into vip_dram")
    end
    if (fe0.issued_req_count != fe_issued_before_read) begin
      `uvm_fatal(get_name(), "Unsupported exclusive read should not have incremented the FE-issued request count")
    end
    if (!fe0.last_completed.pre_resolved ||
        (fe0.last_completed.resp != VIP_MC_AXI4_RESP_SLVERR_C)) begin
      `uvm_fatal(get_name(), "Unsupported exclusive read did not complete as a pre-resolved SLVERR")
    end

    if (this._tb_env.u_mc.backend.issued_req_count != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "Unsupported reject test expected 0 backend issues, saw %0d",
        this._tb_env.u_mc.backend.issued_req_count))
    end
    if (this._tb_env.u_mc.backend.observed_rsp_count != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "Unsupported reject test expected 0 DRAM responses, saw %0d",
        this._tb_env.u_mc.backend.observed_rsp_count))
    end
    if (fe0.issued_req_count != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "Unsupported reject test expected 0 FE-issued backend requests, saw %0d",
        fe0.issued_req_count))
    end
    if (fe0.complete_count != 2) begin
      `uvm_fatal(get_name(), $sformatf(
        "Unsupported reject test expected 2 FE completions, saw %0d",
        fe0.complete_count))
    end
    if ((fe0.observed_aw_count != 1) ||
        (fe0.observed_w_count != UNSUPPORTED_FIXED_BEATS_C) ||
        (fe0.observed_ar_count != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "Unsupported reject test saw unexpected channel handshakes: AW=%0d W=%0d AR=%0d",
        fe0.observed_aw_count,
        fe0.observed_w_count,
        fe0.observed_ar_count))
    end

    `uvm_info(get_name(),
      "vip_mc AXI4 unsupported reject test passed (SLVERR responses stayed FE-local)",
      UVM_LOW)
  endtask

endclass
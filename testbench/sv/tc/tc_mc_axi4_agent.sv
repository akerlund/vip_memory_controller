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
// tc_mc_axi4_agent
//
// Focused for the stock-manager-driven vip_mc example path. It drives the
// stock vip_axi4 agents connected 1:1 into vip_mc's owned interfaces.
// -----------------------------------------------------------------------------
class tc_mc_axi4_agent extends mc_base_test;

  `uvm_component_utils(tc_mc_axi4_agent)

  typedef vip_axi4_item #(VIP_AXI4_AGENT_CFG_C) axi4_item_t;
  typedef logic [(8 * DRAM_CFG_C.ROW_BYTES_P) - 1 : 0] dram_row_t;

  localparam int unsigned SEQ_TIMEOUT_CYCLES_C = 256;
  localparam longint unsigned ADDR0_C = 'h0A00;
  localparam longint unsigned ADDR1_C = 'h0B00;
  localparam wdata_t          DATA0_C = 'h0102_0304_0506_0708;
  localparam wdata_t          DATA1_C = 'hA1A2_A3A4_A5A6_A7A8;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Enable the stock manager agents for this test.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    uvm_config_db #(int)::set(this, "env", "manager_agents_active", 1);
    super.build_phase(phase);
  endfunction

  // ---------------------------------------------------------------------------
  // Flatten one beat of sequence-returned RDATA into the packed local alias.
  // ---------------------------------------------------------------------------
  protected function rdata_t flatten_read_beat(
    input vip_axi4_item #(VIP_AXI4_AGENT_CFG_C) rsp,
    input int unsigned                          beat_idx
  );
    rdata_t flat_rdata;

    flat_rdata = '0;
    if (rsp.rdata.size() <= beat_idx) begin
      return flat_rdata;
    end

    for (int byte_idx = 0; byte_idx < VIP_AXI4_AGENT_CFG_C.RDATA_BYTES_P; byte_idx++) begin
      flat_rdata[(8 * byte_idx) +: 8] = rsp.rdata[beat_idx][byte_idx];
    end

    return flat_rdata;
  endfunction

  // ---------------------------------------------------------------------------
  // Start one stock AXI4 sequence and fail fast with local handshake state if
  // the bus stalls.
  // ---------------------------------------------------------------------------
  protected task start_seq_or_timeout(
    input uvm_sequence_base                               seq,
    input uvm_sequencer_base                              sequencer,
    input vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe,
    input int unsigned                                    port_id,
    input string                                          seq_name
  );
    bit seq_done;

    seq_done = 1'b0;
    fork
      begin
        seq.start(sequencer);
        seq_done = 1'b1;
      end
      begin
        repeat (SEQ_TIMEOUT_CYCLES_C) @(posedge this._mc_vif.clk);
        if (!seq_done) begin
          `uvm_fatal(get_name(), $sformatf(
            "%s timed out on port %0d after %0d cycles man{awv=%0b awr=%0b wv=%0b wr=%0b bv=%0b br=%0b arv=%0b arr=%0b rv=%0b rr=%0b} mc{awv=%0b awr=%0b wv=%0b wr=%0b bv=%0b br=%0b arv=%0b arr=%0b rv=%0b rr=%0b} fe{obs_aw=%0d obs_w=%0d obs_ar=%0d inflight_wr=%0d inflight_rd=%0d complete=%0d decerr=%0d 4k=%0d}",
            seq_name,
            port_id,
            SEQ_TIMEOUT_CYCLES_C,
            this._tb_env._man_vif[port_id].awvalid,
            this._tb_env._man_vif[port_id].awready,
            this._tb_env._man_vif[port_id].wvalid,
            this._tb_env._man_vif[port_id].wready,
            this._tb_env._man_vif[port_id].bvalid,
            this._tb_env._man_vif[port_id].bready,
            this._tb_env._man_vif[port_id].arvalid,
            this._tb_env._man_vif[port_id].arready,
            this._tb_env._man_vif[port_id].rvalid,
            this._tb_env._man_vif[port_id].rready,
            this._tb_env._mc_vif[port_id].awvalid,
            this._tb_env._mc_vif[port_id].awready,
            this._tb_env._mc_vif[port_id].wvalid,
            this._tb_env._mc_vif[port_id].wready,
            this._tb_env._mc_vif[port_id].bvalid,
            this._tb_env._mc_vif[port_id].bready,
            this._tb_env._mc_vif[port_id].arvalid,
            this._tb_env._mc_vif[port_id].arready,
            this._tb_env._mc_vif[port_id].rvalid,
            this._tb_env._mc_vif[port_id].rready,
            fe.observed_aw_count,
            fe.observed_w_count,
            fe.observed_ar_count,
            fe.inflight_wr_count,
            fe.inflight_rd_count,
            fe.complete_count,
            fe.get_decerr_count(),
            fe.get_4k_violation_count()))
        end
      end
    join_any
    disable fork;
  endtask

  // ---------------------------------------------------------------------------
  // Drive one manager write sequence per port and check the written DRAM rows.
  // ---------------------------------------------------------------------------
  task body();
    vip_axi4_write_seq #(VIP_AXI4_AGENT_CFG_C) wr_seq0;
    vip_axi4_write_seq #(VIP_AXI4_AGENT_CFG_C) wr_seq1;
    axi4_item_t                             wr_rsp_q[$];
    wdata_t                                 write_q[$];
    wstrb_t                                 strb_q[$];
    dram_row_t                              read_data;
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe1;
    int unsigned                            issued_base;

    if (!$cast(fe0, this._tb_env.u_mc.fes[0])) begin
      `uvm_fatal(get_name(), "vip_mc port 0 was not built as an AXI4 front-end")
    end
    if (!$cast(fe1, this._tb_env.u_mc.fes[1])) begin
      `uvm_fatal(get_name(), "vip_mc port 1 was not built as an AXI4 front-end")
    end

    this.wait_for_reset_release();

    issued_base = this._tb_env.u_mc.backend.issued_req_count;

    write_q.delete();
    strb_q.delete();
    write_q.push_back(DATA0_C);
    strb_q.push_back('1);

    wr_seq0 = vip_axi4_write_seq #(VIP_AXI4_AGENT_CFG_C)::type_id::create("wr_seq0");
    wr_seq0.reset();
    wr_seq0.set_axaddr(ADDR0_C);
    wr_seq0.set_axlen(0);
    wr_seq0.set_axsize(this.get_full_width_axi_size());
    wr_seq0.set_axburst(VIP_AXI4_BURST_INCR_C);
    wr_seq0.set_requests(1);
    wr_seq0.set_get_wr_response(1'b1);
    wr_seq0.set_wdata_type(VIP_AXI4_DATA_CUSTOM_E);
    wr_seq0.set_wstrb_type(VIP_AXI4_STRB_CUSTOM_E);
    wr_seq0.set_wdata(write_q);
    wr_seq0.set_wstrb(strb_q);
    this.start_seq_or_timeout(
      wr_seq0,
      this._tb_env.man_agent[0].sequencer,
      fe0,
      0,
      "wr_seq0");
    wr_rsp_q = wr_seq0.get_wr_responses();
    if ((wr_rsp_q.size() != 1) || (wr_rsp_q[0].bresp != VIP_AXI4_RESP_OK_C)) begin
      `uvm_fatal(get_name(), "Stock manager port 0 write did not return OKAY")
    end

    write_q.delete();
    strb_q.delete();
    write_q.push_back(DATA1_C);
    strb_q.push_back('1);

    wr_seq1 = vip_axi4_write_seq #(VIP_AXI4_AGENT_CFG_C)::type_id::create("wr_seq1");
    wr_seq1.reset();
    wr_seq1.set_axaddr(ADDR1_C);
    wr_seq1.set_axlen(0);
    wr_seq1.set_axsize(this.get_full_width_axi_size());
    wr_seq1.set_axburst(VIP_AXI4_BURST_INCR_C);
    wr_seq1.set_requests(1);
    wr_seq1.set_get_wr_response(1'b1);
    wr_seq1.set_wdata_type(VIP_AXI4_DATA_CUSTOM_E);
    wr_seq1.set_wstrb_type(VIP_AXI4_STRB_CUSTOM_E);
    wr_seq1.set_wdata(write_q);
    wr_seq1.set_wstrb(strb_q);
    this.start_seq_or_timeout(
      wr_seq1,
      this._tb_env.man_agent[1].sequencer,
      fe1,
      1,
      "wr_seq1");
    wr_rsp_q = wr_seq1.get_wr_responses();
    if ((wr_rsp_q.size() != 1) || (wr_rsp_q[0].bresp != VIP_AXI4_RESP_OK_C)) begin
      `uvm_fatal(get_name(), "Stock manager port 1 write did not return OKAY")
    end

    wait (this._tb_env.u_mc.backend.issued_req_count >= (issued_base + 2));

    read_data = this._tb_env.dram.backdoor_read(ADDR0_C);
    if (read_data !== DATA0_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Stock manager port 0 backdoor mismatch exp=0x%0h got=0x%0h",
        DATA0_C,
        read_data))
    end

    read_data = this._tb_env.dram.backdoor_read(ADDR1_C);
    if (read_data !== DATA1_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Stock manager port 1 backdoor mismatch exp=0x%0h got=0x%0h",
        DATA1_C,
        read_data))
    end

    if ((this._tb_env.u_mc.backend.issued_req_count - issued_base) < 2) begin
      `uvm_fatal(get_name(), "vip_mc backend did not issue at least two write requests for the stock-agent")
    end

    `uvm_info(get_name(), "vip_mc stock manager-agent test passed", UVM_LOW)
  endtask

endclass
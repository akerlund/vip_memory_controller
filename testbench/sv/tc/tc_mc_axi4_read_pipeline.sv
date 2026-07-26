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
// tc_mc_axi4_read_pipeline
//
// Multiple-outstanding reads (the read-side mirror of the pipelined write path).
// With man_rd_outstanding_max > 1 the stock manager keeps several reads in flight
// (AR issued, R not yet complete), so AR gets ahead of R. This test seeds N lines
// with distinct patterns, then issues N reads-with-response through one
// vip_axi4_pipelined_seq (set_pipelined_send), and checks:
//   * all N reads return their own correct data (matched per item),
//   * the reads genuinely overlapped — the FE's peak in-flight read count > 1
//     (a strictly serial manager would never exceed 1).
// -----------------------------------------------------------------------------
class tc_mc_axi4_read_pipeline extends mc_base_test;

  `uvm_component_utils(tc_mc_axi4_read_pipeline)

  localparam int              N_READS_C        = 6;
  localparam int              RD_OUTSTANDING_C = 6;
  localparam longint unsigned RD_ID_BASE_C     = 'h1;

  typedef vip_axi4_item          #(VIP_AXI4_AGENT_CFG_C) man_item_t;
  typedef vip_axi4_pipelined_seq #(VIP_AXI4_AGENT_CFG_C) pl_seq_t;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(input uvm_phase phase);
    uvm_config_db #(int)::set(this, "env", "mc_refresh_enabled", 0);
    uvm_config_db #(int)::set(this, "env", "mc_scoreboard_enabled", 0);
    // Let the stock manager keep several reads outstanding (pipelined read path).
    uvm_config_db #(int)::set(this, "env", "man_rd_outstanding_max", RD_OUTSTANDING_C);
    super.build_phase(phase);
  endfunction

  protected function longint unsigned encode_addr(
    input int row,
    input int bg,
    input int bank
  );
    vip_dram_dec_t dec;
    dec = '{default: 0};
    dec.row  = row;
    dec.bg   = bg;
    dec.bank = bank;
    return vip_dram_encode_addr(dec, DRAM_CFG_C, this._tb_env.u_mc.cfg.addr_map_policy);
  endfunction

  protected function longint unsigned read_addr(input int i);
    return this.encode_addr(.row(i), .bg(i % 4), .bank(0));
  endfunction

  // Deterministic per-line seed pattern.
  protected function vip_dram_types #(DRAM_CFG_C)::data_t seed_pattern(input int i);
    vip_dram_types #(DRAM_CFG_C)::data_t d;
    d = '0;
    for (int b = 0; b < DRAM_CFG_C.ROW_BYTES_P; b++) begin
      d[(8 * b) +: 8] = 8'h10 * i[3:0] + b[7:0];
    end
    return d;
  endfunction

  protected function man_item_t make_read(input int i);
    man_item_t rd;
    rd = man_item_t::type_id::create($sformatf("pl_rd_%0d", i));
    rd.set_access(VIP_AXI4_RD_REQUEST_E);
    rd.set_rd_rsp(vip_mem_types_pkg::TRUE);
    rd.arid    = RD_ID_BASE_C + i;
    rd.araddr  = this.read_addr(i);
    rd.arlen   = 0;
    rd.arsize  = this.get_full_width_axi_size();
    rd.arburst = VIP_MC_AXI4_BURST_INCR_C;
    return rd;
  endfunction

  task body();
    pl_seq_t   seq;
    man_item_t rd_rsps[$];
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;
    int  peak_inflight;
    bit  sampling;

    this.wait_for_reset_release();
    fe0 = this.get_port_fe(0);

    // Seed the N lines with distinct patterns.
    for (int i = 0; i < N_READS_C; i++) begin
      this._tb_env.dram.backdoor_write(this.read_addr(i), this.seed_pattern(i));
    end

    // Sample the FE's in-flight read count while the pipelined reads run.
    peak_inflight = 0;
    sampling      = 1'b1;
    fork
      begin
        while (sampling) begin
          @(posedge this._tb_env._man_vif[0].clk);
          if (fe0.inflight_rd_count > peak_inflight) begin
            peak_inflight = fe0.inflight_rd_count;
          end
        end
      end
    join_none

    seq = pl_seq_t::type_id::create("read_pl_seq");
    for (int i = 0; i < N_READS_C; i++) begin
      seq.add_item(this.make_read(i));
    end
    seq.set_pipelined_send(vip_mem_types_pkg::TRUE);
    seq.set_collect_rd_responses(vip_mem_types_pkg::TRUE);
    seq.start(this._tb_env.man_agent[0].sequencer);

    sampling = 1'b0;

    // All N reads must return their own correct data (collected in item order).
    rd_rsps = seq.rd_responses;
    if (rd_rsps.size() != N_READS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Expected %0d read responses, got %0d", N_READS_C, rd_rsps.size()))
    end
    foreach (rd_rsps[i]) begin
      vip_dram_types #(DRAM_CFG_C)::data_t exp;
      exp = this.seed_pattern(i);
      if (rd_rsps[i].rresp != VIP_MC_AXI4_RESP_OKAY_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "Read %0d returned RRESP=%0b instead of OKAY", i, rd_rsps[i].rresp))
      end
      if (rd_rsps[i].rdata.size() != 1) begin
        `uvm_fatal(get_name(), $sformatf(
          "Read %0d returned %0d beats instead of 1", i, rd_rsps[i].rdata.size()))
      end
      for (int b = 0; b < DRAM_CFG_C.ROW_BYTES_P; b++) begin
        if (rd_rsps[i].rdata[0][b] !== exp[(8 * b) +: 8]) begin
          `uvm_fatal(get_name(), $sformatf(
            "Read %0d byte %0d = 0x%0h, expected 0x%0h",
            i, b, rd_rsps[i].rdata[0][b], exp[(8 * b) +: 8]))
        end
      end
    end

    // A strictly serial manager never exceeds 1 read in flight; pipelining must.
    if (peak_inflight < 2) begin
      `uvm_fatal(get_name(), $sformatf(
        "Expected peak in-flight reads > 1 (pipelined), saw %0d", peak_inflight))
    end

    `uvm_info(get_name(), $sformatf(
      "vip_mc AXI4 read-pipelining test passed (%0d reads, peak %0d in flight, all data correct)",
      N_READS_C, peak_inflight), UVM_LOW)
  endtask
endclass

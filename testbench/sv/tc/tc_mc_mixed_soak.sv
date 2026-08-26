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
// tc_mc_mixed_soak
//
// Randomized mixed-protocol soak: one vip_mc has an AXI4 port and a CHI-D port,
// both sharing one backend and one vip_dram. Each protocol replays a generated
// read/write stream concurrently with the other. The streams use disjoint line
// windows, so each protocol can update its own byte-addressed model in issue
// order while the shared backend still has to arbitrate the requests.
//
// The generator keeps CHI-D full-line and line-aligned, while AXI4 varies the
// legal FIXED/INCR/WRAP burst shape, beat size, length, and sub-line offset. It
// also randomizes direction, address, ID, QoS, inter-request gap, and write
// data. The default is 32000 transactions per port, calibrated to approximately
// a 60-second VCS run on the reference workstation.
// Use +MC_MIXED_SOAK_SEED=<n> and +MC_MIXED_SOAK_TXNS=<n> to reproduce or
// shorten a run. The count is per port.
// -----------------------------------------------------------------------------
class tc_mc_mixed_soak extends mc_neutral_base_test;

  `uvm_component_utils(tc_mc_mixed_soak)

  localparam int unsigned REQUESTS_C = 32000;

  mc_mixed_tb_env       _env;
  mc_mixed_soak_gen     _gen;
  mc_equiv_model        _axi_model;
  mc_equiv_model        _chi_model;
  mc_mixed_soak_txn_t   _axi_txns [$];
  mc_mixed_soak_txn_t   _chi_txns [$];

  int unsigned _writes [2];
  int unsigned _reads  [2];

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
    this._phase_timeout = 10ms;
  endfunction

  function void build_phase(input uvm_phase phase);
    super.build_phase(phase);
    this._env = mc_mixed_tb_env::type_id::create("env", this);
  endfunction

  protected function uvm_sequencer_base get_clk_sequencer();
    return this._env.clk_agent.sequencer;
  endfunction

  protected function void report_telemetry(input string tag);
    if ((this._env == null) || (this._env.u_mc == null)) begin
      return;
    end
    `uvm_info(tag, this._env.u_mc.sprint_telemetry(), UVM_LOW)
  endfunction

  task body();
    int unsigned count_per_port;
    longint unsigned seed;

    count_per_port = REQUESTS_C;
    void'($value$plusargs("MC_MIXED_SOAK_TXNS=%d", count_per_port));
    seed = 64'd1;
    void'($value$plusargs("MC_MIXED_SOAK_SEED=%d", seed));

    this._gen = mc_mixed_soak_gen::type_id::create("gen");
    this._gen.line_bytes = VIP_MC_AXI4_CFG_C.WDATA_BYTES_P;
    this._gen.set_seed(seed);
    this._gen.generate_program(count_per_port, this._axi_txns, this._chi_txns);

    this._axi_model = mc_equiv_model::type_id::create("axi_model");
    this._chi_model = mc_equiv_model::type_id::create("chi_model");
    this._axi_model.clear();
    this._chi_model.clear();
    this._writes = '{0, 0};
    this._reads  = '{0, 0};

    `uvm_info(get_name(), $sformatf(
      "Mixed soak: %0d transactions per port, seed %0d, AXI4 + CHI-D concurrent",
      count_per_port, seed), UVM_LOW)

    if (this._env.rni_agent.vif.rst_n !== 1'b1) begin
      @(posedge this._env.rni_agent.vif.rst_n);
    end
    repeat (20) @(posedge this._env.rni_agent.vif.clk);

    fork
      this.run_axi4();
      this.run_chi();
    join

    `uvm_info(get_name(), $sformatf(
      "Mixed soak complete: AXI4 %0d writes / %0d reads, CHI-D %0d writes / %0d reads",
      this._writes[0], this._reads[0], this._writes[1], this._reads[1]), UVM_LOW)
  endtask

  protected task run_axi4();
    vip_axi4_write_seq #(VIP_AXI4_AGENT_CFG_C)      wr_seq;
    vip_axi4_read_seq  #(VIP_AXI4_AGENT_CFG_C)      rd_seq;
    vip_axi4_item      #(VIP_AXI4_AGENT_CFG_C)      wrsp [$];
    vip_axi4_item      #(VIP_AXI4_AGENT_CFG_C)      rrsp [$];
    vip_axi4_types #(VIP_AXI4_AGENT_CFG_C)::wdata_t word;
    vip_axi4_types #(VIP_AXI4_AGENT_CFG_C)::wdata_t wdata_q [$];
    vip_axi4_types #(VIP_AXI4_AGENT_CFG_C)::wstrb_t wstrb_q [$];
    vip_axi4_types #(VIP_AXI4_AGENT_CFG_C)::wstrb_t strb_word;
    byte unsigned beat_bytes [];
    byte unsigned got [];
    bit beat_be [];
    int unsigned nb;
    int unsigned size;
    int unsigned lane;
    longint unsigned ba;

    nb = VIP_MC_AXI4_CFG_C.WDATA_BYTES_P;

    foreach (this._axi_txns[i]) begin
      repeat (this._axi_txns[i].gap_cycles) @(negedge this._env._man_vif.clk);

      if (this._axi_txns[i].is_write) begin
        wdata_q.delete();
        wstrb_q.delete();
        size = $clog2(this._axi_txns[i].size_bytes);
        for (int b = 0; b < this._axi_txns[i].beats; b++) begin
          ba        = mc_mixed_soak_gen::beat_addr(this._axi_txns[i], b);
          lane      = int'(ba % nb);
          word      = '0;
          strb_word = '0;
          for (int k = 0; k < this._axi_txns[i].size_bytes; k++) begin
            word[(8 * (lane + k)) +: 8] =
              this._axi_txns[i].payload[(b * this._axi_txns[i].size_bytes) + k];
            strb_word[lane + k] = 1'b1;
          end
          wdata_q.push_back(word);
          wstrb_q.push_back(strb_word);
        end

        wr_seq = vip_axi4_write_seq #(VIP_AXI4_AGENT_CFG_C)::type_id::create(
          $sformatf("axi4_soak_wr_%0d", i));
        wr_seq.set_awid(this._axi_txns[i].axi_id);
        wr_seq.set_axaddr(this._axi_txns[i].addr);
        wr_seq.set_axlen(this._axi_txns[i].beats - 1);
        wr_seq.set_axsize(3'(size));
        wr_seq.set_axburst(this._axi_txns[i].burst);
        wr_seq.set_axqos(this._axi_txns[i].qos);
        wr_seq.set_requests(1);
        wr_seq.set_get_wr_response(1'b1);
        wr_seq.set_wdata_type(VIP_AXI4_DATA_CUSTOM_E);
        wr_seq.set_wstrb_type(VIP_AXI4_STRB_CUSTOM_E);
        wr_seq.set_wdata(wdata_q);
        wr_seq.set_wstrb(wstrb_q);
        wr_seq.start(this._env.man_agent.sequencer);
        wrsp = wr_seq.get_wr_responses();
        if ((wrsp.size() != 1) || (wrsp[0].bresp !== 2'b00)) begin
          `uvm_error(get_name(), $sformatf(
            "mixed soak AXI4 write %0d at 0x%0h failed (responses=%0d)",
            i, this._axi_txns[i].addr, wrsp.size()))
        end
        else begin
          for (int b = 0; b < this._axi_txns[i].beats; b++) begin
            ba         = mc_mixed_soak_gen::beat_addr(this._axi_txns[i], b);
            beat_bytes = new[this._axi_txns[i].size_bytes];
            beat_be    = new[this._axi_txns[i].size_bytes];
            for (int k = 0; k < this._axi_txns[i].size_bytes; k++) begin
              beat_bytes[k] =
                this._axi_txns[i].payload[(b * this._axi_txns[i].size_bytes) + k];
              beat_be[k] = 1'b1;
            end
            this._axi_model.write(ba, beat_bytes, beat_be);
          end
          this._writes[0]++;
        end
      end
      else begin
        size = $clog2(this._axi_txns[i].size_bytes);
        rd_seq = vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)::type_id::create(
          $sformatf("axi4_soak_rd_%0d", i));
        rd_seq.set_arid(this._axi_txns[i].axi_id);
        rd_seq.set_axaddr(this._axi_txns[i].addr);
        rd_seq.set_axlen(this._axi_txns[i].beats - 1);
        rd_seq.set_axsize(3'(size));
        rd_seq.set_axburst(this._axi_txns[i].burst);
        rd_seq.set_axqos(this._axi_txns[i].qos);
        rd_seq.set_requests(1);
        rd_seq.set_get_rd_response(1'b1);
        rd_seq.start(this._env.man_agent.sequencer);
        rrsp = rd_seq.get_rd_responses();
        if ((rrsp.size() != 1) ||
            (rrsp[0].rdata.size() != this._axi_txns[i].beats) ||
            (rrsp[0].rresp !== 2'b00)) begin
          `uvm_error(get_name(), $sformatf(
            "mixed soak AXI4 read %0d at 0x%0h failed (responses=%0d)",
            i, this._axi_txns[i].addr, rrsp.size()))
        end
        else begin
          for (int b = 0; b < this._axi_txns[i].beats; b++) begin
            ba   = mc_mixed_soak_gen::beat_addr(this._axi_txns[i], b);
            lane = int'(ba % nb);
            got  = new[this._axi_txns[i].size_bytes];
            for (int k = 0; k < this._axi_txns[i].size_bytes; k++) begin
              got[k] = rrsp[0].rdata[b][lane + k];
            end
            void'(this._axi_model.check_read(ba, got,
              $sformatf("mixed soak AXI4 txn %0d beat %0d", i, b)));
          end
          this._reads[0]++;
        end
      end
    end
  endtask

  protected task run_chi();
    vip_chi_write_seq #(VIP_CHI_CFG_C) wr_seq;
    vip_chi_read_seq  #(VIP_CHI_CFG_C) rd_seq;
    chi_item_t                         wrsp [$];
    chi_item_t                         rrsp [$];
    chi_item_t::data_t                 word;
    chi_item_t::data_t                 data_q [$];
    byte unsigned got [];
    bit be [];
    int unsigned nb;
    int unsigned size;

    nb   = VIP_MC_CHI_CFG_C.DATA_BYTES_P;
    size = $clog2(nb);
    be   = new[nb];
    foreach (be[i]) begin
      be[i] = 1'b1;
    end

    foreach (this._chi_txns[i]) begin
      repeat (this._chi_txns[i].gap_cycles) @(negedge this._env.rni_agent.vif.clk);

      if (this._chi_txns[i].is_write) begin
        word = '0;
        for (int b = 0; b < nb; b++) begin
          word[(8 * b) +: 8] = this._chi_txns[i].payload[b];
        end
        data_q = '{word};

        wr_seq = vip_chi_write_seq #(VIP_CHI_CFG_C)::type_id::create(
          $sformatf("chi_soak_wr_%0d", i));
        wr_seq.reset();
        wr_seq.set_requests(1);
        wr_seq.set_initial_addr(chi_item_t::addr_t'(this._chi_txns[i].addr));
        wr_seq.set_size(3'(size));
        wr_seq.set_qos(this._chi_txns[i].qos);
        wr_seq.set_data_type(VIP_CHI_DATA_CUSTOM_E);
        wr_seq.set_data(data_q);
        wr_seq.set_get_response(1'b1);
        wr_seq.set_verbose(1'b0);
        wr_seq.start(this._env.rni_agent.sequencer);
        wrsp = wr_seq.get_responses();
        if ((wrsp.size() != 1) || (wrsp[0].rsp_resp_err !== 2'b00)) begin
          `uvm_error(get_name(), $sformatf(
            "mixed soak CHI write %0d at 0x%0h failed (responses=%0d)",
            i, this._chi_txns[i].addr, wrsp.size()))
        end
        else begin
          this._chi_model.write(this._chi_txns[i].addr,
            this._chi_txns[i].payload, be);
          this._writes[1]++;
        end
      end
      else begin
        rd_seq = vip_chi_read_seq #(VIP_CHI_CFG_C)::type_id::create(
          $sformatf("chi_soak_rd_%0d", i));
        rd_seq.reset();
        rd_seq.set_requests(1);
        rd_seq.set_initial_addr(chi_item_t::addr_t'(this._chi_txns[i].addr));
        rd_seq.set_size(3'(size));
        rd_seq.set_qos(this._chi_txns[i].qos);
        rd_seq.set_get_response(1'b1);
        rd_seq.set_verbose(1'b0);
        rd_seq.start(this._env.rni_agent.sequencer);
        rrsp = rd_seq.get_responses();
        if ((rrsp.size() != 1) || (rrsp[0].data.size() != 1) ||
            (rrsp[0].dat_resp_err[0] !== 2'b00)) begin
          `uvm_error(get_name(), $sformatf(
            "mixed soak CHI read %0d at 0x%0h failed (responses=%0d)",
            i, this._chi_txns[i].addr, rrsp.size()))
        end
        else begin
          got = new[nb];
          for (int b = 0; b < nb; b++) begin
            got[b] = rrsp[0].data[0][(8 * b) +: 8];
          end
          void'(this._chi_model.check_read(this._chi_txns[i].addr, got,
            $sformatf("mixed soak CHI txn %0d", i)));
          this._reads[1]++;
        end
      end
    end
  endtask

endclass

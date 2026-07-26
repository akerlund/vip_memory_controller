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
// tc_mc_mixed_concurrent
//
// Mixed-protocol concurrency: one vip_mc with port 0 = AXI4 and port 1 = CHI-D
// over one shared backend and one shared vip_dram. Two forked threads drive the
// AXI4 manager and the CHI RN-I concurrently, each writing a distinct full-line
// pattern to its own disjoint address window and reading it back. Both legs
// matching proves the shared backend arbitrates concurrent cross-protocol traffic
// without deadlock and without either protocol corrupting the other's data.
// -----------------------------------------------------------------------------
class tc_mc_mixed_concurrent extends mc_neutral_base_test;

  `uvm_component_utils(tc_mc_mixed_concurrent)

  localparam int unsigned N_LINES_C = 8;

  mc_mixed_tb_env _env;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Build the mixed env on top of the neutral base's shared plumbing (phase
  // timeout, report server, clk_rst agent config).
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    super.build_phase(phase);
    this._env = mc_mixed_tb_env::type_id::create("env", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Neutral-base hooks: clk_rst sequencer for the shared reset drive + telemetry.
  // ---------------------------------------------------------------------------
  protected function uvm_sequencer_base get_clk_sequencer();
    return this._env.clk_agent.sequencer;
  endfunction

  protected function void report_telemetry(input string tag);
    if ((this._env == null) || (this._env.u_mc == null)) begin
      return;
    end
    `uvm_info(tag, this._env.u_mc.sprint_telemetry(), UVM_LOW)
  endfunction

  // ---------------------------------------------------------------------------
  // Settle after the base-owned reset, then drive both protocols concurrently.
  // ---------------------------------------------------------------------------
  task body();
    // Both protocols share rst_n; settle a few clocks so the CHI link activates
    // and initial credits exchange before either leg issues.
    if (this._env.rni_agent.vif.rst_n !== 1'b1) begin
      @(posedge this._env.rni_agent.vif.rst_n);
    end
    repeat (20) @(posedge this._env.rni_agent.vif.clk);

    fork
      this.drive_axi4();
      this.drive_chi();
    join

    `uvm_info(get_name(),
      "Mixed AXI4 + CHI-D concurrent traffic matched on both ports through one shared backend",
      UVM_LOW)
  endtask

  // ---------------------------------------------------------------------------
  // AXI4 leg: N_LINES_C full-line writes (counter 0xA0+line per byte) + read-back
  // verification on the AXI4 port.
  // ---------------------------------------------------------------------------
  task drive_axi4();
    vip_axi4_write_seq #(VIP_AXI4_AGENT_CFG_C)      wr;
    vip_axi4_read_seq  #(VIP_AXI4_AGENT_CFG_C)      rd;
    vip_axi4_item      #(VIP_AXI4_AGENT_CFG_C)      wrsp [$];
    vip_axi4_item      #(VIP_AXI4_AGENT_CFG_C)      rrsp [$];
    vip_axi4_types #(VIP_AXI4_AGENT_CFG_C)::wdata_t wq [$];
    vip_axi4_types #(VIP_AXI4_AGENT_CFG_C)::wstrb_t sq [$];
    vip_axi4_types #(VIP_AXI4_AGENT_CFG_C)::wdata_t word;
    int unsigned     nb;
    logic [2 : 0]    sz;
    longint unsigned a;
    byte unsigned    got;
    byte unsigned    exp;

    nb = VIP_MC_AXI4_CFG_C.WDATA_BYTES_P;
    sz = 3'($clog2(nb));

    for (int L = 0; L < N_LINES_C; L++) begin
      a    = MIXED_AXI4_ADDR_C + (L * nb);
      word = '0;
      for (int i = 0; i < nb; i++) word[(8 * i) +: 8] = 8'hA0 + L + i;
      wq = '{word};
      sq = '{'1};

      wr = vip_axi4_write_seq #(VIP_AXI4_AGENT_CFG_C)::type_id::create($sformatf("axi4_wr_%0d", L));
      wr.set_awid('h3);
      wr.set_axaddr(a);
      wr.set_axlen(0);
      wr.set_axsize(sz);
      wr.set_axburst(VIP_MC_AXI4_BURST_INCR_C);
      wr.set_axqos(4'h0);
      wr.set_requests(1);
      wr.set_get_wr_response(1'b1);
      wr.set_wdata_type(VIP_AXI4_DATA_CUSTOM_E);
      wr.set_wstrb_type(VIP_AXI4_STRB_CUSTOM_E);
      wr.set_wdata(wq);
      wr.set_wstrb(sq);
      wr.start(this._env.man_agent.sequencer);
      wrsp = wr.get_wr_responses();
      if ((wrsp.size() != 1) || (wrsp[0].bresp !== 2'b00)) begin
        `uvm_error(get_name(), $sformatf(
          "AXI4 write at 0x%0h line %0d failed (n=%0d bresp=0x%0h)",
          a, L, wrsp.size(), (wrsp.size() > 0) ? wrsp[0].bresp : 2'bxx))
      end

      rd = vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)::type_id::create($sformatf("axi4_rd_%0d", L));
      rd.set_arid('h5);
      rd.set_axaddr(a);
      rd.set_axlen(0);
      rd.set_axsize(sz);
      rd.set_axburst(VIP_MC_AXI4_BURST_INCR_C);
      rd.set_axqos(4'h0);
      rd.set_requests(1);
      rd.set_get_rd_response(1'b1);
      rd.start(this._env.man_agent.sequencer);
      rrsp = rd.get_rd_responses();
      if ((rrsp.size() != 1) || (rrsp[0].rdata.size() != 1)) begin
        `uvm_fatal(get_name(), $sformatf(
          "AXI4 read at 0x%0h line %0d returned %0d responses", a, L, rrsp.size()))
      end
      for (int i = 0; i < nb; i++) begin
        got = rrsp[0].rdata[0][i];
        exp = 8'hA0 + L + i;
        if (got !== exp) begin
          `uvm_error(get_name(), $sformatf(
            "AXI4 read-back at 0x%0h byte %0d: got 0x%02h expected 0x%02h", a, i, got, exp))
        end
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // CHI leg: N_LINES_C full-line WriteNoSnpFull (counter 0x50+line per byte) +
  // ReadNoSnp verification on the CHI port.
  // ---------------------------------------------------------------------------
  task drive_chi();
    vip_chi_write_seq #(VIP_CHI_CFG_C) wr;
    vip_chi_read_seq  #(VIP_CHI_CFG_C) rd;
    chi_item_t                         rrsp [$];
    chi_item_t::data_t                 word;
    chi_item_t::data_t                 data_q [$];
    int unsigned     nb;
    logic [2 : 0]    sz;
    longint unsigned a;
    byte unsigned    got;
    byte unsigned    exp;

    nb = VIP_MC_CHI_CFG_C.DATA_BYTES_P;
    sz = 3'($clog2(nb));

    for (int L = 0; L < N_LINES_C; L++) begin
      a    = MIXED_CHI_ADDR_C + (L * nb);
      word = '0;
      for (int i = 0; i < nb; i++) word[(8 * i) +: 8] = 8'h50 + L + i;
      data_q = '{word};

      wr = vip_chi_write_seq #(VIP_CHI_CFG_C)::type_id::create($sformatf("chi_wr_%0d", L));
      wr.reset();
      wr.set_requests(1);
      wr.set_initial_addr(chi_item_t::addr_t'(a));
      wr.set_size(sz);
      wr.set_allow_retry(1'b0);
      wr.set_data_type(VIP_CHI_DATA_CUSTOM_E);
      wr.set_data(data_q);
      wr.set_get_response(1'b1);
      wr.set_verbose(1'b0);
      wr.start(this._env.rni_agent.sequencer);

      rd = vip_chi_read_seq #(VIP_CHI_CFG_C)::type_id::create($sformatf("chi_rd_%0d", L));
      rd.reset();
      rd.set_requests(1);
      rd.set_initial_addr(chi_item_t::addr_t'(a));
      rd.set_size(sz);
      rd.set_allow_retry(1'b0);
      rd.set_get_response(1'b1);
      rd.set_verbose(1'b0);
      rd.start(this._env.rni_agent.sequencer);
      rrsp = rd.get_responses();
      if ((rrsp.size() != 1) || (rrsp[0].data.size() != 1)) begin
        `uvm_fatal(get_name(), $sformatf(
          "CHI read at 0x%0h line %0d returned %0d responses", a, L, rrsp.size()))
      end
      for (int i = 0; i < nb; i++) begin
        got = rrsp[0].data[0][(8 * i) +: 8];
        exp = 8'h50 + L + i;
        if (got !== exp) begin
          `uvm_error(get_name(), $sformatf(
            "CHI read-back at 0x%0h byte %0d: got 0x%02h expected 0x%02h", a, i, got, exp))
        end
      end
    end
  endtask

endclass

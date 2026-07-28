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
// tc_mc_axi4_soak
//
// The suite's one constrained-random test. Every other tc_mc_* is directed: it
// sets up an exact scenario, checks one property and finishes in tens of clock
// cycles. That leaves whole classes of bug unreachable - anything that needs an
// unplanned *combination* of burst shape, QoS, bank conflict and refresh timing
// to show up.
//
// This test drives a randomized mixed read/write program concurrently on both
// AXI4 ports and checks every read byte against a golden model. It mixes
// INCR/WRAP/FIXED, narrow and full-width beats, 1..16 beats, four AXI4 ids, the
// full QoS range, and inter-transaction gaps from saturating to fully drained.
//
// Reproducibility. Stimulus comes from mc_soak_gen, a shared explicit LCG that
// produces byte-identical programs in the SystemVerilog and pyUVM flows, so a
// failure reproduces in both. Override the seed and length with:
//
//   +MC_SOAK_SEED=<n>       (default 1)
//   +MC_SOAK_TXNS=<n>       (default 96)
//   +MC_SOAK_WRAP_PCT=<n>   (default 15; FIXED stays at 15%, INCR takes the rest)
//
// What it caught. On its first run, with WRAP in the mix, this test found a real
// vip_mc defect: the device request went out at the AXI start address
// (vip_mc_backend `req.addr = entry.addr`) while pack_write_beat and
// unpack_read_beat index the payload rows from the wrap-region base. A WRAP
// burst not starting at its region base was therefore written rotated by the
// start offset, with its last row one row past the region - corrupting a
// neighbour the burst never touched. A WRAP read of the same shape rotated
// identically, so read-after-write hid it; only a non-WRAP observer could see
// it, which is what the backdoor sweep below is. Fixed by issuing at the burst
// window base (vip_mc_cmd_entry::get_dev_addr); seed 1 port 1 txn 12 (WRAP,
// 4 beats x 64 B, start 0xbbdc40, region base 0xbbdc00) is the regression case.
//
// Timing scoreboard. Left off. The random program hits write coalescing and
// multi-outstanding grants constantly, and mc_scoreboard's predictor assumes one
// device access maps to one host completion (see docs/FURTHER_WORK.md item 5).
// Data correctness is checked instead, which is the stronger property; when
// item 5 lands, the timing check can be turned back on here.
// -----------------------------------------------------------------------------
class tc_mc_axi4_soak extends mc_base_test;

  `uvm_component_utils(tc_mc_axi4_soak)

  localparam int unsigned DEFAULT_TXNS_C = 96;
  localparam longint unsigned DEFAULT_SEED_C = 64'd1;
  localparam int unsigned DEFAULT_WRAP_PCT_C = 15;

  // Let each port hold a few transactions in flight so the backend actually has
  // a queue to schedule over. Same-id ordering still holds per port.
  localparam int unsigned OUTSTANDING_C = 4;
  localparam int unsigned DRAIN_TIMEOUT_CYCLES_C = 4096;

  mc_soak_gen   gen;
  mc_equiv_model model;

  protected mc_soak_txn_t txn_list [];
  protected int unsigned  txn_count;
  protected int unsigned  wrap_pct;
  protected longint unsigned seed;

  // Per-port completion tallies, reported at the end.
  protected int unsigned writes_done  [N_PORTS_C];
  protected int unsigned reads_done   [N_PORTS_C];
  protected int unsigned rejects_done [N_PORTS_C];

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Both ports active, several transactions in flight, timing scoreboard off
  // (see the header note).
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    uvm_config_db #(int)::set(this, "env", "mc_scoreboard_timing_check", 0);
    uvm_config_db #(int)::set(this, "env", "man_wr_outstanding_max", OUTSTANDING_C);
    uvm_config_db #(int)::set(this, "env", "man_rd_outstanding_max", OUTSTANDING_C);
    super.build_phase(phase);
  endfunction

  // ---------------------------------------------------------------------------
  // Build the program, replay it concurrently per port, then sweep the whole
  // written image through the backdoor as a final independent check.
  // ---------------------------------------------------------------------------
  task body();
    mc_soak_txn_t port_txns [N_PORTS_C][$];

    this.txn_count = DEFAULT_TXNS_C;
    void'($value$plusargs("MC_SOAK_TXNS=%d", this.txn_count));
    this.seed = DEFAULT_SEED_C;
    void'($value$plusargs("MC_SOAK_SEED=%d", this.seed));

    this.gen          = mc_soak_gen::type_id::create("gen");
    this.gen.geom     = DRAM_CFG_C;
    this.gen.addr_map = this._tb_env.dram.cfg.addr_map;
    this.gen.n_ports  = N_PORTS_C;
    this.gen.bus_bytes = VIP_MC_AXI4_CFG_C.WDATA_BYTES_P;

    // Trading WRAP share against INCR keeps FIXED at a constant 15%, so raising
    // the WRAP knob does not silently drop the FIXED corner as well.
    this.wrap_pct = DEFAULT_WRAP_PCT_C;
    void'($value$plusargs("MC_SOAK_WRAP_PCT=%d", this.wrap_pct));
    if (this.wrap_pct > 85) begin
      `uvm_fatal(get_name(), $sformatf(
        "MC_SOAK_WRAP_PCT=%0d leaves no room for INCR (max 85)", this.wrap_pct))
    end
    this.gen.wrap_percent = this.wrap_pct;
    this.gen.incr_percent = 85 - this.wrap_pct;

    this.gen.set_seed(this.seed);

    this.model = mc_equiv_model::type_id::create("model");
    this.model.clear();

    this.gen.generate_program(this.txn_count, this.txn_list);

    `uvm_info(get_name(), $sformatf(
      "Soak program: %0d transactions, seed %0d, %0d ports",
      this.txn_count, this.seed, N_PORTS_C), UVM_LOW)

    foreach (this.txn_list[i]) begin
      port_txns[this.txn_list[i].port_id].push_back(this.txn_list[i]);
    end

    for (int p = 0; p < N_PORTS_C; p++) begin
      this.wait_for_reset_release_on_port(p);
      this.writes_done[p]  = 0;
      this.reads_done[p]   = 0;
      this.rejects_done[p] = 0;
    end

    // Ports run concurrently; within a port the program is replayed in order so
    // the golden model stays exact without predicting arbitration.
    fork
      begin : port_threads
        for (int p = 0; p < N_PORTS_C; p++) begin
          automatic int port_id = p;
          fork
            this.run_port(port_id, port_txns[port_id]);
          join_none
        end
        wait fork;
      end
    join

    this.wait_for_device_drain();
    this.final_backdoor_sweep();

    `uvm_info(get_name(), $sformatf(
      {"Soak complete: port0 %0d writes / %0d reads / %0d decerr, ",
       "port1 %0d writes / %0d reads / %0d decerr"},
      this.writes_done[0], this.reads_done[0], this.rejects_done[0],
      this.writes_done[1], this.reads_done[1], this.rejects_done[1]), UVM_LOW)

    this.report_telemetry("soak");
  endtask

  // ---------------------------------------------------------------------------
  // Lowest and highest byte address a transaction covers.
  //
  // Deliberately an independent restatement of the front-end's own span math
  // rather than a call into it: this is what the DECERR prediction below is
  // checked against, and predicting with the code under test would make the
  // check vacuous. It is only this short because mc_soak_gen size-aligns every
  // start address, so the AXI4 A3.4.3 first-beat clipping term is always zero -
  // asserted rather than assumed.
  // ---------------------------------------------------------------------------
  protected function void soak_span(
    input  mc_soak_txn_t     t,
    output longint unsigned  lo_addr,
    output longint unsigned  hi_addr
  );
    longint unsigned total;

    if ((t.addr % t.size_bytes) != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        {"soak generator produced an unaligned start 0x%0h for a %0d B ",
         "transfer; soak_span's simplified math no longer holds"},
        t.addr, t.size_bytes))
    end

    total = t.beats * t.size_bytes;

    case (t.burst)
      VIP_MC_AXI4_BURST_FIXED_C: begin
        lo_addr = t.addr;
        hi_addr = t.addr + t.size_bytes - 1;
      end
      VIP_MC_AXI4_BURST_WRAP_C: begin
        lo_addr = t.addr & ~(total - 1);
        hi_addr = lo_addr + total - 1;
      end
      default: begin
        lo_addr = t.addr;
        hi_addr = t.addr + total - 1;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // OKAY, or DECERR when the transaction lands in a configured DECERR window.
  //
  // The windows live in cfg (mc_tb_env installs 'h1000-'h1FFF for every AXI4
  // test), so the soak can predict the rejection instead of tripping over it.
  // Before this the generator drew across the whole device with no knowledge of
  // the window and a rare seed produced a legal-looking access inside it - the
  // controller correctly returned DECERR and the soak reported a failure.
  // ---------------------------------------------------------------------------
  protected function resp_t soak_expected_resp(input mc_soak_txn_t t);
    longint unsigned lo_addr;
    longint unsigned hi_addr;

    this.soak_span(t, lo_addr, hi_addr);

    foreach (this._tb_env.u_mc.cfg.axi4.decerr_addr_lo[i]) begin
      if ((lo_addr <= this._tb_env.u_mc.cfg.axi4.decerr_addr_hi[i]) &&
          (hi_addr >= this._tb_env.u_mc.cfg.axi4.decerr_addr_lo[i])) begin
        return VIP_MC_AXI4_RESP_DECERR_C;
      end
    end

    return VIP_MC_AXI4_RESP_OKAY_C;
  endfunction

  // ---------------------------------------------------------------------------
  // Replay one port's slice of the program in order.
  // ---------------------------------------------------------------------------
  protected task run_port(
    input int unsigned  port_id,
    input mc_soak_txn_t txns []
  );
    foreach (txns[i]) begin
      if (txns[i].gap_cycles > 0) begin
        repeat (txns[i].gap_cycles) begin
          @(negedge this._tb_env._man_vif[port_id].clk);
        end
      end

      // Run with +UVM_VERBOSITY=UVM_HIGH to dump the generated program; that is
      // how a soak failure gets narrowed to one transaction.
      `uvm_info(get_name(), $sformatf(
        "soak port %0d txn %0d: %s addr 0x%0h burst %0d beats %0d size %0d id %0d qos %0d gap %0d",
        port_id, i, txns[i].is_write ? "WR" : "RD", txns[i].addr,
        txns[i].burst, txns[i].beats, txns[i].size_bytes, txns[i].axi_id,
        txns[i].qos, txns[i].gap_cycles), UVM_HIGH)

      if (txns[i].is_write) begin
        this.drive_write(port_id, i, txns[i]);
      end
      else begin
        this.drive_read(port_id, i, txns[i]);
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Drive one randomized write and fold it into the golden model.
  //
  // Lane placement: a beat of size_bytes at byte address `ba` occupies bus lanes
  // [ba % bus_bytes +: size_bytes]. The start address is size-aligned by
  // construction, so a beat never straddles the lane window.
  // ---------------------------------------------------------------------------
  protected task drive_write(
    input int unsigned  port_id,
    input int unsigned  idx,
    input mc_soak_txn_t t
  );
    wdata_t       data_q [];
    wstrb_t       strb_q [];
    resp_t        bresp;
    resp_t        want;
    buser_t       buser;
    byte unsigned beat_bytes [];
    bit           all_enabled [];
    longint unsigned ba;
    int unsigned  lane;
    int unsigned  bus_bytes;
    logic [VIP_MC_AXI4_CFG_C.AWID_WIDTH_P - 1 : 0] awid;

    bus_bytes = VIP_MC_AXI4_CFG_C.WDATA_BYTES_P;
    awid      = t.axi_id;
    data_q    = new[t.beats];
    strb_q    = new[t.beats];

    for (int b = 0; b < t.beats; b++) begin
      ba   = mc_soak_gen::beat_addr(t, b);
      lane = int'(ba % bus_bytes);

      data_q[b] = '0;
      strb_q[b] = '0;
      for (int k = 0; k < t.size_bytes; k++) begin
        data_q[b][(8 * (lane + k)) +: 8] = t.payload[(b * t.size_bytes) + k];
        strb_q[b][lane + k]              = 1'b1;
      end
    end

    this.axi4_write_custom_user_on_port(
      port_id,
      awid,
      t.qos,
      1'b0,
      t.addr,
      this.get_axi_size_for_bytes(t.size_bytes),
      t.burst,
      awuser_t'('0),
      wuser_t'('0),
      data_q,
      strb_q,
      bresp,
      buser);

    want = this.soak_expected_resp(t);

    if (bresp !== want) begin
      `uvm_error(get_name(), $sformatf(
        "soak txn %0d port %0d: write at 0x%0h returned BRESP 0x%0h, expected 0x%0h",
        idx, port_id, t.addr, bresp, want))
      return;
    end

    // A rejected write never reaches storage, so it must not enter the model
    // either - folding it would make every later read of those bytes disagree.
    if (want === VIP_MC_AXI4_RESP_DECERR_C) begin
      this.rejects_done[port_id]++;
      return;
    end

    // Fold into the model only after the write is accepted, in beat order, so a
    // FIXED burst's later beats correctly overwrite the earlier ones.
    for (int b = 0; b < t.beats; b++) begin
      ba          = mc_soak_gen::beat_addr(t, b);
      beat_bytes  = new[t.size_bytes];
      all_enabled = new[t.size_bytes];
      for (int k = 0; k < t.size_bytes; k++) begin
        beat_bytes[k]  = t.payload[(b * t.size_bytes) + k];
        all_enabled[k] = 1'b1;
      end
      this.model.write(ba, beat_bytes, all_enabled);
    end

    this.writes_done[port_id]++;
  endtask

  // ---------------------------------------------------------------------------
  // Drive one randomized read and check every beat against the golden model.
  // ---------------------------------------------------------------------------
  protected task drive_read(
    input int unsigned  port_id,
    input int unsigned  idx,
    input mc_soak_txn_t t
  );
    rdata_t       data_q [];
    resp_t        rresp_q [];
    resp_t        want;
    ruser_t       ruser_q [];
    byte unsigned got [];
    longint unsigned ba;
    int unsigned  lane;
    int unsigned  bus_bytes;
    logic [VIP_MC_AXI4_CFG_C.ARID_WIDTH_P - 1 : 0] arid;

    bus_bytes = VIP_MC_AXI4_CFG_C.RDATA_BYTES_P;
    arid      = t.axi_id;

    this.axi4_read_custom_user_on_port(
      port_id,
      arid,
      t.qos,
      1'b0,
      t.addr,
      this.get_axi_size_for_bytes(t.size_bytes),
      t.burst,
      aruser_t'('0),
      t.beats,
      data_q,
      rresp_q,
      ruser_q);

    want = this.soak_expected_resp(t);

    for (int b = 0; b < t.beats; b++) begin
      if (rresp_q[b] !== want) begin
        `uvm_error(get_name(), $sformatf(
          {"soak txn %0d port %0d: read at 0x%0h beat %0d returned RRESP 0x%0h, ",
           "expected 0x%0h"},
          idx, port_id, t.addr, b, rresp_q[b], want))
        return;
      end
    end

    // A rejected read returns no data to compare - the model holds nothing for
    // those bytes, since the matching writes were rejected too.
    if (want === VIP_MC_AXI4_RESP_DECERR_C) begin
      this.rejects_done[port_id]++;
      return;
    end

    // A FIXED read returns the same location every beat, so checking beat 0 is
    // enough and the later beats are redundant - but they must still match.
    for (int b = 0; b < t.beats; b++) begin
      ba   = mc_soak_gen::beat_addr(t, b);
      lane = int'(ba % bus_bytes);
      got  = new[t.size_bytes];
      for (int k = 0; k < t.size_bytes; k++) begin
        got[k] = data_q[b][(8 * (lane + k)) +: 8];
      end
      void'(this.model.check_read(ba, got, $sformatf(
        "soak txn %0d port %0d beat %0d", idx, port_id, b)));
    end

    this.reads_done[port_id]++;
  endtask

  // ---------------------------------------------------------------------------
  // A host write completes when the controller accepts it, which is not the same
  // instant the device commits it: the backend may still hold the access, and a
  // coalesced primary is only written when its device response returns. Wait for
  // the backend to have no access outstanding before reading the device
  // directly, or the sweep races the write path and reports stale bytes that are
  // simply not there yet.
  // ---------------------------------------------------------------------------
  protected task wait_for_device_drain();
    int unsigned guard;

    guard = 0;
    while ((this._tb_env.u_mc.backend.get_inflight_to_device() > 0) ||
           (this._tb_env.u_mc.backend.issued_req_count !=
            this._tb_env.u_mc.backend.observed_rsp_count)) begin
      @(negedge this._tb_env._man_vif[0].clk);
      guard++;
      if (guard > DRAIN_TIMEOUT_CYCLES_C) begin
        `uvm_error(get_name(), $sformatf(
          "backend did not drain: %0d issued, %0d observed, %0d in flight",
          this._tb_env.u_mc.backend.issued_req_count,
          this._tb_env.u_mc.backend.observed_rsp_count,
          this._tb_env.u_mc.backend.get_inflight_to_device()))
        return;
      end
    end

    // One more device-access window so a just-completed write is committed to
    // storage before the backdoor reads it.
    repeat (16) begin
      @(negedge this._tb_env._man_vif[0].clk);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Independent end-of-test check: read every byte the model believes it wrote
  // straight out of the device, bypassing the controller entirely. Catches
  // anything the in-flight read checks could not see - a write that landed at
  // the wrong address, or one that never landed at all.
  // ---------------------------------------------------------------------------
  protected task final_backdoor_sweep();
    int unsigned mismatches;
    int unsigned checked;
    longint unsigned addr;
    byte unsigned    expected_byte;
    byte unsigned    got_byte;
    vip_dram_types #(DRAM_CFG_C)::data_t word;
    int unsigned  bus_bytes;
    longint unsigned word_addr;

    mismatches = 0;
    checked    = 0;
    bus_bytes  = DRAM_CFG_C.ROW_BYTES_P;

    foreach (this.model.mem[addr]) begin
      expected_byte = this.model.mem[addr];
      word_addr     = addr - (addr % bus_bytes);
      word          = this._tb_env.dram.backdoor_read(word_addr);
      got_byte      = word[(8 * int'(addr % bus_bytes)) +: 8];
      checked++;

      if (got_byte !== expected_byte) begin
        mismatches++;
        if (mismatches <= 8) begin
          `uvm_error(get_name(), $sformatf(
            "backdoor sweep: device byte at 0x%0h is 0x%02h, model says 0x%02h",
            addr, got_byte, expected_byte))
        end
      end
    end

    if (mismatches > 8) begin
      `uvm_error(get_name(), $sformatf(
        "backdoor sweep: %0d total mismatching bytes (first 8 reported)",
        mismatches))
    end

    `uvm_info(get_name(), $sformatf(
      "Backdoor sweep checked %0d bytes, %0d mismatches", checked, mismatches),
      UVM_LOW)
  endtask

endclass

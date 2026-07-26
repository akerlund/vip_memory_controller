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
// tc_mc_observability
//
// Exercises the §11 residual-observability telemetry that layers on top of the
// §8.8 getters: the pending-depth occupancy histogram, completion-latency stats
// (min/mean/max + coarse log2-ns histogram), and per-port utilization.
//
// Phase A fires several fire-and-forget reads on port 0 with the device window
// held to one in-flight request (mc_max_inflight_to_device = 1), so requests
// pile up in the cmd_queue and the occupancy histogram records depth > 0.
// Phase B issues a couple of sequential reads on port 1 to give the per-port
// breakdown a second populated port. The test then cross-checks:
//   * every completion produced exactly one latency sample (0 < min <= mean <= max),
//   * the occupancy histogram is internally consistent (buckets sum to the
//     sample count) and reached a depth >= 1,
//   * per-port completed counts / bytes match the traffic actually driven,
//   * the observed-OoO counter stayed at 0 for this strictly in-order stream
//     (the paired positive check lives in tc_mc_axi4_ooo_inter_id).
// -----------------------------------------------------------------------------
class tc_mc_observability extends mc_base_test;

  `uvm_component_utils(tc_mc_observability)

  localparam int              OBS_TIMEOUT_CYCLES_C = 2048;
  localparam int              N_PORT0_READS_C      = 6;
  localparam int              N_PORT1_READS_C      = 2;
  localparam longint unsigned P0_ID_BASE_C         = 'h10;
  localparam longint unsigned P1_ID_BASE_C         = 'h20;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(input uvm_phase phase);
    uvm_config_db #(int)::set(this, "env", "mc_refresh_enabled", 0);
    uvm_config_db #(int)::set(this, "env", "mc_scoreboard_enabled", 0);
    // Hold the device window to one in-flight request so admitted requests
    // queue and the occupancy histogram records depth > 0.
    uvm_config_db #(int)::set(this, "env", "mc_max_inflight_to_device", 1);
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

  protected function longint unsigned port0_addr(input int i);
    return this.encode_addr(.row(i + 1), .bg(i % 4), .bank(0));
  endfunction

  protected function longint unsigned port1_addr(input int i);
    return this.encode_addr(.row(i + 1), .bg(i % 4), .bank(1));
  endfunction

  // Deterministic per-line seed pattern (device-side full row).
  protected function vip_dram_types #(DRAM_CFG_C)::data_t seed_pattern(input int base, input int i);
    vip_dram_types #(DRAM_CFG_C)::data_t d;
    d = '0;
    for (int b = 0; b < DRAM_CFG_C.ROW_BYTES_P; b++) begin
      d[(8 * b) +: 8] = base[7:0] + 8'h10 * i[3:0] + b[7:0];
    end
    return d;
  endfunction

  protected task issue_read_no_wait(
    input logic [VIP_MC_AXI4_CFG_C.ARID_WIDTH_P - 1 : 0] arid,
    input longint unsigned                               addr
  );
    vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)           rd_seq;
    vip_mc_axi4_driver #(VIP_MC_AXI4_CFG_C, DRAM_CFG_C) fe0;

    fe0 = this.get_port_fe(0);

    rd_seq = vip_axi4_read_seq #(VIP_AXI4_AGENT_CFG_C)::type_id::create($sformatf(
      "obs_rd_%0h_%0h", arid, addr));
    rd_seq.reset();
    rd_seq.set_arid(arid);
    rd_seq.set_axaddr(addr);
    rd_seq.set_axlen(0);
    rd_seq.set_axsize(this.get_full_width_axi_size());
    rd_seq.set_axburst(VIP_MC_AXI4_BURST_INCR_C);
    rd_seq.set_axqos(4'h4);
    rd_seq.set_requests(1);
    rd_seq.set_get_rd_response(1'b0);
    this.start_seq_or_timeout(
      rd_seq,
      this._tb_env.man_agent[0].sequencer,
      fe0,
      0,
      rd_seq.get_name());
  endtask

  task body();
    rdata_t          rdata;
    resp_t           rresp;
    int              peak_depth;
    longint unsigned hist_sum;
    longint unsigned occ_samples;
    real             min_ns;
    real             mean_ns;
    real             max_ns;
    int unsigned     lat_samples;

    this.wait_for_reset_release();
    this.wait_for_reset_release_on_port(1);
    this.clear_manager_observations();

    // Seed all lines the test will read (device-side, no bus traffic / counts).
    for (int i = 0; i < N_PORT0_READS_C; i++) begin
      this._tb_env.dram.backdoor_write(this.port0_addr(i), this.seed_pattern('h30, i));
    end
    for (int i = 0; i < N_PORT1_READS_C; i++) begin
      this._tb_env.dram.backdoor_write(this.port1_addr(i), this.seed_pattern('h80, i));
    end

    // Phase A: fire N fire-and-forget reads on port 0 so they queue behind the
    // one-deep device window.
    for (int i = 0; i < N_PORT0_READS_C; i++) begin
      this.issue_read_no_wait(P0_ID_BASE_C + i, this.port0_addr(i));
    end

    // Wait until all port-0 reads have been seen back on the R channel (so the
    // manager has no read outstanding at end of test).
    repeat (OBS_TIMEOUT_CYCLES_C) begin
      @(posedge this._tb_env._man_vif[0].clk);
      if (this.rd_observations.size() >= N_PORT0_READS_C) begin
        break;
      end
    end
    if (this.rd_observations.size() != N_PORT0_READS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Observability test expected %0d port-0 read responses, saw %0d",
        N_PORT0_READS_C, this.rd_observations.size()))
    end
    foreach (this.rd_observations[i]) begin
      if (this.rd_observations[i].rresp != VIP_MC_AXI4_RESP_OKAY_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "Observability port-0 read %0d returned RRESP=%0b instead of OKAY",
          i, this.rd_observations[i].rresp))
      end
    end

    // Phase B: sequential reads on port 1 to populate the second port.
    for (int i = 0; i < N_PORT1_READS_C; i++) begin
      this.axi4_read_single_on_port(1, P1_ID_BASE_C + i, 4'h4, this.port1_addr(i), rdata, rresp);
      if (rresp != VIP_MC_AXI4_RESP_OKAY_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "Observability port-1 read %0d returned RRESP=%0b instead of OKAY", i, rresp))
      end
    end

    // ---- Latency stats -------------------------------------------------------
    lat_samples = this._tb_env.u_mc.get_latency_sample_count();
    min_ns      = this._tb_env.u_mc.get_min_latency_ns();
    mean_ns     = this._tb_env.u_mc.get_mean_latency_ns();
    max_ns      = this._tb_env.u_mc.get_max_latency_ns();

    if (lat_samples != (N_PORT0_READS_C + N_PORT1_READS_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "Observability latency sample count = %0d, expected %0d",
        lat_samples, N_PORT0_READS_C + N_PORT1_READS_C))
    end
    if (min_ns <= 0.0) begin
      `uvm_fatal(get_name(), $sformatf(
        "Observability min latency should be > 0, got %0.3fns", min_ns))
    end
    if ((min_ns > mean_ns) || (mean_ns > max_ns)) begin
      `uvm_fatal(get_name(), $sformatf(
        "Observability latency ordering violated: min=%0.3f mean=%0.3f max=%0.3f",
        min_ns, mean_ns, max_ns))
    end

    // ---- Occupancy histogram -------------------------------------------------
    occ_samples = this._tb_env.u_mc.get_occupancy_sample_count();
    peak_depth  = this._tb_env.u_mc.get_cmd_queue_peak_depth();
    if (occ_samples == 0) begin
      `uvm_fatal(get_name(), "Observability occupancy histogram recorded no samples")
    end
    if (peak_depth < 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Observability expected the queue to reach depth >= 1, peak was %0d", peak_depth))
    end
    if (this._tb_env.u_mc.get_occupancy_hist_count(peak_depth) < 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "Observability occupancy histogram has no sample at its own peak depth %0d", peak_depth))
    end
    // Every sample lands in exactly one bucket in [0, peak_depth].
    hist_sum = 0;
    for (int d = 0; d <= peak_depth; d++) begin
      hist_sum += this._tb_env.u_mc.get_occupancy_hist_count(d);
    end
    if (hist_sum != occ_samples) begin
      `uvm_fatal(get_name(), $sformatf(
        "Observability occupancy buckets sum to %0d but %0d samples were taken",
        hist_sum, occ_samples))
    end

    // ---- Per-port utilization ------------------------------------------------
    if (this._tb_env.u_mc.get_port_completed_count(0) != N_PORT0_READS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Observability port-0 completed count = %0d, expected %0d",
        this._tb_env.u_mc.get_port_completed_count(0), N_PORT0_READS_C))
    end
    if (this._tb_env.u_mc.get_port_completed_count(1) != N_PORT1_READS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "Observability port-1 completed count = %0d, expected %0d",
        this._tb_env.u_mc.get_port_completed_count(1), N_PORT1_READS_C))
    end
    if (this._tb_env.u_mc.get_port_data_bytes(0) !=
        (longint'(N_PORT0_READS_C) * longint'(DRAM_CFG_C.ROW_BYTES_P))) begin
      `uvm_fatal(get_name(), $sformatf(
        "Observability port-0 data bytes = %0d, expected %0d",
        this._tb_env.u_mc.get_port_data_bytes(0),
        longint'(N_PORT0_READS_C) * longint'(DRAM_CFG_C.ROW_BYTES_P)))
    end
    if (this._tb_env.u_mc.get_port_data_bytes(1) !=
        (longint'(N_PORT1_READS_C) * longint'(DRAM_CFG_C.ROW_BYTES_P))) begin
      `uvm_fatal(get_name(), $sformatf(
        "Observability port-1 data bytes = %0d, expected %0d",
        this._tb_env.u_mc.get_port_data_bytes(1),
        longint'(N_PORT1_READS_C) * longint'(DRAM_CFG_C.ROW_BYTES_P)))
    end

    // ---- Observed-OoO: this strictly in-order stream must not reorder --------
    if (this._tb_env.u_mc.get_observed_reorder_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "Observability in-order stream produced %0d out-of-order retirements (expected 0)",
        this._tb_env.u_mc.get_observed_reorder_count()))
    end

    `uvm_info(get_name(), $sformatf(
      "vip_mc observability test passed (lat samples=%0d min=%0.1f mean=%0.1f max=%0.1fns, occ samples=%0d peak depth=%0d, port0/1 completed=%0d/%0d)",
      lat_samples, min_ns, mean_ns, max_ns, occ_samples, peak_depth,
      this._tb_env.u_mc.get_port_completed_count(0),
      this._tb_env.u_mc.get_port_completed_count(1)), UVM_LOW)
  endtask
endclass

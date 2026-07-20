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
// vip_mc_config
//
// Shared MC-level knobs plus the per-port runtime map. The compile-time host
// topology lives in the PORTS[] parameter table; this object carries only the
// runtime policy state that the testbench may override.
// -----------------------------------------------------------------------------

class vip_mc_config extends uvm_object;

  vip_mc_axi4_cfg         axi4;
  vip_mc_chi_cfg          chi;
  int                     max_outstanding_rd    = 16;
  int                     max_outstanding_wr    = 16;
  int                     qos_class_count       = 1;
  real                    qos_aging_ns          = 0.0;
  bool_t                  fr_fcfs_enable        = FALSE;
  // FR-FCFS starvation cap (§11 item 1): bound how many times a queued request may
  // be reordered past by a younger readiness-winner within the same effective QoS
  // class. Once an eligible entry has been bypassed this many times the backend
  // force-serves the oldest such entry (FCFS override), so a page-miss cannot be
  // starved indefinitely behind a younger page-hit streak. 0 = disabled (unbounded
  // reorder = pure FR-FCFS, legacy). Only meaningful with fr_fcfs_enable; distinct
  // from qos_aging_ns, which promotes across QoS classes rather than within one.
  int                     fr_fcfs_starvation_cap = 0;
  // Read/write bus-direction grouping (§11 item 1, the turnaround-aware FR-FCFS
  // refinement). When TRUE, the within-class selector prefers the eligible
  // candidate whose bus direction (RD/WR) matches the last issued command's, so
  // reads and writes are served in runs that amortize the device read/write
  // turnaround bubble (tWTR/tRTW) instead of paying it on every RD<->WR flip.
  // Direction match is the PRIMARY key; predicted completion then admit_order break
  // ties within a direction, and the pure readiness winner is the fallback when no
  // same-direction candidate is eligible (an unavoidable flip). Off by default
  // (pure readiness-first FR-FCFS). Only meaningful with fr_fcfs_enable. This is
  // the classic write-drain trade: a little per-request latency for bus throughput.
  bool_t                  rd_wr_grouping_enable = FALSE;
  // Max consecutive same-direction issues before the grouping preference inverts
  // for one pick (a forced turnaround), so the opposite direction cannot be starved
  // by an unbroken same-direction stream. 0 = unbounded run (drain the current
  // direction while candidates exist). Ignored unless rd_wr_grouping_enable; a
  // within-direction bound distinct from fr_fcfs_starvation_cap. Must be >= 0.
  int                     rd_wr_grouping_max    = 0;
  // Write coalescing (§11): when TRUE, a newly admitted write is merged into the
  // newest outstanding same-stream ({port,id,WR}) pending write to the SAME
  // row-word address instead of being issued separately — the two host writes
  // become one device access with byte lanes overlaid (newer wins). Off by
  // default; the timing scoreboard is coalescing-unaware (one device access now
  // completes two host writes), so enable it only where the scoreboard is off.
  // Requires a host that can hold >1 write outstanding (AXI4: the manager's
  // cfg.wr_outstanding_max > 1; CHI: multi_outstanding_write) so two same-line
  // writes can be co-pending in the cmd queue.
  bool_t                  write_coalescing_enable = FALSE;
  // ECC / SECDED read-error mapping (§11 item 5): when TRUE, the backend applies
  // a 64+8 SECDED decision to each completed read. The device physically corrupts
  // a faulted beat (CORRECTABLE = one bit flipped, UNCORRECTABLE = two); the SECDED
  // layer un-flips the repairable single-bit flip the device flags in
  // rsp.corrupt_mask (data restored, stays OKAY) and maps an uncorrectable double-
  // bit error to a bus SLVERR with its poisoned bytes intact. Off by default: the
  // corruption still happens in the device, but the controller passes the bad
  // bytes through as OKAY (silent data corruption — the danger ECC guards against).
  // Faults are injected on the device via vip_dram::inject_fault(); this knob only
  // gates the controller-side correction/classification. Writes are unaffected (no
  // read-modify-write ECC modeled).
  bool_t                  ecc_enable            = FALSE;
  int                     rsp_buf_depth         = 0;
  // Bounded device-side command window: the backend issues a new request to the
  // device only while fewer than this many are outstanding (issued, response not
  // yet seen). Models the finite command-bus/bandwidth of a real controller, so
  // requests queue at the QoS arbiter under load. 0 = unbounded (issue freely);
  // negative values mean "auto" and resolve to total banks across all ranks.
  int                     max_inflight_to_device = -1;
  vip_dram_addr_map_t     addr_map_policy;
  bool_t                  refresh_enabled       = TRUE;
  vip_mc_refresh_policy_e refresh_policy        = VIP_MC_REFRESH_PERIODIC_E;
  // Max number of tREFI intervals a refresh may be postponed under
  // VIP_MC_REFRESH_DEFERRED_E before a forced catch-up burst (JEDEC allows up to
  // 8). Ignored by the periodic policy. Must be >= 1.
  int                     refresh_max_deferred  = 8;
  real                    tREFI_override        = -1.0;
  bool_t                  init_delay_enabled    = FALSE;
  // Controller bring-up (tINIT-like) hold-off: when init_delay_enabled, the
  // backend issues nothing to the device (normal traffic and refresh alike) until
  // init_delay_ns after each reset deassertion. Requests still admit and queue;
  // they simply are not serviced until bring-up completes.
  real                    init_delay_ns         = 0.0;
  bool_t                  perf_counters_enabled = TRUE;
  // Honor vip_dram's per-beat ready times on the read-data channel (§5.4): the
  // device delivers at first_beat_ready_time and the AXI4 driver paces R beats
  // first->last. FALSE reverts to delivering at last and driving beats back-to-
  // back (no pacing, no late accounting).
  bool_t                  honor_beat_timing     = TRUE;

  vip_mc_port_runtime_cfg ports[];

  `uvm_object_utils(vip_mc_config)

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(string name = "vip_mc_config");
    super.new(name);
    this.axi4 = vip_mc_axi4_cfg::type_id::create("axi4");
    this.chi  = vip_mc_chi_cfg::type_id::create("chi");
    this.addr_map_policy = vip_dram_default_addr_map(VIP_DRAM_CFG_DEFAULT_C);
  endfunction

  // ---------------------------------------------------------------------------
  // Resize the runtime port map and seed default per-port vif keys.
  // ---------------------------------------------------------------------------
  function void ensure_port_count(int port_count);
    if (port_count < 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "Port count must be >= 0 (got %0d)", port_count))
    end

    this.ports = new[port_count](this.ports);
    for (int port_id = 0; port_id < port_count; port_id++) begin
      if (this.ports[port_id] == null) begin
        this.ports[port_id] = vip_mc_port_runtime_cfg::type_id::create(
          $sformatf("port_cfg_%0d", port_id));
      end
      if (this.ports[port_id].vif_key == "") begin
        this.ports[port_id].vif_key = $sformatf("vif_port%0d", port_id);
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Validate the shared MC configuration against the selected DRAM geometry.
  // ---------------------------------------------------------------------------
  function void validate(input vip_dram_cfg_t dram_cfg = VIP_DRAM_CFG_DEFAULT_C);
    if (this.axi4 == null) begin
      `uvm_fatal(get_name(), "axi4 config handle is null")
    end

    if (this.chi == null) begin
      `uvm_fatal(get_name(), "chi config handle is null")
    end
    this.chi.validate();

    if (this.max_outstanding_rd < 0 || this.max_outstanding_wr < 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "Outstanding limits must be >= 0 (rd=%0d wr=%0d)",
        this.max_outstanding_rd, this.max_outstanding_wr))
    end

    if (this.qos_class_count < 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "qos_class_count must be >= 1 (got %0d)", this.qos_class_count))
    end

    if (this.refresh_max_deferred < 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "refresh_max_deferred must be >= 1 (got %0d)", this.refresh_max_deferred))
    end

    if (this.qos_aging_ns < 0.0) begin
      `uvm_fatal(get_name(), $sformatf(
        "qos_aging_ns must be >= 0.0 (got %0.3f)", this.qos_aging_ns))
    end

    if (this.rd_wr_grouping_max < 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "rd_wr_grouping_max must be >= 0 (got %0d)", this.rd_wr_grouping_max))
    end

    if (this.rsp_buf_depth < 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "rsp_buf_depth must be >= 0 (got %0d)", this.rsp_buf_depth))
    end

    if (this.max_inflight_to_device < -1) begin
      `uvm_fatal(get_name(), $sformatf(
        "max_inflight_to_device must be >= -1 (got %0d)",
        this.max_inflight_to_device))
    end
    if (this.max_inflight_to_device < 0) begin
      this.max_inflight_to_device = this.default_max_inflight_to_device(dram_cfg);
    end

    if (this.axi4.aw_outstanding_limit < 0 || this.axi4.ar_outstanding_limit < 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "AXI4 outstanding limits must be >= 0 (aw=%0d ar=%0d)",
        this.axi4.aw_outstanding_limit, this.axi4.ar_outstanding_limit))
    end

    if (this.axi4.aw_pending_depth < 0 || this.axi4.w_data_buf_depth < 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "AXI4 buffer depths must be >= 0 (aw_pending=%0d w_data=%0d)",
        this.axi4.aw_pending_depth, this.axi4.w_data_buf_depth))
    end

    if (this.axi4.decerr_addr_lo.size() != this.axi4.decerr_addr_hi.size()) begin
      `uvm_fatal(get_name(), $sformatf(
        "DECERR range vectors differ in size (lo=%0d hi=%0d)",
        this.axi4.decerr_addr_lo.size(), this.axi4.decerr_addr_hi.size()))
    end

    foreach (this.axi4.decerr_addr_lo[i]) begin
      if (this.axi4.decerr_addr_lo[i] > this.axi4.decerr_addr_hi[i]) begin
        `uvm_fatal(get_name(), $sformatf(
          "DECERR range %0d has lo > hi (lo=0x%0h hi=0x%0h)",
          i, this.axi4.decerr_addr_lo[i], this.axi4.decerr_addr_hi[i]))
      end
    end

    foreach (this.axi4.qos_class_map[i]) begin
      if (this.axi4.qos_class_map[i] < 0) begin
        `uvm_fatal(get_name(), $sformatf(
          "qos_class_map[%0d] must be >= 0 (got %0d)",
          i, this.axi4.qos_class_map[i]))
      end
      if (this.axi4.qos_class_map[i] >= this.qos_class_count) begin
        this.axi4.qos_class_map[i] = this.qos_class_count - 1;
      end
    end

    foreach (this.ports[i]) begin
      if (this.ports[i] == null) begin
        `uvm_fatal(get_name(), $sformatf("ports[%0d] is null", i))
      end
      if (this.ports[i].arb_weight < 0) begin
        `uvm_fatal(get_name(), $sformatf(
          "ports[%0d].arb_weight must be >= 0 (got %0d)",
          i, this.ports[i].arb_weight))
      end
      foreach (this.ports[i].regions[j]) begin
        if (!vip_mc_region_is_valid(this.ports[i].regions[j])) begin
          `uvm_fatal(get_name(), $sformatf(
            "ports[%0d].regions[%0d] has lo > hi (lo=0x%0h hi=0x%0h)",
            i, j, this.ports[i].regions[j].lo, this.ports[i].regions[j].hi))
        end
      end
    end

    this.validate_addr_map(dram_cfg);
  endfunction

  // ---------------------------------------------------------------------------
  // Geometry-derived finite default for the device command window.
  // ---------------------------------------------------------------------------
  protected function int default_max_inflight_to_device(input vip_dram_cfg_t dram_cfg);
    int total_banks;

    total_banks = dram_cfg.N_RANKS_P * dram_cfg.N_BANK_GROUPS_P * dram_cfg.BANKS_PER_BG_P;
    if (total_banks < 1) begin
      return 1;
    end
    return total_banks;
  endfunction

  // ---------------------------------------------------------------------------
  // Validate that the address-map slices cover the DRAM geometry exactly once.
  // ---------------------------------------------------------------------------
  protected function void validate_addr_map(input vip_dram_cfg_t dram_cfg);
    bit [255 : 0] used_bits;

    if (dram_cfg.ADDR_WIDTH_P > 256) begin
      `uvm_fatal(get_name(), $sformatf(
        "ADDR_WIDTH_P=%0d exceeds vip_mc_config validation mask width",
        dram_cfg.ADDR_WIDTH_P))
    end

    used_bits = '0;

    this.validate_addr_slice(
      "byte",
      this.addr_map_policy.byte_lsb,
      $clog2(dram_cfg.ROW_BYTES_P),
      dram_cfg.ADDR_WIDTH_P,
      used_bits);
    this.validate_addr_slice(
      "col",
      this.addr_map_policy.col_lsb,
      dram_cfg.COL_BITS_P,
      dram_cfg.ADDR_WIDTH_P,
      used_bits);
    this.validate_addr_slice(
      "bank",
      this.addr_map_policy.bank_lsb,
      $clog2(dram_cfg.BANKS_PER_BG_P),
      dram_cfg.ADDR_WIDTH_P,
      used_bits);
    this.validate_addr_slice(
      "bg",
      this.addr_map_policy.bg_lsb,
      $clog2(dram_cfg.N_BANK_GROUPS_P),
      dram_cfg.ADDR_WIDTH_P,
      used_bits);
    this.validate_addr_slice(
      "row",
      this.addr_map_policy.row_lsb,
      dram_cfg.ROW_BITS_P,
      dram_cfg.ADDR_WIDTH_P,
      used_bits);
    this.validate_addr_slice(
      "rank",
      this.addr_map_policy.rank_lsb,
      $clog2(dram_cfg.N_RANKS_P),
      dram_cfg.ADDR_WIDTH_P,
      used_bits);

    for (int bit_idx = 0; bit_idx < dram_cfg.ADDR_WIDTH_P; bit_idx++) begin
      if (!used_bits[bit_idx]) begin
        `uvm_fatal(get_name(), $sformatf(
          "addr_map_policy leaves address bit %0d uncovered", bit_idx))
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Validate one address-map slice and mark its occupied bits.
  // ---------------------------------------------------------------------------
  protected function void validate_addr_slice(
    input string         field_name,
    input int            lsb,
    input int            width,
    input int            addr_width,
    ref   bit [255 : 0]  used_bits
  );
    if (width == 0) begin
      return;
    end

    if (lsb < 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "addr_map_policy.%s_lsb must be >= 0 (got %0d)", field_name, lsb))
    end

    if ((lsb + width) > addr_width) begin
      `uvm_fatal(get_name(), $sformatf(
        "addr_map_policy.%s_lsb=%0d width=%0d exceeds ADDR_WIDTH_P=%0d",
        field_name, lsb, width, addr_width))
    end

    for (int bit_idx = lsb; bit_idx < (lsb + width); bit_idx++) begin
      if (used_bits[bit_idx]) begin
        `uvm_fatal(get_name(), $sformatf(
          "addr_map_policy bit %0d overlaps while placing %s",
          bit_idx, field_name))
      end
      used_bits[bit_idx] = 1'b1;
    end
  endfunction

endclass
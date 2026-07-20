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
// vip_mc_refresh
//
// Periodic refresh emitter for vip_mc. It owns the cached tREFI interval and
// publishes REF requests as MC-internal command entries so the backend remains
// the single writer to vip_dram.
// -----------------------------------------------------------------------------
class vip_mc_refresh #(
  vip_dram_cfg_t DRAM_CFG_P = VIP_DRAM_CFG_DEFAULT_C
  ) extends uvm_component;

  typedef vip_mc_cmd_entry #(DRAM_CFG_P) cmd_t;

  vip_mc_config                cfg;
  uvm_analysis_port #(cmd_t)   req_port;

  protected real              tREFI_cached_ns = -1.0;
  protected longint unsigned  ref_ctr = 0;
  protected int unsigned      refresh_count = 0;
  protected process           emit_proc;
  protected bit               armed = 1'b0;

  // Deferred-policy bookkeeping: current postponed-refresh debt, the peak debt
  // reached, and how many forced catch-up bursts have been emitted.
  protected int unsigned      deferred_debt          = 0;
  protected int unsigned      peak_deferred_debt     = 0;
  protected int unsigned      deferred_catchup_count = 0;

  `uvm_component_param_utils(vip_mc_refresh #(DRAM_CFG_P))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
    this.req_port = new("req_port", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Validate the shared config handle.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    super.build_phase(phase);

    if (this.cfg == null) begin
      `uvm_fatal(get_name(), "vip_mc_refresh requires the shared MC cfg handle")
    end

    if ((this.cfg.refresh_policy != VIP_MC_REFRESH_PERIODIC_E) &&
        (this.cfg.refresh_policy != VIP_MC_REFRESH_DEFERRED_E)) begin
      `uvm_fatal(get_name(), "Unsupported refresh_policy")
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Cache the refresh interval selected by vip_mc at start_of_simulation.
  // ---------------------------------------------------------------------------
  function void cache_trefi_ns(input real trefi_ns);
    this.tREFI_cached_ns = trefi_ns;
  endfunction

  // ---------------------------------------------------------------------------
  // (Re-)arm the periodic emitter (§9). vip_mc calls this on every posedge
  // rst_n, including the first deassertion. The emitter runs as an independent
  // forked process: it is intentionally orphaned from this call site so it
  // survives, and is killed only via flush()'s stored process handle. The
  // armed flag (set before the fork) guards against a double-arm. The
  // process::self() capture inside the fork lands before any flush(), because
  // arm() (posedge) and flush() (next negedge) are always separated by the
  // full rst_n-high window.
  // ---------------------------------------------------------------------------
  task arm();
    if (this.tREFI_cached_ns <= 0.0) begin
      `uvm_fatal(get_name(), $sformatf(
        "vip_mc_refresh requires tREFI_cached_ns > 0.0 (got %0.3f)",
        this.tREFI_cached_ns))
    end

    if (this.armed == 1'b1) begin
      return;
    end
    this.armed = 1'b1;

    fork
      begin
        this.emit_proc = process::self();
        forever begin
          #(this.tREFI_cached_ns * 1ns);
          #0;
          if (this.cfg.refresh_policy == VIP_MC_REFRESH_DEFERRED_E) begin
            this.tick_deferred();
          end
          else begin
            this.emit_refresh_burst();
          end
        end
      end
    join_none
  endtask

  // ---------------------------------------------------------------------------
  // One tREFI tick under the deferred policy: a refresh becomes due (debt++). It
  // is postponed until the debt reaches refresh_max_deferred (JEDEC's max of 8
  // postponed refreshes by default), at which point the whole debt is drained in
  // one catch-up burst. Net refresh rate matches periodic; the arrival is bursty.
  // ---------------------------------------------------------------------------
  protected function void tick_deferred();
    int unsigned limit;

    limit = (this.cfg.refresh_max_deferred >= 1) ? this.cfg.refresh_max_deferred : 1;

    this.deferred_debt++;
    if (this.deferred_debt > this.peak_deferred_debt) begin
      this.peak_deferred_debt = this.deferred_debt;
    end

    if (this.deferred_debt >= limit) begin
      repeat (this.deferred_debt) begin
        this.emit_refresh_burst();
      end
      this.deferred_catchup_count++;
      this.deferred_debt = 0;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Kill the periodic emitter and reset the refresh counters (§9). Re-read of
  // tREFI happens on the next arm(); the cached interval is preserved here.
  // ---------------------------------------------------------------------------
  function void flush();
    if (this.emit_proc != null) begin
      this.emit_proc.kill();
      this.emit_proc = null;
    end
    this.armed                  = 1'b0;
    this.ref_ctr                = 0;
    this.refresh_count          = 0;
    this.deferred_debt          = 0;
    this.peak_deferred_debt     = 0;
    this.deferred_catchup_count = 0;
  endfunction

  // ---------------------------------------------------------------------------
  // Emit one REF per rank as MC-internal command entries.
  // ---------------------------------------------------------------------------
  protected function void emit_refresh_burst();
    for (int rank = 0; rank < DRAM_CFG_P.N_RANKS_P; rank++) begin
      cmd_t ref_entry;

      ref_entry = cmd_t::type_id::create($sformatf("ref_rank_%0d_%0d", rank, this.ref_ctr));
      ref_entry.tag               = (64'd1 << 63) | this.ref_ctr;
      ref_entry.port_id           = -1;
      ref_entry.axi4_id           = '0;
      ref_entry.op                = VIP_DRAM_OP_REF_E;
      ref_entry.addr              = '0;
      ref_entry.beats             = 1;
      ref_entry.has_explicit_rank = 1'b1;
      ref_entry.rank              = rank;
      ref_entry.enqueue_time      = $realtime;

      this.ref_ctr++;
      this.refresh_count++;
      this.req_port.write(ref_entry);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Return how many REF requests this component has emitted.
  // ---------------------------------------------------------------------------
  function int get_refresh_count();
    return this.refresh_count;
  endfunction

  // ---------------------------------------------------------------------------
  // Deferred-policy observability: the live postponed-refresh debt, the peak debt
  // reached (should never exceed refresh_max_deferred), and the number of forced
  // catch-up bursts emitted.
  // ---------------------------------------------------------------------------
  function int get_deferred_debt();
    return this.deferred_debt;
  endfunction

  function int get_peak_deferred_debt();
    return this.peak_deferred_debt;
  endfunction

  function int get_deferred_catchup_count();
    return this.deferred_catchup_count;
  endfunction

endclass
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
// vip_mc_cmd_queue
//
// Backend-owned QoS queue for MC-internal requests. Requests are admitted into
// per-class FIFOs, aged upward logically at pick time, and issued with strict
// same-stream ordering for a given {port_id, axi4_id, op} stream.
// -----------------------------------------------------------------------------
class vip_mc_cmd_queue #(
  vip_dram_cfg_t DRAM_CFG_P = VIP_DRAM_CFG_DEFAULT_C
  ) extends uvm_component;

  typedef vip_mc_cmd_entry #(DRAM_CFG_P) cmd_t;
  typedef vip_dram_rsp     #(DRAM_CFG_P) rsp_t;

  vip_mc_config cfg;
  uvm_event     state_changed_ev;

  protected cmd_t             class_q[][$];
  protected cmd_t             inflight_cmd_by_tag[longint unsigned];
  protected longint unsigned  oldest_queued_admit_order_by_stream[string];
  protected longint unsigned  oldest_inflight_admit_order_by_stream[string];
  protected longint unsigned  next_tag = 1;
  protected longint unsigned  next_admit_order = 1;
  protected int               peak_depth = 0;
  protected int unsigned      coalesced_write_count = 0;

  // Residual observability (§11): pending-depth occupancy histogram. Sampled on
  // every depth transition (each admit and each dequeue), so occupancy_hist[d]
  // counts how many times the queue was observed at depth d. Guarded by
  // perf_counters_enabled; cleared per epoch by clear_perf_counters().
  protected longint unsigned  occupancy_hist[int];
  protected longint unsigned  occupancy_samples = 0;

  `uvm_component_param_utils(vip_mc_cmd_queue #(DRAM_CFG_P))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Validate the injected config and size the per-class FIFOs.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    super.build_phase(phase);

    if (this.cfg == null) begin
      `uvm_fatal(get_name(), "vip_mc_cmd_queue requires a non-null mc_cfg handle")
    end

    if (this.cfg.qos_class_count < 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "qos_class_count must be >= 1 (got %0d)", this.cfg.qos_class_count))
    end

    this.class_q = new[this.cfg.qos_class_count];
  endfunction

  // ---------------------------------------------------------------------------
  // Admit one FE-emitted entry into its base QoS class.
  // ---------------------------------------------------------------------------
  function void admit(input cmd_t entry);
    int unsigned class_idx;

    if (entry == null) begin
      `uvm_fatal(get_name(), "admit() received a null command entry")
    end

    class_idx = this.clamp_qos_class(entry.qos_class);
    entry.qos_class   = class_idx;
    entry.admit_time  = $realtime;
    entry.admit_order = this.next_admit_order;
    this.next_admit_order++;
    this.class_q[class_idx].push_back(entry);
    this.update_oldest_queued_stream_order(entry);

    if (this.get_pending_count() > this.peak_depth) begin
      this.peak_depth = this.get_pending_count();
    end
    this.record_occupancy();
  endfunction

  // ---------------------------------------------------------------------------
  // Residual observability (§11): sample the current pending depth into the
  // occupancy histogram. Called on every depth transition; no-op unless
  // perf_counters_enabled.
  // ---------------------------------------------------------------------------
  protected function void record_occupancy();
    int depth;

    if ((this.cfg == null) || (this.cfg.perf_counters_enabled != TRUE)) begin
      return;
    end
    depth = this.get_pending_count();
    if (this.occupancy_hist.exists(depth)) begin
      this.occupancy_hist[depth]++;
    end
    else begin
      this.occupancy_hist[depth] = 1;
    end
    this.occupancy_samples++;
  endfunction

  // ---------------------------------------------------------------------------
  // Write coalescing (§11). Try to merge one newly arrived write into an already
  // pending write of the same ordered stream targeting the same row-word address,
  // instead of admitting it separately. Returns 1 if merged (caller must NOT
  // admit the entry); 0 if it should be admitted normally.
  //
  // Safety: the primary must be the NEWEST outstanding entry (pending or inflight)
  // of that stream, so there is no intervening same-id write between them and
  // W-after-W order is preserved (the newer write's bytes win on overlap, exactly
  // as issuing them in order would leave the line). Never merges exclusive or
  // pre-resolved (DECERR / 4 KB) writes.
  //
  // Cross-stream caveat: only same-stream ({port,id,WR}) writes merge, and the MC
  // does not order the RD and WR streams against each other for the same address
  // (matching AXI4 — R/W ordering needs master serialization). A read to a
  // coalesced row can therefore observe a later-merged write's bytes early; this
  // is consistent with the model's ordering but must not be relied on the other
  // way (see README write_coalescing_enable).
  // ---------------------------------------------------------------------------
  function bit try_coalesce_write(input cmd_t entry);
    string           key;
    longint unsigned newest_order;
    cmd_t            newest_pending;

    if ((this.cfg == null) || (this.cfg.write_coalescing_enable != TRUE)) begin
      return 1'b0;
    end
    if ((entry == null) || (entry.op != VIP_DRAM_OP_WR_E) ||
        entry.is_exclusive || entry.pre_resolved) begin
      return 1'b0;
    end

    key            = this.stream_key(entry);
    newest_order   = 0;
    newest_pending = null;

    // Newest same-stream pending candidate.
    foreach (this.class_q[class_idx]) begin
      foreach (this.class_q[class_idx][entry_idx]) begin
        cmd_t p;

        p = this.class_q[class_idx][entry_idx];
        if (this.stream_key(p) != key) begin
          continue;
        end
        if (p.admit_order >= newest_order) begin
          newest_order   = p.admit_order;
          newest_pending = p;
        end
      end
    end

    // If any inflight same-stream write is newer than the newest pending one, the
    // pending candidate is not the tail of the stream — do not merge.
    foreach (this.inflight_cmd_by_tag[tag]) begin
      cmd_t f;

      f = this.inflight_cmd_by_tag[tag];
      if (this.stream_key(f) != key) begin
        continue;
      end
      if (f.admit_order >= newest_order) begin
        newest_order   = f.admit_order;
        newest_pending = null;   // tail is inflight, not mergeable
      end
    end

    if (newest_pending == null) begin
      return 1'b0;
    end
    if (newest_pending.is_exclusive || newest_pending.pre_resolved) begin
      return 1'b0;
    end
    if (!this.same_row_word(newest_pending, entry)) begin
      return 1'b0;
    end

    this.overlay_write(newest_pending, entry);
    newest_pending.merged_writes.push_back(entry);
    this.coalesced_write_count++;
    if (this.state_changed_ev != null) begin
      this.state_changed_ev.trigger();
    end
    return 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether two write entries address the same row-word (same aligned
  // address, rank, and device beat count), so their payloads line up index-for-
  // index for an overlay merge.
  // ---------------------------------------------------------------------------
  protected function bit same_row_word(input cmd_t lhs, input cmd_t rhs);
    longint unsigned align_mask;

    if ((lhs == null) || (rhs == null)) begin
      return 1'b0;
    end
    if (lhs.beats != rhs.beats) begin
      return 1'b0;
    end
    if (lhs.has_explicit_rank != rhs.has_explicit_rank) begin
      return 1'b0;
    end
    if (lhs.has_explicit_rank && (lhs.rank != rhs.rank)) begin
      return 1'b0;
    end
    if ((lhs.wdata.size() != rhs.wdata.size()) ||
        (lhs.wstrb.size() != rhs.wstrb.size())) begin
      return 1'b0;
    end

    // Compare where the payloads actually land on the device, not the protocol
    // start addresses: two WRAP writes over the same region can start at
    // different offsets inside it and still be row-for-row overlayable.
    align_mask = ~longint'(DRAM_CFG_P.ROW_BYTES_P - 1);
    return (lhs.get_dev_addr() & align_mask) == (rhs.get_dev_addr() & align_mask);
  endfunction

  // ---------------------------------------------------------------------------
  // Overlay the source write's enabled byte lanes onto the destination (primary)
  // write: for every strobe-enabled byte the newer (source) data wins and the
  // destination strobe is set. Destination bytes the source does not write are
  // left untouched, so the merged line equals issuing dst then src in order.
  // ---------------------------------------------------------------------------
  protected function void overlay_write(input cmd_t dst, input cmd_t src);
    foreach (src.wdata[beat_idx]) begin
      if (beat_idx >= dst.wdata.size()) begin
        break;
      end
      for (int byte_idx = 0; byte_idx < DRAM_CFG_P.ROW_BYTES_P; byte_idx++) begin
        if (src.wstrb[beat_idx][byte_idx]) begin
          dst.wdata[beat_idx][(8 * byte_idx) +: 8] = src.wdata[beat_idx][(8 * byte_idx) +: 8];
          dst.wstrb[beat_idx][byte_idx] = 1'b1;
        end
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Return the lifetime count of writes merged into a coalesced primary (§11).
  // ---------------------------------------------------------------------------
  function int unsigned get_coalesced_write_count();
    return this.coalesced_write_count;
  endfunction

  // ---------------------------------------------------------------------------
  // Pick the next eligible entry by effective class, then FIFO order.
  // ---------------------------------------------------------------------------
  function bit pick(output cmd_t entry);
    int               selected_list_idx;
    int               selected_effective_class;
    longint unsigned  selected_admit_order;
    int               class_idx_q[$];
    int               entry_idx_q[$];

    entry = null;
    selected_list_idx = -1;
    selected_effective_class = -1;
    selected_admit_order = '1;

    selected_effective_class = this.get_highest_effective_class();
    if (selected_effective_class < 0) begin
      return 1'b0;
    end

    this.get_eligible_entries_in_effective_class(
      selected_effective_class,
      class_idx_q,
      entry_idx_q);

    foreach (class_idx_q[i]) begin
      cmd_t candidate;

      if (!this.peek_entry(class_idx_q[i], entry_idx_q[i], candidate)) begin
        continue;
      end
      if ((selected_list_idx < 0) || (candidate.admit_order < selected_admit_order)) begin
        selected_list_idx   = i;
        selected_admit_order = candidate.admit_order;
      end
    end

    if (selected_list_idx < 0) begin
      return 1'b0;
    end

    return this.take_entry(
      class_idx_q[selected_list_idx],
      entry_idx_q[selected_list_idx],
      entry);
  endfunction

  // ---------------------------------------------------------------------------
  // Return the highest effective QoS class that currently has an eligible entry.
  // ---------------------------------------------------------------------------
  function int get_highest_effective_class();
    int selected_effective_class;

    selected_effective_class = -1;

    for (int class_idx = 0; class_idx < this.class_q.size(); class_idx++) begin
      cmd_t         candidate;
      int unsigned  effective_class;
      int           candidate_idx;

      candidate_idx = this.find_first_eligible_index_in_class(class_idx);
      if (candidate_idx < 0) begin
        continue;
      end

      candidate = this.class_q[class_idx][candidate_idx];
      effective_class = this.get_effective_qos_class(candidate);
      if (int'(effective_class) > selected_effective_class) begin
        selected_effective_class = int'(effective_class);
      end
    end

    return selected_effective_class;
  endfunction

  // ---------------------------------------------------------------------------
  // Collect every currently eligible entry whose effective class matches the
  // supplied target class.
  // ---------------------------------------------------------------------------
  function void get_eligible_entries_in_effective_class(
    input  int target_effective_class,
    output int class_idx_q[$],
    output int entry_idx_q[$]
  );
    class_idx_q.delete();
    entry_idx_q.delete();

    if (target_effective_class < 0) begin
      return;
    end

    for (int class_idx = 0; class_idx < this.class_q.size(); class_idx++) begin
      foreach (this.class_q[class_idx][entry_idx]) begin
        cmd_t queued_entry;

        queued_entry = this.class_q[class_idx][entry_idx];
        if (this.is_stream_blocked(queued_entry)) begin
          continue;
        end
        if (int'(this.get_effective_qos_class(queued_entry)) != target_effective_class) begin
          continue;
        end

        class_idx_q.push_back(class_idx);
        entry_idx_q.push_back(entry_idx);
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Peek one queued entry by its class and in-class index.
  // ---------------------------------------------------------------------------
  function bit peek_entry(
    input  int   class_idx,
    input  int   entry_idx,
    output cmd_t entry
  );
    entry = null;

    if ((class_idx < 0) || (class_idx >= this.class_q.size())) begin
      return 1'b0;
    end
    if ((entry_idx < 0) || (entry_idx >= this.class_q[class_idx].size())) begin
      return 1'b0;
    end

    entry = this.class_q[class_idx][entry_idx];
    return 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Remove one queued entry by its class and in-class index.
  // ---------------------------------------------------------------------------
  function bit take_entry(
    input  int   class_idx,
    input  int   entry_idx,
    output cmd_t entry
  );
    entry = null;

    if (!this.peek_entry(class_idx, entry_idx, entry)) begin
      return 1'b0;
    end

    this.class_q[class_idx].delete(entry_idx);
    this.rebuild_oldest_queued_stream_order(this.stream_key(entry));
    this.record_occupancy();
    return 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether at least one queued entry is currently issuable.
  // ---------------------------------------------------------------------------
  function bit has_issuable_entry();
    for (int class_idx = 0; class_idx < this.class_q.size(); class_idx++) begin
      if (this.find_first_eligible_index_in_class(class_idx) >= 0) begin
        return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // Stamp the flat tag and move one picked entry into the inflight map.
  // ---------------------------------------------------------------------------
  function void enqueue(input cmd_t entry);
    if (entry == null) begin
      `uvm_fatal(get_name(), "enqueue() received a null command entry")
    end

    entry.tag = this.next_tag;
    this.next_tag++;
    entry.enqueue_time = $realtime;
    this.inflight_cmd_by_tag[entry.tag] = entry;
    this.update_oldest_inflight_stream_order(entry);
  endfunction

  // ---------------------------------------------------------------------------
  // Retire one device completion by tag and return the owning entry.
  // ---------------------------------------------------------------------------
  function bit complete_by_rsp(input rsp_t rsp, output cmd_t entry);
    entry = null;

    if (!this.inflight_cmd_by_tag.exists(rsp.tag)) begin
      return 1'b0;
    end

    entry = this.inflight_cmd_by_tag[rsp.tag];
    this.inflight_cmd_by_tag.delete(rsp.tag);
    this.rebuild_oldest_inflight_stream_order(this.stream_key(entry));
    if (this.state_changed_ev != null) begin
      this.state_changed_ev.trigger();
    end
    return 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Clear queued and inflight state while preserving the flat tag sequence.
  // ---------------------------------------------------------------------------
  function void flush();
    foreach (this.class_q[class_idx]) begin
      this.class_q[class_idx].delete();
    end
    this.inflight_cmd_by_tag.delete();
    this.oldest_queued_admit_order_by_stream.delete();
    this.oldest_inflight_admit_order_by_stream.delete();
    this.record_occupancy();   // sample the depth N->0 drop on reset/flush
    if (this.state_changed_ev != null) begin
      this.state_changed_ev.trigger();
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Return the number of admitted but not yet issued entries.
  // ---------------------------------------------------------------------------
  function int get_pending_count();
    int pending_count;

    pending_count = 0;
    foreach (this.class_q[class_idx]) begin
      pending_count += this.class_q[class_idx].size();
    end
    return pending_count;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the high-water mark across all QoS-class FIFOs.
  // ---------------------------------------------------------------------------
  function int get_peak_depth();
    return this.peak_depth;
  endfunction

  // ---------------------------------------------------------------------------
  // Residual observability (§11): return how many times the pending queue was
  // observed at exactly `depth` entries (0 for a depth never seen).
  // ---------------------------------------------------------------------------
  function longint unsigned get_occupancy_hist_count(input int depth);
    if (!this.occupancy_hist.exists(depth)) begin
      return 0;
    end
    return this.occupancy_hist[depth];
  endfunction

  // ---------------------------------------------------------------------------
  // Total occupancy samples taken (sum over all histogram buckets).
  // ---------------------------------------------------------------------------
  function longint unsigned get_occupancy_sample_count();
    return this.occupancy_samples;
  endfunction

  // ---------------------------------------------------------------------------
  // Reset the §8.8 high-water mark for a fresh post-reset epoch (handle_reset).
  // ---------------------------------------------------------------------------
  function void clear_perf_counters();
    this.peak_depth = 0;
    this.coalesced_write_count = 0;
    this.occupancy_hist.delete();
    this.occupancy_samples = 0;
  endfunction

  // ---------------------------------------------------------------------------
  // Clamp one requested QoS class into the configured class range.
  // ---------------------------------------------------------------------------
  protected function int unsigned clamp_qos_class(input int requested_class);
    if (requested_class < 0) begin
      return 0;
    end

    if (requested_class >= this.cfg.qos_class_count) begin
      return this.cfg.qos_class_count - 1;
    end

    return requested_class;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the effective class after applying aging promotion.
  // ---------------------------------------------------------------------------
  protected function int unsigned get_effective_qos_class(input cmd_t entry);
    realtime      waited_ns;
    int           promotions;
    int unsigned  effective_class;

    effective_class = this.clamp_qos_class(entry.qos_class);
    if (this.cfg.qos_aging_ns <= 0.0) begin
      return effective_class;
    end

    waited_ns = $realtime - entry.admit_time;
    if (waited_ns <= 0.0) begin
      return effective_class;
    end

    promotions = int'(waited_ns / this.cfg.qos_aging_ns);
    return this.clamp_qos_class(int'(effective_class) + promotions);
  endfunction

  // ---------------------------------------------------------------------------
  // Return the first issuable index in one QoS class, or -1 if none are ready.
  // ---------------------------------------------------------------------------
  protected function int find_first_eligible_index_in_class(input int class_idx);
    for (int entry_idx = 0; entry_idx < this.class_q[class_idx].size(); entry_idx++) begin
      if (!this.is_stream_blocked(this.class_q[class_idx][entry_idx])) begin
        return entry_idx;
      end
    end
    return -1;
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether an older queued or inflight request blocks this stream.
  // ---------------------------------------------------------------------------
  protected function bit is_stream_blocked(input cmd_t candidate);
    string stream_name;

    stream_name = this.stream_key(candidate);
    if (this.oldest_queued_admit_order_by_stream.exists(stream_name) &&
        (this.oldest_queued_admit_order_by_stream[stream_name] < candidate.admit_order)) begin
      return 1'b1;
    end

    if (this.oldest_inflight_admit_order_by_stream.exists(stream_name) &&
        (this.oldest_inflight_admit_order_by_stream[stream_name] < candidate.admit_order)) begin
      return 1'b1;
    end

    return 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the per-stream ordering key for queued/inflight maps.
  // ---------------------------------------------------------------------------
  protected function string stream_key(input cmd_t entry);
    return $sformatf("%0d:%0h:%0d", entry.port_id, entry.axi4_id, entry.op);
  endfunction

  // ---------------------------------------------------------------------------
  // Update the oldest queued admit-order map for one newly admitted stream.
  // ---------------------------------------------------------------------------
  protected function void update_oldest_queued_stream_order(input cmd_t entry);
    string stream_name;

    stream_name = this.stream_key(entry);
    if (!this.oldest_queued_admit_order_by_stream.exists(stream_name) ||
        (entry.admit_order < this.oldest_queued_admit_order_by_stream[stream_name])) begin
      this.oldest_queued_admit_order_by_stream[stream_name] = entry.admit_order;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Rebuild the oldest queued admit-order map for one stream after dequeue.
  // ---------------------------------------------------------------------------
  protected function void rebuild_oldest_queued_stream_order(input string stream_name);
    longint unsigned oldest_order;
    bit              found_order;

    oldest_order = '1;
    found_order  = 1'b0;
    foreach (this.class_q[class_idx]) begin
      foreach (this.class_q[class_idx][entry_idx]) begin
        cmd_t queued_entry;

        queued_entry = this.class_q[class_idx][entry_idx];
        if (this.stream_key(queued_entry) != stream_name) begin
          continue;
        end
        if (!found_order || (queued_entry.admit_order < oldest_order)) begin
          oldest_order = queued_entry.admit_order;
          found_order  = 1'b1;
        end
      end
    end

    if (found_order) begin
      this.oldest_queued_admit_order_by_stream[stream_name] = oldest_order;
    end
    else begin
      this.oldest_queued_admit_order_by_stream.delete(stream_name);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Update the oldest inflight admit-order map for one newly issued stream.
  // ---------------------------------------------------------------------------
  protected function void update_oldest_inflight_stream_order(input cmd_t entry);
    string stream_name;

    stream_name = this.stream_key(entry);
    if (!this.oldest_inflight_admit_order_by_stream.exists(stream_name) ||
        (entry.admit_order < this.oldest_inflight_admit_order_by_stream[stream_name])) begin
      this.oldest_inflight_admit_order_by_stream[stream_name] = entry.admit_order;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Rebuild the oldest inflight admit-order map for one stream after retire.
  // ---------------------------------------------------------------------------
  protected function void rebuild_oldest_inflight_stream_order(input string stream_name);
    longint unsigned oldest_order;
    bit              found_order;

    oldest_order = '1;
    found_order  = 1'b0;
    foreach (this.inflight_cmd_by_tag[tag]) begin
      cmd_t inflight_entry;

      inflight_entry = this.inflight_cmd_by_tag[tag];
      if (this.stream_key(inflight_entry) != stream_name) begin
        continue;
      end
      if (!found_order || (inflight_entry.admit_order < oldest_order)) begin
        oldest_order = inflight_entry.admit_order;
        found_order  = 1'b1;
      end
    end

    if (found_order) begin
      this.oldest_inflight_admit_order_by_stream[stream_name] = oldest_order;
    end
    else begin
      this.oldest_inflight_admit_order_by_stream.delete(stream_name);
    end
  endfunction

endclass
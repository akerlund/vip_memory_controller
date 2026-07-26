################################################################################
##
## Copyright (C) 2026 Fredrik Akerlund
##
## Permission is hereby granted, free of charge, to any person obtaining a copy
## of this software and associated documentation files (the "Software"), to deal
## in the Software without restriction, including without limitation the rights
## to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
## copies of the Software, and to permit persons to whom the Software is
## furnished to do so, subject to the following conditions:
##
## The above copyright notice and this permission notice shall be included in
## all copies or substantial portions of the Software.
##
## THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
## IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
## FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
## AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
## LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
## OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
## SOFTWARE.
##
## Description:
## pyUVM port of vip_mc/sv/vip_mc_cmd_queue.sv.
##
################################################################################

from __future__ import annotations

from vip_dram_types_pkg import VIP_DRAM_CFG_DEFAULT, VipDramOp


class vip_mc_cmd_queue:

  def __init__(self, name="vip_mc_cmd_queue", cfg=None,
               geom=VIP_DRAM_CFG_DEFAULT, now_func=None, state_changed_ev=None):
    if cfg is None:
      from vip_mc_config import vip_mc_config
      cfg = vip_mc_config()
    self.name = name
    self.cfg = cfg
    self.geom = geom
    self.now_func = now_func or (lambda: 0.0)
    self.state_changed_ev = state_changed_ev
    self.class_q = [[] for _ in range(self.cfg.qos_class_count)]
    self.inflight_cmd_by_tag = {}
    self.oldest_queued_admit_order_by_stream = {}
    self.oldest_inflight_admit_order_by_stream = {}
    self.next_tag = 1
    self.next_admit_order = 1
    self.peak_depth = 0
    self.coalesced_write_count = 0
    self.occupancy_hist = {}
    self.occupancy_samples = 0

  def _now(self) -> float:
    return float(self.now_func())

  def _trigger(self) -> None:
    if self.state_changed_ev is None:
      return
    if hasattr(self.state_changed_ev, "trigger"):
      self.state_changed_ev.trigger()
    elif hasattr(self.state_changed_ev, "set"):
      self.state_changed_ev.set()

  def admit(self, entry) -> None:
    if entry is None:
      raise RuntimeError(f"[{self.name}] admit() received a null command entry")
    class_idx = self.clamp_qos_class(entry.qos_class)
    entry.qos_class = class_idx
    entry.admit_time = self._now()
    entry.admit_order = self.next_admit_order
    self.next_admit_order += 1
    self.class_q[class_idx].append(entry)
    self.update_oldest_queued_stream_order(entry)
    self.peak_depth = max(self.peak_depth, self.get_pending_count())
    self.record_occupancy()

  def record_occupancy(self) -> None:
    if self.cfg is None or not self.cfg.perf_counters_enabled:
      return
    depth = self.get_pending_count()
    self.occupancy_hist[depth] = self.occupancy_hist.get(depth, 0) + 1
    self.occupancy_samples += 1

  def try_coalesce_write(self, entry) -> bool:
    if self.cfg is None or not self.cfg.write_coalescing_enable:
      return False
    if entry is None or entry.op != VipDramOp.WR or entry.is_exclusive:
      return False
    if entry.pre_resolved:
      return False

    key = self.stream_key(entry)
    newest_order = 0
    newest_pending = None

    for q in self.class_q:
      for p in q:
        if self.stream_key(p) != key:
          continue
        if p.admit_order >= newest_order:
          newest_order = p.admit_order
          newest_pending = p

    for f in self.inflight_cmd_by_tag.values():
      if self.stream_key(f) != key:
        continue
      if f.admit_order >= newest_order:
        newest_order = f.admit_order
        newest_pending = None

    if newest_pending is None:
      return False
    if newest_pending.is_exclusive or newest_pending.pre_resolved:
      return False
    if not self.same_row_word(newest_pending, entry):
      return False

    self.overlay_write(newest_pending, entry)
    newest_pending.merged_writes.append(entry)
    self.coalesced_write_count += 1
    self._trigger()
    return True

  def same_row_word(self, lhs, rhs) -> bool:
    if lhs is None or rhs is None:
      return False
    if lhs.beats != rhs.beats:
      return False
    if lhs.has_explicit_rank != rhs.has_explicit_rank:
      return False
    if lhs.has_explicit_rank and lhs.rank != rhs.rank:
      return False
    if len(lhs.wdata) != len(rhs.wdata) or len(lhs.wstrb) != len(rhs.wstrb):
      return False
    align_mask = ~(self.geom.ROW_BYTES_P - 1)
    return (lhs.addr & align_mask) == (rhs.addr & align_mask)

  def overlay_write(self, dst, src) -> None:
    for beat_idx, src_data in enumerate(src.wdata):
      if beat_idx >= len(dst.wdata):
        break
      src_strb = src.wstrb[beat_idx]
      dst_strb = dst.wstrb[beat_idx]
      dst_data = dst.wdata[beat_idx]
      for byte_idx in range(self.geom.ROW_BYTES_P):
        if (src_strb >> byte_idx) & 1:
          byte = (src_data >> (8 * byte_idx)) & 0xff
          dst_data &= ~(0xff << (8 * byte_idx))
          dst_data |= byte << (8 * byte_idx)
          dst_strb |= 1 << byte_idx
      dst.wdata[beat_idx] = dst_data
      dst.wstrb[beat_idx] = dst_strb

  def get_coalesced_write_count(self) -> int:
    return self.coalesced_write_count

  def pick(self):
    selected_effective_class = self.get_highest_effective_class()
    if selected_effective_class < 0:
      return None

    entries = self.get_eligible_entries_in_effective_class(selected_effective_class)
    selected = None
    selected_order = None
    for class_idx, entry_idx in entries:
      candidate = self.peek_entry(class_idx, entry_idx)
      if candidate is None:
        continue
      if selected is None or candidate.admit_order < selected_order:
        selected = (class_idx, entry_idx)
        selected_order = candidate.admit_order

    if selected is None:
      return None
    return self.take_entry(selected[0], selected[1])

  def get_highest_effective_class(self) -> int:
    selected = -1
    for class_idx in range(len(self.class_q)):
      candidate_idx = self.find_first_eligible_index_in_class(class_idx)
      if candidate_idx < 0:
        continue
      candidate = self.class_q[class_idx][candidate_idx]
      selected = max(selected, int(self.get_effective_qos_class(candidate)))
    return selected

  def get_eligible_entries_in_effective_class(self, target_effective_class: int):
    if target_effective_class < 0:
      return []
    entries = []
    for class_idx, q in enumerate(self.class_q):
      for entry_idx, queued_entry in enumerate(q):
        if self.is_stream_blocked(queued_entry):
          continue
        if int(self.get_effective_qos_class(queued_entry)) != target_effective_class:
          continue
        entries.append((class_idx, entry_idx))
    return entries

  def peek_entry(self, class_idx: int, entry_idx: int):
    if class_idx < 0 or class_idx >= len(self.class_q):
      return None
    if entry_idx < 0 or entry_idx >= len(self.class_q[class_idx]):
      return None
    return self.class_q[class_idx][entry_idx]

  def take_entry(self, class_idx: int, entry_idx: int):
    entry = self.peek_entry(class_idx, entry_idx)
    if entry is None:
      return None
    del self.class_q[class_idx][entry_idx]
    self.rebuild_oldest_queued_stream_order(self.stream_key(entry))
    self.record_occupancy()
    return entry

  def has_issuable_entry(self) -> bool:
    return any(self.find_first_eligible_index_in_class(i) >= 0
               for i in range(len(self.class_q)))

  def enqueue(self, entry) -> None:
    if entry is None:
      raise RuntimeError(f"[{self.name}] enqueue() received a null command entry")
    entry.tag = self.next_tag
    self.next_tag += 1
    entry.enqueue_time = self._now()
    self.inflight_cmd_by_tag[entry.tag] = entry
    self.update_oldest_inflight_stream_order(entry)

  def complete_by_rsp(self, rsp):
    entry = self.inflight_cmd_by_tag.pop(rsp.tag, None)
    if entry is None:
      return None
    self.rebuild_oldest_inflight_stream_order(self.stream_key(entry))
    self._trigger()
    return entry

  def flush(self) -> None:
    for q in self.class_q:
      q.clear()
    self.inflight_cmd_by_tag.clear()
    self.oldest_queued_admit_order_by_stream.clear()
    self.oldest_inflight_admit_order_by_stream.clear()
    self.record_occupancy()
    self._trigger()

  def get_pending_count(self) -> int:
    return sum(len(q) for q in self.class_q)

  def get_peak_depth(self) -> int:
    return self.peak_depth

  def get_occupancy_hist_count(self, depth: int) -> int:
    return self.occupancy_hist.get(int(depth), 0)

  def get_occupancy_sample_count(self) -> int:
    return self.occupancy_samples

  def clear_perf_counters(self) -> None:
    self.peak_depth = 0
    self.coalesced_write_count = 0
    self.occupancy_hist.clear()
    self.occupancy_samples = 0

  def clamp_qos_class(self, requested_class: int) -> int:
    if requested_class < 0:
      return 0
    if requested_class >= self.cfg.qos_class_count:
      return self.cfg.qos_class_count - 1
    return int(requested_class)

  def get_effective_qos_class(self, entry) -> int:
    effective_class = self.clamp_qos_class(entry.qos_class)
    if self.cfg.qos_aging_ns <= 0.0:
      return effective_class
    waited_ns = self._now() - entry.admit_time
    if waited_ns <= 0.0:
      return effective_class
    promotions = int(waited_ns / self.cfg.qos_aging_ns)
    return self.clamp_qos_class(effective_class + promotions)

  def find_first_eligible_index_in_class(self, class_idx: int) -> int:
    for entry_idx, entry in enumerate(self.class_q[class_idx]):
      if not self.is_stream_blocked(entry):
        return entry_idx
    return -1

  def is_stream_blocked(self, candidate) -> bool:
    stream_name = self.stream_key(candidate)
    queued_oldest = self.oldest_queued_admit_order_by_stream.get(stream_name)
    if queued_oldest is not None and queued_oldest < candidate.admit_order:
      return True
    inflight_oldest = self.oldest_inflight_admit_order_by_stream.get(stream_name)
    if inflight_oldest is not None and inflight_oldest < candidate.admit_order:
      return True
    return False

  @staticmethod
  def stream_key(entry) -> str:
    return f"{entry.port_id}:{int(entry.axi4_id):x}:{int(entry.op)}"

  def update_oldest_queued_stream_order(self, entry) -> None:
    stream_name = self.stream_key(entry)
    old = self.oldest_queued_admit_order_by_stream.get(stream_name)
    if old is None or entry.admit_order < old:
      self.oldest_queued_admit_order_by_stream[stream_name] = entry.admit_order

  def rebuild_oldest_queued_stream_order(self, stream_name: str) -> None:
    found = None
    for q in self.class_q:
      for queued_entry in q:
        if self.stream_key(queued_entry) != stream_name:
          continue
        if found is None or queued_entry.admit_order < found:
          found = queued_entry.admit_order
    if found is None:
      self.oldest_queued_admit_order_by_stream.pop(stream_name, None)
    else:
      self.oldest_queued_admit_order_by_stream[stream_name] = found

  def update_oldest_inflight_stream_order(self, entry) -> None:
    stream_name = self.stream_key(entry)
    old = self.oldest_inflight_admit_order_by_stream.get(stream_name)
    if old is None or entry.admit_order < old:
      self.oldest_inflight_admit_order_by_stream[stream_name] = entry.admit_order

  def rebuild_oldest_inflight_stream_order(self, stream_name: str) -> None:
    found = None
    for inflight_entry in self.inflight_cmd_by_tag.values():
      if self.stream_key(inflight_entry) != stream_name:
        continue
      if found is None or inflight_entry.admit_order < found:
        found = inflight_entry.admit_order
    if found is None:
      self.oldest_inflight_admit_order_by_stream.pop(stream_name, None)
    else:
      self.oldest_inflight_admit_order_by_stream[stream_name] = found

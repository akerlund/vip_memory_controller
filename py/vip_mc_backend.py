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
## pyUVM port of the simulator-independent backend semantics in
## vip_mc/sv/vip_mc_backend.sv.
##
################################################################################

from __future__ import annotations

import cocotb
from cocotb.triggers import Event, Timer
from pyuvm import (
  ConfigDB, UVMConfigItemNotFound, uvm_analysis_port, uvm_subscriber,
  uvm_root,
)

from vip_dram_req import VipDramReq
from vip_dram_types_pkg import VIP_DRAM_CFG_DEFAULT, VipDramFault, VipDramOp

from vip_mc_activity_fifo import vip_mc_activity_fifo
from vip_mc_axi4_types_pkg import (
  VIP_MC_AXI4_RESP_EXOKAY_C, VIP_MC_AXI4_RESP_OKAY_C,
  VIP_MC_AXI4_RESP_SLVERR_C,
)
from vip_mc_cmd_queue import vip_mc_cmd_queue
from vip_mc_status_snapshot import latency_bucket
from vip_mc_types_pkg import VipMcStatusStall


PREDICT_EPS_C = 0.001


class _UvmEvent:

  def __init__(self):
    self._on = False
    self._ev = Event()

  def trigger(self):
    self._on = True
    self._ev.set()

  def reset(self):
    self._on = False
    self._ev.clear()

  async def wait_ptrigger(self):
    if self._on:
      return
    await self._ev.wait()

  async def wait_trigger(self):
    self._ev.clear()
    await self._ev.wait()


class _ActivitySubscriber(uvm_subscriber):

  def __init__(self, name, parent, fifo):
    super().__init__(name, parent)
    self.fifo = fifo

  def write(self, item):
    self.fifo.write(item)


def _unique_root_name(name: str) -> str:
  root = uvm_root()
  if name not in root._children:
    return name
  idx = 1
  while f"{name}_{idx}" in root._children:
    idx += 1
  return f"{name}_{idx}"


class vip_mc_backend(uvm_subscriber):

  def __init__(self, name="vip_mc_backend", parent=None, mc_cfg=None, dram=None,
               n_ports=1, geom=VIP_DRAM_CFG_DEFAULT, now_func=None):
    if parent is None:
      name = _unique_root_name(name)
    super().__init__(name, parent)
    if mc_cfg is None:
      from vip_mc_config import vip_mc_config
      mc_cfg = vip_mc_config()
      mc_cfg.ensure_port_count(n_ports)
    self.mc_cfg = mc_cfg
    self.dram = dram
    self.n_ports = n_ports
    self.geom = geom
    self.now_func = now_func or (lambda: 0.0)
    self.state_changed_event = _UvmEvent()
    self.init_gate_event = _UvmEvent()
    self.cmd_queue = vip_mc_cmd_queue(
        "cmd_queue", mc_cfg, geom, self.now_func, self.state_changed_event)
    self.fe_fifo = [
        vip_mc_activity_fifo(f"fe_fifo_{i}", self.state_changed_event)
        for i in range(n_ports)
    ]
    self.fe_export = [
        _ActivitySubscriber(f"fe_export_{i}", self, self.fe_fifo[i])
        for i in range(n_ports)
    ]
    self.ref_fifo = vip_mc_activity_fifo("ref_fifo", self.state_changed_event)
    self.ref_export = _ActivitySubscriber("ref_export", self, self.ref_fifo)
    self.req_port = uvm_analysis_port("req_port", self)
    self.issued_port = uvm_analysis_port("issued_port", self)
    self.frontends = [None] * n_ports
    self.inflight_ref_by_tag = {}
    self.next_fe_port_rr = 0
    self.current_fe_port_grants_left = 0
    self.inflight_to_device = 0
    self.init_gate_open = True

    self.last_issued_cmd = None
    self.last_issued_req = None
    self.last_rsp = None
    self.last_completed_cmd = None
    self.issued_req_count = 0
    self.observed_rsp_count = 0
    self.completed_cmd_count = 0
    self.predicted_last_by_tag = {}
    self.telemetry_data_bytes = 0
    self.telemetry_predict_error_ns = 0.0
    self.telemetry_predict_samples = 0
    self.telemetry_busy_time_ns = 0.0
    self.telemetry_first_data_ns = 0.0
    self.telemetry_last_burst_end_ns = 0.0
    self.telemetry_window_valid = False
    self.telemetry_latency_sum_ns = 0.0
    self.telemetry_latency_samples = 0
    self.telemetry_latency_min_ns = 0.0
    self.telemetry_latency_max_ns = 0.0
    self.latency_hist = {}
    self.observed_reorder_count = 0
    self.max_completed_admit_order = 0
    self.port_completed_count = [0] * n_ports
    self.port_data_bytes = [0] * n_ports
    self.ecc_corrected_count = 0
    self.ecc_uncorrectable_count = 0
    self.fr_fcfs_forced_count = 0
    self.last_issued_dir_valid = False
    self.last_issued_is_read = False
    self.same_dir_run_len = 0
    self.bus_turnaround_count = 0
    self.rd_wr_grouped_count = 0

  def build_phase(self):
    try:
      self.mc_cfg = ConfigDB().get(self, "", "cfg")
    except UVMConfigItemNotFound:
      pass
    try:
      self.geom = ConfigDB().get(self, "", "geom")
    except UVMConfigItemNotFound:
      pass
    try:
      self.dram = ConfigDB().get(self, "", "dram")
    except UVMConfigItemNotFound:
      pass
    try:
      n_ports = ConfigDB().get(self, "", "n_ports")
      if int(n_ports) != self.n_ports:
        self._resize_ports(int(n_ports))
    except UVMConfigItemNotFound:
      pass

  def _resize_ports(self, n_ports: int) -> None:
    if n_ports < 0:
      raise RuntimeError(f"[{self.name}] n_ports must be >= 0")
    old_fifos = list(self.fe_fifo)
    old_exports = list(self.fe_export)
    old_frontends = list(self.frontends)
    self.n_ports = n_ports
    self.fe_fifo = old_fifos[:n_ports]
    self.fe_export = old_exports[:n_ports]
    self.frontends = old_frontends[:n_ports]
    while len(self.fe_fifo) < n_ports:
      idx = len(self.fe_fifo)
      fifo = vip_mc_activity_fifo(f"fe_fifo_{idx}", self.state_changed_event)
      self.fe_fifo.append(fifo)
      self.fe_export.append(_ActivitySubscriber(f"fe_export_{idx}", self, fifo))
      self.frontends.append(None)
    self.port_completed_count = [0] * n_ports
    self.port_data_bytes = [0] * n_ports

  def register_port(self, port_id: int, frontend) -> None:
    if port_id < 0 or port_id >= self.n_ports:
      raise RuntimeError(
          f"[{self.name}] register_port({port_id}) outside n_ports={self.n_ports}")
    self.frontends[port_id] = frontend
    frontend.port_id = port_id
    frontend.req_port.connect(self.fe_export[port_id].analysis_export)

  def get_registered_port_count(self) -> int:
    return sum(1 for frontend in self.frontends if frontend is not None)

  async def run_phase(self):
    while True:
      progressed = False
      if self.init_gate_open:
        progressed = self._run_once()
      if not progressed:
        self.state_changed_event.reset()
        await Timer(1, unit="ns")

  def _run_once(self) -> bool:
    if not self.ref_fifo.is_empty():
      ref_entry = self.ref_fifo.try_get()
      self._issue_or_complete(ref_entry)
      return True

    admitted = self.admit_one_ready_fe_entry()
    if not self.device_has_issue_credit():
      return admitted

    entry = self.pick_next_entry()
    if entry is None:
      return admitted
    self._issue_or_complete(entry)
    return True

  def _issue_or_complete(self, entry) -> None:
    if entry.pre_resolved:
      entry.completed = True
      self.last_completed_cmd = entry
      self.completed_cmd_count += 1
      self.note_completion_observability(entry)
      self._complete_frontend(entry)
      return

    if entry.op != VipDramOp.REF:
      self.cmd_queue.enqueue(entry)
    self.issued_port.write(entry)
    req = self.issue_one(entry)
    if entry.op != VipDramOp.REF:
      self.inflight_to_device += 1
    self.req_port.write(req)

  def admit_one_ready_fe_entry(self) -> bool:
    if self.n_ports <= 0:
      return False

    for offset in range(self.n_ports):
      port_id = (self.next_fe_port_rr + offset) % self.n_ports
      fifo = self.fe_fifo[port_id]
      if fifo.is_empty():
        continue
      entry = fifo.try_get()
      if entry is None:
        continue
      entry.port_id = port_id
      if not self.cmd_queue.try_coalesce_write(entry):
        self.cmd_queue.admit(entry)
      self.update_fe_rr_after_grant(port_id)
      return True
    return False

  def get_port_weight(self, port_id: int) -> int:
    if self.mc_cfg is None or port_id < 0 or port_id >= len(self.mc_cfg.ports):
      return 1
    return max(1, int(self.mc_cfg.ports[port_id].arb_weight))

  def update_fe_rr_after_grant(self, port_id: int) -> None:
    if self.n_ports <= 0:
      return
    if port_id != self.next_fe_port_rr:
      self.next_fe_port_rr = port_id
      self.current_fe_port_grants_left = self.get_port_weight(port_id)
    if self.current_fe_port_grants_left <= 0:
      self.current_fe_port_grants_left = self.get_port_weight(port_id)
    self.current_fe_port_grants_left -= 1
    if self.current_fe_port_grants_left <= 0:
      self.next_fe_port_rr = (port_id + 1) % self.n_ports

  def has_buffered_input(self) -> bool:
    if not self.ref_fifo.is_empty():
      return True
    if self.cmd_queue.get_pending_count() > 0:
      return True
    return any(not f.is_empty() for f in self.fe_fifo)

  def init_gate_arm(self, delay_ns=0.0) -> None:
    self.init_gate_open = False
    if delay_ns <= 0.0:
      self.init_gate_open = True
      self.init_gate_event.trigger()
      self.state_changed_event.trigger()
      return
    cocotb.start_soon(self._open_init_gate_after(delay_ns))

  async def _open_init_gate_after(self, delay_ns: float) -> None:
    await Timer(round(float(delay_ns) * 1000.0), unit="ps")
    self.init_gate_open = True
    self.init_gate_event.trigger()
    self.state_changed_event.trigger()

  def flush(self) -> None:
    self.cmd_queue.flush()
    for fifo in self.fe_fifo:
      fifo.flush()
    self.ref_fifo.flush()
    self.inflight_ref_by_tag.clear()
    self.predicted_last_by_tag.clear()
    self.next_fe_port_rr = 0
    self.current_fe_port_grants_left = 0
    self.inflight_to_device = 0
    self.last_issued_dir_valid = False
    self.last_issued_is_read = False
    self.same_dir_run_len = 0
    self.state_changed_event.trigger()

  def handle_reset(self) -> None:
    self.flush()
    for frontend in self.frontends:
      if frontend is not None:
        frontend.handle_reset()

  def device_has_issue_credit(self) -> bool:
    if self.mc_cfg.max_inflight_to_device <= 0:
      return True
    return self.inflight_to_device < self.mc_cfg.max_inflight_to_device

  def pick_next_entry(self):
    if self.mc_cfg is not None and self.mc_cfg.fr_fcfs_enable:
      return self.pick_next_entry_fr_fcfs()
    return self.cmd_queue.pick()

  def pick_next_entry_fr_fcfs(self):
    if self.cmd_queue is None or self.dram is None:
      return None
    selected_effective_class = self.cmd_queue.get_highest_effective_class()
    if selected_effective_class < 0:
      return None
    entries = self.cmd_queue.get_eligible_entries_in_effective_class(
        selected_effective_class)
    if not entries:
      return None

    winner_list_idx = -1
    winner_admit_order = None
    winner_last_ready = 0.0
    for i, (class_idx, entry_idx) in enumerate(entries):
      candidate = self.cmd_queue.peek_entry(class_idx, entry_idx)
      if candidate is None:
        continue
      _, last_ready = self.predict_candidate_ready_times(candidate)
      if (winner_list_idx < 0 or
          last_ready < (winner_last_ready - PREDICT_EPS_C) or
          ((winner_last_ready - PREDICT_EPS_C) <= last_ready <=
           (winner_last_ready + PREDICT_EPS_C) and
           candidate.admit_order < winner_admit_order)):
        winner_list_idx = i
        winner_admit_order = candidate.admit_order
        winner_last_ready = last_ready

    if winner_list_idx < 0:
      return None

    if self.mc_cfg.rd_wr_grouping_enable and self.last_issued_dir_valid:
      prefer_read = self.last_issued_is_read
      if (self.mc_cfg.rd_wr_grouping_max > 0 and
          self.same_dir_run_len >= self.mc_cfg.rd_wr_grouping_max):
        prefer_read = not self.last_issued_is_read

      group_list_idx = -1
      group_admit_order = None
      group_last_ready = 0.0
      for i, (class_idx, entry_idx) in enumerate(entries):
        candidate = self.cmd_queue.peek_entry(class_idx, entry_idx)
        if candidate is None:
          continue
        if (candidate.op == VipDramOp.RD) != prefer_read:
          continue
        _, last_ready = self.predict_candidate_ready_times(candidate)
        if (group_list_idx < 0 or
            last_ready < (group_last_ready - PREDICT_EPS_C) or
            ((group_last_ready - PREDICT_EPS_C) <= last_ready <=
             (group_last_ready + PREDICT_EPS_C) and
             candidate.admit_order < group_admit_order)):
          group_list_idx = i
          group_admit_order = candidate.admit_order
          group_last_ready = last_ready

      if group_list_idx >= 0:
        if group_list_idx != winner_list_idx:
          self.rd_wr_grouped_count += 1
        winner_list_idx = group_list_idx
        winner_admit_order = group_admit_order
        winner_last_ready = group_last_ready

    if self.mc_cfg.fr_fcfs_starvation_cap > 0:
      forced_list_idx = -1
      forced_admit_order = None
      for i, (class_idx, entry_idx) in enumerate(entries):
        candidate = self.cmd_queue.peek_entry(class_idx, entry_idx)
        if candidate is None:
          continue
        if (candidate.bypass_count >= self.mc_cfg.fr_fcfs_starvation_cap and
            (forced_admit_order is None or
             candidate.admit_order < forced_admit_order)):
          forced_list_idx = i
          forced_admit_order = candidate.admit_order

      if forced_list_idx >= 0:
        self.fr_fcfs_forced_count += 1
        class_idx, entry_idx = entries[forced_list_idx]
        return self.cmd_queue.take_entry(class_idx, entry_idx)

      for i, (class_idx, entry_idx) in enumerate(entries):
        if i == winner_list_idx:
          continue
        candidate = self.cmd_queue.peek_entry(class_idx, entry_idx)
        if candidate is not None and candidate.admit_order < winner_admit_order:
          candidate.bypass_count += 1

    class_idx, entry_idx = entries[winner_list_idx]
    return self.cmd_queue.take_entry(class_idx, entry_idx)

  def predict_candidate_ready_times(self, entry):
    if entry.pre_resolved:
      now = float(self.now_func())
      return now, now
    req = self.entry_to_req(entry)
    return self.dram.predict(req)

  def entry_to_req(self, entry):
    req = VipDramReq(f"req_{entry.tag:x}")
    req.addr = entry.addr
    req.op = entry.op
    req.beats = entry.beats
    req.has_explicit_rank = entry.has_explicit_rank
    req.rank = entry.rank
    req.tag = entry.tag
    req.wdata = list(entry.wdata)
    req.wstrb = list(entry.wstrb)
    return req

  def issue_one(self, entry):
    self.last_issued_cmd = entry
    if entry.op == VipDramOp.REF and ((entry.tag >> 63) & 1):
      self.inflight_ref_by_tag[entry.tag] = entry
    elif entry.tag == 0:
      raise RuntimeError(
          f"[{self.name}] issue_one() received a non-refresh entry without tag")

    if entry.op != VipDramOp.REF:
      issued_is_read = entry.op == VipDramOp.RD
      if self.last_issued_dir_valid and issued_is_read != self.last_issued_is_read:
        self.bus_turnaround_count += 1
        self.same_dir_run_len = 1
      else:
        self.same_dir_run_len += 1
      self.last_issued_is_read = issued_is_read
      self.last_issued_dir_valid = True

    req = self.entry_to_req(entry)
    if (self.mc_cfg is not None and self.mc_cfg.perf_counters_enabled and
        entry.op != VipDramOp.REF and self.dram is not None):
      _, pred_last_ready = self.dram.predict(req)
      self.predicted_last_by_tag[entry.tag] = pred_last_ready

    self.last_issued_req = req
    self.issued_req_count += 1
    return req

  def write(self, rsp):
    entry = self.complete_rsp(rsp)
    if entry is not None:
      self._complete_frontend(entry)

  def _complete_frontend(self, entry) -> None:
    entries = [entry] + [m for m in entry.merged_writes if m is not None]
    for completed in entries:
      if completed.port_id < 0 or completed.port_id >= self.n_ports:
        continue
      frontend = self.frontends[completed.port_id]
      if frontend is not None:
        frontend.complete(completed)

  def complete_rsp(self, rsp):
    self.last_rsp = rsp
    self.observed_rsp_count += 1

    if rsp.tag in self.inflight_ref_by_tag:
      del self.inflight_ref_by_tag[rsp.tag]
      return None

    entry = self.cmd_queue.complete_by_rsp(rsp)
    if entry is None:
      return None

    if self.inflight_to_device > 0:
      self.inflight_to_device -= 1

    entry.resp = (VIP_MC_AXI4_RESP_EXOKAY_C if entry.is_exclusive
                  else VIP_MC_AXI4_RESP_OKAY_C)
    entry.first_beat_ready_time = rsp.first_beat_ready_time
    entry.last_beat_ready_time = rsp.last_beat_ready_time
    entry.completed = True

    if (self.mc_cfg is not None and self.mc_cfg.ecc_enable and
        entry.op == VipDramOp.RD):
      if len(rsp.corrupt_mask) == len(rsp.rdata):
        rsp.rdata = [d ^ m for d, m in zip(rsp.rdata, rsp.corrupt_mask)]
      if rsp.injected_fault == VipDramFault.UNCORRECTABLE:
        entry.resp = VIP_MC_AXI4_RESP_SLVERR_C
      if self.mc_cfg.perf_counters_enabled:
        if rsp.injected_fault == VipDramFault.CORRECTABLE:
          self.ecc_corrected_count += 1
        elif rsp.injected_fault == VipDramFault.UNCORRECTABLE:
          self.ecc_uncorrectable_count += 1

    entry.rdata = list(rsp.rdata)
    self._note_prediction(rsp, entry)
    self.last_completed_cmd = entry
    self.completed_cmd_count += 1
    self.note_completion_observability(entry)

    for secondary in entry.merged_writes:
      if secondary is None:
        continue
      secondary.resp = entry.resp
      secondary.first_beat_ready_time = rsp.first_beat_ready_time
      secondary.last_beat_ready_time = rsp.last_beat_ready_time
      secondary.completed = True
      self.completed_cmd_count += 1
      self.note_completion_observability(secondary)

    return entry

  def _note_prediction(self, rsp, entry) -> None:
    if (self.mc_cfg is None or not self.mc_cfg.perf_counters_enabled or
        self.dram is None):
      return
    tBL = getattr(getattr(self.dram, "cfg", None), "timing", None)
    tBL = getattr(tBL, "tBL", 0.0)
    burst_end_ns = rsp.last_beat_ready_time + tBL
    busy_span_ns = max(0.0, burst_end_ns - rsp.first_beat_ready_time)
    self.telemetry_data_bytes += entry.beats * self.geom.ROW_BYTES_P
    self.telemetry_busy_time_ns += busy_span_ns
    if (not self.telemetry_window_valid or
        rsp.first_beat_ready_time < self.telemetry_first_data_ns):
      self.telemetry_first_data_ns = rsp.first_beat_ready_time
    if (not self.telemetry_window_valid or
        burst_end_ns > self.telemetry_last_burst_end_ns):
      self.telemetry_last_burst_end_ns = burst_end_ns
    self.telemetry_window_valid = True

    predicted = self.predicted_last_by_tag.pop(rsp.tag, None)
    if predicted is not None:
      self.telemetry_predict_error_ns += abs(rsp.last_beat_ready_time - predicted)
      self.telemetry_predict_samples += 1

  def note_completion_observability(self, entry) -> None:
    if entry is None or self.mc_cfg is None or not self.mc_cfg.perf_counters_enabled:
      return
    lat_ns = max(0.0, entry.last_beat_ready_time - entry.admit_time)
    self.telemetry_latency_sum_ns += lat_ns
    if (self.telemetry_latency_samples == 0 or
        lat_ns < self.telemetry_latency_min_ns):
      self.telemetry_latency_min_ns = lat_ns
    if (self.telemetry_latency_samples == 0 or
        lat_ns > self.telemetry_latency_max_ns):
      self.telemetry_latency_max_ns = lat_ns
    self.telemetry_latency_samples += 1
    bucket = latency_bucket(lat_ns)
    self.latency_hist[bucket] = self.latency_hist.get(bucket, 0) + 1

    if entry.admit_order < self.max_completed_admit_order:
      self.observed_reorder_count += 1
    else:
      self.max_completed_admit_order = entry.admit_order

    if 0 <= entry.port_id < self.n_ports:
      self.port_completed_count[entry.port_id] += 1
      self.port_data_bytes[entry.port_id] += entry.beats * self.geom.ROW_BYTES_P

  def clear_perf_counters(self) -> None:
    self.issued_req_count = 0
    self.observed_rsp_count = 0
    self.completed_cmd_count = 0
    self.predicted_last_by_tag.clear()
    self.telemetry_data_bytes = 0
    self.telemetry_predict_error_ns = 0.0
    self.telemetry_predict_samples = 0
    self.telemetry_busy_time_ns = 0.0
    self.telemetry_first_data_ns = 0.0
    self.telemetry_last_burst_end_ns = 0.0
    self.telemetry_window_valid = False
    self.telemetry_latency_sum_ns = 0.0
    self.telemetry_latency_samples = 0
    self.telemetry_latency_min_ns = 0.0
    self.telemetry_latency_max_ns = 0.0
    self.latency_hist.clear()
    self.observed_reorder_count = 0
    self.max_completed_admit_order = 0
    self.port_completed_count = [0] * self.n_ports
    self.port_data_bytes = [0] * self.n_ports
    self.ecc_corrected_count = 0
    self.ecc_uncorrectable_count = 0
    self.fr_fcfs_forced_count = 0
    self.bus_turnaround_count = 0
    self.rd_wr_grouped_count = 0
    self.cmd_queue.clear_perf_counters()

  def get_cmd_queue_peak_depth(self) -> int:
    if self.mc_cfg is None or not self.mc_cfg.perf_counters_enabled:
      return 0
    return self.cmd_queue.get_peak_depth()

  def get_predict_accuracy(self) -> float:
    if (self.mc_cfg is None or not self.mc_cfg.perf_counters_enabled or
        self.telemetry_predict_samples == 0):
      return 0.0
    return self.telemetry_predict_error_ns / float(self.telemetry_predict_samples)

  def get_effective_bandwidth(self) -> float:
    if (self.mc_cfg is None or not self.mc_cfg.perf_counters_enabled or
        not self.telemetry_window_valid):
      return 0.0
    window_ns = self.telemetry_last_burst_end_ns - self.telemetry_first_data_ns
    return 0.0 if window_ns <= 0.0 else self.telemetry_data_bytes / window_ns

  def get_bus_utilization(self) -> float:
    if (self.mc_cfg is None or not self.mc_cfg.perf_counters_enabled or
        not self.telemetry_window_valid):
      return 0.0
    window_ns = self.telemetry_last_burst_end_ns - self.telemetry_first_data_ns
    return 0.0 if window_ns <= 0.0 else self.telemetry_busy_time_ns / window_ns

  def get_coalesced_write_count(self) -> int:
    return self.cmd_queue.get_coalesced_write_count()

  def get_observed_reorder_count(self) -> int:
    if self.mc_cfg is None or not self.mc_cfg.perf_counters_enabled:
      return 0
    return self.observed_reorder_count

  def get_mean_latency_ns(self) -> float:
    if (self.mc_cfg is None or not self.mc_cfg.perf_counters_enabled or
        self.telemetry_latency_samples == 0):
      return 0.0
    return self.telemetry_latency_sum_ns / float(self.telemetry_latency_samples)

  def get_min_latency_ns(self) -> float:
    if (self.mc_cfg is None or not self.mc_cfg.perf_counters_enabled or
        self.telemetry_latency_samples == 0):
      return 0.0
    return self.telemetry_latency_min_ns

  def get_max_latency_ns(self) -> float:
    if (self.mc_cfg is None or not self.mc_cfg.perf_counters_enabled or
        self.telemetry_latency_samples == 0):
      return 0.0
    return self.telemetry_latency_max_ns

  def get_latency_sample_count(self) -> int:
    if self.mc_cfg is None or not self.mc_cfg.perf_counters_enabled:
      return 0
    return self.telemetry_latency_samples

  def get_latency_hist_count(self, bucket: int) -> int:
    if self.mc_cfg is None or not self.mc_cfg.perf_counters_enabled:
      return 0
    return self.latency_hist.get(int(bucket), 0)

  def get_port_completed_count(self, port_id: int) -> int:
    if (self.mc_cfg is None or not self.mc_cfg.perf_counters_enabled or
        port_id < 0 or port_id >= self.n_ports):
      return 0
    return self.port_completed_count[port_id]

  def get_port_data_bytes(self, port_id: int) -> int:
    if (self.mc_cfg is None or not self.mc_cfg.perf_counters_enabled or
        port_id < 0 or port_id >= self.n_ports):
      return 0
    return self.port_data_bytes[port_id]

  def get_occupancy_hist_count(self, depth: int) -> int:
    if self.mc_cfg is None or not self.mc_cfg.perf_counters_enabled:
      return 0
    return self.cmd_queue.get_occupancy_hist_count(depth)

  def get_occupancy_sample_count(self) -> int:
    if self.mc_cfg is None or not self.mc_cfg.perf_counters_enabled:
      return 0
    return self.cmd_queue.get_occupancy_sample_count()

  def get_ecc_corrected_count(self) -> int:
    if self.mc_cfg is None or not self.mc_cfg.perf_counters_enabled:
      return 0
    return self.ecc_corrected_count

  def get_ecc_uncorrectable_count(self) -> int:
    if self.mc_cfg is None or not self.mc_cfg.perf_counters_enabled:
      return 0
    return self.ecc_uncorrectable_count

  def get_fr_fcfs_forced_count(self) -> int:
    if self.mc_cfg is None or not self.mc_cfg.perf_counters_enabled:
      return 0
    return self.fr_fcfs_forced_count

  def get_bus_turnaround_count(self) -> int:
    if self.mc_cfg is None or not self.mc_cfg.perf_counters_enabled:
      return 0
    return self.bus_turnaround_count

  def get_rd_wr_grouped_count(self) -> int:
    if self.mc_cfg is None or not self.mc_cfg.perf_counters_enabled:
      return 0
    return self.rd_wr_grouped_count

  def get_cmd_queue_depth(self) -> int:
    return self.cmd_queue.get_pending_count()

  def get_inflight_to_device(self) -> int:
    return self.inflight_to_device

  def get_device_issue_credit_avail(self) -> bool:
    return self.device_has_issue_credit()

  def get_status_stall_reason(self):
    if not self.ref_fifo.is_empty():
      return VipMcStatusStall.REF_STRICT_PRIORITY
    if not self.device_has_issue_credit():
      return VipMcStatusStall.DEVICE_CREDIT_FULL
    if self.cmd_queue.has_issuable_entry():
      return VipMcStatusStall.NONE
    if self.cmd_queue.get_pending_count() > 0:
      return VipMcStatusStall.SAME_STREAM_BLOCKED
    if any(not f.is_empty() for f in self.fe_fifo):
      return VipMcStatusStall.CMD_QUEUE_EMPTY
    return VipMcStatusStall.NO_BUFFERED_INPUT

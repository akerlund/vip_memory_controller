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
## First Python scoreboard slice: subscribe to backend grant-order entries and
## match observed AXI4 B/R completions back to those predictions.
##
################################################################################

from __future__ import annotations

from dataclasses import dataclass

from pyuvm import uvm_subscriber

from vip_dram_types_pkg import VipDramOp, sim_time_ns
from vip_mc_axi4_types_pkg import VIP_MC_AXI4_RESP_DECERR_C


@dataclass
class _Pred:
  tag: int
  first_ready: float
  last_ready: float
  predicted: bool


class mc_scoreboard(uvm_subscriber):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.enabled = True
    self.dram = None
    self.backend = None
    self.timing_check_enabled = True
    self.timing_tol_ns = 30.0
    self.beat_period_ns = 10.0
    self.wr_pending = {}
    self.rd_pending = {}
    self.predicted_entries = 0
    self.observed_b = 0
    self.observed_r = 0
    self.timing_checked = 0
    self.timing_errors = 0
    self.decerr_responses = 0
    self.unpredicted_responses = 0
    self.last_observed_time_ns = 0.0

  def write(self, entry) -> None:
    if not self.enabled:
      return
    if entry is None or entry.op == VipDramOp.REF:
      return

    pred = _Pred(
        tag=entry.tag,
        first_ready=0.0,
        last_ready=0.0,
        predicted=not entry.pre_resolved and self.dram is not None)
    if pred.predicted:
      req = self.backend.entry_to_req(entry)
      pred.first_ready, pred.last_ready = self.dram.predict(req)
      self.predicted_entries += 1

    q = self.wr_pending if entry.op == VipDramOp.WR else self.rd_pending
    q.setdefault(self.stream_key(entry.port_id, entry.axi4_id), []).append(pred)

  def observe_b(self, port_id: int, axi4_id: int, resp: int,
                obs_time_ns=None) -> None:
    if not self.enabled:
      return
    self.observed_b += 1
    self._check_completion(
        True, port_id, axi4_id, resp, 1,
        sim_time_ns() if obs_time_ns is None else float(obs_time_ns))

  def observe_r(self, port_id: int, axi4_id: int, resp: int, beats: int,
                obs_time_ns=None) -> None:
    if not self.enabled:
      return
    self.observed_r += 1
    self._check_completion(
        False, port_id, axi4_id, resp, beats,
        sim_time_ns() if obs_time_ns is None else float(obs_time_ns))

  def _check_completion(self, is_wr: bool, port_id: int, axi4_id: int,
                        resp: int, n_beats: int, obs_time_ns: float) -> None:
    self.last_observed_time_ns = obs_time_ns
    if int(resp) == VIP_MC_AXI4_RESP_DECERR_C:
      self.decerr_responses += 1
      return

    table = self.wr_pending if is_wr else self.rd_pending
    pred = self._pop(table, port_id, axi4_id)
    if pred is None:
      self.unpredicted_responses += 1
      self.logger.info(
          f"Observed {'B' if is_wr else 'R'} with no device prediction "
          f"(port={port_id} id=0x{axi4_id:x}) - FE-resolved")
      return

    if not pred.predicted or not self.timing_check_enabled:
      return

    self.timing_checked += 1
    expected_last = pred.first_ready + (float(n_beats) - 1.0) * self.beat_period_ns
    if pred.last_ready > expected_last:
      expected_last = pred.last_ready
    delta = obs_time_ns - expected_last
    if delta < -2.0 or delta > self.timing_tol_ns:
      self.timing_errors += 1
      self.logger.error(
          f"{'B' if is_wr else 'R'} timing mismatch port={port_id} "
          f"id=0x{axi4_id:x} tag={pred.tag} beats={n_beats}: "
          f"observed={obs_time_ns:.3f}ns expected={expected_last:.3f}ns "
          f"(pred_last={pred.last_ready:.3f}ns) delta={delta:.3f}ns "
          f"(tol={self.timing_tol_ns:.3f}ns)")

  def check_phase(self):
    if not self.enabled:
      return
    n_pending = sum(len(q) for q in self.wr_pending.values())
    n_pending += sum(len(q) for q in self.rd_pending.values())
    if n_pending:
      raise AssertionError(f"{self.get_name()}: {n_pending} unmatched predictions")
    if self.timing_errors:
      raise AssertionError(
          f"{self.get_name()}: {self.timing_errors} timing errors")

  def get_timing_checked_count(self) -> int:
    return self.timing_checked

  def get_timing_error_count(self) -> int:
    return self.timing_errors

  def get_predicted_count(self) -> int:
    return self.predicted_entries

  @staticmethod
  def stream_key(port_id: int, axi4_id: int) -> str:
    return f"{int(port_id)}:{int(axi4_id):x}"

  def _pop(self, table, port_id: int, axi4_id: int):
    key = self.stream_key(port_id, axi4_id)
    q = table.get(key)
    if not q:
      return None
    pred = q.pop(0)
    if not q:
      table.pop(key, None)
    return pred

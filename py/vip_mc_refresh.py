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
## pyUVM port of the synchronous state in vip_mc/sv/vip_mc_refresh.sv.
##
################################################################################

from __future__ import annotations

from vip_dram_types_pkg import VIP_DRAM_CFG_DEFAULT, VipDramOp

from vip_mc_cmd_entry import vip_mc_cmd_entry
from vip_mc_types_pkg import VipMcRefreshPolicy


class vip_mc_refresh:

  def __init__(self, name="vip_mc_refresh", cfg=None, geom=VIP_DRAM_CFG_DEFAULT,
               req_port=None, now_func=None):
    if cfg is None:
      from vip_mc_config import vip_mc_config
      cfg = vip_mc_config()
    self.name = name
    self.cfg = cfg
    self.geom = geom
    self.req_port = req_port
    self.now_func = now_func or (lambda: 0.0)
    self.tREFI_cached_ns = -1.0
    self.ref_ctr = 0
    self.refresh_count = 0
    self.armed = False
    self.deferred_debt = 0
    self.peak_deferred_debt = 0
    self.deferred_catchup_count = 0

  def cache_trefi_ns(self, trefi_ns: float) -> None:
    self.tREFI_cached_ns = float(trefi_ns)

  def tick(self):
    if self.cfg.refresh_policy == VipMcRefreshPolicy.DEFERRED:
      return self.tick_deferred()
    return self.emit_refresh_burst()

  def arm(self) -> None:
    self.armed = True

  def tick_deferred(self):
    limit = self.cfg.refresh_max_deferred if self.cfg.refresh_max_deferred >= 1 else 1
    self.deferred_debt += 1
    self.peak_deferred_debt = max(self.peak_deferred_debt, self.deferred_debt)
    emitted = []
    if self.deferred_debt >= limit:
      for _ in range(self.deferred_debt):
        emitted.extend(self.emit_refresh_burst())
      self.deferred_catchup_count += 1
      self.deferred_debt = 0
    return emitted

  def flush(self) -> None:
    self.armed = False
    self.ref_ctr = 0
    self.refresh_count = 0
    self.deferred_debt = 0
    self.peak_deferred_debt = 0
    self.deferred_catchup_count = 0

  def emit_refresh_burst(self):
    emitted = []
    for rank in range(self.geom.N_RANKS_P):
      ref_entry = vip_mc_cmd_entry(f"ref_rank_{rank}_{self.ref_ctr}")
      ref_entry.tag = (1 << 63) | self.ref_ctr
      ref_entry.port_id = -1
      ref_entry.axi4_id = 0
      ref_entry.op = VipDramOp.REF
      ref_entry.addr = 0
      ref_entry.beats = 1
      ref_entry.has_explicit_rank = True
      ref_entry.rank = rank
      ref_entry.enqueue_time = float(self.now_func())
      self.ref_ctr += 1
      self.refresh_count += 1
      emitted.append(ref_entry)
      if self.req_port is not None:
        self.req_port.write(ref_entry)
    return emitted

  def get_refresh_count(self) -> int:
    return self.refresh_count

  def get_deferred_debt(self) -> int:
    return self.deferred_debt

  def get_peak_deferred_debt(self) -> int:
    return self.peak_deferred_debt

  def get_deferred_catchup_count(self) -> int:
    return self.deferred_catchup_count

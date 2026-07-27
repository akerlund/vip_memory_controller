################################################################################
##
## Copyright (C) 2026 Fredrik Åkerlund
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
################################################################################
#
# Python port of tb/mc_coverage.sv - controller-specific functional coverage for
# the vip_mc example. Same four groups, same bins, same crosses; built on pyvsc,
# which is the framework the AXI4/CHI agent coverage already uses.
#
# Coverage percentages are NOT comparable across the two flows: pyvsc and SV
# covergroups weight bins differently, so treat the SV and Python numbers as two
# independent scores over the same intent, not as a single figure to close.
#
################################################################################

from __future__ import annotations

import vsc

from pyuvm import ConfigDB, uvm_component, uvm_subscriber

from vip_dram_addr_pkg import vip_dram_decode_addr
from vip_dram_types_pkg import (
  VIP_DRAM_CFG_DEFAULT, VipDramFault, VipDramOp,
)
from vip_mc_axi4_types_pkg import (
  VIP_MC_AXI4_BURST_FIXED_C, VIP_MC_AXI4_BURST_INCR_C,
  VIP_MC_AXI4_BURST_WRAP_C, VIP_MC_AXI4_RESP_DECERR_C,
  VIP_MC_AXI4_RESP_EXOKAY_C, VIP_MC_AXI4_RESP_OKAY_C,
  VIP_MC_AXI4_RESP_SLVERR_C,
)

_BIG = 1 << 20  # open-ended upper bound stand-in for SV `$`

# Page classification, matching the SV cp_page encoding.
_PAGE_HIT = 0
_PAGE_MISS = 1
_PAGE_EMPTY = 2
_PAGE_NONE = 3


def _make_cg_issue(n_ports, n_ranks, n_bank_groups, n_banks_per_bg):
  """Scheduling decision, sampled once per granted backend entry."""

  @vsc.covergroup
  class cg_issue(object):
    def __init__(self):
      self.with_sample(dict(
        op=vsc.uint8_t(), port=vsc.uint8_t(), qos_class=vsc.uint8_t(),
        burst=vsc.uint8_t(), beats=vsc.uint32_t(), bypass=vsc.uint32_t(),
        coalesce=vsc.uint32_t(), exclusive=vsc.uint8_t(),
        pre_resolved=vsc.uint8_t(), rank=vsc.uint8_t(), bg=vsc.uint8_t(),
        bank=vsc.uint8_t()))

      self.cp_op = vsc.coverpoint(lambda: self.op, bins=dict(
        rd=vsc.bin(int(VipDramOp.RD)), wr=vsc.bin(int(VipDramOp.WR)),
        ref_op=vsc.bin(int(VipDramOp.REF))))
      self.cp_port = vsc.coverpoint(lambda: self.port, bins=dict(
        ports=vsc.bin_array([], [0, n_ports - 1])))
      self.cp_qos_class = vsc.coverpoint(lambda: self.qos_class, bins=dict(
        low=vsc.bin(0), mid=vsc.bin(1), high=vsc.bin(2),
        other=vsc.bin([3, 15])))
      self.cp_burst = vsc.coverpoint(lambda: self.burst, bins=dict(
        fixed=vsc.bin(VIP_MC_AXI4_BURST_FIXED_C),
        incr=vsc.bin(VIP_MC_AXI4_BURST_INCR_C),
        wrap=vsc.bin(VIP_MC_AXI4_BURST_WRAP_C)))
      # Device-side column accesses per entry. A refresh carries one.
      self.cp_beats = vsc.coverpoint(lambda: self.beats, bins=dict(
        single=vsc.bin(1), pair=vsc.bin(2), quad=vsc.bin([3, 4]),
        mid=vsc.bin([5, 8]), big=vsc.bin([9, 16]), huge=vsc.bin([17, _BIG])))
      # FR-FCFS starvation pressure: younger readiness-winners this entry was
      # reordered past before it was granted.
      self.cp_bypass = vsc.coverpoint(lambda: self.bypass, bins=dict(
        none=vsc.bin(0), few=vsc.bin([1, 3]), several=vsc.bin([4, 7]),
        capped=vsc.bin([8, _BIG])))
      # Write coalescing fan-out: secondaries merged into this primary.
      self.cp_coalesce = vsc.coverpoint(lambda: self.coalesce, bins=dict(
        none=vsc.bin(0), one=vsc.bin(1), many=vsc.bin([2, _BIG])))
      self.cp_exclusive = vsc.coverpoint(lambda: self.exclusive, bins=dict(
        normal=vsc.bin(0), exclusive=vsc.bin(1)))
      # A DECERR resolved in the front-end never reaches the device.
      self.cp_pre_resolved = vsc.coverpoint(lambda: self.pre_resolved, bins=dict(
        scheduled=vsc.bin(0), pre_resolved=vsc.bin(1)))
      self.cp_rank = vsc.coverpoint(lambda: self.rank, bins=dict(
        ranks=vsc.bin_array([], [0, n_ranks - 1])))
      self.cp_bg = vsc.coverpoint(lambda: self.bg, bins=dict(
        bgs=vsc.bin_array([], [0, n_bank_groups - 1])))
      self.cp_bank = vsc.coverpoint(lambda: self.bank, bins=dict(
        banks=vsc.bin_array([], [0, n_banks_per_bg - 1])))

      self.cx_port_op = vsc.cross([self.cp_port, self.cp_op])
      self.cx_qos_op = vsc.cross([self.cp_qos_class, self.cp_op])
      self.cx_op_burst = vsc.cross([self.cp_op, self.cp_burst])
      self.cx_op_bypass = vsc.cross([self.cp_op, self.cp_bypass])
      self.cx_op_coalesce = vsc.cross([self.cp_op, self.cp_coalesce])

  return cg_issue()


def _make_cg_device(n_banks_per_bg):
  """Device outcome, sampled per DRAM response and joined back to its entry."""

  @vsc.covergroup
  class cg_device(object):
    def __init__(self):
      self.with_sample(dict(
        op=vsc.uint8_t(), page=vsc.uint8_t(), qos_class=vsc.uint8_t(),
        bank=vsc.uint8_t(), fault=vsc.uint8_t()))

      self.cp_op = vsc.coverpoint(lambda: self.op, bins=dict(
        rd=vsc.bin(int(VipDramOp.RD)), wr=vsc.bin(int(VipDramOp.WR)),
        ref_op=vsc.bin(int(VipDramOp.REF))))
      self.cp_page = vsc.coverpoint(lambda: self.page, bins=dict(
        hit=vsc.bin(_PAGE_HIT), miss=vsc.bin(_PAGE_MISS),
        empty=vsc.bin(_PAGE_EMPTY), none=vsc.bin(_PAGE_NONE)))
      self.cp_qos_class = vsc.coverpoint(lambda: self.qos_class, bins=dict(
        low=vsc.bin(0), mid=vsc.bin(1), high=vsc.bin(2),
        other=vsc.bin([3, 15])))
      self.cp_bank = vsc.coverpoint(lambda: self.bank, bins=dict(
        banks=vsc.bin_array([], [0, n_banks_per_bg - 1])))
      self.cp_fault = vsc.coverpoint(lambda: self.fault, bins=dict(
        none=vsc.bin(int(VipDramFault.NONE)),
        correctable=vsc.bin(int(VipDramFault.CORRECTABLE)),
        uncorrectable=vsc.bin(int(VipDramFault.UNCORRECTABLE))))

      # The headline scheduling question: reads and writes against every page
      # state. Also where FR-FCFS-vs-QoS bugs show up (cx_qos_page).
      self.cx_op_page = vsc.cross([self.cp_op, self.cp_page])
      self.cx_qos_page = vsc.cross([self.cp_qos_class, self.cp_page])
      self.cx_op_fault = vsc.cross([self.cp_op, self.cp_fault])

  return cg_device()


def _make_cg_turnaround():
  """Transition between consecutive granted operations - read/write grouping
  and refresh insertion both show up here."""

  @vsc.covergroup
  class cg_turnaround(object):
    def __init__(self):
      self.with_sample(dict(prev_op=vsc.uint8_t(), op=vsc.uint8_t()))

      self.cp_prev_op = vsc.coverpoint(lambda: self.prev_op, bins=dict(
        rd=vsc.bin(int(VipDramOp.RD)), wr=vsc.bin(int(VipDramOp.WR)),
        ref_op=vsc.bin(int(VipDramOp.REF))))
      self.cp_op = vsc.coverpoint(lambda: self.op, bins=dict(
        rd=vsc.bin(int(VipDramOp.RD)), wr=vsc.bin(int(VipDramOp.WR)),
        ref_op=vsc.bin(int(VipDramOp.REF))))

      # All nine transitions, including refresh entering and leaving a busy bus.
      self.cx_turnaround = vsc.cross([self.cp_prev_op, self.cp_op])

  return cg_turnaround()


def _make_cg_response(n_ports):
  """Host-visible completion, sampled per B / R response."""

  @vsc.covergroup
  class cg_response(object):
    def __init__(self):
      self.with_sample(dict(
        port=vsc.uint8_t(), op=vsc.uint8_t(), resp=vsc.uint8_t()))

      self.cp_port = vsc.coverpoint(lambda: self.port, bins=dict(
        ports=vsc.bin_array([], [0, n_ports - 1])))
      self.cp_op = vsc.coverpoint(lambda: self.op, bins=dict(
        rd=vsc.bin(int(VipDramOp.RD)), wr=vsc.bin(int(VipDramOp.WR))))
      self.cp_resp = vsc.coverpoint(lambda: self.resp, bins=dict(
        okay=vsc.bin(VIP_MC_AXI4_RESP_OKAY_C),
        exokay=vsc.bin(VIP_MC_AXI4_RESP_EXOKAY_C),
        slverr=vsc.bin(VIP_MC_AXI4_RESP_SLVERR_C),
        decerr=vsc.bin(VIP_MC_AXI4_RESP_DECERR_C)))

      self.cx_port_resp = vsc.cross([self.cp_port, self.cp_resp])
      self.cx_op_resp = vsc.cross([self.cp_op, self.cp_resp])

  return cg_response()


class _cov_sub(uvm_subscriber):
  """Child subscriber whose analysis_export feeds one coverage callback. pyuvm
  requires a real uvm_export_base on the receiving end, so the coverage exposes
  these subscribers' analysis_export as its tap ports."""

  def __init__(self, name, parent, cb):
    super().__init__(name, parent)
    self._cb = cb

  def write(self, item):
    self._cb(item)


class _cov_port_sub(uvm_subscriber):
  """Per-port B / R tap; forwards the item tagged with its originating port."""

  def __init__(self, name, parent, cb, port_id):
    super().__init__(name, parent)
    self._cb = cb
    self.port_id = port_id

  def write(self, item):
    self._cb(self.port_id, item)


class mc_coverage(uvm_component):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.dram = None
    self.mc = None
    self.n_ports = 1
    self.cg_issue = None
    self.cg_device = None
    self.cg_turnaround = None
    self.cg_response = None
    self.issued_export = None
    self.dram_rsp_export = None
    self.b_collectors = []
    self.r_collectors = []
    # Entries awaiting their device response, keyed by tag.
    self._inflight = {}
    self._prev_op = None
    self.issued_samples = 0
    self.rsp_samples = 0
    self.resp_samples = 0
    self.orphan_responses = 0

  def build_phase(self):
    try:
      self.n_ports = int(ConfigDB().get(self, "", "n_ports"))
    except Exception:
      self.n_ports = 1

    self._issued_sub = _cov_sub("issued_cov_sub", self, self.write_issued)
    self._dram_rsp_sub = _cov_sub("dram_rsp_cov_sub", self, self.write_dram_rsp)
    # Exposed connect targets (mirror the SV uvm_analysis_imp ports).
    self.issued_export = self._issued_sub.analysis_export
    self.dram_rsp_export = self._dram_rsp_sub.analysis_export

    for port_id in range(self.n_ports):
      b_sub = _cov_port_sub(
          f"cov_b_collector_{port_id}", self, self.observe_b, port_id)
      r_sub = _cov_port_sub(
          f"cov_r_collector_{port_id}", self, self.observe_r, port_id)
      self.b_collectors.append(b_sub)
      self.r_collectors.append(r_sub)

  # ---------------------------------------------------------------------------
  # Covergroups are built here rather than in build_phase because their bin
  # ranges come from the device geometry, and the env hands over the dram handle
  # in connect_phase - which runs after every build_phase but before this one.
  # ---------------------------------------------------------------------------
  def end_of_elaboration_phase(self):
    cfg = self.dram.cfg.geom if self.dram is not None else VIP_DRAM_CFG_DEFAULT
    self._dram_cfg = cfg

    self.cg_issue = _make_cg_issue(
        self.n_ports, cfg.N_RANKS_P, cfg.N_BANK_GROUPS_P, cfg.BANKS_PER_BG_P)
    self.cg_device = _make_cg_device(cfg.BANKS_PER_BG_P)
    self.cg_turnaround = _make_cg_turnaround()
    self.cg_response = _make_cg_response(self.n_ports)

  # ---------------------------------------------------------------------------
  # Backend grant tap. Samples the scheduling decision and the turnaround from
  # the previous grant, then parks the entry until its device response returns.
  # ---------------------------------------------------------------------------
  def write_issued(self, e):
    if e is None:
      return

    # Device address, not the protocol start address: these coverpoints describe
    # where the access lands on the device (they differ for a WRAP burst).
    dec = self._decode(int(e.get_dev_addr()))
    rank = int(e.rank) if e.has_explicit_rank else dec.rank

    self.cg_issue.sample(
      int(e.op), int(e.port_id), int(e.qos_class), int(e.axi_burst),
      int(e.beats), int(e.bypass_count), len(e.merged_writes),
      1 if e.is_exclusive else 0, 1 if e.pre_resolved else 0,
      rank, dec.bg, dec.bank)
    self.issued_samples += 1

    if self._prev_op is not None:
      self.cg_turnaround.sample(int(self._prev_op), int(e.op))
    self._prev_op = int(e.op)

    # A pre-resolved entry (front-end DECERR) never reaches the device, so it
    # would otherwise leak into the inflight map forever.
    if not e.pre_resolved:
      self._inflight[int(e.tag)] = e

  # ---------------------------------------------------------------------------
  # Device response tap. Joins the outcome back to its granted entry by tag.
  # ---------------------------------------------------------------------------
  def write_dram_rsp(self, r):
    if r is None:
      return

    tag = int(r.tag)
    if tag in self._inflight:
      e = self._inflight.pop(tag)
      qos_class = int(e.qos_class)
      bank = self._decode(int(e.get_dev_addr())).bank
    else:
      # A response with no matching grant: refresh issued directly by the
      # refresh engine, or traffic from a slice this collector does not tap.
      self.orphan_responses += 1
      qos_class = 0
      bank = 0

    if int(r.op) == int(VipDramOp.REF):
      page = _PAGE_NONE
    elif r.was_page_hit:
      page = _PAGE_HIT
    elif r.was_page_miss:
      page = _PAGE_MISS
    elif r.was_page_empty:
      page = _PAGE_EMPTY
    else:
      page = _PAGE_NONE

    self.cg_device.sample(
      int(r.op), page, qos_class, bank, int(r.injected_fault))
    self.rsp_samples += 1

  # ---------------------------------------------------------------------------
  # Host completions.
  # ---------------------------------------------------------------------------
  def observe_b(self, port_id, t):
    if t is None:
      return
    self.cg_response.sample(port_id, int(VipDramOp.WR), int(t.bresp))
    self.resp_samples += 1

  def observe_r(self, port_id, t):
    if t is None:
      return
    self.cg_response.sample(port_id, int(VipDramOp.RD), int(t.rresp))
    self.resp_samples += 1

  # ---------------------------------------------------------------------------
  # Decode a byte address into the device geometry using the DRAM's live map.
  # ---------------------------------------------------------------------------
  def _decode(self, addr):
    return vip_dram_decode_addr(addr, self._dram_cfg, self.dram.cfg.addr_map)

  # ---------------------------------------------------------------------------
  # Report the four group scores. Coverage is informational - this component
  # never fails a test, so an unpopulated group is a gap to close in the
  # stimulus, not a regression error.
  # ---------------------------------------------------------------------------
  def report_phase(self):
    self.logger.info(
      f"[COV] issue {self.cg_issue.get_coverage():.1f}%  "
      f"device {self.cg_device.get_coverage():.1f}%  "
      f"turnaround {self.cg_turnaround.get_coverage():.1f}%  "
      f"response {self.cg_response.get_coverage():.1f}%")
    self.logger.info(
      f"[COV] samples: issued {self.issued_samples}, "
      f"device {self.rsp_samples}, response {self.resp_samples}, "
      f"unmatched device {self.orphan_responses}")

  # ---------------------------------------------------------------------------
  # Accessors for a test that wants to assert on its own coverage.
  # ---------------------------------------------------------------------------
  def get_issue_coverage(self):
    return self.cg_issue.get_coverage()

  def get_device_coverage(self):
    return self.cg_device.get_coverage()

  def get_turnaround_coverage(self):
    return self.cg_turnaround.get_coverage()

  def get_response_coverage(self):
    return self.cg_response.get_coverage()

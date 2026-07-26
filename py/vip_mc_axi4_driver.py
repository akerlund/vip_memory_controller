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
## pyUVM port of the executable AXI4 front-end slice in
## vip_mc/sv/vip_mc_axi4_driver.sv.
##
################################################################################

from __future__ import annotations

from pyuvm import ConfigDB, UVMConfigItemNotFound

from vip_dram_types_pkg import VIP_DRAM_CFG_DEFAULT, VipDramOp, sim_time_ns

from vip_mc_axi4_cfg import vip_mc_axi4_cfg
from vip_mc_axi4_types_pkg import (
  VIP_MC_AXI4_4K_ADDRESS_BOUNDARY_C,
  VIP_MC_AXI4_BURST_FIXED_C,
  VIP_MC_AXI4_BURST_INCR_C,
  VIP_MC_AXI4_BURST_WRAP_C,
  VIP_MC_AXI4_RESP_DECERR_C,
  VIP_MC_AXI4_RESP_EXOKAY_C,
  VIP_MC_AXI4_RESP_OKAY_C,
  VIP_MC_AXI4_RESP_SLVERR_C,
  VipMcAxi4CfgT,
  vip_mc_axi4_size_bytes,
)
from vip_mc_cmd_entry import vip_mc_cmd_entry
from vip_mc_config import vip_mc_config
from vip_mc_fe_base import vip_mc_fe_base
from vip_mc_types_pkg import VipMcStatusFeBlock, VipMcStatusOp, VipMcStatusReject


BEAT_EPS_C = 0.001


class vip_mc_axi4_driver(vip_mc_fe_base):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.cfg = None
    self.mc_cfg = None
    self.cfg_t = None
    self.geom = VIP_DRAM_CFG_DEFAULT
    self.vif = None

    self.pending_aw_q = []
    self.pending_b_q = []
    self.pending_r_q = []
    self.active_b = None
    self.active_r_q = []
    self.active_r_beat_idx_q = []
    self.active_r_slot_idx = -1
    self.w_data_buf_occupancy = 0
    self.exclusive_reservations = {}

    self.last_issued = None
    self.last_completed = None
    self.issued_req_count = 0
    self.complete_count = 0
    self.observed_aw_count = 0
    self.observed_w_count = 0
    self.observed_ar_count = 0
    self.inflight_rd_count = 0
    self.inflight_wr_count = 0
    self.decerr_count = 0
    self.four_k_violation_count = 0
    self.wready_stall_cycles = 0
    self.rsp_buf_full_cycles = 0
    self.rsp_late_count = 0
    self.exokay_count = 0
    self.excl_fail_count = 0
    self.local_reject_count = 0
    self.last_reject_op = VipMcStatusOp.NONE
    self.last_reject_reason = VipMcStatusReject.NONE
    self.prev_cb_time = -1.0

  def build_phase(self):
    try:
      self.vif = ConfigDB().get(self, "", "vif")
    except UVMConfigItemNotFound:
      pass
    try:
      self.cfg = ConfigDB().get(self, "", "axi4_cfg")
    except UVMConfigItemNotFound:
      pass
    try:
      self.mc_cfg = ConfigDB().get(self, "", "cfg")
    except UVMConfigItemNotFound:
      pass
    try:
      self.cfg_t = ConfigDB().get(self, "", "cfg_t")
    except UVMConfigItemNotFound:
      pass
    try:
      self.geom = ConfigDB().get(self, "", "geom")
    except UVMConfigItemNotFound:
      pass

    if self.mc_cfg is None:
      self.mc_cfg = vip_mc_config()
      self.mc_cfg.ensure_port_count(self.port_id + 1)
    if self.cfg is None:
      self.cfg = self.mc_cfg.axi4 if self.mc_cfg is not None else vip_mc_axi4_cfg()
    if self.cfg_t is None:
      self.cfg_t = VipMcAxi4CfgT(
          AWID_WIDTH_P=4, ARID_WIDTH_P=4, ADDR_WIDTH_P=self.geom.ADDR_WIDTH_P,
          WDATA_BYTES_P=self.geom.ROW_BYTES_P,
          RDATA_BYTES_P=self.geom.ROW_BYTES_P)

    self._validate_config()

  def _validate_config(self) -> None:
    if self.vif is None:
      raise RuntimeError(f"[{self.get_name()}] AXI4 vif handle is null")
    if self.port_id < 0 or self.port_id >= len(self.mc_cfg.ports):
      raise RuntimeError(
          f"[{self.get_name()}] port_id {self.port_id} outside configured ports")
    if (self.cfg_t.WDATA_BYTES_P > self.geom.ROW_BYTES_P or
        self.geom.ROW_BYTES_P % self.cfg_t.WDATA_BYTES_P != 0):
      raise RuntimeError(
          f"[{self.get_name()}] WDATA_BYTES_P={self.cfg_t.WDATA_BYTES_P} must "
          f"divide ROW_BYTES_P={self.geom.ROW_BYTES_P}")
    if (self.cfg_t.RDATA_BYTES_P > self.geom.ROW_BYTES_P or
        self.geom.ROW_BYTES_P % self.cfg_t.RDATA_BYTES_P != 0):
      raise RuntimeError(
          f"[{self.get_name()}] RDATA_BYTES_P={self.cfg_t.RDATA_BYTES_P} must "
          f"divide ROW_BYTES_P={self.geom.ROW_BYTES_P}")

  async def run_phase(self):
    self.handle_reset()

    while True:
      await self.vif.rising()
      if self.vif.in_reset():
        self.handle_reset()
        continue

      self._sample_and_advance()
      self.prev_cb_time = sim_time_ns()

  def _sample_and_advance(self) -> None:
    w_accepted = self.vif.get_or("wvalid") == 1 and self.vif.get_or("wready") == 1
    w_burst_completed = False

    if (self.mc_cfg.perf_counters_enabled and self.pending_aw_q and
        not self.can_accept_w()):
      self.wready_stall_cycles += 1
    if (self.mc_cfg.perf_counters_enabled and self.mc_cfg.rsp_buf_depth > 0 and
        not self.rsp_buffer_has_credit()):
      self.rsp_buf_full_cycles += 1

    self.advance_write_rsp_channel()
    self.advance_read_rsp_channel()

    if self.vif.get_or("awvalid") == 1 and self.vif.get_or("awready") == 1:
      self.capture_aw()
    if w_accepted:
      w_burst_completed = self.capture_w()
    if self.vif.get_or("arvalid") == 1 and self.vif.get_or("arready") == 1:
      self.capture_ar()

    self.advance_w_data_buffer_model(w_accepted, w_burst_completed)
    self.drive_accept_outputs()

  def drive_accept_outputs(self) -> None:
    if self.vif is None or self.vif.in_reset():
      return
    self.vif.drive_opt(
        awready=1 if self.can_accept_aw() else 0,
        wready=1 if self.can_accept_w() else 0,
        arready=1 if self.can_accept_ar() else 0)

  def complete(self, entry) -> None:
    if entry.op == VipDramOp.RD and entry.is_exclusive and not entry.pre_resolved:
      self.register_exclusive_reservation(entry)
    if (self.mc_cfg.perf_counters_enabled and entry.is_exclusive and
        entry.resp == VIP_MC_AXI4_RESP_EXOKAY_C):
      self.exokay_count += 1

    self.last_completed = entry
    self.complete_count += 1
    if entry.op == VipDramOp.RD:
      self.pending_r_q.append(entry)
    else:
      self.pending_b_q.append(entry)

  def handle_reset(self) -> None:
    self.pending_aw_q.clear()
    self.pending_b_q.clear()
    self.pending_r_q.clear()
    self.active_r_q.clear()
    self.active_r_beat_idx_q.clear()
    self.active_b = None
    self.active_r_slot_idx = -1
    self.w_data_buf_occupancy = 0
    self.inflight_rd_count = 0
    self.inflight_wr_count = 0
    self.decerr_count = 0
    self.four_k_violation_count = 0
    self.wready_stall_cycles = 0
    self.rsp_buf_full_cycles = 0
    self.rsp_late_count = 0
    self.exokay_count = 0
    self.excl_fail_count = 0
    self.local_reject_count = 0
    self.last_reject_op = VipMcStatusOp.NONE
    self.last_reject_reason = VipMcStatusReject.NONE
    self.prev_cb_time = -1.0
    self.exclusive_reservations.clear()
    if self.vif is not None:
      if hasattr(self.vif, "reset_controller"):
        self.vif.reset_controller()
      else:
        self.vif.reset_subordinate()

  def can_accept_aw(self) -> bool:
    if not self.rsp_buffer_has_credit():
      return False
    outstanding_writes = len(self.pending_aw_q) + self.inflight_wr_count
    if not self.limit_allows(outstanding_writes, self.cfg.aw_outstanding_limit):
      return False
    return self.depth_allows(len(self.pending_aw_q), self.cfg.aw_pending_depth)

  def can_accept_ar(self) -> bool:
    if not self.rsp_buffer_has_credit():
      return False
    return self.limit_allows(self.inflight_rd_count, self.cfg.ar_outstanding_limit)

  def can_accept_w(self) -> bool:
    if not self.pending_aw_q:
      return False
    return self.depth_allows(self.w_data_buf_occupancy, self.cfg.w_data_buf_depth)

  def get_aw_block_reason(self):
    if self.vif is not None and self.vif.in_reset():
      return VipMcStatusFeBlock.IN_RESET
    if not self.rsp_buffer_has_credit():
      return VipMcStatusFeBlock.RSP_BUF_FULL
    outstanding_writes = len(self.pending_aw_q) + self.inflight_wr_count
    if not self.limit_allows(outstanding_writes, self.cfg.aw_outstanding_limit):
      return VipMcStatusFeBlock.AW_OUTSTANDING_FULL
    if not self.depth_allows(len(self.pending_aw_q), self.cfg.aw_pending_depth):
      return VipMcStatusFeBlock.AW_PENDING_FULL
    return VipMcStatusFeBlock.NONE

  def get_ar_block_reason(self):
    if self.vif is not None and self.vif.in_reset():
      return VipMcStatusFeBlock.IN_RESET
    if not self.rsp_buffer_has_credit():
      return VipMcStatusFeBlock.RSP_BUF_FULL
    if not self.limit_allows(self.inflight_rd_count, self.cfg.ar_outstanding_limit):
      return VipMcStatusFeBlock.AR_OUTSTANDING_FULL
    return VipMcStatusFeBlock.NONE

  def get_w_block_reason(self):
    if self.vif is not None and self.vif.in_reset():
      return VipMcStatusFeBlock.IN_RESET
    if not self.pending_aw_q:
      return VipMcStatusFeBlock.NO_WRITE_IN_FLIGHT
    if not self.depth_allows(self.w_data_buf_occupancy, self.cfg.w_data_buf_depth):
      return VipMcStatusFeBlock.WBUF_FULL
    return VipMcStatusFeBlock.NONE

  def rsp_buffer_has_credit(self) -> bool:
    if self.mc_cfg.rsp_buf_depth <= 0:
      return True
    return self.get_rsp_slots_used() < self.mc_cfg.rsp_buf_depth

  def get_rsp_slots_used(self) -> int:
    return (len(self.pending_b_q) + len(self.pending_r_q) +
            (1 if self.active_b is not None else 0) + len(self.active_r_q))

  @staticmethod
  def limit_allows(current_count: int, limit: int) -> bool:
    return True if limit <= 0 else current_count < limit

  @staticmethod
  def depth_allows(current_depth: int, max_depth: int) -> bool:
    return True if max_depth <= 0 else current_depth < max_depth

  def capture_aw(self) -> None:
    self.observed_aw_count += 1
    entry = self._build_addr_entry("aw", VipDramOp.WR, self.observed_aw_count)
    if not entry.pre_resolved:
      entry.wdata = [0] * entry.beats
      entry.wstrb = [0] * entry.beats
    self.pending_aw_q.append(entry)

  def capture_w(self) -> bool:
    self.observed_w_count += 1
    if not self.pending_aw_q:
      self.logger.error("Observed W handshake with no pending AW entry")
      return False

    entry = self.pending_aw_q[0]
    entry.wuser = self.vif.get_or("wuser")
    entry.captured_w_beats += 1
    beat_idx = entry.captured_w_beats - 1

    if not entry.pre_resolved and beat_idx < entry.axi_beats:
      self.pack_write_beat(
          entry, beat_idx, self.vif.get_or("wdata"), self.vif.get_or("wstrb"))

    wlast = self.vif.get_or("wlast") == 1
    if wlast and entry.captured_w_beats < entry.axi_beats:
      if not entry.pre_resolved:
        self.record_local_reject(VipMcStatusOp.WR, VipMcStatusReject.SLVERR_LOCAL)
      entry.pre_resolved = True
      entry.resp = VIP_MC_AXI4_RESP_SLVERR_C
      entry.axi_beats = entry.captured_w_beats
      entry.beats = self.get_dram_req_beats(
          entry.addr, entry.axi_size_bytes, entry.axi_beats, entry.axi_burst)
    elif not wlast and entry.captured_w_beats == entry.axi_beats:
      if not entry.pre_resolved:
        self.record_local_reject(VipMcStatusOp.WR, VipMcStatusReject.SLVERR_LOCAL)
      entry.pre_resolved = True
      entry.resp = VIP_MC_AXI4_RESP_SLVERR_C

    if not wlast:
      return False

    self.pending_aw_q.pop(0)

    if not entry.pre_resolved:
      if entry.is_exclusive:
        if not self.check_and_clear_exclusive_reservation(entry):
          entry.pre_resolved = True
          entry.resp = VIP_MC_AXI4_RESP_OKAY_C
          if self.mc_cfg.perf_counters_enabled:
            self.excl_fail_count += 1
          self.record_local_reject(
              VipMcStatusOp.WR, VipMcStatusReject.EXCLUSIVE_FAIL_LOCAL)
        else:
          self.invalidate_exclusive_reservations_for_write(entry)
      else:
        self.invalidate_exclusive_reservations_for_write(entry)

    if entry.pre_resolved:
      self.complete_local(entry)
    else:
      self.issue_request(entry)
    return True

  def advance_w_data_buffer_model(self, w_accepted: bool,
                                  w_burst_completed: bool) -> None:
    if w_burst_completed:
      self.w_data_buf_occupancy = 0
    elif w_accepted:
      self.w_data_buf_occupancy += 1
    elif self.w_data_buf_occupancy > 0:
      self.w_data_buf_occupancy -= 1

  def capture_ar(self) -> None:
    self.observed_ar_count += 1
    entry = self._build_addr_entry("ar", VipDramOp.RD, self.observed_ar_count)

    if entry.pre_resolved:
      entry.rdata = [0] * entry.axi_beats
      self.complete_local(entry)
      return

    self.issue_request(entry)

  def _build_addr_entry(self, channel: str, op: VipDramOp,
                        count: int) -> vip_mc_cmd_entry:
    prefix = channel.lower()
    entry = vip_mc_cmd_entry(f"{prefix}_cmd_{count}")
    is_write = op == VipDramOp.WR
    size = self.vif.get_or(f"{prefix}size")
    beats = self.vif.get_or(f"{prefix}len") + 1
    size_bytes = vip_mc_axi4_size_bytes(size)
    burst = self.vif.get_or(f"{prefix}burst")
    addr = self.vif.get_or(f"{prefix}addr")
    axcache = self.vif.get_or(f"{prefix}cache")

    entry.port_id = self.port_id
    entry.axi4_id = self.vif.get_or("awid" if is_write else "arid")
    entry.op = op
    entry.addr = addr
    entry.axi_beats = beats
    entry.axi_size_bytes = size_bytes
    entry.axi_burst = burst
    entry.beats = self.get_dram_req_beats(addr, size_bytes, beats, burst)
    entry.qos = self.vif.get_or(f"{prefix}qos")
    entry.qos_class = self.cfg.qos_to_class(entry.qos)
    entry.is_exclusive = self.vif.get_or(f"{prefix}lock") != 0
    entry.auser = self.vif.get_or(f"{prefix}user")
    entry.enqueue_time = sim_time_ns()

    resp, reject_reason = self.classify_request(addr, size_bytes, beats, burst)
    if resp != VIP_MC_AXI4_RESP_OKAY_C:
      entry.pre_resolved = True
      entry.resp = resp
      self.record_local_reject(
          VipMcStatusOp.WR if is_write else VipMcStatusOp.RD, reject_reason)
    elif not self.supports_axi_burst(addr, beats - 1, size, burst):
      entry.pre_resolved = True
      entry.resp = VIP_MC_AXI4_RESP_SLVERR_C
      self.record_local_reject(
          VipMcStatusOp.WR if is_write else VipMcStatusOp.RD,
          VipMcStatusReject.UNSUPPORTED_AXI_SHAPE)
    elif entry.is_exclusive and not self.supports_exclusive_request(
        addr, size_bytes, beats, axcache):
      entry.pre_resolved = True
      entry.resp = VIP_MC_AXI4_RESP_SLVERR_C
      self.record_local_reject(
          VipMcStatusOp.WR if is_write else VipMcStatusOp.RD,
          VipMcStatusReject.EXCLUSIVE_FAIL_LOCAL)

    return entry

  def issue_request(self, entry) -> None:
    self.last_issued = entry
    self.issued_req_count += 1
    if entry.op == VipDramOp.RD:
      self.inflight_rd_count += 1
    else:
      self.inflight_wr_count += 1
    self.req_port.write(entry)

  def complete_local(self, entry) -> None:
    now = sim_time_ns()
    entry.first_beat_ready_time = now
    entry.last_beat_ready_time = now
    entry.completed = True
    self.complete(entry)

  def supports_axi_burst(self, addr: int, axlen: int, axsize: int,
                         axburst: int) -> bool:
    size_bytes = vip_mc_axi4_size_bytes(axsize)
    beats = int(axlen) + 1
    if beats < 1 or size_bytes < 1 or size_bytes > self.geom.ROW_BYTES_P:
      return False
    if axburst == VIP_MC_AXI4_BURST_INCR_C:
      return True
    if axburst == VIP_MC_AXI4_BURST_FIXED_C:
      return beats <= 16
    if axburst == VIP_MC_AXI4_BURST_WRAP_C:
      return self.is_wrap_burst_length_supported(beats) and (addr % size_bytes) == 0
    return False

  def supports_exclusive_request(self, addr: int, size_bytes: int, beats: int,
                                 axcache: int) -> bool:
    if not self.cfg.exclusive_enabled:
      return False
    total_bytes = self.get_total_axi_transfer_bytes(size_bytes, beats)
    return (self.is_legal_exclusive_granule(total_bytes) and
            (addr & (total_bytes - 1)) == 0 and
            ((axcache >> 2) & 0b11) == 0)

  @staticmethod
  def get_total_axi_transfer_bytes(size_bytes: int, beats: int) -> int:
    return int(size_bytes) * int(beats)

  @staticmethod
  def is_legal_exclusive_granule(n_bytes: int) -> bool:
    return n_bytes >= 1 and n_bytes <= 128 and (n_bytes & (n_bytes - 1)) == 0

  @staticmethod
  def is_wrap_burst_length_supported(beats: int) -> bool:
    return beats in (2, 4, 8, 16)

  def classify_request(self, addr: int, size_bytes: int, beats: int,
                       axburst: int):
    first_addr = self.get_burst_window_first_addr(addr, size_bytes, beats, axburst)
    last_addr = self.last_byte_addr(addr, size_bytes, beats, axburst)
    if not self.port_owns_range(first_addr, last_addr):
      if self.mc_cfg.perf_counters_enabled:
        self.decerr_count += 1
      return VIP_MC_AXI4_RESP_DECERR_C, VipMcStatusReject.DECERR_REGION
    if self.range_hits_decerr(first_addr, last_addr):
      if self.mc_cfg.perf_counters_enabled:
        self.decerr_count += 1
      return VIP_MC_AXI4_RESP_DECERR_C, VipMcStatusReject.DECERR_REGION
    if self.crosses_4k_boundary(first_addr, last_addr):
      if self.mc_cfg.perf_counters_enabled:
        self.decerr_count += 1
        self.four_k_violation_count += 1
      return VIP_MC_AXI4_RESP_DECERR_C, VipMcStatusReject.DECERR_4K
    return VIP_MC_AXI4_RESP_OKAY_C, VipMcStatusReject.NONE

  def get_burst_window_first_addr(self, addr: int, size_bytes: int, beats: int,
                                  axburst: int) -> int:
    if axburst == VIP_MC_AXI4_BURST_WRAP_C:
      return self.get_wrap_region_base_addr(addr, size_bytes, beats)
    return int(addr)

  @staticmethod
  def get_wrap_region_base_addr(addr: int, size_bytes: int, beats: int) -> int:
    if beats == 0 or size_bytes == 0:
      return int(addr)
    region_bytes = int(size_bytes) * int(beats)
    return (int(addr) // region_bytes) * region_bytes

  def last_byte_addr(self, addr: int, size_bytes: int, beats: int,
                     axburst: int) -> int:
    if beats == 0 or size_bytes == 0:
      return int(addr)
    unaligned_bytes = int(addr) % int(size_bytes)
    if axburst == VIP_MC_AXI4_BURST_FIXED_C:
      valid_bytes = int(size_bytes) - unaligned_bytes
      if valid_bytes == 0:
        valid_bytes = int(size_bytes)
      return int(addr) + valid_bytes - 1
    if axburst == VIP_MC_AXI4_BURST_WRAP_C:
      region_bytes = int(size_bytes) * int(beats)
      return self.get_wrap_region_base_addr(addr, size_bytes, beats) + region_bytes - 1
    total_bytes = int(size_bytes) * int(beats) - unaligned_bytes
    return int(addr) + total_bytes - 1

  @staticmethod
  def get_axi_unaligned_byte_shift(entry) -> int:
    return int(entry.addr) % int(entry.axi_size_bytes)

  def get_axi_valid_byte_count(self, entry, axi_beat_idx: int) -> int:
    if entry.axi_burst == VIP_MC_AXI4_BURST_FIXED_C or axi_beat_idx == 0:
      return int(entry.axi_size_bytes) - self.get_axi_unaligned_byte_shift(entry)
    return int(entry.axi_size_bytes)

  def get_axi_first_valid_byte_addr(self, entry, axi_beat_idx: int) -> int:
    if entry.axi_burst == VIP_MC_AXI4_BURST_FIXED_C:
      return int(entry.addr)
    if entry.axi_burst == VIP_MC_AXI4_BURST_WRAP_C:
      base_addr = self.get_burst_window_first_addr(
          entry.addr, entry.axi_size_bytes, entry.axi_beats, entry.axi_burst)
      region_bytes = int(entry.axi_size_bytes) * int(entry.axi_beats)
      beat_offset = int(axi_beat_idx) * int(entry.axi_size_bytes)
      return base_addr + ((int(entry.addr) - base_addr + beat_offset) % region_bytes)
    if axi_beat_idx == 0:
      return int(entry.addr)
    return (int(entry.addr) + (int(axi_beat_idx) * int(entry.axi_size_bytes)) -
            self.get_axi_unaligned_byte_shift(entry))

  def get_dram_req_beats(self, addr: int, size_bytes: int, axi_beats: int,
                         axburst: int) -> int:
    if axi_beats == 0:
      return 0
    if axburst == VIP_MC_AXI4_BURST_FIXED_C:
      return 1
    first_addr = self.get_burst_window_first_addr(
        addr, size_bytes, axi_beats, axburst)
    last_addr = self.last_byte_addr(addr, size_bytes, axi_beats, axburst)
    return ((last_addr // self.geom.ROW_BYTES_P) -
            (first_addr // self.geom.ROW_BYTES_P) + 1)

  def register_exclusive_reservation(self, entry) -> None:
    total_bytes = self.get_total_axi_transfer_bytes(
        entry.axi_size_bytes, entry.axi_beats)
    if not self.is_legal_exclusive_granule(total_bytes):
      return
    self.exclusive_reservations.setdefault(entry.addr, {})[entry.axi4_id] = total_bytes

  def check_and_clear_exclusive_reservation(self, entry) -> bool:
    total_bytes = self.get_total_axi_transfer_bytes(
        entry.axi_size_bytes, entry.axi_beats)
    by_id = self.exclusive_reservations.get(entry.addr, {})
    ok = by_id.get(entry.axi4_id) == total_bytes
    if entry.axi4_id in by_id:
      del by_id[entry.axi4_id]
      if not by_id:
        self.exclusive_reservations.pop(entry.addr, None)
    return ok

  def invalidate_exclusive_reservations_for_write(self, entry) -> None:
    first_addr = self.get_burst_window_first_addr(
        entry.addr, entry.axi_size_bytes, entry.axi_beats, entry.axi_burst)
    last_addr = self.last_byte_addr(
        entry.addr, entry.axi_size_bytes, entry.axi_beats, entry.axi_burst)
    self.invalidate_exclusive_reservations(first_addr, last_addr - first_addr + 1)

  def invalidate_exclusive_reservations(self, addr: int, n_bytes: int) -> None:
    if n_bytes == 0:
      return
    wr_lo = int(addr)
    wr_hi = wr_lo + int(n_bytes) - 1
    victims = []
    for base, by_id in self.exclusive_reservations.items():
      for axi4_id, res_bytes in by_id.items():
        res_lo = int(base)
        res_hi = res_lo + int(res_bytes) - 1
        if self.ranges_overlap(wr_lo, wr_hi, res_lo, res_hi):
          victims.append((base, axi4_id))
    for base, axi4_id in victims:
      by_id = self.exclusive_reservations.get(base)
      if by_id is None:
        continue
      by_id.pop(axi4_id, None)
      if not by_id:
        self.exclusive_reservations.pop(base, None)

  @staticmethod
  def ranges_overlap(a_lo: int, a_hi: int, b_lo: int, b_hi: int) -> bool:
    return a_lo <= b_hi and b_lo <= a_hi

  def fill_active_r_streams(self) -> None:
    if self.active_r_q or not self.pending_r_q:
      return
    self.active_r_q.append(self.pending_r_q.pop(0))
    self.active_r_beat_idx_q.append(0)

  def pack_write_beat(self, entry, axi_beat_idx: int, wdata: int,
                      wstrb: int) -> None:
    burst_base_addr = self.get_burst_window_first_addr(
        entry.addr, entry.axi_size_bytes, entry.axi_beats, entry.axi_burst)
    first_valid_addr = self.get_axi_first_valid_byte_addr(entry, axi_beat_idx)
    valid_bytes = self.get_axi_valid_byte_count(entry, axi_beat_idx)
    base_row_idx = burst_base_addr // self.geom.ROW_BYTES_P
    row_idx = (first_valid_addr // self.geom.ROW_BYTES_P) - base_row_idx
    row_lane_offset = first_valid_addr % self.geom.ROW_BYTES_P
    bus_lane_offset = first_valid_addr % self.cfg_t.WDATA_BYTES_P

    if row_idx >= len(entry.wdata):
      self.logger.error(
          f"Computed write row index {row_idx} outside wdata.size={len(entry.wdata)}")
      return

    for byte_idx in range(valid_bytes):
      row_lane = row_lane_offset + byte_idx
      bus_lane = bus_lane_offset + byte_idx
      if row_lane >= self.geom.ROW_BYTES_P:
        self.logger.error(
            f"Computed write row lane {row_lane} outside ROW_BYTES_P="
            f"{self.geom.ROW_BYTES_P}")
        return
      if bus_lane >= self.cfg_t.WDATA_BYTES_P:
        self.logger.error(
            f"Computed write bus lane {bus_lane} outside WDATA_BYTES_P="
            f"{self.cfg_t.WDATA_BYTES_P}")
        return
      if (int(wstrb) >> bus_lane) & 1:
        byte = (int(wdata) >> (8 * bus_lane)) & 0xff
        entry.wdata[row_idx] &= ~(0xff << (8 * row_lane))
        entry.wdata[row_idx] |= byte << (8 * row_lane)
        entry.wstrb[row_idx] |= 1 << row_lane

  def unpack_read_beat(self, entry, axi_beat_idx: int) -> int:
    beat_rdata = 0
    burst_base_addr = self.get_burst_window_first_addr(
        entry.addr, entry.axi_size_bytes, entry.axi_beats, entry.axi_burst)
    first_valid_addr = self.get_axi_first_valid_byte_addr(entry, axi_beat_idx)
    valid_bytes = self.get_axi_valid_byte_count(entry, axi_beat_idx)
    base_row_idx = burst_base_addr // self.geom.ROW_BYTES_P
    row_idx = (first_valid_addr // self.geom.ROW_BYTES_P) - base_row_idx
    row_lane_offset = first_valid_addr % self.geom.ROW_BYTES_P
    bus_lane_offset = first_valid_addr % self.cfg_t.RDATA_BYTES_P

    if row_idx >= len(entry.rdata):
      self.logger.error(
          f"Computed read row index {row_idx} outside rdata.size={len(entry.rdata)}")
      return beat_rdata

    for byte_idx in range(valid_bytes):
      row_lane = row_lane_offset + byte_idx
      bus_lane = bus_lane_offset + byte_idx
      if row_lane >= self.geom.ROW_BYTES_P:
        self.logger.error(
            f"Computed read row lane {row_lane} outside ROW_BYTES_P="
            f"{self.geom.ROW_BYTES_P}")
        return beat_rdata
      if bus_lane >= self.cfg_t.RDATA_BYTES_P:
        self.logger.error(
            f"Computed read bus lane {bus_lane} outside RDATA_BYTES_P="
            f"{self.cfg_t.RDATA_BYTES_P}")
        return beat_rdata
      byte = (int(entry.rdata[row_idx]) >> (8 * row_lane)) & 0xff
      beat_rdata |= byte << (8 * bus_lane)

    return beat_rdata

  @staticmethod
  def crosses_4k_boundary(addr: int, last_addr: int) -> bool:
    return (int(addr) // VIP_MC_AXI4_4K_ADDRESS_BOUNDARY_C) != (
        int(last_addr) // VIP_MC_AXI4_4K_ADDRESS_BOUNDARY_C)

  def port_owns_range(self, addr: int, last_addr: int) -> bool:
    port_cfg = self.mc_cfg.ports[self.port_id]
    if not port_cfg.regions:
      return True
    return any(int(addr) >= r.lo and int(last_addr) <= r.hi
               for r in port_cfg.regions)

  def range_hits_decerr(self, addr: int, last_addr: int) -> bool:
    for lo, hi in zip(self.cfg.decerr_addr_lo, self.cfg.decerr_addr_hi):
      if int(addr) <= hi and int(last_addr) >= lo:
        return True
    return False

  def advance_write_rsp_channel(self) -> None:
    if self.vif.get_or("bvalid") == 1 and self.vif.get_or("bready") == 1:
      if self.active_b is not None and not self.active_b.pre_resolved:
        self.inflight_wr_count = max(0, self.inflight_wr_count - 1)
      self.active_b = None
      self.clear_b_channel()

    if self.active_b is None and self.pending_b_q:
      head = self.pending_b_q[0]
      if (not self.mc_cfg.honor_beat_timing or head.pre_resolved or
          (sim_time_ns() + BEAT_EPS_C) >= head.last_beat_ready_time):
        if (self.mc_cfg.honor_beat_timing and not head.pre_resolved and
            self.prev_cb_time >= 0.0 and
            (self.prev_cb_time + BEAT_EPS_C) >= head.last_beat_ready_time):
          self.rsp_late_count += 1
        self.active_b = self.pending_b_q.pop(0)
        self.vif.drive_opt(
            bid=self.active_b.axi4_id,
            bresp=self.active_b.resp,
            buser=self.active_b.auser,
            bvalid=1)

  def advance_read_rsp_channel(self) -> None:
    if self.vif.get_or("rvalid") == 1 and self.vif.get_or("rready") == 1:
      if 0 <= self.active_r_slot_idx < len(self.active_r_q):
        if (self.active_r_beat_idx_q[self.active_r_slot_idx] + 1 >=
            self.active_r_q[self.active_r_slot_idx].axi_beats):
          if not self.active_r_q[self.active_r_slot_idx].pre_resolved:
            self.inflight_rd_count = max(0, self.inflight_rd_count - 1)
          del self.active_r_q[self.active_r_slot_idx]
          del self.active_r_beat_idx_q[self.active_r_slot_idx]
        else:
          self.active_r_beat_idx_q[self.active_r_slot_idx] += 1
      self.active_r_slot_idx = -1
      self.clear_r_channel()
    elif self.vif.get_or("rvalid") == 1 and self.vif.get_or("rready") == 0:
      return

    self.fill_active_r_streams()
    if not self.active_r_q:
      self.active_r_slot_idx = -1
      return

    self.active_r_slot_idx = 0 if self.r_slot_beat_ready(0) else -1
    if self.active_r_slot_idx < 0:
      self.clear_r_channel()
      return
    self.drive_active_r_beat()

  def r_beat_target(self, entry, beat_idx: int) -> float:
    if entry.axi_beats <= 1:
      return float(entry.first_beat_ready_time)
    span = float(entry.last_beat_ready_time) - float(entry.first_beat_ready_time)
    step = span / float(entry.axi_beats - 1)
    return float(entry.first_beat_ready_time) + (float(beat_idx) * step)

  def r_slot_beat_ready(self, slot: int) -> bool:
    if slot < 0 or slot >= len(self.active_r_q):
      return False
    if not self.mc_cfg.honor_beat_timing:
      return True
    entry = self.active_r_q[slot]
    if entry.pre_resolved:
      return True
    return (sim_time_ns() + BEAT_EPS_C) >= self.r_beat_target(
        entry, self.active_r_beat_idx_q[slot])

  def drive_active_r_beat(self) -> None:
    if self.active_r_slot_idx < 0 or self.active_r_slot_idx >= len(self.active_r_q):
      self.clear_r_channel()
      return

    entry = self.active_r_q[self.active_r_slot_idx]
    beat_idx = self.active_r_beat_idx_q[self.active_r_slot_idx]
    if (self.mc_cfg.honor_beat_timing and not entry.pre_resolved and
        beat_idx == 0 and self.prev_cb_time >= 0.0 and
        (self.prev_cb_time + BEAT_EPS_C) >= entry.first_beat_ready_time):
      self.rsp_late_count += 1

    rdata = (entry.rdata[beat_idx] if entry.pre_resolved and
             len(entry.rdata) > beat_idx else self.unpack_read_beat(entry, beat_idx))
    self.vif.drive_opt(
        rid=entry.axi4_id,
        rdata=rdata,
        rresp=entry.resp,
        rlast=1 if (beat_idx + 1) == entry.axi_beats else 0,
        ruser=entry.auser,
        rvalid=1)

  def clear_b_channel(self) -> None:
    self.vif.drive_opt(
        bid=0, bresp=VIP_MC_AXI4_RESP_OKAY_C, buser=0, bvalid=0)

  def clear_r_channel(self) -> None:
    self.vif.drive_opt(
        rid=0, rdata=0, rresp=VIP_MC_AXI4_RESP_OKAY_C, rlast=0, ruser=0,
        rvalid=0)

  def record_local_reject(self, op, reason) -> None:
    self.local_reject_count += 1
    self.last_reject_op = op
    self.last_reject_reason = reason

  def get_decerr_count(self) -> int:
    return self.decerr_count if self.mc_cfg.perf_counters_enabled else 0

  def get_4k_violation_count(self) -> int:
    return self.four_k_violation_count if self.mc_cfg.perf_counters_enabled else 0

  def get_wready_stall_cycles(self) -> int:
    return self.wready_stall_cycles if self.mc_cfg.perf_counters_enabled else 0

  def get_rsp_late_count(self) -> int:
    return self.rsp_late_count if self.mc_cfg.perf_counters_enabled else 0

  def get_exokay_count(self) -> int:
    return self.exokay_count if self.mc_cfg.perf_counters_enabled else 0

  def get_excl_fail_count(self) -> int:
    return self.excl_fail_count if self.mc_cfg.perf_counters_enabled else 0

  def get_rsp_buf_full_cycles(self) -> int:
    return self.rsp_buf_full_cycles if self.mc_cfg.perf_counters_enabled else 0

  def get_rd_outstanding_count(self) -> int:
    return self.inflight_rd_count + len(self.pending_r_q) + len(self.active_r_q)

  def get_wr_outstanding_count(self) -> int:
    return (self.inflight_wr_count + len(self.pending_aw_q) +
            len(self.pending_b_q) + (1 if self.active_b is not None else 0))

  def get_aw_pending_depth(self) -> int:
    return len(self.pending_aw_q)

  def get_pending_b_depth(self) -> int:
    return len(self.pending_b_q) + (1 if self.active_b is not None else 0)

  def get_pending_r_depth(self) -> int:
    return len(self.pending_r_q)

  def get_active_r_slots_used(self) -> int:
    return len(self.active_r_q)

  def get_w_data_buf_occupancy(self) -> int:
    return self.w_data_buf_occupancy

  def get_rsp_slots_used_count(self) -> int:
    return self.get_rsp_slots_used()

  def get_local_reject_count(self) -> int:
    return self.local_reject_count

  def get_last_reject_op(self):
    return self.last_reject_op

  def get_last_reject_reason(self):
    return self.last_reject_reason

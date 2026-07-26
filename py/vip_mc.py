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
## Top-level pyUVM component for the AXI4-backed vip_mc Python slice.
##
################################################################################

from __future__ import annotations

import cocotb
from cocotb.triggers import Timer
from pyuvm import ConfigDB, UVMConfigItemNotFound, uvm_component

from vip_dram import vip_dram
from vip_dram_config import VipDramConfig
from vip_dram_types_pkg import VIP_DRAM_CFG_DEFAULT, VipDramOp, delay_ns, sim_time_ns

from vip_mc_axi4_driver import vip_mc_axi4_driver
from vip_mc_axi4_types_pkg import (
  VIP_MC_AXI4_RESP_DECERR_C,
  VIP_MC_AXI4_RESP_EXOKAY_C,
  VIP_MC_AXI4_RESP_OKAY_C,
  VIP_MC_AXI4_RESP_SLVERR_C,
  VipMcAxi4CfgT,
)
from vip_mc_backend import vip_mc_backend
from vip_mc_config import vip_mc_config
from vip_mc_refresh import vip_mc_refresh
from vip_mc_status_snapshot import vip_mc_status_snapshot
from vip_mc_types_pkg import (
  VipMcProto,
  VipMcStatusFeBlock,
  VipMcStatusOp,
  VipMcStatusPage,
  VipMcStatusReject,
  VipMcStatusRsp,
  VipMcStatusStall,
)


class vip_mc(uvm_component):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.cfg = None
    self.geom = VIP_DRAM_CFG_DEFAULT
    self.dram_cfg = None
    self.env_cfg = None
    self.status_vif = None
    self.status_snapshot = None
    self.port_cfgs = []
    self.axi4_vifs = []
    self.axi4_cfg_ts = []
    self.chi_vifs = []
    self.chi_cfg_ts = []
    self.n_ports = 1

    self.dram = None
    self.backend = None
    self.refresh = None
    self.fes = []
    self._refresh_task = None
    self.last_status_issued_count = 0
    self.last_status_completed_count = 0
    self.last_status_refresh_count = 0
    self.last_status_reject_count = []

  def build_phase(self):
    self._resolve_config()

    self.cfg.ensure_port_count(self.n_ports)
    self._ensure_port_cfgs()
    self._require_supported_ports()
    self.cfg.validate(self.geom)
    self.cfg.axi4.aw_outstanding_limit = self.cfg.max_outstanding_wr
    self.cfg.axi4.ar_outstanding_limit = self.cfg.max_outstanding_rd
    self.status_snapshot = vip_mc_status_snapshot("status_snapshot", self.n_ports)
    self.last_status_reject_count = [0] * self.n_ports

    if self.dram is None:
      if self.dram_cfg is None:
        self.dram_cfg = VipDramConfig("dram_cfg", self.geom)
      self.dram_cfg.addr_map = self.cfg.addr_map_policy
      self.dram_cfg.deliver_at_first_beat = bool(self.cfg.honor_beat_timing)
      ConfigDB().set(self, "dram", "cfg", self.dram_cfg)
      self.dram = vip_dram("dram", self)
    elif self.dram_cfg is None:
      self.dram_cfg = getattr(self.dram, "cfg", None)

    self.backend = vip_mc_backend(
        "backend", self, mc_cfg=self.cfg, dram=self.dram, n_ports=self.n_ports,
        geom=self.geom, now_func=sim_time_ns)

    if self.cfg.refresh_enabled:
      self.refresh = vip_mc_refresh(
          "refresh", cfg=self.cfg, geom=self.geom,
          req_port=self.backend.ref_export.analysis_export,
          now_func=sim_time_ns)

    self._build_frontends()

  def _resolve_config(self) -> None:
    try:
      self.env_cfg = ConfigDB().get(self, "", "env_cfg")
    except UVMConfigItemNotFound:
      self.env_cfg = None

    if self.env_cfg is not None:
      self.cfg = self.env_cfg.cfg
      self.geom = getattr(self.env_cfg, "geom", VIP_DRAM_CFG_DEFAULT)
      self.dram = self.env_cfg.dram
      self.status_vif = self.env_cfg.status_vif
      self.port_cfgs = list(self.env_cfg.ports)
      self.n_ports = int(self.env_cfg.n_ports)
      self.axi4_vifs = []
      self.axi4_cfg_ts = []
      self.chi_vifs = []
      self.chi_cfg_ts = []
      for holder in self.env_cfg.vif_h:
        if holder is None:
          self.axi4_vifs.append(None)
          self.axi4_cfg_ts.append(None)
          self.chi_vifs.append(None)
          self.chi_cfg_ts.append(None)
        elif holder.proto == VipMcProto.AXI4:
          self.axi4_vifs.append(holder.vif)
          self.axi4_cfg_ts.append(getattr(holder, "cfg_t", None))
          self.chi_vifs.append(None)
          self.chi_cfg_ts.append(None)
        elif holder.proto == VipMcProto.CHI:
          self.axi4_vifs.append(None)
          self.axi4_cfg_ts.append(None)
          self.chi_vifs.append(holder.vif)
          self.chi_cfg_ts.append(getattr(holder, "cfg_t", None))
        else:
          self.axi4_vifs.append(None)
          self.axi4_cfg_ts.append(None)
          self.chi_vifs.append(None)
          self.chi_cfg_ts.append(None)
      return

    try:
      self.cfg = ConfigDB().get(self, "", "config")
    except UVMConfigItemNotFound:
      try:
        self.cfg = ConfigDB().get(self, "", "cfg")
      except UVMConfigItemNotFound:
        self.cfg = vip_mc_config()

    try:
      self.geom = ConfigDB().get(self, "", "geom")
    except UVMConfigItemNotFound:
      self.geom = VIP_DRAM_CFG_DEFAULT

    try:
      self.dram = ConfigDB().get(self, "", "dram")
    except UVMConfigItemNotFound:
      self.dram = None

    try:
      self.status_vif = ConfigDB().get(self, "", "status_vif")
    except UVMConfigItemNotFound:
      self.status_vif = None

    try:
      self.port_cfgs = list(ConfigDB().get(self, "", "ports"))
    except UVMConfigItemNotFound:
      self.port_cfgs = []

    try:
      self.dram_cfg = ConfigDB().get(self, "", "dram_cfg")
    except UVMConfigItemNotFound:
      self.dram_cfg = None

    try:
      self.axi4_vifs = list(ConfigDB().get(self, "", "axi4_vifs"))
    except UVMConfigItemNotFound:
      try:
        self.axi4_vifs = [ConfigDB().get(self, "", "vif")]
      except UVMConfigItemNotFound:
        self.axi4_vifs = []

    try:
      self.axi4_cfg_ts = list(ConfigDB().get(self, "", "axi4_cfg_ts"))
    except UVMConfigItemNotFound:
      try:
        self.axi4_cfg_ts = [ConfigDB().get(self, "", "cfg_t")]
      except UVMConfigItemNotFound:
        self.axi4_cfg_ts = []

    try:
      self.chi_vifs = list(ConfigDB().get(self, "", "chi_vifs"))
    except UVMConfigItemNotFound:
      try:
        self.chi_vifs = [ConfigDB().get(self, "", "chi_vif")]
      except UVMConfigItemNotFound:
        self.chi_vifs = []

    try:
      self.chi_cfg_ts = list(ConfigDB().get(self, "", "chi_cfg_ts"))
    except UVMConfigItemNotFound:
      try:
        self.chi_cfg_ts = [ConfigDB().get(self, "", "chi_cfg_t")]
      except UVMConfigItemNotFound:
        self.chi_cfg_ts = []

    try:
      self.n_ports = int(ConfigDB().get(self, "", "n_ports"))
    except UVMConfigItemNotFound:
      self.n_ports = max(1, len(self.axi4_vifs))

  def _ensure_port_cfgs(self) -> None:
    if len(self.port_cfgs) < self.n_ports:
      self.port_cfgs = list(self.port_cfgs)
      self.port_cfgs.extend([None] * (self.n_ports - len(self.port_cfgs)))

  def _require_supported_ports(self) -> None:
    if self.n_ports < 1:
      raise RuntimeError(
          f"[{self.get_name()}] vip_mc requires at least one host port "
          f"(n_ports={self.n_ports})")
    for port_id in range(self.n_ports):
      port_cfg = self.port_cfgs[port_id]
      proto = getattr(port_cfg, "proto", VipMcProto.AXI4)
      if proto not in (VipMcProto.AXI4, VipMcProto.CHI):
        raise RuntimeError(
            f"[{self.get_name()}] Unsupported port {port_id} proto {proto}")

  def _build_frontends(self) -> None:
    self.fes = [None] * self.n_ports
    for port_id in range(self.n_ports):
      proto = getattr(self.port_cfgs[port_id], "proto", VipMcProto.AXI4)
      inst = f"fe_{port_id}"
      if proto == VipMcProto.AXI4:
        port_vif, cfg_t = self._resolve_axi4_vif(port_id)
        ConfigDB().set(self, inst, "vif", port_vif)
        ConfigDB().set(self, inst, "cfg", self.cfg)
        ConfigDB().set(self, inst, "axi4_cfg", self.cfg.axi4)
        ConfigDB().set(self, inst, "cfg_t", cfg_t)
        ConfigDB().set(self, inst, "geom", self.geom)
        fe = vip_mc_axi4_driver(inst, self)
        fe.port_id = port_id
        fe.vif = port_vif
        fe.cfg_t = cfg_t
        fe.cfg = self.cfg.axi4
        fe.mc_cfg = self.cfg
        fe.geom = self.geom
        self.fes[port_id] = fe
      elif proto == VipMcProto.CHI:
        from vip_mc_chi_driver import vip_mc_chi_driver

        port_vif, cfg_t = self._resolve_chi_vif(port_id)
        ConfigDB().set(self, inst, "vif", port_vif)
        ConfigDB().set(self, inst, "cfg", self.cfg)
        ConfigDB().set(self, inst, "chi_cfg", self.cfg.chi)
        ConfigDB().set(self, inst, "cfg_t", cfg_t)
        ConfigDB().set(self, inst, "geom", self.geom)
        fe = vip_mc_chi_driver(inst, self)
        fe.port_id = port_id
        fe.vif = port_vif
        fe.cfg_t = cfg_t
        fe.chi_cfg = self.cfg.chi
        fe.mc_cfg = self.cfg
        fe.geom = self.geom
        self.fes[port_id] = fe

  def _resolve_axi4_vif(self, port_id: int):
    if self.env_cfg is not None:
      holder = self.env_cfg.vif_h[port_id]
      if holder is None:
        raise RuntimeError(
            f"[{self.get_name()}] env_cfg.vif_h[{port_id}] is null")
      if holder.proto != VipMcProto.AXI4:
        raise RuntimeError(
            f"[{self.get_name()}] env_cfg.vif_h[{port_id}] is not an AXI4 holder")
      cfg_t = getattr(holder, "cfg_t", None) or self._default_axi4_cfg_t()
      return holder.vif, cfg_t

    if port_id < len(self.axi4_vifs) and self.axi4_vifs[port_id] is not None:
      cfg_t = (self.axi4_cfg_ts[port_id] if port_id < len(self.axi4_cfg_ts)
               and self.axi4_cfg_ts[port_id] is not None
               else self._default_axi4_cfg_t())
      return self.axi4_vifs[port_id], cfg_t

    key = self.cfg.ports[port_id].vif_key
    try:
      port_vif = ConfigDB().get(self, "", key)
    except UVMConfigItemNotFound as exc:
      raise RuntimeError(
          f"[{self.get_name()}] vip_mc requires AXI4 port {port_id} vif "
          f"under key '{key}'") from exc

    cfg_t = self.axi4_cfg_ts[port_id] if port_id < len(self.axi4_cfg_ts) else None
    return port_vif, cfg_t or self._default_axi4_cfg_t()

  def _resolve_chi_vif(self, port_id: int):
    if self.env_cfg is not None:
      holder = self.env_cfg.vif_h[port_id]
      if holder is None:
        raise RuntimeError(
            f"[{self.get_name()}] env_cfg.vif_h[{port_id}] is null")
      if holder.proto != VipMcProto.CHI:
        raise RuntimeError(
            f"[{self.get_name()}] env_cfg.vif_h[{port_id}] is not a CHI holder")
      cfg_t = getattr(holder, "cfg_t", None) or self.port_cfgs[port_id].chi
      return holder.vif, cfg_t

    if port_id < len(self.chi_vifs) and self.chi_vifs[port_id] is not None:
      cfg_t = (self.chi_cfg_ts[port_id] if port_id < len(self.chi_cfg_ts)
               and self.chi_cfg_ts[port_id] is not None
               else self.port_cfgs[port_id].chi)
      return self.chi_vifs[port_id], cfg_t

    key = self.cfg.ports[port_id].vif_key
    try:
      port_vif = ConfigDB().get(self, "", key)
    except UVMConfigItemNotFound as exc:
      raise RuntimeError(
          f"[{self.get_name()}] vip_mc requires CHI port {port_id} vif "
          f"under key '{key}'") from exc

    cfg_t = self.chi_cfg_ts[port_id] if port_id < len(self.chi_cfg_ts) else None
    return port_vif, cfg_t or self.port_cfgs[port_id].chi

  def _default_axi4_cfg_t(self) -> VipMcAxi4CfgT:
    return VipMcAxi4CfgT(
        AWID_WIDTH_P=4,
        ARID_WIDTH_P=4,
        ADDR_WIDTH_P=self.geom.ADDR_WIDTH_P,
        WDATA_BYTES_P=self.geom.ROW_BYTES_P,
        RDATA_BYTES_P=self.geom.ROW_BYTES_P)

  def connect_phase(self):
    self.backend.req_port.connect(self.dram.req_fifo.analysis_export)
    self.dram.rsp_port.connect(self.backend.analysis_export)
    for port_id, fe in enumerate(self.fes):
      self.backend.register_port(port_id, fe)

  def start_of_simulation_phase(self):
    if self.refresh is not None:
      refresh_interval_ns = self.cfg.tREFI_override
      if refresh_interval_ns < 0.0:
        refresh_interval_ns = self.dram.cfg.timing.tREFI
      self.refresh.cache_trefi_ns(refresh_interval_ns)

  async def run_phase(self):
    reset_vif = self.get_reset_vif()
    if reset_vif is None:
      return
    if self.status_vif is not None:
      self.status_snapshot.clear()
      self.status_snapshot.rst_active = self._vif_rst_value(reset_vif) != 1
      self.drive_status_vif()

    last_rst = self._vif_rst_value(reset_vif)
    if last_rst == 1:
      self._arm_after_reset()
    while True:
      await reset_vif.rising()
      rst = self._vif_rst_value(reset_vif)
      if last_rst == 1 and rst == 0:
        await self.handle_reset()
      elif last_rst == 0 and rst == 1:
        self._arm_after_reset()
      last_rst = rst
      if self.status_vif is not None:
        self.update_status_snapshot(reset_vif)
        self.drive_status_vif()
        self.status_snapshot.clear_pulses()

  @staticmethod
  def _vif_rst_value(reset_vif) -> int:
    if hasattr(reset_vif, "get_rst"):
      return int(reset_vif.get_rst())
    if hasattr(reset_vif, "in_reset"):
      return 0 if reset_vif.in_reset() else 1
    return int(reset_vif.rst_n.value)

  def get_reset_vif(self):
    if not self.fes:
      return None
    for fe in self.fes:
      if fe is not None and getattr(fe, "vif", None) is not None:
        return fe.vif
    return None

  def _arm_after_reset(self) -> None:
    delay = self.cfg.init_delay_ns if self.cfg.init_delay_enabled else 0.0
    self.backend.init_gate_arm(delay)
    if self.refresh is not None and self._refresh_task is None:
      self.refresh.arm()
      self._refresh_task = cocotb.start_soon(self._refresh_loop())

  async def _refresh_loop(self):
    while True:
      trefi = self.refresh.tREFI_cached_ns
      if trefi <= 0.0:
        await Timer(1, unit="ns")
      else:
        await delay_ns(trefi)
      if self.refresh.armed:
        self.refresh.tick()

  async def handle_reset(self) -> None:
    for fe in self.fes:
      if fe is not None:
        fe.handle_reset()
    self.backend.flush()
    self.backend.clear_perf_counters()
    if self.refresh is not None:
      self.refresh.flush()
    if self._refresh_task is not None and not self._refresh_task.done():
      self._refresh_task.kill()
    self._refresh_task = None
    await self.dram.reset()
    if self.status_snapshot is not None:
      self.status_snapshot.clear()
      self.status_snapshot.rst_active = True
      self.last_status_issued_count = 0
      self.last_status_completed_count = 0
      self.last_status_refresh_count = 0
      self.last_status_reject_count = [0] * self.n_ports
      self.drive_status_vif()

  def perf_counters_enabled(self) -> bool:
    return self.cfg is not None and bool(self.cfg.perf_counters_enabled)

  def _axi4_fe(self, port_id: int):
    if port_id < 0 or port_id >= len(self.fes):
      return None
    fe = self.fes[port_id]
    return fe if isinstance(fe, vip_mc_axi4_driver) else None

  def get_refresh_count(self) -> int:
    if not self.perf_counters_enabled() or self.refresh is None:
      return 0
    return self.refresh.get_refresh_count()

  def get_cmd_queue_peak_depth(self) -> int:
    if not self.perf_counters_enabled() or self.backend is None:
      return 0
    return self.backend.get_cmd_queue_peak_depth()

  def get_row_hit_rate(self) -> float:
    if not self.perf_counters_enabled() or self.dram is None:
      return 0.0
    hit = self.dram.get_page_hit_count()
    miss = self.dram.get_page_miss_count()
    empty = self.dram.get_page_empty_count()
    total = hit + miss + empty
    return 0.0 if total == 0 else float(hit) / float(total)

  def get_predict_accuracy(self) -> float:
    if not self.perf_counters_enabled() or self.backend is None:
      return 0.0
    return self.backend.get_predict_accuracy()

  def get_effective_bandwidth(self) -> float:
    if not self.perf_counters_enabled() or self.backend is None:
      return 0.0
    return self.backend.get_effective_bandwidth()

  def get_bus_utilization(self) -> float:
    if not self.perf_counters_enabled() or self.backend is None:
      return 0.0
    return self.backend.get_bus_utilization()

  def get_observed_reorder_count(self) -> int:
    if not self.perf_counters_enabled() or self.backend is None:
      return 0
    return self.backend.get_observed_reorder_count()

  def get_mean_latency_ns(self) -> float:
    if not self.perf_counters_enabled() or self.backend is None:
      return 0.0
    return self.backend.get_mean_latency_ns()

  def get_min_latency_ns(self) -> float:
    if not self.perf_counters_enabled() or self.backend is None:
      return 0.0
    return self.backend.get_min_latency_ns()

  def get_max_latency_ns(self) -> float:
    if not self.perf_counters_enabled() or self.backend is None:
      return 0.0
    return self.backend.get_max_latency_ns()

  def get_latency_sample_count(self) -> int:
    if not self.perf_counters_enabled() or self.backend is None:
      return 0
    return self.backend.get_latency_sample_count()

  def get_latency_hist_count(self, bucket: int) -> int:
    if not self.perf_counters_enabled() or self.backend is None:
      return 0
    return self.backend.get_latency_hist_count(bucket)

  def get_occupancy_hist_count(self, depth: int) -> int:
    if not self.perf_counters_enabled() or self.backend is None:
      return 0
    return self.backend.get_occupancy_hist_count(depth)

  def get_occupancy_sample_count(self) -> int:
    if not self.perf_counters_enabled() or self.backend is None:
      return 0
    return self.backend.get_occupancy_sample_count()

  def get_port_completed_count(self, port_id: int = 0) -> int:
    if not self.perf_counters_enabled() or self.backend is None:
      return 0
    return self.backend.get_port_completed_count(port_id)

  def get_port_data_bytes(self, port_id: int = 0) -> int:
    if not self.perf_counters_enabled() or self.backend is None:
      return 0
    return self.backend.get_port_data_bytes(port_id)

  def get_ecc_corrected_count(self) -> int:
    if not self.perf_counters_enabled() or self.backend is None:
      return 0
    return self.backend.get_ecc_corrected_count()

  def get_ecc_uncorrectable_count(self) -> int:
    if not self.perf_counters_enabled() or self.backend is None:
      return 0
    return self.backend.get_ecc_uncorrectable_count()

  def get_fr_fcfs_forced_count(self) -> int:
    if not self.perf_counters_enabled() or self.backend is None:
      return 0
    return self.backend.get_fr_fcfs_forced_count()

  def get_bus_turnaround_count(self) -> int:
    if not self.perf_counters_enabled() or self.backend is None:
      return 0
    return self.backend.get_bus_turnaround_count()

  def get_rd_wr_grouped_count(self) -> int:
    if not self.perf_counters_enabled() or self.backend is None:
      return 0
    return self.backend.get_rd_wr_grouped_count()

  def get_decerr_count(self, port_id: int = 0) -> int:
    fe = self._axi4_fe(port_id)
    if not self.perf_counters_enabled():
      return 0
    if fe is not None:
      return fe.get_decerr_count()
    if port_id < 0 or port_id >= len(self.fes) or self.fes[port_id] is None:
      return 0
    return getattr(self.fes[port_id], "get_decerr_count", lambda: 0)()

  def get_4k_violation_count(self, port_id: int = 0) -> int:
    fe = self._axi4_fe(port_id)
    if not self.perf_counters_enabled() or fe is None:
      return 0
    return fe.get_4k_violation_count()

  def get_wready_stall_cycles(self, port_id: int = 0) -> int:
    fe = self._axi4_fe(port_id)
    if not self.perf_counters_enabled() or fe is None:
      return 0
    return fe.get_wready_stall_cycles()

  def get_rsp_late_count(self, port_id: int = 0) -> int:
    fe = self._axi4_fe(port_id)
    if not self.perf_counters_enabled() or fe is None:
      return 0
    return fe.get_rsp_late_count()

  def get_exokay_count(self, port_id: int = 0) -> int:
    fe = self._axi4_fe(port_id)
    if not self.perf_counters_enabled() or fe is None:
      return 0
    return fe.get_exokay_count()

  def get_excl_fail_count(self, port_id: int = 0) -> int:
    fe = self._axi4_fe(port_id)
    if not self.perf_counters_enabled() or fe is None:
      return 0
    return fe.get_excl_fail_count()

  def get_rsp_buf_full_cycles(self, port_id: int = 0) -> int:
    fe = self._axi4_fe(port_id)
    if not self.perf_counters_enabled() or fe is None:
      return 0
    return fe.get_rsp_buf_full_cycles()

  def sprint_telemetry(self) -> str:
    if self.cfg is None:
      return ""
    n_ports = self.backend.get_registered_port_count() if self.backend is not None else 0
    lines = [
        "",
        "---------------- vip_mc telemetry ----------------",
        f"  refresh_count           = {self.get_refresh_count()}",
        f"  cmd_queue_peak_depth    = {self.get_cmd_queue_peak_depth()}",
        f"  row_hit_rate            = {self.get_row_hit_rate():.4f}",
        f"  predict_accuracy_ns     = {self.get_predict_accuracy():.4f}",
        f"  effective_bw_B_per_ns   = {self.get_effective_bandwidth():.4f}",
        f"  bus_utilization         = {self.get_bus_utilization():.4f}",
        f"  observed_reorder_count  = {self.get_observed_reorder_count()}",
        "  latency n/min/mean/max ns= "
        f"{self.get_latency_sample_count()} / {self.get_min_latency_ns():.2f} / "
        f"{self.get_mean_latency_ns():.2f} / {self.get_max_latency_ns():.2f}",
        f"  occupancy_samples       = {self.get_occupancy_sample_count()}",
        "  ecc corrected/uncorrect = "
        f"{self.get_ecc_corrected_count()} / {self.get_ecc_uncorrectable_count()}",
        f"  fr_fcfs_forced_count    = {self.get_fr_fcfs_forced_count()}",
        f"  bus_turnaround_count    = {self.get_bus_turnaround_count()}",
        f"  rd_wr_grouped_count     = {self.get_rd_wr_grouped_count()}",
    ]
    if self.backend is not None:
      lines.append(
          f"  coalesced_write_count   = {self.backend.get_coalesced_write_count()}")
    for port_id in range(n_ports):
      lines.append(
          f"  port {port_id}: completed={self.get_port_completed_count(port_id)} "
          f"bytes={self.get_port_data_bytes(port_id)} "
          f"decerr={self.get_decerr_count(port_id)} "
          f"4k={self.get_4k_violation_count(port_id)} "
          f"wready_stall={self.get_wready_stall_cycles(port_id)} "
          f"rsp_late={self.get_rsp_late_count(port_id)} "
          f"exokay={self.get_exokay_count(port_id)} "
          f"excl_fail={self.get_excl_fail_count(port_id)} "
          f"rsp_buf_full={self.get_rsp_buf_full_cycles(port_id)}")
    lines.append("--------------------------------------------------")
    return "\n".join(lines)

  def update_status_snapshot(self, reset_vif) -> None:
    snap = self.status_snapshot
    snap.rst_active = self._vif_rst_value(reset_vif) != 1
    snap.cmd_queue_depth = self.backend.get_cmd_queue_depth()
    snap.cmd_queue_peak_depth = self.get_cmd_queue_peak_depth()
    snap.inflight_to_device = self.backend.get_inflight_to_device()
    snap.device_issue_credit_avail = self.backend.get_device_issue_credit_avail()
    snap.backend_stall_reason = (VipMcStatusStall.IN_RESET if snap.rst_active
                                 else self.backend.get_status_stall_reason())
    snap.refresh_count = self.get_refresh_count()

    self.update_status_per_port_levels()
    self.update_status_rsp_buf_summary()
    self.update_status_issue_pulse()
    self.update_status_complete_pulse()
    self.update_status_reject_pulse()

    current_refresh_count = snap.refresh_count
    if current_refresh_count != self.last_status_refresh_count:
      snap.refresh_emit_pulse = True
      snap.refresh_emit_rank = ((current_refresh_count - 1) % self.geom.N_RANKS_P
                                if self.geom.N_RANKS_P > 0 else 0)
      self.last_status_refresh_count = current_refresh_count
    else:
      snap.refresh_emit_pulse = False

  def update_status_rsp_buf_summary(self) -> None:
    used_slots = 0
    for fe in self.fes:
      if isinstance(fe, vip_mc_axi4_driver):
        used_slots += fe.get_rsp_slots_used_count()
    self.status_snapshot.rsp_buf_used = used_slots
    self.status_snapshot.rsp_buf_full = (
        self.cfg.rsp_buf_depth > 0 and used_slots >= self.cfg.rsp_buf_depth)

  def update_status_per_port_levels(self) -> None:
    for port_id in range(self.n_ports):
      fe = self._axi4_fe(port_id)
      if fe is None:
        self.status_snapshot.rd_outstanding_count[port_id] = 0
        self.status_snapshot.wr_outstanding_count[port_id] = 0
        self.status_snapshot.aw_pending_depth[port_id] = 0
        self.status_snapshot.pending_b_depth[port_id] = 0
        self.status_snapshot.pending_r_depth[port_id] = 0
        self.status_snapshot.active_r_slots_used[port_id] = 0
        self.status_snapshot.w_data_buf_occupancy[port_id] = 0
        self.status_snapshot.aw_block_reason[port_id] = VipMcStatusFeBlock.NONE
        self.status_snapshot.ar_block_reason[port_id] = VipMcStatusFeBlock.NONE
        self.status_snapshot.w_block_reason[port_id] = VipMcStatusFeBlock.NONE
        continue
      self.status_snapshot.rd_outstanding_count[port_id] = fe.get_rd_outstanding_count()
      self.status_snapshot.wr_outstanding_count[port_id] = fe.get_wr_outstanding_count()
      self.status_snapshot.aw_pending_depth[port_id] = fe.get_aw_pending_depth()
      self.status_snapshot.pending_b_depth[port_id] = fe.get_pending_b_depth()
      self.status_snapshot.pending_r_depth[port_id] = fe.get_pending_r_depth()
      self.status_snapshot.active_r_slots_used[port_id] = fe.get_active_r_slots_used()
      self.status_snapshot.w_data_buf_occupancy[port_id] = fe.get_w_data_buf_occupancy()
      self.status_snapshot.aw_block_reason[port_id] = fe.get_aw_block_reason()
      self.status_snapshot.ar_block_reason[port_id] = fe.get_ar_block_reason()
      self.status_snapshot.w_block_reason[port_id] = fe.get_w_block_reason()

  def update_status_issue_pulse(self) -> None:
    cmd = self.backend.last_issued_cmd
    if self.backend.issued_req_count != self.last_status_issued_count and cmd is not None:
      self.status_snapshot.issue_pulse = True
      self.status_snapshot.issue_port_id = cmd.port_id
      self.status_snapshot.issue_tag = cmd.tag
      self.status_snapshot.issue_op = self.map_status_op(cmd.op)
      self.status_snapshot.issue_qos_class = cmd.qos_class
      self.status_snapshot.issue_pre_resolved = cmd.pre_resolved
      self.last_status_issued_count = self.backend.issued_req_count
    else:
      self.status_snapshot.issue_pulse = False

  def update_status_complete_pulse(self) -> None:
    cmd = self.backend.last_completed_cmd
    if self.backend.completed_cmd_count != self.last_status_completed_count and cmd is not None:
      self.status_snapshot.complete_pulse = True
      self.status_snapshot.complete_port_id = cmd.port_id
      self.status_snapshot.complete_tag = cmd.tag
      self.status_snapshot.complete_op = self.map_status_op(cmd.op)
      self.status_snapshot.complete_resp = self.map_status_rsp(cmd.resp)
      self.status_snapshot.complete_page = self.map_status_page(self.backend.last_rsp)
      self.status_snapshot.complete_pre_resolved = cmd.pre_resolved
      self.last_status_completed_count = self.backend.completed_cmd_count
    else:
      self.status_snapshot.complete_pulse = False

  def update_status_reject_pulse(self) -> None:
    pulse_set = False
    self.status_snapshot.local_reject_pulse = False
    self.status_snapshot.local_reject_port_id = 0
    self.status_snapshot.local_reject_op = VipMcStatusOp.NONE
    self.status_snapshot.local_reject_reason = VipMcStatusReject.NONE

    for port_id in range(self.n_ports):
      fe = self._axi4_fe(port_id)
      if fe is None:
        self.last_status_reject_count[port_id] = 0
        continue
      current_count = fe.get_local_reject_count()
      if current_count != self.last_status_reject_count[port_id] and not pulse_set:
        self.status_snapshot.local_reject_pulse = True
        self.status_snapshot.local_reject_port_id = port_id
        self.status_snapshot.local_reject_op = fe.get_last_reject_op()
        self.status_snapshot.local_reject_reason = fe.get_last_reject_reason()
        pulse_set = True
        self.last_status_reject_count[port_id] = current_count

  def drive_status_vif(self) -> None:
    if self.status_vif is None or self.status_snapshot is None:
      return
    if hasattr(self.status_vif, "drive_from_snapshot"):
      self.status_vif.drive_from_snapshot(self.status_snapshot)
      return
    for name, value in vars(self.status_snapshot).items():
      if name.startswith("_") or name in ("name", "n_ports"):
        continue
      setattr(self.status_vif, name, list(value) if isinstance(value, list) else value)

  @staticmethod
  def map_status_op(op):
    if op == VipDramOp.RD:
      return VipMcStatusOp.RD
    if op == VipDramOp.WR:
      return VipMcStatusOp.WR
    if op == VipDramOp.REF:
      return VipMcStatusOp.REF
    return VipMcStatusOp.NONE

  @staticmethod
  def map_status_rsp(resp: int):
    if int(resp) == VIP_MC_AXI4_RESP_OKAY_C:
      return VipMcStatusRsp.OKAY
    if int(resp) == VIP_MC_AXI4_RESP_EXOKAY_C:
      return VipMcStatusRsp.EXOKAY
    if int(resp) == VIP_MC_AXI4_RESP_SLVERR_C:
      return VipMcStatusRsp.SLVERR
    if int(resp) == VIP_MC_AXI4_RESP_DECERR_C:
      return VipMcStatusRsp.DECERR
    return VipMcStatusRsp.NONE

  @staticmethod
  def map_status_page(rsp):
    if rsp is None:
      return VipMcStatusPage.UNKNOWN
    if getattr(rsp, "was_page_hit", False):
      return VipMcStatusPage.HIT
    if getattr(rsp, "was_page_miss", False):
      return VipMcStatusPage.MISS
    if getattr(rsp, "was_page_empty", False):
      return VipMcStatusPage.EMPTY
    return VipMcStatusPage.UNKNOWN

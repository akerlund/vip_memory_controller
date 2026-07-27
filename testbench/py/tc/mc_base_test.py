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
## Base test for the first vip_mc AXI4 pyUVM smoke cases.
##
################################################################################

from __future__ import annotations

import logging

import cocotb
from cocotb.triggers import RisingEdge, Timer, with_timeout
from pyuvm import ConfigDB, UVMConfigItemNotFound, uvm_subscriber, uvm_test

from seq_lib.vip_axi4_pipelined_seq import vip_axi4_pipelined_seq
from seq_lib.vip_axi4_read_seq import vip_axi4_read_seq
from seq_lib.vip_axi4_write_seq import vip_axi4_write_seq
from vip_axi4_item import vip_axi4_item
from vip_dram_addr_pkg import vip_dram_decode_addr, vip_dram_encode_addr
from vip_axi4_types_pkg import Axi4Access, Axi4DataType, Axi4StrbType
from vip_dram import vip_dram
from vip_dram_config import VipDramConfig
from vip_dram_req import VipDramReq
from vip_dram_timing_pkg import VipDramPreset
from vip_dram_types_pkg import (
  VIP_DRAM_CFG_DEFAULT, VipDramCfgT, VipDramDecT, VipDramFault, VipDramOp,
  sim_time_ns, vip_dram_default_addr_map,
)
from vip_mc_axi4_vif_holder import vip_mc_axi4_vif_holder
from mc_equiv_model import mc_equiv_model
from mc_equiv_program import EqOp, build_equiv_program
from vip_mc_axi4_types_pkg import (
  VIP_MC_AXI4_BURST_FIXED_C,
  VIP_MC_AXI4_BURST_INCR_C,
  VIP_MC_AXI4_BURST_WRAP_C,
  VIP_MC_AXI4_RESP_EXOKAY_C,
  VIP_MC_AXI4_RESP_OKAY_C,
  VIP_MC_AXI4_RESP_SLVERR_C,
)
from vip_mc_config import vip_mc_config
from vip_mc_env_cfg import vip_mc_env_cfg
from mc_tb_env import mc_tb_env
from vip_mc_types_pkg import (
  VipMcStatusFeBlock,
  VipMcStatusOp,
  VipMcStatusReject,
  VipMcRefreshPolicy,
)


class _ErrorCounter(logging.Handler):

  def __init__(self):
    super().__init__(level=logging.ERROR)
    self.count = 0

  def emit(self, record):
    if record.levelno >= logging.ERROR:
      self.count += 1


class _TelemetryCollector:

  def __init__(self):
    self.dram = None
    self.pred_by_tag = {}
    self.page_hit_count = 0
    self.page_miss_count = 0
    self.page_empty_count = 0
    self.predict_samples = 0
    self.predict_error_ns = 0.0
    self.data_bytes = 0
    self.busy_time_ns = 0.0
    self.first_data_ns = 0.0
    self.last_burst_end_ns = 0.0
    self.window_valid = False

  def clear(self) -> None:
    self.pred_by_tag.clear()
    self.page_hit_count = 0
    self.page_miss_count = 0
    self.page_empty_count = 0
    self.predict_samples = 0
    self.predict_error_ns = 0.0
    self.data_bytes = 0
    self.busy_time_ns = 0.0
    self.first_data_ns = 0.0
    self.last_burst_end_ns = 0.0
    self.window_valid = False

  def write_issued(self, entry) -> None:
    if entry is None or entry.op == VipDramOp.REF or self.dram is None:
      return

    req = VipDramReq("telemetry_predict_req")
    req.addr = int(entry.addr)
    req.op = entry.op
    req.beats = int(entry.beats)
    req.has_explicit_rank = bool(entry.has_explicit_rank)
    req.rank = int(entry.rank)
    req.tag = int(entry.tag)
    req.wdata = list(entry.wdata)
    req.wstrb = list(entry.wstrb)
    _, pred_last_ns = self.dram.predict(req)
    self.pred_by_tag[int(entry.tag)] = (int(entry.beats), float(pred_last_ns))

  def write_rsp(self, rsp) -> None:
    if rsp is None or self.dram is None or int(rsp.tag) not in self.pred_by_tag:
      return

    beats, pred_last_ns = self.pred_by_tag.pop(int(rsp.tag))
    if getattr(rsp, "was_page_hit", False):
      self.page_hit_count += 1
    elif getattr(rsp, "was_page_miss", False):
      self.page_miss_count += 1
    elif getattr(rsp, "was_page_empty", False):
      self.page_empty_count += 1

    self.predict_error_ns += abs(float(rsp.last_beat_ready_time) - pred_last_ns)
    self.predict_samples += 1

    row_bytes = int(self.dram.geom.ROW_BYTES_P)
    t_bl = float(self.dram.cfg.timing.tBL)
    burst_end_ns = float(rsp.last_beat_ready_time) + t_bl
    busy_span_ns = max(0.0, burst_end_ns - float(rsp.first_beat_ready_time))
    self.data_bytes += beats * row_bytes
    self.busy_time_ns += busy_span_ns

    if not self.window_valid or float(rsp.first_beat_ready_time) < self.first_data_ns:
      self.first_data_ns = float(rsp.first_beat_ready_time)
    if not self.window_valid or burst_end_ns > self.last_burst_end_ns:
      self.last_burst_end_ns = burst_end_ns
    self.window_valid = True

  def get_row_hit_rate(self) -> float:
    total = self.page_hit_count + self.page_miss_count + self.page_empty_count
    return 0.0 if total == 0 else self.page_hit_count / total

  def get_predict_accuracy(self) -> float:
    if self.predict_samples == 0:
      return 0.0
    return self.predict_error_ns / self.predict_samples

  def get_effective_bandwidth(self) -> float:
    if not self.window_valid:
      return 0.0
    window_ns = self.last_burst_end_ns - self.first_data_ns
    return 0.0 if window_ns <= 0.0 else self.data_bytes / window_ns

  def get_bus_utilization(self) -> float:
    if not self.window_valid:
      return 0.0
    window_ns = self.last_burst_end_ns - self.first_data_ns
    return 0.0 if window_ns <= 0.0 else self.busy_time_ns / window_ns


class _TelemetrySubscriber(uvm_subscriber):

  def __init__(self, name, parent, collector, kind):
    super().__init__(name, parent)
    self.collector = collector
    self.kind = kind

  def write(self, item):
    if self.kind == "issued":
      self.collector.write_issued(item)
    else:
      self.collector.write_rsp(item)


class mc_base_test(uvm_test):

  DRAM_GEOM = VIP_DRAM_CFG_DEFAULT
  MAX_WAIT_CYCLES = 2000
  USE_ENV_CFG = True
  SCOREBOARD_ENABLED = True
  SCOREBOARD_TIMING_CHECK = True
  MAN_WR_OUTSTANDING_MAX = 1
  MAN_RD_OUTSTANDING_MAX = 1
  MAN_BREADY_DELAY_ENABLED = False
  MAN_BREADY_DELAY_PERIOD = 1
  MAN_BREADY_DELAY_TIME = 1
  MAN_RREADY_DELAY_ENABLED = False
  MAN_RREADY_DELAY_PERIOD = 1
  MAN_RREADY_DELAY_TIME = 1

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.env = None
    self.bus = None
    self.buses = []
    self.cfg = None
    self.cfg_ts = []
    self.n_ports = 1
    self.status_vif = None
    self.external_dram = None
    self._err_handler = None

  def build_phase(self):
    self._resolve_bus_config()
    self.cfg = vip_mc_config("mc_cfg")
    self.cfg.ensure_port_count(self.n_ports)
    self._apply_default_env_config(self.cfg)
    self.configure(self.cfg)
    self._publish_mc_config()
    self.env = mc_tb_env("env", self)

  def _apply_default_env_config(self, cfg) -> None:
    cfg.qos_class_count = 4
    cfg.qos_aging_ns = 25.0
    cfg.max_outstanding_rd = 8
    cfg.max_outstanding_wr = 8
    cfg.rsp_buf_depth = 2
    cfg.max_inflight_to_device = 4
    cfg.refresh_enabled = False
    cfg.honor_beat_timing = True
    cfg.axi4.aw_pending_depth = 2
    cfg.axi4.w_data_buf_depth = 4
    cfg.axi4.qos_class_map[15] = 3
    cfg.axi4.clear_decerr_ranges()
    cfg.axi4.add_decerr_range(0x1000, 0x1fff)

    cfg.addr_map_policy = vip_dram_default_addr_map(self.DRAM_GEOM)
    old_bank_lsb = cfg.addr_map_policy.bank_lsb
    old_bg_lsb = cfg.addr_map_policy.bg_lsb
    cfg.addr_map_policy.bank_lsb = old_bg_lsb
    cfg.addr_map_policy.bg_lsb = old_bank_lsb

    for port in cfg.ports:
      port.clear_regions()
      port.add_region(0, self.get_max_addr())

  def _resolve_bus_config(self) -> None:
    try:
      self.buses = list(ConfigDB().get(self, "", "axi4_vifs"))
    except UVMConfigItemNotFound:
      self.buses = [ConfigDB().get(self, "", "vif")]
    self.bus = self.buses[0]

    try:
      self.cfg_ts = list(ConfigDB().get(self, "", "axi4_cfg_ts"))
    except UVMConfigItemNotFound:
      try:
        self.cfg_ts = [ConfigDB().get(self, "", "cfg_t")]
      except UVMConfigItemNotFound:
        self.cfg_ts = []

    try:
      self.n_ports = int(ConfigDB().get(self, "", "n_ports"))
    except UVMConfigItemNotFound:
      self.n_ports = len(self.buses)

    try:
      self.status_vif = ConfigDB().get(self, "", "status_vif")
    except UVMConfigItemNotFound:
      self.status_vif = None

  def _publish_mc_config(self) -> None:
    ConfigDB().set(self, "env", "manager_agents_active", True)
    ConfigDB().set(
        self, "env", "man_wr_outstanding_max", self.MAN_WR_OUTSTANDING_MAX)
    ConfigDB().set(
        self, "env", "man_rd_outstanding_max", self.MAN_RD_OUTSTANDING_MAX)
    ConfigDB().set(
        self, "env", "man_bready_delay_enabled",
        self.MAN_BREADY_DELAY_ENABLED)
    ConfigDB().set(
        self, "env", "man_bready_delay_period",
        self.MAN_BREADY_DELAY_PERIOD)
    ConfigDB().set(
        self, "env", "man_bready_delay_time",
        self.MAN_BREADY_DELAY_TIME)
    ConfigDB().set(
        self, "env", "man_rready_delay_enabled",
        self.MAN_RREADY_DELAY_ENABLED)
    ConfigDB().set(
        self, "env", "man_rready_delay_period",
        self.MAN_RREADY_DELAY_PERIOD)
    ConfigDB().set(
        self, "env", "man_rready_delay_time", self.MAN_RREADY_DELAY_TIME)
    if self.USE_ENV_CFG:
      dram_cfg = VipDramConfig("dram_cfg", self.DRAM_GEOM)
      dram_cfg.addr_map = self.cfg.addr_map_policy
      dram_cfg.deliver_at_first_beat = bool(self.cfg.honor_beat_timing)
      ConfigDB().set(self, "dram", "cfg", dram_cfg)
      self.external_dram = vip_dram("dram", self)

      env_cfg = vip_mc_env_cfg("env_cfg", self.n_ports, geom=self.DRAM_GEOM)
      env_cfg.cfg = self.cfg
      env_cfg.dram = self.external_dram
      env_cfg.status_vif = self.status_vif
      for port_id, bus in enumerate(self.buses):
        cfg_t = self.cfg_ts[port_id] if port_id < len(self.cfg_ts) else None
        env_cfg.register_vif(
            port_id,
            vip_mc_axi4_vif_holder(f"axi4_vif_h_{port_id}", bus, cfg_t))
      ConfigDB().set(self, "env.mc", "env_cfg", env_cfg)
      return

    ConfigDB().set(self, "env.mc", "cfg", self.cfg)
    if self.status_vif is not None:
      ConfigDB().set(self, "env.mc", "status_vif", self.status_vif)

  def configure(self, cfg) -> None:
    pass

  def connect_phase(self):
    self.env.scoreboard.enabled = self.SCOREBOARD_ENABLED
    self.env.scoreboard.timing_check_enabled = self.SCOREBOARD_TIMING_CHECK

  def end_of_elaboration_phase(self):
    self._err_handler = _ErrorCounter()
    self.add_logging_handler_hier(self._err_handler)

  async def body(self):
    pass

  async def run_phase(self):
    self.raise_objection()
    await self.bus.clocks(4)
    await self.body()
    self.drop_objection()

  def check_phase(self):
    n_errors = self._err_handler.count if self._err_handler is not None else 0
    if n_errors:
      raise AssertionError(f"{type(self).__name__}: {n_errors} UVM_ERROR(s) logged")

  async def write_axi(self, addr: int, data_beats, strb_beats=None, axi_id=0,
                      size=None, burst=VIP_MC_AXI4_BURST_INCR_C, awuser=0,
                      wuser=0, awlock=0, awcache=0, awqos=0, port_id=0,
                      return_info=False):
    size = self.get_full_width_axi_size() if size is None else int(size)
    if not isinstance(data_beats, list):
      data_beats = [data_beats]
    if strb_beats is None:
      strb_beats = [(1 << (1 << size)) - 1] * len(data_beats)
    elif not isinstance(strb_beats, list):
      strb_beats = [strb_beats]
    if len(strb_beats) != len(data_beats):
      raise ValueError("strb_beats must match data_beats")

    wr_seq = vip_axi4_write_seq(f"man_wr_p{port_id}", self._agent_cfg_t(port_id))
    wr_seq.reset()
    wr_seq.set_awid(axi_id)
    wr_seq.set_axaddr(addr)
    wr_seq.set_axlen(len(data_beats) - 1)
    wr_seq.set_axsize(size)
    wr_seq.set_axburst(burst)
    wr_seq.set_axlock(awlock)
    wr_seq.set_awcache(awcache)
    wr_seq.set_axqos(awqos)
    wr_seq.set_awuser(awuser)
    wr_seq.set_requests(1)
    wr_seq.set_get_wr_response(True)
    wr_seq.set_wdata_type(Axi4DataType.CUSTOM)
    wr_seq.set_wstrb_type(Axi4StrbType.CUSTOM)
    wr_seq.set_wuser_type(Axi4DataType.CUSTOM)
    wr_seq.set_wdata([int(x) for x in data_beats])
    wr_seq.set_wstrb([int(x) for x in strb_beats])
    wr_seq.set_wuser([int(wuser)] * len(data_beats))

    await self.start_seq_or_timeout(wr_seq, port_id)
    wr_rsps = wr_seq.get_wr_responses()
    if len(wr_rsps) != 1:
      raise AssertionError(
          f"stock AXI4 manager write returned {len(wr_rsps)} responses")
    rsp = wr_rsps[0]
    assert int(rsp.bid) == int(axi_id)
    if return_info:
      return {"id": int(rsp.bid), "resp": int(rsp.bresp), "user": int(rsp.buser)}
    return int(rsp.bresp)

  async def read_axi(self, addr: int, beats=1, axi_id=0, size=None,
                     burst=VIP_MC_AXI4_BURST_INCR_C, aruser=0, arlock=0,
                     arcache=0, arqos=0, port_id=0, return_info=False):
    size = self.get_full_width_axi_size() if size is None else int(size)
    rd_seq = vip_axi4_read_seq(f"man_rd_p{port_id}", self._agent_cfg_t(port_id))
    rd_seq.reset()
    rd_seq.set_arid(axi_id)
    rd_seq.set_axaddr(addr)
    rd_seq.set_axlen(beats - 1)
    rd_seq.set_axsize(size)
    rd_seq.set_axburst(burst)
    rd_seq.set_axlock(arlock)
    rd_seq.set_arcache(arcache)
    rd_seq.set_axqos(arqos)
    rd_seq.set_aruser(aruser)
    rd_seq.set_requests(1)
    rd_seq.set_get_rd_response(True)

    await self.start_seq_or_timeout(rd_seq, port_id)
    rd_rsps = rd_seq.get_rd_responses()
    if len(rd_rsps) != 1:
      raise AssertionError(
          f"stock AXI4 manager read returned {len(rd_rsps)} responses")
    rsp = rd_rsps[0]
    assert int(rsp.rid) == int(axi_id)
    if len(rsp.rdata) != beats:
      raise AssertionError(
          f"stock AXI4 manager read returned {len(rsp.rdata)} beats, expected {beats}")
    if return_info:
      return [
          {
              "id": int(rsp.rid),
              "data": int(rsp.rdata[i]),
              "resp": int(rsp.rresp),
              "last": 1 if i == beats - 1 else 0,
              "user": int(rsp.ruser[i]) if i < len(rsp.ruser) else 0,
          }
          for i in range(beats)
      ]
    return [
        (int(rsp.rdata[i]), int(rsp.rresp), 1 if i == beats - 1 else 0)
        for i in range(beats)
    ]

  async def start_seq_or_timeout(self, seq, port_id=0):
    sequencer = self.env.man_agent[port_id].sequencer
    timeout_ns = self.MAX_WAIT_CYCLES * 10
    try:
      await with_timeout(seq.start(sequencer), timeout_ns, "ns")
    except Exception as exc:
      bus = self.buses[port_id]
      fe = self.env.mc.fes[port_id]
      raise AssertionError(
          f"{seq.get_name()} timed out on port {port_id}: "
          f"bus aw={bus.get_or('awvalid')}/{bus.get_or('awready')} "
          f"w={bus.get_or('wvalid')}/{bus.get_or('wready')} "
          f"b={bus.get_or('bvalid')}/{bus.get_or('bready')} "
          f"ar={bus.get_or('arvalid')}/{bus.get_or('arready')} "
          f"r={bus.get_or('rvalid')}/{bus.get_or('rready')} "
          f"fe obs_aw={fe.observed_aw_count} obs_w={fe.observed_w_count} "
          f"obs_ar={fe.observed_ar_count}") from exc

  def _agent_cfg_t(self, port_id=0):
    if port_id < len(self.env.axi4_cfg_ts):
      return self.env.axi4_cfg_ts[port_id]
    return self.env.axi4_cfg_ts[0]

  def clear_manager_observations(self, port_id=0) -> None:
    self.env.clear_manager_observations(port_id)

  def aw_observations(self, port_id=0):
    return self.env.aw_observations[port_id]

  def aw_observation_times(self, port_id=0):
    return self.env.aw_observation_times[port_id]

  def b_observations(self, port_id=0):
    return self.env.b_observations[port_id]

  def b_observation_times(self, port_id=0):
    return self.env.b_observation_times[port_id]

  def ar_observations(self, port_id=0):
    return self.env.ar_observations[port_id]

  def ar_observation_times(self, port_id=0):
    return self.env.ar_observation_times[port_id]

  def rd_observations(self, port_id=0):
    return self.env.rd_observations[port_id]

  def rd_observation_times(self, port_id=0):
    return self.env.rd_observation_times[port_id]

  def issued_observations(self):
    return self.env.issued_observations

  def dram_rsp_observations(self):
    return self.env.dram_rsp_observations

  def get_max_addr(self) -> int:
    if self.DRAM_GEOM.ADDR_WIDTH_P >= 64:
      return (1 << 64) - 1
    return (1 << self.DRAM_GEOM.ADDR_WIDTH_P) - 1

  def get_full_width_axi_size(self) -> int:
    return (int(self.cfg_ts[0].WDATA_BYTES_P) - 1).bit_length()

  def encode_dram_addr(self, row=0, bg=0, bank=0, col=0, rank=0) -> int:
    dec = VipDramDecT()
    dec.row = int(row)
    dec.bg = int(bg)
    dec.bank = int(bank)
    dec.col = int(col)
    dec.rank = int(rank)
    return vip_dram_encode_addr(dec, self.DRAM_GEOM, self.env.mc.cfg.addr_map_policy)

  @staticmethod
  def lane_payload(addr: int, size_bytes: int, data: int, data_bytes: int = 64):
    bus_lane = int(addr) % int(data_bytes)
    payload = int(data) << (8 * bus_lane)
    strobe = ((1 << int(size_bytes)) - 1) << bus_lane
    return payload, strobe

  @staticmethod
  def byte_mask_from_strobe(strobe: int) -> int:
    mask = 0
    for byte_idx in range(64):
      if (int(strobe) >> byte_idx) & 1:
        mask |= 0xff << (8 * byte_idx)
    return mask

  @staticmethod
  def assert_ok(resp: int) -> None:
    assert resp == VIP_MC_AXI4_RESP_OKAY_C

  async def write_read_check(self, addr: int, data: int, axi_id=0):
    rsp = await self.write_axi(addr, data, axi_id=axi_id)
    self.assert_ok(rsp)
    got = await self.read_axi(addr, axi_id=axi_id)
    assert len(got) == 1
    assert got[0][1] == VIP_MC_AXI4_RESP_OKAY_C
    assert got[0][2] == 1
    assert got[0][0] == data

  def axi_width_pattern(self, seed: int) -> int:
    data = 0
    for byte_idx in range(self.cfg_ts[0].WDATA_BYTES_P):
      data |= ((int(seed) + byte_idx) & 0xff) << (8 * byte_idx)
    return data

  def make_read_item(self, name: str, addr: int, beats: int = 1, axi_id: int = 0,
                     size=None, burst=VIP_MC_AXI4_BURST_INCR_C, arqos=0,
                     get_response=True):
    item = vip_axi4_item(name, self._agent_cfg_t(0))
    item.set_access(Axi4Access.RD_REQUEST)
    item.set_rd_rsp(bool(get_response))
    item.arid = int(axi_id)
    item.araddr = int(addr)
    item.arlen = int(beats) - 1
    item.arsize = self.get_full_width_axi_size() if size is None else int(size)
    item.arburst = int(burst)
    item.arlock = 0
    item.arcache = 0
    item.arprot = 0
    item.arqos = int(arqos)
    item.arregion = 0
    item.aruser = 0
    return item

  def make_write_item(self, name: str, addr: int, data_beats, strb_beats=None,
                      axi_id: int = 0, size=None,
                      burst=VIP_MC_AXI4_BURST_INCR_C, awqos=0,
                      get_response=True):
    if not isinstance(data_beats, list):
      data_beats = [data_beats]
    if strb_beats is None:
      strb_beats = [(1 << self.cfg_ts[0].WDATA_BYTES_P) - 1] * len(data_beats)
    elif not isinstance(strb_beats, list):
      strb_beats = [strb_beats]

    item = vip_axi4_item(name, self._agent_cfg_t(0))
    item.set_access(Axi4Access.WR_REQUEST)
    item.set_wr_rsp(bool(get_response))
    item.awid = int(axi_id)
    item.awaddr = int(addr)
    item.awlen = len(data_beats) - 1
    item.awsize = self.get_full_width_axi_size() if size is None else int(size)
    item.awburst = int(burst)
    item.awlock = 0
    item.awcache = 0
    item.awprot = 0
    item.awqos = int(awqos)
    item.awregion = 0
    item.awuser = 0
    item.wdata = [int(data) for data in data_beats]
    item.wstrb = [int(strb) for strb in strb_beats]
    item.wuser = [0] * len(data_beats)
    return item

  async def write_axi_addrs_no_response(self, addrs, data_beats, strb_beats,
                                        axi_id=0, size=None, awqos=0,
                                        port_id=0):
    wr_seq = vip_axi4_write_seq(f"man_wr_multi_p{port_id}", self._agent_cfg_t(port_id))
    wr_seq.reset()
    wr_seq.set_awid(axi_id)
    wr_seq.set_axaddrs([int(addr) for addr in addrs])
    wr_seq.set_axlen(0)
    wr_seq.set_axsize(self.get_full_width_axi_size() if size is None else int(size))
    wr_seq.set_axburst(VIP_MC_AXI4_BURST_INCR_C)
    wr_seq.set_axqos(awqos)
    wr_seq.set_get_wr_response(False)
    wr_seq.set_wdata_type(Axi4DataType.CUSTOM)
    wr_seq.set_wstrb_type(Axi4StrbType.CUSTOM)
    wr_seq.set_wdata([int(x) for x in data_beats])
    wr_seq.set_wstrb([int(x) for x in strb_beats])
    await self.start_seq_or_timeout(wr_seq, port_id)


class mc_axi4_single_beat_base(mc_base_test):

  async def body(self):
    await self.write_read_check(0x2000, 0x8877665544332211, axi_id=3)


class mc_axi4_burst_base(mc_base_test):

  async def body(self):
    beats = [0x0102030405060708 + i for i in range(8)]
    rsp = await self.write_axi(0x2000, beats, axi_id=4)
    self.assert_ok(rsp)
    got = await self.read_axi(0x2000, beats=8, axi_id=4)
    assert [d for d, _, _ in got] == beats
    assert [r for _, r, _ in got] == [VIP_MC_AXI4_RESP_OKAY_C] * 8
    assert [last for _, _, last in got] == [0] * 7 + [1]


class mc_axi4_page_hit_streak_base(mc_base_test):

  BURST_BEATS = 64
  ADDR = 0x2000
  TIME_TOL_NS = 0.01

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = False

  async def body(self):
    data_beats = []
    strb_beats = []
    data_bytes = self.cfg_ts[0].WDATA_BYTES_P
    full_strb = (1 << data_bytes) - 1

    for beat_idx in range(self.BURST_BEATS):
      data = 0
      for byte_idx in range(data_bytes):
        data |= ((0x20 + beat_idx + byte_idx) & 0xff) << (8 * byte_idx)
      data_beats.append(data)
      strb_beats.append(full_strb)

    hit_before = self.env.mc.dram.get_page_hit_count()
    empty_before = self.env.mc.dram.get_page_empty_count()

    bresp = await self.write_axi(self.ADDR, data_beats, strb_beats)
    assert bresp == VIP_MC_AXI4_RESP_OKAY_C

    readback = await self.read_axi(self.ADDR, beats=self.BURST_BEATS)
    assert [resp for _, resp, _ in readback] == [
        VIP_MC_AXI4_RESP_OKAY_C] * self.BURST_BEATS
    assert [data for data, _, _ in readback] == data_beats

    assert self.env.scoreboard.get_timing_checked_count() >= 2
    assert self.env.scoreboard.get_timing_error_count() == 0
    assert self.env.mc.dram.get_page_empty_count() - empty_before == 1
    assert self.env.mc.dram.get_page_hit_count() - hit_before == 1

    last_cmd = self.env.mc.backend.last_completed_cmd
    assert last_cmd.op == VipDramOp.RD
    assert last_cmd.axi_beats == self.BURST_BEATS

    actual_span_ns = (
        last_cmd.last_beat_ready_time - last_cmd.first_beat_ready_time)
    expected_span_ns = (
        float(self.BURST_BEATS - 1) * self.env.mc.dram.cfg.timing.tCCD_L)
    assert (expected_span_ns - self.TIME_TOL_NS <= actual_span_ns <=
            expected_span_ns + self.TIME_TOL_NS)


class mc_axi4_narrow_unaligned_base(mc_base_test):

  async def body(self):
    addr = 0x3022
    payload, strobe = self.lane_payload(
        addr, 2, 0xabcd, self.cfg_ts[0].WDATA_BYTES_P)
    rsp = await self.write_axi(addr, payload, strobe, axi_id=5, size=2)
    self.assert_ok(rsp)
    got = await self.read_axi(addr, axi_id=5, size=2)
    mask = self.byte_mask_from_strobe(strobe)
    assert got[0][1] == VIP_MC_AXI4_RESP_OKAY_C
    assert got[0][2] == 1
    assert (got[0][0] & mask) == (payload & mask)


class mc_axi4_fixed_base(mc_base_test):

  async def body(self):
    addr = 0x4040
    data = []
    strb = []
    for i in range(4):
      payload, strobe = self.lane_payload(
          addr, 1, 0x30 + i, self.cfg_ts[0].WDATA_BYTES_P)
      data.append(payload)
      strb.append(strobe)
    rsp = await self.write_axi(
        addr, data, strb, axi_id=6, size=0, burst=VIP_MC_AXI4_BURST_FIXED_C)
    self.assert_ok(rsp)
    got = await self.read_axi(
        addr, beats=4, axi_id=6, size=0, burst=VIP_MC_AXI4_BURST_FIXED_C)
    expected = data[-1]
    assert [d for d, _, _ in got] == [expected] * 4
    assert [last for _, _, last in got] == [0, 0, 0, 1]


class mc_axi4_wrap_base(mc_base_test):

  async def body(self):
    beat_bytes = self.cfg_ts[0].WDATA_BYTES_P
    start_addr = 0x0200 + (2 * beat_bytes)
    beats = [0x1111111111111111 + i for i in range(4)]
    rsp = await self.write_axi(
        start_addr, beats, axi_id=7, burst=VIP_MC_AXI4_BURST_WRAP_C)
    self.assert_ok(rsp)
    got = await self.read_axi(
        start_addr, beats=4, axi_id=7, burst=VIP_MC_AXI4_BURST_WRAP_C)
    assert [d for d, _, _ in got] == beats


class mc_axi4_user_passthrough_base(mc_base_test):

  async def body(self):
    b = await self.write_axi(
        0x6000, 0xdeadbeef01020304, axi_id=8, awuser=0xa, wuser=0x5,
        return_info=True)
    assert b["resp"] == VIP_MC_AXI4_RESP_OKAY_C
    assert b["user"] == 0xa

    r = await self.read_axi(0x6000, axi_id=8, aruser=0xb, return_info=True)
    assert r[0]["resp"] == VIP_MC_AXI4_RESP_OKAY_C
    assert r[0]["user"] == 0xb
    assert r[0]["data"] == 0xdeadbeef01020304


class mc_axi4_exclusive_base(mc_base_test):

  async def body(self):
    addr = 0x03c0
    init_data = self.axi_width_pattern(0x10)
    success_data = self.axi_width_pattern(0x40)
    interfering_data = self.axi_width_pattern(0x70)
    failed_excl_data = self.axi_width_pattern(0xa0)

    b = await self.write_axi(addr, init_data, axi_id=9, return_info=True)
    assert b["resp"] == VIP_MC_AXI4_RESP_OKAY_C

    r = await self.read_axi(
        addr, axi_id=9, arlock=1, arcache=0, return_info=True)
    assert r[0]["resp"] == VIP_MC_AXI4_RESP_EXOKAY_C
    assert r[0]["data"] == init_data

    b = await self.write_axi(
        addr, success_data, axi_id=9, awlock=1, awcache=0, return_info=True)
    assert b["resp"] == VIP_MC_AXI4_RESP_EXOKAY_C

    r = await self.read_axi(addr, axi_id=9, return_info=True)
    assert r[0]["resp"] == VIP_MC_AXI4_RESP_OKAY_C
    assert r[0]["data"] == success_data

    r = await self.read_axi(
        addr, axi_id=9, arlock=1, arcache=0, return_info=True)
    assert r[0]["resp"] == VIP_MC_AXI4_RESP_EXOKAY_C
    assert r[0]["data"] == success_data

    b = await self.write_axi(
        addr, interfering_data, axi_id=9, return_info=True)
    assert b["resp"] == VIP_MC_AXI4_RESP_OKAY_C

    issued_before_failed_write = self.env.mc.backend.issued_req_count
    b_fail = await self.write_axi(
        addr, failed_excl_data, axi_id=9, awlock=1, awcache=0,
        return_info=True)
    assert b_fail["resp"] == VIP_MC_AXI4_RESP_OKAY_C
    assert self.env.mc.backend.issued_req_count == issued_before_failed_write

    r = await self.read_axi(addr, axi_id=9, return_info=True)
    assert r[0]["resp"] == VIP_MC_AXI4_RESP_OKAY_C
    assert r[0]["data"] == interfering_data

    assert self.env.mc.get_exokay_count(0) == 3
    assert self.env.mc.get_excl_fail_count(0) == 1


class mc_axi4_unsupported_reject_base(mc_base_test):

  USE_ENV_CFG = True

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = False

  async def body(self):
    data = [0] * 17
    strb = [0xff] * 17
    b = await self.write_axi(
        0x8000, data, strb, axi_id=10, size=3,
        burst=VIP_MC_AXI4_BURST_FIXED_C, return_info=True)
    assert b["resp"] == VIP_MC_AXI4_RESP_SLVERR_C
    assert self.env.mc.fes[0].get_local_reject_count() >= 1
    assert self.env.mc.fes[0].get_last_reject_op() == VipMcStatusOp.WR
    assert (self.env.mc.fes[0].get_last_reject_reason() ==
            VipMcStatusReject.UNSUPPORTED_AXI_SHAPE)


class mc_status_probe_base(mc_base_test):

  USE_ENV_CFG = True
  SCOREBOARD_TIMING_CHECK = False
  MAN_RD_OUTSTANDING_MAX = 2
  MAN_RREADY_DELAY_ENABLED = True
  MAN_RREADY_DELAY_PERIOD = 1
  MAN_RREADY_DELAY_TIME = 80

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = True
    cfg.tREFI_override = 2000.0
    cfg.rsp_buf_depth = 1
    cfg.max_inflight_to_device = 1

  async def body(self):
    bus = self.bus
    first_read = cocotb.start_soon(
        self.read_axi(0x9000, axi_id=1, return_info=True))

    saw_full = False
    saw_block = False
    saw_backpressured_r = False
    for _ in range(80):
      await bus.rising()
      saw_full = saw_full or bool(self.status_vif.rsp_buf_full)
      saw_block = saw_block or (
          self.status_vif.ar_block_reason[0] == VipMcStatusFeBlock.RSP_BUF_FULL)
      if bus.get_or("rvalid") == 1 and bus.get_or("rready") == 0:
        saw_backpressured_r = True
        break

    second_read = cocotb.start_soon(
        self.read_axi(0x9100, axi_id=2, return_info=True))
    for _ in range(40):
      await bus.rising()
      saw_full = saw_full or bool(self.status_vif.rsp_buf_full)
      saw_block = saw_block or (
          self.status_vif.ar_block_reason[0] == VipMcStatusFeBlock.RSP_BUF_FULL)

    await first_read
    await second_read

    for _ in range(260):
      await bus.rising()
      if self.status_vif.refresh_count > 0:
        break

    assert saw_backpressured_r
    assert saw_full
    assert saw_block
    assert self.status_vif.cmd_queue_peak_depth >= 0
    assert self.status_vif.refresh_count > 0
    assert self.env.mc.get_refresh_count() > 0


class mc_axi4_multi_port_base(mc_base_test):

  async def body(self):
    assert self.n_ports >= 2
    await self.write_axi(0xa000, 0x0102030405060708, axi_id=1, port_id=0)
    await self.write_axi(0xb000, 0x1112131415161718, axi_id=2, port_id=1)
    rd0 = await self.read_axi(0xa000, axi_id=1, port_id=0)
    rd1 = await self.read_axi(0xb000, axi_id=2, port_id=1)
    assert rd0[0][0] == 0x0102030405060708
    assert rd1[0][0] == 0x1112131415161718
    assert self.env.mc.get_port_completed_count(0) >= 2
    assert self.env.mc.get_port_completed_count(1) >= 2


class mc_axi4_agent_base(mc_base_test):

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = False

  async def body(self):
    assert self.n_ports >= 2
    addr0 = 0x0a00
    addr1 = 0x0b00
    data0 = 0x0102030405060708
    data1 = 0xa1a2a3a4a5a6a7a8
    issued_base = self.env.mc.backend.issued_req_count

    b0 = await self.write_axi(addr0, data0, port_id=0)
    assert b0 == VIP_MC_AXI4_RESP_OKAY_C
    b1 = await self.write_axi(addr1, data1, port_id=1)
    assert b1 == VIP_MC_AXI4_RESP_OKAY_C

    assert self.env.mc.backend.issued_req_count - issued_base >= 2
    assert self.env.mc.dram.backdoor_read(addr0) == data0
    assert self.env.mc.dram.backdoor_read(addr1) == data1


class mc_axi4_outstanding_limit_base(mc_base_test):

  SCOREBOARD_TIMING_CHECK = False
  MAN_RREADY_DELAY_ENABLED = True
  MAN_RREADY_DELAY_PERIOD = 1
  MAN_RREADY_DELAY_TIME = 8

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = False
    cfg.max_outstanding_rd = 1
    cfg.axi4.ar_outstanding_limit = 1
    cfg.rsp_buf_depth = 0

  async def body(self):
    bus = self.bus
    fe0 = self.env.mc.fes[0]
    self.clear_manager_observations()

    first = cocotb.start_soon(
        self.read_axi(0x0300, axi_id=1, return_info=True))
    second = None
    blocked_rsp_seen = False

    for _ in range(512):
      await bus.rising()
      if (len(self.ar_observations()) == 1 and
          bus.get_or("rvalid") == 1 and bus.get_or("rready") == 0):
        blocked_rsp_seen = True
        break

    assert len(self.ar_observations()) == 1
    assert blocked_rsp_seen

    second = cocotb.start_soon(
        self.read_axi(0x0400, axi_id=2, return_info=True))

    for _ in range(512):
      await bus.rising()
      if len(self.rd_observations()) >= 1:
        break
    assert len(self.rd_observations()) >= 1

    for _ in range(512):
      await bus.rising()
      if len(self.ar_observations()) >= 2:
        break
    assert len(self.ar_observations()) == 2

    await first
    await second

    assert len(self.rd_observations()) == 2
    assert self.ar_observation_times()[1] >= self.rd_observation_times()[0]
    assert [int(r.rresp) for r in self.rd_observations()] == [
        VIP_MC_AXI4_RESP_OKAY_C, VIP_MC_AXI4_RESP_OKAY_C]
    assert fe0.observed_ar_count == 2
    assert self.env.mc.get_rsp_buf_full_cycles(0) == 0


class mc_axi4_aw_backpressure_base(mc_base_test):

  SCOREBOARD_TIMING_CHECK = False
  MAN_WR_OUTSTANDING_MAX = 2
  MAN_BREADY_DELAY_ENABLED = True
  MAN_BREADY_DELAY_PERIOD = 12
  MAN_BREADY_DELAY_TIME = 8

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = False
    cfg.max_outstanding_wr = 1
    cfg.axi4.aw_outstanding_limit = 1
    cfg.rsp_buf_depth = 0

  async def body(self):
    fe0 = self.env.mc.fes[0]
    self.clear_manager_observations()
    await self.write_axi_addrs_no_response(
        [0x0500, 0x0600],
        [0x55, 0x66],
        [0xff, 0xff],
        axi_id=1,
        awqos=2)

    for _ in range(512):
      await self.bus.rising()
      if len(self.aw_observations()) == 2 and len(self.b_observations()) == 2:
        break

    assert len(self.aw_observations()) == 2
    assert len(self.b_observations()) == 2
    assert self.aw_observation_times()[1] >= self.b_observation_times()[0]
    assert [int(b.bresp) for b in self.b_observations()] == [
        VIP_MC_AXI4_RESP_OKAY_C, VIP_MC_AXI4_RESP_OKAY_C]
    assert fe0.observed_aw_count == 2
    assert self.env.mc.get_rsp_buf_full_cycles(0) == 0


class mc_axi4_wready_backpressure_base(mc_base_test):

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = False
    cfg.axi4.w_data_buf_depth = 1

  async def body(self):
    fe0 = self.env.mc.fes[0]
    stall_base = fe0.get_wready_stall_cycles()
    beats = [0x1111222233334444, 0x5555666677778888]

    self.assert_ok(await self.write_axi(0x0900, beats, [0xff, 0xff], axi_id=1))
    assert fe0.get_wready_stall_cycles() > stall_base

    got = await self.read_axi(0x0900, beats=2, axi_id=2)
    assert [int(data) for data, _, _ in got] == beats
    assert [int(resp) for _, resp, _ in got] == [
        VIP_MC_AXI4_RESP_OKAY_C, VIP_MC_AXI4_RESP_OKAY_C]
    assert fe0.observed_w_count == 2


class mc_axi4_bresp_backpressure_base(mc_base_test):

  SCOREBOARD_TIMING_CHECK = False
  MAN_WR_OUTSTANDING_MAX = 2
  MAN_BREADY_DELAY_ENABLED = True
  MAN_BREADY_DELAY_PERIOD = 1
  MAN_BREADY_DELAY_TIME = 8

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = False
    cfg.rsp_buf_depth = 1

  async def body(self):
    bus = self.bus
    fe0 = self.env.mc.fes[0]
    self.clear_manager_observations()

    first = cocotb.start_soon(self.write_axi_addrs_no_response(
        [0x0500],
        [0x55],
        [0xff],
        axi_id=1,
        awqos=2))

    blocked_b_seen = False
    for _ in range(512):
      await bus.rising()
      if bus.get_or("bvalid") == 1 and bus.get_or("bready") == 0:
        blocked_b_seen = True
        break
    await first
    assert blocked_b_seen

    await self.write_axi_addrs_no_response(
        [0x0600],
        [0x66],
        [0xff],
        axi_id=1,
        awqos=2)

    for _ in range(512):
      await bus.rising()
      if len(self.aw_observations()) == 2 and len(self.b_observations()) == 2:
        break

    assert len(self.aw_observations()) == 2
    assert len(self.b_observations()) == 2
    assert self.aw_observation_times()[1] >= self.b_observation_times()[0]
    assert [int(b.bresp) for b in self.b_observations()] == [
        VIP_MC_AXI4_RESP_OKAY_C, VIP_MC_AXI4_RESP_OKAY_C]
    assert fe0.observed_aw_count == 2
    assert self.env.mc.get_rsp_buf_full_cycles(0) > 0


class mc_axi4_rsp_backpressure_base(mc_base_test):

  SCOREBOARD_TIMING_CHECK = False
  MAN_RREADY_DELAY_ENABLED = True
  MAN_RREADY_DELAY_PERIOD = 1
  MAN_RREADY_DELAY_TIME = 8

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = False
    cfg.rsp_buf_depth = 1

  async def body(self):
    bus = self.bus
    fe0 = self.env.mc.fes[0]
    self.clear_manager_observations()

    first = cocotb.start_soon(
        self.read_axi(0x0300, axi_id=2, return_info=True))
    blocked_rsp_seen = False
    for _ in range(512):
      await bus.rising()
      if (len(self.ar_observations()) == 1 and
          bus.get_or("rvalid") == 1 and bus.get_or("rready") == 0):
        blocked_rsp_seen = True
        break

    assert len(self.ar_observations()) == 1
    assert blocked_rsp_seen

    second = cocotb.start_soon(
        self.read_axi(0x0400, axi_id=4, return_info=True))
    for _ in range(512):
      await bus.rising()
      if len(self.rd_observations()) >= 1:
        break
    assert len(self.rd_observations()) >= 1

    for _ in range(512):
      await bus.rising()
      if len(self.ar_observations()) >= 2:
        break

    await first
    await second

    assert len(self.ar_observations()) == 2
    assert len(self.rd_observations()) == 2
    assert self.ar_observation_times()[1] >= self.rd_observation_times()[0]
    assert [int(r.rresp) for r in self.rd_observations()] == [
        VIP_MC_AXI4_RESP_OKAY_C, VIP_MC_AXI4_RESP_OKAY_C]
    assert fe0.observed_ar_count == 2
    assert self.env.mc.get_rsp_buf_full_cycles(0) > 0


class mc_axi4_write_coalesce_base(mc_base_test):

  SCOREBOARD_ENABLED = False
  SCOREBOARD_TIMING_CHECK = False
  MAN_WR_OUTSTANDING_MAX = 4
  MAN_RD_OUTSTANDING_MAX = 4

  DUMMY_BEATS = 16
  N_HOLD = 4
  DUMMY_ID = 3
  WR_ID = 2

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = False
    cfg.honor_beat_timing = False
    cfg.max_inflight_to_device = 1
    cfg.write_coalescing_enable = True

  async def body(self):
    line_addr = self.encode_dram_addr(row=0, bg=1, bank=0)
    data_bytes = self.cfg_ts[0].WDATA_BYTES_P
    half = data_bytes // 2
    strb_a = (1 << data_bytes) - 1
    strb_b = (1 << half) - 1
    data_a = self.axi_width_pattern(0xa0)
    data_b = 0
    expected = 0
    for byte_idx in range(data_bytes):
      if byte_idx < half:
        val = (0x50 + byte_idx) & 0xff
        data_b |= val << (8 * byte_idx)
      else:
        val = (0xa0 + byte_idx) & 0xff
      expected |= val << (8 * byte_idx)

    self.env.mc.dram.backdoor_write(line_addr, 0)
    self.clear_manager_observations()

    seq = vip_axi4_pipelined_seq("coalesce_pl_seq", self._agent_cfg_t(0))
    for idx in range(self.N_HOLD):
      seq.add_item(self.make_read_item(
          f"hold_rd_{idx}",
          self.encode_dram_addr(row=idx + 1, bg=3, bank=0),
          beats=self.DUMMY_BEATS,
          axi_id=self.DUMMY_ID + idx,
          get_response=False))
    seq.add_item(self.make_write_item(
        "coalesce_wr_a", line_addr, data_a, strb_a,
        axi_id=self.WR_ID, get_response=True))
    seq.add_item(self.make_write_item(
        "coalesce_wr_b", line_addr, data_b, strb_b,
        axi_id=self.WR_ID, get_response=True))
    seq.set_pipelined_send(True)
    seq.set_collect_wr_responses(True)
    await self.start_seq_or_timeout(seq)

    for _ in range(4096):
      if (self.env.mc.backend.get_inflight_to_device() == 0 and
          self.env.mc.backend.get_cmd_queue_depth() == 0):
        break
      await self.bus.rising()
    for _ in range(self.N_HOLD * self.DUMMY_BEATS + 64):
      await self.bus.rising()

    wr_issued = [
        entry for entry in self.issued_observations()
        if getattr(entry, "op", None) == VipDramOp.WR]
    wr_issue_detail = [
        (entry.port_id, int(entry.axi4_id), int(entry.addr), entry.admit_order)
        for entry in wr_issued]
    assert len(seq.wr_responses) == 2
    assert [int(rsp.bresp) for rsp in seq.wr_responses] == [
        VIP_MC_AXI4_RESP_OKAY_C, VIP_MC_AXI4_RESP_OKAY_C]
    assert len(wr_issued) == 1, wr_issue_detail
    assert self.env.mc.backend.get_coalesced_write_count() == 1
    got = self.env.mc.dram.backdoor_read(line_addr)
    mask = (1 << (8 * data_bytes)) - 1
    assert (got & mask) == expected


class mc_axi4_read_pipeline_base(mc_base_test):

  N_READS = 6
  MAN_RD_OUTSTANDING_MAX = N_READS
  SCOREBOARD_TIMING_CHECK = False

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = False

  def read_addr(self, idx: int) -> int:
    return self.encode_dram_addr(row=idx, bg=idx % 4, bank=0)

  async def body(self):
    fe0 = self.env.mc.fes[0]
    for idx in range(self.N_READS):
      self.env.mc.dram.backdoor_write(
          self.read_addr(idx), self.axi_width_pattern(0x10 * idx))

    peak_inflight = 0
    sampling = True

    async def sample_inflight():
      nonlocal peak_inflight
      while sampling:
        await self.bus.rising()
        peak_inflight = max(peak_inflight, fe0.inflight_rd_count)

    sampler = cocotb.start_soon(sample_inflight())
    seq = vip_axi4_pipelined_seq("read_pl_seq", self._agent_cfg_t(0))
    for idx in range(self.N_READS):
      seq.add_item(self.make_read_item(
          f"pl_rd_{idx}", self.read_addr(idx), axi_id=idx + 1))
    seq.set_pipelined_send(True)
    seq.set_collect_rd_responses(True)
    await self.start_seq_or_timeout(seq)
    sampling = False
    await self.bus.rising()
    if not sampler.done():
      sampler.kill()

    assert len(seq.rd_responses) == self.N_READS
    for idx, rsp in enumerate(seq.rd_responses):
      assert int(rsp.rresp) == VIP_MC_AXI4_RESP_OKAY_C
      assert len(rsp.rdata) == 1
      assert int(rsp.rdata[0]) == self.axi_width_pattern(0x10 * idx)
    assert peak_inflight >= 2


class mc_axi4_read_multi_id_base(mc_base_test):

  BURST_BEATS = 2
  MAN_RD_OUTSTANDING_MAX = 2

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = False

  async def body(self):
    addr_a = 0x0500
    addr_b = 0x0600
    data_a = [self.axi_width_pattern(0x20 + 0x10 * beat)
              for beat in range(self.BURST_BEATS)]
    data_b = [self.axi_width_pattern(0x80 + 0x10 * beat)
              for beat in range(self.BURST_BEATS)]

    self.assert_ok(await self.write_axi(addr_a, data_a))
    self.assert_ok(await self.write_axi(addr_b, data_b))

    self.clear_manager_observations()
    seq = vip_axi4_pipelined_seq("read_multi_id_seq", self._agent_cfg_t(0))
    seq.add_item(self.make_read_item(
        "rd_a", addr_a, beats=self.BURST_BEATS, axi_id=1))
    seq.add_item(self.make_read_item(
        "rd_b", addr_b, beats=self.BURST_BEATS, axi_id=2))
    seq.set_pipelined_send(True)
    seq.set_collect_rd_responses(True)
    await self.start_seq_or_timeout(seq)

    assert len(seq.rd_responses) == 2
    by_id = {int(rsp.rid): rsp for rsp in seq.rd_responses}
    assert set(by_id) == {1, 2}
    assert int(by_id[1].rresp) == VIP_MC_AXI4_RESP_OKAY_C
    assert int(by_id[2].rresp) == VIP_MC_AXI4_RESP_OKAY_C
    assert [int(x) for x in by_id[1].rdata] == data_a
    assert [int(x) for x in by_id[2].rdata] == data_b
    assert len(self.ar_observations()) == 2
    assert len(self.rd_observations()) == 2
    assert self.env.mc.fes[0].observed_ar_count >= 2


class mc_axi4_ooo_inter_id_base(mc_base_test):

  MAN_RD_OUTSTANDING_MAX = 3
  SCOREBOARD_TIMING_CHECK = False

  DUMMY_ID = 3
  MISS_ID = 1
  HIT_ID = 2
  DUMMY_BEATS = 16

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = False
    cfg.honor_beat_timing = False
    cfg.max_inflight_to_device = 1

  async def body(self):
    self.env.mc.cfg.fr_fcfs_enable = True

    dummy_addr = self.encode_dram_addr(row=0, bg=3, bank=0)
    miss_seed_addr = self.encode_dram_addr(row=1, bg=0, bank=0)
    miss_open_addr = self.encode_dram_addr(row=0, bg=0, bank=0)
    hit_addr = self.encode_dram_addr(row=0, bg=1, bank=0)

    miss_seed_data = self.axi_width_pattern(0x31)
    miss_open_data = self.axi_width_pattern(0x61)
    hit_seed_data = self.axi_width_pattern(0x91)

    self.env.mc.dram.backdoor_write(miss_seed_addr, miss_seed_data)
    self.env.mc.dram.backdoor_write(miss_open_addr, miss_open_data)
    self.env.mc.dram.backdoor_write(hit_addr, hit_seed_data)

    got = await self.read_axi(miss_open_addr, axi_id=4)
    assert got[0][1] == VIP_MC_AXI4_RESP_OKAY_C
    assert got[0][0] == miss_open_data
    got = await self.read_axi(hit_addr, axi_id=5)
    assert got[0][1] == VIP_MC_AXI4_RESP_OKAY_C
    assert got[0][0] == hit_seed_data

    self.clear_manager_observations()
    seq = vip_axi4_pipelined_seq("ooo_inter_id_seq", self._agent_cfg_t(0))
    seq.add_item(self.make_read_item(
        "dummy_rd", dummy_addr, beats=self.DUMMY_BEATS, axi_id=self.DUMMY_ID,
        arqos=4))
    seq.add_item(self.make_read_item(
        "miss_rd", miss_seed_addr, axi_id=self.MISS_ID, arqos=4))
    seq.add_item(self.make_read_item(
        "hit_rd", hit_addr, axi_id=self.HIT_ID, arqos=4))
    seq.set_pipelined_send(True)
    seq.set_collect_rd_responses(True)
    await self.start_seq_or_timeout(seq)

    issued_reads = [
        entry for entry in self.issued_observations()
        if getattr(entry, "op", None) == VipDramOp.RD]
    grant_ids = [int(entry.axi4_id) for entry in issued_reads]
    assert len(grant_ids) >= 3
    assert grant_ids[:3] == [self.DUMMY_ID, self.HIT_ID, self.MISS_ID]

    rd_ids = [int(item.rid) for item in self.rd_observations()]
    assert self.HIT_ID in rd_ids
    assert self.MISS_ID in rd_ids
    assert rd_ids.index(self.HIT_ID) < rd_ids.index(self.MISS_ID)

    tag_by_id = {int(entry.axi4_id): int(entry.tag) for entry in issued_reads}
    rsp_by_tag = {
        int(rsp.tag): rsp for rsp in self.dram_rsp_observations()
        if getattr(rsp, "op", None) == VipDramOp.RD
    }
    miss_rsp = rsp_by_tag.get(tag_by_id[self.MISS_ID])
    hit_rsp = rsp_by_tag.get(tag_by_id[self.HIT_ID])
    assert miss_rsp is not None
    assert hit_rsp is not None
    assert miss_rsp.was_page_miss and not miss_rsp.was_page_hit
    assert hit_rsp.was_page_hit and not hit_rsp.was_page_miss
    assert hit_rsp.last_beat_ready_time < miss_rsp.last_beat_ready_time
    assert self.env.mc.get_observed_reorder_count() >= 1


class mc_axi4_fr_fcfs_mixed_rd_wr_base(mc_base_test):

  MAN_RD_OUTSTANDING_MAX = 3
  MAN_WR_OUTSTANDING_MAX = 2
  SCOREBOARD_TIMING_CHECK = False

  OBS_TIMEOUT_CYCLES = 1024
  DUMMY_BEATS = 32
  DUMMY_ID = 3
  MISS_RD_ID = 1
  HIT_WR_ID = 2

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = False
    cfg.honor_beat_timing = False
    cfg.max_inflight_to_device = 1

  async def body(self):
    self.env.mc.cfg.fr_fcfs_enable = True

    dummy_addr = self.encode_dram_addr(row=0, bg=3, bank=0)
    miss_seed_addr = self.encode_dram_addr(row=1, bg=0, bank=0)
    miss_open_addr = self.encode_dram_addr(row=0, bg=0, bank=0)
    hit_wr_addr = self.encode_dram_addr(row=0, bg=1, bank=0)

    miss_seed_data = self.axi_width_pattern(0x31)
    miss_open_data = self.axi_width_pattern(0x61)
    hit_seed_data = self.axi_width_pattern(0x91)
    hit_wr_data = self.axi_width_pattern(0xd0)
    full_strb = (1 << self.cfg_ts[0].WDATA_BYTES_P) - 1

    self.env.mc.dram.backdoor_write(miss_seed_addr, miss_seed_data)
    self.env.mc.dram.backdoor_write(miss_open_addr, miss_open_data)
    self.env.mc.dram.backdoor_write(hit_wr_addr, hit_seed_data)

    got = await self.read_axi(miss_open_addr, axi_id=4)
    assert got[0][1] == VIP_MC_AXI4_RESP_OKAY_C
    assert got[0][0] == miss_open_data
    got = await self.read_axi(hit_wr_addr, axi_id=5)
    assert got[0][1] == VIP_MC_AXI4_RESP_OKAY_C
    assert got[0][0] == hit_seed_data

    self.clear_manager_observations()
    seq = vip_axi4_pipelined_seq("mixed_rd_wr_seq", self._agent_cfg_t(0))
    seq.add_item(self.make_read_item(
        "dummy_rd", dummy_addr, beats=self.DUMMY_BEATS,
        axi_id=self.DUMMY_ID, arqos=4, get_response=False))
    seq.add_item(self.make_read_item(
        "miss_rd", miss_seed_addr, axi_id=self.MISS_RD_ID,
        arqos=4, get_response=False))
    seq.add_item(self.make_write_item(
        "hit_wr", hit_wr_addr, hit_wr_data, full_strb,
        axi_id=self.HIT_WR_ID, awqos=4, get_response=False))
    seq.set_pipelined_send(True)
    await self.start_seq_or_timeout(seq)

    for _ in range(self.OBS_TIMEOUT_CYCLES):
      issued = [
          entry for entry in self.issued_observations()
          if getattr(entry, "op", None) in (VipDramOp.RD, VipDramOp.WR)]
      if (len(self.b_observations()) >= 1 and
          len(self.rd_observations()) >= 2 and
          len(issued) >= 3):
        break
      await self.bus.rising()

    issued = [
        entry for entry in self.issued_observations()
        if getattr(entry, "op", None) in (VipDramOp.RD, VipDramOp.WR)]
    grant_pairs = [(entry.op, int(entry.axi4_id)) for entry in issued[:3]]
    assert len(grant_pairs) >= 3
    assert grant_pairs == [
        (VipDramOp.RD, self.DUMMY_ID),
        (VipDramOp.WR, self.HIT_WR_ID),
        (VipDramOp.RD, self.MISS_RD_ID),
    ]

    assert len(self.b_observations()) == 1
    assert int(self.b_observations()[0].bid) == self.HIT_WR_ID
    assert int(self.b_observations()[0].bresp) == VIP_MC_AXI4_RESP_OKAY_C

    rd_ids = [int(item.rid) for item in self.rd_observations()]
    assert self.DUMMY_ID in rd_ids
    assert self.MISS_RD_ID in rd_ids
    miss_obs_idx = rd_ids.index(self.MISS_RD_ID)
    assert self.b_observation_times()[0] < self.rd_observation_times()[miss_obs_idx]

    tag_by_id = {int(entry.axi4_id): int(entry.tag) for entry in issued}
    rsp_by_tag = {int(rsp.tag): rsp for rsp in self.dram_rsp_observations()}
    miss_rsp = rsp_by_tag.get(tag_by_id[self.MISS_RD_ID])
    hit_wr_rsp = rsp_by_tag.get(tag_by_id[self.HIT_WR_ID])
    assert miss_rsp is not None
    assert hit_wr_rsp is not None
    assert hit_wr_rsp.op == VipDramOp.WR
    assert hit_wr_rsp.was_page_hit
    assert not hit_wr_rsp.was_page_miss
    assert not hit_wr_rsp.was_page_empty
    assert miss_rsp.op == VipDramOp.RD
    assert miss_rsp.was_page_miss
    assert not miss_rsp.was_page_hit
    assert not miss_rsp.was_page_empty
    assert hit_wr_rsp.last_beat_ready_time < miss_rsp.last_beat_ready_time
    assert self.env.mc.dram.backdoor_read(hit_wr_addr) == hit_wr_data


class mc_fr_fcfs_starvation_cap_base(mc_base_test):

  SCOREBOARD_TIMING_CHECK = False

  OBS_TIMEOUT_CYCLES = 2048
  DUMMY_BEATS = 32
  CAP = 2
  N_HITS = 5
  DUMMY_ID = 3
  MISS_ID = 1
  HIT_ID_BASE = 4

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = False
    cfg.honor_beat_timing = False
    cfg.max_inflight_to_device = 1

  def build_phase(self):
    self.MAN_RD_OUTSTANDING_MAX = 2 + self.N_HITS
    super().build_phase()

  async def body(self):
    self.env.mc.cfg.fr_fcfs_enable = True
    self.env.mc.cfg.fr_fcfs_starvation_cap = self.CAP

    dummy_addr = self.encode_dram_addr(row=0, bg=3, bank=0)
    miss_seed_addr = self.encode_dram_addr(row=1, bg=0, bank=0)
    miss_open_addr = self.encode_dram_addr(row=0, bg=0, bank=0)
    hit_open_addr = self.encode_dram_addr(row=0, bg=1, bank=0, col=0)
    hit_addrs = [
        self.encode_dram_addr(row=0, bg=1, bank=0, col=i)
        for i in range(self.N_HITS)]

    await self.read_axi(miss_open_addr, axi_id=4)
    await self.read_axi(hit_open_addr, axi_id=5)

    self.clear_manager_observations()
    seq = vip_axi4_pipelined_seq("starvation_cap_seq", self._agent_cfg_t(0))
    seq.add_item(self.make_read_item(
        "dummy_rd", dummy_addr, beats=self.DUMMY_BEATS,
        axi_id=self.DUMMY_ID, arqos=4, get_response=False))
    seq.add_item(self.make_read_item(
        "miss_rd", miss_seed_addr, axi_id=self.MISS_ID,
        arqos=4, get_response=False))
    for idx, hit_addr in enumerate(hit_addrs):
      seq.add_item(self.make_read_item(
          f"hit_rd_{idx}", hit_addr, axi_id=self.HIT_ID_BASE + idx,
          arqos=4, get_response=False))
    seq.set_pipelined_send(True)
    await self.start_seq_or_timeout(seq)

    expected_grants = 2 + self.N_HITS
    for _ in range(self.OBS_TIMEOUT_CYCLES):
      grant_ids = [
          int(entry.axi4_id) for entry in self.issued_observations()
          if getattr(entry, "op", None) == VipDramOp.RD]
      if len(grant_ids) >= expected_grants:
        break
      await self.bus.rising()

    grant_ids = [
        int(entry.axi4_id) for entry in self.issued_observations()
        if getattr(entry, "op", None) == VipDramOp.RD]
    assert len(grant_ids) >= expected_grants
    assert grant_ids[0] == self.DUMMY_ID

    miss_pos = grant_ids.index(self.MISS_ID)
    hits_before_miss = sum(
        1 for axi_id in grant_ids[1:miss_pos]
        if self.HIT_ID_BASE <= axi_id < self.HIT_ID_BASE + self.N_HITS)
    assert hits_before_miss == self.CAP
    assert self.env.mc.get_fr_fcfs_forced_count() >= 1

    for _ in range(self.OBS_TIMEOUT_CYCLES):
      if len(self.rd_observations()) >= expected_grants:
        break
      await self.bus.rising()
    assert len(self.rd_observations()) >= expected_grants


class mc_qos_scheduling_base(mc_base_test):

  SCOREBOARD_TIMING_CHECK = False
  MAN_RD_OUTSTANDING_MAX = 12

  OBS_TIMEOUT_CYCLES = 1024
  N_READS = 12
  HI_ARRIVAL = 8

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = False
    cfg.max_inflight_to_device = 1

  async def body(self):
    self.clear_manager_observations()
    seq = vip_axi4_pipelined_seq("qos_sched_seq", self._agent_cfg_t(0))
    for idx in range(self.N_READS):
      qos = 0xf if idx == self.HI_ARRIVAL else 0
      seq.add_item(self.make_read_item(
          f"qos_rd_{idx}", 0x0400 + (idx * 0x10000),
          axi_id=idx + 1, arqos=qos, get_response=False))
    seq.set_pipelined_send(True)
    await self.start_seq_or_timeout(seq)

    for _ in range(self.OBS_TIMEOUT_CYCLES):
      grants = [
          entry for entry in self.issued_observations()
          if getattr(entry, "op", None) == VipDramOp.RD]
      if len(grants) >= self.N_READS:
        break
      await self.bus.rising()
    for _ in range(self.OBS_TIMEOUT_CYCLES):
      if len(self.rd_observations()) >= self.N_READS:
        break
      await self.bus.rising()

    grants = [
        entry for entry in self.issued_observations()
        if getattr(entry, "op", None) == VipDramOp.RD]
    assert len(grants) == self.N_READS
    assert self.env.mc.get_cmd_queue_peak_depth() >= 2

    grant_ids = [int(entry.axi4_id) for entry in grants]
    grant_classes = [int(entry.qos_class) for entry in grants]
    hi_id = self.HI_ARRIVAL + 1
    hi_grant_idx = grant_ids.index(hi_id)
    assert hi_grant_idx < self.HI_ARRIVAL

    preempted_older_low = sum(
        1 for idx, (axi_id, qos_class) in enumerate(zip(grant_ids, grant_classes))
        if idx > hi_grant_idx and qos_class == 0 and (axi_id - 1) < self.HI_ARRIVAL)
    assert preempted_older_low > 0

    prev_low_arrival = -1
    for axi_id, qos_class in zip(grant_ids, grant_classes):
      if qos_class != 0:
        continue
      arrival = axi_id - 1
      assert arrival > prev_low_arrival
      prev_low_arrival = arrival


class mc_qos_aging_base(mc_base_test):

  SCOREBOARD_TIMING_CHECK = False
  N_HIGH_BEFORE = 4
  N_HIGH_AFTER = 8
  LOW_ID = 1
  OBS_TIMEOUT_CYCLES = 2048

  def build_phase(self):
    self.MAN_RD_OUTSTANDING_MAX = (
        self.N_HIGH_BEFORE + self.N_HIGH_AFTER + 1)
    super().build_phase()

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = False
    cfg.max_inflight_to_device = 1

  async def body(self):
    total = self.N_HIGH_BEFORE + self.N_HIGH_AFTER + 1
    self.clear_manager_observations()

    seq = vip_axi4_pipelined_seq("qos_aging_seq", self._agent_cfg_t(0))
    next_id = 2
    slot = 0
    for _ in range(self.N_HIGH_BEFORE):
      seq.add_item(self.make_read_item(
          f"aging_hi_before_{slot}", 0x0400 + (slot * 0x10000),
          axi_id=next_id, arqos=0xf, get_response=False))
      next_id += 1
      slot += 1

    seq.add_item(self.make_read_item(
        "aging_low", 0x0400 + (slot * 0x10000),
        axi_id=self.LOW_ID, arqos=0, get_response=False))
    slot += 1

    for _ in range(self.N_HIGH_AFTER):
      seq.add_item(self.make_read_item(
          f"aging_hi_after_{slot}", 0x0400 + (slot * 0x10000),
          axi_id=next_id, arqos=0xf, get_response=False))
      next_id += 1
      slot += 1

    seq.set_pipelined_send(True)
    await self.start_seq_or_timeout(seq)

    for _ in range(self.OBS_TIMEOUT_CYCLES):
      grants = [
          entry for entry in self.issued_observations()
          if getattr(entry, "op", None) == VipDramOp.RD]
      if len(grants) >= total:
        break
      await self.bus.rising()
    for _ in range(self.OBS_TIMEOUT_CYCLES):
      if len(self.rd_observations()) >= total:
        break
      await self.bus.rising()

    grants_with_time = [
        (entry, grant_time)
        for entry, grant_time in zip(
            self.issued_observations(), self.env.issued_observation_times)
        if getattr(entry, "op", None) == VipDramOp.RD]
    assert len(grants_with_time) == total
    assert self.env.mc.get_cmd_queue_peak_depth() >= 2

    grant_ids = [int(entry.axi4_id) for entry, _ in grants_with_time]
    grant_classes = [int(entry.qos_class) for entry, _ in grants_with_time]
    low_idx = grant_ids.index(self.LOW_ID)

    highs_before_low = sum(
        1 for idx, qos_class in enumerate(grant_classes)
        if qos_class == 3 and idx < low_idx)
    highs_after_low = sum(
        1 for idx, qos_class in enumerate(grant_classes)
        if qos_class == 3 and idx > low_idx)
    assert highs_before_low > 0
    assert highs_after_low > 0

    low_entry, low_grant_time = grants_with_time[low_idx]
    grant_delay = float(low_grant_time) - float(low_entry.admit_time)
    aging_bound = (
        (float(self.env.mc.cfg.qos_class_count) - 1.0) *
        float(self.env.mc.cfg.qos_aging_ns) + 100.0)
    assert grant_delay <= aging_bound


class mc_rd_wr_grouping_base(mc_base_test):

  SCOREBOARD_ENABLED = False
  SCOREBOARD_TIMING_CHECK = False
  MAN_RD_OUTSTANDING_MAX = 16
  MAN_WR_OUTSTANDING_MAX = 16

  OBS_TIMEOUT_CYCLES = 8192
  N_RD = 4
  N_WR = 2
  DUMMY_BEATS = 32
  HOLD_ID = 3
  RD_ID_BASE = 4
  WR_ID_BASE = 10

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = False
    cfg.honor_beat_timing = False
    cfg.max_inflight_to_device = 1
    cfg.axi4.w_data_buf_depth = 32

  async def body(self):
    self.env.mc.cfg.fr_fcfs_enable = True
    self.env.mc.cfg.rd_wr_grouping_enable = True

    wr_row_addr = self.encode_dram_addr(row=0, bg=1, bank=0)

    got = await self.read_axi(wr_row_addr, axi_id=2)
    assert got[0][1] == VIP_MC_AXI4_RESP_OKAY_C

    self.clear_manager_observations()
    full_strb = (1 << self.cfg_ts[0].WDATA_BYTES_P) - 1

    seq = vip_axi4_pipelined_seq("grouping_pl_seq", self._agent_cfg_t(0))
    seq.add_item(self.make_read_item(
        "hold_rd",
        self.encode_dram_addr(row=0, bg=3, bank=0),
        beats=self.DUMMY_BEATS,
        axi_id=self.HOLD_ID,
        get_response=False))
    for idx in range(self.N_WR):
      seq.add_item(self.make_write_item(
          f"group_wr_{idx}",
          self.encode_dram_addr(row=0, bg=1, bank=0, col=idx),
          self.axi_width_pattern(0x80 + idx),
          full_strb,
          axi_id=self.WR_ID_BASE + idx,
          awqos=4,
          get_response=True))
    for idx in range(self.N_RD):
      seq.add_item(self.make_read_item(
          f"group_rd_{idx}",
          self.encode_dram_addr(row=0, bg=2, bank=idx),
          axi_id=self.RD_ID_BASE + idx,
          arqos=4,
          get_response=False))
    seq.set_pipelined_send(True)
    seq.set_collect_wr_responses(True)
    await self.start_seq_or_timeout(seq)

    expected_grants = self.N_RD + self.N_WR + 1
    for _ in range(self.OBS_TIMEOUT_CYCLES):
      grants = [
          entry for entry in self.issued_observations()
          if getattr(entry, "op", None) in (VipDramOp.RD, VipDramOp.WR)]
      if (len(grants) >= expected_grants and
          len(self.b_observations()) >= self.N_WR):
        break
      await self.bus.rising()

    for _ in range(self.DUMMY_BEATS + 64):
      await self.bus.rising()

    assert len(seq.wr_responses) == self.N_WR
    assert [int(rsp.bresp) for rsp in seq.wr_responses] == [
        VIP_MC_AXI4_RESP_OKAY_C] * self.N_WR

    grants = [
        entry for entry in self.issued_observations()
        if getattr(entry, "op", None) in (VipDramOp.RD, VipDramOp.WR)]
    assert len(grants) == expected_grants

    seen_write = False
    n_rd = 0
    n_wr = 0
    for entry in grants:
      if entry.op == VipDramOp.RD:
        n_rd += 1
        assert not seen_write
      else:
        n_wr += 1
        seen_write = True

    assert n_rd == self.N_RD + 1
    assert n_wr == self.N_WR
    assert self.env.mc.get_rd_wr_grouped_count() >= 1
    assert self.env.mc.get_bus_turnaround_count() == 1


class mc_observability_base(mc_base_test):

  SCOREBOARD_ENABLED = False
  MAN_RD_OUTSTANDING_MAX = 8

  OBS_TIMEOUT_CYCLES = 2048
  N_PORT0_READS = 6
  N_PORT1_READS = 2
  P0_ID_BASE = 1
  P1_ID_BASE = 10

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = False
    cfg.max_inflight_to_device = 1

  def port0_addr(self, idx: int) -> int:
    return self.encode_dram_addr(row=idx + 1, bg=idx % 4, bank=0)

  def port1_addr(self, idx: int) -> int:
    return self.encode_dram_addr(row=idx + 1, bg=idx % 4, bank=1)

  def seed_pattern(self, base: int, idx: int) -> int:
    data = 0
    for byte_idx in range(self.cfg_ts[0].RDATA_BYTES_P):
      data |= ((int(base) + (0x10 * int(idx)) + byte_idx) & 0xff) << (8 * byte_idx)
    return data

  async def body(self):
    assert self.n_ports >= 2
    self.clear_manager_observations()

    for idx in range(self.N_PORT0_READS):
      self.env.mc.dram.backdoor_write(
          self.port0_addr(idx), self.seed_pattern(0x30, idx))
    for idx in range(self.N_PORT1_READS):
      self.env.mc.dram.backdoor_write(
          self.port1_addr(idx), self.seed_pattern(0x80, idx))

    seq = vip_axi4_pipelined_seq("obs_port0_seq", self._agent_cfg_t(0))
    for idx in range(self.N_PORT0_READS):
      seq.add_item(self.make_read_item(
          f"obs_p0_rd_{idx}",
          self.port0_addr(idx),
          axi_id=self.P0_ID_BASE + idx,
          arqos=4,
          get_response=False))
    seq.set_pipelined_send(True)
    await self.start_seq_or_timeout(seq, port_id=0)

    for _ in range(self.OBS_TIMEOUT_CYCLES):
      if len(self.rd_observations(0)) >= self.N_PORT0_READS:
        break
      await self.bus.rising()
    assert len(self.rd_observations(0)) == self.N_PORT0_READS
    assert [int(r.rresp) for r in self.rd_observations(0)] == [
        VIP_MC_AXI4_RESP_OKAY_C] * self.N_PORT0_READS

    for idx, rsp in enumerate(self.rd_observations(0)):
      assert int(rsp.rdata[0]) == self.seed_pattern(0x30, idx)

    for idx in range(self.N_PORT1_READS):
      got = await self.read_axi(
          self.port1_addr(idx), axi_id=self.P1_ID_BASE + idx, port_id=1)
      assert got[0][1] == VIP_MC_AXI4_RESP_OKAY_C
      assert got[0][0] == self.seed_pattern(0x80, idx)

    total = self.N_PORT0_READS + self.N_PORT1_READS
    assert self.env.mc.get_latency_sample_count() == total
    min_ns = self.env.mc.get_min_latency_ns()
    mean_ns = self.env.mc.get_mean_latency_ns()
    max_ns = self.env.mc.get_max_latency_ns()
    assert min_ns > 0.0
    assert min_ns <= mean_ns <= max_ns

    occ_samples = self.env.mc.get_occupancy_sample_count()
    peak_depth = self.env.mc.get_cmd_queue_peak_depth()
    assert occ_samples > 0
    assert peak_depth >= 1
    assert self.env.mc.get_occupancy_hist_count(peak_depth) >= 1

    hist_sum = 0
    for depth in range(peak_depth + 1):
      hist_sum += self.env.mc.get_occupancy_hist_count(depth)
    assert hist_sum == occ_samples

    assert self.env.mc.get_port_completed_count(0) == self.N_PORT0_READS
    assert self.env.mc.get_port_completed_count(1) == self.N_PORT1_READS
    assert (self.env.mc.get_port_data_bytes(0) ==
            self.N_PORT0_READS * self.DRAM_GEOM.ROW_BYTES_P)
    assert (self.env.mc.get_port_data_bytes(1) ==
            self.N_PORT1_READS * self.DRAM_GEOM.ROW_BYTES_P)
    assert self.env.mc.get_observed_reorder_count() == 0


class mc_telemetry_counters_base(mc_base_test):

  SCOREBOARD_TIMING_CHECK = False
  MAN_RD_OUTSTANDING_MAX = 3
  MAN_RREADY_DELAY_ENABLED = True
  MAN_RREADY_DELAY_PERIOD = 1
  MAN_RREADY_DELAY_TIME = 8

  OBS_TIMEOUT_CYCLES = 1024
  REAL_TOL = 0.001
  EMPTY_ID = 1
  HIT_ID = 2
  MISS_ID = 3

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.telemetry = _TelemetryCollector()
    self._tel_issued_sub = None
    self._tel_rsp_sub = None

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = False
    cfg.rsp_buf_depth = 1
    cfg.max_inflight_to_device = 1

  def connect_phase(self):
    super().connect_phase()
    self.telemetry.dram = self.env.mc.dram
    self._tel_issued_sub = _TelemetrySubscriber(
        "telemetry_issued_sub", self, self.telemetry, "issued")
    self._tel_rsp_sub = _TelemetrySubscriber(
        "telemetry_rsp_sub", self, self.telemetry, "rsp")
    self.env.mc.backend.issued_port.connect(self._tel_issued_sub.analysis_export)
    self.env.mc.dram.rsp_port.connect(self._tel_rsp_sub.analysis_export)

  @staticmethod
  def assert_real_close(name: str, actual: float, expected: float,
                        tol: float) -> None:
    if actual < expected - tol or actual > expected + tol:
      raise AssertionError(
          f"{name} mismatch: actual={actual:.6f} expected={expected:.6f} "
          f"tol={tol:.6f}")

  async def issue_read_no_wait(self, axi_id: int, addr: int) -> None:
    seq = vip_axi4_pipelined_seq(
        f"telemetry_rd_{axi_id:x}_{addr:x}", self._agent_cfg_t(0))
    seq.add_item(self.make_read_item(
        f"telemetry_rd_item_{axi_id:x}",
        addr,
        axi_id=axi_id,
        arqos=5,
        get_response=False))
    seq.set_pipelined_send(True)
    await self.start_seq_or_timeout(seq)

  async def body(self):
    self.telemetry.clear()
    self.clear_manager_observations()

    empty_hit_addr = self.encode_dram_addr(row=0, bg=0, bank=0)
    miss_addr = self.encode_dram_addr(row=1, bg=0, bank=0)
    empty_hit_data = self.axi_width_pattern(0x20)
    miss_data = self.axi_width_pattern(0x80)

    self.env.mc.dram.backdoor_write(empty_hit_addr, empty_hit_data)
    self.env.mc.dram.backdoor_write(miss_addr, miss_data)

    await self.issue_read_no_wait(self.EMPTY_ID, empty_hit_addr)

    blocked_rsp_seen = False
    for _ in range(self.OBS_TIMEOUT_CYCLES):
      if self.bus.get_or("rvalid") == 1 and self.bus.get_or("rready") == 0:
        blocked_rsp_seen = True
        break
      await self.bus.rising()
    assert blocked_rsp_seen

    await self.issue_read_no_wait(self.HIT_ID, empty_hit_addr)
    await self.issue_read_no_wait(self.MISS_ID, miss_addr)

    for _ in range(self.OBS_TIMEOUT_CYCLES):
      if len(self.rd_observations()) >= 3:
        break
      await self.bus.rising()
    assert len(self.rd_observations()) == 3

    expected_data = [empty_hit_data, empty_hit_data, miss_data]
    for idx, rsp in enumerate(self.rd_observations()):
      assert int(rsp.rresp) == VIP_MC_AXI4_RESP_OKAY_C
      assert int(rsp.rdata[0]) == expected_data[idx]

    assert self.env.mc.get_rsp_buf_full_cycles(0) > 0

    actual_row_hit_rate = self.env.mc.get_row_hit_rate()
    actual_predict_accuracy = self.env.mc.get_predict_accuracy()
    actual_effective_bandwidth = self.env.mc.get_effective_bandwidth()
    actual_bus_utilization = self.env.mc.get_bus_utilization()

    self.assert_real_close(
        "row_hit_rate", actual_row_hit_rate,
        self.telemetry.get_row_hit_rate(), self.REAL_TOL)
    self.assert_real_close(
        "predict_accuracy", actual_predict_accuracy,
        self.telemetry.get_predict_accuracy(), self.REAL_TOL)
    self.assert_real_close(
        "effective_bandwidth", actual_effective_bandwidth,
        self.telemetry.get_effective_bandwidth(), self.REAL_TOL)
    self.assert_real_close(
        "bus_utilization", actual_bus_utilization,
        self.telemetry.get_bus_utilization(), self.REAL_TOL)

    assert 0.0 < actual_row_hit_rate < 1.0
    assert actual_effective_bandwidth > 0.0
    assert 0.0 < actual_bus_utilization <= 1.0 + self.REAL_TOL


class mc_reset_recovery_base(mc_base_test):

  SCOREBOARD_ENABLED = False

  OBS_TIMEOUT_CYCLES = 2048
  PRE_RESET_BEATS = 16
  PRE_ID = 1
  POST_ID = 2
  ADDR = 0x0400

  def find_issued_tag(self, axi_id: int):
    for entry in reversed(self.issued_observations()):
      if getattr(entry, "op", None) == VipDramOp.RD and int(entry.axi4_id) == int(axi_id):
        return int(entry.tag)
    return None

  def find_dram_rsp(self, tag: int):
    for rsp in reversed(self.dram_rsp_observations()):
      if int(rsp.tag) == int(tag):
        return rsp
    return None

  async def issue_read_no_wait(self, axi_id: int, addr: int, beats: int) -> None:
    seq = vip_axi4_pipelined_seq(
        f"reset_recovery_rd_{axi_id:x}_{addr:x}", self._agent_cfg_t(0))
    seq.add_item(self.make_read_item(
        f"reset_recovery_rd_item_{axi_id:x}",
        addr,
        beats=beats,
        axi_id=axi_id,
        arqos=4,
        get_response=False))
    seq.set_pipelined_send(True)
    await self.start_seq_or_timeout(seq)

  async def pulse_reset_low(self, cycles: int = 2) -> None:
    self.bus.rst_n.value = 0
    for bus in self.buses:
      bus.reset_master()
    for _ in range(cycles):
      await self.bus.rising()
    self.bus.rst_n.value = 1
    for _ in range(3):
      await self.bus.rising()

  async def body(self):
    self.clear_manager_observations()

    await self.issue_read_no_wait(self.PRE_ID, self.ADDR, self.PRE_RESET_BEATS)

    pre_reset_tag = None
    for _ in range(self.OBS_TIMEOUT_CYCLES):
      pre_reset_tag = self.find_issued_tag(self.PRE_ID)
      if pre_reset_tag is not None:
        break
      await self.bus.rising()
    assert pre_reset_tag is not None

    await Timer(1, unit="ns")
    await self.pulse_reset_low()

    assert len(self.rd_observations()) == 0
    assert len(self.b_observations()) == 0

    got = await self.read_axi(self.ADDR, axi_id=self.POST_ID, return_info=True)
    assert len(got) == 1
    assert got[0]["resp"] == VIP_MC_AXI4_RESP_OKAY_C

    post_reset_tag = None
    for _ in range(self.OBS_TIMEOUT_CYCLES):
      post_reset_tag = self.find_issued_tag(self.POST_ID)
      if post_reset_tag is not None:
        break
      await self.bus.rising()
    assert post_reset_tag is not None

    for _ in range(self.OBS_TIMEOUT_CYCLES):
      if self.find_dram_rsp(post_reset_tag) is not None:
        break
      await self.bus.rising()

    assert self.find_dram_rsp(pre_reset_tag) is None
    post_rsp = self.find_dram_rsp(post_reset_tag)
    assert post_rsp is not None
    assert post_rsp.op == VipDramOp.RD
    assert post_rsp.was_page_empty
    assert not post_rsp.was_page_hit
    assert not post_rsp.was_page_miss
    assert len(self.rd_observations()) == 1
    assert int(self.rd_observations()[0].rid) == self.POST_ID


class mc_refresh_collision_base(mc_base_test):

  SCOREBOARD_TIMING_CHECK = False
  MAN_RD_OUTSTANDING_MAX = 2

  OBS_TIMEOUT_CYCLES = 2048
  LONG_READ_BEATS = 16
  AXI_BEAT_PERIOD_NS = 10.0
  AXI_TIMING_TOL_NS = 30.0
  AXI_EARLY_SLACK_NS = -2.0

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = True
    cfg.tREFI_override = 80.0
    cfg.honor_beat_timing = False
    cfg.max_inflight_to_device = 1

  def expected_axi_last(self, first_ready: float, last_ready: float,
                        beat_count: int) -> float:
    deliver_ready = (first_ready if self.env.mc.dram.cfg.deliver_at_first_beat
                     else last_ready)
    expected_last = deliver_ready + ((int(beat_count) - 1) * self.AXI_BEAT_PERIOD_NS)
    return max(float(last_ready), expected_last)

  def find_dram_rsp(self, tag: int):
    for rsp in reversed(self.dram_rsp_observations()):
      if int(rsp.tag) == int(tag):
        return rsp
    return None

  async def body(self):
    self.env.mc.cfg.honor_beat_timing = False
    self.env.mc.dram.cfg.deliver_at_first_beat = False

    self.clear_manager_observations()
    mc_before = self.env.mc.get_refresh_count()
    dram_before = self.env.mc.dram.get_refresh_count()

    seq = vip_axi4_pipelined_seq("refresh_collision_seq", self._agent_cfg_t(0))
    seq.add_item(self.make_read_item(
        "refresh_collision_rd0",
        0x0400,
        beats=self.LONG_READ_BEATS,
        axi_id=1,
        arqos=4,
        get_response=False))
    seq.add_item(self.make_read_item(
        "refresh_collision_rd1",
        0x2400,
        axi_id=2,
        arqos=4,
        get_response=False))
    seq.set_pipelined_send(True)
    await self.start_seq_or_timeout(seq)

    for _ in range(self.OBS_TIMEOUT_CYCLES):
      grants = list(zip(self.issued_observations(),
                        self.env.issued_observation_times))
      if len(grants) >= 3 and len(self.rd_observations()) >= 2:
        break
      await self.bus.rising()

    assert len(self.rd_observations()) == 2
    first_obs_idx = -1
    second_obs_idx = -1
    for idx, rsp in enumerate(self.rd_observations()):
      if first_obs_idx < 0 and int(rsp.rid) == 1:
        first_obs_idx = idx
      elif second_obs_idx < 0 and int(rsp.rid) == 2:
        second_obs_idx = idx
      assert int(rsp.rresp) == VIP_MC_AXI4_RESP_OKAY_C
    assert first_obs_idx >= 0
    assert second_obs_idx >= 0

    grants = list(zip(self.issued_observations(),
                      self.env.issued_observation_times))
    first_idx = -1
    ref_idx = -1
    second_idx = -1
    for idx, (entry, _) in enumerate(grants):
      if (first_idx < 0 and getattr(entry, "op", None) == VipDramOp.RD and
          int(entry.axi4_id) == 1):
        first_idx = idx
      elif first_idx >= 0 and ref_idx < 0 and getattr(entry, "op", None) == VipDramOp.REF:
        ref_idx = idx
      elif (ref_idx >= 0 and getattr(entry, "op", None) == VipDramOp.RD and
            int(entry.axi4_id) == 2):
        second_idx = idx
        break

    assert first_idx >= 0
    assert ref_idx >= 0
    assert second_idx >= 0

    first_entry, first_grant_time = grants[first_idx]
    ref_entry, ref_grant_time = grants[ref_idx]
    second_entry, second_grant_time = grants[second_idx]
    first_rsp = self.find_dram_rsp(first_entry.tag)
    ref_rsp = self.find_dram_rsp(ref_entry.tag)
    second_rsp = self.find_dram_rsp(second_entry.tag)
    assert first_rsp is not None
    assert ref_rsp is not None
    assert second_rsp is not None
    assert first_rsp.op == VipDramOp.RD
    assert ref_rsp.op == VipDramOp.REF
    assert second_rsp.op == VipDramOp.RD

    mc_after = self.env.mc.get_refresh_count()
    dram_after = self.env.mc.dram.get_refresh_count()
    assert (mc_after - mc_before) > 0
    assert (mc_after - mc_before) == (dram_after - dram_before)

    trfc_ns = float(self.env.mc.dram.cfg.timing.tRFC)
    ref_latency_ns = float(ref_rsp.first_beat_ready_time) - float(ref_grant_time)
    assert ref_latency_ns >= trfc_ns - 1.0

    first_expected_axi_last = self.expected_axi_last(
        first_rsp.first_beat_ready_time,
        first_rsp.last_beat_ready_time,
        first_entry.beats)
    second_expected_axi_last = self.expected_axi_last(
        second_rsp.first_beat_ready_time,
        second_rsp.last_beat_ready_time,
        second_entry.beats)

    assert float(second_rsp.first_beat_ready_time) >= float(ref_rsp.first_beat_ready_time)
    assert float(second_grant_time) < float(ref_rsp.first_beat_ready_time)

    first_obs_delta = (
        float(self.rd_observation_times()[first_obs_idx]) - first_expected_axi_last)
    second_obs_delta = (
        float(self.rd_observation_times()[second_obs_idx]) - second_expected_axi_last)
    assert self.AXI_EARLY_SLACK_NS <= first_obs_delta <= self.AXI_TIMING_TOL_NS
    assert self.AXI_EARLY_SLACK_NS <= second_obs_delta <= self.AXI_TIMING_TOL_NS


NARROW_DRAM_GEOM = VipDramCfgT(
    ROW_BYTES_P=128,
    ADDR_WIDTH_P=33,
    N_RANKS_P=1,
    N_BANK_GROUPS_P=4,
    BANKS_PER_BG_P=4,
    ROW_BITS_P=13,
    COL_BITS_P=9,
    DEVICE_WIDTH_P=8,
    N_DEVICES_PER_RANK_P=8,
)


class mc_narrow_axi4_base(mc_base_test):

  DRAM_GEOM = NARROW_DRAM_GEOM
  NARROW_AXI4_ADDR = 0x0000_C000

  def pattern(self, base: int) -> int:
    data = 0
    for byte_idx in range(self.cfg_ts[0].WDATA_BYTES_P):
      data |= ((int(base) + byte_idx) & 0xff) << (8 * byte_idx)
    return data

  def check_beat(self, ctx: str, data: int, base: int) -> None:
    for byte_idx in range(self.cfg_ts[0].RDATA_BYTES_P):
      got = (int(data) >> (8 * byte_idx)) & 0xff
      exp = (int(base) + byte_idx) & 0xff
      assert got == exp, (
          f"{ctx}: byte {byte_idx} got 0x{got:02x} expected 0x{exp:02x}")

  async def write_burst(self, addr: int, beats) -> None:
    if not isinstance(beats, list):
      beats = [beats]
    full_strb = (1 << self.cfg_ts[0].WDATA_BYTES_P) - 1
    bresp = await self.write_axi(
        addr,
        beats,
        [full_strb] * len(beats),
        axi_id=3,
        size=self.get_full_width_axi_size())
    assert bresp == VIP_MC_AXI4_RESP_OKAY_C

  async def read_burst(self, addr: int, beat_count: int):
    rd = await self.read_axi(
        addr,
        beats=beat_count,
        axi_id=5,
        size=self.get_full_width_axi_size())
    assert len(rd) == beat_count
    assert [resp for _, resp, _ in rd] == [
        VIP_MC_AXI4_RESP_OKAY_C] * beat_count
    return [data for data, _, _ in rd]

  async def body(self):
    nb = self.cfg_ts[0].WDATA_BYTES_P
    row = self.DRAM_GEOM.ROW_BYTES_P
    assert nb == 64
    assert row == 128

    addr = self.NARROW_AXI4_ADDR
    await self.write_burst(addr, [self.pattern(0x10), self.pattern(0x80)])
    rdq = await self.read_burst(addr, 2)
    self.check_beat("gather beat0", rdq[0], 0x10)
    self.check_beat("gather beat1", rdq[1], 0x80)

    addr = self.NARROW_AXI4_ADDR + row
    await self.write_burst(addr, [self.pattern(0x20), self.pattern(0x90)])
    await self.write_burst(addr + nb, [self.pattern(0xc0)])
    rdq = await self.read_burst(addr, 2)
    self.check_beat("subrow lower untouched", rdq[0], 0x20)
    self.check_beat("subrow upper overwritten", rdq[1], 0xc0)


MULTIRANK_DRAM_GEOM = VipDramCfgT(
    ROW_BYTES_P=64,
    ADDR_WIDTH_P=33,
    N_RANKS_P=2,
    N_BANK_GROUPS_P=4,
    BANKS_PER_BG_P=4,
    ROW_BITS_P=12,
    COL_BITS_P=10,
    DEVICE_WIDTH_P=8,
    N_DEVICES_PER_RANK_P=8,
)


class mc_multi_rank_base(mc_base_test):

  DRAM_GEOM = MULTIRANK_DRAM_GEOM

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = True
    cfg.tREFI_override = 100.0

  def grant_rank(self, entry) -> int:
    if entry.op == VipDramOp.REF:
      return int(entry.rank)
    dec = vip_dram_decode_addr(
        int(entry.addr), self.DRAM_GEOM, self.env.mc.cfg.addr_map_policy)
    return int(dec.rank)

  async def body(self):
    assert self.n_ports >= 2
    rank0_data = 0x1122_3344_5566_7788
    rank1_data = 0x99aa_bbcc_ddee_ff00

    rank0_addr = self.encode_dram_addr(rank=0, row=3, bg=0, bank=1, col=4)
    rank1_addr = self.encode_dram_addr(rank=1, row=5, bg=1, bank=2, col=7)

    mc_before = self.env.mc.get_refresh_count()
    dram_before = self.env.mc.dram.get_refresh_count()
    self.clear_manager_observations()

    bresp = await self.write_axi(rank0_addr, rank0_data, axi_id=1, port_id=0)
    assert bresp == VIP_MC_AXI4_RESP_OKAY_C
    bresp = await self.write_axi(rank1_addr, rank1_data, axi_id=2, port_id=1)
    assert bresp == VIP_MC_AXI4_RESP_OKAY_C

    got = await self.read_axi(rank0_addr, axi_id=3, port_id=0)
    assert got[0][1] == VIP_MC_AXI4_RESP_OKAY_C
    assert got[0][0] == rank0_data
    got = await self.read_axi(rank1_addr, axi_id=4, port_id=1)
    assert got[0][1] == VIP_MC_AXI4_RESP_OKAY_C
    assert got[0][0] == rank1_data

    await Timer(230, unit="ns")

    mc_after = self.env.mc.get_refresh_count()
    dram_after = self.env.mc.dram.get_refresh_count()

    saw_ref = [False] * self.DRAM_GEOM.N_RANKS_P
    saw_traffic = [False] * self.DRAM_GEOM.N_RANKS_P
    for entry in self.issued_observations():
      rank = self.grant_rank(entry)
      if entry.op == VipDramOp.REF:
        saw_ref[rank] = True
      else:
        saw_traffic[rank] = True

    for rank in range(self.DRAM_GEOM.N_RANKS_P):
      assert saw_traffic[rank]
      assert saw_ref[rank]

    assert (mc_after - mc_before) >= (2 * self.DRAM_GEOM.N_RANKS_P)
    assert (mc_after - mc_before) == (dram_after - dram_before)


class mc_equiv_axi4_base(mc_base_test):

  @staticmethod
  def bytes_to_int(data) -> int:
    value = 0
    for idx, byte in enumerate(data):
      value |= (int(byte) & 0xff) << (8 * idx)
    return value

  @staticmethod
  def be_to_strb(be) -> int:
    strb = 0
    for idx, enable in enumerate(be):
      if bool(enable):
        strb |= 1 << idx
    return strb

  @staticmethod
  def int_to_bytes(value: int, nbytes: int):
    return [
        (int(value) >> (8 * idx)) & 0xff
        for idx in range(int(nbytes))
    ]

  async def body(self):
    model = mc_equiv_model()
    model.clear()
    program = build_equiv_program(self.DRAM_GEOM.ROW_BYTES_P)

    for txn in program:
      if txn.op == EqOp.READ:
        readback = await self.read_axi(txn.addr, beats=1)
        assert len(readback) == 1
        assert readback[0][1] == VIP_MC_AXI4_RESP_OKAY_C
        got = self.int_to_bytes(readback[0][0], txn.nbytes)
        assert model.check_read(txn.addr, got, "axi4")
      else:
        data = self.bytes_to_int(txn.data)
        strb = self.be_to_strb(txn.be)
        bresp = await self.write_axi(txn.addr, data, strb)
        assert bresp == VIP_MC_AXI4_RESP_OKAY_C
        model.write(txn.addr, txn.data, txn.be)


class mc_cfg_base(mc_base_test):

  async def body(self):
    mc = self.env.mc
    fe0 = mc.fes[0]

    assert mc is not None
    assert mc.dram is self.external_dram
    assert mc.backend is not None
    assert mc.backend.get_registered_port_count() == self.n_ports
    assert fe0 is not None
    assert fe0.cfg is mc.cfg.axi4
    assert fe0.mc_cfg is mc.cfg
    assert fe0.vif is not None
    assert mc.cfg.axi4.aw_outstanding_limit == mc.cfg.max_outstanding_wr
    assert mc.cfg.axi4.ar_outstanding_limit == mc.cfg.max_outstanding_rd
    assert mc.cfg.axi4.qos_to_class(15) == 3
    assert mc.cfg.axi4.is_decerr_addr(0x1800)
    assert not mc.cfg.axi4.is_decerr_addr(0x2000)
    assert mc.cfg.ports[0].allows_addr(self.get_max_addr())
    assert mc.dram.cfg.addr_map == mc.cfg.addr_map_policy


class mc_refresh_base(mc_base_test):

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = True
    cfg.tREFI_override = 50.0

  async def body(self):
    assert self.env.mc.refresh is not None
    mc_before = self.env.mc.get_refresh_count()
    dram_before = self.env.mc.dram.get_refresh_count()
    await Timer(130, unit="ns")
    mc_after = self.env.mc.get_refresh_count()
    dram_after = self.env.mc.dram.get_refresh_count()
    assert (mc_after - mc_before) >= (2 * self.DRAM_GEOM.N_RANKS_P)
    assert (mc_after - mc_before) == (dram_after - dram_before)


class mc_refresh_deferred_base(mc_base_test):

  MAX_DEFERRED = 4

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = True
    cfg.tREFI_override = 50.0
    cfg.refresh_policy = VipMcRefreshPolicy.DEFERRED
    cfg.refresh_max_deferred = self.MAX_DEFERRED

  async def body(self):
    rf = self.env.mc.refresh
    assert rf is not None
    await Timer(1200, unit="ns")

    peak = rf.get_peak_deferred_debt()
    catchups = rf.get_deferred_catchup_count()
    mc_cnt = self.env.mc.get_refresh_count()
    expected = catchups * self.MAX_DEFERRED * self.DRAM_GEOM.N_RANKS_P
    rf.armed = False

    for _ in range(3000):
      dram_cnt = self.env.mc.dram.get_refresh_count()
      if dram_cnt == mc_cnt:
        break
      await Timer(10, unit="ns")
    else:
      dram_cnt = self.env.mc.dram.get_refresh_count()

    assert catchups >= 1
    assert 1 <= peak <= self.MAX_DEFERRED
    assert mc_cnt == dram_cnt
    assert mc_cnt == expected


class mc_init_delay_base(mc_base_test):

  INIT_DELAY_NS = 300.0

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = False
    cfg.init_delay_enabled = True
    cfg.init_delay_ns = self.INIT_DELAY_NS

  async def body(self):
    t0 = sim_time_ns()
    bresp = await self.write_axi(0x2000, 0xa5a5a5a5a5a5a5a5, axi_id=3)
    first_elapsed = sim_time_ns() - t0
    assert bresp == VIP_MC_AXI4_RESP_OKAY_C
    assert first_elapsed >= 200.0

    t0 = sim_time_ns()
    bresp = await self.write_axi(0x2040, 0x5a5a5a5a5a5a5a5a, axi_id=3)
    second_elapsed = sim_time_ns() - t0
    assert bresp == VIP_MC_AXI4_RESP_OKAY_C
    assert second_elapsed <= 150.0


class mc_preset_sweep_base(mc_base_test):

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = False

  async def body(self):
    presets = [
        VipDramPreset.DDR4_3200_CL22,
        VipDramPreset.DDR4_2400_CL17,
        VipDramPreset.DDR3_1600_CL11,
        VipDramPreset.LPDDR4_3200,
        VipDramPreset.DDR5_4800,
        VipDramPreset.IDEAL,
    ]

    for idx, preset in enumerate(presets):
      self.env.mc.dram.cfg.apply_preset(preset)
      self.env.mc.dram.cfg.validate()
      await self.env.mc.dram.reset()

      timing_checked_before = self.env.scoreboard.get_timing_checked_count()
      timing_errors_before = self.env.scoreboard.get_timing_error_count()
      data = 0
      for byte_idx in range(self.cfg_ts[0].WDATA_BYTES_P):
        data |= (0x10 + idx + byte_idx) << (8 * byte_idx)

      bresp = await self.write_axi(0, data, axi_id=3)
      assert bresp == VIP_MC_AXI4_RESP_OKAY_C
      got = await self.read_axi(0, axi_id=5)
      assert got[0][1] == VIP_MC_AXI4_RESP_OKAY_C
      assert got[0][0] == data
      assert (self.env.scoreboard.get_timing_checked_count() -
              timing_checked_before) >= 2
      assert self.env.scoreboard.get_timing_error_count() == timing_errors_before


class mc_ecc_slverr_base(mc_base_test):

  SCOREBOARD_TIMING_CHECK = False

  def configure(self, cfg) -> None:
    cfg.refresh_enabled = False

  async def body(self):
    clean_data = 0x1111222233334444
    corr_data = 0x5555666677778888
    uncorr_data = 0x9999aaaabbbbcccc

    self.env.mc.cfg.ecc_enable = True
    clean_addr = self.encode_dram_addr(row=1, bg=0, bank=0)
    corr_addr = self.encode_dram_addr(row=2, bg=1, bank=0)
    uncorr_addr = self.encode_dram_addr(row=3, bg=2, bank=0)

    assert await self.write_axi(clean_addr, clean_data, axi_id=1) == VIP_MC_AXI4_RESP_OKAY_C
    assert await self.write_axi(corr_addr, corr_data, axi_id=1) == VIP_MC_AXI4_RESP_OKAY_C
    assert await self.write_axi(uncorr_addr, uncorr_data, axi_id=1) == VIP_MC_AXI4_RESP_OKAY_C

    self.env.mc.dram.inject_fault(corr_addr, VipDramFault.CORRECTABLE)
    self.env.mc.dram.inject_fault(uncorr_addr, VipDramFault.UNCORRECTABLE)

    got = await self.read_axi(clean_addr, axi_id=2)
    assert got[0][1] == VIP_MC_AXI4_RESP_OKAY_C
    assert got[0][0] == clean_data

    got = await self.read_axi(corr_addr, axi_id=2)
    assert got[0][1] == VIP_MC_AXI4_RESP_OKAY_C
    assert got[0][0] == corr_data

    got = await self.read_axi(uncorr_addr, axi_id=2)
    assert got[0][1] == VIP_MC_AXI4_RESP_SLVERR_C
    assert got[0][0] != uncorr_data
    assert self.env.mc.get_ecc_corrected_count() == 1
    assert self.env.mc.get_ecc_uncorrectable_count() == 1

    self.env.mc.cfg.ecc_enable = False
    got = await self.read_axi(uncorr_addr, axi_id=2)
    assert got[0][1] == VIP_MC_AXI4_RESP_OKAY_C
    assert got[0][0] != uncorr_data
    assert self.env.mc.get_ecc_corrected_count() == 1
    assert self.env.mc.get_ecc_uncorrectable_count() == 1

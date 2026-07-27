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
## CHI-only pyUVM testbench environment for vip_mc.
##
################################################################################

from __future__ import annotations

from pyuvm import ConfigDB, UVMConfigItemNotFound, uvm_env, uvm_subscriber

from vip_chi_agent import vip_chi_agent
from vip_chi_cfg_agent import UVM_ACTIVE, VipChiCfgAgent
from vip_chi_coverage import vip_chi_coverage
from vip_chi_types_pkg import Role

from vip_dram import vip_dram
from vip_dram_config import VipDramConfig
from vip_dram_types_pkg import VIP_DRAM_CFG_DEFAULT, vip_dram_default_addr_map

from vip_mc import vip_mc
from vip_mc_chi_vif_holder import vip_mc_chi_vif_holder
from vip_mc_env_cfg import vip_mc_env_cfg
from vip_mc_types_pkg import VipMcPortCfgT, VipMcProto


CHI_DECERR_LO_C = 0x0003_0000
CHI_DECERR_HI_C = 0x0003_FFFF


class _chi_observation_collector(uvm_subscriber):

  def __init__(self, name, parent, observations):
    super().__init__(name, parent)
    self.observations = observations

  def write(self, item):
    stored = item.clone() if hasattr(item, "clone") else item
    self.observations.append(stored)


class mc_chi_tb_env(uvm_env):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.rni_vif = None
    self.mc_chi_vif = None
    self.chi_cfg_t = None
    self.mc_chi_cfg_t = None
    self.geom = VIP_DRAM_CFG_DEFAULT
    self.status_vif = None

    self.env_cfg = None
    self.dram = None
    self.u_mc = None
    self.rni_cfg = None
    self.rni_agent = None
    self.coverage = None
    self.rni_req_observations = []
    self.rni_rsp_observations = []
    self.rni_dat_observations = []
    self.observation_collectors = []

  def build_phase(self):
    self._resolve_config()

    dram_cfg = VipDramConfig("dram_cfg", self.geom)
    dram_cfg.addr_map = vip_dram_default_addr_map(self.geom)
    dram_cfg.deliver_at_first_beat = True
    ConfigDB().set(self, "dram", "cfg", dram_cfg)
    self.dram = vip_dram("dram", self)

    self.rni_cfg = VipChiCfgAgent("rni_cfg")
    self.rni_cfg.role = Role.RNI
    self.rni_cfg.is_active = UVM_ACTIVE
    ConfigDB().set(self, "rni_agent", "cfg", self.rni_cfg)
    ConfigDB().set(self, "rni_agent", "role", Role.RNI)
    ConfigDB().set(self, "rni_agent", "vif", self.rni_vif)
    self.rni_agent = vip_chi_agent("rni_agent", self)

    port_cfg = VipMcPortCfgT(proto=VipMcProto.CHI, chi=self.mc_chi_cfg_t)
    self.env_cfg = vip_mc_env_cfg(
        "env_cfg", n_ports=1, ports=[port_cfg], geom=self.geom)
    self.env_cfg.dram = self.dram
    self.env_cfg.status_vif = self.status_vif
    self._apply_default_mc_config()

    self.env_cfg.register_vif(
        0, vip_mc_chi_vif_holder("mc_chi_holder", self.mc_chi_vif,
                                 self.mc_chi_cfg_t))
    ConfigDB().set(self, "u_mc", "env_cfg", self.env_cfg)
    self.u_mc = vip_mc("u_mc", self)

    self._build_coverage()

  def _build_coverage(self):
    """CHI protocol coverage. The agent already ships vip_chi_coverage; this env
    is the RN-I side of the link, so the RN-I channel taps carry the traffic.
    Opt out with mc_coverage_enabled = 0."""
    try:
      if int(ConfigDB().get(self, "", "mc_coverage_enabled")) == 0:
        return
    except UVMConfigItemNotFound:
      pass

    self.coverage = vip_chi_coverage("coverage", self)
    self.coverage.set_cfg(self.chi_cfg_t)

  def connect_phase(self):
    if self.coverage is not None:
      self.rni_agent.req_port.connect(self.coverage.rni_req_cov_port)
      self.rni_agent.rsp_port.connect(self.coverage.rni_rsp_cov_port)
      self.rni_agent.dat_port.connect(self.coverage.rni_dat_cov_port)

    specs = [
        ("req", self.rni_agent.req_port, self.rni_req_observations),
        ("rsp", self.rni_agent.rsp_port, self.rni_rsp_observations),
        ("dat", self.rni_agent.dat_port, self.rni_dat_observations),
    ]
    for kind, port, observations in specs:
      collector = _chi_observation_collector(
          f"rni_{kind}_collector", self, observations)
      port.connect(collector.analysis_export)
      self.observation_collectors.append(collector)

  def clear_rni_observations(self) -> None:
    self.rni_req_observations.clear()
    self.rni_rsp_observations.clear()
    self.rni_dat_observations.clear()

  def _resolve_config(self) -> None:
    self.rni_vif = ConfigDB().get(self, "", "rni_vif")
    self.mc_chi_vif = ConfigDB().get(self, "", "mc_chi_vif")
    self.chi_cfg_t = ConfigDB().get(self, "", "chi_cfg_t")
    self.mc_chi_cfg_t = ConfigDB().get(self, "", "mc_chi_cfg_t")
    try:
      self.geom = ConfigDB().get(self, "", "dram_geom")
    except UVMConfigItemNotFound:
      self.geom = VIP_DRAM_CFG_DEFAULT
    try:
      self.status_vif = ConfigDB().get(self, "", "status_vif")
    except UVMConfigItemNotFound:
      self.status_vif = None

  def _apply_default_mc_config(self) -> None:
    cfg = self.env_cfg.cfg
    cfg.qos_class_count = 4
    cfg.qos_aging_ns = 25.0
    cfg.max_outstanding_rd = 8
    cfg.max_outstanding_wr = 8
    cfg.rsp_buf_depth = 2
    cfg.max_inflight_to_device = 4
    cfg.refresh_enabled = False
    cfg.honor_beat_timing = True
    cfg.addr_map_policy = vip_dram_default_addr_map(self.geom)
    cfg.axi4.qos_class_map[15] = 3
    cfg.axi4.clear_decerr_ranges()
    cfg.axi4.add_decerr_range(CHI_DECERR_LO_C, CHI_DECERR_HI_C)

    try:
      split_write_rsp = int(
          ConfigDB().get(self, "", "mc_chi_split_write_rsp")) != 0
    except UVMConfigItemNotFound:
      split_write_rsp = True
    cfg.chi.split_write_rsp = split_write_rsp

    for port in cfg.ports:
      port.clear_regions()
      port.add_region(0, self._max_addr())

  def _max_addr(self) -> int:
    if self.geom.ADDR_WIDTH_P >= 64:
      return (1 << 64) - 1
    return (1 << self.geom.ADDR_WIDTH_P) - 1

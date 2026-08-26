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
################################################################################

from __future__ import annotations

import os

import cocotb
from cocotb.triggers import FallingEdge
from pyuvm import ConfigDB, UVMConfigItemNotFound, uvm_env

from vip_axi4_agent import vip_axi4_agent
from vip_axi4_cfg_agent import vip_axi4_cfg_agent
from vip_axi4_coverage import vip_axi4_coverage
from vip_axi4_types_pkg import Axi4Role
from vip_chi_agent import vip_chi_agent
from vip_chi_cfg_agent import UVM_ACTIVE, VipChiCfgAgent
from vip_chi_coverage import vip_chi_coverage
from vip_chi_types_pkg import Role
from vip_dram import vip_dram
from vip_dram_config import VipDramConfig
from vip_dram_types_pkg import VIP_DRAM_CFG_DEFAULT, vip_dram_default_addr_map
from vip_mc import vip_mc
from vip_mc_axi4_vif_holder import vip_mc_axi4_vif_holder
from vip_mc_chi_vif_holder import vip_mc_chi_vif_holder
from vip_mc_env_cfg import vip_mc_env_cfg
from vip_mc_types_pkg import VipMcPortCfgT, VipMcProto
from sva.bind_chi import bind_chi


class mc_mixed_tb_env(uvm_env):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.axi4_vif = None
    self.axi4_agent_cfg_t = None
    self.mc_axi4_cfg_t = None
    self.rni_vif = None
    self.mc_chi_vif = None
    self.chi_cfg_t = None
    self.mc_chi_cfg_t = None
    self.geom = VIP_DRAM_CFG_DEFAULT

    self.env_cfg = None
    self.dram = None
    self.u_mc = None
    self.man_cfg = None
    self.man_agent = None
    self.rni_cfg = None
    self.rni_agent = None
    self.axi4_coverage = None
    self.chi_coverage = None
    self.rni_sva = None
    self.mc_snf_sva = None

  def build_phase(self):
    self._resolve_config()

    dram_cfg = VipDramConfig("dram_cfg", self.geom)
    dram_cfg.addr_map = vip_dram_default_addr_map(self.geom)
    dram_cfg.deliver_at_first_beat = True
    ConfigDB().set(self, "dram", "cfg", dram_cfg)
    self.dram = vip_dram("dram", self)

    ports = [
        VipMcPortCfgT(
            proto=VipMcProto.AXI4, axi4=self.mc_axi4_cfg_t,
            chi=self.mc_chi_cfg_t),
        VipMcPortCfgT(
            proto=VipMcProto.CHI, axi4=self.mc_axi4_cfg_t,
            chi=self.mc_chi_cfg_t),
    ]
    self.env_cfg = vip_mc_env_cfg(
        "env_cfg", n_ports=2, ports=ports, geom=self.geom)
    self.env_cfg.dram = self.dram
    self._apply_default_mc_config()
    self.env_cfg.register_vif(
        0, vip_mc_axi4_vif_holder("mc_axi4_holder", self.axi4_vif,
                                  self.mc_axi4_cfg_t))
    self.env_cfg.register_vif(
        1, vip_mc_chi_vif_holder("mc_chi_holder", self.mc_chi_vif,
                                 self.mc_chi_cfg_t))
    ConfigDB().set(self, "u_mc", "env_cfg", self.env_cfg)
    self.u_mc = vip_mc("u_mc", self)

    self.man_cfg = vip_axi4_cfg_agent("man_cfg")
    self.man_cfg.is_active = "UVM_ACTIVE"
    self.man_cfg.awvalid_delay_enabled = False
    self.man_cfg.wvalid_delay_enabled = False
    self.man_cfg.bready_delay_enabled = False
    self.man_cfg.rready_delay_enabled = False
    self.man_cfg.wr_outstanding_max = 1
    self.man_cfg.rd_outstanding_max = 1
    ConfigDB().set(self, "man_agent", "role", Axi4Role.MANAGER)
    ConfigDB().set(self, "man_agent", "cfg", self.man_cfg)
    ConfigDB().set(self, "man_agent", "vif", self.axi4_vif)
    ConfigDB().set(self, "man_agent", "cfg_t", self.axi4_agent_cfg_t)
    self.man_agent = vip_axi4_agent("man_agent", self)

    self.rni_cfg = VipChiCfgAgent("rni_cfg")
    self.rni_cfg.role = Role.RNI
    self.rni_cfg.is_active = UVM_ACTIVE
    ConfigDB().set(self, "rni_agent", "cfg", self.rni_cfg)
    ConfigDB().set(self, "rni_agent", "role", Role.RNI)
    ConfigDB().set(self, "rni_agent", "vif", self.rni_vif)
    self.rni_agent = vip_chi_agent("rni_agent", self)
    self.rni_sva = bind_chi(self.rni_vif, "rni_sva")
    self.mc_snf_sva = bind_chi(self.mc_chi_vif, "mc_snf_sva")

    self._build_coverage()

  def _build_coverage(self):
    """Protocol coverage on both host legs of the mixed topology. Opt out with
    mc_coverage_enabled = 0."""
    try:
      if int(ConfigDB().get(self, "", "mc_coverage_enabled")) == 0:
        return
    except UVMConfigItemNotFound:
      pass

    ConfigDB().set(self, "axi4_coverage", "cfg_t", self.axi4_agent_cfg_t)
    ConfigDB().set(self, "axi4_coverage", "vif", self.axi4_vif)
    self.axi4_coverage = vip_axi4_coverage("axi4_coverage", self)

    self.chi_coverage = vip_chi_coverage("chi_coverage", self)
    self.chi_coverage.set_cfg(self.chi_cfg_t)

  def connect_phase(self):
    """Connect both host legs to their coverage collectors."""
    if self.axi4_coverage is not None:
      self.man_agent.monitor.bresp_port.connect(self.axi4_coverage.wr_cov_port)
      self.man_agent.monitor.rdata_port.connect(self.axi4_coverage.rd_cov_port)

    if self.chi_coverage is not None:
      self.rni_agent.req_port.connect(self.chi_coverage.rni_req_cov_port)
      self.rni_agent.rsp_port.connect(self.chi_coverage.rni_rsp_cov_port)
      self.rni_agent.dat_port.connect(self.chi_coverage.rni_dat_cov_port)

  async def run_phase(self):
    cocotb.start_soon(self.rni_sva.run())
    cocotb.start_soon(self.mc_snf_sva.run())

    while True:
      await FallingEdge(self.rni_vif.rst_n)

  def report_phase(self):
    csv_path = os.environ.get("VIP_CHI_CHECK_CSV", "")
    opcode_csv = os.environ.get("VIP_CHI_OPCODE_CSV", "")
    run_name = os.environ.get("VIP_CHI_TESTNAME", "") or "unknown"

    for checker in (self.rni_sva, self.mc_snf_sva):
      checker.report(self.logger)
      if csv_path:
        checker.export_check_csv(csv_path, run_name)
      if opcode_csv:
        checker.export_opcode_csv(opcode_csv, run_name)

    total = self.rni_sva.errors + self.mc_snf_sva.errors
    assert total == 0, (
        f"CHI protocol checkers reported {total} violation(s): "
        f"rni_sva={self.rni_sva.errors} mc_snf_sva={self.mc_snf_sva.errors}")

  def _resolve_config(self) -> None:
    self.axi4_vif = ConfigDB().get(self, "", "axi4_vif")
    self.axi4_agent_cfg_t = ConfigDB().get(self, "", "axi4_agent_cfg_t")
    self.mc_axi4_cfg_t = ConfigDB().get(self, "", "mc_axi4_cfg_t")
    self.rni_vif = ConfigDB().get(self, "", "rni_vif")
    self.mc_chi_vif = ConfigDB().get(self, "", "mc_chi_vif")
    self.chi_cfg_t = ConfigDB().get(self, "", "chi_cfg_t")
    self.mc_chi_cfg_t = ConfigDB().get(self, "", "mc_chi_cfg_t")
    try:
      self.geom = ConfigDB().get(self, "", "dram_geom")
    except UVMConfigItemNotFound:
      self.geom = VIP_DRAM_CFG_DEFAULT

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
    cfg.axi4.aw_pending_depth = 2
    cfg.axi4.w_data_buf_depth = 4
    cfg.axi4.qos_class_map[15] = 3
    cfg.axi4.clear_decerr_ranges()
    cfg.chi.split_write_rsp = True
    cfg.addr_map_policy = vip_dram_default_addr_map(self.geom)

    for port in cfg.ports:
      port.clear_regions()
      port.add_region(0, self._max_addr())

  def _max_addr(self) -> int:
    if self.geom.ADDR_WIDTH_P >= 64:
      return (1 << 64) - 1
    return (1 << self.geom.ADDR_WIDTH_P) - 1

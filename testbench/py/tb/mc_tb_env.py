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
## Minimal pyUVM environment for the vip_mc AXI4 smoke tests.
##
################################################################################

from __future__ import annotations

from pyuvm import ConfigDB, UVMConfigItemNotFound, uvm_env, uvm_subscriber

from vip_dram_types_pkg import sim_time_ns
from vip_axi4_agent import vip_axi4_agent
from vip_axi4_cfg_agent import vip_axi4_cfg_agent
from vip_axi4_types_pkg import Axi4Role
from mc_scoreboard import mc_scoreboard
from mc_coverage import mc_coverage
from vip_axi4_coverage import vip_axi4_coverage
from vip_mc import vip_mc


class _scoreboard_b_collector(uvm_subscriber):

  def __init__(self, name, parent, scoreboard, port_id):
    super().__init__(name, parent)
    self.scoreboard = scoreboard
    self.port_id = port_id

  def write(self, item):
    self.scoreboard.observe_b(
        self.port_id, int(item.bid), int(item.bresp))


class _scoreboard_r_collector(uvm_subscriber):

  def __init__(self, name, parent, scoreboard, port_id):
    super().__init__(name, parent)
    self.scoreboard = scoreboard
    self.port_id = port_id

  def write(self, item):
    self.scoreboard.observe_r(
        self.port_id, int(item.rid), int(item.rresp), len(item.rdata))


class _manager_observation_collector(uvm_subscriber):

  def __init__(self, name, parent, observations, observation_times, port_id):
    super().__init__(name, parent)
    self.observations = observations
    self.observation_times = observation_times
    self.port_id = port_id

  def write(self, item):
    stored = item.clone() if hasattr(item, "clone") else item
    self.observations[self.port_id].append(stored)
    self.observation_times[self.port_id].append(sim_time_ns())


class mc_tb_env(uvm_env):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.mc = None
    self.scoreboard = None
    self.coverage = None
    self.man_coverage = []
    self.man_cfg = []
    self.man_agent = []
    self.b_collectors = []
    self.r_collectors = []
    self.manager_observation_collectors = []
    self.aw_observations = []
    self.aw_observation_times = []
    self.w_observations = []
    self.w_observation_times = []
    self.b_observations = []
    self.b_observation_times = []
    self.ar_observations = []
    self.ar_observation_times = []
    self.rd_observations = []
    self.rd_observation_times = []
    self.issued_observations = []
    self.issued_observation_times = []
    self.dram_rsp_observations = []
    self.dram_rsp_observation_times = []
    self.axi4_vifs = []
    self.axi4_cfg_ts = []
    self.n_ports = 1
    self.manager_agents_active = True

  def build_phase(self):
    self._resolve_cfg()
    self.mc = vip_mc("mc", self)
    self.scoreboard = mc_scoreboard("scoreboard", self)
    self._build_manager_agents()
    self._build_coverage()

  def _build_coverage(self):
    """Functional coverage, opt-out via the mc_coverage_enabled knob:

      ConfigDB().set(None, "*", "mc_coverage_enabled", 0)

    Two layers: vip_axi4_coverage per manager port (AXI4 protocol coverage the
    agent already ships but no vip_mc env instantiated until now), and
    mc_coverage for the controller-specific scheduling decisions.
    """
    try:
      if int(ConfigDB().get(self, "", "mc_coverage_enabled")) == 0:
        return
    except UVMConfigItemNotFound:
      pass

    for port_id in range(len(self.man_agent)):
      cfg_t = (self.axi4_cfg_ts[port_id]
               if port_id < len(self.axi4_cfg_ts) else self.axi4_cfg_ts[0])
      cov_name = f"man_coverage_{port_id}"
      ConfigDB().set(self, cov_name, "cfg_t", cfg_t)
      ConfigDB().set(self, cov_name, "vif", self.axi4_vifs[port_id])
      self.man_coverage.append(vip_axi4_coverage(cov_name, self))

    ConfigDB().set(self, "coverage", "n_ports", self.n_ports)
    self.coverage = mc_coverage("coverage", self)

  def connect_phase(self):
    self.mc.backend.issued_port.connect(self.scoreboard.analysis_export)
    self.scoreboard.dram = self.mc.dram
    self.scoreboard.backend = self.mc.backend
    self._init_manager_observations()
    issued_collector = _manager_observation_collector(
        "issued_collector", self,
        [self.issued_observations], [self.issued_observation_times], 0)
    dram_rsp_collector = _manager_observation_collector(
        "dram_rsp_collector", self,
        [self.dram_rsp_observations], [self.dram_rsp_observation_times], 0)
    self.mc.backend.issued_port.connect(issued_collector.analysis_export)
    self.mc.dram.rsp_port.connect(dram_rsp_collector.analysis_export)
    self.manager_observation_collectors.extend([
        issued_collector, dram_rsp_collector])
    for port_id, agent in enumerate(self.man_agent):
      b_collector = _scoreboard_b_collector(
          f"scoreboard_b_collector_{port_id}", self, self.scoreboard, port_id)
      r_collector = _scoreboard_r_collector(
          f"scoreboard_r_collector_{port_id}", self, self.scoreboard, port_id)
      agent.monitor.bresp_port.connect(b_collector.analysis_export)
      agent.monitor.rdata_port.connect(r_collector.analysis_export)
      self.b_collectors.append(b_collector)
      self.r_collectors.append(r_collector)
      self._connect_manager_observation_collectors(port_id, agent)
    self._connect_coverage()

  def _connect_coverage(self):
    """AXI4 protocol coverage taps the same manager B/R streams the scoreboard
    uses; the controller coverage taps the backend grant and DRAM response."""
    for port_id, cov in enumerate(self.man_coverage):
      agent = self.man_agent[port_id]
      agent.monitor.bresp_port.connect(cov.wr_cov_port)
      agent.monitor.rdata_port.connect(cov.rd_cov_port)

    if self.coverage is None:
      return

    self.coverage.dram = self.mc.dram
    self.coverage.mc = self.mc
    self.mc.backend.issued_port.connect(self.coverage.issued_export)
    self.mc.dram.rsp_port.connect(self.coverage.dram_rsp_export)

    for port_id, agent in enumerate(self.man_agent):
      if port_id >= len(self.coverage.b_collectors):
        break
      agent.monitor.bresp_port.connect(
          self.coverage.b_collectors[port_id].analysis_export)
      agent.monitor.rdata_port.connect(
          self.coverage.r_collectors[port_id].analysis_export)

  def _resolve_cfg(self):
    try:
      self.axi4_vifs = list(ConfigDB().get(self, "", "axi4_vifs"))
    except UVMConfigItemNotFound:
      self.axi4_vifs = [ConfigDB().get(self, "", "vif")]

    try:
      self.axi4_cfg_ts = list(ConfigDB().get(self, "", "axi4_agent_cfg_ts"))
    except UVMConfigItemNotFound:
      try:
        self.axi4_cfg_ts = list(ConfigDB().get(self, "", "axi4_cfg_ts"))
      except UVMConfigItemNotFound:
        self.axi4_cfg_ts = [ConfigDB().get(self, "", "cfg_t")]

    try:
      self.n_ports = int(ConfigDB().get(self, "", "n_ports"))
    except UVMConfigItemNotFound:
      self.n_ports = len(self.axi4_vifs)

    try:
      self.manager_agents_active = bool(
          ConfigDB().get(self, "", "manager_agents_active"))
    except UVMConfigItemNotFound:
      self.manager_agents_active = True

  def _build_manager_agents(self):
    if not self.manager_agents_active:
      return

    try:
      wr_outstanding_max = int(
          ConfigDB().get(self, "", "man_wr_outstanding_max"))
    except UVMConfigItemNotFound:
      wr_outstanding_max = 1
    try:
      rd_outstanding_max = int(
          ConfigDB().get(self, "", "man_rd_outstanding_max"))
    except UVMConfigItemNotFound:
      rd_outstanding_max = 1
    try:
      rready_delay_enabled = bool(
          ConfigDB().get(self, "", "man_rready_delay_enabled"))
    except UVMConfigItemNotFound:
      rready_delay_enabled = False
    try:
      bready_delay_enabled = bool(
          ConfigDB().get(self, "", "man_bready_delay_enabled"))
    except UVMConfigItemNotFound:
      bready_delay_enabled = False
    try:
      rready_delay_period = int(
          ConfigDB().get(self, "", "man_rready_delay_period"))
    except UVMConfigItemNotFound:
      rready_delay_period = 1
    try:
      bready_delay_period = int(
          ConfigDB().get(self, "", "man_bready_delay_period"))
    except UVMConfigItemNotFound:
      bready_delay_period = 1
    try:
      rready_delay_time = int(
          ConfigDB().get(self, "", "man_rready_delay_time"))
    except UVMConfigItemNotFound:
      rready_delay_time = 1
    try:
      bready_delay_time = int(
          ConfigDB().get(self, "", "man_bready_delay_time"))
    except UVMConfigItemNotFound:
      bready_delay_time = 1

    for port_id in range(self.n_ports):
      agent_name = f"man_agent_{port_id}"
      cfg = vip_axi4_cfg_agent(f"man_cfg_{port_id}")
      cfg.is_active = "UVM_ACTIVE"
      cfg.awvalid_delay_enabled = False
      cfg.wvalid_delay_enabled = False
      cfg.bready_delay_enabled = bready_delay_enabled
      cfg.bready_delay_gauss_enabled = False
      cfg.bready_delay_period_min = bready_delay_period
      cfg.bready_delay_period_max = bready_delay_period
      cfg.bready_delay_time_min = bready_delay_time
      cfg.bready_delay_time_max = bready_delay_time
      cfg.rready_delay_enabled = rready_delay_enabled
      cfg.rready_delay_gauss_enabled = False
      cfg.rready_delay_period_min = rready_delay_period
      cfg.rready_delay_period_max = rready_delay_period
      cfg.rready_delay_time_min = rready_delay_time
      cfg.rready_delay_time_max = rready_delay_time
      cfg.wr_outstanding_max = wr_outstanding_max
      cfg.rd_outstanding_max = rd_outstanding_max

      bus = self.axi4_vifs[port_id]
      cfg_t = self.axi4_cfg_ts[port_id] if port_id < len(self.axi4_cfg_ts) else self.axi4_cfg_ts[0]
      ConfigDB().set(self, agent_name, "role", Axi4Role.MANAGER)
      ConfigDB().set(self, agent_name, "cfg", cfg)
      ConfigDB().set(self, agent_name, "vif", bus)
      ConfigDB().set(self, agent_name, "cfg_t", cfg_t)
      self.man_cfg.append(cfg)
      self.man_agent.append(vip_axi4_agent(agent_name, self))

  def _init_manager_observations(self) -> None:
    self.aw_observations = [[] for _ in range(self.n_ports)]
    self.aw_observation_times = [[] for _ in range(self.n_ports)]
    self.w_observations = [[] for _ in range(self.n_ports)]
    self.w_observation_times = [[] for _ in range(self.n_ports)]
    self.b_observations = [[] for _ in range(self.n_ports)]
    self.b_observation_times = [[] for _ in range(self.n_ports)]
    self.ar_observations = [[] for _ in range(self.n_ports)]
    self.ar_observation_times = [[] for _ in range(self.n_ports)]
    self.rd_observations = [[] for _ in range(self.n_ports)]
    self.rd_observation_times = [[] for _ in range(self.n_ports)]
    self.issued_observations = []
    self.issued_observation_times = []
    self.dram_rsp_observations = []
    self.dram_rsp_observation_times = []

  def _connect_manager_observation_collectors(self, port_id: int, agent) -> None:
    specs = [
        ("aw", agent.monitor.awaddr_port,
         self.aw_observations, self.aw_observation_times),
        ("w", agent.monitor.wdata_port,
         self.w_observations, self.w_observation_times),
        ("b", agent.monitor.bresp_port,
         self.b_observations, self.b_observation_times),
        ("ar", agent.monitor.araddr_port,
         self.ar_observations, self.ar_observation_times),
        ("rd", agent.monitor.rdata_port,
         self.rd_observations, self.rd_observation_times),
    ]
    for kind, port, observations, observation_times in specs:
      collector = _manager_observation_collector(
          f"manager_{kind}_collector_{port_id}", self,
          observations, observation_times, port_id)
      port.connect(collector.analysis_export)
      self.manager_observation_collectors.append(collector)

  def clear_manager_observations(self, port_id=None) -> None:
    ports = range(self.n_ports) if port_id is None else [int(port_id)]
    for idx in ports:
      self.aw_observations[idx].clear()
      self.aw_observation_times[idx].clear()
      self.w_observations[idx].clear()
      self.w_observation_times[idx].clear()
      self.b_observations[idx].clear()
      self.b_observation_times[idx].clear()
      self.ar_observations[idx].clear()
      self.ar_observation_times[idx].clear()
      self.rd_observations[idx].clear()
      self.rd_observation_times[idx].clear()
    self.issued_observations.clear()
    self.issued_observation_times.clear()
    self.dram_rsp_observations.clear()
    self.dram_rsp_observation_times.clear()

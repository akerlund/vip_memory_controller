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
## System-config aggregator matching vip_mc/sv/vip_mc_env_cfg.sv.
##
################################################################################

from __future__ import annotations

from pyuvm import ConfigDB

from vip_dram_types_pkg import VIP_DRAM_CFG_DEFAULT, vip_dram_default_addr_map
from vip_mc_config import vip_mc_config
from vip_mc_types_pkg import VipMcPortCfgT


class vip_mc_env_cfg:

  def __init__(self, name="vip_mc_env_cfg", n_ports=1, ports=None,
               geom=VIP_DRAM_CFG_DEFAULT):
    self.name = name
    self.n_ports = int(n_ports)
    self.geom = geom
    self.ports = list(ports) if ports is not None else [
        VipMcPortCfgT() for _ in range(self.n_ports)
    ]
    if len(self.ports) != self.n_ports:
      raise RuntimeError(
          f"[{self.name}] ports length {len(self.ports)} does not match "
          f"n_ports={self.n_ports}")

    self.cfg = vip_mc_config("cfg")
    self.cfg.ensure_port_count(self.n_ports)
    self.cfg.addr_map_policy = vip_dram_default_addr_map(self.geom)
    for port_id, port in enumerate(self.cfg.ports):
      if port.vif_key == "":
        port.vif_key = f"vif_port{port_id}"

    self.dram = None
    self.status_vif = None
    self.vif_h = [None] * self.n_ports

  def register_vif(self, port_id: int, holder) -> None:
    if port_id < 0 or port_id >= self.n_ports:
      raise RuntimeError(
          f"[{self.name}] Port id {port_id} out of range "
          f"0..{self.n_ports - 1}")
    if holder is None:
      raise RuntimeError(f"[{self.name}] register_vif({port_id}) got None")
    if holder.proto != self.ports[port_id].proto:
      raise RuntimeError(
          f"[{self.name}] register_vif({port_id}) proto mismatch: "
          f"holder={holder.proto.name} expected={self.ports[port_id].proto.name}")
    self.vif_h[port_id] = holder

  def apply(self, ctxt=None, inst="*vip_mc*") -> None:
    self.validate()
    ConfigDB().set(ctxt, inst, "env_cfg", self)

  def validate(self) -> None:
    self.cfg.ensure_port_count(self.n_ports)
    self.cfg.validate(self.geom)
    if self.dram is None:
      raise RuntimeError(f"[{self.name}] dram handle is null")

    max_addr = self.device_max_addr()
    for port_id, holder in enumerate(self.vif_h):
      if holder is None:
        raise RuntimeError(f"[{self.name}] vif_h[{port_id}] is null")
      if holder.proto != self.ports[port_id].proto:
        raise RuntimeError(
            f"[{self.name}] vif_h[{port_id}] proto mismatch: "
            f"holder={holder.proto.name} expected={self.ports[port_id].proto.name}")
      for region_id, region in enumerate(self.cfg.ports[port_id].regions):
        if int(region.hi) > max_addr:
          raise RuntimeError(
              f"[{self.name}] ports[{port_id}].regions[{region_id}] exceeds "
              f"device address width (hi=0x{region.hi:x} max=0x{max_addr:x})")

  def device_max_addr(self) -> int:
    if self.geom.ADDR_WIDTH_P >= 64:
      return (1 << 64) - 1
    return (1 << self.geom.ADDR_WIDTH_P) - 1

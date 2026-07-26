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
## pyUVM port of vip_mc/sv/vip_mc_port_runtime_cfg.sv.
##
################################################################################

from __future__ import annotations

from vip_mc_types_pkg import VipMcAddrRegionT, vip_mc_addr_in_region


class vip_mc_port_runtime_cfg:

  def __init__(self, name="vip_mc_port_runtime_cfg"):
    self.name = name
    self.regions = []
    self.arb_weight = 1
    self.vif_key = ""

  def clear_regions(self) -> None:
    self.regions.clear()

  def add_region(self, lo: int, hi: int) -> None:
    if lo > hi:
      raise RuntimeError(
          f"[{self.name}] Region lo > hi (lo=0x{lo:x} hi=0x{hi:x})")
    self.regions.append(VipMcAddrRegionT(int(lo), int(hi)))

  def allows_addr(self, addr: int) -> bool:
    if not self.regions:
      return True
    return any(vip_mc_addr_in_region(addr, r) for r in self.regions)

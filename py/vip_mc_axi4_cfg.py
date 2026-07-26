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
## pyUVM port of vip_mc/sv/vip_mc_axi4_cfg.sv.
##
################################################################################

from __future__ import annotations


class vip_mc_axi4_cfg:

  def __init__(self, name="vip_mc_axi4_cfg"):
    self.name = name
    self.aw_outstanding_limit = 0
    self.ar_outstanding_limit = 0
    self.aw_pending_depth = 0
    self.w_data_buf_depth = 0
    self.qos_class_map = [i for i in range(16)]
    self.exclusive_enabled = True
    self.decerr_addr_lo = []
    self.decerr_addr_hi = []
    self.dram_handle_path = "uvm_test_top.env.dram"

  def add_decerr_range(self, lo: int, hi: int) -> None:
    if lo > hi:
      raise RuntimeError(
          f"[{self.name}] DECERR range lo > hi (lo=0x{lo:x} hi=0x{hi:x})")
    self.decerr_addr_lo.append(int(lo))
    self.decerr_addr_hi.append(int(hi))

  def clear_decerr_ranges(self) -> None:
    self.decerr_addr_lo.clear()
    self.decerr_addr_hi.clear()

  def is_decerr_addr(self, addr: int) -> bool:
    a = int(addr)
    for lo, hi in zip(self.decerr_addr_lo, self.decerr_addr_hi):
      if lo <= a <= hi:
        return True
    return False

  def qos_to_class(self, axqos: int) -> int:
    idx = 15 if int(axqos) > 15 else int(axqos)
    q = int(self.qos_class_map[idx])
    return 0 if q < 0 else q

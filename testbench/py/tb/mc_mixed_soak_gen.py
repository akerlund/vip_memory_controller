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

from vip_mc_axi4_types_pkg import (
  VIP_MC_AXI4_BURST_FIXED_C,
  VIP_MC_AXI4_BURST_INCR_C,
  VIP_MC_AXI4_BURST_WRAP_C,
)

_LCG_MUL = 6364136223846793005
_LCG_INC = 1442695040888963407
_U64 = (1 << 64) - 1
_U32 = (1 << 32) - 1

AXI4_BASE_C = 0x0001_0000
CHI_BASE_C = 0x0002_0000


class mc_mixed_soak_txn:

  __slots__ = ("port_id", "is_write", "line", "addr", "axi_id", "qos",
               "gap_cycles", "payload", "burst", "beats", "size_bytes")

  def __init__(self):
    self.port_id = 0
    self.is_write = False
    self.line = 0
    self.addr = 0
    self.burst = VIP_MC_AXI4_BURST_INCR_C
    self.beats = 1
    self.size_bytes = 64
    self.axi_id = 0
    self.qos = 0
    self.gap_cycles = 0
    self.payload = []


def beat_addr(txn: mc_mixed_soak_txn, idx: int) -> int:
  """Return the byte address of an AXI4 beat for the generated burst."""
  if txn.burst == VIP_MC_AXI4_BURST_FIXED_C:
    return txn.addr
  if txn.burst == VIP_MC_AXI4_BURST_WRAP_C:
    total = txn.beats * txn.size_bytes
    base = txn.addr & ~(total - 1)
    return base + ((txn.addr - base + idx * txn.size_bytes) % total)
  return txn.addr + idx * txn.size_bytes


class mc_mixed_soak_gen:

  def __init__(self, line_bytes=64):
    self.line_count = 64
    self.line_bytes = int(line_bytes)
    self.qos_count = 16
    self.id_count = 4
    self.max_gap = 9
    self.incr_percent = 70
    self.wrap_percent = 15
    self._state = 1

  def set_seed(self, seed: int) -> None:
    self._state = int(seed) & _U64

  def _next_u32(self) -> int:
    self._state = ((self._state * _LCG_MUL) + _LCG_INC) & _U64
    return (self._state >> 32) & _U32

  def _next_below(self, n: int) -> int:
    if int(n) <= 1:
      return 0
    return self._next_u32() % int(n)

  # Keep this draw order identical to mc_mixed_soak_gen.sv.
  def next_txn(self, port_id: int):
    txn = mc_mixed_soak_txn()
    txn.port_id = int(port_id)
    txn.is_write = self._next_below(100) < 50

    if txn.port_id == 0:
      burst_sel = self._next_below(100)
      if burst_sel < self.incr_percent:
        txn.burst = VIP_MC_AXI4_BURST_INCR_C
      elif burst_sel < self.incr_percent + self.wrap_percent:
        txn.burst = VIP_MC_AXI4_BURST_WRAP_C
      else:
        txn.burst = VIP_MC_AXI4_BURST_FIXED_C

      size_log = self._next_below(self.line_bytes.bit_length())
      txn.size_bytes = 1 << size_log
      if txn.burst == VIP_MC_AXI4_BURST_WRAP_C:
        txn.beats = 2 << self._next_below(4)
      else:
        txn.beats = 1 + self._next_below(16)
    else:
      txn.burst = VIP_MC_AXI4_BURST_INCR_C
      txn.beats = 1
      txn.size_bytes = self.line_bytes

    txn.line = self._next_below(self.line_count)
    txn.axi_id = self._next_below(self.id_count)
    txn.qos = self._next_below(self.qos_count)
    txn.gap_cycles = self._next_below(self.max_gap)

    base = AXI4_BASE_C if txn.port_id == 0 else CHI_BASE_C
    line_offset = (
        self._next_below(self.line_bytes // txn.size_bytes) * txn.size_bytes
        if txn.port_id == 0 else 0)
    txn.addr = base + (txn.line * self.line_bytes) + line_offset

    total_bytes = txn.beats * txn.size_bytes
    if (txn.port_id == 0 and txn.burst != VIP_MC_AXI4_BURST_WRAP_C
        and (((txn.addr - AXI4_BASE_C) & 0xfff) + total_bytes > 4096)):
      txn.addr = base + ((txn.addr - base) & ~0xfff)

    if txn.is_write:
      txn.payload = [self._next_u32() & 0xff for _ in range(total_bytes)]
    else:
      txn.payload = []
    return txn

  def generate_program(self, count_per_port: int):
    axi_txns = []
    chi_txns = []
    for _ in range(int(count_per_port)):
      axi_txns.append(self.next_txn(0))
      chi_txns.append(self.next_txn(1))
    return axi_txns, chi_txns

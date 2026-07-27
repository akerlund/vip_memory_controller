################################################################################
##
## Copyright (C) 2026 Fredrik Åkerlund
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
#
# Python port of tb/mc_soak_gen.sv. This file and its SystemVerilog twin MUST
# stay byte-identical in behaviour: same LCG constants, same draw order, same
# fixups. That is the whole point - Python's `random` and SV's `$urandom` cannot
# be made to agree, so a solver-based generator would give the two flows
# different stimulus and a soak failure would reproduce in only one of them.
#
# If you change a draw here, change it in mc_soak_gen.sv in the same commit.
#
################################################################################

from __future__ import annotations

from vip_dram_addr_pkg import vip_dram_encode_addr
from vip_dram_types_pkg import VipDramDecT
from vip_mc_axi4_types_pkg import (
  VIP_MC_AXI4_BURST_FIXED_C, VIP_MC_AXI4_BURST_INCR_C,
  VIP_MC_AXI4_BURST_WRAP_C,
)

# MMIX Linear Congruential Generator (LCG). 64-bit state, output taken from the
# high half where the period is long; the low bits of a power-of-two-modulus
# LCG are notoriously short.
_LCG_MUL = 6364136223846793005
_LCG_INC = 1442695040888963407
_U64 = (1 << 64) - 1
_U32 = (1 << 32) - 1


class mc_soak_txn:
  """One generated transaction, fully resolved (no randomization left at drive
  time). Mirrors mc_soak_txn_t in mc_soak_gen.sv."""

  __slots__ = ("port_id", "is_write", "addr", "burst", "beats", "size_bytes",
               "axi_id", "qos", "gap_cycles", "payload")

  def __init__(self):
    self.port_id = 0
    self.is_write = False
    self.addr = 0
    self.burst = VIP_MC_AXI4_BURST_INCR_C
    self.beats = 1
    self.size_bytes = 1
    self.axi_id = 0
    self.qos = 0
    self.gap_cycles = 0
    self.payload = []


def beat_addr(t: mc_soak_txn, idx: int) -> int:
  """Address of beat `idx`. AXI4 burst arithmetic; shared by the driver (lane
  placement) and the golden model (byte placement), so the two can never
  disagree about where a beat landed."""
  if t.burst == VIP_MC_AXI4_BURST_FIXED_C:
    return t.addr
  if t.burst == VIP_MC_AXI4_BURST_WRAP_C:
    total = t.beats * t.size_bytes
    base = t.addr & ~(total - 1)
    return base + (((t.addr - base) + (idx * t.size_bytes)) % total)
  # INCR, per AXI4 A3.4.1: only the first beat sits at the start address; every
  # later beat is measured from the size-aligned address. next_txn() aligns every
  # start it generates, so the two coincide today - but vip_mc's front-end
  # implements the spec rule, and this model must agree with the front-end rather
  # than with the stimulus generator's own convenience if that alignment is ever
  # relaxed.
  if idx == 0:
    return t.addr
  return (t.addr - (t.addr % t.size_bytes)) + (idx * t.size_bytes)


class mc_soak_gen:

  def __init__(self, geom, addr_map):
    # Device geometry / map, handed over by the test so addresses are encoded
    # the way the device actually decodes them.
    self.geom = geom
    self.addr_map = addr_map

    self.n_ports = 2
    self.bus_bytes = 64
    self.rows_per_port = 8
    self.qos_max = 15
    # Share of draws that reuse one of the hot pages, which is what generates
    # page hits and bank conflicts rather than a uniform address sweep.
    self.hot_percent = 80
    self.hot_page_count = 4

    # Burst-type mix, in percent. INCR first, then WRAP, remainder FIXED. INCR
    # dominates because it is what real traffic looks like; WRAP and FIXED are
    # kept at a steady minority share so every run crosses both corners.
    self.incr_percent = 70
    self.wrap_percent = 15

    self._state = 1

  def set_seed(self, seed: int) -> None:
    """Seed the stream. Any 64-bit value works; the LCG has full period."""
    self._state = int(seed) & _U64

  def _next_u32(self) -> int:
    """Raw 32-bit draw. Every random decision below goes through this, so the
    draw order is the contract between the two flows."""
    self._state = ((self._state * _LCG_MUL) + _LCG_INC) & _U64
    return (self._state >> 32) & _U32

  def _next_below(self, n: int) -> int:
    """Uniform draw in [0, n). Modulo bias is irrelevant here - the ranges are
    all tiny next to 2^32, and reproducibility matters more than uniformity."""
    if n <= 1:
      return 0
    return self._next_u32() % n

  def _encode(self, row, bg, bank, col, byte_in_col) -> int:
    """Encode a device coordinate into a byte address through the live map."""
    dec = VipDramDecT()
    dec.rank = 0
    dec.row = row
    dec.bg = bg
    dec.bank = bank
    dec.col = col
    dec.byte_in_col = byte_in_col
    return vip_dram_encode_addr(dec, self.geom, self.addr_map)

  def next_txn(self) -> mc_soak_txn:
    """Generate one transaction. The draw order below is the cross-flow
    contract - mc_soak_gen.sv performs exactly these draws, in this sequence."""
    t = mc_soak_txn()

    # 1. port
    t.port_id = self._next_below(self.n_ports)

    # 2. direction
    t.is_write = self._next_below(100) < 50

    # 3. burst type: INCR dominant, WRAP and FIXED as the corners. One draw
    #    regardless of the mix, so changing the percentages does not shift the
    #    rest of the stream.
    burst_sel = self._next_below(100)
    if burst_sel < self.incr_percent:
      t.burst = VIP_MC_AXI4_BURST_INCR_C
    elif burst_sel < (self.incr_percent + self.wrap_percent):
      t.burst = VIP_MC_AXI4_BURST_WRAP_C
    else:
      t.burst = VIP_MC_AXI4_BURST_FIXED_C

    # 4. transfer size (bytes per beat), 1 .. bus width
    max_size_log = self.bus_bytes.bit_length() - 1
    size_log = self._next_below(max_size_log + 1)
    t.size_bytes = 1 << size_log

    # 5. beat count. WRAP is only legal at 2/4/8/16 beats.
    if t.burst == VIP_MC_AXI4_BURST_WRAP_C:
      wrap_sel = self._next_below(4)
      t.beats = 2 << wrap_sel
    else:
      t.beats = 1 + self._next_below(16)

    # 6. AXI4 id - a small pool so same-id ordering and inter-id reordering
    #    both get exercised
    t.axi_id = self._next_below(4)

    # 7. QoS across the full 4-bit field
    t.qos = self._next_below(self.qos_max + 1)

    # 8. inter-transaction gap: 0 saturates the port, 8 lets the queue drain
    t.gap_cycles = self._next_below(9)

    # 9. address. Each port owns a disjoint row range so the golden model never
    #    has to predict inter-port arbitration order.
    n_cols = 1 << self.geom.COL_BITS_P
    hot_sel = self._next_below(100)
    if hot_sel < self.hot_percent:
      # Hot page: a small recurring (row, bg, bank) set, column varying. This is
      # what produces page hits, bank conflicts and coalescable writes.
      row = (t.port_id * self.rows_per_port) + self._next_below(self.hot_page_count)
      bg = self._next_below(self.geom.N_BANK_GROUPS_P)
      bank = self._next_below(self.geom.BANKS_PER_BG_P)
    else:
      row = (t.port_id * self.rows_per_port) + self._next_below(self.rows_per_port)
      bg = self._next_below(self.geom.N_BANK_GROUPS_P)
      bank = self._next_below(self.geom.BANKS_PER_BG_P)
    col = self._next_below(n_cols)
    byte_in_col = self._next_below(self.bus_bytes)

    # Align the start down to the transfer size: every beat then stays inside
    # one bus lane window, which is what lets one strobe describe it.
    byte_in_col = byte_in_col & ~(t.size_bytes - 1)
    t.addr = self._encode(row, bg, bank, col, byte_in_col)
    t.addr = t.addr & ~(t.size_bytes - 1)

    total_bytes = t.beats * t.size_bytes

    # AXI4 forbids a burst crossing a 4 KB page. The stock vip_axi4 manager
    # enforces this with the FULL bus width per beat rather than 1 << axsize, so
    # a narrow burst is held to the same reservation - match that, or the
    # agent's randomize() fails on the pinned address. WRAP is exempt.
    if t.burst != VIP_MC_AXI4_BURST_WRAP_C:
      if ((t.addr & 0xFFF) + (t.beats * self.bus_bytes)) > 4096:
        t.addr = t.addr & ~0xFFF

    # 10. payload, one byte per written byte. Generated here (not at drive time)
    #     so the concurrent port drivers never draw.
    if t.is_write:
      t.payload = [self._next_u32() & 0xFF for _ in range(total_bytes)]
    else:
      t.payload = []

    return t

  def generate_program(self, count: int):
    """Generate the whole program up front. Single-threaded and deterministic;
    the test then splits it per port and replays the slices concurrently."""
    return [self.next_txn() for _ in range(int(count))]

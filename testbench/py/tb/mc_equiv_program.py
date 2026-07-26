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

from dataclasses import dataclass
from enum import IntEnum


class EqOp(IntEnum):
  WRITE_FULL = 0
  WRITE_PTL = 1
  READ = 2


@dataclass
class EqTxn:
  op: EqOp
  addr: int
  nbytes: int
  data: list[int]
  be: list[bool]


EQ_BASE_ADDR = 0x0000_8000
EQ_LINE_STRIDE = 0x0000_1000


def _make_full(addr: int, nbytes: int, start: int, step: int) -> EqTxn:
  data = [((int(start) + (int(step) * idx)) & 0xff) for idx in range(nbytes)]
  return EqTxn(EqOp.WRITE_FULL, int(addr), int(nbytes), data, [True] * nbytes)


def _make_ptl_lowhalf(addr: int, nbytes: int, value: int) -> EqTxn:
  data = [int(value) & 0xff for _ in range(nbytes)]
  be = [idx < (nbytes // 2) for idx in range(nbytes)]
  return EqTxn(EqOp.WRITE_PTL, int(addr), int(nbytes), data, be)


def _make_ptl_odd(addr: int, nbytes: int, value: int) -> EqTxn:
  data = [((int(value) + idx) & 0xff) for idx in range(nbytes)]
  be = [(idx % 2) == 1 for idx in range(nbytes)]
  return EqTxn(EqOp.WRITE_PTL, int(addr), int(nbytes), data, be)


def _make_read(addr: int, nbytes: int) -> EqTxn:
  return EqTxn(EqOp.READ, int(addr), int(nbytes), [], [])


def build_equiv_program(row_bytes: int):
  nb = int(row_bytes)
  q = []

  addr = EQ_BASE_ADDR + (0 * EQ_LINE_STRIDE)
  q.append(_make_full(addr, nb, 0x00, 0x01))
  q.append(_make_read(addr, nb))

  addr = EQ_BASE_ADDR + (1 * EQ_LINE_STRIDE)
  q.append(_make_full(addr, nb, 0x40, 0x01))
  q.append(_make_ptl_lowhalf(addr, nb, 0xee))
  q.append(_make_read(addr, nb))

  addr = EQ_BASE_ADDR + (2 * EQ_LINE_STRIDE)
  q.append(_make_full(addr, nb, 0x80, 0x03))
  q.append(_make_ptl_odd(addr, nb, 0x11))
  q.append(_make_read(addr, nb))

  addr = EQ_BASE_ADDR + (3 * EQ_LINE_STRIDE)
  q.append(_make_full(addr, nb, 0xc0, 0x07))
  q.append(_make_read(addr, nb))

  return q

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


class mc_equiv_model:

  def __init__(self):
    self.mem = {}

  def clear(self) -> None:
    self.mem.clear()

  def write(self, addr: int, data, be=None) -> None:
    be = [] if be is None else list(be)
    for idx, byte in enumerate(data):
      if idx >= len(be) or bool(be[idx]):
        self.mem[int(addr) + idx] = int(byte) & 0xff

  def expected(self, addr: int, nbytes: int):
    return [self.mem.get(int(addr) + idx, 0) for idx in range(int(nbytes))]

  def check_read(self, addr: int, got, ctx: str) -> bool:
    got = [int(byte) & 0xff for byte in got]
    exp = self.expected(addr, len(got))
    mismatches = [
        (idx, got_byte, exp_byte)
        for idx, (got_byte, exp_byte) in enumerate(zip(got, exp))
        if got_byte != exp_byte
    ]
    if mismatches:
      idx, got_byte, exp_byte = mismatches[0]
      raise AssertionError(
          f"{ctx}: read mismatch at addr 0x{int(addr):x} byte {idx}: "
          f"got 0x{got_byte:02x} expected 0x{exp_byte:02x}")
    return True

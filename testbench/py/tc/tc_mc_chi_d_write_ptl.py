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

from vip_chi_types_pkg import DataType
from mc_chi_base_test import CHI_PTL_ADDR_C, mc_chi_base_test


class tc_mc_chi_d_write_ptl(mc_chi_base_test):

  async def body(self):
    full_byte = 0xC3
    ptl_byte = 0x5A
    ptl_bytes = 8
    full_data = self.byte_replicate(full_byte)
    ptl_data = self.byte_replicate(ptl_byte)
    ptl_be = (1 << ptl_bytes) - 1

    await self.write_chi(
        CHI_PTL_ADDR_C, data_beats=[full_data], data_type=DataType.CUSTOM)
    await self.write_chi(
        CHI_PTL_ADDR_C, data_beats=[ptl_data], be_beats=[ptl_be],
        data_type=DataType.CUSTOM)
    rd = await self.read_chi(CHI_PTL_ADDR_C)

    assert len(rd) == 1 and len(rd[0].data) == 1
    word = int(rd[0].data[0])
    for i in range(64):
      got = (word >> (8 * i)) & 0xff
      exp = ptl_byte if i < ptl_bytes else full_byte
      assert got == exp, f"byte {i}: got 0x{got:02x} expected 0x{exp:02x}"

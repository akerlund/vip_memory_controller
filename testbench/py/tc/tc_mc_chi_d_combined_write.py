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

from vip_chi_types_pkg import DataType, RespErr
from mc_chi_base_test import CHI_COMBINED_ADDR_C, mc_chi_base_test


class tc_mc_chi_d_combined_write(mc_chi_base_test):

  SPLIT_WRITE_RSP = False

  async def body(self):
    wdata = self.byte_replicate(0x3C)
    wr = await self.write_chi(
        CHI_COMBINED_ADDR_C, data_beats=[wdata], data_type=DataType.CUSTOM)
    assert len(wr) == 1
    assert int(wr[0].rsp_resp_err) == int(RespErr.OKAY)

    rd = await self.read_chi(CHI_COMBINED_ADDR_C)
    assert len(rd) == 1 and len(rd[0].data) == 1
    assert int(rd[0].data[0]) == wdata

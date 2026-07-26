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

from vip_chi_types_pkg import ChiCfg, DataType, Issue
from vip_dram_types_pkg import VIP_DRAM_CFG_DEFAULT
from mc_chi_base_test import CHI_ZERO_ADDR_C, mc_chi_base_test
from vip_mc_types_pkg import VipMcChiCfgT, VipMcChiIssue


class tc_mc_chi_e_write_zero(mc_chi_base_test):

  CHI_CFG = ChiCfg(
      issue=Issue.E, node_id_width=11,
      addr_width=VIP_DRAM_CFG_DEFAULT.ADDR_WIDTH_P,
      data_bytes=VIP_DRAM_CFG_DEFAULT.ROW_BYTES_P)
  MC_CHI_CFG = VipMcChiCfgT(
      issue=VipMcChiIssue.E, NODE_ID_WIDTH_P=11,
      ADDR_WIDTH_P=VIP_DRAM_CFG_DEFAULT.ADDR_WIDTH_P,
      DATA_BYTES_P=VIP_DRAM_CFG_DEFAULT.ROW_BYTES_P)

  async def body(self):
    fe = self.get_chi_fe()
    await self.write_chi(
        CHI_ZERO_ADDR_C, data_type=DataType.COUNTER,
        counter_value=0x11, counter_increment=1)
    seed = await self.read_chi(CHI_ZERO_ADDR_C)
    assert len(seed) == 1 and int(seed[0].data[0]) != 0

    writes_before = fe.get_write_count()
    await self.write_zero_chi(CHI_ZERO_ADDR_C)
    rd = await self.read_chi(CHI_ZERO_ADDR_C)

    assert len(rd) == 1 and len(rd[0].data) == 1
    assert int(rd[0].data[0]) == 0
    assert fe.get_write_count() == writes_before + 1

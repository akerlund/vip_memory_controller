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

from vip_chi_types_pkg import ChiCfg, DataType, Issue, RespErr
from vip_dram_types_pkg import VIP_DRAM_CFG_DEFAULT
from mc_chi_base_test import mc_chi_base_test
from mc_equiv_model import mc_equiv_model
from mc_equiv_program import EqOp, build_equiv_program
from vip_mc_types_pkg import VipMcChiCfgT, VipMcChiIssue


class mc_equiv_chi_base_test(mc_chi_base_test):

  @staticmethod
  def bytes_to_int(data) -> int:
    value = 0
    for idx, byte in enumerate(data):
      value |= (int(byte) & 0xff) << (8 * idx)
    return value

  @staticmethod
  def be_to_int(be) -> int:
    value = 0
    for idx, enable in enumerate(be):
      if bool(enable):
        value |= 1 << idx
    return value

  @staticmethod
  def int_to_bytes(value: int, nbytes: int):
    return [
        (int(value) >> (8 * idx)) & 0xff
        for idx in range(int(nbytes))
    ]

  @staticmethod
  def size_from_bytes(nbytes: int) -> int:
    return (int(nbytes) - 1).bit_length()

  async def body(self):
    model = mc_equiv_model()
    model.clear()
    program = build_equiv_program(self.DRAM_GEOM.ROW_BYTES_P)

    for txn in program:
      size = self.size_from_bytes(txn.nbytes)
      if txn.op == EqOp.READ:
        readback = await self.read_chi(txn.addr, size=size)
        assert len(readback) == 1
        assert len(readback[0].data) == 1
        assert int(readback[0].dat_resp_err[0]) == int(RespErr.OKAY)
        got = self.int_to_bytes(readback[0].data[0], txn.nbytes)
        assert model.check_read(txn.addr, got, "chi")
      else:
        data = self.bytes_to_int(txn.data)
        be = self.be_to_int(txn.be)
        be_beats = [be] if txn.op == EqOp.WRITE_PTL else None
        responses = await self.write_chi(
            txn.addr, data_beats=[data], be_beats=be_beats, size=size,
            data_type=DataType.CUSTOM)
        assert len(responses) == 1
        assert int(responses[0].rsp_resp_err) == int(RespErr.OKAY)
        model.write(txn.addr, txn.data, txn.be)


class tc_mc_equiv_chi_d(mc_equiv_chi_base_test):
  pass


class tc_mc_equiv_chi_e(mc_equiv_chi_base_test):

  CHI_CFG = ChiCfg(
      issue=Issue.E, node_id_width=11,
      addr_width=VIP_DRAM_CFG_DEFAULT.ADDR_WIDTH_P,
      data_bytes=VIP_DRAM_CFG_DEFAULT.ROW_BYTES_P)
  MC_CHI_CFG = VipMcChiCfgT(
      issue=VipMcChiIssue.E, NODE_ID_WIDTH_P=11,
      ADDR_WIDTH_P=VIP_DRAM_CFG_DEFAULT.ADDR_WIDTH_P,
      DATA_BYTES_P=VIP_DRAM_CFG_DEFAULT.ROW_BYTES_P)

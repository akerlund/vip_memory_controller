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

from vip_chi_raw_seq import vip_chi_raw_seq
from vip_chi_types_pkg import ReqOpcode, RespErr, RspOpcode
from mc_chi_base_test import CHI_WRITE_READ_ADDR_C, mc_chi_base_test


class tc_mc_chi_d_persist(mc_chi_base_test):

  async def body(self):
    fe = self.get_chi_fe()
    issued_before = int(fe.issued_req_count)
    self.env.clear_rni_observations()

    await self._send_raw_persist(ReqOpcode.CLEAN_SHARED_PERSIST, 0x5,
                                 "raw_persist")
    await self.rni_vif.clocks(20)
    await self._send_raw_persist(ReqOpcode.CLEAN_SHARED_PERSIST_SEP, 0x6,
                                 "raw_persist_sep")
    await self.rni_vif.clocks(20)

    assert fe.get_persist_count() == 2
    assert fe.get_unsupported_count() == 0
    assert int(fe.issued_req_count) == issued_before

    assert self._rsp_seen(0x5, RspOpcode.COMP, RespErr.OKAY)
    assert self._rsp_seen(0, RspOpcode.PERSIST, RespErr.OKAY)
    assert self._rsp_seen(0x6, RspOpcode.COMP_PERSIST, RespErr.OKAY)

  async def _send_raw_persist(self, opcode, txn_id: int, name: str) -> None:
    seq = vip_chi_raw_seq(name, cfg=self.CHI_CFG)
    seq.set_get_response(False)
    seq.add_raw_req({
        "opcode": int(opcode),
        "addr": CHI_WRITE_READ_ADDR_C,
        "size": 6,
        "txnid": int(txn_id),
        "srcid": 1,
        "allowretry": 1,
    })
    await self.start_seq_or_timeout(seq)

  def _rsp_seen(self, txn_id: int, opcode, resp_err) -> bool:
    return any(
        int(rsp.txn_id) == int(txn_id) and
        int(rsp.rsp_opcode) == int(opcode) and
        int(rsp.rsp_resp_err) == int(resp_err)
        for rsp in self.env.rni_rsp_observations)

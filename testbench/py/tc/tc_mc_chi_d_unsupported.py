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


class tc_mc_chi_d_unsupported(mc_chi_base_test):

  async def body(self):
    fe = self.get_chi_fe()
    issued_before = int(fe.issued_req_count)
    self.env.clear_rni_observations()

    seq = vip_chi_raw_seq("raw_seq", cfg=self.CHI_CFG)
    seq.set_get_response(False)
    seq.add_raw_req({
        "opcode": int(ReqOpcode.ATOMIC_STORE_0),
        "addr": CHI_WRITE_READ_ADDR_C,
        "size": 3,
        "txnid": 0x7,
        "srcid": 1,
        "tgtid": 0,
        "qos": 0,
        "allowretry": 1,
    })
    await self.start_seq_or_timeout(seq)
    await self.rni_vif.clocks(20)

    assert fe.get_unsupported_count() == 1
    assert int(fe.issued_req_count) == issued_before
    assert self._comp_nderr_count(0x7) == 1

  def _comp_nderr_count(self, txn_id: int) -> int:
    return sum(
        1 for rsp in self.env.rni_rsp_observations
        if int(rsp.txn_id) == int(txn_id) and
        int(rsp.rsp_opcode) == int(RspOpcode.COMP) and
        int(rsp.rsp_resp_err) == int(RespErr.NDERR))

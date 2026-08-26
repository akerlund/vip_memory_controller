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
from vip_chi_types_pkg import DatOpcode, ReqOpcode, RespErr, RspOpcode
from mc_chi_base_test import CHI_WRITE_READ_ADDR_C, mc_chi_base_test


class tc_mc_chi_d_reject(mc_chi_base_test):

  async def body(self):
    fe = self.get_chi_fe()
    # The MC CHI bus is one 64-byte DAT beat wide, while AtomicCompare's
    # conformant maximum operand is 32 bytes. The checker deliberately models
    # that half-operand corner using a narrower bus; waive only its derived
    # TXSACTIVE tail rule for this rejection-only test, keeping all field,
    # completion, and atomic-form checks enabled.
    for checker in (self.env.rni_sva, self.env.mc_snf_sva):
      checker.off_check("CHI_TXSACTIVE_COVERS_OUTSTANDING")
    issued_before = int(fe.issued_req_count)
    unsup_before = int(fe.get_unsupported_count())
    self.env.clear_rni_observations()

    ops = [
        ReqOpcode.ATOMIC_STORE_0,
        ReqOpcode.ATOMIC_LOAD_0,
        ReqOpcode.ATOMIC_SWAP,
        ReqOpcode.ATOMIC_COMPARE,
    ]
    for idx, opcode in enumerate(ops):
      seq = vip_chi_raw_seq(f"raw_atomic_{idx}", cfg=self.CHI_CFG)
      seq.set_get_response(False)
      seq.add_raw_req({
          "opcode": int(opcode),
          "addr": CHI_WRITE_READ_ADDR_C,
          "size": 4 if opcode == ReqOpcode.ATOMIC_COMPARE else 3,
          "txnid": 0x10 + idx,
          "srcid": 1,
          "allowretry": 1,
      })
      await self.start_seq_or_timeout(seq)
      await self.rni_vif.clocks(20)

    assert fe.get_unsupported_count() == unsup_before + len(ops)
    assert fe.get_persist_count() == 0
    assert int(fe.issued_req_count) == issued_before

    seen_rsp = {
        int(rsp.txn_id)
        for rsp in self.env.rni_rsp_observations
        if int(rsp.rsp_opcode) == int(RspOpcode.COMP) and
        int(rsp.rsp_resp_err) == int(RespErr.NDERR)
    }
    seen_dat = {
        int(dat.txn_id)
        for dat in self.env.rni_dat_observations
        if int(dat.dat_opcode) == int(DatOpcode.COMP_DATA) and
        int(dat.dat_resp_err[0]) == int(RespErr.NDERR)
    }
    assert 0x10 in seen_rsp
    for idx in range(1, len(ops)):
      assert (0x10 + idx) in seen_dat

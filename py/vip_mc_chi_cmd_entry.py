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
## Description:
## CHI-specialized command entry matching vip_mc/sv/vip_mc_chi_cmd_entry.sv.
##
################################################################################

from __future__ import annotations

from vip_mc_cmd_entry import vip_mc_cmd_entry


class vip_mc_chi_cmd_entry(vip_mc_cmd_entry):

  def __init__(self, name="vip_mc_chi_cmd_entry"):
    super().__init__(name)

    self.chi_srcid = 0
    self.chi_tgtid = 0
    self.chi_txnid = 0
    self.chi_dbid = 0
    self.chi_return_nid = 0
    self.chi_return_txn = 0
    self.chi_qos = 0

    self.chi_is_write = False
    self.chi_is_write_zero = False
    self.chi_is_sep_read = False
    self.chi_needs_receipt = False
    self.chi_split_write_rsp = False
    self.chi_exp_comp_ack = False
    self.chi_resp_err = 0

    self.chi_wr_beats_seen = 0
    self.chi_dat_beats = 1
    self.chi_size_bytes = 1

  def clone(self, name=None):
    c = vip_mc_chi_cmd_entry(name or self.name)
    c.do_copy(self)
    return c

  def do_copy(self, rhs) -> None:
    super().do_copy(rhs)
    self.chi_srcid = rhs.chi_srcid
    self.chi_tgtid = rhs.chi_tgtid
    self.chi_txnid = rhs.chi_txnid
    self.chi_dbid = rhs.chi_dbid
    self.chi_return_nid = rhs.chi_return_nid
    self.chi_return_txn = rhs.chi_return_txn
    self.chi_qos = rhs.chi_qos
    self.chi_is_write = rhs.chi_is_write
    self.chi_is_write_zero = rhs.chi_is_write_zero
    self.chi_is_sep_read = rhs.chi_is_sep_read
    self.chi_needs_receipt = rhs.chi_needs_receipt
    self.chi_split_write_rsp = rhs.chi_split_write_rsp
    self.chi_exp_comp_ack = rhs.chi_exp_comp_ack
    self.chi_resp_err = rhs.chi_resp_err
    self.chi_wr_beats_seen = rhs.chi_wr_beats_seen
    self.chi_dat_beats = rhs.chi_dat_beats
    self.chi_size_bytes = rhs.chi_size_bytes

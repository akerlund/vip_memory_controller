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
## pyUVM port of vip_mc/sv/vip_mc_chi_cfg.sv.
##
################################################################################

from __future__ import annotations

import warnings


CHI_LCRD_MAX_C = 15


class vip_mc_chi_cfg:

  def __init__(self, name="vip_mc_chi_cfg"):
    self.name = name
    self.sn_node_id = 0
    # Fifteen is the CHI protocol maximum. Keep the knobs open above that
    # value so a negative-control test can model a broken peer and prove the
    # checker catches it.
    self.initial_req_credits = 15
    self.initial_rsp_credits = 15
    self.initial_dat_credits = 15
    self.split_write_rsp = True

  def validate(self) -> None:
    if self.initial_req_credits < 1:
      raise RuntimeError(
          f"[{self.name}] initial_req_credits must be >= 1 "
          f"(got {self.initial_req_credits})")
    if self.initial_rsp_credits < 1:
      raise RuntimeError(
          f"[{self.name}] initial_rsp_credits must be >= 1 "
          f"(got {self.initial_rsp_credits})")
    if self.initial_dat_credits < 1:
      raise RuntimeError(
          f"[{self.name}] initial_dat_credits must be >= 1 "
          f"(got {self.initial_dat_credits})")
    # Keep values above the CHI maximum representable for negative-control
    # tests. Normal configurations use the protocol-max default of 15.
    for field_name in ("initial_req_credits", "initial_rsp_credits",
                       "initial_dat_credits"):
      value = int(getattr(self, field_name))
      if value > CHI_LCRD_MAX_C:
        warnings.warn(
            f"[{self.name}] {field_name} ({value}) exceeds the CHI maximum "
            f"of {CHI_LCRD_MAX_C}; retained for checker-negative testing",
            RuntimeWarning, stacklevel=2)

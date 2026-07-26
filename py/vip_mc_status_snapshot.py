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
## pyUVM port of vip_mc/sv/vip_mc_status_snapshot.sv.
##
################################################################################

from __future__ import annotations

LAT_HIST_MAX_BUCKET_C = 24

from vip_mc_types_pkg import (
  VipMcStatusFeBlock, VipMcStatusOp, VipMcStatusPage, VipMcStatusReject,
  VipMcStatusRsp, VipMcStatusStall,
)


def latency_bucket(lat_ns: float) -> int:
  bucket = 0
  value = float(lat_ns)
  if value < 1.0:
    return 0
  while value >= 2.0 and bucket < LAT_HIST_MAX_BUCKET_C:
    value /= 2.0
    bucket += 1
  return bucket


class vip_mc_status_snapshot:

  def __init__(self, name="vip_mc_status_snapshot", n_ports=1):
    self.name = name
    self.n_ports = n_ports
    self.clear()

  def clear(self) -> None:
    self.rst_active = False
    self.cmd_queue_depth = 0
    self.cmd_queue_peak_depth = 0
    self.inflight_to_device = 0
    self.rsp_buf_used = 0
    self.rsp_buf_full = False
    self.device_issue_credit_avail = True
    self.backend_stall_reason = VipMcStatusStall.NONE
    self.refresh_count = 0

    self.issue_port_id = 0
    self.issue_tag = 0
    self.issue_op = VipMcStatusOp.NONE
    self.issue_qos_class = 0
    self.issue_pre_resolved = False

    self.complete_port_id = 0
    self.complete_tag = 0
    self.complete_op = VipMcStatusOp.NONE
    self.complete_resp = VipMcStatusRsp.NONE
    self.complete_page = VipMcStatusPage.UNKNOWN
    self.complete_pre_resolved = False

    self.refresh_emit_rank = 0

    self.local_reject_port_id = 0
    self.local_reject_op = VipMcStatusOp.NONE
    self.local_reject_reason = VipMcStatusReject.NONE

    self.rd_outstanding_count = [0] * self.n_ports
    self.wr_outstanding_count = [0] * self.n_ports
    self.aw_pending_depth = [0] * self.n_ports
    self.pending_b_depth = [0] * self.n_ports
    self.pending_r_depth = [0] * self.n_ports
    self.active_r_slots_used = [0] * self.n_ports
    self.w_data_buf_occupancy = [0] * self.n_ports
    self.aw_block_reason = [VipMcStatusFeBlock.NONE] * self.n_ports
    self.ar_block_reason = [VipMcStatusFeBlock.NONE] * self.n_ports
    self.w_block_reason = [VipMcStatusFeBlock.NONE] * self.n_ports
    self.clear_pulses()

  def clear_pulses(self) -> None:
    self.issue_pulse = False
    self.complete_pulse = False
    self.refresh_emit_pulse = False
    self.local_reject_pulse = False

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
## Python mirror object for vip_mc/sv/vip_mc_status_if.sv.
##
################################################################################

from __future__ import annotations

from vip_mc_status_snapshot import vip_mc_status_snapshot


class vip_mc_status_if:

  def __init__(self, name="vip_mc_status_if", n_ports=1):
    self.name = name
    self.n_ports = int(n_ports)
    self.clear()

  def clear(self) -> None:
    self.drive_from_snapshot(vip_mc_status_snapshot(
        f"{self.name}_clear_snapshot", self.n_ports))

  def drive_from_snapshot(self, snapshot) -> None:
    self.rst_active = bool(snapshot.rst_active)
    self.cmd_queue_depth = int(snapshot.cmd_queue_depth)
    self.cmd_queue_peak_depth = int(snapshot.cmd_queue_peak_depth)
    self.inflight_to_device = int(snapshot.inflight_to_device)
    self.rsp_buf_used = int(snapshot.rsp_buf_used)
    self.rsp_buf_full = bool(snapshot.rsp_buf_full)
    self.device_issue_credit_avail = bool(snapshot.device_issue_credit_avail)
    self.backend_stall_reason = snapshot.backend_stall_reason
    self.refresh_count = int(snapshot.refresh_count)

    self.issue_pulse = bool(snapshot.issue_pulse)
    self.issue_port_id = int(snapshot.issue_port_id)
    self.issue_tag = int(snapshot.issue_tag)
    self.issue_op = snapshot.issue_op
    self.issue_qos_class = int(snapshot.issue_qos_class)
    self.issue_pre_resolved = bool(snapshot.issue_pre_resolved)

    self.complete_pulse = bool(snapshot.complete_pulse)
    self.complete_port_id = int(snapshot.complete_port_id)
    self.complete_tag = int(snapshot.complete_tag)
    self.complete_op = snapshot.complete_op
    self.complete_resp = snapshot.complete_resp
    self.complete_page = snapshot.complete_page
    self.complete_pre_resolved = bool(snapshot.complete_pre_resolved)

    self.refresh_emit_pulse = bool(snapshot.refresh_emit_pulse)
    self.refresh_emit_rank = int(snapshot.refresh_emit_rank)

    self.local_reject_pulse = bool(snapshot.local_reject_pulse)
    self.local_reject_port_id = int(snapshot.local_reject_port_id)
    self.local_reject_op = snapshot.local_reject_op
    self.local_reject_reason = snapshot.local_reject_reason

    self.rd_outstanding_count = list(snapshot.rd_outstanding_count)
    self.wr_outstanding_count = list(snapshot.wr_outstanding_count)
    self.aw_pending_depth = list(snapshot.aw_pending_depth)
    self.pending_b_depth = list(snapshot.pending_b_depth)
    self.pending_r_depth = list(snapshot.pending_r_depth)
    self.active_r_slots_used = list(snapshot.active_r_slots_used)
    self.w_data_buf_occupancy = list(snapshot.w_data_buf_occupancy)
    self.aw_block_reason = list(snapshot.aw_block_reason)
    self.ar_block_reason = list(snapshot.ar_block_reason)
    self.w_block_reason = list(snapshot.w_block_reason)

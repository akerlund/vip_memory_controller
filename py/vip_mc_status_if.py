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
from vip_mc_types_pkg import (
  VipMcStatusFeBlock,
  VipMcStatusOp,
  VipMcStatusPage,
  VipMcStatusReject,
  VipMcStatusRsp,
  VipMcStatusStall,
)


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
    self.decode_status_fields()

  # ---------------------------------------------------------------------------
  # Keep Python-side helpers aligned with vip_mc_status_if.sv wave decodes.
  # ---------------------------------------------------------------------------
  def decode_status_fields(self) -> None:
    self.issue_op_rd = self.issue_op == VipMcStatusOp.RD
    self.issue_op_wr = self.issue_op == VipMcStatusOp.WR
    self.issue_op_ref = self.issue_op == VipMcStatusOp.REF

    self.complete_op_rd = self.complete_op == VipMcStatusOp.RD
    self.complete_op_wr = self.complete_op == VipMcStatusOp.WR
    self.complete_op_ref = self.complete_op == VipMcStatusOp.REF

    self.complete_resp_okay = self.complete_resp == VipMcStatusRsp.OKAY
    self.complete_resp_exokay = self.complete_resp == VipMcStatusRsp.EXOKAY
    self.complete_resp_slverr = self.complete_resp == VipMcStatusRsp.SLVERR
    self.complete_resp_decerr = self.complete_resp == VipMcStatusRsp.DECERR

    self.complete_page_unknown = self.complete_page == VipMcStatusPage.UNKNOWN
    self.complete_page_hit = self.complete_page == VipMcStatusPage.HIT
    self.complete_page_miss = self.complete_page == VipMcStatusPage.MISS
    self.complete_page_empty = self.complete_page == VipMcStatusPage.EMPTY

    self.backend_stall_none = (
        self.backend_stall_reason == VipMcStatusStall.NONE)
    self.backend_stall_in_reset = (
        self.backend_stall_reason == VipMcStatusStall.IN_RESET)
    self.backend_stall_no_buffered_input = (
        self.backend_stall_reason == VipMcStatusStall.NO_BUFFERED_INPUT)
    self.backend_stall_cmd_queue_empty = (
        self.backend_stall_reason == VipMcStatusStall.CMD_QUEUE_EMPTY)
    self.backend_stall_same_stream_blocked = (
        self.backend_stall_reason == VipMcStatusStall.SAME_STREAM_BLOCKED)
    self.backend_stall_device_credit_full = (
        self.backend_stall_reason == VipMcStatusStall.DEVICE_CREDIT_FULL)
    self.backend_stall_rsp_buffer_full = (
        self.backend_stall_reason == VipMcStatusStall.RSP_BUFFER_FULL)
    self.backend_stall_ref_strict_priority = (
        self.backend_stall_reason == VipMcStatusStall.REF_STRICT_PRIORITY)

    self.local_reject_decerr_region = (
        self.local_reject_reason == VipMcStatusReject.DECERR_REGION)
    self.local_reject_decerr_4k = (
        self.local_reject_reason == VipMcStatusReject.DECERR_4K)
    self.local_reject_decerr_row_span = (
        self.local_reject_reason == VipMcStatusReject.DECERR_ROW_SPAN)
    self.local_reject_unsupported_axi_shape = (
        self.local_reject_reason == VipMcStatusReject.UNSUPPORTED_AXI_SHAPE)
    self.local_reject_exclusive_fail_local = (
        self.local_reject_reason == VipMcStatusReject.EXCLUSIVE_FAIL_LOCAL)
    self.local_reject_slverr_local = (
        self.local_reject_reason == VipMcStatusReject.SLVERR_LOCAL)

    self.aw_blocked = [
        reason != VipMcStatusFeBlock.NONE for reason in self.aw_block_reason]
    self.ar_blocked = [
        reason != VipMcStatusFeBlock.NONE for reason in self.ar_block_reason]
    self.w_blocked = [
        reason != VipMcStatusFeBlock.NONE for reason in self.w_block_reason]

    self.aw_blocked_rsp_buf_full = [
        reason == VipMcStatusFeBlock.RSP_BUF_FULL
        for reason in self.aw_block_reason]
    self.ar_blocked_rsp_buf_full = [
        reason == VipMcStatusFeBlock.RSP_BUF_FULL
        for reason in self.ar_block_reason]
    self.aw_blocked_outstanding_full = [
        reason == VipMcStatusFeBlock.AW_OUTSTANDING_FULL
        for reason in self.aw_block_reason]
    self.ar_blocked_outstanding_full = [
        reason == VipMcStatusFeBlock.AR_OUTSTANDING_FULL
        for reason in self.ar_block_reason]
    self.aw_blocked_pending_full = [
        reason == VipMcStatusFeBlock.AW_PENDING_FULL
        for reason in self.aw_block_reason]
    self.w_blocked_wbuf_full = [
        reason == VipMcStatusFeBlock.WBUF_FULL
        for reason in self.w_block_reason]
    self.w_blocked_no_write_in_flight = [
        reason == VipMcStatusFeBlock.NO_WRITE_IN_FLIGHT
        for reason in self.w_block_reason]

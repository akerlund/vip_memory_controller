////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2026 Fredrik Åkerlund
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
////////////////////////////////////////////////////////////////////////////////

// -----------------------------------------------------------------------------
// vip_mc_status_if
//
// Optional debug-only waveform probe for vip_mc. This interface is not part of
// the functional host/device contract; it exists solely so vip_mc can mirror a
// controller-global status snapshot into waves from exactly one publisher.
// -----------------------------------------------------------------------------

`ifndef VIP_MC_STATUS_IF
`define VIP_MC_STATUS_IF

import vip_mc_types_pkg::*;

interface vip_mc_status_if #(
  parameter int N_PORTS = 1
  )(
    input clk,
    input rst_n
  );

  bit                   rst_active;
  int unsigned          cmd_queue_depth;
  int unsigned          cmd_queue_peak_depth;
  int unsigned          inflight_to_device;
  int unsigned          rsp_buf_used;
  bit                   rsp_buf_full;
  bit                   device_issue_credit_avail;
  vip_mc_status_stall_e backend_stall_reason;
  int unsigned          refresh_count;

  bit                   issue_pulse;
  int unsigned          issue_port_id;
  longint unsigned      issue_tag;
  vip_mc_status_op_e    issue_op;
  int unsigned          issue_qos_class;
  bit                   issue_pre_resolved;

  bit                   complete_pulse;
  int unsigned          complete_port_id;
  longint unsigned      complete_tag;
  vip_mc_status_op_e    complete_op;
  vip_mc_status_rsp_e   complete_resp;
  vip_mc_status_page_e  complete_page;
  bit                   complete_pre_resolved;

  bit                   refresh_emit_pulse;
  int unsigned          refresh_emit_rank;

  bit                   local_reject_pulse;
  int unsigned          local_reject_port_id;
  vip_mc_status_op_e    local_reject_op;
  vip_mc_status_reject_e local_reject_reason;

  int unsigned             rd_outstanding_count [N_PORTS];
  int unsigned             wr_outstanding_count [N_PORTS];
  int unsigned             aw_pending_depth     [N_PORTS];
  int unsigned             pending_b_depth      [N_PORTS];
  int unsigned             pending_r_depth      [N_PORTS];
  int unsigned             active_r_slots_used  [N_PORTS];
  int unsigned             w_data_buf_occupancy [N_PORTS];
  vip_mc_status_fe_block_e aw_block_reason      [N_PORTS];
  vip_mc_status_fe_block_e ar_block_reason      [N_PORTS];
  vip_mc_status_fe_block_e w_block_reason       [N_PORTS];

endinterface

`endif
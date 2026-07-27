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

  // ---------------------------------------------------------------------------
  // Waveform-friendly decodes. GTKWave shows Verilator VCD enum fields as integer
  // values, so these one-bit mirrors make the common status states visible.
  // ---------------------------------------------------------------------------

  wire issue_op_rd  = (issue_op == VIP_MC_STATUS_OP_RD_E);
  wire issue_op_wr  = (issue_op == VIP_MC_STATUS_OP_WR_E);
  wire issue_op_ref = (issue_op == VIP_MC_STATUS_OP_REF_E);

  wire complete_op_rd  = (complete_op == VIP_MC_STATUS_OP_RD_E);
  wire complete_op_wr  = (complete_op == VIP_MC_STATUS_OP_WR_E);
  wire complete_op_ref = (complete_op == VIP_MC_STATUS_OP_REF_E);

  wire complete_resp_okay   = (complete_resp == VIP_MC_STATUS_RSP_OKAY_E);
  wire complete_resp_exokay = (complete_resp == VIP_MC_STATUS_RSP_EXOKAY_E);
  wire complete_resp_slverr = (complete_resp == VIP_MC_STATUS_RSP_SLVERR_E);
  wire complete_resp_decerr = (complete_resp == VIP_MC_STATUS_RSP_DECERR_E);

  wire complete_page_unknown = (complete_page == VIP_MC_STATUS_PAGE_UNKNOWN_E);
  wire complete_page_hit     = (complete_page == VIP_MC_STATUS_PAGE_HIT_E);
  wire complete_page_miss    = (complete_page == VIP_MC_STATUS_PAGE_MISS_E);
  wire complete_page_empty   = (complete_page == VIP_MC_STATUS_PAGE_EMPTY_E);

  wire backend_stall_none =
    (backend_stall_reason == VIP_MC_STATUS_STALL_NONE_E);
  wire backend_stall_in_reset =
    (backend_stall_reason == VIP_MC_STATUS_STALL_IN_RESET_E);
  wire backend_stall_no_buffered_input =
    (backend_stall_reason == VIP_MC_STATUS_STALL_NO_BUFFERED_INPUT_E);
  wire backend_stall_cmd_queue_empty =
    (backend_stall_reason == VIP_MC_STATUS_STALL_CMD_QUEUE_EMPTY_E);
  wire backend_stall_same_stream_blocked =
    (backend_stall_reason == VIP_MC_STATUS_STALL_SAME_STREAM_BLOCKED_E);
  wire backend_stall_device_credit_full =
    (backend_stall_reason == VIP_MC_STATUS_STALL_DEVICE_CREDIT_FULL_E);
  wire backend_stall_rsp_buffer_full =
    (backend_stall_reason == VIP_MC_STATUS_STALL_RSP_BUFFER_FULL_E);
  wire backend_stall_ref_strict_priority =
    (backend_stall_reason == VIP_MC_STATUS_STALL_REF_STRICT_PRIORITY_E);

  wire local_reject_decerr_region =
    (local_reject_reason == VIP_MC_STATUS_REJECT_DECERR_REGION_E);
  wire local_reject_decerr_4k =
    (local_reject_reason == VIP_MC_STATUS_REJECT_DECERR_4K_E);
  wire local_reject_decerr_row_span =
    (local_reject_reason == VIP_MC_STATUS_REJECT_DECERR_ROW_SPAN_E);
  wire local_reject_unsupported_axi_shape =
    (local_reject_reason == VIP_MC_STATUS_REJECT_UNSUPPORTED_AXI_SHAPE_E);
  wire local_reject_exclusive_fail_local =
    (local_reject_reason == VIP_MC_STATUS_REJECT_EXCLUSIVE_FAIL_LOCAL_E);
  wire local_reject_slverr_local =
    (local_reject_reason == VIP_MC_STATUS_REJECT_SLVERR_LOCAL_E);

  wire aw_blocked [N_PORTS];
  wire ar_blocked [N_PORTS];
  wire w_blocked  [N_PORTS];

  wire aw_blocked_rsp_buf_full      [N_PORTS];
  wire ar_blocked_rsp_buf_full      [N_PORTS];
  wire aw_blocked_outstanding_full  [N_PORTS];
  wire ar_blocked_outstanding_full  [N_PORTS];
  wire aw_blocked_pending_full      [N_PORTS];
  wire w_blocked_wbuf_full          [N_PORTS];
  wire w_blocked_no_write_in_flight [N_PORTS];

  for (genvar port_id = 0; port_id < N_PORTS; port_id++) begin : gen_status_decode

    assign aw_blocked[port_id] =
    (aw_block_reason[port_id] != VIP_MC_STATUS_FE_BLOCK_NONE_E);

    assign ar_blocked[port_id] =
    (ar_block_reason[port_id] != VIP_MC_STATUS_FE_BLOCK_NONE_E);

    assign w_blocked[port_id] =
    (w_block_reason[port_id] != VIP_MC_STATUS_FE_BLOCK_NONE_E);


    assign aw_blocked_rsp_buf_full[port_id] =
    (aw_block_reason[port_id] == VIP_MC_STATUS_FE_BLOCK_RSP_BUF_FULL_E);

    assign ar_blocked_rsp_buf_full[port_id] =
    (ar_block_reason[port_id] == VIP_MC_STATUS_FE_BLOCK_RSP_BUF_FULL_E);

    assign aw_blocked_outstanding_full[port_id] =
    (aw_block_reason[port_id] == VIP_MC_STATUS_FE_BLOCK_AW_OUTSTANDING_FULL_E);

    assign ar_blocked_outstanding_full[port_id] =
    (ar_block_reason[port_id] == VIP_MC_STATUS_FE_BLOCK_AR_OUTSTANDING_FULL_E);

    assign aw_blocked_pending_full[port_id] =
    (aw_block_reason[port_id] == VIP_MC_STATUS_FE_BLOCK_AW_PENDING_FULL_E);

    assign w_blocked_wbuf_full[port_id] =
    (w_block_reason[port_id] == VIP_MC_STATUS_FE_BLOCK_WBUF_FULL_E);

    assign w_blocked_no_write_in_flight[port_id] =
    (w_block_reason[port_id] == VIP_MC_STATUS_FE_BLOCK_NO_WRITE_IN_FLIGHT_E);
  end

endinterface

`endif

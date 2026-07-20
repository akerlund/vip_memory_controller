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
// vip_mc_status_snapshot
//
// Shared software mirror of the optional vip_mc_status_if probe. Producers in
// the vip_mc stack publish into this object; vip_mc alone mirrors it onto the
// physical interface on the controller clock.
// -----------------------------------------------------------------------------

class vip_mc_status_snapshot #(
  int N_PORTS = 1
  ) extends uvm_object;

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

  bit                    local_reject_pulse;
  int unsigned           local_reject_port_id;
  vip_mc_status_op_e     local_reject_op;
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

  `uvm_object_param_utils(vip_mc_status_snapshot #(N_PORTS))

  function new(string name = "vip_mc_status_snapshot");
    super.new(name);
    this.clear();
  endfunction

  function void clear();
    this.rst_active                = 1'b0;
    this.cmd_queue_depth           = 0;
    this.cmd_queue_peak_depth      = 0;
    this.inflight_to_device        = 0;
    this.rsp_buf_used              = 0;
    this.rsp_buf_full              = 1'b0;
    this.device_issue_credit_avail = 1'b1;
    this.backend_stall_reason      = VIP_MC_STATUS_STALL_NONE_E;
    this.refresh_count             = 0;

    this.issue_port_id       = 0;
    this.issue_tag           = '0;
    this.issue_op            = VIP_MC_STATUS_OP_NONE_E;
    this.issue_qos_class     = 0;
    this.issue_pre_resolved  = 1'b0;

    this.complete_port_id      = 0;
    this.complete_tag          = '0;
    this.complete_op           = VIP_MC_STATUS_OP_NONE_E;
    this.complete_resp         = VIP_MC_STATUS_RSP_NONE_E;
    this.complete_page         = VIP_MC_STATUS_PAGE_UNKNOWN_E;
    this.complete_pre_resolved = 1'b0;

    this.refresh_emit_rank     = 0;

    this.local_reject_port_id  = 0;
    this.local_reject_op       = VIP_MC_STATUS_OP_NONE_E;
    this.local_reject_reason   = VIP_MC_STATUS_REJECT_NONE_E;

    for (int port_id = 0; port_id < N_PORTS; port_id++) begin
      this.rd_outstanding_count[port_id] = 0;
      this.wr_outstanding_count[port_id] = 0;
      this.aw_pending_depth[port_id]     = 0;
      this.pending_b_depth[port_id]      = 0;
      this.pending_r_depth[port_id]      = 0;
      this.active_r_slots_used[port_id]  = 0;
      this.w_data_buf_occupancy[port_id] = 0;
      this.aw_block_reason[port_id]      = VIP_MC_STATUS_FE_BLOCK_NONE_E;
      this.ar_block_reason[port_id]      = VIP_MC_STATUS_FE_BLOCK_NONE_E;
      this.w_block_reason[port_id]       = VIP_MC_STATUS_FE_BLOCK_NONE_E;
    end

    this.clear_pulses();
  endfunction

  function void clear_pulses();
    this.issue_pulse        = 1'b0;
    this.complete_pulse     = 1'b0;
    this.refresh_emit_pulse = 1'b0;
    this.local_reject_pulse = 1'b0;
  endfunction

endclass
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
// vip_mc_types_pkg
//
// Shared vip_mc topology types that sit above the per-protocol cfg packages.
// The back-end uses these to decide which front-end exists on each port while
// keeping protocol semantics in the protocol-owned layers.
//
// CHI note: a complete vip_chi agent exists, so vip_mc does NOT re-own the CHI
// flit/opcode/width types — those come from vip_chi_types_pkg (see §1 CHI
// planning decisions, §3). The only CHI type carried here is the thin
// vip_mc_chi_cfg_t *selector* (the user-chosen axes), so the AXI4-only core
// compiles with no vip_chi import. The CHI front-end maps it to vip_chi_cfg_t
// at its own boundary.
// -----------------------------------------------------------------------------

`ifndef VIP_MC_TYPES_PKG
`define VIP_MC_TYPES_PKG

package vip_mc_types_pkg;

  import vip_mc_axi4_types_pkg::*;

  // ---------------------------------------------------------------------------
  // vip_mc owns its own boolean enum. Peer agents still type their public cfg
  // fields as vip_mem_types_pkg::bool_t, so cross-agent assignments use an
  // explicit vip_mem_types_pkg:: qualifier.
  // ---------------------------------------------------------------------------
  typedef enum bit {
    FALSE,
    TRUE
  } bool_t;

  // ---------------------------------------------------------------------------
  // Thin CHI port selector. Field shape mirrors vip_chi_cfg_t (issue + the
  // user-selected width/enable axes) so the CHI front-end can map it 1:1 to
  // vip_chi_cfg_t. Derived flit/opcode widths are NOT stored here — they come
  // from vip_chi_types #(vip_chi_cfg_t) in vip_chi_types_pkg.
  // ---------------------------------------------------------------------------
  typedef enum {
    VIP_MC_CHI_ISSUE_D_E,
    VIP_MC_CHI_ISSUE_E_E
  } vip_mc_chi_issue_e;

  typedef struct packed {
    vip_mc_chi_issue_e issue;
    int                NODE_ID_WIDTH_P;
    int                ADDR_WIDTH_P;
    int                DATA_BYTES_P;
    bit                DATACHECK_EN_P;
    bit                POISON_EN_P;
    bit                MPAM_EN_P;
    bit                PARITY_EN_P;
  } vip_mc_chi_cfg_t;

  // ---------------------------------------------------------------------------
  // Per-port topology descriptor: which front-end adapter sits on each port and
  // that protocol's width cfg (only the field matching `proto` is meaningful).
  // ---------------------------------------------------------------------------
  typedef enum {
    VIP_MC_PROTO_AXI4_E,
    VIP_MC_PROTO_CHI_E
  } vip_mc_proto_e;

  typedef struct packed {
    vip_mc_proto_e    proto;
    vip_mc_axi4_cfg_t axi4;
    vip_mc_chi_cfg_t  chi;
  } vip_mc_port_cfg_t;

  typedef struct packed {
    longint unsigned lo;
    longint unsigned hi;
  } vip_mc_addr_region_t;

  typedef enum {
    VIP_MC_REFRESH_PERIODIC_E,   // one REF burst every tREFI
    VIP_MC_REFRESH_DEFERRED_E    // postpone up to refresh_max_deferred, then catch up
  } vip_mc_refresh_policy_e;

  typedef enum int unsigned {
    VIP_MC_STATUS_OP_NONE_E,
    VIP_MC_STATUS_OP_RD_E,
    VIP_MC_STATUS_OP_WR_E,
    VIP_MC_STATUS_OP_REF_E
  } vip_mc_status_op_e;

  typedef enum int unsigned {
    VIP_MC_STATUS_RSP_NONE_E,
    VIP_MC_STATUS_RSP_OKAY_E,
    VIP_MC_STATUS_RSP_EXOKAY_E,
    VIP_MC_STATUS_RSP_SLVERR_E,
    VIP_MC_STATUS_RSP_DECERR_E
  } vip_mc_status_rsp_e;

  typedef enum int unsigned {
    VIP_MC_STATUS_PAGE_UNKNOWN_E,
    VIP_MC_STATUS_PAGE_HIT_E,
    VIP_MC_STATUS_PAGE_MISS_E,
    VIP_MC_STATUS_PAGE_EMPTY_E
  } vip_mc_status_page_e;

  typedef enum int unsigned {
    VIP_MC_STATUS_STALL_NONE_E,
    VIP_MC_STATUS_STALL_IN_RESET_E,
    VIP_MC_STATUS_STALL_NO_BUFFERED_INPUT_E,
    VIP_MC_STATUS_STALL_CMD_QUEUE_EMPTY_E,
    VIP_MC_STATUS_STALL_SAME_STREAM_BLOCKED_E,
    VIP_MC_STATUS_STALL_DEVICE_CREDIT_FULL_E,
    VIP_MC_STATUS_STALL_RSP_BUFFER_FULL_E,
    VIP_MC_STATUS_STALL_REF_STRICT_PRIORITY_E
  } vip_mc_status_stall_e;

  typedef enum int unsigned {
    VIP_MC_STATUS_REJECT_NONE_E,
    VIP_MC_STATUS_REJECT_DECERR_REGION_E,
    VIP_MC_STATUS_REJECT_DECERR_4K_E,
    VIP_MC_STATUS_REJECT_DECERR_ROW_SPAN_E,
    VIP_MC_STATUS_REJECT_UNSUPPORTED_AXI_SHAPE_E,
    VIP_MC_STATUS_REJECT_EXCLUSIVE_FAIL_LOCAL_E,
    VIP_MC_STATUS_REJECT_SLVERR_LOCAL_E
  } vip_mc_status_reject_e;

  typedef enum int unsigned {
    VIP_MC_STATUS_FE_BLOCK_NONE_E,
    VIP_MC_STATUS_FE_BLOCK_IN_RESET_E,
    VIP_MC_STATUS_FE_BLOCK_AW_OUTSTANDING_FULL_E,
    VIP_MC_STATUS_FE_BLOCK_AR_OUTSTANDING_FULL_E,
    VIP_MC_STATUS_FE_BLOCK_AW_PENDING_FULL_E,
    VIP_MC_STATUS_FE_BLOCK_WBUF_FULL_E,
    VIP_MC_STATUS_FE_BLOCK_NO_WRITE_IN_FLIGHT_E,
    VIP_MC_STATUS_FE_BLOCK_RSP_BUF_FULL_E
  } vip_mc_status_fe_block_e;

  // ---------------------------------------------------------------------------
  // Return whether a port is configured as AXI4.
  // ---------------------------------------------------------------------------
  function automatic bit vip_mc_port_is_axi4(vip_mc_port_cfg_t cfg);
    return (cfg.proto == VIP_MC_PROTO_AXI4_E);
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether a port is configured as CHI.
  // ---------------------------------------------------------------------------
  function automatic bit vip_mc_port_is_chi(vip_mc_port_cfg_t cfg);
    return (cfg.proto == VIP_MC_PROTO_CHI_E);
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether an address region has a legal inclusive range.
  // ---------------------------------------------------------------------------
  function automatic bit vip_mc_region_is_valid(vip_mc_addr_region_t region);
    return (region.lo <= region.hi);
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether an address falls inside the inclusive region.
  // ---------------------------------------------------------------------------
  function automatic bit vip_mc_addr_in_region(
    longint unsigned addr,
    vip_mc_addr_region_t region
  );
    return (addr >= region.lo) && (addr <= region.hi);
  endfunction

endpackage

`endif

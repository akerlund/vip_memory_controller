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
// vip_mc_chi_if
//
// vip_mc's OWN single-role controller-side CHI interface for the SN (memory
// subordinate) role. Like vip_mc_axi4_if it has a SINGLE driving clocking block
// (snf_cb) plus an all-input monitor_cb and NO ROLE_P parameter, so the "two
// distinct SV types cannot alias one role-gated instance" trap does not arise.
// When a vip_chi RN-I manager is reused for stimulus, it drives a SEPARATE
// vip_chi_if instance and vip_mc_chi_connect cross-wires the two.
//
// The flit/opcode/width types are REUSED from vip_chi_types_pkg (CHI decision
// 2/7): the thin vip_mc_chi_cfg_t selector is mapped 1:1 to vip_chi_cfg_t and
// vip_chi_types #(CHI_CFG_C) derives every width. See vip_mc/IMPLEMENTATION_PLAN.md
// "CHI planning decisions".
// -----------------------------------------------------------------------------

`ifndef VIP_MC_CHI_IF
`define VIP_MC_CHI_IF

import vip_mc_types_pkg::*;
import vip_chi_types_pkg::*;

interface vip_mc_chi_if #(
  parameter vip_mc_chi_cfg_t CFG_P = '{default: '0}
  )(
    input clk,
    input rst_n
  );

  // Map the thin vip_mc selector to vip_chi_cfg_t so vip_chi_types derives the
  // flit/opcode widths. The two structs share field layout; only the issue enum
  // type differs.
  localparam vip_chi_cfg_t CHI_CFG_C = '{
    ISSUE_P         : (CFG_P.issue == VIP_MC_CHI_ISSUE_E_E) ?
                        VIP_CHI_ISSUE_E_E : VIP_CHI_ISSUE_D_E,
    NODE_ID_WIDTH_P : CFG_P.NODE_ID_WIDTH_P,
    ADDR_WIDTH_P    : CFG_P.ADDR_WIDTH_P,
    DATA_BYTES_P    : CFG_P.DATA_BYTES_P,
    DATACHECK_EN_P  : CFG_P.DATACHECK_EN_P,
    POISON_EN_P     : CFG_P.POISON_EN_P,
    MPAM_EN_P       : CFG_P.MPAM_EN_P,
    PARITY_EN_P     : CFG_P.PARITY_EN_P
  };

  typedef vip_chi_types #(CHI_CFG_C)         flit_types_t;
  typedef flit_types_t::vip_chi_req_flit_t   req_flit_t;
  typedef flit_types_t::vip_chi_rsp_flit_t   rsp_flit_t;
  typedef flit_types_t::vip_chi_dat_flit_t   dat_flit_t;

  // ---------------------------------------------------------------------------
  // Link state and activation handshake.
  // ---------------------------------------------------------------------------
  logic txlinkactivereq;
  logic txlinkactiveack;
  logic rxlinkactivereq;
  logic rxlinkactiveack;
  logic txsactive;
  logic rxsactive;

  // ---------------------------------------------------------------------------
  // Request channel (SN receives REQ, grants inbound REQ credits).
  // ---------------------------------------------------------------------------
  logic      txreqflitpend;
  logic      txreqflitv;
  req_flit_t txreqflit;
  logic      txreqlcrdv;

  logic      rxreqflitpend;
  logic      rxreqflitv;
  req_flit_t rxreqflit;
  logic      rxreqlcrdv;

  // ---------------------------------------------------------------------------
  // Response channel (SN sources RSP, grants inbound RSP credits).
  // ---------------------------------------------------------------------------
  logic      txrspflitpend;
  logic      txrspflitv;
  rsp_flit_t txrspflit;
  logic      txrsplcrdv;

  logic      rxrspflitpend;
  logic      rxrspflitv;
  rsp_flit_t rxrspflit;
  logic      rxrsplcrdv;

  // ---------------------------------------------------------------------------
  // Data channel (SN sources read DAT, receives write DAT, grants DAT credits).
  // ---------------------------------------------------------------------------
  logic      txdatflitpend;
  logic      txdatflitv;
  dat_flit_t txdatflit;
  logic      txdatlcrdv;

  logic      rxdatflitpend;
  logic      rxdatflitv;
  dat_flit_t rxdatflit;
  logic      rxdatlcrdv;

  // ---------------------------------------------------------------------------
  // Controller-side (SN completer) driving clocking block. vip_mc DRIVES the
  // tx* link-active/credit/flit signals and SAMPLES the rx* payloads. Directions
  // mirror vip_chi_if's snf_cb.
  // ---------------------------------------------------------------------------
  clocking controller_cb @(posedge clk);

    default input #1step output #0;

    output txlinkactivereq;
    output txlinkactiveack;
    input  rxlinkactivereq;
    input  rxlinkactiveack;
    output txsactive;
    input  rxsactive;

    input  rxreqflitpend;
    input  rxreqflitv;
    input  rxreqflit;
    output txreqlcrdv;

    output txrspflitpend;
    output txrspflitv;
    output txrspflit;
    output txrsplcrdv;
    input  rxrspflitpend;
    input  rxrspflitv;
    input  rxrspflit;
    input  rxrsplcrdv;

    output txdatflitpend;
    output txdatflitv;
    output txdatflit;
    output txdatlcrdv;
    input  rxdatflitpend;
    input  rxdatflitv;
    input  rxdatflit;
    input  rxdatlcrdv;
  endclocking
  modport controller (clocking controller_cb, input clk, input rst_n);

  // ---------------------------------------------------------------------------
  // Passive monitor clocking block — all inputs.
  // ---------------------------------------------------------------------------
  clocking monitor_cb @(posedge clk);

    default input #1step;

    input txlinkactivereq;
    input txlinkactiveack;
    input rxlinkactivereq;
    input rxlinkactiveack;
    input txsactive;
    input rxsactive;

    input txreqflitpend;
    input txreqflitv;
    input txreqflit;
    input txreqlcrdv;
    input rxreqflitpend;
    input rxreqflitv;
    input rxreqflit;
    input rxreqlcrdv;

    input txrspflitpend;
    input txrspflitv;
    input txrspflit;
    input txrsplcrdv;
    input rxrspflitpend;
    input rxrspflitv;
    input rxrspflit;
    input rxrsplcrdv;

    input txdatflitpend;
    input txdatflitv;
    input txdatflit;
    input txdatlcrdv;
    input rxdatflitpend;
    input rxdatflitv;
    input rxdatflit;
    input rxdatlcrdv;
  endclocking
  modport monitor (clocking monitor_cb, input clk, input rst_n);

  // ---------------------------------------------------------------------------
  // Raw-signal SN modport for structural hookups (the connector bridge).
  // ---------------------------------------------------------------------------
  modport snf (
    input  clk,
    input  rst_n,
    output txlinkactivereq,
    output txlinkactiveack,
    input  rxlinkactivereq,
    input  rxlinkactiveack,
    output txsactive,
    input  rxsactive,
    input  rxreqflitpend,
    input  rxreqflitv,
    input  rxreqflit,
    output txreqlcrdv,
    output txrspflitpend,
    output txrspflitv,
    output txrspflit,
    output txrsplcrdv,
    input  rxrspflitpend,
    input  rxrspflitv,
    input  rxrspflit,
    input  rxrsplcrdv,
    output txdatflitpend,
    output txdatflitv,
    output txdatflit,
    output txdatlcrdv,
    input  rxdatflitpend,
    input  rxdatflitv,
    input  rxdatflit,
    input  rxdatlcrdv
  );

endinterface

`endif

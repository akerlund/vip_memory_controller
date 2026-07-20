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
// vip_mc_chi_connect
//
// Optional glue between a stock vip_chi RN-I manager interface (vip_chi_if in
// RN-I role) and vip_mc's owned SN interface (vip_mc_chi_if). This module is
// example-only and intentionally lives outside vip_mc_pkg so the core VIP stays
// free of any vip_chi *agent* dependency (CHI decision 7). It is the CHI
// counterpart of vip_mc_axi4_connect: two separate role-typed interface
// instances, bridged by a structural crossover, never one shared role-gated
// interface (B1).
//
// Each link direction's tx* signals of one side feed the rx* signals of the
// other. The RN drives its tx* (REQ, CompAck RSP, write DAT) + credit grants;
// the SN drives its tx* (RSP/DAT completions) + credit grants. The connector
// only drives the rx* inputs of each side, so there is exactly one driver per
// net.
// -----------------------------------------------------------------------------
module vip_mc_chi_connect (
    vip_mc_chi_if mc,   // vip_mc SN interface (this VIP)
    vip_chi_if    rn    // stock vip_chi RN-I manager interface
  );

  // ---------------------------------------------------------------------------
  // RN -> MC: requests, write data, RN-side completions (CompAck), and the
  // credit grants the RN issues for the SN's RSP/DAT traffic.
  // ---------------------------------------------------------------------------
  always_comb begin
    mc.rxlinkactivereq = rn.txlinkactivereq;
    mc.rxlinkactiveack = rn.txlinkactiveack;
    mc.rxsactive       = rn.txsactive;

    mc.rxreqflitpend   = rn.txreqflitpend;
    mc.rxreqflitv      = rn.txreqflitv;
    mc.rxreqflit       = rn.txreqflit;

    mc.rxrspflitpend   = rn.txrspflitpend;
    mc.rxrspflitv      = rn.txrspflitv;
    mc.rxrspflit       = rn.txrspflit;
    mc.rxrsplcrdv      = rn.txrsplcrdv;

    mc.rxdatflitpend   = rn.txdatflitpend;
    mc.rxdatflitv      = rn.txdatflitv;
    mc.rxdatflit       = rn.txdatflit;
    mc.rxdatlcrdv      = rn.txdatlcrdv;
  end

  // ---------------------------------------------------------------------------
  // MC -> RN: the SN's RSP/DAT completions, and the credit grants the SN issues
  // for inbound REQ/RSP/DAT traffic.
  // ---------------------------------------------------------------------------
  always_comb begin
    rn.rxlinkactivereq = mc.txlinkactivereq;
    rn.rxlinkactiveack = mc.txlinkactiveack;
    rn.rxsactive       = mc.txsactive;

    rn.rxreqlcrdv      = mc.txreqlcrdv;

    rn.rxrspflitpend   = mc.txrspflitpend;
    rn.rxrspflitv      = mc.txrspflitv;
    rn.rxrspflit       = mc.txrspflit;
    rn.rxrsplcrdv      = mc.txrsplcrdv;

    rn.rxdatflitpend   = mc.txdatflitpend;
    rn.rxdatflitv      = mc.txdatflitv;
    rn.rxdatflit       = mc.txdatflit;
    rn.rxdatlcrdv      = mc.txdatlcrdv;
  end

endmodule

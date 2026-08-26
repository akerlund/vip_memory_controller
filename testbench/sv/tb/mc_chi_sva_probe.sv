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
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
////////////////////////////////////////////////////////////////////////////////

// Adapt the MC-native SN interface to a standard SNF vip_chi_if for the
// protocol checker. This is a passive mirror: it has no procedural driver and
// does not alter the DUT-facing MC interface.
module mc_chi_sva_probe (
    vip_mc_chi_if mc,
    vip_chi_if    checker
  );

  assign checker.txlinkactivereq = mc.txlinkactivereq;
  assign checker.txlinkactiveack = mc.txlinkactiveack;
  assign checker.rxlinkactivereq = mc.rxlinkactivereq;
  assign checker.rxlinkactiveack = mc.rxlinkactiveack;
  assign checker.txsactive       = mc.txsactive;
  assign checker.rxsactive       = mc.rxsactive;

  assign checker.txreqflitpend  = mc.txreqflitpend;
  assign checker.txreqflitv     = mc.txreqflitv;
  assign checker.txreqflit      = mc.txreqflit;
  assign checker.txreqlcrdv     = mc.txreqlcrdv;
  assign checker.rxreqflitpend  = mc.rxreqflitpend;
  assign checker.rxreqflitv     = mc.rxreqflitv;
  assign checker.rxreqflit      = mc.rxreqflit;
  assign checker.rxreqlcrdv     = mc.rxreqlcrdv;

  assign checker.txrspflitpend = mc.txrspflitpend;
  assign checker.txrspflitv    = mc.txrspflitv;
  assign checker.txrspflit     = mc.txrspflit;
  assign checker.txrsplcrdv    = mc.txrsplcrdv;
  assign checker.rxrspflitpend = mc.rxrspflitpend;
  assign checker.rxrspflitv    = mc.rxrspflitv;
  assign checker.rxrspflit     = mc.rxrspflit;
  assign checker.rxrsplcrdv    = mc.rxrsplcrdv;

  assign checker.txdatflitpend = mc.txdatflitpend;
  assign checker.txdatflitv    = mc.txdatflitv;
  assign checker.txdatflit     = mc.txdatflit;
  assign checker.txdatlcrdv    = mc.txdatlcrdv;
  assign checker.rxdatflitpend = mc.rxdatflitpend;
  assign checker.rxdatflitv    = mc.rxdatflitv;
  assign checker.rxdatflit     = mc.rxdatflit;
  assign checker.rxdatlcrdv    = mc.rxdatlcrdv;

  // The MC SN has no snoop channel. Tie the absent receive side down so the
  // standard interface's link-quiet and role-gated checks see a known idle SNP
  // channel; its SNF transmit side is already tied off by vip_chi_if.
  assign checker.rxsnpflitpend = 1'b0;
  assign checker.rxsnpflitv    = 1'b0;
  assign checker.rxsnpflit     = '0;
  assign checker.rxsnplcrdv    = 1'b0;

endmodule

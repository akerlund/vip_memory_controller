////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2026 Fredrik Akerlund
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

`timescale 1ns/1ps
`default_nettype none

module mc_hdl_top #(
    parameter int ID_W      = 4,
    parameter int ADDR_W    = 33,
    parameter int DATA_W    = 512,
    parameter int STRB_W    = DATA_W/8,
    parameter int AWUSER_W  = 4,
    parameter int WUSER_W   = 4,
    parameter int BUSER_W   = 4,
    parameter int ARUSER_W  = 4,
    parameter int RUSER_W   = 4
  );

  localparam int CHI_REQ_W = 192;
  localparam int CHI_RSP_W = 96;
  localparam int CHI_DAT_W = 768;
  localparam int CHI_SNP_W = 160;

  logic clk;
  logic rst_n;

  // Verilated with --public-flat-rw: cocotb drives the manager side and the
  // Python vip_mc AXI4 front-end drives the controller side.
  // verilator lint_off UNDRIVEN
  logic [ID_W-1:0]     awid;
  logic [ADDR_W-1:0]   awaddr;
  logic [7:0]          awlen;
  logic [2:0]          awsize;
  logic [1:0]          awburst;
  logic                awlock;
  logic [3:0]          awcache;
  logic [2:0]          awprot;
  logic [3:0]          awqos;
  logic [3:0]          awregion;
  logic [AWUSER_W-1:0] awuser;
  logic                awvalid;
  logic                awready;

  logic [DATA_W-1:0]   wdata;
  logic [STRB_W-1:0]   wstrb;
  logic                wlast;
  logic [WUSER_W-1:0]  wuser;
  logic                wvalid;
  logic                wready;

  logic [ID_W-1:0]     bid;
  logic [1:0]          bresp;
  logic [BUSER_W-1:0]  buser;
  logic                bvalid;
  logic                bready;

  logic [ID_W-1:0]     arid;
  logic [ADDR_W-1:0]   araddr;
  logic [7:0]          arlen;
  logic [2:0]          arsize;
  logic [1:0]          arburst;
  logic                arlock;
  logic [3:0]          arcache;
  logic [2:0]          arprot;
  logic [3:0]          arqos;
  logic [3:0]          arregion;
  logic [ARUSER_W-1:0] aruser;
  logic                arvalid;
  logic                arready;

  logic [ID_W-1:0]     rid;
  logic [DATA_W-1:0]   rdata;
  logic [1:0]          rresp;
  logic                rlast;
  logic [RUSER_W-1:0]  ruser;
  logic                rvalid;
  logic                rready;

`define VIP_MC_DECL_AXI4_PORT(P) \
  logic [ID_W-1:0]     P``awid; \
  logic [ADDR_W-1:0]   P``awaddr; \
  logic [7:0]          P``awlen; \
  logic [2:0]          P``awsize; \
  logic [1:0]          P``awburst; \
  logic                P``awlock; \
  logic [3:0]          P``awcache; \
  logic [2:0]          P``awprot; \
  logic [3:0]          P``awqos; \
  logic [3:0]          P``awregion; \
  logic [AWUSER_W-1:0] P``awuser; \
  logic                P``awvalid; \
  logic                P``awready; \
  logic [DATA_W-1:0]   P``wdata; \
  logic [STRB_W-1:0]   P``wstrb; \
  logic                P``wlast; \
  logic [WUSER_W-1:0]  P``wuser; \
  logic                P``wvalid; \
  logic                P``wready; \
  logic [ID_W-1:0]     P``bid; \
  logic [1:0]          P``bresp; \
  logic [BUSER_W-1:0]  P``buser; \
  logic                P``bvalid; \
  logic                P``bready; \
  logic [ID_W-1:0]     P``arid; \
  logic [ADDR_W-1:0]   P``araddr; \
  logic [7:0]          P``arlen; \
  logic [2:0]          P``arsize; \
  logic [1:0]          P``arburst; \
  logic                P``arlock; \
  logic [3:0]          P``arcache; \
  logic [2:0]          P``arprot; \
  logic [3:0]          P``arqos; \
  logic [3:0]          P``arregion; \
  logic [ARUSER_W-1:0] P``aruser; \
  logic                P``arvalid; \
  logic                P``arready; \
  logic [ID_W-1:0]     P``rid; \
  logic [DATA_W-1:0]   P``rdata; \
  logic [1:0]          P``rresp; \
  logic                P``rlast; \
  logic [RUSER_W-1:0]  P``ruser; \
  logic                P``rvalid; \
  logic                P``rready;

  `VIP_MC_DECL_AXI4_PORT(p0_)
  `VIP_MC_DECL_AXI4_PORT(p1_)
`undef VIP_MC_DECL_AXI4_PORT

`define VIP_MC_DECL_CHI_PORT(P) \
  logic P``txlinkactivereq; \
  logic P``txlinkactiveack; \
  logic P``rxlinkactivereq; \
  logic P``rxlinkactiveack; \
  logic P``txsactive; \
  logic P``rxsactive; \
  logic P``txreqflitpend; \
  logic P``txreqflitv; \
  logic [CHI_REQ_W-1:0] P``txreqflit; \
  logic P``txreqlcrdv; \
  logic P``rxreqflitpend; \
  logic P``rxreqflitv; \
  logic [CHI_REQ_W-1:0] P``rxreqflit; \
  logic P``rxreqlcrdv; \
  logic P``txrspflitpend; \
  logic P``txrspflitv; \
  logic [CHI_RSP_W-1:0] P``txrspflit; \
  logic P``txrsplcrdv; \
  logic P``rxrspflitpend; \
  logic P``rxrspflitv; \
  logic [CHI_RSP_W-1:0] P``rxrspflit; \
  logic P``rxrsplcrdv; \
  logic P``txdatflitpend; \
  logic P``txdatflitv; \
  logic [CHI_DAT_W-1:0] P``txdatflit; \
  logic P``txdatlcrdv; \
  logic P``rxdatflitpend; \
  logic P``rxdatflitv; \
  logic [CHI_DAT_W-1:0] P``rxdatflit; \
  logic P``rxdatlcrdv; \
  logic P``txsnpflitpend; \
  logic P``txsnpflitv; \
  logic [CHI_SNP_W-1:0] P``txsnpflit; \
  logic P``txsnplcrdv; \
  logic P``rxsnpflitpend; \
  logic P``rxsnpflitv; \
  logic [CHI_SNP_W-1:0] P``rxsnpflit; \
  logic P``rxsnplcrdv;

  `VIP_MC_DECL_CHI_PORT(rni_)
  `VIP_MC_DECL_CHI_PORT(mcchi_)
  `VIP_MC_DECL_CHI_PORT(rni_e_)
  `VIP_MC_DECL_CHI_PORT(mcchi_e_)
  `VIP_MC_DECL_CHI_PORT(rni_n32_)
  `VIP_MC_DECL_CHI_PORT(mcchi_n32_)
`undef VIP_MC_DECL_CHI_PORT
  // verilator lint_on UNDRIVEN

`define VIP_MC_CHI_XWIRE(D, S) \
  assign D``rxlinkactivereq = S``txlinkactivereq; \
  assign D``rxlinkactiveack = S``txlinkactiveack; \
  assign D``rxsactive       = S``txsactive; \
  assign D``rxreqflitpend   = S``txreqflitpend; \
  assign D``rxreqflitv      = S``txreqflitv; \
  assign D``rxreqflit       = S``txreqflit; \
  assign D``rxreqlcrdv      = S``txreqlcrdv; \
  assign D``rxrspflitpend   = S``txrspflitpend; \
  assign D``rxrspflitv      = S``txrspflitv; \
  assign D``rxrspflit       = S``txrspflit; \
  assign D``rxrsplcrdv      = S``txrsplcrdv; \
  assign D``rxdatflitpend   = S``txdatflitpend; \
  assign D``rxdatflitv      = S``txdatflitv; \
  assign D``rxdatflit       = S``txdatflit; \
  assign D``rxdatlcrdv      = S``txdatlcrdv; \
  assign D``rxsnpflitpend   = S``txsnpflitpend; \
  assign D``rxsnpflitv      = S``txsnpflitv; \
  assign D``rxsnpflit       = S``txsnpflit; \
  assign D``rxsnplcrdv      = S``txsnplcrdv;

  `VIP_MC_CHI_XWIRE(mcchi_, rni_)
  `VIP_MC_CHI_XWIRE(rni_, mcchi_)
  `VIP_MC_CHI_XWIRE(mcchi_e_, rni_e_)
  `VIP_MC_CHI_XWIRE(rni_e_, mcchi_e_)
  `VIP_MC_CHI_XWIRE(mcchi_n32_, rni_n32_)
  `VIP_MC_CHI_XWIRE(rni_n32_, mcchi_n32_)
`undef VIP_MC_CHI_XWIRE

endmodule

`default_nettype wire

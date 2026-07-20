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
// vip_mc_axi4_connect
//
// Optional glue between a stock vip_axi4_if MANAGER instance and vip_mc's
// owned vip_mc_axi4_if. This module is example-only and intentionally lives
// outside vip_mc_pkg so the core VIP stays free of any vip_axi4_* dependency.
// -----------------------------------------------------------------------------
import vip_mc_axi4_types_pkg::*;
import vip_axi4_types_pkg::*;

module vip_mc_axi4_connect #(
  parameter vip_mc_axi4_cfg_t MC_CFG_P   = '{default: '0},
  parameter vip_axi4_cfg_t    AXI4_CFG_P = '{default: '0}
  )(
    input logic                                        clk,
    input logic                                        rst_n,
    input  logic [AXI4_CFG_P.AWID_WIDTH_P-1 : 0]       man_awid,
    input  logic [AXI4_CFG_P.ADDR_WIDTH_P-1 : 0]       man_awaddr,
    input  logic [7 : 0]                               man_awlen,
    input  logic [2 : 0]                               man_awsize,
    input  logic [1 : 0]                               man_awburst,
    input  logic                                       man_awlock,
    input  logic [3 : 0]                               man_awcache,
    input  logic [2 : 0]                               man_awprot,
    input  logic [3 : 0]                               man_awqos,
    input  logic [3 : 0]                               man_awregion,
    input  logic [AXI4_CFG_P.AWUSER_WIDTH_P-1 : 0]     man_awuser,
    input  logic                                       man_awvalid,
    output logic                                       man_awready,

    input  logic [(8 * AXI4_CFG_P.WDATA_BYTES_P)-1 : 0] man_wdata,
    input  logic [AXI4_CFG_P.WDATA_BYTES_P-1 : 0]       man_wstrb,
    input  logic                                        man_wlast,
    input  logic [AXI4_CFG_P.WUSER_WIDTH_P-1 : 0]       man_wuser,
    input  logic                                        man_wvalid,
    output logic                                        man_wready,

    output logic [AXI4_CFG_P.AWID_WIDTH_P-1 : 0]      man_bid,
    output logic [1 : 0]                              man_bresp,
    output logic [AXI4_CFG_P.BUSER_WIDTH_P-1 : 0]     man_buser,
    output logic                                      man_bvalid,
    input  logic                                      man_bready,

    input  logic [AXI4_CFG_P.ARID_WIDTH_P-1 : 0]      man_arid,
    input  logic [AXI4_CFG_P.ADDR_WIDTH_P-1 : 0]      man_araddr,
    input  logic [7 : 0]                              man_arlen,
    input  logic [2 : 0]                              man_arsize,
    input  logic [1 : 0]                              man_arburst,
    input  logic                                      man_arlock,
    input  logic [3 : 0]                              man_arcache,
    input  logic [2 : 0]                              man_arprot,
    input  logic [3 : 0]                              man_arqos,
    input  logic [3 : 0]                              man_arregion,
    input  logic [AXI4_CFG_P.ARUSER_WIDTH_P-1 : 0]    man_aruser,
    input  logic                                      man_arvalid,
    output logic                                      man_arready,

    output logic [AXI4_CFG_P.ARID_WIDTH_P-1 : 0]      man_rid,
    output logic [(8 * AXI4_CFG_P.RDATA_BYTES_P)-1 : 0] man_rdata,
    output logic [1 : 0]                              man_rresp,
    output logic                                      man_rlast,
    output logic [AXI4_CFG_P.RUSER_WIDTH_P-1 : 0]     man_ruser,
    output logic                                      man_rvalid,
    input  logic                                      man_rready,

    output logic [MC_CFG_P.AWID_WIDTH_P-1 : 0]        mc_awid,
    output logic [MC_CFG_P.ADDR_WIDTH_P-1 : 0]        mc_awaddr,
    output logic [7 : 0]                              mc_awlen,
    output logic [2 : 0]                              mc_awsize,
    output logic [1 : 0]                              mc_awburst,
    output logic                                      mc_awlock,
    output logic [3 : 0]                              mc_awcache,
    output logic [2 : 0]                              mc_awprot,
    output logic [3 : 0]                              mc_awqos,
    output logic [3 : 0]                              mc_awregion,
    output logic [MC_CFG_P.AWUSER_WIDTH_P-1 : 0]      mc_awuser,
    output logic                                      mc_awvalid,
    input  logic                                      mc_awready,

    output logic [(8 * MC_CFG_P.WDATA_BYTES_P)-1 : 0] mc_wdata,
    output logic [MC_CFG_P.WDATA_BYTES_P-1 : 0]       mc_wstrb,
    output logic                                      mc_wlast,
    output logic [MC_CFG_P.WUSER_WIDTH_P-1 : 0]       mc_wuser,
    output logic                                      mc_wvalid,
    input  logic                                      mc_wready,

    input  logic [MC_CFG_P.AWID_WIDTH_P-1 : 0]        mc_bid,
    input  logic [1 : 0]                              mc_bresp,
    input  logic [MC_CFG_P.BUSER_WIDTH_P-1 : 0]       mc_buser,
    input  logic                                      mc_bvalid,
    output logic                                      mc_bready,

    output logic [MC_CFG_P.ARID_WIDTH_P-1 : 0]        mc_arid,
    output logic [MC_CFG_P.ADDR_WIDTH_P-1 : 0]        mc_araddr,
    output logic [7 : 0]                              mc_arlen,
    output logic [2 : 0]                              mc_arsize,
    output logic [1 : 0]                              mc_arburst,
    output logic                                      mc_arlock,
    output logic [3 : 0]                              mc_arcache,
    output logic [2 : 0]                              mc_arprot,
    output logic [3 : 0]                              mc_arqos,
    output logic [3 : 0]                              mc_arregion,
    output logic [MC_CFG_P.ARUSER_WIDTH_P-1 : 0]      mc_aruser,
    output logic                                      mc_arvalid,
    input  logic                                      mc_arready,

    input  logic [MC_CFG_P.ARID_WIDTH_P-1 : 0]        mc_rid,
    input  logic [(8 * MC_CFG_P.RDATA_BYTES_P)-1 : 0] mc_rdata,
    input  logic [1 : 0]                              mc_rresp,
    input  logic                                      mc_rlast,
    input  logic [MC_CFG_P.RUSER_WIDTH_P-1 : 0]       mc_ruser,
    input  logic                                      mc_rvalid,
    output logic                                      mc_rready
  );

  logic man_awvalid_d;
  logic man_arvalid_d;

  // ---------------------------------------------------------------------------
  // Check that both interfaces describe the same bus shape.
  // ---------------------------------------------------------------------------
  initial begin
    if ((MC_CFG_P.AWID_WIDTH_P   != AXI4_CFG_P.AWID_WIDTH_P)   ||
        (MC_CFG_P.ARID_WIDTH_P   != AXI4_CFG_P.ARID_WIDTH_P)   ||
        (MC_CFG_P.ADDR_WIDTH_P   != AXI4_CFG_P.ADDR_WIDTH_P)   ||
        (MC_CFG_P.WDATA_BYTES_P  != AXI4_CFG_P.WDATA_BYTES_P)  ||
        (MC_CFG_P.RDATA_BYTES_P  != AXI4_CFG_P.RDATA_BYTES_P)  ||
        (MC_CFG_P.AWUSER_WIDTH_P != AXI4_CFG_P.AWUSER_WIDTH_P) ||
        (MC_CFG_P.WUSER_WIDTH_P  != AXI4_CFG_P.WUSER_WIDTH_P)  ||
        (MC_CFG_P.BUSER_WIDTH_P  != AXI4_CFG_P.BUSER_WIDTH_P)  ||
        (MC_CFG_P.ARUSER_WIDTH_P != AXI4_CFG_P.ARUSER_WIDTH_P) ||
        (MC_CFG_P.RUSER_WIDTH_P  != AXI4_CFG_P.RUSER_WIDTH_P)) begin
      $error("vip_mc_axi4_connect requires matching vip_mc/vip_axi4 cfg widths");
      $fatal(1);
    end
  end

  // ---------------------------------------------------------------------------
  // Write address channel.
  // ---------------------------------------------------------------------------
  assign mc_awid     = man_awid;
  assign mc_awaddr   = man_awaddr;
  assign mc_awlen    = man_awlen;
  assign mc_awsize   = man_awsize;
  assign mc_awburst  = man_awburst;
  assign mc_awlock   = man_awlock;
  assign mc_awcache  = man_awcache;
  assign mc_awprot   = man_awprot;
  assign mc_awqos    = man_awqos;
  assign mc_awregion = man_awregion;
  assign mc_awuser   = man_awuser;
  assign mc_awvalid  = man_awvalid_d;
  assign man_awready = rst_n ? (mc_awready & man_awvalid_d) : 1'b0;
  // ---------------------------------------------------------------------------
  // Write data channel.
  // ---------------------------------------------------------------------------
  assign mc_wdata   = man_wdata;
  assign mc_wstrb   = man_wstrb;
  assign mc_wlast   = man_wlast;
  assign mc_wuser   = man_wuser;
  assign mc_wvalid  = man_wvalid;
  assign man_wready = mc_wready;

  // ---------------------------------------------------------------------------
  // Write response channel.
  // ---------------------------------------------------------------------------
  assign man_bid    = mc_bid;
  assign man_bresp  = mc_bresp;
  assign man_buser  = mc_buser;
  assign man_bvalid = mc_bvalid;
  assign mc_bready  = man_bready;

  // ---------------------------------------------------------------------------
  // Read address channel.
  // ---------------------------------------------------------------------------
  assign mc_arid     = man_arid;
  assign mc_araddr   = man_araddr;
  assign mc_arlen    = man_arlen;
  assign mc_arsize   = man_arsize;
  assign mc_arburst  = man_arburst;
  assign mc_arlock   = man_arlock;
  assign mc_arcache  = man_arcache;
  assign mc_arprot   = man_arprot;
  assign mc_arqos    = man_arqos;
  assign mc_arregion = man_arregion;
  assign mc_aruser   = man_aruser;
  assign mc_arvalid  = man_arvalid_d;
  assign man_arready = rst_n ? (mc_arready & man_arvalid_d) : 1'b0;
  // ---------------------------------------------------------------------------
  // Read data channel.
  // ---------------------------------------------------------------------------
  assign man_rid    = mc_rid;
  assign man_rdata  = mc_rdata;
  assign man_rresp  = mc_rresp;
  assign man_rlast  = mc_rlast;
  assign man_ruser  = mc_ruser;
  assign man_rvalid = mc_rvalid;
  assign mc_rready  = man_rready;

  // ---------------------------------------------------------------------------
  // Delay manager AxVALID by one cycle so vip_mc samples the request after the
  // stock manager drives it, then clear the delayed valid once the manager-side
  // handshake completes to avoid re-issuing the same request on vip_mc.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      man_awvalid_d <= 1'b0;
      man_arvalid_d <= 1'b0;
    end
    else begin
      if (man_awvalid && man_awready) begin
        man_awvalid_d <= 1'b0;
      end
      else begin
        man_awvalid_d <= man_awvalid;
      end

      if (man_arvalid && man_arready) begin
        man_arvalid_d <= 1'b0;
      end
      else begin
        man_arvalid_d <= man_arvalid;
      end
    end
  end

endmodule
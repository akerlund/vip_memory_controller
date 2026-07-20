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
// vip_mc_axi4_if
//
// vip_mc's OWN AXI4 controller-side interface. It has a SINGLE driving
// clocking block (controller_cb) for the subordinate-responder role plus an
// all-input monitor_cb — there is NO ROLE_P parameter and NO role-gated
// generate block, so the "two distinct SV types cannot alias one role-gated
// instance" trap does not arise. When the stock manager is reused, it drives a
// SEPARATE vip_axi4_if instance and vip_mc_axi4_connect cross-wires the two.
// No dependency on the AXI4 VIP. See vip_mc/IMPLEMENTATION_PLAN.md
// "Interface ownership".
// -----------------------------------------------------------------------------

`ifndef VIP_MC_AXI4_IF
`define VIP_MC_AXI4_IF

import vip_mc_axi4_types_pkg::*;

interface vip_mc_axi4_if #(
  parameter vip_mc_axi4_cfg_t CFG_P = '{default: '0}
  )(
    input clk,
    input rst_n
  );

  // Note: USER widths follow CFG_P verbatim (>= 1 by convention) so the
  // vip_mc_axi4_connect bridge to a stock vip_axi4_if is a clean 1:1.

  // Write Address Channel
  logic   [CFG_P.AWID_WIDTH_P-1 : 0] awid;
  logic   [CFG_P.ADDR_WIDTH_P-1 : 0] awaddr;
  logic                      [7 : 0] awlen;
  logic                      [2 : 0] awsize;
  logic                      [1 : 0] awburst;
  logic                              awlock;
  logic                      [3 : 0] awcache;
  logic                      [2 : 0] awprot;
  logic                      [3 : 0] awqos;
  logic                      [3 : 0] awregion;
  logic [CFG_P.AWUSER_WIDTH_P-1 : 0] awuser;
  logic                              awvalid;
  logic                              awready;

  // Write Data Channel
  logic [(8 * CFG_P.WDATA_BYTES_P)-1 : 0] wdata;
  logic       [CFG_P.WDATA_BYTES_P-1 : 0] wstrb;
  logic                                   wlast;
  logic       [CFG_P.WUSER_WIDTH_P-1 : 0] wuser;
  logic                                   wvalid;
  logic                                   wready;

  // Write Response Channel
  logic  [CFG_P.AWID_WIDTH_P-1 : 0] bid;
  logic                     [1 : 0] bresp;
  logic [CFG_P.BUSER_WIDTH_P-1 : 0] buser;
  logic                             bvalid;
  logic                             bready;

  // Read Address Channel
  logic   [CFG_P.ARID_WIDTH_P-1 : 0] arid;
  logic   [CFG_P.ADDR_WIDTH_P-1 : 0] araddr;
  logic                      [7 : 0] arlen;
  logic                      [2 : 0] arsize;
  logic                      [1 : 0] arburst;
  logic                              arlock;
  logic                      [3 : 0] arcache;
  logic                      [2 : 0] arprot;
  logic                      [3 : 0] arqos;
  logic                      [3 : 0] arregion;
  logic [CFG_P.ARUSER_WIDTH_P-1 : 0] aruser;
  logic                              arvalid;
  logic                              arready;

  // Read Data Channel
  logic        [CFG_P.ARID_WIDTH_P-1 : 0] rid;
  logic [(8 * CFG_P.RDATA_BYTES_P)-1 : 0] rdata;
  logic                           [1 : 0] rresp;
  logic                                   rlast;
  logic       [CFG_P.RUSER_WIDTH_P-1 : 0] ruser;
  logic                                   rvalid;
  logic                                   rready;

  // ---------------------------------------------------------------------------
  // Controller-side (subordinate-responder) driving clocking block. vip_mc
  // DRIVES the *ready / B / R response signals and SAMPLES the AW/W/AR payload
  // plus bready/rready.
  // ---------------------------------------------------------------------------
  clocking controller_cb @(posedge clk);

    default input #1step output #0;

    // Write Address Channel
    input  awid;
    input  awaddr;
    input  awlen;
    input  awsize;
    input  awburst;
    input  awlock;
    input  awcache;
    input  awprot;
    input  awqos;
    input  awregion;
    input  awuser;
    input  awvalid;
    output awready;

    // Write Data Channel
    input  wdata;
    input  wstrb;
    input  wlast;
    input  wuser;
    input  wvalid;
    output wready;

    // Write Response Channel
    output bid;
    output bresp;
    output buser;
    output bvalid;
    input  bready;

    // Read Address Channel
    input  arid;
    input  araddr;
    input  arlen;
    input  arsize;
    input  arburst;
    input  arlock;
    input  arcache;
    input  arprot;
    input  arqos;
    input  arregion;
    input  aruser;
    input  arvalid;
    output arready;

    // Read Data Channel
    output rid;
    output rdata;
    output rresp;
    output rlast;
    output ruser;
    output rvalid;
    input  rready;
  endclocking
  modport controller (clocking controller_cb, input clk, input rst_n);

  // ---------------------------------------------------------------------------
  // Passive monitor clocking block — all inputs.
  // ---------------------------------------------------------------------------
  clocking monitor_cb @(posedge clk);

    default input #1step;

    // Write Address Channel
    input awid;
    input awaddr;
    input awlen;
    input awsize;
    input awburst;
    input awlock;
    input awcache;
    input awprot;
    input awqos;
    input awregion;
    input awuser;
    input awvalid;
    input awready;

    // Write Data Channel
    input wdata;
    input wstrb;
    input wlast;
    input wuser;
    input wvalid;
    input wready;

    // Write Response Channel
    input bid;
    input bresp;
    input buser;
    input bvalid;
    input bready;

    // Read Address Channel
    input arid;
    input araddr;
    input arlen;
    input arsize;
    input arburst;
    input arlock;
    input arcache;
    input arprot;
    input arqos;
    input arregion;
    input aruser;
    input arvalid;
    input arready;

    // Read Data Channel
    input rid;
    input rdata;
    input rresp;
    input rlast;
    input ruser;
    input rvalid;
    input rready;
  endclocking
  modport monitor (clocking monitor_cb, input clk, input rst_n);

endinterface

`endif

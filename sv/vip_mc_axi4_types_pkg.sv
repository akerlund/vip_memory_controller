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
// vip_mc_axi4_types_pkg
//
// vip_mc's OWN AXI4 width/cfg types and AXI4 constants. By design this package
// has NO dependency on the AXI4 VIP (no vip_axi4_types_pkg / vip_axi4_agent_pkg
// import). The duplication of the AXI4 width-struct shape is the deliberate
// price of decoupling vip_mc from the AXI4 agent — see
// vip_mc/IMPLEMENTATION_PLAN.md "New decisions" and "Native AXI4-face config".
// -----------------------------------------------------------------------------

`ifndef VIP_MC_AXI4_TYPES_PKG
`define VIP_MC_AXI4_TYPES_PKG

package vip_mc_axi4_types_pkg;

  // ---------------------------------------------------------------------------
  // AXI4 spec constants (vip_mc's own copies — no vip_axi4_types_pkg).
  // ---------------------------------------------------------------------------
  localparam int VIP_MC_AXI4_MAX_LENGTH_C          = 256;
  localparam int VIP_MC_AXI4_4K_ADDRESS_BOUNDARY_C = 4096;

  // Response codes (AWRESP/BRESP/RRESP).
  localparam logic [1 : 0] VIP_MC_AXI4_RESP_OKAY_C   = 2'b00;
  localparam logic [1 : 0] VIP_MC_AXI4_RESP_EXOKAY_C = 2'b01;
  localparam logic [1 : 0] VIP_MC_AXI4_RESP_SLVERR_C = 2'b10;
  localparam logic [1 : 0] VIP_MC_AXI4_RESP_DECERR_C = 2'b11;

  // Burst codes (AWBURST/ARBURST). First cut models INCR only.
  localparam logic [1 : 0] VIP_MC_AXI4_BURST_FIXED_C = 2'b00;
  localparam logic [1 : 0] VIP_MC_AXI4_BURST_INCR_C  = 2'b01;
  localparam logic [1 : 0] VIP_MC_AXI4_BURST_WRAP_C  = 2'b10;

  // Burst-size encoding: 2^N bytes per beat (AWSIZE/ARSIZE).
  localparam logic [2 : 0] VIP_MC_AXI4_SIZE_1B_C   = 3'b000;
  localparam logic [2 : 0] VIP_MC_AXI4_SIZE_2B_C   = 3'b001;
  localparam logic [2 : 0] VIP_MC_AXI4_SIZE_4B_C   = 3'b010;
  localparam logic [2 : 0] VIP_MC_AXI4_SIZE_8B_C   = 3'b011;
  localparam logic [2 : 0] VIP_MC_AXI4_SIZE_16B_C  = 3'b100;
  localparam logic [2 : 0] VIP_MC_AXI4_SIZE_32B_C  = 3'b101;
  localparam logic [2 : 0] VIP_MC_AXI4_SIZE_64B_C  = 3'b110;
  localparam logic [2 : 0] VIP_MC_AXI4_SIZE_128B_C = 3'b111;

  // ---------------------------------------------------------------------------
  // AXI4-face width struct. Same shape as a generic AXI4 cfg (so the
  // vip_mc_axi4_connect bridge to a stock vip_axi4_if is a clean 1:1), but it
  // is vip_mc's OWN type — the connector requires both structs to describe
  // identical physical widths.
  // ---------------------------------------------------------------------------
  typedef struct packed {
    int AWID_WIDTH_P;
    int ARID_WIDTH_P;
    int ADDR_WIDTH_P;
    int WDATA_BYTES_P;
    int RDATA_BYTES_P;
    int AWUSER_WIDTH_P;
    int WUSER_WIDTH_P;
    int BUSER_WIDTH_P;
    int ARUSER_WIDTH_P;
    int RUSER_WIDTH_P;
  } vip_mc_axi4_cfg_t;

  // ---------------------------------------------------------------------------
  // CFG_P-derived scalar typedefs. Consumers alias the ones they use, e.g.
  //   typedef vip_mc_axi4_types #(CFG_P)::addr_t addr_t;
  // so widths are computed once and stay consistent across the driver and
  // interface.
  // ---------------------------------------------------------------------------
  class vip_mc_axi4_types #(
    vip_mc_axi4_cfg_t CFG_P = '{default: '0}
  );

    typedef logic       [CFG_P.ADDR_WIDTH_P  - 1 : 0] addr_t;
    typedef logic [(8 * CFG_P.WDATA_BYTES_P) - 1 : 0] wdata_t;
    typedef logic [(8 * CFG_P.RDATA_BYTES_P) - 1 : 0] rdata_t;
    typedef logic       [CFG_P.WDATA_BYTES_P - 1 : 0] wstrb_t;
    typedef logic        [CFG_P.AWID_WIDTH_P - 1 : 0] awid_t;
    typedef logic        [CFG_P.ARID_WIDTH_P - 1 : 0] arid_t;

    // USER channels clamp to a minimum width of 1 so structs/queues stay legal
    // when a given USER_WIDTH is 0. Test "is USER present" via CFG_P directly.
    typedef logic [((CFG_P.AWUSER_WIDTH_P > 0) ? CFG_P.AWUSER_WIDTH_P : 1) - 1 : 0] awuser_t;
    typedef logic [((CFG_P.WUSER_WIDTH_P  > 0) ? CFG_P.WUSER_WIDTH_P  : 1) - 1 : 0] wuser_t;
    typedef logic [((CFG_P.BUSER_WIDTH_P  > 0) ? CFG_P.BUSER_WIDTH_P  : 1) - 1 : 0] buser_t;
    typedef logic [((CFG_P.ARUSER_WIDTH_P > 0) ? CFG_P.ARUSER_WIDTH_P : 1) - 1 : 0] aruser_t;
    typedef logic [((CFG_P.RUSER_WIDTH_P  > 0) ? CFG_P.RUSER_WIDTH_P  : 1) - 1 : 0] ruser_t;
  endclass

  // ---------------------------------------------------------------------------
  // AWSIZE/ARSIZE byte count <-> encoding helpers.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Convert an AXI4 AxSIZE encoding into bytes per beat.
  // ---------------------------------------------------------------------------
  function automatic int vip_mc_axi4_size_bytes(logic [2 : 0] axsize);
    return (1 << axsize);
  endfunction

endpackage

`endif

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
// vip_mc_tb_top
//
// Top module for the minimal vip_mc example harness. It provides a clocked
// owned AXI4 interface instance and publishes that virtual interface to the UVM
// testbench before run_test().
// -----------------------------------------------------------------------------
import uvm_pkg::*;
import vip_chi_types_pkg::*;
import vip_mc_tb_pkg::*;
import vip_mc_tc_pkg::*;

module vip_mc_tb_top;

  // Clock and reset are owned by the vip_clk_rst_agent: the agent driver toggles
  // clk_rst_vif.clk and drives rst_n from a reset_sequence started in the base
  // test. No hand-rolled clock generation or reset override lives here anymore.
  clk_rst_if clk_rst_vif ();

  vip_mc_status_if #(N_PORTS_C) status_vif (
    .clk   ( clk_rst_vif.clk   ),
    .rst_n ( clk_rst_vif.rst_n )
  );

  vip_mc_axi4_if #(VIP_MC_AXI4_CFG_C) mc_vif0 (
    .clk   ( clk_rst_vif.clk   ),
    .rst_n ( clk_rst_vif.rst_n )
  );

  vip_mc_axi4_if #(VIP_MC_AXI4_CFG_C) mc_vif1 (
    .clk   ( clk_rst_vif.clk   ),
    .rst_n ( clk_rst_vif.rst_n )
  );

  vip_axi4_if #(VIP_AXI4_AGENT_CFG_C, VIP_AXI4_ROLE_MANAGER_E) man_vif0 (
    .clk   ( clk_rst_vif.clk   ),
    .rst_n ( clk_rst_vif.rst_n )
  );

  vip_axi4_if #(VIP_AXI4_AGENT_CFG_C, VIP_AXI4_ROLE_MANAGER_E) man_vif1 (
    .clk   ( clk_rst_vif.clk   ),
    .rst_n ( clk_rst_vif.rst_n )
  );

  vip_mc_axi4_connect #(VIP_MC_AXI4_CFG_C, VIP_AXI4_AGENT_CFG_C) connect0 (
    .clk   ( clk_rst_vif.clk   ),
    .rst_n ( clk_rst_vif.rst_n ),
    .man_awid     ( man_vif0.awid     ),
    .man_awaddr   ( man_vif0.awaddr   ),
    .man_awlen    ( man_vif0.awlen    ),
    .man_awsize   ( man_vif0.awsize   ),
    .man_awburst  ( man_vif0.awburst  ),
    .man_awlock   ( man_vif0.awlock   ),
    .man_awcache  ( man_vif0.awcache  ),
    .man_awprot   ( man_vif0.awprot   ),
    .man_awqos    ( man_vif0.awqos    ),
    .man_awregion ( man_vif0.awregion ),
    .man_awuser   ( man_vif0.awuser   ),
    .man_awvalid  ( man_vif0.awvalid  ),
    .man_awready  ( man_vif0.awready  ),
    .man_wdata    ( man_vif0.wdata    ),
    .man_wstrb    ( man_vif0.wstrb    ),
    .man_wlast    ( man_vif0.wlast    ),
    .man_wuser    ( man_vif0.wuser    ),
    .man_wvalid   ( man_vif0.wvalid   ),
    .man_wready   ( man_vif0.wready   ),
    .man_bid      ( man_vif0.bid      ),
    .man_bresp    ( man_vif0.bresp    ),
    .man_buser    ( man_vif0.buser    ),
    .man_bvalid   ( man_vif0.bvalid   ),
    .man_bready   ( man_vif0.bready   ),
    .man_arid     ( man_vif0.arid     ),
    .man_araddr   ( man_vif0.araddr   ),
    .man_arlen    ( man_vif0.arlen    ),
    .man_arsize   ( man_vif0.arsize   ),
    .man_arburst  ( man_vif0.arburst  ),
    .man_arlock   ( man_vif0.arlock   ),
    .man_arcache  ( man_vif0.arcache  ),
    .man_arprot   ( man_vif0.arprot   ),
    .man_arqos    ( man_vif0.arqos    ),
    .man_arregion ( man_vif0.arregion ),
    .man_aruser   ( man_vif0.aruser   ),
    .man_arvalid  ( man_vif0.arvalid  ),
    .man_arready  ( man_vif0.arready  ),
    .man_rid      ( man_vif0.rid      ),
    .man_rdata    ( man_vif0.rdata    ),
    .man_rresp    ( man_vif0.rresp    ),
    .man_rlast    ( man_vif0.rlast    ),
    .man_ruser    ( man_vif0.ruser    ),
    .man_rvalid   ( man_vif0.rvalid   ),
    .man_rready   ( man_vif0.rready   ),
    .mc_awid      ( mc_vif0.awid      ),
    .mc_awaddr    ( mc_vif0.awaddr    ),
    .mc_awlen     ( mc_vif0.awlen     ),
    .mc_awsize    ( mc_vif0.awsize    ),
    .mc_awburst   ( mc_vif0.awburst   ),
    .mc_awlock    ( mc_vif0.awlock    ),
    .mc_awcache   ( mc_vif0.awcache   ),
    .mc_awprot    ( mc_vif0.awprot    ),
    .mc_awqos     ( mc_vif0.awqos     ),
    .mc_awregion  ( mc_vif0.awregion  ),
    .mc_awuser    ( mc_vif0.awuser    ),
    .mc_awvalid   ( mc_vif0.awvalid   ),
    .mc_awready   ( mc_vif0.awready   ),
    .mc_wdata     ( mc_vif0.wdata     ),
    .mc_wstrb     ( mc_vif0.wstrb     ),
    .mc_wlast     ( mc_vif0.wlast     ),
    .mc_wuser     ( mc_vif0.wuser     ),
    .mc_wvalid    ( mc_vif0.wvalid    ),
    .mc_wready    ( mc_vif0.wready    ),
    .mc_bid       ( mc_vif0.bid       ),
    .mc_bresp     ( mc_vif0.bresp     ),
    .mc_buser     ( mc_vif0.buser     ),
    .mc_bvalid    ( mc_vif0.bvalid    ),
    .mc_bready    ( mc_vif0.bready    ),
    .mc_arid      ( mc_vif0.arid      ),
    .mc_araddr    ( mc_vif0.araddr    ),
    .mc_arlen     ( mc_vif0.arlen     ),
    .mc_arsize    ( mc_vif0.arsize    ),
    .mc_arburst   ( mc_vif0.arburst   ),
    .mc_arlock    ( mc_vif0.arlock    ),
    .mc_arcache   ( mc_vif0.arcache   ),
    .mc_arprot    ( mc_vif0.arprot    ),
    .mc_arqos     ( mc_vif0.arqos     ),
    .mc_arregion  ( mc_vif0.arregion  ),
    .mc_aruser    ( mc_vif0.aruser    ),
    .mc_arvalid   ( mc_vif0.arvalid   ),
    .mc_arready   ( mc_vif0.arready   ),
    .mc_rid       ( mc_vif0.rid       ),
    .mc_rdata     ( mc_vif0.rdata     ),
    .mc_rresp     ( mc_vif0.rresp     ),
    .mc_rlast     ( mc_vif0.rlast     ),
    .mc_ruser     ( mc_vif0.ruser     ),
    .mc_rvalid    ( mc_vif0.rvalid    ),
    .mc_rready    ( mc_vif0.rready    )
  );

  vip_mc_axi4_connect #(VIP_MC_AXI4_CFG_C, VIP_AXI4_AGENT_CFG_C) connect1 (
    .clk   ( clk_rst_vif.clk   ),
    .rst_n ( clk_rst_vif.rst_n ),
    .man_awid     ( man_vif1.awid     ),
    .man_awaddr   ( man_vif1.awaddr   ),
    .man_awlen    ( man_vif1.awlen    ),
    .man_awsize   ( man_vif1.awsize   ),
    .man_awburst  ( man_vif1.awburst  ),
    .man_awlock   ( man_vif1.awlock   ),
    .man_awcache  ( man_vif1.awcache  ),
    .man_awprot   ( man_vif1.awprot   ),
    .man_awqos    ( man_vif1.awqos    ),
    .man_awregion ( man_vif1.awregion ),
    .man_awuser   ( man_vif1.awuser   ),
    .man_awvalid  ( man_vif1.awvalid  ),
    .man_awready  ( man_vif1.awready  ),
    .man_wdata    ( man_vif1.wdata    ),
    .man_wstrb    ( man_vif1.wstrb    ),
    .man_wlast    ( man_vif1.wlast    ),
    .man_wuser    ( man_vif1.wuser    ),
    .man_wvalid   ( man_vif1.wvalid   ),
    .man_wready   ( man_vif1.wready   ),
    .man_bid      ( man_vif1.bid      ),
    .man_bresp    ( man_vif1.bresp    ),
    .man_buser    ( man_vif1.buser    ),
    .man_bvalid   ( man_vif1.bvalid   ),
    .man_bready   ( man_vif1.bready   ),
    .man_arid     ( man_vif1.arid     ),
    .man_araddr   ( man_vif1.araddr   ),
    .man_arlen    ( man_vif1.arlen    ),
    .man_arsize   ( man_vif1.arsize   ),
    .man_arburst  ( man_vif1.arburst  ),
    .man_arlock   ( man_vif1.arlock   ),
    .man_arcache  ( man_vif1.arcache  ),
    .man_arprot   ( man_vif1.arprot   ),
    .man_arqos    ( man_vif1.arqos    ),
    .man_arregion ( man_vif1.arregion ),
    .man_aruser   ( man_vif1.aruser   ),
    .man_arvalid  ( man_vif1.arvalid  ),
    .man_arready  ( man_vif1.arready  ),
    .man_rid      ( man_vif1.rid      ),
    .man_rdata    ( man_vif1.rdata    ),
    .man_rresp    ( man_vif1.rresp    ),
    .man_rlast    ( man_vif1.rlast    ),
    .man_ruser    ( man_vif1.ruser    ),
    .man_rvalid   ( man_vif1.rvalid   ),
    .man_rready   ( man_vif1.rready   ),
    .mc_awid      ( mc_vif1.awid      ),
    .mc_awaddr    ( mc_vif1.awaddr    ),
    .mc_awlen     ( mc_vif1.awlen     ),
    .mc_awsize    ( mc_vif1.awsize    ),
    .mc_awburst   ( mc_vif1.awburst   ),
    .mc_awlock    ( mc_vif1.awlock    ),
    .mc_awcache   ( mc_vif1.awcache   ),
    .mc_awprot    ( mc_vif1.awprot    ),
    .mc_awqos     ( mc_vif1.awqos     ),
    .mc_awregion  ( mc_vif1.awregion  ),
    .mc_awuser    ( mc_vif1.awuser    ),
    .mc_awvalid   ( mc_vif1.awvalid   ),
    .mc_awready   ( mc_vif1.awready   ),
    .mc_wdata     ( mc_vif1.wdata     ),
    .mc_wstrb     ( mc_vif1.wstrb     ),
    .mc_wlast     ( mc_vif1.wlast     ),
    .mc_wuser     ( mc_vif1.wuser     ),
    .mc_wvalid    ( mc_vif1.wvalid    ),
    .mc_wready    ( mc_vif1.wready    ),
    .mc_bid       ( mc_vif1.bid       ),
    .mc_bresp     ( mc_vif1.bresp     ),
    .mc_buser     ( mc_vif1.buser     ),
    .mc_bvalid    ( mc_vif1.bvalid    ),
    .mc_bready    ( mc_vif1.bready    ),
    .mc_arid      ( mc_vif1.arid      ),
    .mc_araddr    ( mc_vif1.araddr    ),
    .mc_arlen     ( mc_vif1.arlen     ),
    .mc_arsize    ( mc_vif1.arsize    ),
    .mc_arburst   ( mc_vif1.arburst   ),
    .mc_arlock    ( mc_vif1.arlock    ),
    .mc_arcache   ( mc_vif1.arcache   ),
    .mc_arprot    ( mc_vif1.arprot    ),
    .mc_arqos     ( mc_vif1.arqos     ),
    .mc_arregion  ( mc_vif1.arregion  ),
    .mc_aruser    ( mc_vif1.aruser    ),
    .mc_arvalid   ( mc_vif1.arvalid   ),
    .mc_arready   ( mc_vif1.arready   ),
    .mc_rid       ( mc_vif1.rid       ),
    .mc_rdata     ( mc_vif1.rdata     ),
    .mc_rresp     ( mc_vif1.rresp     ),
    .mc_rlast     ( mc_vif1.rlast     ),
    .mc_ruser     ( mc_vif1.ruser     ),
    .mc_rvalid    ( mc_vif1.rvalid    ),
    .mc_rready    ( mc_vif1.rready    )
  );

  // ---------------------------------------------------------------------------
  // CHI slice: vip_mc's owned SN interface plus a stock vip_chi RN-I manager
  // interface, bridged by vip_mc_chi_connect (B1 two-instance pattern). Both are
  // clocked/reset by the shared clk_rst agent, so the CHI test env's reset
  // sequence drives them exactly as it drives the AXI4 slice. These sit idle for
  // the AXI4 tests (no CHI env built) and carry traffic for tc_vip_mc_chi_*.
  // ---------------------------------------------------------------------------
  vip_mc_chi_if #(VIP_MC_CHI_CFG_C) mc_chi_vif (
    .clk   ( clk_rst_vif.clk   ),
    .rst_n ( clk_rst_vif.rst_n )
  );

  vip_chi_if #(VIP_CHI_CFG_C, chi_types_t, VIP_CHI_ROLE_RNI_E) rni_vif (
    .clk   ( clk_rst_vif.clk   ),
    .rst_n ( clk_rst_vif.rst_n )
  );

  vip_mc_chi_connect u_chi_connect (
    .mc ( mc_chi_vif ),
    .rn ( rni_vif    )
  );

  // CHI-E variant of the slice (the D/E matrix). A second SN+RN-I interface pair
  // built with the issue=E cfg family, bridged by its own connect. Only one test
  // runs per simv, so these share the CHI-D config_db keys below -- uvm_config_db
  // separates entries by their parameterized vif type, so a CHI-D env resolves
  // the D vifs and a CHI-E env the E vifs from the same key strings.
  vip_mc_chi_if #(VIP_MC_CHI_CFG_E_C) mc_chi_vif_e (
    .clk   ( clk_rst_vif.clk   ),
    .rst_n ( clk_rst_vif.rst_n )
  );

  vip_chi_if #(VIP_CHI_CFG_E_C, chi_types_e_t, VIP_CHI_ROLE_RNI_E) rni_vif_e (
    .clk   ( clk_rst_vif.clk   ),
    .rst_n ( clk_rst_vif.rst_n )
  );

  vip_mc_chi_connect u_chi_connect_e (
    .mc ( mc_chi_vif_e ),
    .rn ( rni_vif_e    )
  );

  // Narrow-DAT (32 B) CHI slice for the multi-beat gather test: a 64 B WriteNoSnp
  // presents two 32 B DAT beats that gather into one 64 B DRAM row word. Same
  // config_db keys as the CHI-D slice, distinguished by the parameterized vif type.
  vip_mc_chi_if #(VIP_MC_CHI_CFG_N32_C) mc_chi_vif_n32 (
    .clk   ( clk_rst_vif.clk   ),
    .rst_n ( clk_rst_vif.rst_n )
  );

  vip_chi_if #(VIP_CHI_CFG_N32_C, chi_types_n32_t, VIP_CHI_ROLE_RNI_E) rni_vif_n32 (
    .clk   ( clk_rst_vif.clk   ),
    .rst_n ( clk_rst_vif.rst_n )
  );

  vip_mc_chi_connect u_chi_connect_n32 (
    .mc ( mc_chi_vif_n32 ),
    .rn ( rni_vif_n32    )
  );

  initial begin
    uvm_config_db #(virtual clk_rst_if)::set(
      null,
      "*",
      "clk_rst_vif",
      clk_rst_vif);
    uvm_config_db #(virtual vip_mc_status_if #(N_PORTS_C))::set(
      null,
      "*",
      "status_vif",
      status_vif);
    uvm_config_db #(virtual vip_mc_axi4_if #(VIP_MC_AXI4_CFG_C))::set(
      null,
      "*",
      "vif_port0",
      mc_vif0);
    uvm_config_db #(virtual vip_mc_axi4_if #(VIP_MC_AXI4_CFG_C))::set(
      null,
      "*",
      "vif_port1",
      mc_vif1);
    uvm_config_db #(virtual vip_axi4_if #(VIP_AXI4_AGENT_CFG_C, VIP_AXI4_ROLE_MANAGER_E))::set(
      null,
      "*",
      "man_vif_port0",
      man_vif0);
    uvm_config_db #(virtual vip_axi4_if #(VIP_AXI4_AGENT_CFG_C, VIP_AXI4_ROLE_MANAGER_E))::set(
      null,
      "*",
      "man_vif_port1",
      man_vif1);

    // CHI slice: vip_mc resolves its SN vif from env_cfg (filled from this key
    // by the CHI test env); the RN-I manager gets its vif directly by path.
    uvm_config_db #(virtual vip_mc_chi_if #(VIP_MC_CHI_CFG_C))::set(
      null,
      "*",
      "mc_chi_vif",
      mc_chi_vif);
    uvm_config_db #(virtual vip_chi_if #(VIP_CHI_CFG_C, chi_types_t, VIP_CHI_ROLE_RNI_E))::set(
      uvm_root::get(),
      "uvm_test_top.env.rni_agent",
      "vif",
      rni_vif);

    // CHI-E slice: same keys/paths as the CHI-D slice above, distinguished only
    // by the parameterized vif type (issue=E). A CHI-E test's env gets these.
    uvm_config_db #(virtual vip_mc_chi_if #(VIP_MC_CHI_CFG_E_C))::set(
      null,
      "*",
      "mc_chi_vif",
      mc_chi_vif_e);
    uvm_config_db #(virtual vip_chi_if #(VIP_CHI_CFG_E_C, chi_types_e_t, VIP_CHI_ROLE_RNI_E))::set(
      uvm_root::get(),
      "uvm_test_top.env.rni_agent",
      "vif",
      rni_vif_e);

    // Narrow-DAT (32 B) CHI slice: same keys/paths, distinguished by vif type.
    uvm_config_db #(virtual vip_mc_chi_if #(VIP_MC_CHI_CFG_N32_C))::set(
      null,
      "*",
      "mc_chi_vif",
      mc_chi_vif_n32);
    uvm_config_db #(virtual vip_chi_if #(VIP_CHI_CFG_N32_C, chi_types_n32_t, VIP_CHI_ROLE_RNI_E))::set(
      uvm_root::get(),
      "uvm_test_top.env.rni_agent",
      "vif",
      rni_vif_n32);

    $timeformat(-9, 3, " ns", 11);
    run_test();
    $stop();
  end

endmodule
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
// vip_mc_pkg
//
// Umbrella package for the first vip_mc implementation slice. It imports the
// device model and the vip_mc-owned AXI4/type packages, then includes the UVM
// class items that define the config and environment boundary.
// -----------------------------------------------------------------------------
`ifndef VIP_MC_PKG
`define VIP_MC_PKG

package vip_mc_pkg;

  timeunit      1ns;
  timeprecision 1ps;

  `include "uvm_macros.svh"
  import uvm_pkg::*;

  // bool_t/TRUE/FALSE come from vip_mc's own vip_mc_types_pkg (below).
  import vip_dram_types_pkg::*;
  import vip_dram_pkg::*;

  import vip_mc_axi4_types_pkg::*;
  import vip_mc_types_pkg::*;

  // CHI front-end is an opt-in layer (VIP_MC_ENABLE_CHI). The AXI4-only core
  // carries NO vip_chi dependency (CHI decision 7); the flit/opcode/width types
  // are reused from vip_chi_types_pkg only when the CHI path is compiled.
`ifdef VIP_MC_ENABLE_CHI
  import vip_chi_types_pkg::*;
`endif

  `include "vip_mc_axi4_cfg.sv"
  `include "vip_mc_chi_cfg.sv"
  `include "vip_mc_port_runtime_cfg.sv"
  `include "vip_mc_config.sv"
  `include "vip_mc_vif_holder.sv"
  `include "vip_mc_axi4_vif_holder.sv"
  `include "vip_mc_env_cfg.sv"
  `include "vip_mc_status_snapshot.sv"
  `include "vip_mc_cmd_entry.sv"
  `include "vip_mc_activity_fifo.sv"
  `include "vip_mc_cmd_queue.sv"
  `include "vip_mc_fe_base.sv"
  `include "vip_mc_refresh.sv"
  `include "vip_mc_backend.sv"
  `include "vip_mc_axi4_driver.sv"
`ifdef VIP_MC_ENABLE_CHI
  `include "vip_mc_chi_cmd_entry.sv"
  `include "vip_mc_chi_vif_holder.sv"
  `include "vip_mc_chi_driver.sv"
`endif
  `include "vip_mc.sv"

endpackage

`endif

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
// vip_mc.svh
//
// Compile header for the first vip_mc slice. Pulls in the owned AXI4 types and
// interface, the shared vip_mc types package, and the umbrella package with the
// config/env classes.
// -----------------------------------------------------------------------------
`ifndef VIP_MC_SVH
`define VIP_MC_SVH

`include "vip_mem_types_pkg.sv"
`include "vip_memory_pkg.sv"
`include "vip_dram.svh"
`include "vip_mc_axi4_types_pkg.sv"
`include "vip_mc_types_pkg.sv"
`include "vip_mc_axi4_if.sv"
`include "vip_mc_status_if.sv"
`ifdef VIP_MC_ENABLE_CHI
`include "vip_chi_types_pkg.sv"
`include "vip_mc_chi_if.sv"
`endif
`include "vip_mc_pkg.sv"

`endif

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
// vip_mc_axi4_vif_holder
//
// Typed holder for one AXI4 host interface. The env aggregator stores it as a
// vip_mc_vif_holder base handle and the vip_mc top resolves it back by a
// constant-index cast per port.
// -----------------------------------------------------------------------------
class vip_mc_axi4_vif_holder #(
  vip_mc_axi4_cfg_t AXI4_CFG_P = '{default: '0}
  ) extends vip_mc_vif_holder;

  virtual vip_mc_axi4_if #(AXI4_CFG_P) vif;

  `uvm_object_param_utils(vip_mc_axi4_vif_holder #(AXI4_CFG_P))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(string name = "vip_mc_axi4_vif_holder");
    super.new(name);
    this.proto = VIP_MC_PROTO_AXI4_E;
  endfunction

endclass
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
// vip_mc_fe_base
//
// Abstract per-port front-end base for vip_mc. Concrete protocol drivers own
// the host-interface semantics and feed command entries into the backend over
// req_port.
// -----------------------------------------------------------------------------
virtual class vip_mc_fe_base #(
  vip_dram_cfg_t DRAM_CFG_P = VIP_DRAM_CFG_DEFAULT_C
  ) extends uvm_component;

  typedef vip_mc_cmd_entry #(DRAM_CFG_P) cmd_t;

  int port_id = 0;
  uvm_analysis_port #(cmd_t) req_port;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
    this.req_port = new("req_port", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Deliver one completed backend entry back to the owning front-end.
  // ---------------------------------------------------------------------------
  pure virtual function void complete(input cmd_t entry);

  // ---------------------------------------------------------------------------
  // Clear all front-end runtime state and drive the owned outputs to their
  // reset values (reset choreography, §9). Invoked by vip_mc::handle_reset on
  // negedge rst_n so no B/R completion is driven for an outstanding txn.
  // ---------------------------------------------------------------------------
  pure virtual function void handle_reset();

endclass
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
// vip_mc_port_runtime_cfg
//
// Runtime, per-port policy state for vip_mc. The compile-time protocol/width
// selection lives in PORTS[]; this object carries only access ownership and the
// fallback vif key used by the top-level config path.
// -----------------------------------------------------------------------------
class vip_mc_port_runtime_cfg extends uvm_object;

  vip_mc_addr_region_t regions[$];
  int                  arb_weight = 1;
  string               vif_key    = "";

  `uvm_object_utils(vip_mc_port_runtime_cfg)

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(string name = "vip_mc_port_runtime_cfg");
    super.new(name);
  endfunction

  // ---------------------------------------------------------------------------
  // Clear the explicit address-ownership list for this port.
  // ---------------------------------------------------------------------------
  function void clear_regions();
    this.regions.delete();
  endfunction

  // ---------------------------------------------------------------------------
  // Add one inclusive owned address range.
  // ---------------------------------------------------------------------------
  function void add_region(longint unsigned lo, longint unsigned hi);
    vip_mc_addr_region_t region;

    if (lo > hi) begin
      `uvm_fatal(get_name(), $sformatf(
        "Region lo > hi (lo=0x%0h hi=0x%0h)", lo, hi))
    end

    region.lo = lo;
    region.hi = hi;
    this.regions.push_back(region);
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether the address is allowed by this port's region map.
  // ---------------------------------------------------------------------------
  function bool_t allows_addr(longint unsigned addr);
    if (this.regions.size() == 0) begin
      return TRUE;
    end

    foreach (this.regions[i]) begin
      if (vip_mc_addr_in_region(addr, this.regions[i])) begin
        return TRUE;
      end
    end
    return FALSE;
  endfunction

endclass
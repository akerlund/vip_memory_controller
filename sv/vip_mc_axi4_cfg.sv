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
// vip_mc_axi4_cfg
//
// Native AXI4-face knobs for vip_mc. This object deliberately carries only MC
// concerns: finite acceptance budgets, QoS mapping, exclusive support, and the
// MC-owned DECERR map. There is no vip_axi4_cfg_sub dependency.
// -----------------------------------------------------------------------------
class vip_mc_axi4_cfg extends uvm_object;

  int aw_outstanding_limit = 0;
  int ar_outstanding_limit = 0;

  int aw_pending_depth     = 0;
  int w_data_buf_depth     = 0;

  int qos_class_map [16];

  bit exclusive_enabled  = 1'b1;

  longint unsigned decerr_addr_lo [$];
  longint unsigned decerr_addr_hi [$];

  string dram_handle_path = "uvm_test_top.env.dram";

  `uvm_object_utils(vip_mc_axi4_cfg)

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(string name = "vip_mc_axi4_cfg");
    super.new(name);
    foreach (this.qos_class_map[i]) begin
      this.qos_class_map[i] = i;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Add one inclusive DECERR address range.
  // ---------------------------------------------------------------------------
  function void add_decerr_range(longint unsigned lo, longint unsigned hi);
    if (lo > hi) begin
      `uvm_fatal(get_name(), $sformatf(
        "DECERR range lo > hi (lo=0x%0h hi=0x%0h)", lo, hi))
    end
    this.decerr_addr_lo.push_back(lo);
    this.decerr_addr_hi.push_back(hi);
  endfunction

  // ---------------------------------------------------------------------------
  // Clear the DECERR address map.
  // ---------------------------------------------------------------------------
  function void clear_decerr_ranges();
    this.decerr_addr_lo.delete();
    this.decerr_addr_hi.delete();
  endfunction

  // ---------------------------------------------------------------------------
  // Return whether the supplied address is DECERR-mapped.
  // ---------------------------------------------------------------------------
  function bool_t is_decerr_addr(longint unsigned addr);
    foreach (this.decerr_addr_lo[i]) begin
      if ((addr >= this.decerr_addr_lo[i]) && (addr <= this.decerr_addr_hi[i])) begin
        return TRUE;
      end
    end
    return FALSE;
  endfunction

  // ---------------------------------------------------------------------------
  // Map a 4-bit AxQOS value to its configured scheduler class.
  // ---------------------------------------------------------------------------
  function int qos_to_class(int unsigned axqos);
    int idx;

    idx = (axqos > 15) ? 15 : int'(axqos);
    if (this.qos_class_map[idx] < 0) begin
      return 0;
    end
    return this.qos_class_map[idx];
  endfunction

endclass
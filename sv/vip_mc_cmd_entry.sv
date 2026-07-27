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
// vip_mc_cmd_entry
//
// Internal MC request/completion item carried between the protocol front-end
// and the shared backend. This first implementation slice keeps the full field
// shape needed by the plan even though only a subset is exercised by the build
// and config smoke tests.
// -----------------------------------------------------------------------------
class vip_mc_cmd_entry #(
  vip_dram_cfg_t DRAM_CFG_P = VIP_DRAM_CFG_DEFAULT_C
  ) extends uvm_object;

  typedef vip_dram_types #(DRAM_CFG_P)::data_t data_t;
  typedef vip_dram_types #(DRAM_CFG_P)::strb_t strb_t;

  longint unsigned tag = '0;
  int              port_id = 0;
  longint unsigned axi4_id = '0;
  vip_dram_op_t    op = VIP_DRAM_OP_RD_E;
  longint unsigned addr = '0;
  int unsigned     beats = 1;
  int unsigned     axi_beats = 1;
  int unsigned     axi_size_bytes = 1;
  logic [1 : 0]    axi_burst = VIP_MC_AXI4_BURST_INCR_C;
  int unsigned     captured_w_beats = 0;
  bit              has_explicit_rank = 1'b0;
  int unsigned     rank = '0;
  int unsigned     qos = '0;
  int unsigned     qos_class = '0;
  realtime         admit_time = 0.0;
  longint unsigned admit_order = '0;
  // FR-FCFS starvation cap (§11 item 1): how many times this queued entry has
  // been reordered past by a younger readiness-winner. When it reaches
  // cfg.fr_fcfs_starvation_cap the backend force-serves it (FCFS override).
  int unsigned     bypass_count = 0;
  bit              is_exclusive = 1'b0;
  longint unsigned auser = '0;
  longint unsigned wuser = '0;
  data_t           wdata[];
  strb_t           wstrb[];
  realtime         enqueue_time = 0.0;

  bit              pre_resolved = 1'b0;
  logic [1 : 0]    resp = VIP_MC_AXI4_RESP_OKAY_C;
  data_t           rdata[];
  realtime         first_beat_ready_time = 0.0;
  realtime         last_beat_ready_time  = 0.0;
  bit              completed = 1'b0;

  // Write coalescing (§11): when this entry is the primary of a coalesced write,
  // it holds the secondary entries whose host writes were merged into it. Each
  // secondary still owes its originator a completion, so the backend fans out one
  // complete() per secondary (in arrival order) when the primary's device
  // response returns. Empty for a non-coalesced entry.
  vip_mc_cmd_entry #(DRAM_CFG_P) merged_writes[$];

  `uvm_object_param_utils(vip_mc_cmd_entry #(DRAM_CFG_P))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(string name = "vip_mc_cmd_entry");
    super.new(name);
  endfunction

  // ---------------------------------------------------------------------------
  // Return the device-facing base address of this access: the lowest byte
  // address of its burst window.
  //
  // This is NOT always addr. addr is the protocol start address (AWADDR/ARADDR),
  // which is what the front-end needs for lane placement, exclusive-monitor
  // keying and region checks. The payload arrays below (wdata/wstrb/rdata) are
  // row-indexed from the burst window base instead, and beats counts the rows
  // from that base - so the device access must start there too. The two differ
  // only for a WRAP burst that does not begin at its wrap-region base; issuing
  // such an access at addr would place every row rotated by the start offset and
  // push the last row one row past the region, corrupting a neighbour.
  //
  // Non-AXI4 front-ends leave axi_burst at its INCR default, so this returns addr
  // for them and for backend-generated refresh entries.
  // ---------------------------------------------------------------------------
  function longint unsigned get_dev_addr();

    return vip_mc_axi4_types_pkg::vip_mc_axi4_burst_window_first_addr(
      .addr       ( this.addr           ),
      .size_bytes ( this.axi_size_bytes ),
      .beats      ( this.axi_beats      ),
      .axburst    ( this.axi_burst      )
    );
  endfunction

endclass
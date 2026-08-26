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
// vip_mc_chi_cfg
//
// Native CHI-face knobs for vip_mc's SN (memory-target) front-end. Like
// vip_mc_axi4_cfg, this object carries only MC concerns and deliberately has NO
// vip_chi dependency (CHI decision 7) -- it is a plain int/bit config, so it can
// live in the always-compiled core and hang off vip_mc_config unconditionally.
// The CHI front-end (compiled only under +define+VIP_MC_ENABLE_CHI) reads these
// at build time; the MC-owned DECERR map / per-port regions stay on the shared
// vip_mc_config (the CHI driver reuses them exactly as the AXI4 driver does).
// -----------------------------------------------------------------------------
class vip_mc_chi_cfg extends uvm_object;

  // SN node id advertised as the completer / HomeNID in outbound RSP/DAT flits.
  int unsigned sn_node_id = 0;

  // Initial inbound receive-credit budgets the SN advertises after link
  // activation: REQ lets the RN send requests, DAT lets it send write data, RSP
  // lets it send CompAck. Fifteen is the CHI protocol maximum. The values are
  // intentionally still configurable above that maximum so a negative-control
  // test can model a broken peer and prove the checker catches it.
  int initial_req_credits = 15;
  int initial_rsp_credits = 15;
  int initial_dat_credits = 15;

  // Write-response style: 1 = split (DBIDResp early to release write data, then a
  // deferred Comp paced to the device); 0 = combined (single CompDBIDResp).
  bit split_write_rsp = 1'b1;

  `uvm_object_utils(vip_mc_chi_cfg)

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(string name = "vip_mc_chi_cfg");
    super.new(name);
  endfunction

  // ---------------------------------------------------------------------------
  // Validate the CHI knobs. Called from vip_mc_config::validate().
  // ---------------------------------------------------------------------------
  function void validate();
    if (this.initial_req_credits < 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "initial_req_credits must be >= 1 (got %0d)", this.initial_req_credits))
    end
    if (this.initial_rsp_credits < 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "initial_rsp_credits must be >= 1 (got %0d)", this.initial_rsp_credits))
    end
    if (this.initial_dat_credits < 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "initial_dat_credits must be >= 1 (got %0d)", this.initial_dat_credits))
    end
    // Keep values above the CHI maximum representable for negative-control
    // tests. Normal configurations use the protocol-max default of 15.
    if (this.initial_req_credits > 15) begin
      `uvm_warning("VIP_MC_CHI_CFG", $sformatf(
        "initial_req_credits (%0d) exceeds the CHI maximum of 15; retained for checker-negative testing",
        this.initial_req_credits))
    end
    if (this.initial_rsp_credits > 15) begin
      `uvm_warning("VIP_MC_CHI_CFG", $sformatf(
        "initial_rsp_credits (%0d) exceeds the CHI maximum of 15; retained for checker-negative testing",
        this.initial_rsp_credits))
    end
    if (this.initial_dat_credits > 15) begin
      `uvm_warning("VIP_MC_CHI_CFG", $sformatf(
        "initial_dat_credits (%0d) exceeds the CHI maximum of 15; retained for checker-negative testing",
        this.initial_dat_credits))
    end
  endfunction

endclass

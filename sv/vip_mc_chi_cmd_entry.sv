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
// vip_mc_chi_cmd_entry
//
// CHI-specialized command entry. It extends the protocol-agnostic
// vip_mc_cmd_entry with the CHI request context the front-end needs to build the
// completion flits (node ids, TxnID/DBID, ordering, exclusive/expcompack, and
// the CHI response-error code). The backend only ever touches the base fields,
// and it round-trips the same object handle back through complete(), so the
// CHI front-end recovers this context with a single $cast.
//
// Compiled only on the CHI path (VIP_MC_ENABLE_CHI); see vip_mc_pkg.sv.
// -----------------------------------------------------------------------------
class vip_mc_chi_cmd_entry #(
  vip_dram_cfg_t DRAM_CFG_P = VIP_DRAM_CFG_DEFAULT_C
  ) extends vip_mc_cmd_entry #(DRAM_CFG_P);

  // CHI node routing.
  longint unsigned chi_srcid       = '0;  // original requester
  longint unsigned chi_tgtid       = '0;  // this SN node id (req.tgtid)
  longint unsigned chi_txnid       = '0;  // requester TxnID
  longint unsigned chi_dbid        = '0;  // DBID granted for the write buffer
  longint unsigned chi_return_nid  = '0;  // ReadNoSnpSep return node
  longint unsigned chi_return_txn  = '0;  // ReadNoSnpSep return TxnID
  int unsigned     chi_qos         = '0;

  // Request classification.
  bit              chi_is_write        = 1'b0;
  bit              chi_is_write_zero   = 1'b0;
  bit              chi_is_sep_read     = 1'b0;  // ReadNoSnpSep -> DataSepResp
  bit              chi_needs_receipt   = 1'b0;  // ordered read -> ReadReceipt
  bit              chi_split_write_rsp = 1'b0;  // DBIDResp + deferred Comp
  bit              chi_exp_comp_ack    = 1'b0;  // wait for CompAck

  // CHI response-error code (vip_chi_resp_err_t encoding): 0=OKAY, 1=EXOKAY,
  // 2=DATAERR, 3=NONDATAERR. Kept as a plain 2-bit code so the base cmd entry
  // stays protocol-agnostic; mapped to the flit field by the driver.
  logic [1 : 0]    chi_resp_err        = 2'b00;

  // Write-data assembly bookkeeping (how many write DAT beats collected so far).
  int unsigned     chi_wr_beats_seen   = 0;

  // Number of CHI DAT beats on the link for this transfer (may exceed the base
  // `beats` DRAM-row count when DATA_BYTES_P < ROW_BYTES_P: several DATA_BYTES
  // link beats gather into one ROW_BYTES device row word).
  int unsigned     chi_dat_beats       = 1;

  // Exact transfer byte count (1 << req.size), used for byte-accurate region /
  // DECERR classification (a sub-row transfer must not be rounded up to a row).
  int unsigned     chi_size_bytes      = 1;

  `uvm_object_param_utils(vip_mc_chi_cmd_entry #(DRAM_CFG_P))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(string name = "vip_mc_chi_cmd_entry");
    super.new(name);
  endfunction

endclass

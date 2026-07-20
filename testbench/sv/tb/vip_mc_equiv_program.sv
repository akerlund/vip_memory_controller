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
// vip_mc_equiv_program
//
// The single deterministic op list every equivalence test replays (AXI4, CHI-D,
// CHI-E). Ops are protocol-uniform on purpose -- full-line writes, byte-enabled
// partial writes, and reads -- so the three protocols do apples-to-apples work
// (the E-only WriteNoSnpZero / ReadNoSnpSep are covered by their own directed
// tests, not here). Every op is a single ROW_BYTES line at a row-aligned address.
// Each write carries a full be[] (all-ones for full writes) so a replay can map
// it straight onto AXI4 WSTRB / CHI byte-enables and onto the golden model.
// -----------------------------------------------------------------------------
class vip_mc_equiv_program;

  // ---------------------------------------------------------------------------
  // Build the shared program. Line layout (base = EQ_BASE_ADDR_C, stride =
  // EQ_LINE_STRIDE_C): every line is seeded with a full write before any partial
  // write or read, so every byte a read observes is model-defined.
  // ---------------------------------------------------------------------------
  static function void build(output eq_txn_t q []);
    int unsigned     nb;
    longint unsigned a;

    nb = DRAM_CFG_C.ROW_BYTES_P;
    q  = new[0];

    // Line 0: full write (counter from 0x00, step 1), read back.
    a = EQ_BASE_ADDR_C + (0 * EQ_LINE_STRIDE_C);
    push(q, make_full(a, nb, 8'h00, 8'h01));
    push(q, make_read(a, nb));

    // Line 1: full write (0x40, step 1), partial overwrite of the low half, read.
    a = EQ_BASE_ADDR_C + (1 * EQ_LINE_STRIDE_C);
    push(q, make_full(a, nb, 8'h40, 8'h01));
    push(q, make_ptl_lowhalf(a, nb, 8'hEE));
    push(q, make_read(a, nb));

    // Line 2: full write (0x80, step 3), partial overwrite of odd bytes, read.
    a = EQ_BASE_ADDR_C + (2 * EQ_LINE_STRIDE_C);
    push(q, make_full(a, nb, 8'h80, 8'h03));
    push(q, make_ptl_odd(a, nb, 8'h11));
    push(q, make_read(a, nb));

    // Line 3: full write (0xC0, step 7), read back.
    a = EQ_BASE_ADDR_C + (3 * EQ_LINE_STRIDE_C);
    push(q, make_full(a, nb, 8'hC0, 8'h07));
    push(q, make_read(a, nb));
  endfunction

  // ---------------------------------------------------------------------------
  // Append one transaction to the dynamic array (grow-by-one helper).
  // ---------------------------------------------------------------------------
  static function void push(ref eq_txn_t q [], input eq_txn_t t);
    eq_txn_t grown [];
    grown = new[q.size() + 1](q);
    grown[q.size()] = t;
    q = grown;
  endfunction

  // ---------------------------------------------------------------------------
  // Full-line write: counter payload, all byte-enables set.
  // ---------------------------------------------------------------------------
  static function eq_txn_t make_full(
    input longint unsigned a,
    input int unsigned     nb,
    input byte unsigned    start,
    input byte unsigned    step
  );
    eq_txn_t t;
    t.op     = EQ_WRITE_FULL_E;
    t.addr   = a;
    t.nbytes = nb;
    t.data   = new[nb];
    t.be     = new[nb];
    for (int i = 0; i < nb; i++) begin
      t.data[i] = start + (step * i);
      t.be[i]   = 1'b1;
    end
    return t;
  endfunction

  // ---------------------------------------------------------------------------
  // Partial write of the low half of the line to a constant value.
  // ---------------------------------------------------------------------------
  static function eq_txn_t make_ptl_lowhalf(
    input longint unsigned a,
    input int unsigned     nb,
    input byte unsigned    val
  );
    eq_txn_t t;
    t.op     = EQ_WRITE_PTL_E;
    t.addr   = a;
    t.nbytes = nb;
    t.data   = new[nb];
    t.be     = new[nb];
    for (int i = 0; i < nb; i++) begin
      t.data[i] = val;
      t.be[i]   = (i < (nb / 2));
    end
    return t;
  endfunction

  // ---------------------------------------------------------------------------
  // Partial write of the odd bytes of the line to a per-byte-varying value.
  // ---------------------------------------------------------------------------
  static function eq_txn_t make_ptl_odd(
    input longint unsigned a,
    input int unsigned     nb,
    input byte unsigned    val
  );
    eq_txn_t t;
    t.op     = EQ_WRITE_PTL_E;
    t.addr   = a;
    t.nbytes = nb;
    t.data   = new[nb];
    t.be     = new[nb];
    for (int i = 0; i < nb; i++) begin
      t.data[i] = val + i;
      t.be[i]   = ((i % 2) == 1);
    end
    return t;
  endfunction

  // ---------------------------------------------------------------------------
  // Read of one line.
  // ---------------------------------------------------------------------------
  static function eq_txn_t make_read(
    input longint unsigned a,
    input int unsigned     nb
  );
    eq_txn_t t;
    t.op     = EQ_READ_E;
    t.addr   = a;
    t.nbytes = nb;
    t.data   = new[0];
    t.be     = new[0];
    return t;
  endfunction

endclass

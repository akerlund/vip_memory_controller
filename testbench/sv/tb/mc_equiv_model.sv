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
// mc_equiv_model
//
// Protocol-neutral golden memory for the AXI4/CHI-D/CHI-E equivalence suite. It
// is a sparse byte-addressed reference image: writes apply byte-enable-gated
// stores, reads are checked against it. Each equivalence test drives the SAME
// deterministic program (see mc_equiv_program) through one protocol front-end
// and checks every read-back against a fresh instance of this model. Because all
// three tests build the model from the identical program, passing all three is a
// transitive proof that AXI4, CHI-D, and CHI-E land byte-identical device state
// and return byte-identical read data.
// -----------------------------------------------------------------------------
class mc_equiv_model extends uvm_object;

  // Sparse byte-addressed golden image (only written bytes are present).
  byte unsigned mem [longint unsigned];

  `uvm_object_utils(mc_equiv_model)

  function new(input string name = "mc_equiv_model");
    super.new(name);
  endfunction

  // ---------------------------------------------------------------------------
  // Drop all golden state (fresh model per test).
  // ---------------------------------------------------------------------------
  function void clear();
    this.mem.delete();
  endfunction

  // ---------------------------------------------------------------------------
  // Apply a byte-enabled write: store data[i] at addr+i for every enabled byte.
  // An empty (or short) be[] treats the corresponding bytes as enabled, so a
  // full write may pass be = '{} or an all-ones vector interchangeably.
  // ---------------------------------------------------------------------------
  function void write(
    input longint unsigned addr,
    input byte unsigned    data [],
    input bit              be   []
  );
    foreach (data[i]) begin
      if ((be.size() <= i) || be[i]) begin
        this.mem[addr + i] = data[i];
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Expected bytes for a read of nbytes at addr (untouched bytes read as 0x00).
  // ---------------------------------------------------------------------------
  function void expected(
    input  longint unsigned addr,
    input  int unsigned     nbytes,
    output byte unsigned    exp []
  );
    exp = new[nbytes];
    for (int i = 0; i < nbytes; i++) begin
      exp[i] = this.mem.exists(addr + i) ? this.mem[addr + i] : 8'h00;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Compare observed read bytes against the model. Raises one uvm_error per
  // mismatching byte and returns 0 on any mismatch (1 if the line matched).
  // ---------------------------------------------------------------------------
  function bit check_read(
    input longint unsigned addr,
    input byte unsigned    got [],
    input string           ctx
  );
    byte unsigned exp [];
    bit           ok;

    ok = 1'b1;
    this.expected(addr, got.size(), exp);
    foreach (got[i]) begin
      if (got[i] !== exp[i]) begin
        ok = 1'b0;
        `uvm_error("equiv_model", $sformatf(
          "%s: read mismatch at addr 0x%0h byte %0d: got 0x%02h expected 0x%02h",
          ctx, addr, i, got[i], exp[i]))
      end
    end
    return ok;
  endfunction

endclass

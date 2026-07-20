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
// tc_vip_mc_equiv_axi4
//
// AXI4 leg of the protocol-equivalence suite. It replays the shared deterministic
// program (vip_mc_equiv_program) through the AXI4 front-end -- full-line writes,
// byte-enabled partial writes (WSTRB), and reads -- and checks every read-back
// against a fresh golden model. The CHI-D/CHI-E legs replay the identical program
// against the same model logic; all three passing proves the three protocols land
// byte-identical device state and return byte-identical read data.
// -----------------------------------------------------------------------------
class tc_vip_mc_equiv_axi4 extends vip_mc_base_test;

  `uvm_component_utils(tc_vip_mc_equiv_axi4)

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task body();
    vip_mc_equiv_model model;
    eq_txn_t           prog [];
    wdata_t            dword;
    wstrb_t            sword;
    wdata_t            data_q [];
    wstrb_t            strb_q [];
    rdata_t            rdata_q [];
    resp_t             rresp_q [];
    resp_t             bresp;
    byte unsigned      got [];

    this.wait_for_reset_release();

    model = vip_mc_equiv_model::type_id::create("model");
    model.clear();
    vip_mc_equiv_program::build(prog);

    foreach (prog[k]) begin
      eq_txn_t t;
      t = prog[k];

      if (t.op == EQ_READ_E) begin
        this.axi4_read_burst(t.addr, 1, rdata_q, rresp_q);
        if (rresp_q[0] !== 2'b00) begin
          `uvm_error(get_name(), $sformatf(
            "AXI4 read at 0x%0h returned RRESP 0x%0h", t.addr, rresp_q[0]))
        end
        got = new[t.nbytes];
        for (int i = 0; i < t.nbytes; i++) begin
          got[i] = rdata_q[0][(8 * i) +: 8];
        end
        void'(model.check_read(t.addr, got, "axi4"));
      end
      else begin
        dword = '0;
        sword = '0;
        foreach (t.data[i]) dword[(8 * i) +: 8] = t.data[i];
        foreach (t.be[i])   sword[i]            = t.be[i];
        data_q = new[1];
        strb_q = new[1];
        data_q[0] = dword;
        strb_q[0] = sword;
        this.axi4_write_burst(t.addr, data_q, strb_q, bresp);
        if (bresp !== 2'b00) begin
          `uvm_error(get_name(), $sformatf(
            "AXI4 write at 0x%0h returned BRESP 0x%0h", t.addr, bresp))
        end
        model.write(t.addr, t.data, t.be);
      end
    end

    `uvm_info(get_name(), "AXI4 equivalence replay matched the golden model", UVM_LOW)
  endtask

endclass

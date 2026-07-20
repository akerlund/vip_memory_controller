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
// vip_mc_equiv_chi_base_test (+ tc_vip_mc_equiv_chi_d / _e leaves)
//
// CHI legs of the protocol-equivalence suite. The parameterized base replays the
// shared deterministic program (vip_mc_equiv_program) through the CHI SN front-
// end -- WriteNoSnpFull, WriteNoSnpPtl (byte-enabled), and ReadNoSnp -- and checks
// every read-back against a fresh golden model, exactly as the AXI4 leg does. It
// is parameterized over the (vip_chi, vip_mc) cfg pair so one body serves both
// issues; the two registered leaves pin CHI-D and CHI-E. All three legs (AXI4,
// CHI-D, CHI-E) matching the same model proves byte-identical device state and
// read data across the protocols.
// -----------------------------------------------------------------------------
class vip_mc_equiv_chi_base_test #(
  vip_chi_cfg_t    CHI_CFG_P    = VIP_CHI_CFG_C,
  vip_mc_chi_cfg_t MC_CHI_CFG_P = VIP_MC_CHI_CFG_C
  ) extends vip_mc_chi_base_test #(CHI_CFG_P, MC_CHI_CFG_P);

  `uvm_component_param_utils(vip_mc_equiv_chi_base_test #(CHI_CFG_P, MC_CHI_CFG_P))

  typedef vip_chi_item #(CHI_CFG_P) item_t;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task body();
    vip_mc_equiv_model model;
    eq_txn_t           prog [];
    item_t             read_responses [$];
    item_t::data_t     data_q [$];
    item_t::be_t       be_q [$];
    item_t::data_t     dword;
    item_t::be_t       bword;
    byte unsigned      got [];

    this.wait_reset_and_settle();

    model = vip_mc_equiv_model::type_id::create("model");
    model.clear();
    vip_mc_equiv_program::build(prog);

    foreach (prog[k]) begin
      eq_txn_t t;
      t = prog[k];

      if (t.op == EQ_READ_E) begin
        this._rd_seq.reset();
        this._rd_seq.set_requests(1);
        this._rd_seq.set_initial_addr(item_t::addr_t'(t.addr));
        this._rd_seq.set_size(3'($clog2(t.nbytes)));
        this._rd_seq.set_allow_retry(1'b0);
        this._rd_seq.set_get_response(1'b1);
        this._rd_seq.set_verbose(1'b0);
        this._rd_seq.start(this._env.rni_agent.sequencer);

        read_responses = this._rd_seq.get_responses();
        if ((read_responses.size() != 1) || (read_responses[0].data.size() != 1)) begin
          `uvm_fatal(get_name(), $sformatf(
            "CHI read at 0x%0h returned %0d completions", t.addr, read_responses.size()))
        end
        got = new[t.nbytes];
        for (int i = 0; i < t.nbytes; i++) begin
          got[i] = read_responses[0].data[0][(8 * i) +: 8];
        end
        void'(model.check_read(t.addr, got, get_name()));
      end
      else begin
        dword = '0;
        bword = '0;
        foreach (t.data[i]) dword[(8 * i) +: 8] = t.data[i];
        foreach (t.be[i])   bword[i]            = t.be[i];
        data_q = '{dword};
        be_q   = '{bword};

        this._wr_seq.reset();
        this._wr_seq.set_requests(1);
        this._wr_seq.set_initial_addr(item_t::addr_t'(t.addr));
        this._wr_seq.set_size(3'($clog2(t.nbytes)));
        this._wr_seq.set_allow_retry(1'b0);
        this._wr_seq.set_data_type(VIP_CHI_DATA_CUSTOM_E);
        this._wr_seq.set_data(data_q);
        if (t.op == EQ_WRITE_PTL_E) begin
          this._wr_seq.set_be(be_q);   // custom BE => WriteNoSnpPtl
        end
        this._wr_seq.set_get_response(1'b1);
        this._wr_seq.set_verbose(1'b0);
        this._wr_seq.start(this._env.rni_agent.sequencer);

        model.write(t.addr, t.data, t.be);
      end
    end

    `uvm_info(get_name(), "CHI equivalence replay matched the golden model", UVM_LOW)
  endtask

endclass

// CHI-D leg.
class tc_vip_mc_equiv_chi_d extends vip_mc_equiv_chi_base_test #(VIP_CHI_CFG_C, VIP_MC_CHI_CFG_C);
  `uvm_component_utils(tc_vip_mc_equiv_chi_d)
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass

// CHI-E leg.
class tc_vip_mc_equiv_chi_e extends vip_mc_equiv_chi_base_test #(VIP_CHI_CFG_E_C, VIP_MC_CHI_CFG_E_C);
  `uvm_component_utils(tc_vip_mc_equiv_chi_e)
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass

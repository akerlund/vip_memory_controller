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
// mc_scoreboard
//
// Timing scoreboard for the vip_mc example (§13.2 / P0-2b). It proves the VIP's
// central claim — believable latency driven by vip_dram's prediction — by
// comparing observed AXI4 B/R completion timing against dram.predict().
//
// How it works:
//   1. Predict in grant order. It subscribes to backend.issued_port (the
//      grant-ordered vip_mc_cmd_entry stream, REF included, §8.9). For each
//      granted FE entry it builds the equivalent vip_dram_req and calls
//      dram.predict() — side-effect free — storing the predicted last-beat
//      ready time in a per-{port, axi4_id} FIFO. Predicting off the grant tap
//      (not AXI4 acceptance order) folds in refresh and multi-port arbitration,
//      the §5.6 predict-ordering rule.
//   2. Correlate to the bus. It subscribes to each manager monitor's
//      bresp_port / rdata_port; each observed B/R is matched to the head
//      prediction for its {port, id} stream (same-ID order is guaranteed, §5.2).
//   3. Check timing. Observed completion time is compared to the predicted
//      last-beat time within an AXI4-handshake tolerance window.
//
// Lock-step caveat (P0-2b): predict() reads the LIVE device scheduler state, so
// it matches schedule() exactly when the device has already committed the
// earlier requests by the time this tap predicts the next — true for the
// sequential traffic the tests drive. When the backend issues several entries
// back-to-back at the same $realtime (deep multi-outstanding), the device may
// not yet have committed the earlier ones, so a strict prediction can diverge;
// `timing_check_enabled` gates the hard error for that case.
// -----------------------------------------------------------------------------

typedef class mc_scoreboard;

// -----------------------------------------------------------------------------
// Per-port B-response tap. Forwards each observed write completion to the
// scoreboard tagged with its originating port id.
// -----------------------------------------------------------------------------
class mc_sb_b_collector extends uvm_subscriber #(vip_axi4_item #(VIP_AXI4_AGENT_CFG_C));
  mc_scoreboard sb;
  int           port_id = 0;

  `uvm_component_utils(mc_sb_b_collector)

  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  function void write(input vip_axi4_item #(VIP_AXI4_AGENT_CFG_C) t);
    if (this.sb != null) begin
      this.sb.observe_b(this.port_id, t);
    end
  endfunction
endclass

// -----------------------------------------------------------------------------
// Per-port R-response tap. Forwards each observed read completion to the
// scoreboard tagged with its originating port id.
// -----------------------------------------------------------------------------
class mc_sb_r_collector extends uvm_subscriber #(vip_axi4_item #(VIP_AXI4_AGENT_CFG_C));
  mc_scoreboard sb;
  int           port_id = 0;

  `uvm_component_utils(mc_sb_r_collector)

  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  function void write(input vip_axi4_item #(VIP_AXI4_AGENT_CFG_C) t);
    if (this.sb != null) begin
      this.sb.observe_r(this.port_id, t);
    end
  endfunction
endclass

`uvm_analysis_imp_decl(_issued)

class mc_scoreboard extends uvm_component;

  typedef vip_mc_cmd_entry #(DRAM_CFG_C)           cmd_t;
  typedef vip_dram_req     #(DRAM_CFG_C)           req_t;
  typedef vip_axi4_item    #(VIP_AXI4_AGENT_CFG_C) axi4_item_t;

  typedef struct {
    longint unsigned tag;
    realtime         pred_first;  // device-predicted first-beat ready time
    realtime         pred_last;   // device-predicted last-beat ready time
    bit              predicted;   // 0 for pre_resolved DECERR (MC-chosen timing)
  } pred_t;

  // Configuration (set by the env from config_db knobs).
  vip_dram #(DRAM_CFG_C) dram;
  bit                    timing_check_enabled = 1'b1;
  realtime               timing_tol_ns        = 30.0;   // residual handshake/phase slack (~11-26ns)
  // The last R beat lands at the later of the device's last-beat-ready time and
  // the bus-rate-limited drain of all beats from first-beat-ready: one R beat
  // per bus cycle means n beats need (n-1) cycles, so a burst whose device span
  // is tighter than the bus rate is bus-bound. expected = max(pred_last,
  // pred_first + (n-1)*beat_period). beat_period is the bus clock period.
  realtime               beat_period_ns       = 10.0;

  uvm_analysis_imp_issued #(cmd_t, mc_scoreboard) issued_export;
  mc_sb_b_collector                               b_collector[N_PORTS_C];
  mc_sb_r_collector                               r_collector[N_PORTS_C];

  // Per-{port, axi4_id} prediction FIFOs (one stream per key, same-ID ordered).
  protected pred_t wr_pending[string][$];
  protected pred_t rd_pending[string][$];

  protected int unsigned predicted_entries   = 0;
  protected int unsigned timing_checked       = 0;
  protected int unsigned timing_errors        = 0;
  protected int unsigned unpredicted_responses = 0;
  protected int unsigned decerr_responses      = 0;

  `uvm_component_utils(mc_scoreboard)

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
    this.issued_export = new("issued_export", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Build the per-port B/R taps and bind them back to this scoreboard.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    super.build_phase(phase);

    for (int port_id = 0; port_id < N_PORTS_C; port_id++) begin
      this.b_collector[port_id] = mc_sb_b_collector::type_id::create(
        $sformatf("b_collector_%0d", port_id), this);
      this.r_collector[port_id] = mc_sb_r_collector::type_id::create(
        $sformatf("r_collector_%0d", port_id), this);
      this.b_collector[port_id].sb      = this;
      this.b_collector[port_id].port_id = port_id;
      this.r_collector[port_id].sb      = this;
      this.r_collector[port_id].port_id = port_id;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Grant-order tap (§8.9). Predict per granted entry and queue it for the bus
  // match. REF entries carry no B/R and predict() is side-effect free, so they
  // are skipped here.
  // ---------------------------------------------------------------------------
  function void write_issued(input cmd_t e);
    req_t    req;
    realtime first_ready;
    realtime last_ready;
    pred_t   pr;
    string   k;

    if (e == null) begin
      return;
    end
    if (e.op == VIP_DRAM_OP_REF_E) begin
      return;
    end

    k      = this.stream_key(e.port_id, e.axi4_id);
    pr.tag = e.tag;

    if (e.pre_resolved) begin
      // DECERR / MC-chosen ready times (§5.1): the device does not time these.
      pr.predicted  = 1'b0;
      pr.pred_first = 0.0;
      pr.pred_last  = 0.0;
    end
    else if (this.dram == null) begin
      pr.predicted  = 1'b0;
      pr.pred_first = 0.0;
      pr.pred_last  = 0.0;
    end
    else begin
      req = req_t::type_id::create("sb_predict_req");
      // The device is issued at the burst window base, so predict from there.
      req.addr              = e.get_dev_addr();
      req.op                = e.op;
      req.beats             = e.beats;
      req.has_explicit_rank = e.has_explicit_rank;
      req.rank              = e.rank;
      req.tag               = e.tag;
      this.dram.predict(req, first_ready, last_ready);
      pr.predicted  = 1'b1;
      pr.pred_first = first_ready;
      pr.pred_last  = last_ready;
      this.predicted_entries++;
    end

    if (e.op == VIP_DRAM_OP_WR_E) begin
      this.wr_pending[k].push_back(pr);
    end
    else begin
      this.rd_pending[k].push_back(pr);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Observed write completion (B) on one port.
  // ---------------------------------------------------------------------------
  function void observe_b(input int port_id, input axi4_item_t t);
    // B is a single response regardless of the write burst length.
    this.check_completion(1'b1, port_id, longint'(t.bid), t.bresp, 1, $realtime);
  endfunction

  // ---------------------------------------------------------------------------
  // Observed read completion (R, last beat) on one port. The R-channel beat
  // count is authoritative from the returned data array.
  // ---------------------------------------------------------------------------
  function void observe_r(input int port_id, input axi4_item_t t);
    int n_beats;
    n_beats = (t.rdata.size() > 0) ? t.rdata.size() : 1;
    this.check_completion(1'b0, port_id, longint'(t.rid), t.rresp, n_beats, $realtime);
  endfunction

  // ---------------------------------------------------------------------------
  // Match one observed completion to its head prediction and check timing. A
  // DECERR completion (AXI4 resp 2'b11) is MC-resolved at the front-end (§4.4):
  // it never reaches the backend grant tap and its ready times are MC-chosen,
  // not predict()-driven, so it is counted and excluded from the timing check.
  // ---------------------------------------------------------------------------
  protected function void check_completion(
    input bit              is_wr,
    input int              port_id,
    input longint unsigned id,
    input logic [1 : 0]    resp,
    input int              n_beats,
    input realtime         obs_time
  );
    string   k;
    pred_t   pr;
    realtime expected_last;
    realtime delta;

    if (resp === 2'b11) begin
      this.decerr_responses++;
      return;
    end

    k = this.stream_key(port_id, id);

    // An OKAY/EXOKAY completion with no pending prediction is a front-end-
    // resolved response that bypassed the device + grant tap — a failed
    // exclusive write (returns OKAY, no device write, §4.6) being the case the
    // resp code cannot distinguish from a normal write. These are expected and
    // outside the device-timing contract, so they are counted, not errored.
    // (Spurious-response detection across reset is the reset-recovery test's
    // job, P2-1.)
    if (is_wr) begin
      if (!this.wr_pending.exists(k) || (this.wr_pending[k].size() == 0)) begin
        this.unpredicted_responses++;
        `uvm_info(get_name(), $sformatf(
          "Observed B with no device prediction (port=%0d id=0x%0h) — FE-resolved",
          port_id, id), UVM_MEDIUM)
        return;
      end
      pr = this.wr_pending[k].pop_front();
    end
    else begin
      if (!this.rd_pending.exists(k) || (this.rd_pending[k].size() == 0)) begin
        this.unpredicted_responses++;
        `uvm_info(get_name(), $sformatf(
          "Observed R with no device prediction (port=%0d id=0x%0h) — FE-resolved",
          port_id, id), UVM_MEDIUM)
        return;
      end
      pr = this.rd_pending[k].pop_front();
    end

    if (!pr.predicted) begin
      return;  // DECERR / MC-timed: no device prediction to check against
    end
    if (!this.timing_check_enabled) begin
      return;
    end

    this.timing_checked++;

    // Expected completion is the later of the device's last-beat-ready time and
    // the bus-rate-limited drain of all beats from first-beat-ready (one R beat
    // per bus cycle => (n_beats-1) cycles). A single B (or single-beat R)
    // reduces to pred_last. The residual is AXI4 handshake / clock-phase slack.
    expected_last = pr.pred_first + (realtime'(n_beats) - 1.0) * this.beat_period_ns;
    if (pr.pred_last > expected_last) begin
      expected_last = pr.pred_last;
    end
    delta = obs_time - expected_last;

    `uvm_info(get_name(), $sformatf(
      "timing %s port=%0d id=0x%0h tag=%0d beats=%0d obs=%0t pred_last=%0t expected=%0t delta=%0.3fns",
      is_wr ? "B" : "R", port_id, id, pr.tag, n_beats, obs_time, pr.pred_last, expected_last, delta),
      UVM_HIGH)

    // The completion can never be driven before the device produces it, and
    // should land within a small handshake window after the expected time.
    if ((delta < -2.0) || (delta > this.timing_tol_ns)) begin
      this.timing_errors++;
      `uvm_error(get_name(), $sformatf(
        "%s timing mismatch port=%0d id=0x%0h tag=%0d beats=%0d: observed=%0t expected=%0t (pred_last=%0t) delta=%0.3fns (tol=%0.3fns)",
        is_wr ? "B" : "R", port_id, id, pr.tag, n_beats, obs_time, expected_last, pr.pred_last, delta, this.timing_tol_ns))
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Per-stream ordering key for the prediction FIFOs.
  // ---------------------------------------------------------------------------
  protected function string stream_key(input int port_id, input longint unsigned id);
    return $sformatf("%0d:%0h", port_id, id);
  endfunction

  // ---------------------------------------------------------------------------
  // Telemetry accessors.
  // ---------------------------------------------------------------------------
  function int get_timing_checked_count(); return this.timing_checked;      endfunction
  function int get_timing_error_count();   return this.timing_errors;       endfunction
  function int get_predicted_count();      return this.predicted_entries;   endfunction

  // ---------------------------------------------------------------------------
  // End-of-test summary.
  // ---------------------------------------------------------------------------
  function void report_phase(input uvm_phase phase);
    int leftover;

    super.report_phase(phase);

    leftover = 0;
    foreach (this.wr_pending[k]) leftover += this.wr_pending[k].size();
    foreach (this.rd_pending[k]) leftover += this.rd_pending[k].size();

    `uvm_info(get_name(), $sformatf(
      "scoreboard summary: predicted=%0d timing_checked=%0d timing_errors=%0d decerr_responses=%0d unpredicted_responses=%0d in_flight_at_end=%0d (timing_check=%0b tol=%0.1fns)",
      this.predicted_entries, this.timing_checked, this.timing_errors,
      this.decerr_responses, this.unpredicted_responses, leftover,
      this.timing_check_enabled, this.timing_tol_ns),
      UVM_LOW)
  endfunction

endclass

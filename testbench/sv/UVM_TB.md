# vip_mc example — UVM testbench guide

This document explains how the `vip_mc` example testbench is built and, in
detail, how the structural top ([tb/mc_tb_top.sv](tb/mc_tb_top.sv))
works. For the per-testcase catalog see [../TEST_CASES.md](../TEST_CASES.md); for the
quick-start / regression-runner notes see [README.md](README.md).

Unlike the DUT-less `vip_chi` example, this example has a **real DUT in the
middle**: `vip_mc` (the memory controller) fronting a real `vip_dram` device.
Stimulus comes from stock VIP managers — a `vip_axi4_agent` MANAGER on the AXI4
side, a `vip_chi` RN-I agent on the CHI side — each cross-wired to `vip_mc`'s own
host interface by a `*_connect` bridge. The top hosts interfaces and bridges
only; every UVM component is built by the **test's env**.

---

## 1. Component hierarchy

The example has one **default env** plus three **self-contained envs**. Which one
is built is decided by the test's base class (only one test runs per `simv`, §3).

**Default AXI4 env** — `mc_base_test` → `mc_tb_env`:

```text
uvm_test_top : mc_base_test  (all tc_mc_axi4_* + cfg/refresh/qos/…)
  └─ env : mc_tb_env
       ├─ clk_agent    : clk_rst_agent                       // owns clk + rst_n
       ├─ dram         : vip_dram #(DRAM_CFG_C)              // the device model
       ├─ u_mc         : vip_mc #(DRAM_CFG_C, 2, PORTS_C)    // the DUT (2 AXI4 ports)
       ├─ man_agent[0] : vip_axi4_agent #(.., MANAGER)       // stock host, port 0
       ├─ man_agent[1] : vip_axi4_agent #(.., MANAGER)       // stock host, port 1
       └─ scoreboard   : mc_scoreboard                        // predict()-based timing check
```

**Self-contained CHI env** — `mc_chi_base_test #(CHI_CFG_P, MC_CHI_CFG_P)` →
`mc_chi_tb_env`:

```text
uvm_test_top : mc_chi_base_test #(...)   (tc_mc_chi_*, equiv chi legs)
  └─ _env : mc_chi_tb_env #(...)
       ├─ clk_agent  : clk_rst_agent
       ├─ dram       : vip_dram #(DRAM_CFG_C)
       ├─ u_mc       : vip_mc #(DRAM_CFG_C, 1, CHI_PORTS_L)  // one CHI SN port
       └─ rni_agent  : vip_chi_agent #(CHI_CFG_P, .., RNI)   // stock RN-I host
```

The base test is parameterized over the `(vip_chi_cfg, vip_mc_chi_cfg)` pair, so
the **same source** builds the CHI-D slice (default), the CHI-E slice
(`VIP_CHI_CFG_E_C` / `VIP_MC_CHI_CFG_E_C`), and the narrow-32 B-DAT slice
(`VIP_CHI_CFG_N32_C`). A CHI-E or narrow test is just a
`mc_chi_base_test #(...)` leaf specialized to that cfg pair.

**Self-contained mixed env** — `tc_mc_mixed_concurrent` and
`tc_mc_mixed_soak` (extend `uvm_test`)
→ `mc_mixed_tb_env`: one `vip_mc #(DRAM_CFG_C, 2, MIXED_PORTS_C)` with port 0
AXI4 (on `man_vif0`) and port 1 CHI-D (on `rni_vif`) over one shared `vip_dram`,
plus the stock `vip_axi4` MANAGER and `vip_chi` RN-I agents that drive them.

**Self-contained narrow-bus env** — `tc_mc_narrow_axi4` (extends `uvm_test`)
→ `mc_narrow_axi4_tb_env`: a one-port AXI4 `vip_mc` over a **128 B-row**
`vip_dram` (`NARROW_DRAM_CFG_C`) while the host bus stays 64 B, exercising the
`WDATA_BYTES < ROW_BYTES` multi-beat gather/scatter path with no new interfaces.

**Multi-rank env** — `tc_mc_multi_rank` (via `mc_multirank_base_test`)
builds its own 2-rank `vip_dram` geometry and a matching one-port AXI4 `vip_mc`.

Ownership and lifecycle:

- **`mc_neutral_base_test`** is the protocol-neutral base every example test extends.
  It owns the shared `report_server`, the `clk_rst_config` (10 ns period), the
  `reset_sequence`, the phase timeout, and the run-phase skeleton (own the initial
  reset, run `body()`, then log `u_mc.sprint_telemetry()`). Both protocol bases
  fill three hooks: build their env, return their clk_rst sequencer for the reset
  drive, and report telemetry.
- **`mc_base_test`** (extends `mc_neutral_base_test`) adds the AXI4 traffic helpers
  (`axi4_write_single`, `axi4_read_burst`, `axi4_write_custom_user_on_port`, …);
  it builds `mc_tb_env` and connects the manager monitor taps.
- **`mc_chi_base_test #(...)`** (extends `mc_neutral_base_test`) builds the CHI env
  and owns the RN-I traffic sequences.
- **`mc_tb_env`** builds the device, the DUT, the stock managers, the clk
  agent, and the scoreboard, and fills one `vip_mc_env_cfg` (QoS classes, aging,
  outstanding limits, buffer depths, addr-map, DECERR range, refresh/init knobs)
  that it `apply()`s into the DUT via `config_db`.
- **`mc_tb_top`** is structural only (§3).

---

## 2. Config: how the DUT is parameterized

`vip_mc` is pinned by three compile-time facts plus a runtime port map, all
declared in [tb/mc_tb_pkg.sv](tb/mc_tb_pkg.sv):

- `DRAM_CFG_C` — the device geometry the MC fronts (default
  `VIP_DRAM_CFG_DEFAULT_C`: 64 B row, 33-bit address, 1 rank). Sizes the neutral
  TLM and must equal the `vip_dram` instance's cfg.
- `N_PORTS_C` (= 2 for the default env) — number of host ports.
- `PORTS_C [N_PORTS_C]` — per-port descriptor `{proto, axi4, chi}`. Per the
  representative-cfg convention, `vip_mc` derives `AXI4_CFG_C` / `CHI_CFG_C` from
  `PORTS[0]`, so **every** entry carries a valid `.axi4` and (for the mixed env) a
  valid `.chi`, regardless of its own `proto`.

Runtime knobs are set into the env by the test through `config_db` (e.g.
`mc_refresh_policy`, `mc_refresh_max_deferred`, `mc_init_delay_enabled`,
`mc_init_delay_ns`, `mc_rsp_buf_depth`, `mc_trefi_override_ns`,
`mc_scoreboard_enabled`). The env reads each with a defaulted `get`, so a test
sets only what it cares about.

---

## 3. `mc_tb_top` in detail

The top is interface instances + `*_connect` bridges + the `config_db` handoff.
There is **no clock/reset generation and no DUT** in the top — the
`vip_clk_rst_agent` drives `clk`/`rst_n` (from the base test's `reset_sequence`),
and the device/DUT/agents are all UVM components built by the env.

### 3.1 Clock and reset

A single `clk_rst_if` instance is hosted here and published to `config_db`. The
`clk_rst_agent` (built in the env) toggles `clk` and drives `rst_n` from a
`reset_sequence` the base test starts in `run_phase`; `start()` blocks until
reset deasserts, so the test body runs against a released DUT. All other
interfaces are clocked/reset from this one `clk_rst_if`.

### 3.2 Interfaces

Every host↔MC pair is two interface instances joined by a connect bridge (the B1
two-instance pattern — never one shared role-gated interface):

| Host-side interface | MC-side interface | Bridge | Used by |
| --- | --- | --- | --- |
| `man_vif0` (`vip_axi4_if`, MANAGER) | `mc_vif0` (`vip_mc_axi4_if`) | `connect0` | AXI4 port 0 (default env, mixed port 0) |
| `man_vif1` (`vip_axi4_if`, MANAGER) | `mc_vif1` (`vip_mc_axi4_if`) | `connect1` | AXI4 port 1 (default env) |
| `rni_vif` (`vip_chi_if`, RN-I, D) | `mc_chi_vif` (`vip_mc_chi_if`, D) | `u_chi_connect` | CHI-D slice, mixed port 1 |
| `rni_vif_e` (`vip_chi_if`, RN-I, E) | `mc_chi_vif_e` (`vip_mc_chi_if`, E) | `u_chi_connect_e` | CHI-E slice |
| `rni_vif_n32` (`vip_chi_if`, RN-I, 32 B DAT) | `mc_chi_vif_n32` (`vip_mc_chi_if`, 32 B) | `u_chi_connect_n32` | narrow-DAT CHI slice |

A `vip_mc_status_if #(N_PORTS_C)` instance is also hosted for the optional status
probe (`tc_mc_status_probe`).

`vip_mc_axi4_connect` cross-wires all five AXI4 channels (explicit per-signal
`assign`s) between the stock MANAGER interface and `vip_mc`'s owned interface.
`vip_mc_chi_connect` cross-wires the RN-I↔SN raw-signal modports.

### 3.3 `config_db` handoff (`initial`)

An `initial` block publishes the virtual interfaces before `run_test()`:

- `clk_rst_vif`, `status_vif`, and the two AXI4 MC vifs (`vif_port0/1`) plus the
  two stock MANAGER vifs (`man_vif_port0/1`) go out on `"*"`.
- Each CHI slice publishes its MC SN vif under `"mc_chi_vif"` and its RN-I vif to
  `uvm_test_top.env.rni_agent`. **All three CHI slices reuse the same key
  strings** — `uvm_config_db` separates entries by the parameterized vif *type*,
  so a CHI-D env resolves the D vifs, a CHI-E env the E vifs, and a narrow env the
  32 B vifs, all from identical keys.

Then `run_test()` runs; from there UVM owns the scenario. Because only one test
runs per `simv`, exactly one env is built and it picks up only the interfaces it
needs; the rest stay parked at idle (their agents are never built, so their links
never activate).

---

## 4. Checking strategy

Three independent levels (see [README.md](README.md) *Checking strategy* for the
summary); a test uses whichever apply:

1. **Per-test data / counter assertions** — read-back byte checks plus front-end
   and backend telemetry getters (`get_decerr_count`, `get_unsupported_count`,
   `get_persist_count`, `issued_req_count`, refresh counts, deferred-debt
   getters, …).
2. **Timing scoreboard** ([tb/mc_scoreboard.sv](tb/mc_scoreboard.sv)) — subscribes
   to `backend.issued_port` (grant order, refresh included), predicts each
   granted entry's completion via the side-effect-free `dram.predict()`, and
   correlates it against the observed AXI4 B/R for that `{port, id}` stream within
   a handshake tolerance. Predicting off the grant tap (not AXI acceptance order)
   folds in refresh and multi-port arbitration. `timing_check_enabled` /
   `timing_tol_ns` gate and relax the hard check; deep back-to-back multi-issue is
   the one case where a strict prediction can diverge (documented in the file).
3. **Protocol-equivalence golden model**
   ([tb/mc_equiv_model.sv](tb/mc_equiv_model.sv)) — the shared program is
   replayed through AXI4 / CHI-D / CHI-E and every read is checked against a fresh
   protocol-neutral image; all three passing proves byte-identical device state
   and read data across the protocols.

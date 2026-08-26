# vip_mc example regression

This directory is the standalone UVM example for `vip_mc`, the behavioral DDR
memory-controller VIP. Unlike the DUT-less `vip_chi` example, this one drives a
**full `manager → vip_mc → vip_dram` system**: `vip_mc` is the DUT in the
middle, fronting a real `vip_dram` device model, and the stimulus comes from
stock VIP managers on the host side.

`vip_mc` exposes two host front-ends over one shared, protocol-agnostic backend:

- an **AXI4** controller-side front-end (`vip_mc_axi4_if` + `vip_mc_axi4_driver`),
  driven by a stock `vip_axi4_agent` MANAGER bridged in by `vip_mc_axi4_connect`;
- a **CHI SN-F** memory-subordinate front-end (`vip_mc_chi_if` +
  `vip_mc_chi_driver`, CHI-D or CHI-E selected in cfg), driven by a stock
  `vip_chi` RN-I manager bridged in by `vip_mc_chi_connect`.

Both faces convert their protocol into one neutral `vip_dram_req`/`vip_dram_rsp`
TLM; the backend (QoS/aging arbiter, cmd queue, refresh, address map) never sees
a protocol. The example proves that claim by running the *same* traffic through
each face against one shared device and checking byte-identical results.

## Architecture

`tb_top` is **structural only**: it hosts the interfaces, bridges each host
interface to the matching `vip_mc` interface with a `*_connect` module, and hands
the virtual interfaces to UVM through `config_db`. Every UVM component — the
`vip_dram` device, the `vip_mc` DUT, the stock managers, the scoreboard — is
built by the **test's env**, not by the top. Only one test runs per `simv`, so
each test's env resolves the interfaces it needs from `tb_top` and leaves the
rest parked at idle.

- [tb/tb.svh](tb/tb.svh) is the single FuseSoC-compiled wrapper (shared TB package,
  testcase package, structural top).
- [tb/mc_tb_pkg.sv](tb/mc_tb_pkg.sv) holds the config families
  (AXI4, CHI-D, CHI-E, narrow-32 B CHI, narrow-128 B-row DRAM), the per-port
  `PORTS[]` descriptors, and the shared address labels.
- [tb/mc_tb_top.sv](tb/mc_tb_top.sv) is the structural top: the AXI4 host
  + `vip_mc` interface pairs (`man_vif0/1` ↔ `mc_vif0/1`) joined by
  `vip_mc_axi4_connect`, three CHI slices (D / E / narrow-32 B) each joined by
  `vip_mc_chi_connect`, the `clk_rst` interface, the status probe interface, and
  the `config_db` handoff. No hand-rolled clock/reset — the `vip_clk_rst_agent`
  owns `clk`/`rst_n`.
- [tb/mc_tb_env.sv](tb/mc_tb_env.sv) is the **default AXI4 env**: it
  builds the shared `vip_dram`, a two-port AXI4 `vip_mc`, the two stock manager
  agents, the `clk_rst` agent, and the timing scoreboard, and publishes one
  `vip_mc_env_cfg` into the DUT.
- [tb/mc_scoreboard.sv](tb/mc_scoreboard.sv) is the timing scoreboard (see
  *Checking strategy*).
- [tb/mc_equiv_model.sv](tb/mc_equiv_model.sv) +
  [tb/mc_equiv_program.sv](tb/mc_equiv_program.sv) are the
  protocol-neutral golden model and the shared deterministic program the
  equivalence suite replays.
- [tc/mc_base_test.sv](tc/mc_base_test.sv) owns the reset sequence and the
  AXI4 traffic helpers every AXI4 test uses; it builds `mc_tb_env`.
- [tc/mc_tc_pkg.sv](tc/mc_tc_pkg.sv) wraps the base tests, the
  self-contained envs, and every `tc_mc_*` test.

The **CHI, mixed-protocol, and narrow-bus tests build their own env** (the
self-contained pattern), reusing the same `tb_top` interfaces:

- [tb/mc_chi_tb_env.sv](tb/mc_chi_tb_env.sv) + [tc/mc_chi_base_test.sv](tc/mc_chi_base_test.sv)
  — a one-port CHI `vip_mc` + its own `vip_dram` + a stock `vip_chi` RN-I agent,
  **parameterized over the `(vip_chi, vip_mc)` cfg pair** so the same source
  serves the CHI-D, CHI-E, and narrow-32 B-DAT slices.
- [tb/mc_mixed_tb_env.sv](tb/mc_mixed_tb_env.sv) — one `vip_mc` with an
  AXI4 port **and** a CHI-D port over one shared backend/device, for the
  concurrent cross-protocol test.
- [tb/mc_narrow_axi4_tb_env.sv](tb/mc_narrow_axi4_tb_env.sv) — a one-port
  AXI4 `vip_mc` over a 128 B-row `vip_dram` (host bus narrower than the row),
  reusing the stock 64 B interfaces.

All four envs (default + the three self-contained) live under `tb/`; every test
base extends the protocol-neutral `mc_neutral_base_test` in `tc/`.

## Checking strategy

This example checks at three independent levels; a test uses whichever apply:

1. **Per-test data / counter assertions.** Directed tests drive write-then-read
   traffic and check the read-back byte-for-byte (counter or custom payloads),
   plus the front-end / backend telemetry counters (`decerr_count`,
   `unsupported_count`, `persist_count`, inflight/complete counts, refresh
   counts, …). This is the primary check for most tests.
2. **Timing scoreboard** ([tb/mc_scoreboard.sv](tb/mc_scoreboard.sv), on by
   default in `mc_tb_env`). It taps `backend.issued_port` (the grant-ordered
   command stream, refresh included) and, for each granted entry, calls the
   side-effect-free `dram.predict()` to get the expected completion time; it then
   correlates each observed AXI4 B/R against the head prediction for its
   `{port, id}` stream and checks the timing within a handshake tolerance. This
   proves the VIP's central claim: believable latency driven by `vip_dram`'s
   prediction, folding in refresh and multi-port arbitration.
3. **Protocol-equivalence golden model**
   ([tb/mc_equiv_model.sv](tb/mc_equiv_model.sv)). One protocol-neutral
   sparse byte image and one deterministic op program are replayed through the
   AXI4, CHI-D, and CHI-E front-ends (`tc_mc_equiv_axi4` /
   `tc_mc_equiv_chi_d` / `tc_mc_equiv_chi_e`); every read is checked
   against a fresh model. All three passing is a transitive proof that the three
   protocols land byte-identical device state and return byte-identical data.

`vip_dram`'s own SVA travels with the device; `vip_mc` has no separate assertion
IP in this example.

The shared named regressions live in [../.refuse.yml](../.refuse.yml). Run them
from this flow directory:

```sh
refuse simv --list-regressions
refuse simv --regression mixed
```

The matching Python command is `refuse verilator --regression mixed` from
`testbench/py`.

## Regression inventory

The full, categorized test catalog — every testcase, its harness env, and what
it proves — lives in [../TEST_CASES.md](../TEST_CASES.md). It is the authoritative
list; this README does not duplicate it. For the component hierarchy and an
elaborated walkthrough of `tb_top`, see [UVM_TB.md](UVM_TB.md).

## Running

The build and single-test commands below run from the repository root. Named
`refuse` regressions run from `testbench/sv` as shown above.

Build the example (clean):

```sh
fusesoc --cores-root=. run --clean --setup --build --target=default --tool=vcs akerlund::vip_mc_example:0
```

Run a single testcase:

```sh
./build/akerlund__vip_mc_example_0/default-vcs/akerlund__vip_mc_example_0 +UVM_TESTNAME=tc_mc_chi_d_write_read
```

List every registered test name:

```sh
grep -rhoE 'uvm_component_(param_)?utils\(tc_mc_[a-z0-9_]+\)' testbench/sv/tc/
```

The compile is driven by [vip_mc_example.core](vip_mc_example.core), which
defines `VIP_MC_ENABLE_CHI` (the CHI front-end is macro-gated) and pulls in
`vip_report_server`, `vip_memory`, `vip_dram`, `vip_gauss`,
`vip_clk_rst_agent`, `vip_axi4_agent`, `vip_chi_agent`, and `vip_mc`.
Treat the build exit code and the per-test `UVM_ERROR : 0` / `UVM_FATAL : 0`
report lines as the success signal.

## File layout

```text
testbench/sv/
├── README.md
├── UVM_TB.md
├── tb/
│   ├── tb.svh
│   ├── mc_tb_pkg.sv
│   ├── mc_tb_top.sv
│   ├── mc_tb_env.sv          (default 2-port AXI4 env)
│   ├── mc_scoreboard.sv          (predict()-based timing scoreboard)
│   ├── mc_equiv_model.sv     (protocol-neutral golden memory)
│   └── mc_equiv_program.sv   (shared deterministic op program)
├── tc/
│   ├── mc_base_test.sv       (AXI4 base + traffic helpers)
│   ├── mc_chi_base_test.sv   (parameterized CHI base)
│   ├── mc_chi_tb_env.sv      (self-contained 1-port CHI env)
│   ├── mc_mixed_tb_env.sv    (self-contained AXI4+CHI env)
│   ├── mc_narrow_axi4_tb_env.sv (self-contained narrow-bus env)
│   ├── mc_tc_pkg.sv
│   └── tc_mc_*.sv
```

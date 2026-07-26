# `vip_mc` - pyUVM / cocotb Porting Plan

Plan for porting the SystemVerilog `vip_mc` memory-controller VIP and its
example testbench to pyUVM / cocotb, following the conventions already proven on
[`vip_dram`](../../vip_dram/) and [`vip_axi4_agent`](../../vip_axi4_agent/). The
CHI-facing slice uses the `vip_chi_agent` Python port from the checked-in
submodule.

- **Source (SV):** this repository's checked-in `sv/` directory and
  `testbench/sv/` example are the frozen reference. The standalone SV baseline
  already builds and runs through the FuseSoC/VCS example flow.
- **Target:** add `py/` for the ported VIP and `testbench/py/` for the cocotb
  example/regression. Keep `sv/` as the authoritative source reference.
- **Scale:** about 8.9k lines of core SV plus 13.2k lines of SV testbench, with
  53 directed `tc_*` tests: 21 AXI4, 12 CHI, and 20 shared controller /
  scheduler / refresh / mixed-topology tests.
- **Dependency stance:** reuse the existing Python ports of `vip_dram`,
  `vip_memory`, `vip_gauss`, `vip_clk_rst_agent`, and `vip_axi4_agent`. Do not
  duplicate their algorithms except where `vip_mc` deliberately owns a native
  front-end contract. The CHI tests use `submodules/vip_chi_agent/py` by
  default.

> **Precondition -- SV baseline is green.** The SV example is the golden
> reference for parity. Keep `*_version.py` drift markers in lock-step with the
> SV `.core` versions.

**Current port status.** This plan is implemented. The Python regression is
green for the controller core, AXI4, CHI-D, CHI-E, equivalence, and mixed
AXI4+CHI cases when run against the updated submodules. The port has config
objects, env/vif holders, command entries, activity FIFO, QoS command queue,
refresh bookkeeping, status snapshot and status mirror, backend pyUVM
lifecycle/TLM plumbing, `vip_mc_axi4_driver`, `vip_mc_chi_driver`, and top-level
`vip_mc` over `vip_dram`. `testbench/py` has a version-drift guard, pure Python
core tests, the timing scoreboard, CHI response observation, a multi-port
Verilator shell, direct/env_cfg construction coverage, and directed AXI4/CHI
tests matching the SV regression surface.

---

## 1. Reuse The House Porting Rules

The same rules from the `vip_axi4_agent` and `vip_dram` ports apply here:

| Concern | Convention |
|---|---|
| Tool stack | pyUVM 4.x, cocotb 2.x, Verilator via FuseSoC flow API |
| Layout | `py/` mirrors `sv/` filename-for-filename where practical; `.svh` and `*_pkg.sv` include mechanics become Python imports |
| Parameters | SV `#(...)` parameters become runtime config dataclasses; no parameterized Python classes |
| Packed vectors | explicit `mask()` / `trunc()` helpers; Python ints never rely on implicit width wrap |
| Clocking blocks | replace interfaces/clocking blocks with bus wrappers that centralize `RisingEdge` / `ReadOnly` / `ReadWrite` discipline |
| `fork` / events / FIFOs | `cocotb.start_soon`, task handles, `asyncio.Event`, and pyUVM TLM FIFOs/ports |
| `realtime` | Python `float` ns plus cocotb `Timer` helpers, matching the `vip_dram` port |
| Randomization | pyvsc only where the ported testbench still needs constrained-random stimulus |
| SVA / status probes | cocotb monitor-side checkers or flat status buses; Verilator is 2-state, so X/Z rules are dropped |
| Version guard | `py/vip_mc_version.py` and `testbench/py/check_versions.py` compare against the `.core` files |
| Formatting | 2-space indentation, matching the sibling Python ports |

The strongest precedent is split: `vip_dram` provides the timing/device model
style, while `vip_axi4_agent` provides the flat-net bus wrapper and cocotb
regression style.

---

## 2. What Is Different About `vip_mc`

`vip_mc` is not a bus agent and not a pure device model. It is the bridge between
host protocols and `vip_dram`'s neutral TLM:

```text
AXI4 / CHI host traffic -> vip_mc front-end -> command queue/backend -> vip_dram
```

The port should preserve this separation. The AXI4 and CHI front-ends are bus
adapters; the backend, command queue, refresh engine, address decode, timing
prediction, response buffering, observability counters, and reset choreography
are protocol-agnostic.

The main design risks are:

1. **Backend parity.** `vip_mc_cmd_queue` and `vip_mc_backend` contain the
   controller behavior users care about: same-stream ordering, QoS classing,
   aging, FR-FCFS readiness selection, read/write grouping, coalescing,
   response-buffer gating, device in-flight limits, and completion telemetry.
2. **Time semantics.** The SV uses `$realtime` and bus-edge retiming around
   `vip_dram.predict()` / completions. The Python port must use the same ns
   model as the `vip_dram` port and snap bus responses to the next relevant
   bus edge.
3. **Front-end ownership.** `vip_mc` owns its AXI4 and CHI controller-side
   interfaces. The Python port should keep that boundary even when the example
   reuses `vip_axi4_agent` or `vip_chi_agent` for stimulus.
4. **CHI availability.** The CHI MC front-end depends on `vip_chi_agent` flit
   types and an RN-I stimulus agent. Port AXI4 and the shared backend first;
   schedule CHI after the CHI Python port exposes a stable codec/bus/sequence
   API.

---

## 3. Target Directory Layout

```text
rtl_dev/vip_memory_controller/
+-- README.md
+-- docs/
|   +-- PORTING_PLAN.md          # this plan
|   +-- PRIMER.md
|   +-- IMPLEMENTATION_PLAN.md
|   +-- FURTHER_WORK.md
+-- vip_mc.core                  # SV/FuseSoC reference core
+-- sv/                          # frozen SystemVerilog reference
+-- py/                          # the Python port
|   +-- vip_mc_types_pkg.py
|   +-- vip_mc_axi4_types_pkg.py
|   +-- vip_mc_axi4_if.py        # McAxi4Bus wrapper
|   +-- vip_mc_status_if.py      # status signal wrapper, if exposed in shell
|   +-- vip_mc_axi4_cfg.py
|   +-- vip_mc_chi_cfg.py
|   +-- vip_mc_port_runtime_cfg.py
|   +-- vip_mc_config.py
|   +-- vip_mc_vif_holder.py
|   +-- vip_mc_axi4_vif_holder.py
|   +-- vip_mc_chi_vif_holder.py
|   +-- vip_mc_env_cfg.py
|   +-- vip_mc_status_snapshot.py
|   +-- vip_mc_cmd_entry.py
|   +-- vip_mc_chi_cmd_entry.py
|   +-- vip_mc_activity_fifo.py
|   +-- vip_mc_cmd_queue.py
|   +-- vip_mc_fe_base.py
|   +-- vip_mc_refresh.py
|   +-- vip_mc_backend.py
|   +-- vip_mc_axi4_driver.py
|   +-- vip_mc_chi_if.py         # McChiBus wrapper, gated by vip_chi availability
|   +-- vip_mc_chi_driver.py
|   +-- vip_mc.py
|   +-- vip_mc_version.py
+-- submodules/
|   +-- vip_dram/                # reuse py/
|   +-- vip_memory/              # reuse py/
|   +-- vip_axi4_agent/          # reuse py/ for AXI4 stimulus
|   +-- vip_chi_agent/           # reuse py/ for CHI stimulus
|   +-- vip_gauss/
|   +-- vip_clk_rst_agent/
+-- testbench/
    +-- sv/                      # SV reference example
    +-- py/
        +-- README.md
        +-- vip_mc_example_py.core
        +-- check_versions.py
        +-- run_fusesoc.sh
        +-- tb/
        |   +-- mc_hdl_top.sv
        |   +-- mc_tb_top.py
        |   +-- mc_tb_env.py
        |   +-- mc_chi_tb_env.py
        |   +-- mc_mixed_tb_env.py
        |   +-- mc_equiv_model.py
        |   +-- mc_equiv_program.py
        |   +-- mc_scoreboard.py
        +-- tc/
            +-- test_mc_core.py
            +-- mc_base_test.py
            +-- mc_chi_base_test.py
            +-- tc_mc_*.py
```

One intentional deviation from strict 1:1 mirroring: `vip_mc_pkg.sv`,
`vip_mc.svh`, and connector modules become import/bootstrap or flat-shell
concerns in Python rather than library modules.

---

## 4. SV To Python Mapping

| SystemVerilog | Python port |
|---|---|
| `vip_mc_axi4_types_pkg.sv`, `vip_mc_types_pkg.sv` | enums, dataclasses, width helpers, protocol selectors, address-region records |
| `vip_mc_config.sv`, child config objects | runtime config dataclasses/objects with the same defaults and `validate()` checks |
| `vip_mc_cmd_entry.sv`, `vip_mc_chi_cmd_entry.sv` | dataclass work items; preserve all completion metadata and timing fields |
| `vip_mc_activity_fifo.sv` | small async queue wrapper with wake event, `try_get()`, `get()`, `flush()`, and occupancy tracking |
| `vip_mc_cmd_queue.sv` | pure Python scheduler class, unit tested without Verilator before integration |
| `vip_mc_backend.sv` | pyUVM component with ingress FIFOs, refresh FIFO, device request path, completion demux, and telemetry |
| `vip_mc_refresh.sv` | async refresh producer using `Timer` and reset-kill semantics |
| `vip_mc_fe_base.sv` | abstract Python base class for protocol front-ends |
| `vip_mc_axi4_if.sv` | `McAxi4Bus` signal wrapper; same handshake discipline as `Axi4Bus`, but with MC-owned names/config |
| `vip_mc_axi4_driver.sv` | AXI4 subordinate front-end; reuse helper ideas from `vip_axi4_agent` for burst iteration/exclusives, but keep MC config native |
| `vip_mc_chi_if.sv` | `McChiBus` signal wrapper using the CHI flit codec/types from the `vip_chi_agent` Python port |
| `vip_mc_chi_driver.sv` | CHI SN memory-target front-end; port after the CHI RN-I Python stimulus path is stable |
| `vip_mc_status_if.sv`, `vip_mc_status_snapshot.sv` | either flat status bus wrapper for parity tests or a Python-only snapshot object for internal telemetry |
| `vip_mc.sv` | top-level pyUVM component that builds front-ends from `PORTS[]`, owns reset choreography, backend, refresh, and status publishing |
| `vip_mc_axi4_connect.sv`, `vip_mc_chi_connect.sv` | flat-shell signal assignments or Python bus aliasing in the example only |
| `mc_scoreboard.sv` | cocotb/pyUVM scoreboard comparing observed response timing with `vip_dram.predict()` |
| `mc_equiv_model.sv`, `mc_equiv_program.sv` | pure Python equivalence helpers for host-vs-device data checks |

---

## 5. Verilator Boundary

Use the sibling Python examples' model: the compiled HDL is only a flat-net
simulation shell with clocks, reset, and public writable/readable bus nets. The
`vip_mc` implementation itself is Python.

Recommended shell rules:

1. Expose one clock/reset pair and one flat net group per host port.
2. Compile with `--public-flat-rw` so cocotb can drive/read every bus net.
3. Keep the shell free of UVM and SV class packages.
4. For AXI4, either share one net group between the Python AXI4 manager and the
   MC AXI4 front-end, or preserve the SV connector shape with two prefixed net
   groups and continuous assignments. Prefer the connector shape if it keeps
   signal ownership clearer.
5. For CHI, generate numeric flit-vector widths from the same Python config used
   by the CHI codec. Do not rely on SV `vip_chi_types_pkg` in the Verilator top.
6. Keep one shell capable of the default AXI4 slice, the narrow AXI4 slice, the
   CHI slice, and the mixed concurrent slice, even if some tests leave ports
   idle.

---

## 6. Phased Implementation

Each phase should end at a runnable gate. Do not port all 53 tests before the
first end-to-end smoke works.

### Step 0 -- Freeze And Guard The SV Reference

1. Record the current `vip_mc.core` version and submodule SHAs.
2. Add `py/vip_mc_version.py`.
3. Add `testbench/py/check_versions.py` for `vip_mc`, `vip_dram`,
   `vip_memory`, `vip_axi4_agent`, `vip_gauss`, and `vip_clk_rst_agent`; add
   `vip_chi_agent` once its Python marker exists.
4. Add the Python FuseSoC core, `run_fusesoc.sh`, and an empty cocotb smoke top.

*Gate:* `python3 testbench/py/check_versions.py` passes and Verilator can build
and run a do-nothing cocotb test against the flat shell.

### Tier A -- Pure Controller Core

Port the protocol-independent pieces first:

1. `vip_mc_types_pkg.py`, `vip_mc_axi4_types_pkg.py`, `vip_mc_config.py`, and
   `vip_mc_port_runtime_cfg.py`.
2. `vip_mc_cmd_entry.py`, `vip_mc_activity_fifo.py`, and `vip_mc_cmd_queue.py`.
3. `vip_mc_refresh.py` and enough `vip_mc_backend.py` to admit requests, issue to
   `vip_dram`, receive completions, flush on reset, and expose counters.

Add ordinary Python tests for the command queue and config validation before
bringing up cocotb. These should cover QoS clamping, aging promotion,
same-stream blocking, FR-FCFS selection, read/write grouping, coalescing, and
flush/reset semantics.

*Gate:* pure Python tests pass, and a small backend-only cocotb test can submit a
synthetic read/write entry and observe the expected `vip_dram` completion timing.

### Tier B -- AXI4 End-To-End

Port the AXI4 front-end and the default AXI4 example path:

1. `McAxi4Bus`, AXI4 vif holder, env config, and top-level `vip_mc.py` build
   logic.
2. `vip_mc_axi4_driver.py`: AW/W/AR capture, burst-to-row-word mapping, 4 KB and
   region DECERR, exclusive monitor, USER passthrough, WREADY backpressure,
   response-buffer crediting, same-ID ordering, and bus-edge response pacing.
3. Reuse the Python `vip_axi4_agent` manager sequences in the testbench where
   possible. Keep any MC-specific stimulus as thin tests rather than adding a
   second AXI4 sequence library.

*Gate:* AXI4 smoke passes: `tc_mc_axi4_single_beat`,
`tc_mc_axi4_burst`, `tc_mc_axi4_narrow_unaligned`,
`tc_mc_axi4_fixed`, `tc_mc_axi4_wrap`,
`tc_mc_axi4_user_passthrough`, `tc_mc_axi4_exclusive`,
`tc_mc_axi4_unsupported_reject`, `tc_mc_status_probe`, and
`tc_mc_axi4_multi_port`. This gate is now green in `testbench/py`.

### Tier C -- AXI4 Breadth And Scheduler Observability

Port the rest of the AXI4 and shared-controller tests:

1. Outstanding limits, read pipeline, read multi-ID, inter-ID out-of-order,
   response/BRESP/AW/WREADY backpressure.
2. QoS scheduling, QoS aging, FR-FCFS page-hit selection, starvation cap, and
   read/write grouping.
3. Refresh periodic/deferred/collision, init delay, reset recovery, multi-rank,
   preset sweep, status probe, telemetry counters, ECC classification, write
   coalescing, and unsupported-reject paths.
4. Port `mc_scoreboard.py` and the equivalence model/program once response
   timing is stable enough for comparison.

*Gate:* all AXI4 and protocol-independent tests pass under the Python
regression. This gate is green in `testbench/py`.

### Tier D -- CHI SN Front-End

Use the `vip_chi_agent` Python port's CHI-D/E type objects, flit codec helpers,
`ChiBus`, RN-I driver, and base sequences.

1. Port `vip_mc_chi_cfg.py`, `McChiBus`, CHI vif holder, and CHI command entry.
2. Port `vip_mc_chi_driver.py` as an SN memory-target front-end over the existing
   backend: link activation, REQ/RSP/DAT credit exchange, ReadNoSnp /
   ReadNoSnpSep, WriteNoSnpFull/Ptl/Zero, CleanSharedPersist/PersistSep,
   Comp/DBIDResp/CompDBIDResp/CompData/DataSepResp/ReadReceipt, DECERR, and
   unsupported-op rejection.
3. Use the `vip_chi_agent` Python RN-I side for stimulus in `mc_chi_tb_env.py`.
4. Keep CHI optional in Python as an import/runtime feature. If `vip_chi_agent`
   is unavailable, skip CHI tests explicitly rather than failing AXI4-only runs.

*Gate:* CHI-D tests pass:
`tc_mc_chi_d_write_read`, `tc_mc_chi_d_read`,
`tc_mc_chi_d_write_ptl`, `tc_mc_chi_d_decerr`,
`tc_mc_chi_d_combined_write`, `tc_mc_chi_d_unsupported`,
`tc_mc_chi_d_persist`, `tc_mc_chi_d_reject`,
`tc_mc_chi_d_narrow`. CHI-E tests pass:
`tc_mc_chi_e_write_read`, `tc_mc_chi_e_write_zero`,
`tc_mc_chi_e_read_sep`. This gate is green in `testbench/py`.

### Tier E -- Mixed Protocol And Equivalence

Port the mixed and equivalence tests:

1. `mc_mixed_tb_env.py` with at least one AXI4 and one CHI port over the
   same backend.
2. `tc_mc_mixed_concurrent`, `tc_mc_equiv_axi4`, and
   `tc_mc_equiv_chi`.
3. Confirm the representative-width convention from the SV `PORTS[]` table is
   represented cleanly in Python. Python can compute representative configs by
   scanning ports rather than inheriting the SV `PORTS[0]` elaboration constraint,
   but the observable validation errors should stay compatible.

*Gate:* full Python regression passes with AXI4, CHI-D, CHI-E, mixed, and
equivalence tests. This gate is green in `testbench/py`.

---

## 7. Testbench Porting Order

Port tests in the order that exposes missing infrastructure earliest:

| Order | Test group | Purpose |
|---:|---|---|
| 1 | `tc_mc_cfg`, backend-only synthetic checks | validate config and scheduler without bus noise |
| 2 | `tc_mc_axi4_single_beat`, burst/fixed/wrap/narrow | prove AXI4 mapping and DRAM timing |
| 3 | AXI4 backpressure/outstanding/read-pipeline/multi-ID | prove response buffering and ordering |
| 4 | QoS/FR-FCFS/read-write grouping/refresh/init/reset | prove controller policy and reset choreography |
| 5 | observability/status/ECC/coalescing/equivalence AXI4 | prove diagnostics and model parity |
| 6 | CHI-D smoke/write/read/decerr/reject/narrow/persist | prove MC CHI SN front-end over the same backend |
| 7 | CHI-E read-sep/write-zero and mixed/equivalence CHI | prove issue-E and mixed-protocol parity |

Use `COCOTB_TEST_FILTER` style selection like the AXI4 example so each milestone
can run as a small subset before the full list is green.

---

## 8. Risks And Decisions To Track

1. **`vip_chi_agent` dependency.** Resolved by stepping the submodule to the
   CHI Python port.
2. **Scheduler equivalence.** The command queue has enough policy that bugs can
   hide without focused tests. Treat it as a pure Python unit-test target, not
   only as cocotb integration behavior.
3. **Bus-edge retiming.** The backend works in absolute ns, but AXI4/CHI return
   traffic is bus-clocked. All response-driver code needs one shared helper for
   "wait until time reached, then next edge" so AXI4 and CHI do not diverge.
4. **Reset kills.** SV reset flushes front-ends, backend, refresh, and the DRAM
   model. Python must track every background task and kill/recreate it at reset,
   especially delayed response senders.
5. **Status interface vs Python snapshot.** If external cocotb tests need the
   exact status pins, keep `vip_mc_status_if.py` and flat nets. If all consumers
   are Python, a snapshot object is simpler. Decide before porting status tests.
6. **Representative config convention.** SV derives representative AXI4/CHI
   elaboration configs from `PORTS[0]`; Python is not constrained by elaboration.
   Prefer scanning the configured ports internally, but keep validation messages
   and user-visible restrictions compatible with SV.
7. **Scoreboard scope.** The timing scoreboard should model the delivered
   scheduler paths first. Keep known SV follow-ups from `FURTHER_WORK.md`
   visible when adding coalescing/ECC/mixed-protocol checks.

---

## 9. Delivered Gate

The delivered Python gate is:

```bash
./testbench/py/run_fusesoc.sh --target sim --clean
```

With the updated submodules, the gate passes the controller core, AXI4, CHI-D,
CHI-E, equivalence, and mixed AXI4+CHI tests in one Verilator/cocotb run.

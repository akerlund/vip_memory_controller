# Further Work

Review date: 2026-07-20

Scope: current standalone `vip_memory_controller` VIP and its testbenches. The
previous review archive was removed because its actionable defects are
addressed in the current code, and several entries belonged to sibling VIP
repositories now consumed as submodules.

**Both flows.** The VIP ships a SystemVerilog implementation under `sv/` and a
pyUVM/cocotb port under `py/`, exercised by `testbench/sv` and `testbench/py`
against the shared catalog in [../testbench/TEST_CASES.md](../testbench/TEST_CASES.md).
Every item below is open in both. When one is implemented, the fix and its
regression coverage land in the SV and Python sides together — otherwise the
flows drift and the catalog stops describing one of them.

The full registered UVM regression passed after this review:

```sh
fusesoc --cores-root=. run --clean --setup --build --target=default --tool=vcs akerlund::vip_mc_example:0
```

All 54 discovered `tc_mc_*` tests then passed with `UVM_ERROR : 0` and
`UVM_FATAL : 0`.

The Python flow runs the same 54 plus the flow-only `tc_mc_core_slice`, 55 in
total, over Verilator:

```sh
./testbench/py/run_fusesoc.sh --target sim
```

## Open Items

### 1. Remove the mixed-protocol representative-cfg convention

`vip_mc` derives the concrete AXI4 and CHI interface/config types from
`PORTS[0]` (`sv/vip_mc.sv`) and requires every `PORTS[]` entry to carry both
representative cfg fields, even for the unused protocol. The example follows
that convention, but it is easy for an integrator to build a mixed table where
port 0 is CHI and a later AXI4 port carries the only real AXI4 cfg; that will
elaborate the AXI4 representative from a dummy value and fail later.

Recommended fix: derive each representative cfg by scanning `PORTS[]` for the
first port of that protocol, or add explicit top parameters for the protocol
representatives. Add a regression with `PORTS[0] = CHI` and `PORTS[1] = AXI4`.

### 2. Track and validate CHI CompAck when `ExpCompAck` is set

The CHI SN front-end captures `req.expcompack`, but inbound RSP flits are only
consumed for credit return. Missing or malformed `CompAck` is therefore not
detected by `vip_mc`.

Recommended fix: keep a small pending-CompAck table keyed by TxnID/DBID/source,
validate inbound `CompAck`, and add positive and negative CHI tests.

### 3. Normalize CHI counter semantics around `perf_counters_enabled`

`get_decerr_count()` is perf-gated, while CHI read/write/unsupported/persist
counters are incremented and returned regardless of `perf_counters_enabled`.
That may be intentional protocol observability, but it differs from AXI4/backend
counter behavior.

Recommended fix: either make all CHI telemetry accessors follow the perf gate or
document them as always-on protocol counters.

### 4. Make ECC telemetry per-beat if the DRAM response exposes per-beat faults

The backend repairs every beat covered by `rsp.corrupt_mask`, but
`ecc_corrected_count` / `ecc_uncorrectable_count` are keyed from the response's
single worst `injected_fault` severity. A mixed multi-beat read with both
correctable and uncorrectable beats can be functionally repaired/classified, but
not counted per corrected beat.

Recommended fix: when `vip_dram_rsp` carries per-beat fault severity, tally ECC
corrections and uncorrectables per beat and add a mixed-fault test.

### 5. Extend the timing scoreboard for transformed completions

The example disables the timing scoreboard for flows where one device access no
longer maps one-to-one to one host completion, notably write coalescing and ECC
fault-injection tests. Those paths are covered by directed checks, but not by the
predictor-vs-observed scoreboard.

Recommended fix: teach `mc_scoreboard` to model coalesced fan-out and ECC-read
classification so those tests can keep timing checks enabled.

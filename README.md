# VIP Memory Controller Agent

Behavioral memory-controller VIP over `vip_dram`. It exposes owned host-facing
types/interfaces and UVM front-end logic — an AXI4 controller-side front-end and
an optional CHI SN (memory-target) front-end — over one shared,
protocol-agnostic backend.

The VIP ships in **two implementations**: the SystemVerilog UVM source under
[`sv/`](sv/) and the pyUVM/cocotb port under [`py/`](py/), which runs on
Verilator. They are feature-equivalent and share one testcase catalog — the
same 57 testcases run in both flows. This README is the **common reference**:
the architecture, configuration, and feature set below apply to both, and the
code snippets are shown in SystemVerilog for concreteness with the Python API
mirroring them.

Current delivered slice:

- homogeneous host ports (AXI4 and/or CHI, one protocol per port) over one
  shared protocol-agnostic backend
- AXI4 `INCR` / `FIXED` / `WRAP`, narrow and unaligned transfers
- exclusive access and USER passthrough (AXI4 has no read-data interleaving)
- CHI SN front-end (opt-in behind `+define+VIP_MC_ENABLE_CHI`): link activation +
  credit exchange, ReadNoSnp / ReadNoSnpSep, WriteNoSnp{Full,Ptl,Zero},
  Comp / CompDBIDResp / DBIDResp / CompData / DataSepResp / ReadReceipt, DECERR +
  unsupported-op rejection — validated under **both CHI-D and CHI-E** issues
- finite response-buffer backpressure and bounded `WREADY` ingress backpressure
- backend-owned QoS command queue with same-stream ordering preservation,
  priority arbitration, and aging promotion (anti-starvation)
- reset choreography: `vip_mc::run_phase` watches `rst_n` and `handle_reset()`
  flushes the front-ends/backend/refresh and calls the blocking `dram.reset()`
- per-beat read-data timing: R beats paced first→last from `vip_dram`'s
  `first/last_beat_ready_time`, B driven at `last_beat_ready_time`
- `backend.issued_port` grant-order tap + an example latency scoreboard
  (`mc_scoreboard`) that checks observed B/R timing against `dram.predict()`
- real `vip_dram` end-to-end example harness in `testbench/sv` (57 testcases in
  one build: 12 CHI — 8 CHI-D directed, a 3-test CHI-E D/E matrix, and a 32 B-DAT
  narrow case — plus AXI4, scheduling, refresh, ECC, mixed and equivalence
  coverage), mirrored by the pyUVM/cocotb port in `testbench/py`; see
  [testbench/TEST_CASES.md](testbench/TEST_CASES.md)

## Feature snapshot

This VIP models a configurable memory controller at the host-protocol and
DRAM-transaction boundary. AXI4 and CHI traffic share one backend, one owned
`vip_dram` model, and one set of scheduling, timing, refresh, ECC, and
observability policies. In short:

- **Architecture and protocol surface**
  - A protocol-agnostic backend with per-port ingress, shared command
    arbitration, device-window limiting, refresh arbitration, and completion
    dispatch.
  - AXI4 `INCR`, `FIXED`, and `WRAP` bursts, narrow and unaligned transfers,
    exclusive accesses, USER passthrough, DECERR windows, and bounded
    `AW`/`AR`/`W`/response backpressure.
  - An opt-in CHI SN memory-target front-end supporting CHI-D and CHI-E,
    `ReadNoSnp`, `ReadNoSnpSep`, `WriteNoSnpFull`, `WriteNoSnpPtl`, and
    `WriteNoSnpZero`, with legal completion, DBID, separated-read, and
    `ReadReceipt` responses.
  - CHI DECERR classification and defined rejection of unsupported requests;
    snoop, DVM, stash, and coherent RN-F/HN-F behavior remain outside this
    memory-target VIP's scope.
  - Multiple host ports may target the same shared device. Compile-time port
    descriptors select AXI4 or CHI per port, while runtime address regions,
    arbitration weights, and protocol-specific policy remain configurable.
- **Scheduling and backend policy**
  - QoS classes with strict same-stream ordering, aging promotion, and
    anti-starvation behavior for low-priority traffic.
  - Optional readiness-aware FR-FCFS arbitration, starvation-cap overrides,
    and read/write direction grouping with a configurable run bound.
  - Optional same-stream write coalescing with newest-byte-wins lane overlay,
    plus counters for coalescing, reorder, grouping, turnaround, and forced
    service decisions.
  - Finite device in-flight and response-buffer windows, outstanding request
    limits, and explicit queue-depth observability.
  - Shared address-map validation and decode, with the resolved layout copied
    into the owned `vip_dram` instance so scheduling and device timing agree.
- **CHI link and flow control**
  - Link activation and deactivation over the MC-owned CHI interface, with
    `LINKACTIVEREQ`/`LINKACTIVEACK`, `TXSACTIVE`, `FLITPEND`, and per-channel
    L-credit handling.
  - Configurable initial REQ/RSP/DAT credit pools, credit validation, and
    credit-aware send/receive backpressure.
  - Split-write response policy (`DBIDResp` followed by `Comp`, or combined
    `CompDBIDResp`), CHI-E field support, and reset-safe transaction cleanup.
  - The SystemVerilog testbench uses `mc_chi_sva_probe` as a passive structural
    adapter to the standard CHI checker interface. The Python flow binds its
    checker directly to the Python `ChiBus` and therefore needs no probe file.
- **DRAM timing and reliability**
  - Real `vip_dram` command/response behavior with row, bank, rank, burst,
    turnaround, and per-beat readiness timing visible to the controller.
  - Per-beat AXI4 read pacing and CHI data timing, optional timing honoring,
    and an example latency scoreboard against `dram.predict()`.
  - Periodic or deferred refresh with refresh debt, catch-up bursts, rank
    handling, and configurable `tREFI` override.
  - Optional initialization delay after reset and controller-side SECDED
    classification of correctable and uncorrectable device read faults.
- **Observability and integration**
  - Controller status interface, per-port completion and byte counters,
    latency and occupancy histograms, bandwidth/utilization, row-hit and
    prediction accuracy, ECC, refresh, QoS, and backpressure counters.
  - Four analysis paths where applicable — host/device command flow and CHI
    REQ/RSP/DAT observations — feeding scoreboards, coverage, and protocol
    evidence.
  - SystemVerilog UVM and pyUVM/cocotb implementations with matching public
    configuration concepts, a shared testcase catalogue, and FuseSoC build
    targets for VCS and Verilator.
  - SystemVerilog transaction recording for waveform viewers; the Python
    pyUVM 4.0.1 recording backend remains a stub.
- **Checking and regression evidence**
  - CHI protocol checking on both the requester-facing and MC SN-facing links,
    with per-rule pass/fail tallies, severity control, vacuity reporting, and
    opcode evidence exported for cross-run analysis.
  - Python uses the corresponding `sva.bind_chi` checker implementation, so
    the two flows exercise the same protocol-checking intent despite different
    simulator interfaces.
  - Directed tests cover CHI-D, CHI-E, separated reads, split and zero writes,
    DECERR, unsupported operations, persistence, narrow transfers, protocol
    equivalence, and mixed AXI4+CHI traffic alongside the AXI4, scheduling,
    refresh, ECC, reset, and observability suites.

Scope boundary: this is a behavioral memory-controller VIP over `vip_dram`, not
a synthesizable DDR controller or a pin-level PHY model. It does not implement
the CHI coherent fabric, snoop directory, DVM/stash traffic, or a general
interconnect. The CHI front-end is the SN memory-target subset described above;
the detailed open follow-ups are tracked in
[docs/FURTHER_WORK.md](docs/FURTHER_WORK.md).

## Documentation map

This README covers the controller's architecture, configuration knobs, and
delivered feature set. The flow-specific guides and the deeper references live
in separate documents:

- [py/README.md](py/README.md) — the **pyUVM / cocotb port** (Python, runs on
  Verilator via FuseSoC). The feature reference here applies to the port; the
  Python API mirrors the SV one.
- [testbench/TEST_CASES.md](testbench/TEST_CASES.md) — the **shared testcase
  catalog**: every testcase, its harness env, what it proves, and measured
  runtimes for both flows. Authoritative for what the regression covers.
- [testbench/sv/README.md](testbench/sv/README.md) — the **SystemVerilog**
  example testbench: quick-start, regression running, and source-file map.
- [testbench/sv/UVM_TB.md](testbench/sv/UVM_TB.md) — elaborated walkthrough of
  the SV structural top and the component hierarchy.
- [testbench/py/README.md](testbench/py/README.md) — the **Python** example
  testbench: how to run it and how the status probe surfaces in waves.
- [docs/PRIMER.md](docs/PRIMER.md) — educational background on
  memory-controller responsibilities, host-to-DRAM translation, scheduling,
  timing, and refresh, with the embedded MC-to-DRAM request walkthrough.
- [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) — the design
  reference: intended architecture, contracts, and file-level decomposition.
- [docs/FURTHER_WORK.md](docs/FURTHER_WORK.md) — open follow-ups. Each applies
  to both flows.

## File map

The checked-in `vip_mc` files fall into two useful buckets: files an
integrator is likely to read, include, configure, or instantiate directly, and
files that mainly implement the internal controller behavior behind that
surface. The `sv/` entries below have Python counterparts of the same name
under `py/`.

### Integration-facing files

| File | Purpose | What it does |
| --- | --- | --- |
| `README.md` | User-facing overview | Describes the delivered slice, configuration knobs, constraints, and the basic build/smoke flow for `vip_mc`. |
| `docs/PRIMER.md` | Educational primer | Explains memory-controller responsibilities, host-to-DRAM translation, scheduling, timing, refresh, and the embedded MC-to-DRAM request examples. |
| `docs/IMPLEMENTATION_PLAN.md` | Design reference | Captures the intended architecture, contracts, tests, and file-level decomposition for the controller VIP. |
| `docs/FURTHER_WORK.md` | Follow-up list | Tracks current low-priority review follow-ups that are not regressions in the delivered slice. |
| `py/` | Python port source | Contains the pyUVM/cocotb port of the controller core, backend lifecycle, AXI4 and CHI front-ends, and top-level `vip_mc` component over `vip_dram`. |
| `testbench/py/` | Python regression testbench | Provides the version guard, pure Python core tests, and a Verilator/cocotb shell covering AXI4, CHI-D, CHI-E, protocol equivalence, and mixed AXI4+CHI traffic with the real Python agents. |
| `sv/vip_mc.svh` | Single include entry point | Pulls in prerequisite packages, the owned AXI4 interface/types, and the umbrella `vip_mc_pkg` so a consumer can compile the slice from one header. |
| `sv/vip_mc_pkg.sv` | Umbrella UVM package | Imports shared dependencies and includes the `vip_mc` classes in the compile order needed by the package. |
| `sv/vip_mc_axi4_types_pkg.sv` | Owned AXI4 type package | Defines `vip_mc`'s AXI4 width/config structs, typedef containers, and constants without depending on stock `vip_axi4_*` config types. |
| `sv/vip_mc_axi4_if.sv` | Controller-side AXI4 interface | Declares the host-facing AXI4 interface type used by the `vip_mc` AXI4 front-end and virtual-interface holders. |
| `sv/vip_mc_types_pkg.sv` | Shared controller types | Holds protocol enums, port descriptors, address-region structs, refresh enums, and other small shared types used across the package. |
| `sv/vip_mc_axi4_cfg.sv` | AXI4 front-end config object | Encapsulates AXI4-specific runtime policy such as outstanding limits, QoS remap, exclusive support, DECERR windows, and `dram_handle_path`. |
| `sv/vip_mc_port_runtime_cfg.sv` | Per-port runtime policy | Stores one port's owned address regions, arbitration weight, and fallback `vif_key`. |
| `sv/vip_mc_config.sv` | Shared MC config object | Owns the controller-level knobs such as outstanding budgets, QoS/aging policy, response-buffer depth, device in-flight window, refresh policy, address map, perf counters, beat timing, and the `ports[]` runtime map. |
| `sv/vip_mc_vif_holder.sv` | Type-erased VIF holder base | Gives the environment config one uniform base handle so different host-interface holder types can live in a single array. |
| `sv/vip_mc_axi4_vif_holder.sv` | Typed AXI4 VIF holder | Wraps a concrete `virtual vip_mc_axi4_if` and tags it as AXI4 so the top can recover the right interface type per port. |
| `sv/vip_mc_env_cfg.sv` | Environment handoff object | Aggregates the shared `vip_mc_config`, the `vip_dram` handle, and per-port interface holders, then validates and publishes that bundle through `uvm_config_db`. |
| `sv/vip_mc_axi4_connect.sv` | Optional AXI4 bridge glue | Bridges a stock `vip_axi4_if` manager-side signal set into the owned `vip_mc_axi4_if`; it is intentionally kept outside `vip_mc_pkg` so the core slice stays free of `vip_axi4_*` dependencies. |
| `sv/vip_mc_chi_cfg.sv` | CHI front-end config object | Native CHI knobs (`sn_node_id`, `initial_{req,rsp,dat}_credits`, `split_write_rsp`), the parallel of `vip_mc_axi4_cfg`. Deliberately a plain int/bit object with no `vip_chi` dependency, so it lives in the always-compiled core and is reached as `cfg.chi`; `validate()` rejects illegal credit counts. |
| `sv/vip_mc_chi_if.sv` | Controller-side CHI SN interface | Single-role SN (memory subordinate) interface carrying superset `vip_chi_types` flits, used by the CHI front-end and its VIF holder. Compiled only under `+define+VIP_MC_ENABLE_CHI`. |
| `sv/vip_mc_chi_vif_holder.sv` | Typed CHI VIF holder | Wraps a concrete `virtual vip_mc_chi_if` and tags it as CHI so the top recovers the right interface type per port. |
| `sv/vip_mc_chi_connect.sv` | Optional CHI bridge glue | Bridges a stock `vip_chi_if` RN-I manager into the owned `vip_mc_chi_if` (the CHI counterpart of `vip_mc_axi4_connect`); example-only, kept outside `vip_mc_pkg`. |
| `sv/vip_mc.sv` | Top-level controller component | Builds the configured front-ends from `PORTS[]` (AXI4 and CHI), owns reset choreography, creates/wires the backend and refresh blocks, and pushes the address-map/timing policy into `vip_dram`. |

### Internal implementation files

| File | Purpose | What it does |
| --- | --- | --- |
| `sv/vip_mc_cmd_entry.sv` | Internal command record | Defines the MC's canonical request/response work item that moves between the host front-end, backend scheduler, and completion path. One entry carries admission metadata (`port_id`, `axi4_id`, QoS class, admit order/time), request shape (`op`, address, burst geometry, write payload/strb, exclusive and USER fields), and completion-side data (`resp`, `rdata`, first/last beat ready timestamps, completion flag). In practice this is the object that preserves everything the backend needs to schedule, and everything the front-end needs later to reconstruct `B` or `R`. |
| `sv/vip_mc_activity_fifo.sv` | Wakeable ingress FIFO | Implements the small backend-owned queue used on ingress paths where producers push work asynchronously and the backend wants an explicit wake event. Unlike a plain `uvm_tlm_analysis_fifo`, this class owns a typed `analysis_export`, keeps a simple queue/count model, supports immediate `try_get()` or blocking `get()`, and exposes `flush()` for reset choreography. The `state_changed_ev` hook is what lets the backend park when idle and wake cleanly when a front-end or refresh source adds new work. |
| `sv/vip_mc_cmd_queue.sv` | QoS scheduling queue | Owns the backlog between admission and device issue. It allocates one FIFO per configured QoS class, stamps admit order/time, clamps the requested class into range, and at pick time computes the effective class after any aging promotion. It also preserves strict same-stream ordering for a `{port_id, axi4_id, op}` stream by tracking the oldest queued and inflight command per stream, so higher-level reordering never violates per-stream rules. Once an entry is chosen it assigns the flat device tag, moves the command into the inflight map, and later retires it on the matching DRAM response. |
| `sv/vip_mc_fe_base.sv` | Abstract front-end base class | Provides the minimal contract every host-protocol front-end must implement. The base owns the fixed `port_id` and the `req_port` used to publish `vip_mc_cmd_entry` objects into the backend, while derived classes provide the protocol-specific logic for turning completions back into bus activity. Its two abstract hooks, `complete()` and `handle_reset()`, are the points where each protocol driver plugs in its response behavior and reset cleanup without the backend needing to know protocol details. |
| `sv/vip_mc_refresh.sv` | Refresh engine | Encapsulates the periodic refresh sideband so the backend can remain the single writer to `vip_dram`. `vip_mc` caches the resolved `tREFI` into this component at start-of-simulation, `arm()` forks a long-lived periodic emitter on every reset deassertion, and `flush()` kills that process plus resets the refresh counters on reset assertion. When active, it emits one MC-internal `REF` command entry per rank and sends those through its analysis port into the backend, so refresh participates in the same arbitration and request path as normal traffic. |
| `sv/vip_mc_backend.sv` | Shared protocol-agnostic core | Central scheduler and device boundary for the controller VIP. It owns the per-port ingress FIFOs, the refresh FIFO, the shared command queue, the single device-bound `req_port`, and the shared DRAM response subscriber. At runtime it admits front-end traffic in weighted round-robin port order, queues it under the QoS/aging policy, enforces the finite device in-flight window, serializes refresh versus normal traffic, and issues device requests while recording diagnostic taps such as `issued_port`. On completions it looks up the matching command, copies timing/data back onto the entry, releases device-window credits, and dispatches the completed work item to the owning front-end. |
| `sv/vip_mc_axi4_driver.sv` | AXI4 front-end implementation | Implements the full host-side AXI4 behavior for the delivered slice. It samples the owned AXI4 interface on the controller clocking block, captures `AW`/`W`/`AR`, checks address ownership and legality, converts bursts into the row-granular `vip_dram` request shape expected by the backend, and emits `vip_mc_cmd_entry` objects through the base `req_port`. On the return path it manages pending `B` and `R` queues, the single active read burst (AXI4 has no read-data interleaving), response buffering, exclusive-access state, `WREADY` backpressure, and per-beat read timing. This is where the protocol-facing details live: narrow and unaligned transfers, `INCR`/`FIXED`/`WRAP`, USER passthrough, `DECERR`, `EXOKAY`, late-response accounting, and the final driving of `BVALID`/`RVALID` back onto the bus. |
| `sv/vip_mc_chi_driver.sv` | CHI SN front-end implementation | Implements the CHI memory-subordinate behavior (opt-in, `+define+VIP_MC_ENABLE_CHI`). It drives link activation and credit exchange on the owned `vip_mc_chi_if`, decodes inbound REQ flits, and maps ReadNoSnp/ReadNoSnpSep and WriteNoSnp{Full,Ptl,Zero} onto the same backend `vip_mc_cmd_entry` path the AXI4 front-end uses (reusing the `vip_chi_driver_snf` algorithms). On completion it emits the matching RSP/DAT flits — Comp / CompDBIDResp / DBIDResp / CompData / DataSepResp / ReadReceipt — honors the `split_write_rsp` style, classifies DECERR windows, and rejects unsupported opcodes with a defined Comp(NONDATA_ERROR). Credit/node/split knobs come from `vip_mc_chi_cfg`; telemetry accessors (`get_read_count`, `get_write_count`, `get_decerr_count`, `get_unsupported_count`) support directed checks. |
| `sv/vip_mc_chi_cmd_entry.sv` | CHI work-item extension | Extends the canonical `vip_mc_cmd_entry` with the CHI-specific fields the SN front-end needs to reconstruct responses (txnid/srcid, DBID, sep-read ReturnNID/ReturnTxnID, split-write style, write-zero flag, CHI response-error class). |

## Configuration knobs (`vip_mc_config`)

`vip_mc_config` owns the shared MC policy for all instantiated ports. The table
below covers every direct field on the object, including the owned child
configs reached as `cfg.axi4` and `cfg.ports[i]`.

| Knob | Type | Default | Description |
| --- | --- | --- | --- |
| `axi4` | `vip_mc_axi4_cfg` | created in `new()` | Owned AXI4-facing child config. Use this handle for native frontend policy such as pending-queue depths, QoS remap, exclusive support, DECERR windows, and the driver `dram_handle_path`. `vip_mc` still treats `max_outstanding_wr` / `max_outstanding_rd` as the top-level ingress budget knobs and mirrors them into `cfg.axi4.aw_outstanding_limit` / `cfg.axi4.ar_outstanding_limit` during `build_phase`. |
| `chi` | `vip_mc_chi_cfg` | created in `new()` | Owned CHI-facing child config for CHI ports. Native SN knobs: `sn_node_id`, `initial_{req,rsp,dat}_credits` (all default `16`), and `split_write_rsp` (default `1` = DBIDResp then a deferred Comp; `0` = combined CompDBIDResp). It is a plain int/bit object with no `vip_chi` dependency, so it always compiles even in AXI4-only builds; `validate()` (invoked from `vip_mc_config::validate()`) rejects credit counts below `1`. DECERR windows are shared with `cfg.axi4` (the CHI front-end reuses the same DECERR map). |
| `max_outstanding_rd` | `int` | `16` | Read-side acceptance ceiling for each AXI4 frontend. After `build_phase` mirrors it into `cfg.axi4.ar_outstanding_limit`, the driver uses it to decide when to deassert `ARREADY` and stop admitting more read commands. `0` is allowed and means effectively unbounded admission; negative values are rejected by `validate()`. |
| `max_outstanding_wr` | `int` | `16` | Write-side acceptance ceiling for each AXI4 frontend. It is mirrored into `cfg.axi4.aw_outstanding_limit`, so this is the knob that determines when `AWREADY` backpressures new write-address traffic. As with the read limit, `0` means unbounded and negative values are illegal. |
| `qos_class_count` | `int` | `1` | Number of scheduler priority classes in the shared backend. `1` collapses behavior to legacy single-class FCFS. Larger values allow `AxQOS` traffic to fan into multiple priority bands, which is what makes arbitration and aging policy observable under load. |
| `qos_aging_ns` | `real` | `0.0` | Aging threshold, in nanoseconds, for requests waiting in the backend command queue. Once a request has waited longer than this threshold it is promoted one class per threshold interval, preventing indefinite starvation of low-priority streams. `0.0` disables aging and leaves class order strict. |
| `fr_fcfs_enable` | `bool_t` | `FALSE` | Enables the backend's readiness-aware within-class tie-break. When `FALSE`, effective QoS classes still use legacy FCFS ordering. When `TRUE`, the backend compares all currently eligible candidates in the winning class with `dram.predict()` and issues the one with the smallest predicted `last_beat_ready_time`, while still preserving same-ID order, refresh priority, aging, and response-credit gating. |
| `fr_fcfs_starvation_cap` | `int` | `0` | Within-class fairness bound on FR-FCFS reordering (§11 item 1). Each pick that serves a readiness winner charges one bypass to every older eligible entry; once an entry has been bypassed this many times the backend force-serves the oldest such entry (FCFS override), so a page miss cannot be starved behind a younger page-hit streak. `0` disables the cap (unbounded reorder = pure FR-FCFS). Only meaningful with `fr_fcfs_enable`; orthogonal to `qos_aging_ns` (which promotes across classes). Overrides are counted by `get_fr_fcfs_forced_count()`. |
| `rd_wr_grouping_enable` | `bool_t` | `FALSE` | Turnaround-aware FR-FCFS (§11 item 1). Makes bus direction (RD/WR) the primary within-class selection key: the backend prefers the eligible candidate whose direction matches the last issued command's, so reads and writes issue in runs that amortize the device read/write turnaround bubble (tWTR/tRTW) instead of paying it on every RD↔WR flip. Readiness (predicted last beat, then `admit_order`) decides within a direction, and the pure readiness winner is the fallback when no same-direction candidate is eligible. This is the classic write-drain trade — a little per-request latency for bus throughput. Only meaningful with `fr_fcfs_enable`. Issued turnarounds are counted by `get_bus_turnaround_count()`, grouping overrides by `get_rd_wr_grouped_count()`. |
| `rd_wr_grouping_max` | `int` | `0` | Max consecutive same-direction issues before the grouping preference inverts for one pick (a forced turnaround), so the opposite direction cannot be starved by an unbroken same-direction stream. `0` = unbounded run (drain the current direction while candidates exist). A within-direction bound, distinct from `fr_fcfs_starvation_cap`; ignored unless `rd_wr_grouping_enable`. |
| `rsp_buf_depth` | `int` | `0` | Response-buffer credit pool for undriven `B` / `R` traffic. The backend stops issuing more device work when the frontend response path would overflow this budget. `0` preserves the legacy unbounded behavior, while a finite value is useful when you want backpressure and queue growth to look like a real controller rather than an ideal sink. |
| `max_inflight_to_device` | `int` | auto (`N_RANKS * N_BANK_GROUPS * BANKS_PER_BG`) | Device-side command window: how many requests may be issued to `vip_dram` before their responses come back. By default `vip_mc` resolves this to one slot per bank across all ranks (`16` for the default DDR4 geometry), which makes contention and QoS observable without needing a per-test override. Set it to `0` only when you explicitly want the legacy unbounded issue behavior. |
| `addr_map_policy` | `vip_dram_addr_map_t` | `vip_dram_default_addr_map(...)` | Shared byte-address decode policy used by both the MC and the owned DRAM model. `vip_mc` validates that the slices cover the configured geometry exactly once, uses the map for backend decode and scheduling decisions, and then copies the same layout into `vip_dram` at `start_of_simulation_phase`. The default layout is the normal LSB-first `[byte][col][bank][bg][row][rank]` ordering. |
| `refresh_enabled` | `bool_t` | `TRUE` | Master enable for the refresh thread. Set it to `FALSE` when a test wants refresh completely absent, either to isolate latency behavior or to avoid periodic refresh pre-emption in highly targeted protocol checks. |
| `refresh_policy` | `vip_mc_refresh_policy_e` | `VIP_MC_REFRESH_PERIODIC_E` | Selects the refresh algorithm. `VIP_MC_REFRESH_PERIODIC_E` emits one REF burst every `tREFI`. `VIP_MC_REFRESH_DEFERRED_E` postpones refreshes (accruing one unit of debt per `tREFI`) up to `refresh_max_deferred`, then drains the whole debt in a forced catch-up burst — the same average rate as periodic but bursty, modeling JEDEC's allowed postponement. The refresh engine exposes `get_deferred_debt()` / `get_peak_deferred_debt()` / `get_deferred_catchup_count()` for observability. |
| `refresh_max_deferred` | `int` | `8` | Under `VIP_MC_REFRESH_DEFERRED_E`, the maximum number of `tREFI` intervals a refresh may be postponed before a forced catch-up burst (JEDEC allows up to 8). Ignored by the periodic policy. `validate()` requires it to be `>= 1`. |
| `tREFI_override` | `real` | `-1.0` | Refresh-interval override in nanoseconds. A negative value means “inherit the device preset” from `vip_dram_config.timing.tREFI`; any non-negative value replaces the cached interval used by the refresh thread. This is the clean way to model non-default or fractional-nanosecond refresh cadence without editing the DRAM preset itself. |
| `init_delay_enabled` | `bool_t` | `FALSE` | Enables a tINIT-like controller bring-up hold-off. When set (with `init_delay_ns > 0`), the backend admits and queues host requests but issues nothing to the device — normal traffic and refresh alike — until `init_delay_ns` after each reset deassertion, then services the backlog. Models a device that is not ready immediately out of reset. |
| `init_delay_ns` | `real` | `0.0` | Bring-up hold-off duration in nanoseconds, applied after every reset deassertion when `init_delay_enabled`. A non-positive value (or the feature disabled) opens the gate immediately. The delay re-arms on each reset, so a mid-test reset re-triggers bring-up. |
| `perf_counters_enabled` | `bool_t` | `TRUE` | Gates the internal performance counters and the associated bookkeeping in the frontend, backend, and top-level `vip_mc` wrapper. Disable it when you want the leanest possible behavioral run or when a test should not accumulate or inspect latency/backpressure statistics across reset boundaries. |
| `honor_beat_timing` | `bool_t` | `TRUE` | Preserves `vip_dram`'s per-beat readiness on the AXI4 read-data channel. When enabled, `vip_mc` requests delivery at `first_beat_ready_time` and the driver paces each `R` beat from first to last, snapped to bus edges. When disabled, the device reverts to last-beat delivery and the frontend drives the read burst back-to-back, which also suppresses late-response accounting for beat-by-beat pacing. |
| `write_coalescing_enable` | `bool_t` | `FALSE` | Merges a newly admitted write into the newest outstanding same-stream (`{port,id,WR}`) pending write to the same row-word, overlaying byte lanes (newer wins); the one device access fans out a completion to every merged host write (§11 item 2). Needs a host holding >1 write outstanding (AXI4 `wr_outstanding_max > 1` / CHI `multi_outstanding_write`). The timing scoreboard is coalescing-unaware, so enable it only with the scoreboard off. Ordering assumption: only same-stream (`{port,id,WR}`) writes are merged, and the MC does not order the RD and WR streams against each other for the same address (matching AXI4, which needs master-side serialization for R/W ordering); so a read to a coalesced row can observe a later-merged write's bytes early — do not enable coalescing if a data scoreboard relies on MC-enforced same-address read/write ordering. Counted by the backend's `get_coalesced_write_count()`. |
| `ecc_enable` | `bool_t` | `FALSE` | Applies a 64+8 SECDED decision to each completed read using the device response's `injected_fault` severity (§11 item 5): CORRECTABLE is corrected to OKAY (bumps `get_ecc_corrected_count()`), UNCORRECTABLE becomes a bus SLVERR (bumps `get_ecc_uncorrectable_count()`). Device read-faults are injected deterministically via `vip_dram::inject_fault()`; this knob only gates the controller-side classification. Writes are unaffected. |
| `ports[]` | `vip_mc_port_runtime_cfg[]` | sized by `ensure_port_count(N_PORTS)` | Per-port runtime policy map. Each entry carries an owned-address region list (`regions[]`, with an empty list meaning the port may target the full device), a frontend arbitration weight (`arb_weight`, default `1`, with non-positive values clamped back to `1`), and a fallback `vif_key` string (auto-seeded as `vif_port<i>` when left blank). Use `ports[]` for runtime access partitioning and weighted scheduling; compile-time protocol and width selection still lives in the `PORTS[]` parameter table. |

Performance-counter accessors exposed by `vip_mc` now include:

- `get_refresh_count()` and `get_cmd_queue_peak_depth()` for controller-side scheduling activity.
- `get_decerr_count()`, `get_4k_violation_count()`, `get_wready_stall_cycles()`, `get_rsp_late_count()`, and `get_rsp_buf_full_cycles()` for AXI4-facing rejects and backpressure.
- `get_exokay_count()` and `get_excl_fail_count()` for exclusive-access outcomes.
- `get_row_hit_rate()`, `get_predict_accuracy()`, `get_effective_bandwidth()`, and `get_bus_utilization()` for aggregate timing/throughput telemetry. `get_predict_accuracy()` is reported as mean absolute last-beat error in ns, while bandwidth/utilization are measured over the observed device data window from the first ready beat to the last burst end.
- Residual observability (§11): `get_observed_reorder_count()` (out-of-order retirements); `get_min_latency_ns()` / `get_mean_latency_ns()` / `get_max_latency_ns()` / `get_latency_sample_count()` / `get_latency_hist_count(bucket)` (completion latency, admit→last beat); `get_occupancy_hist_count(depth)` / `get_occupancy_sample_count()` (pending-depth histogram); and `get_port_completed_count(port)` / `get_port_data_bytes(port)` (per-port utilization).
- Error / scheduling: `get_ecc_corrected_count()` and `get_ecc_uncorrectable_count()` for the SECDED read path, `get_fr_fcfs_forced_count()` for FR-FCFS starvation-cap overrides, and `get_bus_turnaround_count()` / `get_rd_wr_grouped_count()` for read/write bus-direction grouping (issued RD↔WR turnarounds and grouping overrides of the readiness winner).

Practical conventions:

- `0` means “unbounded” for the depth-style knobs (`max_outstanding_rd`, `max_outstanding_wr`, `rsp_buf_depth`) and is the explicit legacy-unbounded setting for `max_inflight_to_device`.
- `tREFI_override < 0.0` means “inherit the DRAM preset” rather than “disable refresh”.
- An empty `ports[i].regions` list means no address ownership restriction for that port.

Current constraints:

- ports are homogeneous per protocol: all AXI4 ports in one `vip_mc` instance
  share one `vip_mc_axi4_cfg_t`, and all CHI ports share one `vip_mc_chi_cfg_t`
- host bus width must be at most the `vip_dram` row width and divide it evenly
  (`WDATA_BYTES_P`/`DATA_BYTES_P` <= and evenly dividing `ROW_BYTES_P`); a narrower
  bus gathers several host beats into one row word (and a sub-row beat scatters
  into part of a row) rather than mapping 1:1
- the CHI SN front-end is opt-in behind `+define+VIP_MC_ENABLE_CHI`; the AXI4-only
  core carries no `vip_chi` dependency without it
- CHI opcode coverage is the SN memory-target subset above; persist CMOs are
  acknowledged locally, atomics are locally rejected with `Comp(NONDATA_ERROR)`,
  and snoop / DVM / stash traffic remains outside the SN memory-target subset

Why `VIP_MC_ENABLE_CHI` exists:

`vip_mc` keeps CHI as a compile-time option so AXI4-only users can build the
controller with only the `vip_memory` and `vip_dram` dependencies. The CHI path
reuses `vip_chi_types_pkg` for flit/opcode/width types and compiles
`vip_mc_chi_if`, `vip_mc_chi_vif_holder`, `vip_mc_chi_cmd_entry`, and
`vip_mc_chi_driver`; those files are intentionally hidden behind the define so
the always-on core does not import or require `vip_chi`.

Set `+define+VIP_MC_ENABLE_CHI` when any `PORTS[]` entry selects CHI, or when
building the example testbench because it exercises both AXI4 and CHI slices and
depends on `vip_chi_agent`. Leave it unset for an AXI4-only integration. This is
a compile/elaboration dependency switch, not a runtime enable; the actual port
mix is still chosen by the `PORTS[]` parameter table.

Build / smoke example (run from the repository root; the `testbench/sv` harness
builds the AXI4 suite and, through `vip_mc_example.core`, the CHI slice too):

```sh
fusesoc --cores-root=. run --clean --setup --build --target=default --tool=vcs akerlund::vip_mc_example:0
./build/akerlund__vip_mc_example_0/default-vcs/akerlund__vip_mc_example_0 +UVM_TESTNAME=tc_mc_axi4_single_beat
./build/akerlund__vip_mc_example_0/default-vcs/akerlund__vip_mc_example_0 +UVM_TESTNAME=tc_mc_chi_e_write_read
```

The same testcases run in the Python flow over Verilator. `VIP_MC_ENABLE_CHI`
has no equivalent there — the port has no compile-time CHI switch, so the CHI
testcases are always built:

```sh
python3 testbench/py/check_versions.py
./testbench/py/run_fusesoc.sh --target sim
```

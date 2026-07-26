# `vip_mc` — Implementation Plan

A behavioral DDR memory-controller VIP that **replaces MIG** in
densemem-style testbenches. It exposes AXI4 upward to the manager VIP
and the neutral TLM contract of [`vip_dram`](../vip_dram/IMPLEMENTATION_PLAN.md)
downward to the device model.

```text
[manager VIP / TB] ── AXI4 ── [vip_mc] ── neutral TLM ── [vip_dram] ── vip_mem
```

`vip_mc` owns everything that real silicon controllers own and the
device model deliberately does not:

- AXI4 bus protocol (controller side): handshakes, same-ID ordering,
  emergent inter-ID completion order, and `DECERR` for unmapped / illegal
  address regions (a real decode error — not probabilistic fault injection).
- Command queue (QoS priority classes + aging, FCFS within a class; §5/§8.9) —
  converts AXI4 transactions into `vip_dram_req`.
- Refresh scheduling — the `tREFI` timer lives here; `vip_mc` emits
  `VIP_DRAM_OP_REF_E` to `vip_dram`.
- Address mapping policy — `vip_mc` decides the system-addr →
  `{rank,bg,bank,row,col}` slicing and writes it into
  `vip_dram_config.addr_map` at `start_of_simulation_phase`.

Naming: this VIP is `vip_mc`, distinct from the existing
[`vip_mig_mc`](../vip_mig_mc/) sidecar. `vip_mig_mc` exists solely to
bypass the missing Xilinx MIG backdoor (it shadows RDATA while real
MIG IP drives AXI4); `vip_mc` is the opposite — a fully behavioral
controller that replaces MIG entirely.

**Goal.** The point of `vip_mc` is to respond to AXI4 traffic in a
*realistic-enough* manner — believable latency, ordering, backpressure and
refresh behavior driven by `vip_dram`'s timing model — **not** to be a
cycle-exact reproduction of a specific controller's micro-architecture or of
the DRAM backend. "Realistic responses over exact backend fidelity" is the
guiding trade-off.

### Main features

- **Behavioral DDR MC** (MIG replacement): one or more **host front-ends**
  upward, neutral `vip_dram` TLM downward.
- **Multi-port** (§2.1): `N_PORTS` configurable host ports, each a per-port
  protocol front-end (AXI4 and CHI, with CHI D/E selection) over a shared protocol-agnostic
  back-end. "2× AXI4" or "1× AXI4 + 1× CHI-E" is just a different `PORTS[]`
  table — the back-end is identical.
- **Zero AXI4-VIP dependency**: owns its **own** `vip_mc_axi4_if` + types and
  native config; an optional `vip_mc_axi4_connect` module bridges to the stock
  `vip_axi4_agent` manager for stimulus (the only place `vip_axi4_if` appears).
- **QoS-prioritised command queue** (priority classes by `AxQOS` + aging, FCFS
  within a class, §5/§8.9) with AXI4↔DRAM transaction mapping (one burst → N DRAM
  column accesses, §5.6) and a flat 64-bit opaque completion tag.
- **Full AXI4 feature set** (§4.6): `INCR`/`WRAP`/`FIXED`, narrow, unaligned,
  exclusive (`EXOKAY`), USER passthrough — MC algorithms
  reused from `vip_axi4_agent`, on native config.
- **Refresh scheduling**: `tREFI` timer emitting `VIP_DRAM_OP_REF_E` per rank.
- **Address-mapping policy** owned here, written into `vip_dram_config.addr_map`.
- **Realistic response behavior**: per-request latency from `vip_dram`'s
  prediction, mandatory same-ID ordering, **emergent** inter-ID out-of-order
  completion, and **finite buffers that backpressure** — a bounded W-data buffer
  (real `WREADY` toggling) and a response buffer that credit-gates request issue
  (§4.5/§8.9); `DECERR` for unmapped / 4 KB-violating accesses.
- **Native config** (no `vip_axi4_cfg_sub`): outstanding limits, finite buffer
  depths, QoS-class map + aging, `exclusive_enabled`, DECERR
  region map, `dram_handle_path`, perf gates — and *deliberately no* fault-injection
  or inter-ID reorder *logic* (§4.3).
- Performance + **observability** counters (refresh count, command-queue peak
  depth, DECERR / 4 KB classifications, WREADY stall cycles, late responses,
  response-buffer-full cycles, exclusive outcomes, row-hit rate, effective
  bandwidth / utilization, and mean last-beat prediction error — §8.8).

### Determinism, seed & clocking

- **Fully deterministic and seed-independent.** With the probabilistic
  fault-injection knobs removed (§4.3), the first-cut MC has **no stochastic
  behavior at all** — QoS-class + aging dispatch, `vip_dram`-derived timing, and
  periodic refresh are all deterministic. Same stimulus ⇒ same B/R timing and ordering,
  regardless of seed. (The only seed-dependence in the whole MC+DRAM model is
  optional `vip_dram` memory-content randomization, which affects data, not
  timing.) Post-reset state is the canonical deterministic state (§9).
- **Clocking / time domains — different MC/DRAM vs DUT frequency is supported
  and is the realistic case.** The AXI4 face (`vip_mc_axi4_if`) is sampled and
  driven on the **bus/fabric clock** supplied by the TB's `clk_rst` — whatever
  frequency the DUT uses. The DRAM timing model is **absolute-time** (ns, from
  the `t_ck` preset) with no clock on the neutral TLM. `vip_mc` is the bridge:
  it accepts AXI4 at the bus clock, computes DRAM-domain ns latencies, and
  re-times completions onto the next bus edge at-or-after each `*_ready_time`
  (§5.4, including the "late response" case). The bus clock and the modeled
  DRAM clock are **independent** — exactly like a real controller bridging a
  fabric clock to a DDR PHY clock.

---

## 1. Scope

`vip_mc` is a standalone UVM component with **no dependency on the AXI4 VIP**
(`vip_axi4_agent_pkg`, `vip_axi4_types_pkg`, `vip_axi4_cfg_sub`, or
`vip_axi4_if`). This is a hard architectural decision (see "Core architectural
decisions" below): `vip_mc` defines and owns its **own** AXI4 controller-side interface
`vip_mc_axi4_if #(CFG_P)` and its own width/cfg types in `vip_mc_axi4_types_pkg`,
and implements the AXI4 subordinate-side protocol directly against that
interface.

`vip_mc` is also **multi-port**: it fronts `N_PORTS` host interfaces over a
single protocol-agnostic back-end (§2.1). Each port is a protocol front-end
adapter — AXI4 or CHI (D/E selected in cfg) — and the configuration (how many ports,
which protocol each is) is fixed by the `PORTS[]` parameter table described in
§2.1. The single-AXI4 case is just `N_PORTS = 1`.

Stimulus reuse is optional and fully decoupled: a small **connector module**
`vip_mc_axi4_connect` cross-wires `vip_mc_axi4_if` to a stock `vip_axi4_if`
(MANAGER role) so the existing `vip_axi4_agent` can drive traffic in the
example TB — exactly the two-instance cross-wiring pattern used in
[`axi4_tb_top.sv`](../examples/vip_axi4_agent/tb/axi4_tb_top.sv). The
connector is the **only** place `vip_axi4_if` is named, it is a Verilog
module (not part of `vip_mc_pkg`), and it is compiled only on the
stock-manager integration path. `vip_mc_pkg` itself compiles and runs
standalone — a user driving `vip_mc_axi4_if` from their own DUT or a custom
driver needs neither the connector nor the AXI4 VIP.

### Core architectural decisions

1. The VIP shall have **NO** dependency on the AXI4 VIP.
2. `vip_mc` has its **own** AXI4 interface, `vip_mc_axi4_if`. A connector
   module bridges it to `vip_axi4_if` when the stock manager is reused.
3. `vip_mc` shall **NOT** use `vip_axi4_cfg_sub`. Its config knobs are
   defined natively on `vip_mc_axi4_cfg` (§4.3, §8.2). The audit of
   `vip_axi4_cfg_sub`'s fields against real-MC behavior (§4.3) is what
   motivates this: most of that stock SUB config is generic-subordinate test
   scaffolding that does not correspond to anything a real controller does.

### CHI planning decisions

> **The CHI front-end builds on the `vip_chi` agent** ([`../vip_chi/`](../vip_chi/)),
> which supplies a CHI-D/E `vip_chi_types_pkg` (issue enum, `vip_chi_cfg_t`, the
> flit structs, and the `ReadNoSnp*`/`WriteNoSnp*` opcode tables), a role-gated
> `vip_chi_if`, an **SN-F memory-target** driver (`vip_chi_driver_snf`, over
> `vip_memory_pkg`), an **RN-I requester** driver, plus monitor / coverage / SVA
> / link-credit manager / sequencer / `seq_lib`. The CHI plan below is therefore
> **reuse-first**, not own-everything: the CHI flit/opcode/width types are taken
> from `vip_chi`, and the one artifact `vip_mc` *owns* is a single-role
> controller-side interface, for the same B1 reason it owns `vip_mc_axi4_if`.

1. CHI versioning is a **config concern, not an interface-name concern**.
  `vip_mc_proto_e` selects **AXI4 vs CHI** only; the trailing `_E` on
  `VIP_MC_PROTO_CHI_E` is the enum suffix convention, **not** "CHI Issue E".
  The actual CHI issue/version lives in `vip_mc_chi_cfg_t.issue`.
2. **Flit/opcode/width types are reused from `vip_chi_types_pkg`, not re-owned.**
  `vip_mc` does **not** carry its own copy of the CHI flit typedefs, opcode
  tables, or width-derivation helpers — those come from
  `vip_chi_types #(CFG_P)` in `vip_chi_types_pkg`. The earlier
  `vip_mc_chi_types_pkg` (issue/cfg + a re-derived width container) is a
  near-verbatim duplicate of `vip_chi_types_pkg` and is dropped; see §3.
3. `vip_mc` owns **one** CHI artifact: a **single-role** controller-side
  interface `vip_mc_chi_if #(CFG_P)` (SN role, **no `ROLE_P`**) plus one CHI
  front-end class `vip_mc_chi_driver #(CFG_P, DRAM_CFG_P)`. Owning the interface
  (rather than reusing the role-gated `vip_chi_if`) is the **same B1 decision**
  made for AXI4: `vip_chi_if` is role-gated (`ROLE_P`, generate-selected
  `snf_cb`/`rni_cb`), so a shared instance hits the role-gating trap; a separate
  single-role IF bridged by a connector does not. We do **not** plan separate
  `vip_mc_chi_b_if` / `_d_if` / `_e_if` files — issue-specific widths/opcodes/
  optional fields are all derived from `CFG_P.issue` inside
  `vip_chi_types #(CFG_P)`.
4. The planned issue set is **CHI-D and CHI-E**, from the start. The first CHI
  design shall accept `issue == VIP_MC_CHI_ISSUE_D_E` or `VIP_MC_CHI_ISSUE_E_E`
  and reject anything else in validation. "Same files, different cfg," not
  "Issue E now, redesign for D later." The D/E delta lives entirely in the
  **reused CHI layer** (`vip_chi_types`); `vip_mc_chi_if` and
  `vip_mc_chi_driver` consume those derived types, and `vip_mc_backend` stays
  issue-blind and protocol-agnostic.
5. **The CHI front-end reuses `vip_chi_driver_snf`'s flit-handling as
  *algorithms*** — the same stance §4.6 takes toward `vip_axi4_agent`: lifted
  and re-implemented under `vip_mc`'s own names against `vip_mc_chi_if` and the
  neutral TLM, never imported or instantiated. `vip_chi_driver_snf` is already
  an SN memory-target, so the marshalling is largely directly reusable.
6. First functional subset = **SN memory-target traffic only**: link
  activation, credit return, `ReadNoSnp*` / `WriteNoSnp*` style requests,
  write data, `Comp` / `CompDBIDResp` / `CompData` completions, and explicit
  unsupported-op / decode-error handling. Snoop traffic, DVM, stash,
  atomics, persistence, and broader home-node behavior stay out of scope until
  a concrete coherent-memory use-case requires them.
7. **The AXI4-only core stays free of any `vip_chi` dependency.** The port table
  (`vip_mc_port_cfg_t`, §2.1) keeps a **thin local `vip_mc_chi_cfg_t`** — just
  the user-selected axes (issue + widths + optional-field enables), *not* the
  re-derived width container — so `vip_mc_types_pkg`/`vip_mc_pkg` compile with no
  `vip_chi` import. The CHI front-end maps `vip_mc_chi_cfg_t → vip_chi_cfg_t` at
  its own boundary; only the CHI files pull in `vip_chi`. Stimulus reuse mirrors
  AXI4: the `vip_chi` RN-I agent drives a bridged `vip_chi_if` via a
  `vip_mc_chi_connect` connector (§10.1, §13), the only place `vip_chi_if`
  appears.

In scope:

- AXI4 controller-side protocol implementation (on `vip_mc_axi4_if`):
  handshakes for AW/W/B/AR/R, the AXI4 same-ID ordering guarantee, and a
  4 KB-boundary check on AW/AR with DECERR. **Full AXI4 feature support**
  (§4.6): `INCR`/`WRAP`/`FIXED` bursts, narrow transfers, unaligned addresses,
  exclusive access (`AxLOCK` → `EXOKAY`), and `USER` passthrough (AXI4 has no
  read-data interleaving) — the reusable algorithms are lifted from
  `vip_axi4_agent` (the exclusive monitor, the address iterator) onto `vip_mc`'s
  own native config (§4.3). Inter-ID completion order is **emergent** (it follows
  `vip_dram`'s per-request timing, not a reorder knob, §5.2), but completions
  pass through a **finite response buffer** that backpressures the request path
  when the master stalls B/R (§4.5, §8.9).
- Per-port front-ends marshal AW/W/AR beats into requests and drive B/R; a
  shared backend arbiter serializes them into an internal **QoS-prioritised**
  command queue (priority classes by `AxQOS`, FCFS within a class, with **aging**
  to prevent starvation; flat-tag tracking) and is the single writer to the
  device; the backend's response subscriber demuxes `vip_dram_rsp` back to the
  originating front-end by `port_id` (§5, §8.9).
- Refresh policy: `tREFI` timer with periodic emission of
  `VIP_DRAM_OP_REF_E`, plus a `DEFERRED` postpone/catch-up policy (§6.2).
- Address-mapping policy: `vip_mc` owns the system-addr →
  `{rank,bg,bank,row,col}` decision and writes it into
  `vip_dram_config.addr_map` at `start_of_simulation_phase`.
- Address-decode errors: `DECERR` on accesses to an unmapped / illegal
  address region (a configurable region map) and on AXI4 4 KB-boundary
  violations (§4.4). These are the only error responses a first-cut MC
  produces — there is **no** probabilistic SLVERR or RDATA-corruption
  injection (that is generic-subordinate test scaffolding, not MC behavior;
  data-integrity faults belong to the device/ECC layer — §11).
- Reset choreography: bus reset → drain command queue → call the **blocking**
  `dram.reset()` task (it triggers `reset_event` and waits on the device's
  `reset_done_event`, §9). Reset is watched on `vip_mc`'s own
  `vip_mc_axi4_if`; multi-agent `rst_n` sharing is coordinated by a
  TB-provided handler (no `vip_axi4_*` component, §9).
- **QoS-aware scheduling** (§5, §8.9): the arbiter biases its pick by `AxQOS`
  priority class with aging, instead of pure arrival-order FCFS; same-ID order
  and refresh priority are still honored.
- **Finite buffers / backpressure** (§4.5, §8.9): request-acceptance limits
  (AW/AR outstanding), a bounded W-data buffer (so `WREADY` actually toggles),
  and a bounded response buffer (credit-gates request issue) — depth-∞ defaults
  reproduce the earlier unbounded behavior.
- **Observability counters** (§8.8): REF emission, command-queue peak depth,
  DECERR / 4 KB / WREADY-stall / late-response / response-buffer-full counts,
  exclusive outcomes, row-hit rate, effective bandwidth / utilization, and mean
  last-beat prediction error.

Out of scope (lives elsewhere):

- DRAM device timing — lives in [`vip_dram`](../vip_dram/IMPLEMENTATION_PLAN.md)
  (`tRCD`, `tCL`, `tWL`, `tRTP`, `tFAW`, `tRFC`, …).
- Bank-state FSM / page policy — lives in `vip_dram`.
- AXI4 stimulus generation, monitoring, coverage, sequence library —
  in the example, the stock `vip_axi4_agent` in `MANAGER` role handles
  those upward, driving its own `vip_axi4_if` bridged to `vip_mc_axi4_if`
  by the connector. `vip_mc` only implements the controller-side responder.
- DFI signal modeling — lives in a future sibling adapter; `vip_mc`
  speaks the neutral TLM only.
- Multi-channel / multi-rank striping — first cut is single channel;
  future work, see §11.
- FR-FCFS reordering (the within-QoS-class readiness ordering upgrade; the
  scheduler reserves the hook) and write coalescing — listed in §11.
- ECC (data-path SECDED or device-side) — not modeled in the first
  cut; see §11.3 for future direction.

Protocol-specific **initialization, mode-register programming, power-state
sequencing, and training orchestration** are out of scope and remain so until
a lower-level (JEDEC-command or DFI) face exists; an AXI4 face alone cannot
model them. A DDR4/DDR5/etc. timing preset is not protocol support.

---

## 2. Layered architecture

`vip_mc` is **multi-port**: `N_PORTS` host front-ends share one
protocol-agnostic back-end. Each front-end is a per-port protocol adapter
(AXI4 or CHI, with D/E selected in cfg) that converts its protocol to an **MC-internal
request** (a `vip_mc_cmd_entry_t` carrying the neutral payload + `axi4_id`); the
back-end arbiter assigns order and derives the **device-neutral** `vip_dram_req`
it writes to the device, so the device boundary sees only neutral, port/ID-
agnostic requests (§8.9). "2× AXI4" and "1× AXI4 +
1× CHI-E" differ **only** in which front-end type sits on each port — the
back-end is identical.

```text
        ┌──────────────────────────── user testbench ────────────────────────────┐
        │  port 0 stimulus              port 1 stimulus               vip_dram     │
        │  (e.g. vip_axi4_agent)        (e.g. vip_axi4_agent           (device)    │
        │                                or a CHI manager)                         │
        └───────┬────────────────────────────┬──────────────────────────┬─────────┘
   vip_mc_axi4_if / vip_mc_chi_if  (one host IF per port)                 │ neutral TLM
                │                              │                          │
   ┌────────────▼──────────────────────────────▼──────────────────┐      │
   │                            vip_mc                             │      │
   │  ┌────────────────────┐     ┌────────────────────┐  front-    │      │
   │  │ vip_mc_axi4_driver │     │ vip_mc_axi4_driver │  ends:      │      │
   │  │  (port 0)          │     │ or vip_mc_chi_driver│ one per    │      │
   │  │  proto ⇄ neutral   │     │  (port 1)          │  port,      │      │
   │  └─────────┬──────────┘     └─────────┬──────────┘  extend     │      │
   │            │ neutral req/rsp          │ neutral     fe_base    │      │
   │  ┌─────────▼──────────────────────────▼─────────────────────┐ │      │
   │  │ vip_mc_backend #(DRAM_CFG_P, N_PORTS)                    │ │      │
   │  │   arbiter (QoS class + aging) → cmd_queue → refresh      │─┼──────▶ vip_dram_req
   │  │   response demux by cmd_entry.port_id                    │◀┼────── vip_dram_rsp
   │  └──────────────────────────────────────────────────────────┘ │
   └────────────────────────────────────────────────────────────────┘
   (each AXI4 port may bridge a stock vip_axi4_agent MANAGER via a per-port
    vip_mc_axi4_connect — the B1 two-instance pattern, replicated per AXI4 port)
```

Rules:

1. `vip_mc_pkg` depends on `vip_dram_pkg`, `vip_memory_pkg`,
  and its **own** `vip_mc_axi4_types_pkg`. It does **not** import
   `vip_axi4_agent_pkg` or `vip_axi4_types_pkg`, does **not** use
   `vip_axi4_cfg_sub`, and does **not** extend/wrap/override any `vip_axi4_*`
   component. Per-protocol width/cfg types and controller-side interfaces are
   defined locally (`vip_mc_axi4_cfg_t`, `vip_mc_axi4_types #(CFG_P)`,
   `vip_mc_axi4_if`). The price of this independence is a small, deliberate
   duplication of the AXI4 width-struct shape; accepted (new-decision 1).
   **CHI is the asymmetric case:** the CHI flit/opcode/width types are **reused**
   from `vip_chi_types_pkg` rather than re-owned — re-deriving a 684-line CHI type
   package is not "a small duplication." The core AXI4-only `vip_mc_pkg` carries no `vip_chi`
   import (only the thin local `vip_mc_chi_cfg_t` selector); `vip_chi_types_pkg`
   enters only with the CHI front-end/interface files (CHI decisions 2/7).
2. The downward contract is the neutral `vip_dram_req` / `vip_dram_rsp`
   TLM API — `vip_mc` never touches `vip_dram` bank or timing internals.
   The TB owns the `vip_dram` instance and passes the handle into
   `vip_mc` via the config DB (see §8.7).
3. The upward contract is **one host interface per port**: AXI4 ports use
   `vip_mc`'s own `vip_mc_axi4_if #(CFG_P)` (single fixed controller clocking
  block, no `ROLE_P` — so the B1 trap does not arise); CHI ports use a
  `vip_mc`-owned single-role `vip_mc_chi_if` (same source for D or E,
  selected by cfg; consumes `vip_chi_types_pkg` flit types). An AXI4 port may
   bridge a stock `vip_axi4_agent` manager via a per-port `vip_mc_axi4_connect`;
   a CHI port bridges a `vip_chi` RN-I manager via `vip_mc_chi_connect` (two
   instances, bridged — B1).
4. Storage lives in `vip_dram` (which owns its own `vip_mem`).
   `vip_mc` neither owns nor adopts a separate `vip_mem`. Backdoor
   pre-loading of the device is done via `vip_dram`'s backdoor accessor.
5. **The neutral TLM is the unification seam.** All protocol logic lives in
   the per-port front-ends; the back-end is homogeneous and parameterized
   only by `(DRAM_CFG_P, N_PORTS)`. Adding a protocol = adding a front-end
   type; it never touches the back-end, the cmd queue, refresh, or the device.

### 2.1 Multi-port configuration — how the top is configured

The top is pinned down by **three compile-time facts** plus a **runtime port
map**. Compile-time (parameters of `vip_mc`):

- `vip_dram_cfg_t DRAM_CFG_P` — the device the MC fronts (one shared device
  for now; multi-channel is §11). Sizes the neutral TLM. Must equal the
  `CFG_P` of the `vip_dram` instance the MC drives.
- `int N_PORTS` — number of host front-end ports.
- `vip_mc_port_cfg_t PORTS [N_PORTS]` — per-port descriptor (protocol + that
  protocol's width cfg):

```sv
typedef enum { VIP_MC_PROTO_AXI4_E, VIP_MC_PROTO_CHI_E } vip_mc_proto_e;

typedef struct packed {
  vip_mc_proto_e    proto;   // which front-end adapter sits on this port
  vip_mc_axi4_cfg_t axi4;    // meaningful iff proto == VIP_MC_PROTO_AXI4_E
  vip_mc_chi_cfg_t  chi;     // meaningful iff proto == VIP_MC_PROTO_CHI_E
} vip_mc_port_cfg_t;
```

The CHI cfg itself carries the **issue/version**; the port selector stays
generic (`AXI4` vs `CHI`):

```sv
typedef enum {
  VIP_MC_CHI_ISSUE_D_E,
  VIP_MC_CHI_ISSUE_E_E
} vip_mc_chi_issue_e;

typedef struct packed {
  vip_mc_chi_issue_e issue;
  int                NODE_ID_WIDTH_P;
  int                ADDR_WIDTH_P;
  int                DATA_BYTES_P;
  bit                DATACHECK_EN_P;
  bit                POISON_EN_P;
  bit                MPAM_EN_P;
  bit                PARITY_EN_P;
} vip_mc_chi_cfg_t;
```

This is a **thin local selector** — issue + the user-selected width/enable axes
only. It deliberately does **not** re-derive flit/opcode widths (that is what the
duplicated `vip_mc_chi_types` did); the CHI front-end maps it to `vip_chi_cfg_t`
and lets `vip_chi_types #(vip_chi_cfg_t)` in `vip_chi_types_pkg` derive every
width/opcode (CHI decision 2/7). Keeping the selector local is what lets the
AXI4-only core compile with no `vip_chi` import.

Using CHI-D vs CHI-E is therefore a **per-port cfg selection**, not a source
selection: the TB passes a `vip_mc_chi_cfg_t` with `issue =
VIP_MC_CHI_ISSUE_D_E` or `VIP_MC_CHI_ISSUE_E_E` into `PORTS[k].chi`, and the
same `vip_mc_chi_if` / `vip_mc_chi_driver` sources elaborate against that cfg
(reusing `vip_chi_types` for the derived widths).

> Note the protocol cfg is a **peer** of the others in `vip_mc_port_cfg_t`, and
> the device cfg (`DRAM_CFG_P`) is a separate top-level parameter — `vip_dram_cfg_t`
> is **not** nested inside `vip_mc_axi4_cfg_t` (that would force the AXI4
> interface/types package to depend on the device and carry an unused field).

Front-ends share a base so the back-end holds them uniformly; each is its own
parameterized type (distinct per protocol), parameterized by *its* width cfg
**and** `DRAM_CFG_P` (it builds `vip_dram_req #(DRAM_CFG_P)`):

```sv
virtual class vip_mc_fe_base #(vip_dram_cfg_t DRAM_CFG_P) extends uvm_component;
  int                                      port_id;
  // FE → back-end: the MC-internal request — a cmd_entry carrying the neutral
  // payload + axi4_id; the arbiter assigns tag/order and derives the
  // device-neutral vip_dram_req (§8.9). NOT the device-neutral req, which
  // cannot convey axi4_id / port_id.
  uvm_analysis_port #(vip_mc_cmd_entry_t)  req_port;
  // back-end → FE: the matched, completed cmd_entry (port_id/axi4_id recovered).
  pure virtual function void complete(vip_mc_cmd_entry_t entry);
endclass

class vip_mc_axi4_driver #(vip_mc_axi4_cfg_t AXI4_CFG_P, vip_dram_cfg_t DRAM_CFG_P)
  extends vip_mc_fe_base #(DRAM_CFG_P);  // the AXI4 front-end
class vip_mc_chi_driver  #(vip_mc_chi_cfg_t  CHI_CFG_P,  vip_dram_cfg_t DRAM_CFG_P)
  extends vip_mc_fe_base #(DRAM_CFG_P);  // the CHI front-end (D/E selected by cfg;
                                         // reuses vip_chi_driver_snf algorithms)
```

**SV constraint — heterogeneous ports are bound per port, not in a generic
loop.** A class parameterization (`vip_mc_axi4_driver #(PORTS[i].axi4, …)`)
requires its parameter to be an *elaboration-time constant*. `PORTS[i]` with a
**runtime** loop variable `i` is not constant, and `generate` does not apply to
the members of a UVM component (a class). So a fully-generic "loop over
`N_PORTS` arbitrary protocols" cannot be expressed. The honest pattern is
**explicit per-port binding using a constant (literal) index** into `PORTS`,
with a *constant-folded* `if`/`case` on `PORTS[k].proto` selecting the FE type
(both branches name legal types; only the selected one runs):

```sv
// vip_mc::build_phase — one block per port, literal index k (constant):
if (PORTS[0].proto == VIP_MC_PROTO_AXI4_E)
  fes[0] = vip_mc_axi4_driver #(PORTS[0].axi4, DRAM_CFG_P)::type_id::create("fe0", this);
else
  fes[0] = vip_mc_chi_driver   #(PORTS[0].chi,  DRAM_CFG_P)::type_id::create("fe0", this);
fes[0].port_id = 0;  backend.register_port(0, fes[0]);
// ... repeat for port 1, 2, … (unrolled, or generated by a small `define macro)
```

The back-end then holds the ports uniformly as `vip_mc_fe_base #(DRAM_CFG_P)
fes[N_PORTS]` (base handles), so **everything downstream of the FE is a plain
runtime loop** — arbitration, queueing, and response demux never depend on the
protocol. (A *homogeneous* config — all ports identical protocol+cfg — collapses
to a single FE type and a real `for` loop.) Each FE gets its own host vif from
`vip_mc`, sourced from the `vip_mc_env_cfg` aggregator the TB fills (§2.2) — or,
as a fallback, from the config DB under a per-port key (`"vif_port0"`, …); an
AXI4 port may use a per-port `vip_mc_axi4_connect` to a stock manager.

**Runtime port map** (`vip_mc_config.ports[N_PORTS]`): per-port
address-region ownership (which ranges the port may access — default = the
full device, i.e. peers), arbitration weight/priority, and the vif key. The
back-end arbitrates the `N_PORTS` MC-internal request streams into the QoS-class
cmd queue (highest effective class after aging, round-robin among ready ports
within a class with refresh strict priority, preserving each port's own emission
order — fully specified in §8.9), and routes each response back to the
originating FE by `cmd_entry.port_id`. `port_id` is back-end state stamped on
the cmd entry — it **never** enters the neutral `vip_dram_req`, so the device
stays port-agnostic.

### 2.2 System configuration — `vip_mc_env_cfg` (the one object the TB fills)

The §2.1 facts can be set piecemeal: a `vip_mc_config`, the `dram` handle,
an optional controller-global `status_vif`, and N per-port `vif` keys, each
`uvm_config_db::set` by hand. For a multi-port TB that is N+3 scattered,
string-keyed sets — easy to mistype a key, and the
topology ends up spread across three places. `vip_mc_env_cfg` collapses all of
it into **one object the TB parameterizes once, fills with handles, and hands to
`vip_mc`** — the commercial "system environment / environment configuration"
idiom: set the topology on a single config, give it over, and the consumer
builds the matching agents.

It is parameterized by the **same topology triple** as `vip_mc`, so their types
line up, and **owns** the shared `vip_mc_config` (whose `ports[]` already holds
the per-port runtime map — region ownership, arb weight — §2.1):

```sv
class vip_mc_env_cfg #(
  vip_dram_cfg_t    DRAM_CFG_P,
  int               N_PORTS,
  vip_mc_port_cfg_t PORTS [N_PORTS]
) extends uvm_object;

  vip_mc_config           cfg;                 // shared MC knobs + cfg.ports[] runtime map (owned, created in new)
  vip_dram #(DRAM_CFG_P)  dram;                // the device this MC fronts (TB-owned handle, §8.7)
  virtual vip_mc_status_if #(N_PORTS) status_vif; // optional controller-global debug probe (§8.8A)
  vip_mc_vif_holder       vif_h [N_PORTS];     // per-port host vif, type-erased (see below)

  function void register_vif(int port_id, vip_mc_vif_holder h);  // "connect your IF here"
  function void apply(uvm_component ctxt, string inst = "*vip_mc*"); // one config-DB set of `this`
  function void validate();                    // every port bound; cfg.ports[] regions ⊆ device; holder proto == PORTS[k].proto
endclass
```

**Why a holder for the vif, not a plain typed array.** A host vif is
`vip_mc_axi4_if #(PORTS[k].axi4)` — a *different* type per port when widths
differ — so heterogeneous ports cannot share one typed array, and SV has no
generic method that takes "any vif." The one type-erased store SV gives us is a
base-class handle, so each port's vif rides in a tiny typed holder the user
constructs (it names the concrete type, which it must anyway) and registers:

```sv
virtual class vip_mc_vif_holder extends uvm_object;                 // type-erased base
  vip_mc_proto_e proto;                                             // for validate()/$cast guard
endclass
class vip_mc_axi4_vif_holder #(vip_mc_axi4_cfg_t AXI4_CFG_P) extends vip_mc_vif_holder;
  virtual vip_mc_axi4_if #(AXI4_CFG_P) vif;                         // the concrete handle
endclass
class vip_mc_chi_vif_holder  #(vip_mc_chi_cfg_t  CHI_CFG_P)  extends vip_mc_vif_holder;
  virtual vip_mc_chi_if  #(CHI_CFG_P)  vif;                         // the CHI SN handle
endclass
```

By contrast, the optional status probe is one homogeneous
`virtual vip_mc_status_if #(N_PORTS)` handle, so it lives directly on
`vip_mc_env_cfg` with **no** holder class.

The TB connects interfaces by registering holders, then gives the whole thing to
`vip_mc` in **one** call — no per-port string keys:

```sv
vip_mc_env_cfg #(VIP_DRAM_CFG_C, 2, PORTS) env_cfg = new("env_cfg");
env_cfg.dram = dram_h;                                              // device (TB-owned)
env_cfg.status_vif = mc_status_vif;                                 // optional debug probe (§8.8A)
begin vip_mc_axi4_vif_holder #(PORTS[0].axi4) h = new; h.vif = mc_vif0; env_cfg.register_vif(0, h); end
begin vip_mc_axi4_vif_holder #(PORTS[1].axi4) h = new; h.vif = mc_vif1; env_cfg.register_vif(1, h); end
env_cfg.apply(null, "uvm_test_top.env.u_mc");                       // single handoff
```

`vip_mc::build_phase` then does **one** `config_db::get` of the `env_cfg` and
reads `cfg`, `dram`, the optional `status_vif`, and each port's vif (via a
constant-index `$cast` of `vif_h[k]`, §8.7) — replacing the N+3 discrete gets.

**The SV constraint still rules the topology.** `N_PORTS` and `PORTS[]` remain
**elaboration-time constants** (§2.1): `vip_mc_env_cfg` is *parameterized* by
them, not configured with them at runtime, because `vip_mc` must build the
parameterized FE types from the *same* constants. The env_cfg carries the
**runtime** half (vif handles, region map, knobs); the **compile-time** half
(how many ports, which protocol each) stays a shared parameter. The TB declares
the topology once (a `localparam PORTS[]`) and instantiates both
`vip_mc_env_cfg #(...)` and `vip_mc #(...)` with it. "How many interfaces per
protocol" *is* that parameter — encoded in `PORTS[]`; a
`vip_mc_ports(.n_axi4, .n_chi, …)` helper can build the table from per-protocol
counts for the homogeneous-ish common case.

`vip_mc_env_cfg` is **additive and optional**. `vip_mc` still accepts the
piecemeal `vip_mc_config` + `dram` + per-port `vif` keys directly (§8.7 falls
back to them when no `env_cfg` is found); `apply()` is just the convenience that
sets one object instead. It introduces **no** new dependency and does **not**
own the device timing model — it only carries the TB-owned `dram` handle (§2
rule 4). A wrapping `vip_mc_env` *component* (a `uvm_env` that instantiates
`vip_mc` + the example managers/connectors and holds a `vip_mc_env_cfg`) is the
natural next layer for TBs, but lives in the example tree, not the core VIP.

---

## 3. Directory layout

```text
vip_memory_controller/
├── IMPLEMENTATION_PLAN.md             (this file)
├── README.md
├── vip_mc.svh                         (compile header)
├── vip_mc_pkg.sv                      (single package)
│
├── vip_mc_axi4_types_pkg.sv          (OWN AXI4 width struct vip_mc_axi4_cfg_t +
│                                       vip_mc_axi4_types #(CFG_P) typedef container,
│                                       resp/burst/size constants — NO vip_axi4_* import)
├── vip_mc_axi4_if.sv                  (OWN controller-side interface, single clocking
│                                       block; global scope, not in the package)
├── vip_mc_status_if.sv                (OPTIONAL debug-only waveform-status probe
│                                       interface (§8.8A); global scope, not in the
│                                       package; depends only on `N_PORTS`)
├── vip_mc_types_pkg.sv                (enums, op tags, tag-prefix consts, region descriptors,
│                                       vip_mc_proto_e + vip_mc_port_cfg_t port descriptor §2.1)
├── vip_mc_port_runtime_cfg.sv         (runtime per-port access-region / arbitration state)
├── vip_mc_cmd_entry.sv                (internal cmd-queue item; carries port_id + completion fields)
├── vip_mc_config.sv                   (MC-specific knobs: outstanding limits,
│                                       refresh policy, addr-map policy, per-port map §2.1)
├── vip_mc_env_cfg.sv                   (system-config aggregator §2.2: owns vip_mc_config +
│                                       dram handle + optional status_vif + per-port vif holders;
│                                       register_vif/apply. Includes vip_mc_vif_holder base +
│                                       per-proto typed holders)
├── vip_mc_status_snapshot.sv          (OPTIONAL debug-only shared snapshot / mirror
│                                       state container for §8.8A probe fields)
├── vip_mc_axi4_cfg.sv                 (OWN AXI4-face knobs: outstanding limits,
│                                       DECERR region map, dram_handle_path;
│                                       NO vip_axi4_cfg_sub, NO fault injection)
│
│   # --- shared protocol-agnostic back-end (one, regardless of #ports) ---
├── vip_mc_fe_base.sv                  (abstract per-port front-end: MC-internal req_port,
│                                       port_id, complete(entry) — §2.1, §8.9)
├── vip_mc_activity_fifo.sv            (backend-owned ingress FIFO with explicit wake events)
├── vip_mc_cmd_queue.sv                (QoS priority-class queue + aging + flat-tag tracking + port_id demux)
├── vip_mc_refresh.sv                  (tREFI counter, REF emitter)
├── vip_mc_backend.sv                  (#(DRAM_CFG_P, N_PORTS): arbiter + cmd_queue +
│                                       refresh + addr_map; holds fes[N_PORTS])
│
│   # --- per-protocol front-ends (one type per protocol) ---
├── vip_mc_axi4_driver.sv              (AXI4 front-end: controller-side protocol;
│                                       extends vip_mc_fe_base)
│   # vip_mc_chi_if.sv               (OWN single-role controller-side CHI SN interface,
│                                     no ROLE_P — B1; consumes vip_chi_types_pkg flit types,
│                                     issue selected by `CFG_P.issue` = D or E)
│   # vip_mc_chi_driver.sv           (CHI SN front-end port; extends vip_mc_fe_base,
│                                     reuses vip_chi_driver_snf flit-handling algorithms)
│   # vip_mc_chi_connect.sv          (optional bridge vip_mc_chi_if <-> a vip_chi_if
│                                     RN-I manager for stimulus; not in the package)
│   # vip_mc_axi4_connect.sv         (optional bridge vip_mc_axi4_if <-> a stock
│                                     vip_axi4_if MANAGER; not in the package)
│   #   (NO vip_mc_chi_types_pkg — flit/opcode/width types reused from vip_chi_types_pkg;
│   #    the thin vip_mc_chi_cfg_t selector lives in vip_mc_types_pkg, §2.1)
│
├── vip_mc.sv                          (top: builds N_PORTS front-ends via PORTS[] +
│                                       the back-end; threads vif/dram handles;
│                                       owns optional status_vif publisher / mirror logic)
│
```

`vip_mc_axi4_if.sv` is a SystemVerilog **interface** compiled at global scope —
it is *not* `include`d into `vip_mc_pkg`. For *type* definitions the package
depends only on `vip_mc_axi4_types_pkg` (the width typedefs), so the core VIP
carries no AXI4-*VIP* coupling. It does, however, reference the
`vip_mc_axi4_if` **interface type** through the `virtual vip_mc_axi4_if` handles
its classes hold (`vip_mc_axi4_driver` §8.6, `vip_mc_axi4_vif_holder` §8.10), so
the interface must be **compiled before** `vip_mc_pkg` (§13.4 file order) — an
intra-VIP dependency, not a dependency on the stock AXI4 VIP. The optional
connector remains the lone bridge file and is compiled only
when the stock manager drives the TB. When the §8.8A status probe is enabled,
`vip_mc_status_if.sv` follows the **same** rule: global-scope interface,
analyzed before `vip_mc_pkg` because `vip_mc` / `vip_mc_env_cfg` hold
`virtual vip_mc_status_if #(N_PORTS)` handles.

Completions are written back into the cmd-entry in place (see §5.2),
so a separate `vip_mc_rsp.sv` is not needed; `vip_mc_cmd_entry.sv`
carries both the request fields and the completion timestamps.

Examples live under
[`testbench/sv/`](../testbench/sv/) — the full
manager → `vip_mc` → `vip_dram` end-to-end TB belongs here, not under
`examples/vip_dram/`.

---

## 4. AXI4 face

`vip_mc` implements the AXI4 controller-side (subordinate-responder) protocol
directly inside `vip_mc_axi4_driver`, against its **own** `vip_mc_axi4_if`. No
`vip_axi4_*` component is reused, extended, wrapped, or overridden. By owning
the protocol explicitly, `vip_mc` ties response timing to MC scheduling
decisions (`vip_dram_rsp.first_beat_ready_time` / `last_beat_ready_time`) with
no stray jitter or storage plumbing from any stock SUB driver.

### 4.1 Interface ownership

`vip_mc_axi4_if` is a self-contained AXI4 interface defined in this VIP
(`vip_mc_axi4_if.sv`), parameterized by `vip_mc`'s own width struct
`vip_mc_axi4_cfg_t CFG_P` (§8.2). It has a single fixed clocking block for the
controller role — it **drives** `awready`/`wready`/`bid`/`bresp`/`bvalid`/
`arready`/`rid`/`rdata`/`rresp`/`rlast`/`rvalid` and **samples** the AW/W/AR
payloads plus `bready`/`rready` — and a passive monitor clocking block. There
is no `ROLE_P` parameter and no role-gated generate block, so it sidesteps the
B1 failure mode entirely (a single interface type, one clocking block).

Each AXI4 **front-end** (one per AXI4 port, §2.1) fetches *its own* handle from
the config DB under a per-port key (`"vif_port0"`, `"vif_port1"`, …):

```sv
virtual vip_mc_axi4_if #(CFG_P) vif;   // CFG_P = PORTS[k].axi4 for this port
uvm_config_db #(virtual vip_mc_axi4_if #(CFG_P))
  ::get(this, "", $sformatf("vif_port%0d", port_id), vif);
```

(In the single-AXI4-port case, `port_id == 0`; the key is still `"vif_port0"`.)
When the stock manager supplies stimulus for a port, it drives a **separate**
`vip_axi4_if #(.., MANAGER)` instance; a per-port `vip_mc_axi4_connect`
cross-wires the two with explicit `assign`s (§13.1). Two instances, bridged —
never one shared, role-gated interface (B1).

Typedef aliases inside `vip_mc_axi4_driver` come from `vip_mc`'s **own**
`vip_mc_axi4_types #(CFG_P)` typedef-container (defined in
`vip_mc_axi4_types_pkg`, **not** `vip_axi4_types_pkg`):

```sv
typedef vip_mc_axi4_types #(CFG_P)::addr_t  addr_t;
typedef vip_mc_axi4_types #(CFG_P)::rdata_t rdata_t;
typedef vip_mc_axi4_types #(CFG_P)::wdata_t wdata_t;
typedef vip_mc_axi4_types #(CFG_P)::wstrb_t wstrb_t;
typedef vip_mc_axi4_types #(CFG_P)::awid_t  awid_t;
typedef vip_mc_axi4_types #(CFG_P)::arid_t  arid_t;
```

`vip_mc_axi4_cfg_t` carries the AXI4 width fields verbatim
(`AWID_WIDTH_P`, `ARID_WIDTH_P`, `ADDR_WIDTH_P`, `WDATA_BYTES_P`,
`RDATA_BYTES_P`, and the USER widths) so the connector's `assign`s are a clean
1:1 against the stock `vip_axi4_if`; the two width structs must describe
identical physical widths (the TB sets both from one source).

### 4.2 Controller-side channel implementation

`vip_mc_axi4_driver` forks one task per channel in its
`driver_start()`. All knobs are `vip_mc`'s own (`cfg` is the
`vip_mc_axi4_cfg`, §8.2) — there is no `cfg.sub` indirection:

| Task                    | Channel | Behavior                                                                                  |
|-------------------------|---------|-------------------------------------------------------------------------------------------|
| `drive_awready`         | AW      | Holds `awready` while `aw_outstanding < cfg.aw_outstanding_limit` (0 ⇒ unbounded) **and** the per-port AW-pending FIFO has room (§4.5). On handshake, builds an AW-pending cmd_entry — capturing `AWQOS` (→ priority class, §5), `AWLOCK` (exclusive, §4.6), and `AWUSER`; the backend arbiter assigns its tag and class order later (§8.9). |
| `drive_wready`          | W       | Asserts `wready` while a write is pending **and** the bounded W-data buffer has room — it **deasserts when the buffer fills** (real W-side backpressure, §4.5), so `wready` actually toggles. Beats accumulate into the matching cmd entry — the oldest accepted AW not yet `WLAST`-ed, head of the per-port AW-pending FIFO (§4.5). On `wlast`, packs the AXI4 beats into channel-row words (narrow/unaligned lane muxing, §5.6) and emits the WR cmd_entry to `req_port` (the arbiter derives the device-neutral `vip_dram_req(VIP_DRAM_OP_WR_E)`, §8.9). |
| `drive_bvalid`          | B       | Drives B at `rsp.last_beat_ready_time` as the backend delivers each completion **from the finite response buffer** via `complete(entry)` (§8.9) — the FE never reads `dram.rsp_port`. Same-AWID order preserved (mandatory FIFO); inter-ID B order follows device completion timing — no reorder knob (§5.2). `bresp = EXOKAY` for a successful exclusive write, `DECERR` for a decode/4 KB reject, else `OKAY` (a *failed* exclusive write returns `OKAY`, §4.6); no probabilistic error injection. |
| `drive_arready`         | AR      | Holds `arready` while `ar_outstanding < cfg.ar_outstanding_limit`, capturing `ARQOS`/`ARLOCK`/`ARUSER`. Performs the 4 KB boundary check on AW/AR (§4.4) — violations enqueue a DECERR-only completion that never reaches `vip_dram`. |
| `drive_rvalid`          | R       | Drives R beats at `rsp.first_beat_ready_time` with per-beat pacing (§5.4) as the backend delivers each completion **from the finite response buffer** via `complete(entry)` (§8.9). Same-ARID order preserved (mandatory FIFO); inter-ID R order follows device completion timing — no reorder knob (§5.2). **No read-data interleaving** — AXI4 dropped the AXI3 feature, so one burst is fully driven before the next (§4.6). `rresp = EXOKAY` for a successful exclusive read, `DECERR` for a decode/4 KB reject, else `OKAY`. |

These tasks are members of `vip_mc_axi4_driver`; they do **not** touch
`cmd_queue` (the backend owns it). Requests reach the device through the backend
arbiter — `req_port.write(entry)` → `backend.fe_req_export[port_id]` → arbiter
(assigns tag/order, enqueues `cmd_queue`, derives the neutral req, §8.9) →
`backend.req_port` → `dram.req_fifo.analysis_export` — and completions arrive
via `backend.rsp_subscriber` which calls `fes[cmd_entry.port_id].complete(entry)`.
There is no stock SUB driver in the picture at all. (Read data is **not**
interleaved across IDs — AXI4 dropped the AXI3 feature — so a burst's beats are
driven contiguously; see §4.6.)

### 4.3 Native AXI4-face config — specified from what an MC needs

`vip_mc_axi4_cfg` (§8.2) is built **bottom-up from controller requirements**,
not by subtracting fields from `vip_axi4_cfg_sub`. Asking "what does a real
DDR controller's AXI4 face actually need?" yields a short list:

- **Request-acceptance budgets** — how many reads / writes can be outstanding
  before the MC backpressures its address channels. A real MC has finite
  command-queue depth. → `aw_outstanding_limit` / `ar_outstanding_limit`
  (`int`, `0` = unbounded; driven from `vip_mc_config.max_outstanding_wr` /
  `_rd` in `build_phase`).
- **Address decode** — which address regions are unmapped / illegal and must
  answer `DECERR`. Every real MC has a decode map. → `decerr_addr_lo[$]` /
  `decerr_addr_hi[$]` with `add_decerr_range(lo,hi)`, `clear_decerr_ranges()`,
  `is_decerr_addr(addr)`. (AXI4 4 KB-boundary `DECERR` is handled in the
  driver, §4.4 — not a config field.)
- **Device handle** — `dram_handle_path`, the UVM path the driver uses to fetch
  the `vip_dram` instance from the config DB.
- **Perf-counter gates** — diagnostic enables for the §8.8 counters.
- **Scheduling policy** — a real MC prioritises by `AxQOS`. → a QoS priority-class
  count and the `AWQOS`/`ARQOS`→class mapping plus an aging threshold
  (`qos_class_count`, `qos_aging_ns`; §5, §8.2).
- **Buffer depths** — finite buffers are what produce realistic backpressure. → a
  bounded W-data buffer (`w_data_buf_depth` + `aw_pending_depth`, drive `WREADY`
  toggling, §4.5). The response buffer is a backend/controller-wide credit that
  lives on `vip_mc_config.rsp_buf_depth` (**not** this AXI4-face cfg — §8.1/§8.9),
  credit-gating request issue. `0` on any depth = unbounded (legacy behavior).
- **Exclusive access** — `exclusive_enabled` plus the monitor state for `AxLOCK`
  reservations (`EXOKAY`/`OKAY`, §4.6); a `vip_mc`-local monitor mirroring
  `vip_axi4_excl_monitor`'s algorithm (re-implemented, not instantiated — §2 rule 1).
That is the whole field set. Notably **absent** by design:

- *No fault-injection* (no probabilistic SLVERR, no RDATA corruption). A real
  MC does not roll a die to fail a well-formed, in-range access. The current
  slice can still return deterministic `SLVERR` for malformed or unsupported
  protocol shapes that are rejected inside the AXI4 front-end (for example an
  unsupported burst form or W/`WLAST` mismatch), while ECC-uncorrectable
  device-side `SLVERR` remains future work (§11.3). Data-integrity faults
  are *physical* and belong to the device / channel, not the controller's
  config (§11). Removing fault injection also closes a scoreboard footgun:
  §13.2 checks data against `dram.backdoor_read` and timing against
  `dram.predict()`, neither of which would know about an injected corruption.
- *No inter-ID reorder **logic*** — completion order stays **emergent** from
  device timing; the MC enforces only the mandatory same-ID order (§5.2) and
  never actively shuffles inter-ID order. (Distinct from the finite response
  **buffer** in v1, §8.9: that bounds how many completed-but-undriven responses
  are held and backpressures the request path — it does not reorder.)
- *No device `mem_cfg`* — storage X-handling lives on `vip_dram_config.mem_cfg`,
  owned and set by the TB on the `vip_dram` instance (vip_dram §7.1). `vip_mc`
  never reads or forwards any `mem_cfg`.

> For the record (the review asked whether `vip_axi4_cfg_sub`'s fields match a
> real MC): **none are inherited** — every knob above is native. Where a stock
> SUB field names a *real* MC concept (outstanding depth, QoS,
> exclusive, USER), `vip_mc` models the **controller behavior** natively and
> deterministically — QoS *scheduling*, `EXOKAY` from an exclusive *monitor*,
> USER *passthrough* — **not** the stock VIP's random-stimulus versions (random
> QoS pick, random reorder window, response-delay jitter). The purely generative scaffolding
> (random SLVERR / RDATA-corrupt, `b_bresp_enabled`, device `mem_cfg`) has no MC
> analogue and stays out (absent list above).

### 4.4 AXI4 4 KB boundary

`vip_mc` does **not** split bursts. The manager is required by AXI4
to respect the 4 KB boundary; if a burst crosses it, `vip_mc` returns
`DECERR` on all beats of the offending burst and counts the
violation in `get_4k_violation_count()` (§8.8). The check fires in
`drive_arready` / `drive_awready` after the address handshake; the FE emits the
DECERR completion to `req_port` with `pre_resolved = TRUE`, so the arbiter
enqueues and orders it like any entry (§8.9) but **skips** the device
write — it never reaches `vip_dram`. The TB test in §13
verifies the DECERR response, not split behavior.

### 4.5 Write-data acceptance

The AW handshake completes whenever `aw_outstanding < cfg.aw_outstanding_limit`
(`0` ⇒ unbounded) **and** the per-port AW-pending FIFO has a free slot
(`cfg.aw_pending_depth`). Write data is accepted into a **bounded W-data buffer**
(`cfg.w_data_buf_depth`): `wready` is asserted while that buffer has room and
**deasserts when it fills**, so W-side flow control is real — `wready` toggles
rather than staying tied high. The buffer drains as `WLAST` lands and the entry
is emitted to the backend (subject to the backend's issue credits, §8.9). `0` on
either depth = unbounded (the legacy "wready always high" behavior, useful for
A/B-ing against the finite model). Partial-write rollback on mid-burst reset is
handled by §9 (the half-built entry is discarded; no `vip_dram_req` is emitted).

**Write-data matching rule (AXI4 has no `WID`).** Write data arrives strictly in
**AW-acceptance order**, so each W burst associates with **the oldest accepted AW
that has not yet seen `WLAST`**. `drive_awready` pushes each accepted AW's
half-built cmd entry onto a per-port FIFO of AW-pending entries; `drive_wready`
accumulates beats into the entry at the **head** of that FIFO and pops it on
`WLAST`. "The matching cmd entry" in §4.2 means exactly that head-of-FIFO entry —
there is no address- or ID-based matching, because AXI4 write data is unlabeled.

### 4.6 AXI4 feature support

`vip_mc` models the full AXI4 transaction feature set. The MC-specific algorithms
(burst-address iteration, narrow-lane muxing, the exclusive monitor) are lifted
from `vip_axi4_agent` — re-implemented under `vip_mc`'s own names as
**algorithms**, never by importing or instantiating any `vip_axi4_*` class
(§2 rule 1) and never via its `vip_axi4_cfg_sub` (§4.3, the native-config rule).

- **Burst type — `INCR`, `WRAP`, `FIXED`.** All three map to device column
  accesses (§5.6). `INCR` advances linearly; `WRAP` advances modulo the burst's
  wrap boundary (the same wrap math `vip_axi4_addr_iterator` uses, re-implemented
  locally); `FIXED` repeats the same
  address every beat (peripheral/FIFO semantics) → repeated accesses to the same
  column. The per-beat address is produced by the iterator, then decoded (§7) to
  the column sequence.
- **Narrow transfers (`AxSIZE` < full width).** Each beat moves fewer bytes on
  the lanes the address selects; `drive_wready` muxes those lanes into the
  channel-row word and folds the matching `wstrb`, and `drive_rvalid` slices the
  device row back onto the right read lanes (§5.6).
- **Unaligned addresses.** The first (and possibly last) beat is partial; the
  byte offset masks `wstrb` on writes and selects the read sub-range. Column
  mapping uses the aligned base; lane selection uses the offset (§5.6).
- **Exclusive access (`AxLOCK`).** `cfg.exclusive_enabled` arms an exclusive
  monitor (a `vip_mc`-local monitor mirroring `vip_axi4_excl_monitor`'s
  algorithm — re-implemented, not instantiated, §2 rule 1): an exclusive read registers a
  reservation per `(ARID, address, size)`; a later exclusive write to a still-valid
  reservation succeeds with `EXOKAY`, otherwise it completes with `OKAY` and
  **does not** modify memory (AXI4 fail semantics). Any intervening normal write
  to the monitored region clears the reservation. The monitor lives in the
  front-end (§8.6); the device sees only ordinary RD/WR.
- **No read-data interleaving (AXI4).** AXI4 removed the AXI3 read-data
  interleaving feature, so the R driver keeps at most **one** read burst active at
  a time and drives all of its beats contiguously. Multiple `ARID`s can be
  outstanding and their *whole bursts* complete in device-timing order (a later
  burst may return before an earlier one), but beats of different bursts are never
  interspersed on R. Same-ID order is always preserved.
- **USER channels.** `AWUSER`/`WUSER`/`ARUSER` are carried into the cmd_entry and
  `BUSER`/`RUSER` are driven back (passthrough — the device is USER-agnostic). The
  connector wires them rather than tying them off.
- **`AxQOS`.** Captured at AW/AR accept; the front-end maps it to a priority
  class via `cfg.qos_to_class(axqos)` (§8.2) and stamps `entry.qos_class` before
  emitting, so the protocol-agnostic backend schedules on a ready-made class
  (§5, §8.9) — `AxQOS` is not ignored.
- **Partial strobes.** Supported within a column access (passed through to
  `wstrb`, §5.6); strobes that straddle a column boundary follow the §5.6 packing
  rule.

**Burst boundaries still rejected** (manager protocol errors, not features):

- **4 KB-boundary crossing** → `DECERR` on all beats (§4.4); `vip_mc` does not
  split bursts.
- **DRAM row-span crossing** (only reachable via a non-default `addr_map_policy`,
  §5.6) → `uvm_error` + `DECERR`; per-row sub-request splitting is §11.

`vip_mc_config.validate()` (or the driver) raises `uvm_error` on a genuine
protocol violation (the two above) and `uvm_warning` when a feature is exercised
while disabled by config (e.g. an exclusive access with `exclusive_enabled == 0`)
rather than silently mis-modeling it.

---

## 5. Internal command queue

The command queue holds both reads and writes, scheduled by **QoS priority
class with aging** (§8.9), not pure arrival order. Requests are grouped into
`cfg.qos_class_count` priority classes by their `AxQOS` (§4.6); the arbiter
serves the highest non-empty class, **FCFS within a class** (the arbiter's
monotonic counter, §8.9). **Aging** promotes a request that has waited longer
than `cfg.qos_aging_ns` up one class per threshold, so low priority never
starves. The **same-ID order guarantee is absolute and overrides QoS**: a
younger same-ID request is never issued ahead of an older one even if its class
is higher (§5.2). REF is a strict-priority insertion that never enters this
queue (§5.5 item 4, §8.9). With `qos_class_count == 1` the model degenerates to
the original single-class FCFS (the legacy default for A/B comparison). One
shared queue is retained (not split RD/WR). By default the within-class
ordering remains FCFS; when `cfg.fr_fcfs_enable == TRUE`, the backend upgrades
that tie-break to FR-FCFS and issues the eligible candidate with the lowest
predicted `last_beat_ready_time` first.

**Behavioral boundary:** the miss-queue behavior exists only **before**
`req_port.write()`. Once an entry is issued, `vip_dram.schedule()` commits its
command/data timing into live scheduler state, and later requests predict
against that mutated state. With `enable_bus_contention = TRUE` (the default)
the later request's `first/last_beat_ready_time` are also gated by
`last_burst_end_chan`. So a later page hit can overtake an earlier miss only if
the backend chooses the hit first while both requests are still queued.

### 5.1 Entry shape

```sv
typedef struct {
  longint unsigned                 tag;       // {REF_FLAG, flat counter} — opaque handle, see below
  int                              port_id;    // originating front-end port (§2.1); back-end routes the
                                               //   response to fes[port_id].complete() — never in the neutral req
  longint unsigned                 axi4_id;    // the AWID (WR) / ARID (RD) — a plain field, NOT in the tag
  vip_dram_op_t                    op;         // RD | WR
  longint unsigned                 addr;       // system byte-address
  int unsigned                     beats;      // # DRAM column accesses (§5.6 mapping), NOT awlen+1
  bit                              has_explicit_rank; // REF (and explicit-rank tests) set this; RD/WR leave 0
  int unsigned                     rank;       // target rank when has_explicit_rank — always set for REF (§6.1)
  int unsigned                     qos;        // AxQOS 0..15 captured at AW/AR accept (§4.6)
  int unsigned                     qos_class;  // priority class the FE derives via cfg.qos_to_class (§8.2) before emitting; aging may raise the effective class (§8.9)
  realtime                         admit_time; // stamped when admitted to the class queue — the aging clock (§8.9)
  bit                              is_exclusive; // AxLOCK; the excl monitor (§8.6) decides EXOKAY vs OKAY
  longint unsigned                 auser;      // AWUSER/ARUSER passthrough; echoed on BUSER/RUSER (§4.6)
  longint unsigned                 wuser;      // WUSER passthrough (WR)
  // Data is held in neutral DRAM channel-row width (one element per column
  // access) — the same `vip_dram_types #(DRAM_CFG_P)::data_t` / `::strb_t`
  // widths the neutral TLM uses (vip_dram §4). The entry type is emitted from
  // the DRAM_CFG_P-parameterized cmd_queue/driver/refresh, so these item
  // widths track the device. The driver packs AXI4 W-beats into rows on wlast
  // and unpacks rows back to R-beats (§5.6); this is what replaced the
  // never-defined MAX_DATA_BITS / MAX_STRB_BITS (B3).
  vip_dram_types #(DRAM_CFG_P)::data_t wdata [];   // WR only
  vip_dram_types #(DRAM_CFG_P)::strb_t wstrb [];   // WR only
  realtime                         enqueue_time; // $realtime annotation only — NOT the ordering key (that is the _tag_ctr / grant order, §8.9)

  // --- Completion path -------------------------------------------------
  // An entry completes one of two ways:
  //   * pre_resolved == 0 : normal DRAM round-trip. A vip_dram_req is
  //     emitted; the timing/data fields below are filled when the
  //     matching vip_dram_rsp arrives.
  //   * pre_resolved == 1 : the entry is resolved inside vip_mc without
  //     ever touching vip_dram (4 KB-boundary DECERR §4.4, range DECERR,
  //     or other MC-side rejects). No vip_dram_req is emitted. `resp`,
  //     the synthetic `rdata[]`, and the ready times are filled at
  //     enqueue time so the AXI4 driver can drive B/R exactly as it
  //     would for a device-backed completion.
  bit                              pre_resolved;
  logic [1:0]                      resp;       // OKAY / DECERR / EXOKAY (per-burst, §4.6)
  vip_dram_types #(DRAM_CFG_P)::data_t rdata [];   // RD only; device data
  // back-pointer fields filled when vip_dram_rsp arrives (or stamped
  // immediately for pre_resolved entries):
  realtime                         first_beat_ready_time; // realtime ns, copied verbatim from vip_dram_rsp — never integer `time` (§5.4)
  realtime                         last_beat_ready_time;  // realtime ns, copied verbatim from vip_dram_rsp
  bit                              completed;
} vip_mc_cmd_entry_t;
```

The `resp` field carries the burst-level AXI4 response — `OKAY` for a normal
device-backed completion, `EXOKAY` for a successful exclusive access (§4.6),
`DECERR` for a decode/4 KB reject (§4.4), and deterministic `SLVERR` for
malformed or unsupported protocol shapes rejected inside the AXI4 front-end.
There is still no probabilistic `SLVERR` / corruption path in the first cut
(§4.3). For a `pre_resolved`
DECERR the driver drives the configured number of beats with `resp == DECERR`
and a zero-filled `rdata[]` at `first_beat_ready_time`/`last_beat_ready_time`
chosen by the MC (a fixed small reject latency, not a device prediction).

**Tag layout — a flat opaque handle.** `tag` is a single **flat monotonic
64-bit counter**, with bit 63 reserved as the REF discriminant:

```text
bit [63]      REF discriminant: 1 = refresh tag, 0 = AXI4-transaction tag.
bits[62 : 0]  monotonic transaction counter (one global sequence, all IDs).
```

The AXI4 ID is **not** encoded in the tag — it is the separate `axi4_id`
field in the cmd entry. The MC has a real per-request completion model, so it
demuxes a `vip_dram_rsp` purely by its (unique) flat counter and recovers the
AWID/ARID from the matched cmd entry; it never reconstructs ID structure from
the tag. This deliberately avoids the AXI4-agent's per-ID-counter idiom
(which exists only because that VIP tracks outstanding work by ID with no
latency model): there is no ID-width-coupled budget, no
`max(AWID,ARID)`-based `uvm_fatal`, and no wrap-collision check — a flat 63-bit
counter cannot realistically wrap within a simulation. `vip_dram` treats the
tag as fully opaque ("caller's private tag — echoes it on the response",
vip_dram §4), so a REF tag (bit 63 = 1) never collides with an AXI4 tag
(bit 63 = 0). This also makes the earlier B2 concern moot: the tag does not
depend on any ID-width parameter at all, so the non-existent
`VIP_AXI4_ID_WIDTH_P` never enters the picture.

### 5.2 Lifecycle

```text
AW + W-last accepted (vip_mc_axi4_driver, port k)
    │
    ▼
FE packs W beats → channel rows (§5.6); builds an MC-internal cmd_entry
  (op=WR, axi4_id=awid, port_id=k; tag/enqueue_time left for the arbiter)
    │  req_port.write(entry)   → backend.fe_req_export[k]
    ▼
backend arbiter (§8.9): pick by QoS class + aging; assign flat tag (bit63=0),
  stamp enqueue_time, enqueue into cmd_queue ──► issue order = tag-counter order
                                                 (QoS class across, FCFS within)
    │  derive neutral vip_dram_req; backend.req_port.write(...)
    ▼     → dram.req_fifo.analysis_export   (the single device writer)
device schedules; vip_dram_rsp arrives on dram.rsp_port
    │
    ▼
backend.rsp_subscriber: tag → cmd_entry (recovers port_id, axi4_id),
  then fes[port_id].complete(entry)
    │
    ▼
FE drives bvalid at rsp.last_beat_ready_time (matched by axi4_id / per-ID FIFO)
    │
    ▼
backend retires the cmd_entry (removed from _inflight by tag)
```

Reads follow the same path with `op=RD`; the rsp carries `rdata[]`
which the driver unpacks (§5.6) onto R-beats starting at
`rsp.first_beat_ready_time` and finishing at
`rsp.last_beat_ready_time`.

The scheduler sets the dispatch order of `vip_dram_req` emissions from the queue
(QoS class + aging, FCFS within a class, §8.9). AXI4-channel response ordering is
a separate, post-completion concern handled by `vip_mc_axi4_driver`: same-ID
transactions complete on the AXI4 bus in the order they were accepted (preserved
by per-ID linked-lists in the driver); different-ID transactions complete in the
order their `vip_dram_rsp`s become ready — i.e. **device-timing-driven**, an
emergent consequence of dispatch order + per-request latency, needing no reorder
*logic*. (A page-hit behind an earlier page-miss simply finishes first.) That
emergent reorder is **bounded by the finite response buffer** (`rsp_buf_depth`,
§8.9): completions are held in finite credits that backpressure the request path
when the master stalls B/R — the MC never actively shuffles order.
§10 test #3 exercises this emergent inter-ID shuffle; §10 test #4 exercises
the same-ID order guarantee.

`vip_mc` does NOT enforce `tWTR` / `tRTW` / `tCCD` or any other
DRAM-protocol pacing; all such timing lives in `vip_dram` (§1 Out of
scope). The MC dispatches in QoS-class order (FCFS within a class, §8.9) and lets
`vip_dram` queue and serialize. Promotion to FR-FCFS — the within-class
readiness-ordered tie-break (§11) — is the future hook for MC-side turnaround
optimization.

### 5.3 Outstanding-limit knob

**Config nesting & naming convention (M4).** `vip_mc_config` **owns** a
`vip_mc_axi4_cfg axi4` child (§8.1, §8.2). There is exactly one access path,
disambiguated only by scope:

- at `vip_mc` / `vip_mc_config` / test scope: `cfg.axi4.<field>` (here `cfg`
  is the `vip_mc_config`);
- inside `vip_mc_axi4_driver`: `cfg.<field>` (here `cfg` is the
  `vip_mc_axi4_cfg` handle the driver was given directly).

The old `cfg.sub.*` / `cfg.axi4.sub.*` split is gone — there is no `.sub`
indirection because there is no `vip_axi4_cfg_sub`.

`vip_mc_config.max_outstanding_rd` / `max_outstanding_wr` are copied in
`build_phase` into `cfg.axi4.ar_outstanding_limit` /
`cfg.axi4.aw_outstanding_limit`. The driver tasks (§4.2) read those as
`cfg.ar_outstanding_limit` / `cfg.aw_outstanding_limit`: `drive_arready`
deasserts when `ar_outstanding` hits the AR limit, `drive_awready` when
`aw_outstanding` hits the AW limit. `0` on either means unbounded.

### 5.4 Beat-timing derivation

Response times on `vip_dram_rsp` are absolute **`realtime` ns** (vip_dram's
`first/last_beat_ready_time`, §4 — sub-ns exact, never integer `time`); the AXI4
bus is clocked, so they are re-timed onto bus edges below and carried in
`realtime` end-to-end (the cmd-entry mirrors them as `realtime`, §5.1) — they are
**never** truncated into integer sim-time units. `n_rbeats = arlen + 1` is the number of **AXI4 R beats** to drive
(distinct from `vip_dram_rsp`'s column-access count — the driver unpacks each
channel-row word into `row_bytes / axi4_beat_bytes` R beats, §5.6). Pacing
rules:

- **B** — driven on the first rising bus edge at-or-after
  `rsp.last_beat_ready_time`, gated by BREADY.
- **R beat[0]** — driven on the first rising bus edge at-or-after
  `rsp.first_beat_ready_time`.
- **R beat[i>0]** — **guard `n_rbeats == 1` first (M10):** for a single-beat
  read (`ARLEN = 0`, e.g. a register read) there is no spacing — drive the one
  beat at `rsp.first_beat_ready_time` and skip the division. Only when
  `n_rbeats > 1` are subsequent beats spaced
  `(last_beat_ready_time - first_beat_ready_time) / (n_rbeats - 1)` as a
  `realtime` value, then snapped to the next rising bus edge by `drive_r_beat`
  (the next-edge rule below) — the spacing is computed in `realtime`, not rounded
  into integer sim-time:

  ```sv
  if (n_rbeats == 1) begin
    drive_r_beat(0, rsp.first_beat_ready_time);   // no /(n-1) division
  end else begin
    automatic realtime step = (rsp.last_beat_ready_time - rsp.first_beat_ready_time)
                              / (n_rbeats - 1);
    for (int i = 0; i < n_rbeats; i++)
      drive_r_beat(i, rsp.first_beat_ready_time + i*step);
  end
  ```

  > **Approximation (first cut).** This spreads the device's column-access ready
  > span evenly across *all* `n_rbeats` AXI4 beats. The exact model would drive
  > the beats *within* one column access back-to-back at the bus rate and place
  > the inter-column gap (`tCCD_x`) only at column boundaries. The even spread
  > keeps the first and last beats exact (the two contract times) and is within
  > the "realistic-enough, not cycle-exact" goal; per-column-boundary pacing is §11.

- **Late response** — if a target time has already elapsed when the
  driver wakes, fire on the next available bus edge and bump
  `get_rsp_late_count()` (§8.8).

REF responses bypass this pipeline entirely (see §5.5 and §6.1).

### 5.5 Saturation behavior

1. **Reads** — AR stalls when `ar_outstanding == cfg.ar_outstanding_limit`
   (i.e. the cmd queue holds `max_outstanding_rd` RD entries).
2. **Writes** — AW stalls when `aw_outstanding == cfg.aw_outstanding_limit`
   **or** the AW-pending FIFO is full (`cfg.aw_pending_depth`); `wready`
   deasserts when the bounded W-data buffer fills (`cfg.w_data_buf_depth`), so W
   beats are paced by real W-side backpressure, not just AW backpressure (§4.5).
   `0` on either depth restores the legacy "wready always high" model.
3. **Tag counter** — a single flat 63-bit monotonic counter (`_tag_ctr`,
   §5.1), incremented per accepted request across all IDs. No per-ID
   bookkeeping and no wrap-collision check: 63 bits cannot realistically wrap
   within a simulation.
4. **REF tag filtering** — REF completions reach the backend's `rsp_subscriber`
   (the single subscriber on `dram.rsp_port`, §8.7/§8.9); it checks the bit-63
   REF flag (equivalently `rsp.op == VIP_DRAM_OP_REF_E`) and short-circuits
   before calling `cmd_queue.on_dram_rsp(...)` or any front-end `complete()`, so
   the cmd queue never sees REF tags.

### 5.6 Transaction semantics — AXI4 ↔ DRAM mapping (the contract)

This is the MC side of the contract pinned down in **vip_dram §4.6** (M7 /
"transaction-semantics" feedback). Both VIPs state it identically:

- **One AXI4 burst → one `vip_dram_req`.** `vip_mc` does **not** split a burst
  into multiple device requests; a burst that would cross a row span is guarded,
  not split (§4.6). True splitting is §11.
- **`vip_dram_req.beats` = DRAM column accesses, not AXI4 beats.** The per-beat
  byte-addresses come from the burst-address iterator (`INCR` linear, `WRAP`
  modulo the wrap boundary, `FIXED` constant; §4.6), each decoded (§7) to a
  `{rank,bg,bank,row,col}`. `beats` is the count of **distinct column accesses**
  that sequence touches: for `INCR`, `ceil(burst_total_bytes / ROW_BYTES_P)`
  (`burst_total_bytes = (awlen+1) * 2^awsize`); for `WRAP`, the same count over
  the wrapped sequence; for `FIXED`, `1` (every beat hits the same column —
  modeled as one column access carrying `awlen+1` bus beats). With the default
  64-bit channel, a 64 B row, and full-width `INCR` beats, 8 AXI4 beats map to one
  column access.
- **Write packing (incl. narrow / unaligned).** As W beats arrive, `drive_wready`
  places each beat's active bytes on the lanes its address selects —
  `WDATA_BYTES_P`-wide for a full beat, a sub-lane slice for a narrow (`AxSIZE <
  full`) or unaligned beat — into the current channel-row word, folding `wstrb`
  (and the unaligned byte mask) into the row strobe. On `wlast` the entry's
  `wdata[]`/`wstrb[]` are the per-column-access rows handed to `vip_dram`; bytes
  with no strobe are not written (the device honors `wstrb`).
- **Read unpacking (incl. narrow / unaligned).** Each returned channel-row
  `rdata[]` element is sliced back into AXI4 R beats — `row_bytes /
  axi4_beat_bytes` full beats, or the address-selected sub-lanes for a narrow /
  unaligned read (§5.4, §4.6). `FIXED`/`WRAP` reads slice from the same / wrapped
  column row(s) per the iterator's address sequence.
- **Column progression.** Successive column accesses of one request advance the
  column index on a **single open row** — `vip_dram` models a multi-beat request
  as same-row page hits at `tCCD_x` and does **not** re-decode per beat (vip_dram
  README: "keep beats within a row — the MC's job"). So one-burst→one-`vip_dram_req`
  is only valid when the burst's beats stay within one row.

  **This holds by construction for the default map.** With the LSB-first default
  (`[byte][col][bank][bg][row][rank]`, §7.1) the column field spans
  `COLS × ROW_BYTES` contiguous bytes (64 KB at the default geometry), and AXI4
  already forbids a burst from crossing a 4 KB boundary (§4.4) — so a legal burst
  can never roll past the column field into bank/bg/row. A real row crossing can
  only arise if a test **overrides `addr_map_policy`** to place row bits low (or
  shrinks `COL_BITS_P`).

  **Row-crossing guard (first cut, #2).** `vip_mc` does not split bursts (§4.4),
  so it must not silently hand `vip_dram` a request whose linear address span
  crosses a row. In the current slice that pure predicate lives directly in the
  AXI4 front-end helpers; a standalone `vip_mc_addr_pkg` remains only a future
  extraction point. On a true result the FE raises `uvm_error` and returns
  `DECERR` for the burst (the same pre-resolved path as the 4 KB reject, §4.4)
  rather than mis-timing it. True burst-splitting into per-row sub-requests is
  **§11 future work**.

**`predict()` serialization point (predict-ordering feedback).** The
scoreboard and any future FR-FCFS arbitration call the side-effect-free
`dram.predict()` (vip_dram §7.4). Prediction is defined **relative to the
accepted-request order at `req_fifo` ingress** — i.e. the order in which
`vip_mc` emits `vip_dram_req`s — not AXI4 acceptance order and not completion
order. Because `predict()` mutates nothing, calling it against the live device
is safe even with multiple outstanding requests, refresh insertion, and reset
races; the single serialization point is "what `vip_dram` has already
ingested."

---

## 6. Refresh policy

`vip_mc_refresh` owns the `tREFI` counter. `vip_dram` does **not**
auto-refresh — if `vip_mc` never sends REF, banks stay live.

### 6.1 First-cut policy (locked)

Simple periodic emission:

`vip_mc_refresh #(DRAM_CFG_P)` exposes a single request output —
`uvm_analysis_port #(vip_mc_cmd_entry_t) req_port` — and writes REF requests
through it as **MC-internal cmd entries** (`op = VIP_DRAM_OP_REF_E`, the bit-63
REF tag, `has_explicit_rank = 1` + `rank` set; `port_id`/`axi4_id`/`addr`/`beats`
unused). The port is wired to `backend.ref_req_export` (= `ref_fifo.analysis_export`,
the `vip_mc_cmd_entry_t` FIFO, §8.9) in the backend's `connect_phase` (§8.7/§8.9);
the arbiter serializes REF with all FE requests and **derives** the neutral
`vip_dram_req` for the device write (§8.9). `vip_mc_refresh` does **not** hold a
`dram` handle or connect to `dram.req_fifo` directly. (Same cmd_entry transport as
the front-ends, §8.9 — so the backend has exactly one input item type.)

```sv
task vip_mc_refresh::run_phase(uvm_phase phase);
  super.run_phase(phase);
  // cached at start_of_simulation_phase; mid-sim changes to
  // vip_dram_config.tREFI are NOT picked up.
  forever begin
    #(tREFI_cached * 1ns);
    #0;  // (M8) one delta after the tREFI boundary — see note below
    for (int r = 0; r < DRAM_CFG_P.N_RANKS_P; r++) begin
      vip_mc_cmd_entry_t ref_entry;
      ref_entry.op                = VIP_DRAM_OP_REF_E;
      ref_entry.has_explicit_rank = 1;          // REF targets a rank directly (§5.1)
      ref_entry.rank              = r;
      // bit 63 = REF discriminant (§5.1 / m2); never collides with AXI4 tags.
      // Refresh sets the REF tag itself; the arbiter passes it through and does
      // NOT allocate a _tag_ctr value for REF (§8.9 grant order).
      ref_entry.tag               = (64'b1 << 63) | ref_ctr++;
      req_port.write(ref_entry);                // → backend.ref_req_export (cmd_entry FIFO)
    end
  end
endtask
```

**All producers serialize through the backend arbiter (M8).** Both
FE `req_port`s and `refresh.req_port` connect to the backend (§8.7), which
arbitrates them into a single request stream to the device. This eliminates
same-delta races entirely — the arbiter picks one producer per arbitration
tick, so `dram.req_fifo` sees exactly one writer (`backend.req_port`). The
`#0` delta offset on the refresh timer (below) is a defensive guard, not the
primary serialization mechanism — the arbiter is.

- `tREFI` is read from `vip_dram_config` at `start_of_simulation_phase`
  — it is exposed there read-only for exactly this purpose. The value
  is cached locally so mid-sim mutations are not observed.
- Only `tREFI` is read from `vip_dram_config`; `tRFC` (refresh
  duration) is consumed entirely inside `vip_dram` when REF executes
  — `vip_mc` must not gate the next request on `tRFC`.
- REF emits one request per rank. `addr/beats/wdata/wstrb` are ignored
  by `vip_dram`; only `op` and `rank` are consulted.
- `tag` carries the bit-63 REF discriminant so the backend's `rsp_subscriber`
  short-circuits REF completions before they reach the cmd queue or any
  front-end `complete()` (§5.5 item 4).

### 6.2 Postponed / forced refresh (`DEFERRED` policy)

JEDEC allows up to **8** refreshes to be postponed if a critical
transaction is pending. Under `refresh_policy == VIP_MC_REFRESH_DEFERRED_E`,
`vip_mc_refresh` accrues one unit of deferral debt per `tREFI` instead of
emitting immediately, up to `refresh_max_deferred` (default 8), then drains the
whole debt in a forced catch-up burst — same **average** refresh rate as
`PERIODIC`, but bursty arrival. It exposes `get_deferred_debt` /
`get_peak_deferred_debt` / `get_deferred_catchup_count`, and `flush()` clears
them on reset. `tc_mc_refresh_deferred` covers it. Opportunistic pull-in on
device idle (coordinating the postpone/force decision with FR-FCFS picks)
remains §11 follow-on.

### 6.3 Reset

On `negedge rst_n` the refresh fork is killed, the `tREFI` counter
resets to 0, and the deferral counter clears. The fork re-arms on
the next `posedge rst_n` from `vip_mc::run_phase` (the cached `tREFI`
is re-read at that point too, in case the test mutated it during reset).

### 6.4 Pre-refresh page state

`vip_dram`'s `VIP_DRAM_OP_REF_E` implies precharge-all (see vip_dram
§7.4). `vip_mc` therefore does **not** need to issue any synthetic PRE
before REF; emitting `VIP_DRAM_OP_REF_E` directly with banks open is
correct, and `vip_dram` handles the bank-state transition internally.
If a future `vip_dram` revision changes this contract, `vip_mc_refresh` would
need to scan open-page state before emitting REF — but **no such accessor
exists in `vip_dram`'s public API today** (M6: `get_bank_state()` is *not* a
member; vip_dram §4 lists the complete public surface). Realizing that path
would therefore require **first defining a new `vip_dram` accessor** (e.g. a
`get_bank_state(rank,bg,bank)` added to vip_dram §4) and only then having
`vip_mc_refresh` emit per-bank fences. This is called out so the (currently
unsatisfied) contract dependency is explicit rather than assumed.

---

## 7. Address mapping policy

Address mapping (AXI4 byte-address → `{rank, bg, bank, row, col, byte_in_col}`)
is a **pure free function**, not a class — the MC reuses `vip_dram_addr_pkg`'s
`vip_dram_decode_addr` and keeps only MC-specific helpers in `vip_mc_addr_pkg`
(§8.3). The policy lives in `vip_mc_config.addr_map_policy` (a
`vip_dram_addr_map_t`) and is written into `vip_dram_config.addr_map` at
`start_of_simulation_phase`.

### 7.1 Default slicing

Matches `vip_dram`'s default (LSB-first):

```text
[byte][col][bank][bg][row][rank]
```

Rationale: column-interleaved keeps consecutive AXI4 burst beats on the
same row of the same bank (page-hit streak), bank/bg in the middle
spreads adjacent cache lines across bank groups (parallelism), row in
the upper bits keeps logically-contiguous pages in one bank, and rank
at the MSB lets coarse striping across DIMMs.

### 7.2 Override mechanism

`vip_mc_config.addr_map_policy` is a `vip_dram_addr_map_t` slot. The
MC stores the policy under the renamed field `addr_map_policy` purely
for clarity at the MC layer — the underlying type is
`vip_dram_addr_map_t` and the value is copied verbatim into
`vip_dram_config.addr_map` in `start_of_simulation_phase`. The
`_policy` suffix signals "the MC decides this"; the device-side field
is named `addr_map` because the device just applies it. The cross-VIP
type dependency is intentional (`vip_mc_pkg` imports `vip_dram_pkg`
per §2 rule 1).

Tests override the policy on `vip_mc_config` before
`start_of_simulation_phase`. A request opts into explicit-rank handling
by setting `vip_dram_req.has_explicit_rank = 1` (see vip_dram §4): the
device then honors `vip_dram_req.rank` verbatim and skips the rank
portion of its own slicing. The validity bit — not a sentinel `rank`
value — is what marks the override, so forcing rank 0 is unambiguous.
`vip_mc` uses this path for REF and direct-rank tests; ordinary RD/WR
traffic leaves `has_explicit_rank = 0` and lets the device decode the
rank from the address like every other field.

### 7.3 Multi-rank dispatch

Single channel with `n_ranks > 1` is supported in the first cut.
Because `vip_mc` writes its slicing policy into `vip_dram_config.addr_map`
(§7.2), the device decodes the rank from the address itself — RD/WR
requests therefore leave `has_explicit_rank = 0` and do **not** pre-set
`vip_dram_req.rank`. The single shared QoS-class queue interleaves ranks (no
per-rank arbitration). Refresh is the one explicit-rank producer: it emits one
REF per rank per tREFI tick with `has_explicit_rank = 1` (§6.1).
Multi-channel striping with multiple `vip_dram` instances remains §11
future work.

---

## 8. Class design

| Class                       | Base type                | Responsibility                                                                                                |
|-----------------------------|--------------------------|---------------------------------------------------------------------------------------------------------------|
| `vip_mc_config`             | `uvm_object`             | MC-specific knobs: outstanding limits, QoS scheduling policy (class count + aging), response-buffer depth, addr-map policy, refresh policy, perf-counter enable. Owns `cfg.ports[]` (per-port runtime map, §2.1). |
| `vip_mc_env_cfg`            | `uvm_object` (`#(DRAM_CFG_P, N_PORTS, PORTS[])`) | **System-config aggregator (§2.2).** The one object the TB fills: owns the `vip_mc_config`, holds the `dram` handle + per-port `vif_h[]` holders; `register_vif()` / `apply()` (one config-DB set). Optional — `vip_mc` falls back to discrete keys without it. |
| `vip_mc_vif_holder`         | `uvm_object` (virtual) + `#(CFG)` derived | Type-erased per-port vif carrier so heterogeneous (different-CFG) host vifs live in one `vif_h[]` array; `vip_mc_axi4_vif_holder #(AXI4_CFG_P)` holds the concrete `virtual vip_mc_axi4_if`. Resolved by constant-index `$cast` in `vip_mc::build_phase` (§2.2, §8.7). |
| `vip_mc_axi4_cfg`           | `uvm_object`             | **Native** AXI4-face knobs (outstanding limits, finite W/AW buffer depths, QoS→class map, `exclusive_enabled`, DECERR region map, `dram_handle_path`). No `vip_axi4_cfg_sub`, no inter-ID reorder *logic*, no fault injection. Owned by `vip_mc_config` as `cfg.axi4`. |
| `vip_mc_fe_base`            | `uvm_component` (virtual, `#(DRAM_CFG_P)`) | Abstract per-port front-end: `port_id`, MC-internal `req_port` (`vip_mc_cmd_entry_t`), `pure virtual complete(entry)`. Base handle the back-end holds (§2.1, §8.9). |
| `vip_mc_axi4_driver`        | `vip_mc_fe_base` (`#(AXI4_CFG_P, DRAM_CFG_P)`) | The **AXI4 front-end**: controller-side AW/W/B + AR/R handshakes, device-timed B/R completion (same-ID FIFOs), DECERR (region + 4 KB), beat↔column packing, full AXI4 features (INCR/WRAP/FIXED, narrow, unaligned, exclusive→EXOKAY, USER; §4.6), finite W backpressure, and the per-port AXI4 telemetry counters (`DECERR`, `4 KB`, `WREADY` stall, late-response, response-buffer-full, `EXOKAY`, exclusive-fail). One instance per AXI4 port. |
| `vip_mc_chi_driver`         | `vip_mc_fe_base` (`#(CHI_CFG_P, DRAM_CFG_P)`) | The **CHI SN front-end** (same source for D or E; issue selected in `CHI_CFG_P.issue`; reuses `vip_chi_types_pkg` types + `vip_chi_driver_snf` algorithms) — proof the back-end is protocol-agnostic. Handles ReadNoSnp / WriteNoSnp{Full,Ptl}, WriteNoSnpZero + ReadNoSnpSep (E), CleanSharedPersist{,Sep}; rejects HN/RN-only ops (atomics) with Comp(NONDATA_ERROR). |
| `vip_mc_cmd_queue`          | `uvm_component #(DRAM_CFG_P)` | QoS priority-class queue of `vip_mc_cmd_entry_t` (FCFS within a class, aging promotes; §5/§8.9). Flat-tag allocation, lifecycle, completion demux (recovers `port_id`). |
| `vip_mc_refresh`            | `uvm_component #(DRAM_CFG_P)` | `tREFI` counter, periodic `VIP_DRAM_OP_REF_E` emission; `DEFERRED` policy postpones up to `refresh_max_deferred` then drains a catch-up burst (§6.2), with `get_deferred_debt` / `get_peak_deferred_debt` / `get_deferred_catchup_count`. |
| `vip_mc_backend`           | `uvm_component` (`#(DRAM_CFG_P, N_PORTS)`) | Shared protocol-agnostic back-end: **single serialization point** — QoS-class + aging arbiter over `fe_req_export[N_PORTS]` + `ref_req_export` → `cmd_queue` → single `req_port` to device (gated by response-buffer credits, §8.9); demuxes responses by `cmd_entry.port_id`. Owns `cmd_queue`, `refresh`, the grant-order `issued_port` tap, and the global backend telemetry accumulators (`cmd_queue` peak depth, prediction error, effective bandwidth, bus utilization); decodes via the shared `vip_dram_addr_pkg` helpers and FE-local burst geometry helpers (§8.3). |
| `vip_mc`                    | `uvm_component` (`#(DRAM_CFG_P, N_PORTS, PORTS[])`) | Top: builds the `N_PORTS` front-ends from `PORTS[]` (case over `proto`, §2.1) + one `vip_mc_backend`; owns reset choreography; threads per-port `vif`s and the `dram` handle; publishes the top-level telemetry getters that aggregate backend, DRAM, refresh, and per-port FE state. |

### 8.1 `vip_mc_config` (uvm_object)

Owns MC-specific properties — scheduling/refresh/addr-map and
perf-counter gates. AXI4-face bus knobs live on the owned `axi4` child
(`vip_mc_axi4_cfg`, native — **not** a `vip_axi4_cfg_sub`), and DRAM device
knobs live on `vip_dram_config`.

| Field                              | Type                       | Default            | Notes                                                                                  |
|------------------------------------|----------------------------|--------------------|----------------------------------------------------------------------------------------|
| `axi4`                             | `vip_mc_axi4_cfg`          | created in `new()` | **Owned child (M4).** All AXI4-face knobs are reached as `cfg.axi4.<field>`; the driver gets this handle directly as its `cfg` (§5.3, §8.2). |
| `max_outstanding_rd`               | `int`                      | `16`               | Copied into `cfg.axi4.ar_outstanding_limit` in `build_phase`.                          |
| `max_outstanding_wr`               | `int`                      | `16`               | Copied into `cfg.axi4.aw_outstanding_limit` in `build_phase`.                          |
| `qos_class_count`                  | `int`                      | `1`                | QoS priority classes for the backend scheduler (§5/§8.9); `1` = legacy single-class FCFS. |
| `qos_aging_ns`                     | `real`                     | `0.0`              | Aging threshold (ns): a request waiting longer than this is promoted one class (§8.9). `0.0` = no aging. |
| `fr_fcfs_starvation_cap`           | `int`                      | `0`                | §11.1: within-class bound on FR-FCFS reordering — an eligible entry bypassed this many times by younger readiness-winners is force-served (oldest first), so a page-miss cannot be starved behind a page-hit streak. `0` = unbounded (pure FR-FCFS, legacy). Only with `fr_fcfs_enable`; distinct from `qos_aging_ns` (cross-class). Fires bump `get_fr_fcfs_forced_count()`. |
| `rd_wr_grouping_enable`            | `bool_t`                   | `FALSE`            | §11.1: turnaround-aware FR-FCFS. Makes bus direction (RD/WR) the PRIMARY within-class key — prefer the candidate matching the last issued command's direction so reads/writes issue in runs that amortize the device tWTR/tRTW bubble, with readiness deciding within a direction. The write-drain latency/throughput trade. Only with `fr_fcfs_enable`. Turnarounds counted by `get_bus_turnaround_count()`, overrides by `get_rd_wr_grouped_count()`. |
| `rd_wr_grouping_max`               | `int`                      | `0`                | §11.1: max consecutive same-direction issues before the grouping preference inverts (a forced turnaround) so the opposite direction cannot starve. `0` = unbounded run. Within-direction bound, distinct from `fr_fcfs_starvation_cap`; ignored unless `rd_wr_grouping_enable`. |
| `rsp_buf_depth`                    | `int`                      | `0`                | Finite response-buffer credits gating request issue (§8.9); `0` = unbounded (legacy emergent behavior). |
| `write_coalescing_enable`          | `bool_t`                   | `FALSE`            | §11.2: merge a newly admitted write into the newest outstanding same-stream pending write to the same row-word (byte-lane overlay + completion fan-out). Needs a host that holds >1 write outstanding. |
| `ecc_enable`                       | `bool_t`                   | `FALSE`            | §11.3: run a 64+8 SECDED decision on each completed read. The device physically corrupts a faulted beat; this layer un-flips the repairable bit in `vip_dram_rsp.corrupt_mask` so a CORRECTABLE read is restored and stays OKAY (bumps `get_ecc_corrected_count()`), and maps an UNCORRECTABLE double-bit error to a bus SLVERR with its poisoned bytes intact (bumps `get_ecc_uncorrectable_count()`). Off = corrupted bytes pass through as OKAY (silent corruption). Faults are injected device-side via `vip_dram::inject_fault()`. Writes unaffected. |
| `addr_map_policy`                  | `vip_dram_addr_map_t`      | LSB-first default  | Copied verbatim into `vip_dram_config.addr_map` at `start_of_simulation_phase`.        |
| `refresh_enabled`                  | `bool_t`                   | `TRUE`             | Disables the entire refresh fork when `FALSE`.                                         |
| `refresh_policy`                   | `vip_mc_refresh_policy_e`  | `PERIODIC`         | `PERIODIC` or `DEFERRED` (§6.2): `DEFERRED` postpones refreshes up to `refresh_max_deferred` then drains a catch-up burst — same average rate, bursty arrival. |
| `refresh_max_deferred`             | `int`                      | `8`                | Max postponed refreshes before a forced catch-up burst under `DEFERRED` (JEDEC's 8×tREFI cap). Validated `>= 1`. |
| `tREFI_override`                   | `real`                     | `-1.0`             | `< 0.0` = use `vip_dram_config.tREFI`; else override the cached `tREFI` (m3 — `real`, matching all other ns-valued timing fields; handles fractional-ns presets). |
| `init_delay_enabled`               | `bool_t`                   | `FALSE`            | tINIT-like bring-up hold-off: the backend gates all device issue (`init_gate`) armed on posedge `rst_n`, opening `init_delay_ns` later. |
| `init_delay_ns`                    | `real`                     | `0.0`              | Hold-off duration (ns) applied when `init_delay_enabled`; the first device access waits this long after reset release. |
| `perf_counters_enabled`            | `bool_t`                   | `TRUE`             | Gates all §8.8 counters; reset by `handle_reset()`.                                    |

Methods: `validate()` (sanity: outstanding limits `>= 0` — `0` is the
explicit "unbounded / no backpressure" value used in §4.2, §5.3, and
§5.5, so only negative values are rejected; addr-map policy slices
cover the geometry; `refresh_policy` is `PERIODIC` or `DEFERRED` with
`refresh_max_deferred >= 1`; `qos_class_count >= 1`, `qos_aging_ns >= 0.0`, and
all buffer depths `>= 0` with `0` meaning unbounded/none). The earlier "strictly
positive" wording was inconsistent with the `0 = unbounded` contract and is
dropped: `0` means unbounded, any positive value is the literal depth, and
negatives are a `uvm_fatal`.

### 8.2 `vip_mc_axi4_cfg` (uvm_object)

A **native** AXI4-face config — it does **not** contain, inherit from, or
reference `vip_axi4_cfg_sub` (§4.3). It is the `axi4` child of
`vip_mc_config` (§8.1) and is also the handle passed to the driver as its
`cfg` (§5.3):

```sv
class vip_mc_axi4_cfg extends uvm_object;
  `uvm_object_utils(vip_mc_axi4_cfg)

  // Outstanding budgets (0 = unbounded). Driven from vip_mc_config.
  int aw_outstanding_limit = 0;
  int ar_outstanding_limit = 0;

  // Finite buffers — what produce real backpressure (§4.5). 0 = unbounded.
  int aw_pending_depth     = 0;   // AW accepted-but-not-WLAST'd FIFO (§4.5)
  int w_data_buf_depth     = 0;   // bounded W-data staging; WREADY toggles when full (§4.5)
  // (the response-buffer credit lives on vip_mc_config.rsp_buf_depth — §8.1/§8.9)

  // QoS -> priority class. The 4-bit AxQOS is mapped into the
  // vip_mc_config.qos_class_count classes by this table (default: linear/clamp).
  // The scheduler (§8.9) acts on the resulting class; aging = qos_aging_ns.
  int qos_class_map [16];         // AxQOS(0..15) -> class index; default-built in new()

  // Exclusive access (AxLOCK) — vip_mc-local monitor mirroring vip_axi4_excl_monitor's algorithm (§4.6).
  bit exclusive_enabled    = 1'b1;

  // NOTE: still no inter-ID *reorder* knob — completion order stays emergent and
  // is never shuffled (§4.3, §5.2). rsp_buf_depth bounds occupancy / backpressure,
  // it does not reorder. And no fault-injection: a real MC's only errors are
  // decode (DECERR) and ECC SLVERR (§11.3); data faults are physical and
  // belong to the device/channel, not this config (§4.3).

  // DECERR-by-address map — the MC's address-decode regions (a real MC
  // concept), owned here. Helper names happen to match the stock API for
  // migration familiarity; the type and semantics are vip_mc's own.
  longint unsigned decerr_addr_lo [$];
  longint unsigned decerr_addr_hi [$];

  // MC-only.
  string dram_handle_path = "uvm_test_top.env.dram";

  function new(string name = "vip_mc_axi4_cfg"); super.new(name); endfunction
  function void     add_decerr_range(longint unsigned lo, longint unsigned hi);
  function void     clear_decerr_ranges();
  function bool_t   is_decerr_addr(longint unsigned addr);
  function int      qos_to_class(int unsigned axqos);   // qos_class_map lookup, clamped
endclass
```

There is **no** nested device `mem_cfg`: device-storage X-handling lives on
`vip_dram_config.mem_cfg` (vip_dram §7.1), owned and set by the TB on the
`vip_dram` instance. `vip_mc` never reads or forwards any `mem_cfg` — there is
no `build_phase` copy of memory config from `vip_mc` into `vip_dram_config`.

### 8.3 Address mapping — `vip_dram_addr_pkg` reuse

**No `vip_mc_addr_map` class.** Address decode is a *pure free function*, so it
lives in a package — never a `uvm_object` (matching `vip_dram`, which keeps its
decode in `vip_dram_addr_pkg` and the `vip_dram_addr_map_t` type + default-builder
in `vip_dram_types_pkg`).

- **Shared decode (no MC copy).** The MC reuses `vip_dram`'s decode directly:
  `vip_dram_decode_addr(addr, DRAM_CFG_P, cfg.addr_map_policy)` (in
  `vip_dram_addr_pkg`, already imported via `vip_dram_pkg`, §2 rule 1). The policy
  is the same `vip_dram_addr_map_t` struct the MC writes into
  `vip_dram_config.addr_map` (§7.2), so the MC's internal queue keying and the
  device's slicing run **one** algorithm — they cannot drift.
- **Current slice note.** The genuinely MC-specific pure helpers that an eventual
  `vip_mc_addr_pkg` would hold — burst→`beats` mapping and the row-crossing
  predicate — currently live inline in `vip_mc_axi4_driver`. The extraction is a
  maintainability follow-on, not a missing runtime dependency.

### 8.4 `vip_mc_cmd_queue`

A flat transaction counter, the QoS priority-class waiting structure, and a
tag→entry lookup for completion demux:

```sv
protected longint unsigned                _tag_ctr;             // flat, ++ per ISSUED request
protected vip_mc_cmd_entry_t              _classq [][$];        // waiting entries per QoS class (FCFS within); dynamic — new[cfg.qos_class_count] in build_phase
protected vip_mc_cmd_entry_t              _inflight [longint unsigned]; // ISSUED, keyed by tag
```

`_classq` holds admitted-but-not-yet-issued entries — one FCFS queue per QoS
class. It is a **dynamic** array allocated `_classq = new[cfg.qos_class_count]`
in `build_phase` — **not** a fixed `[N_CLASSES]` dimension, because
`qos_class_count` is a runtime knob (§8.1) and the elaboration-time-constant
discipline of §2.1 forbids sizing a fixed unpacked dimension from it. The
arbiter (§8.9) selects across classes with aging. `_inflight` holds issued
entries awaiting their `vip_dram_rsp`.

API:

- `function void admit(vip_mc_cmd_entry_t e);`      // FE-emitted entry → `_classq[e.qos_class]`; stamps `admit_time`
- `function bit  pick(output vip_mc_cmd_entry_t e);` // highest **effective** class (after aging), FCFS within, honoring same-ID order; 0 if none eligible
- `function void enqueue(vip_mc_cmd_entry_t e);`     // on ISSUE: `tag = _tag_ctr++`, stamp `enqueue_time`, move to `_inflight`
- `task wait_completion(longint unsigned tag, output vip_mc_cmd_entry_t e);`
- `function void on_dram_rsp(vip_dram_rsp #(DRAM_CFG_P) rsp);`  // wakes waiter; no-op on unknown tag
- `function void flush();`                          // reset — clears `_classq` + `_inflight` (`_tag_ctr` unchanged)

`admit`/`pick`/`enqueue` are called **only by the backend arbiter** (§8.9).
`admit` files an FE-emitted entry into its class queue and stamps `admit_time`
(the aging clock). `pick` chooses the next entry — highest **effective** class
(base class plus any aging promotion, §8.9), FCFS within that class, skipping any
entry blocked by an older same-ID entry. `enqueue` runs at the single ISSUE point
on the picked entry: it assigns `tag = _tag_ctr++` (bit 63 clear for AXI4
requests), stamps `enqueue_time = $realtime`, and moves the entry to `_inflight`.
**Issue order = `_tag_ctr` order = grant order** — QoS-class order across classes,
FCFS within a class; `enqueue_time` is a non-unique `$realtime` annotation, **not**
the ordering key (§8.9). `on_dram_rsp` demuxes by the flat `rsp.tag`, recovers the
AXI4 `axi4_id` from the matched entry, copies the timing fields in, sets
`completed=1`, and triggers the waiter. Unknown tags are silently dropped (REF
responses are filtered upstream in the backend subscriber per §5.5 item 4; this
no-op behavior is defensive).

### 8.5 `vip_mc_refresh`

See §6. Owns `tREFI` counter (cached at `start_of_simulation_phase`),
deferral debt counter (`DEFERRED` policy, §6.2), per-rank emission. Parameterized
`vip_mc_refresh #(DRAM_CFG_P)` so it can read `DRAM_CFG_P.N_RANKS_P` and build
the items. Emits REF through
`uvm_analysis_port #(vip_mc_cmd_entry_t) req_port` (a REF cmd_entry — `op = REF`,
bit-63 tag, `rank`; §6.1) wired to `backend.ref_req_export` in the backend's
`connect_phase` (§8.7/§8.9; the backend arbiter derives the neutral
`vip_dram_req` and is the single writer to `dram.req_fifo.analysis_export`) — no
direct `dram` handle.
Exposes `mc.get_refresh_count()` for the scoreboard — this counts REF
**emitted by the controller** and is a different object from
`dram.get_refresh_count()` (REF **executed** by the device, vip_dram §4 / M5).
The two are equal under normal operation and can diverge only across a reset.

### 8.6 `vip_mc_axi4_driver`

See §4.2. Extends `vip_mc_fe_base #(DRAM_CFG_P)` (§2.1); parameterized by
`vip_mc`'s own AXI4 width cfg `CFG_P` and the device `DRAM_CFG_P` (so its cmd
entries carry DRAM_CFG_P-width packed data, §5.1):

```sv
class vip_mc_axi4_driver #(vip_mc_axi4_cfg_t CFG_P = '{default: '0},
                           vip_dram_cfg_t    DRAM_CFG_P = VIP_DRAM_CFG_DEFAULT_C)
  extends vip_mc_fe_base #(DRAM_CFG_P);   // AXI4 front-end (§2.1; CFG_P is AXI4_CFG_P there)
  `uvm_component_param_utils(vip_mc_axi4_driver #(CFG_P, DRAM_CFG_P))
  ...
endclass
```

Holds:

- `virtual vip_mc_axi4_if #(CFG_P) vif;` (vip_mc's own interface — no
  `vip_axi4_if`, no `ROLE_P`).
- A handle to `vip_mc_cmd_queue` (set by `vip_mc` via config DB).
- `req_port` — inherited from `vip_mc_fe_base`, typed
  `uvm_analysis_port #(vip_mc_cmd_entry_t)` (§2.1/§8.9), wired by
  **`vip_mc_backend::connect_phase`** to `backend.fe_req_export[port_id]` (the
  backend arbiter serializes all producers into a single stream to the device,
  §8.7/§8.9). The driver fills the cmd_entry (op/addr/beats/wdata/wstrb +
  `axi4_id`/`port_id`, leaving `tag`/`enqueue_time` for the arbiter) and
  `req_port.write(entry)` — the arbiter derives the device-neutral `vip_dram_req`.
  The driver never writes a `vip_dram_req` and never holds a direct `dram` handle.
- A handle to its `vip_mc_axi4_cfg` (DECERR map, outstanding limits),
  referenced as `cfg.<field>` in driver scope (§5.3).
- Per-channel state: `aw_outstanding`, `ar_outstanding`, the per-port AW-pending
  FIFO and bounded W-data buffer (finite W backpressure, §4.5), and per-ID FIFOs
  for the mandatory same-ID B / R ordering. Inter-ID completions are driven as
  each `vip_dram_rsp` arrives from the response buffer (device-timed) — there is
  no reorder-window scratch.
- An **exclusive monitor** (when `cfg.exclusive_enabled`): a reservation table
  keyed by `(ARID, addr, size)`, set on an exclusive read and checked/cleared on
  an exclusive write or any intervening normal write to the region — yields
  `EXOKAY`/`OKAY` (§4.6). Mirrors `vip_axi4_excl_monitor`'s algorithm,
  re-implemented as a `vip_mc`-local monitor — no `vip_axi4_*` class is
  instantiated (§2 rule 1).
- A **single-active R scheduler** — one read burst is driven fully before the
  next (AXI4 has no read-data interleaving), while whole bursts of distinct
  `ARID`s still complete in device-timing order and same-ID order is preserved
  (§4.6).

Forks the five channel tasks (§4.2) in `driver_start()`. The driver never
subscribes to `dram.rsp_port`; the backend's single `rsp_subscriber` (§8.7/§8.9)
demuxes each completion by `cmd_entry.port_id` and delivers it into the owning
front-end via `fes[port_id].complete(entry)`, which feeds the same-ID B/R
schedulers (the FE correlates by `axi4_id` through its per-ID FIFOs). REF
responses are filtered in the backend (§5.5 item 4) and never reach a
front-end `complete()`.

### 8.7 `vip_mc` (uvm_component)

Top wiring (parameterized `vip_mc #(DRAM_CFG_P, N_PORTS, PORTS[])`). In
`build_phase`:

1. **Source the configuration.** First try the aggregator:
   `uvm_config_db #(vip_mc_env_cfg #(DRAM_CFG_P, N_PORTS, PORTS))::get(this, "", "env_cfg", env);`
   If found (§2.2), take `cfg = env.cfg` (which owns `cfg.axi4` and the per-port
   map), `dram = env.dram`, and each port's vif from `env.vif_h[k]`. If **not**
   found, fall back to the discrete keys: `vip_mc_config` under `"config"`, the
   `vip_dram` handle via `uvm_config_db #(vip_dram #(DRAM_CFG_P))::get(this, "",
   "dram", dram)`, and per-port vifs under `"vif_port0"`, …. Both paths leave
   `vip_mc` with the same handles — the env_cfg is purely a packaging convenience.
2. Construct the back-end: `backend = vip_mc_backend #(DRAM_CFG_P, N_PORTS)::type_id::create(...)`
   (it owns `cmd_queue` and `refresh`; address decode is the `vip_mc_addr_pkg` /
   `vip_dram_addr_pkg` free functions, §8.3, not an owned object).
3. Build the `N_PORTS` front-ends from `PORTS[]` by **per-port constant-index
   binding** (§2.1 — a literal-index `if`/`case` on `PORTS[k].proto`, not a
   runtime loop over arbitrary types); set each `fe.port_id = k`;
   `backend.register_port(k, fe)`. Each AXI4 front-end is handed its `cfg.axi4`
   and its host vif: with an env_cfg, a constant-index `$cast` of `env.vif_h[k]`
   to `vip_mc_axi4_vif_holder #(PORTS[k].axi4)` (the holder's `proto` field
   guards the cast); otherwise the per-port config-DB key (`"vif_port0"`, …).
4. Mirror outstanding-limit knobs into `cfg.axi4.aw_outstanding_limit` /
   `cfg.axi4.ar_outstanding_limit` (per AXI4 port).

`vip_mc` does **not** touch device-storage X-handling: that is owned by
`vip_dram_config.mem_cfg` and set by the TB on the `vip_dram` instance
(Finding-4 resolution). No memory config flows from `vip_mc` into
`vip_dram_config`.

In `connect_phase`: the **backend is the single serialization point** between
all request producers and the device. No front-end or refresh component
connects directly to `dram.req_fifo.analysis_export` — all requests flow
through the backend, which arbitrates and emits them one at a time:

```sv
// vip_mc::connect_phase wires ONLY the device boundary. The producer→arbiter
// connections (fe[i]/refresh → backend exports) are made inside
// backend.connect_phase (§8.9), since the backend owns the front-ends
// (via register_port) and the refresh component.
backend.req_port.connect(dram.req_fifo.analysis_export);                // backend → device (single writer)
dram.rsp_port.connect   (backend.rsp_subscriber);                       // completions →
                                                                        //   fes[cmd_entry.port_id].complete()
```

**Why not fan-in directly?** A `uvm_analysis_export` accepts multiple writers,
but the FCFS ordering between them in the same delta cycle is
non-deterministic (UVM does not define a priority among fan-in analysis port
writers). With `N_PORTS > 1`, two AXI4 drivers on different ports can call
`req_port.write()` on the same clock edge — the device would see both, but in
an undefined order. That breaks the "fully deterministic" contract (see
"Determinism, seed & clocking" above) and makes `predict()` results
irreproducible across simulators. (The `#0` delta guard (M8, §6.1) does not
prevent the device-fan-in race — the arbiter does, since refresh is arbitrated
through `ref_req_export` — and it does not address the port-vs-port case at all.
It is kept only as a defensive guard, §6.1.)

The backend serializes all producers through a single arbitration task:

- `fe_req_export[N_PORTS]` — one per front-end, receives neutral requests
- `ref_req_export` — receives REF requests from `vip_mc_refresh`
- the arbiter task picks one ready producer per cycle (round-robin among FE
  ports, refresh gets priority when pending), enqueues into `cmd_queue`, and
  emits a single `vip_dram_req` via `backend.req_port.write(...)` — the **only**
  writer to `dram.req_fifo.analysis_export`

This is the single serialization point — the MC's one path to DRAM. The arbiter
assigns the monotonic `_tag_ctr` sequence here, which **is** the grant/issue
order (QoS class + aging, FCFS within a class; §8.9); `cmd_queue.enqueue_time` is
only a `$realtime` annotation, not the ordering key. `predict()` reproducibility
follows from the grant order. Same
stimulus, same arbitration decisions,
same device request sequence, regardless of simulator scheduling.

In `start_of_simulation_phase`: `vip_mc` (which holds the `dram` handle) writes
`cfg.addr_map_policy` into `vip_dram_config.addr_map` and caches `tREFI`
(honoring `tREFI_override`). For internal queue keying the backend decodes with
the **same** policy by calling `vip_dram_decode_addr(addr, DRAM_CFG_P,
cfg.addr_map_policy)` (§8.3) — one decode algorithm, so MC-side and device-side
slicing cannot drift.

In `run_phase`: reset choreography (§9).

`vip_dram` is owned by the testbench, not by `vip_mc`. The TB passes
the handle in via the UVM config DB before `build_phase`, for example:

```sv
uvm_config_db #(vip_dram)::set(null, "uvm_test_top.env.vip_mc_inst*",
                               "dram", dram_h);
```

The handle name `dram` is used consistently in §6.1, §8.6, §9, and §13.2.

### 8.8 Performance counters

Current counters are read-only, gated by `vip_mc_config.perf_counters_enabled`,
and reset on runtime reset:

- `get_refresh_count()` — REF requests **emitted** by the MC (summed across
  ranks). Qualify as `mc.get_refresh_count()` in tests to distinguish it from
  `dram.get_refresh_count()` (REF executed by the device) — M5.
- `get_cmd_queue_peak_depth()` — high-water mark of `vip_mc_cmd_queue`.
- `get_4k_violation_count(port_id)` — 4 KB boundary DECERR classifications for
  one AXI4 front-end.
- `get_decerr_count(port_id)` — total DECERR classifications for one AXI4
  front-end.
- `get_wready_stall_cycles(port_id)` — cycles where `WREADY` was held low while
  an AW-pending burst still had W beats to accept.
- `get_rsp_late_count(port_id)` — B/R completions that became eligible on an
  earlier controller edge but were only driven later because the bus side was
  busy or backpressured.
- `get_exokay_count(port_id)` — exclusive completions that returned `EXOKAY`.
- `get_excl_fail_count(port_id)` — exclusive writes that failed the reservation
  check and therefore completed MC-locally with `OKAY` and no device issue.
- `get_row_hit_rate()` — fraction of completed device accesses classified as
  page hits: `page_hit / (page_hit + page_miss + page_empty)`.
- `get_predict_accuracy()` — mean absolute last-beat prediction error in
  nanoseconds, measured between the backend's pre-issue `dram.predict()` result
  and the completed `vip_dram_rsp.last_beat_ready_time`.
- `get_effective_bandwidth()` — delivered payload bytes per nanosecond over the
  observed data window `[first_data_ready, last_burst_end]`, where one request
  contributes `beats * ROW_BYTES_P` bytes.
- `get_bus_utilization()` — fraction of that same observed window during which
  the DRAM channel carried read/write burst data.

**Residual-observability getters.** Layered on the aggregate
counters above; all return 0 unless `perf_counters_enabled` and reset per epoch by
`clear_perf_counters()`:

- `get_observed_reorder_count()` — completions whose `admit_order` was older than
  one already retired, i.e. the emergent inter-ID out-of-order retirements (§4.3).
  Zero for a strictly in-order stream; ≥ 1 whenever a younger request completes
  ahead of an older one (see `tc_mc_axi4_ooo_inter_id`).
- `get_mean_latency_ns()` / `get_min_latency_ns()` / `get_max_latency_ns()` /
  `get_latency_sample_count()` — completion latency (admit → last device beat)
  across every completed host request (primary and each coalesced secondary).
- `get_latency_hist_count(bucket)` — coarse log2-ns latency histogram; bucket `b`
  spans `[2^b, 2^(b+1))` ns (bucket 0 also absorbs sub-1 ns), saturating at bucket
  `LAT_HIST_MAX_BUCKET_C`.
- `get_occupancy_hist_count(depth)` / `get_occupancy_sample_count()` — the
  `vip_mc_cmd_queue` pending-depth occupancy histogram, sampled on every depth
  transition (each admit and each dequeue), so the buckets sum to the sample
  count.
- `get_port_completed_count(port_id)` / `get_port_data_bytes(port_id)` — per-port
  utilization breakdown (completed request count and delivered payload bytes),
  complementing the channel-global bandwidth/utilization getters.

Broader observability ideas — for example explicit response-buffer occupancy
histories rather than aggregate counters — remain follow-on work beyond this set.

### 8.8A Optional waveform status probe (debug-only)

For **human debug**, there is real value in a small virtual interface that
mirrors MC-internal status into the waveform database. The point is not to add
another functional contract, and not to create a second source of truth for
tests. The point is to make controller behavior that currently lives in UVM
objects, counters, and analysis traffic visually correlate with the host AXI4
waveform: request admission, queueing, refresh insertion, issue timing,
backpressure, and completion pacing.

This probe therefore belongs in the plan as an **optional observability aid**,
not as part of the mandatory host/device contract.

**Why it is useful.**

- The existing getters (`get_cmd_queue_peak_depth()`,
  `get_row_hit_rate()`, `get_predict_accuracy()`,
  `get_effective_bandwidth()`, `get_bus_utilization()`,
  `get_wready_stall_cycles()`, `get_rsp_buf_full_cycles()`,
  `get_exokay_count()`, etc.) and
  `backend.issued_port` are the right **programmatic** surfaces for tests and
  scoreboards, but they are not wave-native.
- A waveform-facing probe makes it much easier to answer questions such as
  "did this request stall in the FE, in the MC queue, behind refresh, or on
  response-buffer credit?" without reconstructing the answer from log text or
  UVM object dumps.
- The probe is especially valuable when debugging timing behavior that is not
  directly visible on the host bus: emergent inter-ID order, FE-local rejects,
  response-buffer pressure, or arbitration starvation / aging effects.

**Hard design rules.**

1. The probe is **optional and non-functional**. If no status VIF is provided,
   `vip_mc` behavior, timing, and compile requirements shall remain unchanged.
2. The probe is **not another host port**. The upward contract remains exactly
   one host interface per port (§2.1 / §8.7). This is a sideband debug surface
   only.
3. The probe must have **one writer**. The backend, refresh logic, and
   front-ends shall not all drive a shared virtual interface directly. Multiple
   class writers create unclear ownership, reset races, and delta-cycle update
   hazards that are much harder to reason about than the behavior being debugged.
4. The probe must respect the existing MC/DRAM boundary. Raw bank/page FSM
   state still belongs to `vip_dram`, not `vip_mc` (§1 / §6 / §8.3). The probe
   may mirror per-request outcomes that already cross the boundary in
   `vip_dram_rsp` (for example page-hit / miss / empty classification), but it
   shall not become a backdoor for DRAM internals.
5. Tests and scoreboards shall **not** depend on the probe for correctness.
   The source-of-truth APIs remain the getters, the TLM traffic, and the timing
   scoreboard. The status probe is for waveform visualization and bring-up.

**Recommended ownership model.**

- Add an owned debug interface, conceptually `vip_mc_status_if #(N_PORTS)`.
- Add a plain snapshot / mirror state container owned by `vip_mc`.
- The backend, refresh block, and front-ends update that snapshot using normal
  class fields, counters, and one-shot event bits.
- `vip_mc` alone owns the optional virtual status-if handle and mirrors the
  current snapshot onto the physical interface on the canonical controller
  clock.
- One-shot events from class code are latched as sticky software bits and
  emitted as one-cycle waveform pulses on the next controller edge. This avoids
  same-delta update races and keeps the wave semantics clock-aligned.
- Reset clears both the snapshot and the waveform probe in the same epoch as
  `handle_reset()`, so the probe reflects a clean post-reset state boundary.

This "many producers, one mirror owner" shape preserves debug value without
making the UVM classes fight over a physical interface.

**What belongs on the probe.**

The probe should focus on **internal MC state that is not already visible on
`vip_mc_axi4_if`**:

- Backend / arbiter state: current command-queue depth, optional peak depth,
  inflight-to-device count, whether device issue credit is currently available,
  last-issued `{port, tag, op}`, and a small issue / stall-reason enum.
- Event pulses: `issue_pulse`, `complete_pulse`, `refresh_emit_pulse`, and a
  `local_reject_pulse` for FE-local DECERR / unsupported-shape resolution.
- Completion summary: last-completed `{port, tag, op, resp}` plus page outcome
  (`hit`, `miss`, `empty`) when that classification is available in the device
  response.
- Per-port FE state: pending response depth, pending write-burst assembly depth,
  W-data buffer occupancy / full, response-buffer occupancy / full, and any
  other internal counters needed to explain why `AWREADY` / `ARREADY` /
  `WREADY` changed.
- Refresh state: refresh count and the most recent refresh-emit pulse. The live
  `tREFI` countdown is optional; it is useful for debug, but lower priority than
  queue / issue / backpressure state.

One especially useful field is an **enumerated stall reason** for "why nothing
happened this cycle." A small enum such as `NONE`, `NO_BUFFERED_INPUT`,
`CMD_QUEUE_EMPTY`, `SAME_STREAM_BLOCKED`, `DEVICE_CREDIT_FULL`,
`RSP_BUFFER_FULL`, `REF_STRICT_PRIORITY`, or `IN_RESET` often explains wave
behavior faster than several independent booleans.

**What does not belong on the probe.**

- Raw AXI4 bus signals already present on `vip_mc_axi4_if`.
- Direct mirroring of `vip_dram` bank arrays, row-open state, or timing tables.
- Multiple independent interface drivers from different UVM classes.
- Scoreboard-only data structures whose meaning depends on off-line log
  reconstruction rather than live controller state.

**Protocol and clocking scope.**

The status probe today is exercised on the AXI4 slice, so the first-cut probe may
legitimately expose a few AXI4-specific FE fields. Even so, the top-level probe
should stay as **MC-centric and protocol-neutral as practical** so extending it
to the CHI ports does not force them to fake `AW` / `W` / `AR` concepts forever.

Likewise, the first-cut mirror can run on the canonical AXI4 controller clock
already used for reset choreography. If future `vip_mc` support grows into a
true multi-clock topology, the right answer is probably **one status probe per
host clock domain**, not one over-compressed probe that hides CDC boundaries.

**Implementation note on time-valued fields.**

Mirroring raw `realtime` values such as `first_beat_ready_time` /
`last_beat_ready_time` is possible, but not mandatory for v1. In practice,
waveforms become more readable from pulse + depth + classification fields than
from absolute-time shadows, so the latter should be treated as optional follow-
on instrumentation, not a gating requirement for the probe itself.

**Exact v1 `vip_mc_status_if` contract (freeze before code).**

The first implementation step should now be to freeze the **user-visible wave
surface** of `vip_mc_status_if` so the later code work does not drift. In v1,
prefer **enum-typed fields** and plain integral types (`int unsigned`,
`longint unsigned`) over densely packed bitfields: this is a debug probe, so
wave readability matters more than compression. The signal list below is the
recommended v1 contract.

```sv
interface vip_mc_status_if #(
  int N_PORTS = 1
) (
  input logic clk,
  input logic rst_n
);

  typedef enum int unsigned {
    VIP_MC_STATUS_OP_NONE_E,
    VIP_MC_STATUS_OP_RD_E,
    VIP_MC_STATUS_OP_WR_E,
    VIP_MC_STATUS_OP_REF_E
  } vip_mc_status_op_e;

  typedef enum int unsigned {
    VIP_MC_STATUS_RSP_NONE_E,
    VIP_MC_STATUS_RSP_OKAY_E,
    VIP_MC_STATUS_RSP_EXOKAY_E,
    VIP_MC_STATUS_RSP_SLVERR_E,
    VIP_MC_STATUS_RSP_DECERR_E
  } vip_mc_status_rsp_e;

  typedef enum int unsigned {
    VIP_MC_STATUS_PAGE_UNKNOWN_E,
    VIP_MC_STATUS_PAGE_HIT_E,
    VIP_MC_STATUS_PAGE_MISS_E,
    VIP_MC_STATUS_PAGE_EMPTY_E
  } vip_mc_status_page_e;

  typedef enum int unsigned {
    VIP_MC_STATUS_STALL_NONE_E,
    VIP_MC_STATUS_STALL_IN_RESET_E,
    VIP_MC_STATUS_STALL_NO_BUFFERED_INPUT_E,
    VIP_MC_STATUS_STALL_CMD_QUEUE_EMPTY_E,
    VIP_MC_STATUS_STALL_SAME_STREAM_BLOCKED_E,
    VIP_MC_STATUS_STALL_DEVICE_CREDIT_FULL_E,
    VIP_MC_STATUS_STALL_RSP_BUFFER_FULL_E,
    VIP_MC_STATUS_STALL_REF_STRICT_PRIORITY_E
  } vip_mc_status_stall_e;

  typedef enum int unsigned {
    VIP_MC_STATUS_REJECT_NONE_E,
    VIP_MC_STATUS_REJECT_DECERR_REGION_E,
    VIP_MC_STATUS_REJECT_DECERR_4K_E,
    VIP_MC_STATUS_REJECT_DECERR_ROW_SPAN_E,
    VIP_MC_STATUS_REJECT_UNSUPPORTED_AXI_SHAPE_E,
    VIP_MC_STATUS_REJECT_EXCLUSIVE_FAIL_LOCAL_E,
    VIP_MC_STATUS_REJECT_SLVERR_LOCAL_E
  } vip_mc_status_reject_e;

  typedef enum int unsigned {
    VIP_MC_STATUS_FE_BLOCK_NONE_E,
    VIP_MC_STATUS_FE_BLOCK_IN_RESET_E,
    VIP_MC_STATUS_FE_BLOCK_AW_OUTSTANDING_FULL_E,
    VIP_MC_STATUS_FE_BLOCK_AR_OUTSTANDING_FULL_E,
    VIP_MC_STATUS_FE_BLOCK_AW_PENDING_FULL_E,
    VIP_MC_STATUS_FE_BLOCK_WBUF_FULL_E,
    VIP_MC_STATUS_FE_BLOCK_NO_WRITE_IN_FLIGHT_E,
    VIP_MC_STATUS_FE_BLOCK_RSP_BUF_FULL_E   // AW/AR gated by the shared response buffer
  } vip_mc_status_fe_block_e;

  // Controller-global level state.
  bit                    rst_active;
  int unsigned           cmd_queue_depth;
  int unsigned           cmd_queue_peak_depth;
  int unsigned           inflight_to_device;
  int unsigned           rsp_buf_used;
  bit                    rsp_buf_full;
  bit                    device_issue_credit_avail;
  vip_mc_status_stall_e  backend_stall_reason;
  int unsigned           refresh_count;

  // Grant / issue pulse and summary. This is the wave-level counterpart to
  // backend.issued_port, so it includes REF and pre_resolved entries.
  bit                    issue_pulse;
  int unsigned           issue_port_id;
  longint unsigned       issue_tag;
  vip_mc_status_op_e     issue_op;
  int unsigned           issue_qos_class;
  bit                    issue_pre_resolved;

  // Completion pulse and summary for one entry entering the FE response path.
  bit                    complete_pulse;
  int unsigned           complete_port_id;
  longint unsigned       complete_tag;
  vip_mc_status_op_e     complete_op;
  vip_mc_status_rsp_e    complete_resp;
  vip_mc_status_page_e   complete_page;
  bit                    complete_pre_resolved;

  // Refresh event summary.
  bit                    refresh_emit_pulse;
  int unsigned           refresh_emit_rank;

  // FE-local reject summary (classification-time view, separate from the later
  // response-drive completion view).
  bit                    local_reject_pulse;
  int unsigned           local_reject_port_id;
  vip_mc_status_op_e     local_reject_op;
  vip_mc_status_reject_e local_reject_reason;

  // Per-port level state.
  int unsigned              rd_outstanding_count [N_PORTS];
  int unsigned              wr_outstanding_count [N_PORTS];
  int unsigned              aw_pending_depth     [N_PORTS];
  int unsigned              pending_b_depth      [N_PORTS];
  int unsigned              pending_r_depth      [N_PORTS];
  int unsigned              active_r_slots_used  [N_PORTS];
  int unsigned              w_data_buf_occupancy [N_PORTS];
  vip_mc_status_fe_block_e  aw_block_reason      [N_PORTS];
  vip_mc_status_fe_block_e  ar_block_reason      [N_PORTS];
  vip_mc_status_fe_block_e  w_block_reason       [N_PORTS];

endinterface
```

**v1 field-semantics rules.**

- `issue_pulse` means one entry crossed the backend's single grant / enqueue
  point this cycle. `issue_op = REF` is legal; `issue_pre_resolved = 1` means
  the entry was ordered like any other but skipped the device write.
- `complete_pulse` means one entry became available to the FE completion path
  this cycle. For FE-local completions, `complete_pre_resolved = 1` and
  `complete_page = VIP_MC_STATUS_PAGE_UNKNOWN_E`.
- `local_reject_pulse` is the **first-cause** FE classification event. It is
  intentionally separate from `complete_pulse`: a local reject is both a debug
  classification event and, later, a response-path event.
- `backend_stall_reason` is the answer to "why did no backend issue happen at
  this sample?" It is a controller-global explanation, not a per-port channel
  throttle reason.
- `aw_block_reason[k]`, `ar_block_reason[k]`, and `w_block_reason[k]` are only
  meaningful when the corresponding bus `*READY` is low on port `k`. When the
  channel is accepting traffic, they shall read `VIP_MC_STATUS_FE_BLOCK_NONE_E`.
- `rsp_buf_used` / `rsp_buf_full` are **controller-wide** because response
  credit-gating is owned at the backend / MC level, even though completed work
  later fans out into per-port B/R queues.

**v1 pulse-coalescing rule.**

The v1 probe is sampled once per controller clock, so it does not try to expose
an unbounded event FIFO in signals. If multiple same-kind events occur between
two probe samples, the pulse remains high for one sampled cycle and the summary
fields show the **most recent** event of that kind. This is acceptable for v1
because the lossless state remains in the depth / occupancy counters and in the
existing TLM / scoreboard surfaces.

**What is intentionally omitted from v1.**

- No raw `realtime` mirrors (`first_beat_ready_time`, `last_beat_ready_time`).
- No full payload mirrors (`wdata[]`, `rdata[]`, `wstrb[]`).
- No direct DRAM bank/page arrays or timing-table shadows.
- No protocol-specific field explosion beyond the minimum FE summaries above.

If later debug experience shows that one timing or payload field is repeatedly
needed, add it in a v2 extension rather than overloading the first-cut probe.

**v1 plumbing and ownership rollout.**

The exact field contract above is only half the design; the other half is how
to thread it through the current `vip_mc` architecture without creating a new
ownership mess.

- **One probe instance, not one per port.** The status probe is controller-
  global and depends only on `N_PORTS`, not on any per-port AXI4 width cfg.
  Unlike the host vifs, it does **not** need type-erased holder machinery.
- **Carry it directly on `vip_mc_env_cfg`.** The cleanest v1 shape is a single
  optional field on the aggregator, conceptually:

  ```sv
  virtual vip_mc_status_if #(N_PORTS) status_vif;
  ```

  With no env_cfg, the fallback path can use one direct config-DB key such as
  `"status_vif"`. There is no value in inventing `status_vif_port0`-style keys
  or a separate holder class for a single homogeneous debug interface.
- **`vip_mc` resolves the handle; producers do not.** `vip_mc::build_phase`
  should resolve the optional `status_vif` handle once, keep it locally, and
  leave every other component oblivious to the interface. Backend / refresh /
  FE code should publish into software state only.
- **Use one shared snapshot, partitioned by field ownership.** A plain object,
  struct, or small helper class is sufficient. The important rule is that each
  field family has one software owner even if many components contribute to the
  overall snapshot: backend owns controller-global occupancy / credit / stall
  state and the grant-order issue summary; refresh owns refresh pulse / rank /
  count fields; each FE owns only its own per-port slice (`[port_id]`) plus its
  own local-reject summary contribution; `vip_mc` owns the physical interface
  mirroring and the pulse-clear epoch.
- **Mirror on the controller clock only.** `vip_mc` should run one small
  publisher task on the canonical controller clock that copies level state into
  the interface, emits one-cycle pulses from latched software event bits, and
  then clears only those pulse bits. The probe must not be written from random
  class call-sites in delta time.
- **Compile-order rule mirrors the host interface rule.** When the probe is
  enabled in the build, `vip_mc_status_if.sv` should analyze before
  `vip_mc_pkg`, exactly like `vip_mc_axi4_if.sv`, because `vip_mc` or its
  config objects will hold a `virtual vip_mc_status_if #(N_PORTS)` handle.

This keeps the probe additive: one optional interface, one publisher, one
shared snapshot, and zero changes to the functional host/device contract.

**Status-probe requirements.** The probe is defined by the following contract, and
a sanity regression (`tc_mc_status_probe`) exercises it under queueing,
refresh, and backpressure:

- The frozen v1 `vip_mc_status_if` contract above keeps a protocol-neutral core
  plus only the minimum AXI4-specific overlay the slice needs.
- Status-VIF plumbing is optional in the TB / env-config path and must not change
  the host-interface contract: one direct optional `status_vif` handle on
  `vip_mc_env_cfg`, and one fallback config-DB key when no env_cfg is used.
- A `vip_mc`-owned snapshot / mirror state container carries the probe fields.
- The backend publishes queue depth, inflight count, issue summary, completion
  summary, and stall reason into that snapshot; refresh publishes refresh pulses
  and refresh count.
- Each FE publishes its own pending-depth, W-buffer, response-buffer, and local-
  reject state. The FE emits true first-cause reject pulses/reasons
  (`classify_request` distinguishes region vs 4K DECERR; unsupported-shape,
  exclusive-fail, and local-SLVERR sites are annotated), and
  `get_aw_block_reason()`/`get_ar_block_reason()` surface response-buffer gating
  explicitly via `VIP_MC_STATUS_FE_BLOCK_RSP_BUF_FULL_E`.
- Exactly one owner mirrors the snapshot onto the status interface on the
  controller clock, with one-cycle pulse semantics for events.
- The probe resets in the same epoch as `handle_reset()` so wave state and
  runtime state restart together.
- Raw DRAM internals stay out of the probe; if device-state waves are later
  needed, they belong on a separate `vip_dram`-owned debug surface, not on an MC
  probe that reaches across the architectural boundary.
- One example / regression scenario instantiates the probe and sanity-checks a
  few fields against known traffic, so the probe cannot silently rot.
- The probe is for wave debug and bring-up only; scoreboards and tests use the
  getters, `issued_port`, and timing prediction as the correctness contract.

### 8.9 Backend arbiter — buffering, ordering & ownership

`vip_mc_backend` is the **single serialization point** (§8.7). This section
pins down how it buffers producers, fixes order deterministically, and which
component owns which connection — the detail §8.7 references.

**Buffered inputs (not bare exports).** Each `fe_req_export[i]` and
`ref_req_export` is the `analysis_export` of a per-producer backend-owned
`vip_mc_activity_fifo`:

```sv
vip_mc_activity_fifo #(vip_mc_cmd_entry_t) fe_fifo [N_PORTS]; // fe_req_export[i] = fe_fifo[i].analysis_export
vip_mc_activity_fifo #(vip_mc_cmd_entry_t) ref_fifo;          // ref_req_export   = ref_fifo.analysis_export
```

A producer's `req_port.write()` is synchronous and only **enqueues** into a
FIFO; it never reaches the device in the caller's delta. (A bare
`uvm_analysis_imp` would run the sink synchronously and reintroduce the very
same-delta fan-in this design removes — so the inputs **must** be FIFOs the
arbiter drains, not imps.)

**FE→backend transport is the MC-internal `vip_mc_cmd_entry_t`, not the
device-neutral `vip_dram_req`.** A front-end fills `op`, `addr`, `beats`,
`wdata[]`/`wstrb[]` (packed per §5.6), `axi4_id`, `port_id`, and — for rejects —
`pre_resolved`/`resp`, and leaves the ordering fields (`tag`, `enqueue_time`)
unset. The device-neutral `vip_dram_req` — which carries no `axi4_id`/`port_id`
— is **derived by the arbiter** for the single device write, so the device
boundary stays port/ID-agnostic (§2 rule 5). (This is why `vip_mc_fe_base`'s
`req_port`/`complete()` carry `vip_mc_cmd_entry_t`, §2.1: the neutral req cannot
convey `axi4_id`, which the entry needs to drive BID/RID.)

**The arbiter is the sole order-owner and sole device writer.** One `run_phase`
task; each iteration it:

1. **Admits** whatever is available: `try_get` on each non-empty `fe_fifo[i]` and
   `ref_fifo`, and for FE entries `cmd_queue.admit(e)` files each into its QoS
   class by the **pre-stamped** `e.qos_class` — the front-end already derived it
   from its own protocol cfg before emitting (AXI4: `cfg.qos_to_class(axqos)`,
   §4.6/§8.6), so the protocol-agnostic backend never reaches into a
   protocol-specific cfg (§2 rule 5) — and `admit` stamps `admit_time`. REF is
   held in a separate strict-priority slot.
2. **Picks** the next entry to issue (see *Grant order*): REF first if pending;
   else `cmd_queue.pick(e)` — highest effective class after aging, FCFS within,
   same-ID-safe — **and only if a response-buffer credit is free** (see
   *Response-buffer credits*). If nothing is eligible it waits.
3. **Issues.** `cmd_queue.enqueue(entry)` assigns `tag = _tag_ctr++` (bit 63 = 0),
   stamps `enqueue_time = $realtime`, and reserves a response credit — tag, order,
   and timestamp are fixed at this one point. If `!entry.pre_resolved` it derives
   the neutral `vip_dram_req` (op/addr/beats/wdata/wstrb/`rank`/`has_explicit_rank`
   + the tag) and `req_port.write()`s it — the **only** writer to
   `dram.req_fifo.analysis_export`. A `pre_resolved` DECERR entry (§4.4) is ordered
   identically but **skips** the device write (ready times MC-chosen, §5.1). A
   **REF** entry (`op = REF`, `has_explicit_rank = 1`) keeps its **own** bit-63 tag
   (no `_tag_ctr`, no response credit) and bypasses `cmd_queue` entirely.

So there is exactly one admit/enqueue path through `cmd_queue` (the arbiter) and
one device writer; the FE never touches `cmd_queue` and never assigns a tag.

**Grant-order tap for scoreboards (`issued_port`).** At this same enqueue point
the arbiter also writes the entry to `backend.issued_port` — an
`uvm_analysis_port #(vip_mc_cmd_entry_t)` carrying the grant-ordered stream (tag,
`axi4_id`, op, addr, beats, the REF flag), REF entries included. This is the
**only** place device-ingress order is observable with the AXI4 IDs still
attached, so the scoreboard (§13.2) subscribes here to drive `predict()` in the
exact order — and with the exact REF interleaving — the device sees. It is a
diagnostic tap (no device coupling); a TB that does not check timing can leave it
unconnected.

**Issue order = `_tag_ctr` order, NOT `enqueue_time`.** The arbiter can enqueue
several entries at the same `$realtime`, so `enqueue_time` is a **non-unique
annotation** that cannot order same-time issues. The authoritative order is the
monotonic `_tag_ctr` sequence (the tag's low 63 bits, §5.1), assigned in grant
order at the single enqueue point — QoS-class order across classes, FCFS within a
class (§5). Reproducibility rests on that **grant order**, specified next.

**Grant order (deterministic).** Priority, then class, then port, then arrival:

- **Refresh has strict priority:** if a REF is pending, grant it this tick. REF
  gets a bit-63 tag, never enters `cmd_queue`, never yields B/R, and takes no
  response credit (see *FCFS scope*).
- **Else highest effective QoS class.** Each waiting entry's *effective* class is
  its base class plus one promotion per `qos_aging_ns` it has waited
  (`$realtime - admit_time`), capped at the top class — this is the **aging** that
  prevents starvation. The arbiter serves the highest non-empty effective class.
- **Within a class: round-robin across ports, then FCFS.** A round-robin pointer
  `_rr` (reset to 0 at construction and `handle_reset()`) breaks ties between
  ports fairly; within one port it is strict arrival order (`_tag_ctr` / the
  port's emission order). A pick is **skipped** if it is blocked by an older
  same-ID entry (same-ID order is absolute, §5.2) or if no response credit is free.
- If nothing is eligible, the task blocks (on FIFO availability or a freed credit)
  and retries.

With `qos_class_count == 1` and `qos_aging_ns == 0` this reduces exactly to the
former round-robin FCFS. The grant sequence — hence `_tag_ctr` order — is a pure
function of the (deterministic) arrival pattern + QoS values + aging clock,
independent of simulator scheduling. "Emission order" for a port is the order it
calls `req_port.write()` (writes at `WLAST`, reads at `AR`-accept — §5.6, the same
order `predict()` is defined against).

**FCFS scope (REF and QoS are both priority insertions).** Pure arrival order
holds only **within a QoS class** (by `_tag_ctr`); a higher class (or an aged-up
entry) is issued ahead of an older lower-class request — the intended QoS behavior
(§5). REF outranks every class (a later REF can pre-empt an earlier FE request);
it never enters `cmd_queue` and yields no B/R (§5.5 item 4), but the device sees it
interleaved — a controller forcing a refresh. The **same-ID order guarantee is
never overridden** by class, aging, or REF (§5.2).

**Response-buffer credits (finite, backpressure).** The MC holds completed-but-
undriven responses in a finite buffer of `cfg.rsp_buf_depth` credits (`0` =
unbounded). The arbiter reserves one credit when it **issues** a device-backed
request and releases it once the completion has been driven on B/R (master
accepted the last beat). When no credit is free the arbiter stops issuing — so a
master stalling `BREADY`/`RREADY` fills the buffer, which back-pressures request
issue, which fills the QoS-class queues, which finally back-pressures
`AWREADY`/`ARREADY`/`WREADY` (§4.5). This is the realistic loop: finite buffers,
not infinite ones, produce controller backpressure. `pre_resolved` DECERR entries
take a credit (they still drive B/R); REF takes none.

**Completion.** `backend.rsp_subscriber` is the sole subscriber on
`dram.rsp_port`. It filters REF (bit-63), looks up `cmd_queue` by `rsp.tag` to
recover the `cmd_entry` (and thus `port_id`, `axi4_id`, `beats`, `resp`), copies
the timing/data in, and calls `fes[port_id].complete(entry)`. The FE matches by
`axi4_id` via its per-ID FIFOs (mandatory same-ID order) and drives B/R.

**Ownership & connections.** The backend owns `cmd_queue`, `refresh`, the input
FIFOs, and the `fes[]` base handles (set by `register_port`, §8.7 step 3) —
address decode is a free function (`vip_dram_addr_pkg` / `vip_mc_addr_pkg`, §8.3),
not an owned object. It makes the producer→arbiter connections in its
**own** `connect_phase`:

```sv
// vip_mc_backend::connect_phase
foreach (fes[i]) fes[i].req_port.connect(fe_req_export[i]); // = fe_fifo[i].analysis_export
refresh.req_port.connect(ref_req_export);                   // = ref_fifo.analysis_export
```

`vip_mc` (top) holds the `dram` handle and makes only the two device-boundary
connections (§8.7) plus the blocking `dram.reset()` task in its `run_phase` reset
path (§9).

### 8.10 `vip_mc_env_cfg` (uvm_object) — system-config aggregator

The user-facing topology object (§2.2). Parameterized by the same triple as
`vip_mc` (`#(DRAM_CFG_P, N_PORTS, PORTS[])`) so their types match; the TB fills
one instance and `apply()`s it.

| Field / method                | Type                                     | Notes                                                                                          |
|-------------------------------|------------------------------------------|------------------------------------------------------------------------------------------------|
| `cfg`                         | `vip_mc_config`                          | **Owned** (created in `new()`). The shared MC knobs + `cfg.axi4` + the per-port runtime map `cfg.ports[]` (§8.1, §2.1). |
| `dram`                        | `vip_dram #(DRAM_CFG_P)`                 | TB-owned device handle, carried (not owned) — §2 rule 4. `validate()` requires it non-null.     |
| `status_vif`                  | `virtual vip_mc_status_if #(N_PORTS)`    | Optional debug-only waveform probe handle (§8.8A). Controller-global, homogeneous across ports, and therefore stored directly with no holder class. May be null. |
| `vif_h [N_PORTS]`             | `vip_mc_vif_holder`                      | Per-port type-erased vif holders; `register_vif(k,h)` sets one. `validate()` requires all bound.|
| `register_vif(port_id, h)`    | `function void`                          | "Connect your IF here." Stores `h` at `vif_h[port_id]`; asserts `h.proto == PORTS[port_id].proto`.|
| `apply(ctxt, inst)`           | `function void`                          | Single `uvm_config_db #(vip_mc_env_cfg #(...))::set(ctxt, inst, "env_cfg", this)` — the one handoff `vip_mc::build_phase` reads (§8.7 step 1). |
| `validate()`                  | `function void`                          | Calls `cfg.validate()`; checks `dram` set, every `vif_h[]` bound with matching `proto`, and each `cfg.ports[k]` region ⊆ device geometry. `uvm_fatal` on failure. |

Helper types (same file): `vip_mc_vif_holder` (virtual base, carries `proto`)
and the per-protocol `vip_mc_axi4_vif_holder #(AXI4_CFG_P)` carrying the
concrete `virtual vip_mc_axi4_if #(AXI4_CFG_P)` (§2.2). `vip_mc` resolves a
holder by constant-index `$cast` per port (§8.7 step 3). The status probe
needs no analogous holder because its type depends only on `N_PORTS`. A
`vip_mc_ports(...)` free function that builds `PORTS[]` from per-protocol counts
is a convenience for the homogeneous-ish case.

---

## 9. Reset & lifecycle

`vip_mc::run_phase` watches `@(negedge vif.rst_n)` on its own
`vip_mc_axi4_if` directly. On assertion it calls the `handle_reset()` **task**
(it runs in this `run_phase` task context), then waits for `@(posedge vif.rst_n)`
and re-arms the driver / refresh forks.

```text
negedge rst_n on vip_mc_axi4_if
    │
    ▼
vip_mc::handle_reset()
    │
    ├──► foreach fe[i]: fe[i].handle_reset()
    │     (drive AWREADY/WREADY/BVALID/ARREADY/RVALID to '0,
    │      flush per-channel same-ID FIFOs,
    │      cancel half-built write entries that haven't seen WLAST)
    ├──► backend.flush()             (quiesce the arbiter task + reset _rr; drain
    │                                 the input FIFOs; flush the owned cmd_queue;
    │                                 refresh.flush() — kill fork, reset tREFI ctr)
    ├──► clear all §8.8 perf counters
    └──► dram.reset()  (BLOCKING task: triggers reset_event and waits on the
                        device's reset_done_event — the device cancels its forked,
                        time-delayed responses and drains BEFORE this returns —
                        vip_dram §7.5/§8, B5)
```

`handle_reset()` is a **task** on `vip_mc`, invoked from `run_phase` (a task
context). It calls the device's **blocking** `dram.reset()` task and waits for it
to return: `dram.reset()` triggers `reset_event` and blocks on the
(device-private) `reset_done_event` until the device's consumer has `disable
fork`-ed its in-flight responses and drained (vip_dram §8). Because `vip_mc` does
**not** re-arm the FE / refresh forks (and accepts no post-reset AXI4 traffic)
until `dram.reset()` has returned **and** `@(posedge vif.rst_n)` is seen,
post-reset traffic cannot race the device's drain/restart boundary — the ordering
is guaranteed, not merely probable. (vip_dram still exposes `reset_event` for a
non-blocking trigger, but `vip_mc` deliberately takes the blocking task.)

**Manager-observable reset contract (reset-semantics feedback).** Because the
device discards every in-flight response on reset, the AXI4 manager must
observe a clean, well-defined boundary — stated here as part of the formal
contract:

- No `B`/`R` completion is driven for any transaction outstanding when reset
  asserts (their cmd-queue entries are flushed and the device's responses are
  cancelled).
- A write whose burst was partially accepted (AW seen, `WLAST` not yet) is
  discarded; no `vip_dram_req` is emitted for it.
- After reset deasserts, the manager is responsible for reissuing anything it
  still needs — `vip_mc` does not replay dropped transactions.

Notes:

- `vip_mc` (top) owns the authoritative `dram` handle for wiring and reset, and
  passes it into the backend so backend-side FR-FCFS ranking can call
  `dram.predict()` at the single pre-issue arbitration point.
- No clock signal is required at the MC↔device boundary — neutral TLM
  is timed against `$realtime` (ns), matching `vip_dram`'s `realtime` ready times.
- Multi-agent environments that share `rst_n` may centralize the watch in a
  TB-provided reset coordinator; `vip_mc` then takes its reset cue from that
  instead of watching `vif.rst_n` inline. This is opt-in and uses **no**
  `vip_axi4_*` component (single-agent TBs use the inline watcher above).
- Refresh fork re-arms automatically on the next `posedge rst_n`.

---

## 10. Verification of the model itself

Tests in §10 are the **MC-core subset**. `vip_mc`'s only stimulus
surface is AXI4 — it has no top-side TLM/sequence injection port into
the cmd queue, and adding one is explicitly out of scope (it would be a
second, untested input path that fights the §1/§2 "AXI4 SUB responder"
architecture). So §10 uses the **same** `vip_axi4_agent` MANAGER as §13;
there is no manager-less mode. The distinction is env weight and
assertion focus, not topology:

- **§10 (core)** — a thin env (manager agent + `vip_mc` + `vip_dram`,
  no coverage collector, minimal scoreboard) running directed
  sequences, asserting against `dram.predict()` and the §8.8 internal
  counters. Fast; pinpoints regressions to the MC core. Refresh is
  observed via `dram.get_refresh_count()` (it is internally timed, not
  driven).
- **§13 (system)** — the full reference TB: manager agent, full
  latency/data scoreboard, coverage, the complete test list.

The two layers may exercise the same feature (e.g., refresh cadence) at
different env weights; the §10 version is the lean regression-pinpoint
form. (Several §10 cases are already labelled "lower-level mirror of
§13.3 case N"; this confirms the shared manager-driven mechanism.)

Self-checking contract tests live in
`testbench/sv/`. Mismatches outside a 1-cycle
tolerance are `uvm_error`. Required tests:

1. **Refresh emission cadence** (lower-level mirror of §13.3 case 3) —
   observe `dram.get_refresh_count()` over `N * tREFI`; count must
   equal `N * n_ranks` within ±1. Cross-check `mc.get_refresh_count()`
   agrees with `dram.get_refresh_count()` (M5).
2. **Address-decode DECERR** (lower-level mirror of §13.3 case 4) — call
   `cfg.axi4.add_decerr_range(lo, hi)`, issue accesses straddling the
   boundary; verify `bresp/rresp == DECERR` inside the unmapped region and
   `OKAY` outside.
3. **Emergent inter-ID reorder, same-ID order guard** (lower-level mirror
  of §13.3 case 5; renamed from the misleading "OOO same-ID delivery") —
  issue interleaved different-ID requests where a later row hit is selected
  ahead of an earlier miss by the backend's FR-FCFS / miss-queue policy.
  Verify per-ID RDATA/BID order is **preserved** while **inter-ID** order
  shuffles, and keep a companion A/B case with `fr_fcfs_enable = FALSE` to show
  the reorder comes from the pre-issue selector rather than the device alone.
4. **Grant-order / same-ID ordering** (Q3) — drive **both** a same-ID stream and
   a different-ID stream **concurrently in flight** (single QoS class, so grant
   order is pure FCFS), and verify: same-ID B/R complete in AW/AR arrival order
   (the mandatory guarantee, even when the device finishes them OoO), and the
   arbiter's grant order — the monotonic `_tag_ctr` (QoS class + aging,
   round-robin within a class; §8.9), **not** `enqueue_time` (which can tie) — is
   preserved end-to-end through the tag-demuxed completion path. Reference the
   §5.2 split.
5. **Page-hit throughput via MC** (lower-level mirror of §13.3 case 2) —
   manager stimulus issues a 64-beat INCR read to consecutive cols of one
   row; throughput is governed by `tCCD_L` per DRAM column access (**not**
   `tBL`, M2), and the observed AXI4 timing matches `dram.predict()` within
   1 cycle.
6. **Reset mid-flight** (lower-level mirror of §13.3 case 9) — assert
   reset while N transactions are in flight; verify cmd-queue drains,
   B/R never fire post-reset (manager-observable contract, §9), and a
   post-reset transaction completes cleanly.
7. **QoS-class scheduling** — drive mixed-`AxQOS` traffic with several in flight;
   via the `issued_port` grant tap (§13.2) verify higher-class requests are issued
   ahead of older lower-class ones while same-ID order holds and refresh still
   pre-empts all. With `qos_class_count = 1` the issue order reverts to FCFS (the
   A/B check).
8. **Aging / anti-starvation** — a saturating high-class stream plus one starved
   low-class request; verify the low-class request is promoted and issued within
   ~`qos_aging_ns` of waiting (it never starves).
9. **Finite-buffer backpressure** — (a) fill `w_data_buf_depth`; verify `wready`
   actually toggles and `get_wready_stall_cycles()` moves. (b) stall
   `BREADY`/`RREADY` to exhaust `rsp_buf_depth`; verify request issue stops, then
   `AWREADY`/`ARREADY` deassert and `get_rsp_buf_full_cycles()` moves; releasing
   the master drains cleanly. `0`-depth config shows the legacy no-backpressure
   behavior.
10. **Exclusive access** — exclusive read then exclusive write to a still-valid
    reservation → `EXOKAY` and memory updated; an intervening normal write to the
    region makes the exclusive write return `OKAY` with memory unchanged (§4.6);
    `get_exokay_count()` / `get_excl_fail_count()` track.
11. **Burst-type & narrow / unaligned mapping** — `WRAP` and `FIXED` bursts, a
    narrow `AxSIZE`, and an unaligned base; verify the column-access sequence and
    `wstrb`-masked data round-trip match the address iterator (§4.6, §5.6) against
    `dram.backdoor_read`.
12. **Concurrent multi-ID reads** — several in-flight reads with distinct
    `ARID`s; verify each completes with correct data. AXI4 has no read-data
    interleaving, so each burst's beats return contiguously (one active burst at
    a time) while same-ID order holds.
13. **Telemetry sanity** — a mixed hit/miss + backpressure run; verify
    `get_row_hit_rate()`, `get_predict_accuracy()` (≈0 error vs the scoreboard),
    and `get_effective_bandwidth()` / `get_bus_utilization()` track expected
    values (§8.8, item 11).

### 10.1 CHI verification path

The CHI bring-up reuses the **`vip_chi` agent** for stimulus and checking rather
than hand-writing a CHI BFM (CHI decision 7). All three stages run in the single
`testbench/sv` example. The staging is:

1. **Direct-interface contract env first** — drive `vip_mc`'s SN
  `vip_mc_chi_if` from a **`vip_chi` agent in RN-I role**, bridged by a
  `vip_mc_chi_connect` connector (the exact symmetric of the AXI4 example:
  `vip_axi4_agent` MANAGER + `vip_mc_axi4_connect`, §13). This is sound because
  `vip_chi_if` is role-gated — two instances (the RN-I source + our SN), bridged
  through the `rni`/`snf` raw-signal modports, never one shared role-gated IF
  (B1). No top-side TLM shortcut, no cmd-queue injection port. The `vip_chi`
  monitor / SVA / coverage come along as a free checker. Directed tests cover
  link bring-up, credits, `ReadNoSnp*` / `WriteNoSnp*`, response/data returns,
  DECERR, and unsupported-op rejection.
2. **Per-issue matrix second** — run the same directed suite twice: once with
  `VIP_MC_CHI_ISSUE_D_E`, once with `VIP_MC_CHI_ISSUE_E_E`. Shared tests prove
  the common memory-target subset; issue-delta tests prove that D-only/E-only
  legality checks stay in the CHI layer and do not leak into the backend.
3. **Protocol-equivalence tests third** — a protocol-neutral golden model
  (`mc_equiv_model`) and one deterministic program (`mc_equiv_program`)
  are replayed through AXI4, CHI-D, and CHI-E fronts (`tc_mc_equiv_axi4` /
  `_chi_d` / `_chi_e`), each checked against a fresh model. All three matching the
  same model proves byte-identical device state and read data across the
  protocols. (Timing/grant-order equivalence stays out of scope here — the
  self-contained CHI envs use their own device, and the AXI4 `mc_scoreboard`
  checks timing against `dram.predict()` on its side.)

---

## 11. Advanced scheduling, ECC, and future directions

The features in §11.1–§11.3 are part of the design, each gated behind a config
knob that defaults off so the deterministic first-cut behavior is unchanged unless
a test opts in. §11.4 catalogs directions deferred to future work.

### 11.1 Readiness-aware scheduling (FR-FCFS)

The base backend queue is a QoS/aging issue queue, not a readiness-aware miss
queue. Once an entry is picked and written to `vip_dram`, the device commits that
request's command/data timing immediately; later requests compute against the
updated state and, with bus contention enabled, cannot bypass the already-reserved
data-bus window. So the familiar real-controller story — "a hit behind a miss
finishes first" — happens only if the controller chooses the hit **before** the
miss is issued.

**No second queue object is required.** The existing `cmd_queue` already holds
multiple pending requests, so it serves as the controller's effective miss queue.
What differs is not storage but the *selection policy* over that storage: keep one
shared queue and change only the **within-class tie-break** from FCFS to
readiness-aware selection.

**Where the ranking lives.** The backend owns the FR-FCFS ranking, because it
already owns the sole device-issue point (`req_port.write()`) and the
response-credit / refresh / per-port fairness context that must remain part of the
final issue decision. It reaches the predictor through the injected `vip_dram`
handle. `cmd_queue` continues to own admission, aging, same-ID blocking, and tag
lifecycle — there is no standalone `miss_queue` object; the queue is promoted into
miss-queue behavior by teaching the backend to compare multiple eligible entries
before issue.

**Arbitration shape** (behind `cfg.fr_fcfs_enable`). The pick path is:

  1. Choose the highest **effective** QoS class exactly as the base policy does
    (base class + aging promotions, capped at the top class).
  2. Ask `cmd_queue` for the set of **currently eligible** entries in that class:
    same-ID-safe, not refresh, not yet tagged, and not blocked by older queued or
    inflight siblings.
  3. For each candidate, build a temporary `vip_dram_req` snapshot and call
    `dram.predict()` at the current `$realtime`. Every candidate is evaluated
    against the *same* live device state, answering the exact question: "if I
    issued *this* request next, when would it complete?"
  4. Rank candidates by predicted ready/completion time, using the smallest
    predicted `last_beat_ready_time` as the FR-FCFS key. Ties stay deterministic:
    older `admit_order` first, then the RR/port tie-break.
  5. Remove only the winning candidate from the queue, assign the flat tag, and
    write it to `req_port`.

**Invariants.** FR-FCFS may change *which* request wins within one class, but it
preserves every outer rule: same-ID ordering stays absolute; refresh stays strict
priority; QoS class precedence and aging are unchanged; response-credit gating
still stops issue when no slot is free; the final pick stays deterministic for
identical predictions.

**Predict-ordering rule.** `dram.predict()` is valid here because it is
side-effect free and defined relative to the **next issue point**. FR-FCFS uses it
only to compare candidates for the *single next issue*, never to simulate a whole
future schedule. Once the winner is issued, the next pick re-evaluates the
remaining queue against the newly committed device state.

**Backlog dependence.** FR-FCFS only matters when more than one issue-eligible
request waits in `cmd_queue`. That requires backlog — in practice a finite
`max_inflight_to_device` (geometry-derived by default) or any other condition that
prevents immediate drain of every admitted request. With an unbounded device
window and traffic that never queues, there is nothing to reorder.

**Reads vs writes.** The selector compares reads and writes with the same
predicted-`last_beat_ready_time` heuristic because the candidate set is
op-agnostic: across reads and writes in the same effective QoS class, the backend
prefers the candidate with the smallest predicted completion time. This is the
intended first-cut policy, exercised by the mixed RD/WR FR-FCFS testcase.

**Fairness cap** (`cfg.fr_fcfs_starvation_cap`, default `0` = unbounded / pure
FR-FCFS). The raw readiness heuristic can starve an older page miss behind a
younger page-hit streak. The cap bounds this: each pick that serves a readiness
winner charges one bypass to every older eligible entry, and once an entry has
been bypassed `cap` times the selector force-serves the oldest such entry (an FCFS
override) instead of the winner — capping each request's reordering to at most
`cap` bypasses. It is a within-class bound, orthogonal to `qos_aging_ns` (which
promotes across classes); overrides are counted by `get_fr_fcfs_forced_count()`
and exercised by `tc_mc_fr_fcfs_starvation_cap`.

**Turnaround-aware grouping** (`cfg.rd_wr_grouping_enable`, default `FALSE`).
Predicted-completion ranking is already *implicitly* turnaround-aware — a
same-direction candidate predicts sooner than a direction-flipping one whenever the
device applies a tWTR/tRTW bubble — so pure readiness-first never voluntarily
flips. The one case it *does* flip is when staying in-direction requires a page
miss while the opposite direction has a cheaper hit: greedy readiness then flips
the bus (paying a turnaround) to shave a single request's latency, even though
draining the same-direction run first would amortize the bubble over a longer
batch. With grouping enabled, bus-direction becomes the PRIMARY within-class key:
the selector prefers the eligible candidate whose direction matches the last
issued command's, the readiness key (predicted last beat, then `admit_order`)
decides within a direction, and the pure readiness winner is the fallback when no
same-direction candidate is eligible (an unavoidable flip). This is the classic
write-drain trade — a little per-request latency for bus throughput.
`cfg.rd_wr_grouping_max` (default `0` = unbounded run) inverts the preferred
direction after that many consecutive same-direction issues so the opposite
direction cannot be starved (a within-direction bound distinct from
`fr_fcfs_starvation_cap`). Issued RD↔WR turnarounds are counted by
`get_bus_turnaround_count()` and grouping overrides of the readiness winner by
`get_rd_wr_grouped_count()`; exercised by `tc_mc_rd_wr_grouping`.

`tc_mc_axi4_ooo_inter_id` is the grey-box demonstration: precondition one request as a
miss and another as a hit, keep both in the queue together behind a held device
window, and verify the backend grants the hit first and the AXI responses follow
that device-timing-driven reorder. (`vip_mc_refresh` reserves a slot for
coordinating postponed refreshes with FR-FCFS picks.)

### 11.2 Write coalescing (`cfg.write_coalescing_enable`, default `FALSE`)

A newly admitted write merges into the newest outstanding same-stream
(`{port,id,WR}`) pending write to the same row-word address, overlaying byte lanes
(newer wins), and the one device response fans out a completion to every merged
host write (`vip_mc_cmd_queue::try_coalesce_write` / `overlay_write`; backend
`write()` fan-out; `get_coalesced_write_count`). Exercising it needs two same-line
writes co-pending, which the `vip_axi4` manager produces only via its pipelined
write path (`cfg.wr_outstanding_max > 1`, see the vip_axi4 agent).
`tc_mc_axi4_write_coalesce` drives two same-line writes concurrently via
`vip_axi4_pipelined_seq` (`set_pipelined_send`) behind a held device window and
checks one device write grant + two BRESPs + correct overlay. The scoreboard is
coalescing-unaware (one device access completes two host writes), so it is off in
that test. Future extensions: contiguous-address extend (grow `beats`) and
same-page different-column batching beyond same-address write-combining.

### 11.3 ECC and error modeling

Error behavior is modeled where the physics lives, not as a bare controller knob.
Two layers make up the design:

  (a) **Device faults** are a deterministic, addressable read-fault map in
  `vip_dram` (`inject_fault()` / `clear_fault()` / `clear_all_faults()` /
  `get_fault()`), carried on the response as `vip_dram_rsp.injected_fault`
  (`vip_dram_fault_e`: NONE / CORRECTABLE / UNCORRECTABLE) — **not** probabilistic
  bus injection. The device physically corrupts a faulted beat: CORRECTABLE flips
  one bit and records it in `vip_dram_rsp.corrupt_mask` (the SECDED-repairable
  syndrome), UNCORRECTABLE flips two bits and leaves a zero mask (unrepairable).

  (b) A **64+8 SECDED layer** in `vip_mc` (gated by `cfg.ecc_enable`, default off)
  repairs and classifies each completed read: it un-flips `corrupt_mask` so a
  CORRECTABLE beat is restored byte-for-byte and stays OKAY, while an UNCORRECTABLE
  double-bit error keeps its poisoned bytes and becomes a bus `SLVERR`, with
  `get_ecc_corrected_count()` / `get_ecc_uncorrectable_count()` tallies. With ECC
  off the corrupted bytes pass through as OKAY (silent data corruption). See
  `tc_mc_ecc_slverr`.

Decode errors (`DECERR`) are not part of this — they are real MC behavior modeled
in §4.3/§4.4. Probabilistic bus-level injection stays excluded by design. Deferred
within this area: partial-write read-modify-write ECC, and a fault-injection veneer
*above* the MC for system tests.

### 11.4 Future directions

- **Multi-channel** — multiple `vip_dram` instances behind one `vip_mc` with a
  channel hash on the address. First cut is single channel; the channel-hash helper
  is reserved for `vip_mc_addr_pkg` (§8.3).
- **DFI face** — a sibling adapter that translates DFI command-level stimulus into
  the same neutral TLM. The device does not change; `vip_mc` becomes one of two
  upward faces.
- **Sub-channel / pseudo-channel-aware dispatch** — generalizes multi-channel: a
  DDR5 dual-sub-channel or GDDR6 pseudo-channel addr-map policy that routes each
  request to the right `vip_dram` instance. Controller-side counterpart of the
  protocol-family roadmap in vip_dram §10.1.
- **Dynamic timing retune wrapper** — a `vip_mc` operation that drains in-flight
  work, calls the device's future `update_timing_preset()` (vip_dram §10.1), and
  re-caches `tREFI`, modeling an operating-point change with no new interface. This
  is a behavioral approximation — real DFS is an MRW + retraining command sequence.

**Tier 1 / Tier 2 roadmap.** The protocol-family presets, refresh variants, EDC,
and all command/PHY/training/pin features (Tier 2, gated on a future JEDEC-command
/ DFI / pin face) are catalogued once in **vip_dram §10.1**; the controller-side
items above are their Tier-1 counterparts. Bus-level probabilistic fault injection
stays **excluded by design** (§4.3, §11.3).

---

## 12. Implementation order

1. `vip_mc_axi4_types_pkg.sv` (OWN `vip_mc_axi4_cfg_t`, `vip_mc_axi4_types
   #(CFG_P)`, resp/burst/size consts — no `vip_axi4_*` import).
2. `vip_mc_axi4_if.sv` (OWN controller-side interface, single clocking block).
  When the §8.8A probe is enabled, analyze `vip_mc_status_if.sv` here too —
  same global-scope / pre-package rule.
3. `vip_mc_types_pkg.sv` (op tags, tag-prefix consts, REF discriminant,
   region descs, `vip_mc_refresh_policy_e`).
4. `vip_mc_cmd_entry.sv` (the §5.1 typedef; completion fields live
   in-place).
5. `vip_mc_config.sv` (owns the `axi4` child), `vip_mc_axi4_cfg.sv`
  (native knobs + `validate()`), `vip_mc_env_cfg.sv` (§2.2 system-config
  aggregator + optional `status_vif` handle + `vip_mc_vif_holder` types — a
  config leaf; needs only `vip_mc_config` + `vip_mc_axi4_if`, and when the
  probe is enabled also `vip_mc_status_if`, so build it any time before
  `vip_mc`), and `vip_mc_status_snapshot.sv` (optional debug-only shared
  snapshot container for §8.8A; no functional contract).
6. *(reserved future extraction)* `vip_mc_addr_pkg.sv` (a standalone
  free-function package for MC-specific addr helpers; the current slice keeps
  those helpers inline in `vip_mc_axi4_driver`, §8.3).
7. `vip_mc_cmd_queue.sv` (QoS priority-class queue + aging `admit`/`pick`, flat
   tag-counter map, demux, perf counters; §8.4).
8. `vip_mc_refresh.sv` (`tREFI` timer with cached value, periodic REF
   emission, `#0`-delta guard).
9. `vip_mc_fe_base.sv` (abstract per-port front-end: `req_port`, `port_id`,
   `pure virtual complete(entry)` — the base handle the backend holds, §2.1).
10. `vip_mc_backend.sv` (`#(DRAM_CFG_P, N_PORTS)` — the single serialization
  point, §8.9: per-producer input FIFOs behind `fe_req_export[N_PORTS]` /
  `ref_req_export`; the arbiter task (QoS-class + aging, weighted round-robin
  across ready FE ports, refresh strict priority, response-buffer credit
  gating, §8.9) that
    assigns the flat tag, stamps `enqueue_time`, enqueues `cmd_queue`, taps
    `issued_port`, and is the sole writer to `dram.req_fifo` via `req_port`; the
    `rsp_subscriber`
    that demuxes `dram.rsp_port` by `cmd_entry.port_id` →
    `fes[port_id].complete()`. Owns `cmd_queue`, `refresh` (decode via the
    `vip_dram_addr_pkg` helpers plus FE-local burst geometry helpers, §8.3, not
    an owned object);
    makes their connections in its own `connect_phase`).
11. `vip_mc_axi4_driver.sv` (AXI4 front-end extending `vip_mc_fe_base` —
    controller-side protocol: fork per channel, beat↔column packing (incl.
    WRAP/FIXED + narrow/unaligned, §5.6), finite W-data backpressure (§4.5),
    exclusive monitor + EXOKAY, USER passthrough (§4.6), DECERR
    (region + 4 KB) check, device-timed B/R via the backend-delivered
    `complete(entry)` with per-ID same-ID FIFOs; emits its cmd_entry to the
    backend via `req_port`, holds no direct `dram` handle).
12. `vip_mc.sv` (top component — builds the `N_PORTS` front-ends + the backend,
    sources config from the `env_cfg` aggregator (or the discrete
    `vif`/`dram`/`status_vif` keys, §8.7 step 1), wires `backend.req_port ↔
    dram.req_fifo` and `dram.rsp_port ↔ backend.rsp_subscriber`, owns reset
    choreography, and when enabled mirrors the §8.8A status snapshot onto the
    optional `status_vif` from exactly one publisher).
13. *(optional glue)* `vip_mc_axi4_connect.sv` (optional bridge to
  `vip_axi4_if`, for the stock-manager example only).
14. Contract tests §10 under `testbench/sv/`.
15. README, `.svh`, and FuseSoC core manifests.

**Keep it compiling at every step.** `vip_mc_pkg` is a single package that
`` `include ``s every class file, and a SV package fails to analyze until *all*
its included files exist and every referenced symbol resolves. So the build stays
green mid-implementation only if the include list and the file manifest grow
deliberately:

- Bring `vip_mc.svh`, the FuseSoC core manifest, and a `vip_mc_pkg.sv` skeleton to the
  front (before step 1) rather than deferring them to step 15, and grow them by
  exactly one entry per step as each file is written.
- Run a compile/elaborate smoke check after each of steps 4–12 (elaborate
  `vip_mc_pkg` against a do-nothing `vip_mc` top stub until the real top exists),
  so a break is caught at the step that caused it.
- Ordering within step 5: `vip_mc_config` owns the `axi4` child, so
  `vip_mc_axi4_cfg.sv` must be `` `include ``d **before** `vip_mc_config.sv`; and
  `vip_mc_env_cfg` needs `vip_mc_config` + `vip_mc_axi4_if` already analyzed.

The rest of the dependency chain is already correct for incremental compile:
`cmd_entry` (4) → `fe_base` (9, holds `analysis_port#(cmd_entry)`) → `backend`
(10, holds `fe_base[]`, uses `cmd_queue`/`refresh`/`addr_pkg`) → `axi4_driver`
(11, extends `fe_base`) → `vip_mc` (12).

**CHI-port steps (§1 CHI decisions).**
The `vip_mc_fe_base` seam (step 9) is what lets these be added without
reordering or touching the back-end:

- **C1.** `vip_mc_chi_if.sv` — owned single-role SN interface (no `ROLE_P`, B1),
  consuming `vip_chi_types_pkg`. Analyzes before `vip_mc_pkg` (like the AXI4 IF).
- **C2.** `vip_mc_chi_driver.sv` — CHI front-end extending `vip_mc_fe_base`,
  reusing `vip_chi_driver_snf` flit-handling as algorithms (the symmetric of
  step 11). Maps the thin `vip_mc_chi_cfg_t` → `vip_chi_cfg_t` at its boundary.
- **C3.** `vip_mc_chi_connect.sv` — optional bridge to a `vip_chi` RN-I manager
  for stimulus (symmetric of step 13).
- **C4.** CHI contract + per-issue (D/E) + AXI4/CHI equivalence tests (§10.1),
  reusing the protocol-agnostic scoreboard taps.

---

## 13. Example testbench

Lives in `testbench/sv/`. Drives a full
manager → `vip_mc` → `vip_dram` system over AXI4. The manager is a
standard `vip_axi4_agent` in `MANAGER` role driving its **own**
`vip_axi4_if #(.., MANAGER)` instance; `vip_mc` owns a **separate**
`vip_mc_axi4_if` instance. The `vip_mc_axi4_connect` module cross-wires the
two (all five channels, explicit `assign`s — the
[`axi4_tb_top.sv`](../examples/vip_axi4_agent/tb/axi4_tb_top.sv) pattern).
This is **two interface instances, bridged** — never one shared role-gated
interface (B1). Each agent fetches its own vif handle from the config DB (the
manager gets `man_vif`; `vip_mc` gets `mc_vif`). The TB owns the `vip_dram`
instance and passes the `dram` handle to `vip_mc` via the config DB (§8.7).

The example is the *only* place the AXI4 VIP appears, and only because it
reuses the stock manager for stimulus; `vip_mc_pkg` itself has no such
dependency (§1, §2 rule 1).

### 13.1 Directory layout

```text
testbench/sv/
├── tb/
│   ├── tb.svh
│   ├── mc_tb_pkg.sv
│   ├── mc_tb_top.sv                 (clk_rst_if + vip_axi4_if man_vif +
│   │                                     vip_mc_axi4_if mc_vif + optional
│   │                                     vip_mc_status_if status_vif +
│   │                                     vip_mc_axi4_connect)
│   ├── mc_tb_env.sv                 (clk_rst_agent + man_agent[] + vip_mc +
│   │                                     vip_dram + mc_scoreboard +
│   │                                     env_cfg.status_vif handoff)
│   └── mc_scoreboard.sv                 (predictor-vs-observed AXI4 latency)
├── tc/
│   ├── mc_tc_pkg.sv
│   ├── mc_base_test.sv
│   ├── tc_mc_axi4_agent.sv          (AXI4 front-end behavior tests:
│   ├── tc_mc_axi4_burst.sv           tc_mc_axi4_<feature> — bursts,
│   ├── tc_mc_axi4_exclusive.sv       exclusive, backpressure,
│   ├── …                                 outstanding limits, reject, …)
│   ├── tc_mc_cfg.sv                 (MC-level tests: tc_mc_<feature> —
│   ├── tc_mc_refresh.sv              cfg, refresh, reset-recovery,
│   ├── tc_mc_multi_rank.sv           multi-rank, qos, preset-sweep,
│   ├── tc_mc_status_probe.sv         status-probe, telemetry, …)
│   └── tc_mc_telemetry_counters.sv
```

There is no separate virtual-sequencer component: the base test drives the stock
manager agents directly and does inline observation, while `mc_scoreboard`
provides the predictor-vs-observed latency check (§13.2). Clock and reset are
owned by a `clk_rst_agent` in `mc_tb_env` (driven by a `reset_sequence`
started from `mc_base_test::run_phase`), not by hand-rolled logic in the top.

File naming: testbench support files use the `mc_` prefix (`mc_tb_env.sv`,
`mc_tb_top.sv`, `mc_scoreboard.sv`, ...), AXI4-front-end tests use
`tc_mc_axi4_<feature>.sv`, and MC-level tests use `tc_mc_<feature>.sv`; class
names match file names.

**`mc_tb_top` interface wiring (B1).** The top instantiates two interfaces on
the shared `clk_rst_if` and bridges them with the connector:

```sv
clk_rst_if                                              clk_rst_vif();
vip_axi4_if    #(VIP_MC_AXI4_CFG_C, VIP_AXI4_ROLE_MANAGER_E)
                                                        man_vif(clk_rst_vif.clk, clk_rst_vif.rst_n);
vip_mc_axi4_if #(VIP_MC_AXI4_CFG_C) mc_vif(clk_rst_vif.clk, clk_rst_vif.rst_n);
vip_mc_status_if #(1) mc_status_vif(clk_rst_vif.clk, clk_rst_vif.rst_n); // optional §8.8A probe

// cross-wire all five channels (AW/W/B/AR/R) — the axi4_tb_top.sv pattern
vip_mc_axi4_connect #(VIP_MC_AXI4_CFG_C) i_connect (.man(man_vif), .mc(mc_vif));

// hand each agent its OWN vif (two instances, never shared):
uvm_config_db #(virtual vip_axi4_if #(VIP_MC_AXI4_CFG_C, VIP_AXI4_ROLE_MANAGER_E))
  ::set(null, "uvm_test_top.env.man_agent*", "vif", man_vif);
uvm_config_db #(virtual vip_mc_axi4_if #(VIP_MC_AXI4_CFG_C))
  ::set(null, "uvm_test_top.env.vip_mc_inst*", "vif", mc_vif);
```

If the optional status probe is used, the preferred handoff is through
`env_cfg.status_vif = mc_status_vif`; the fallback path is one direct config-DB
key such as `"status_vif"` for `vip_mc` to resolve in `build_phase`.

`vip_mc_axi4_connect` is a thin module of `assign`s (manager AW/W/AR → mc;
mc B/R + `*ready` → manager), tying off USER/sideband the MC does not model.

**Multi-port configuration (§2.1) — worked examples.** The TB picks the port
count + per-port protocol via the `PORTS[]` table and instantiates one host
interface (and, for AXI4, one connector + stock manager) per port. The
back-end and `vip_dram` are unchanged across these.

```sv
// ---- "2x AXI4" : two AXI4 host ports into one device ----
localparam int               N_PORTS = 2;
localparam vip_mc_port_cfg_t PORTS [2] = '{
  '{ proto: VIP_MC_PROTO_AXI4_E, axi4: VIP_MC_AXI4_CFG_C, chi: '0 },
  '{ proto: VIP_MC_PROTO_AXI4_E, axi4: VIP_MC_AXI4_CFG_C, chi: '0 } };
// per-port host IFs + connectors (one each):
vip_mc_axi4_if #(VIP_MC_AXI4_CFG_C) mc_vif0(clk, rst_n), mc_vif1(clk, rst_n);
// ... vip_mc_axi4_connect + stock manager per port
vip_mc #(.DRAM_CFG_P(VIP_DRAM_CFG_C), .N_PORTS(2), .PORTS(PORTS)) u_mc(...);
// config (in the env/test build_phase): fill ONE vip_mc_env_cfg #(.,2,PORTS),
// register_vif(0,h0)/register_vif(1,h1), env_cfg.apply(...) — §2.2. No per-port
// "vif_portK" string keys.

// ---- "1x AXI4 + 1x CHI" (tc_mc_mixed_concurrent; D or E in PORTS_MIX[1].chi.issue) ----
// NOTE: MIXED_PORTS_C fills BOTH .axi4 and .chi on every entry
// (representative-cfg convention, §2.1) — the '0 stubs below are schematic only.
localparam vip_mc_port_cfg_t PORTS_MIX [2] = '{
  '{ proto: VIP_MC_PROTO_AXI4_E, axi4: VIP_MC_AXI4_CFG_C, chi: '0            },
  '{ proto: VIP_MC_PROTO_CHI_E,  axi4: '0,               chi: VIP_MC_CHI_CFG_C } };
// port 0: vip_mc_axi4_if (+connector); port 1: vip_mc_chi_if. Same vip_mc/back-end.
```

The `case (PORTS[i].proto)` in `vip_mc::build_phase` (§2.1) creates the right
front-end per port; only the `PORTS[]` table and the per-port host interface
differ between the two configs.

### 13.2 What the scoreboard checks

The scoreboard checks **timing** against `dram.predict()` and **data** against
the device backdoor. The correctness rule (§5.6) is that `predict()` is defined
against **device-ingress order** — the arbiter's grant order — *not* AXI4
acceptance order, and that order includes **REF**, which is invisible on the AXI4
bus yet advances device state. Predicting per monitored AXI4 transaction (the
naïve recipe) mispredicts under refresh, multi-port arbitration, and same-`$time`
accepts, so the scoreboard predicts off the backend's grant-order tap instead:

1. **Predict in grant order.** Subscribe to `backend.issued_port` (the
   grant-ordered `vip_mc_cmd_entry_t` stream with IDs attached, REF included —
   §8.9). On each tapped entry build the equivalent `vip_dram_req` and call
   `dram.predict(req, first, last)` **in tap order**, storing the expected
   `first/last_beat_ready_time` keyed by `tag` (and `axi4_id` for the bus match).
   REF entries are predicted too, so a transaction after a refresh predicts
   correctly. `predict()` mutates nothing, so calling it in lock-step with the
   device's ingress sees the same committed state the device will.
2. **Correlate to the bus.** Subscribe to the manager monitor
   (`bresp_port` / `rdata_port` / …) and match each observed B/R to its predicted
   entry by `axi4_id` + per-ID arrival order (same-ID order is guaranteed, §5.2),
   recovering the `tag`.
3. **Check timing.** Compare observed B/R timing to the predicted times within a
   tolerance window for AXI4 handshake overhead (typically 1-2 cycles).
4. **Check data.** Compare observed RDATA against device storage via
   `dram.backdoor_read(...)` (vip_dram §4). The scoreboard already holds the
   `dram` handle (the TB owns the `vip_dram` instance, §13). `vip_mc` does not
   own, adopt, or re-publish a `vip_mem` (§2 rule 4), so there is no
   `{"mem_", "vip_mc_inst"}` handle.

Mismatches outside the tolerance window are `uvm_error`. Refresh emissions are
counted via `dram.get_refresh_count()` and verified against expected cadence in
the relevant tests. (The earlier "rebuild a `vip_dram_req` from the monitor and
call `predict()` per monitored transaction" recipe is removed: it predicts in
AXI4 acceptance order and never injects REF — wrong under refresh / multi-port /
same-`$time`, per the §5.6 predict-ordering rule.)

### 13.3 Test cases

| #  | TC name                          | What it stresses                                                                                              |
|----|----------------------------------|---------------------------------------------------------------------------------------------------------------|
| 1  | `tc_mc_smoke`                    | One WR + one RD same row. AXI4 latency matches `predict()` within tolerance; data round-trip ok.              |
| 2  | `tc_mc_page_hit_streak`          | Manager issues 64-beat INCR burst same row; throughput governed by `tCCD_L` per column access (**not** `tBL`, M2); AXI4 timing matches `dram.predict()`. |
| 3  | `tc_mc_refresh_emission_cadence` | Run for `N * tREFI`; verify `dram.get_refresh_count() == N * n_ranks` within ±1 (M5).                         |
| 4  | `tc_mc_decerr_range`             | Call `cfg.axi4.add_decerr_range(lo,hi)`; verify B/R `RESP == DECERR` inside, `OKAY` outside.                  |
| 5  | `tc_mc_axi4_ooo_inter_id`        | Interleaved different-ID reads, backend FR-FCFS / miss-queue selection chooses a later hit ahead of an earlier miss; per-ID order preserved, **inter-ID** order shuffles emergently from that pre-issue selection — no separate post-issue reorder knob. |
| 6  | `tc_mc_outstanding_limit`        | Saturate `max_outstanding_rd` reads; `arready` deasserts when queue full, re-asserts on drain.                |
| 7  | `tc_mc_axi4_4k_boundary`         | Bursts that cross 4 KB; verify `vip_mc` returns DECERR on all beats and bumps `get_4k_violation_count()`.     |
| 8  | `tc_mc_preset_sweep`             | **Consistency/smoke check, not timing-correctness.** Run `tc_mc_smoke` once per `vip_dram` timing preset (DDR3/DDR4/LPDDR4/DDR5/IDEAL); asserts MC↔device agree (observed = `predict()`) and nothing wedges. Only **DDR4-3200 CL22** is timing-authoritative (vip_dram); the other presets are first-pass approximations, so absolute-latency realism is **not** asserted here. |
| 9  | `tc_mc_reset_recovery`           | Mid-flight reset — cmd queue drains, no spurious B/R post-reset (§9 manager contract), post-reset traffic completes. |
| 10 | `tc_mc_demonstration`            | Mixed RD/WR stream across many rows/banks; integrity + latency sanity. Reference TC for users.                |
| 11 | `tc_mc_aw_backpressure`          | Saturate AW queue at `cfg.axi4.aw_outstanding_limit`; verify `awready` deasserts and re-asserts on drain.     |
| 12 | `tc_mc_bresp_same_awid_guard`    | Same-AWID stream whose writes the device completes OoO; verify B order is still preserved (the mandatory same-ID guarantee, §4.2).                  |
| 13 | `tc_mc_multi_rank`               | `n_ranks=2`; verify both ranks see traffic and both see REF; `dram.get_refresh_count()` splits per rank (§7.3, §6.1). |
| 14 | `tc_mc_refresh_collision`        | REF emitted while burst in flight; verify both complete and observed latency picks up `tRFC` from `vip_dram`. |
| 15 | `tc_mc_unsupported_axi4_reject`  | Drive AXI4 request shapes the current slice rejects with **FE-local SLVERR**: an unsupported 17-beat `FIXED` write and an exclusive read with unsupported `ARCACHE`. Verify both complete locally, never issue into `vip_dram`, and therefore only appear as FE-resolved responses rather than backend/device traffic (§4.6, §5.6). |
| 16 | `tc_mc_qos_scheduling`           | Mixed-`AxQOS` traffic, several in flight; via the `issued_port` grant tap verify higher classes issue ahead of older lower-class requests, same-ID order held, refresh still pre-empts; `qos_class_count = 1` reverts to FCFS (§5, §8.9). |
| 17 | `tc_mc_qos_aging`                | Saturating high-class stream + one starved low-class request; verify it is promoted and issued within ~`qos_aging_ns` (no starvation, §8.9).                  |
| 18 | `tc_mc_wready_backpressure`      | Fill `w_data_buf_depth` (pause W mid-burst); verify `wready` toggles and `get_wready_stall_cycles()` moves — distinct from AW-side backpressure (§4.5). |
| 19 | `tc_mc_rsp_buffer_backpressure`  | Stall `BREADY`/`RREADY` to exhaust `rsp_buf_depth`; verify request issue stops, `AWREADY`/`ARREADY` then deassert, `get_rsp_buf_full_cycles()` moves, and release drains cleanly (§8.9). |
| 20 | `tc_mc_exclusive_access`         | Exclusive RD then exclusive WR to a valid reservation → `EXOKAY` + memory updated; with an intervening normal WR → exclusive WR returns `OKAY`, memory unchanged; counters track (§4.6). |
| 21 | `tc_mc_burst_wrap_fixed`         | `WRAP` and `FIXED` bursts; verify the column-access sequence + data round-trip match the address iterator against `dram.backdoor_read` (§4.6, §5.6).            |
| 22 | `tc_mc_narrow_unaligned`         | Narrow `AxSIZE` and unaligned base; verify lane muxing + `wstrb` masking on WR and sub-lane slicing on RD round-trip correctly (§4.6, §5.6).                    |
| 23 | `tc_mc_read_multi_id`            | Several in-flight reads with distinct `ARID`s; verify each completes with correct data. AXI4 has no read-data interleaving, so beats return contiguously per burst (one active at a time) while same-ID order holds (§4.6). |
| 24 | `tc_mc_user_passthrough`         | Drive `AWUSER`/`WUSER`/`ARUSER`; verify they are carried through and `BUSER`/`RUSER` are echoed back unchanged (passthrough, §4.6).                              |
| 25 | `tc_mc_telemetry_counters`       | Mixed hit/miss + backpressure run; verify `get_row_hit_rate()`, `get_predict_accuracy()` (≈0 ns error vs an independent tap-side collector), and `get_effective_bandwidth()`/`get_bus_utilization()` track the same observed device window (§8.8). |

### 13.4 Running

`vip_mc_example.core` invokes the project's standard FuseSoC sim flow and orders
files:

1. `vip_mem_types_pkg`, `vip_memory_pkg`
2. `vip_mc_axi4_types_pkg` (vip_mc's OWN AXI4 types)
3. `vip_mc_axi4_if` and, when enabled, `vip_mc_status_if` (interfaces, global
  scope) — **before** `vip_mc_pkg`: package classes (`vip_mc_axi4_driver`, the
  `vip_mc_axi4_vif_holder`, and the optional status-probe plumbing) hold
  `virtual vip_mc_axi4_if` / `virtual vip_mc_status_if` handles, so the
  interface types must be analyzed first (§3).
4. `vip_dram_pkg` (brings in `vip_dram_addr_pkg` / `vip_dram_types_pkg`)
5. `vip_mc_addr_pkg` (MC-specific addr helpers; needs `vip_dram_addr_pkg`, §8.3)
6. `vip_mc_pkg`
7. `vip_axi4_types_pkg`, `vip_axi4_agent_pkg`, `vip_axi4_if`
   — **example only**, to reuse the stock manager for stimulus
8. `vip_mc_axi4_connect` (bridges `vip_mc_axi4_if` ↔ `vip_axi4_if`)
9. `mc_tb_pkg`
10. `mc_tc_pkg`
11. `mc_tb_top` last

Steps 1–6 are the `vip_mc` core (no `vip_axi4_*`). Steps 7–8 enter only because
the example chooses the stock manager as its stimulus source; a TB that drives
`vip_mc_axi4_if` directly omits them. A TB that does not use the §8.8A status
probe omits `vip_mc_status_if` from step 3 as well.

When CHI lands, the ordering stays protocol-symmetric but **reuses** `vip_chi`:
`vip_chi_types_pkg` (brings the CHI flit/opcode/width types) analyzes before the
owned `vip_mc_chi_if`, which in turn analyzes **before** `vip_mc_pkg` — exactly
as the AXI4 IF does. The example then adds `vip_chi_if` + `vip_chi_agent_pkg`
(the RN-I stimulus manager) and `vip_mc_chi_connect`, the CHI counterparts of
steps 7–8. The AXI4-only core build pulls in none of these.

A test is picked with `+UVM_TESTNAME=tc_mc_smoke`.

---

## 14. Feature coverage and scope

This section summarizes what the design encompasses beyond the AXI4 first cut, and
what stays out of scope.

### 14.1 CHI front-end

The CHI front-end (`vip_mc_chi_*`) covers the **SN memory-target subset** (§1 CHI
decisions), opt-in behind `+define+VIP_MC_ENABLE_CHI` so the AXI4-only core carries
no `vip_chi` dependency (CHI decision 7). Its files are `vip_mc_chi_if.sv`
(single-role SN interface, superset `vip_chi_types` flits), `vip_mc_chi_driver.sv`
(link activation, credit exchange, ReadNoSnp / ReadNoSnpSep,
WriteNoSnp{Full,Ptl,Zero}, Comp / CompDBIDResp / DBIDResp / CompData / DataSepResp /
ReadReceipt, DECERR + unsupported-op rejection; reuses `vip_chi_driver_snf`
algorithms and feeds the shared backend + `vip_dram`), `vip_mc_chi_cmd_entry.sv`,
`vip_mc_chi_vif_holder.sv`, and `vip_mc_chi_connect.sv`. `vip_mc` builds mixed
AXI4/CHI ports (per-protocol homogeneity). Native knobs live on `vip_mc_chi_cfg`
(credits, `split_write_rsp`, `sn_node_id`; validated in `vip_mc_config`), the
parallel of `vip_mc_axi4_cfg`.

The CHI demonstration lives in the single [`testbench/sv`](../testbench/sv/)
example (built with `+define+VIP_MC_ENABLE_CHI`), alongside the AXI4 suite: a
self-contained one-port CHI `vip_mc` instance (built inside the test, mirroring the
`tc_mc_multi_rank` pattern) driven by a stock `vip_chi` RN-I manager through the
connector wired in `mc_tb_top`. Directed coverage:

- **CHI-D:** `tc_mc_chi_d_write_read` (data verified through the device),
  `tc_mc_chi_d_read` (well-formed CompData), `tc_mc_chi_d_write_ptl`
  (WriteNoSnpPtl per-byte merge), `tc_mc_chi_d_decerr` (read+write
  NONDATA_ERROR), `tc_mc_chi_d_combined_write` (`split_write_rsp=0`
  CompDBIDResp path), `tc_mc_chi_d_unsupported` (raw CleanSharedPersist
  rejected without touching the device).
- **D/E matrix** (§10.1 stage 2): the CHI env/base test are parameterized over the
  `(vip_chi, vip_mc)` cfg pair, so the same self-contained slice builds under either
  issue; `mc_tb_top` carries a second issue=E SN+RN-I interface pair sharing the
  CHI-D config_db keys (resolved by vif type, since only one test runs per simv).
- **CHI-E:** `tc_mc_chi_e_write_read` (D/E parity + the AXI4/CHI-D/CHI-E
  equivalence point: an identical counter line lands byte-identical device state
  under E), `tc_mc_chi_e_write_zero` (WriteNoSnpZero, E-only: seeds a non-zero
  line then zeroes it, no data phase), `tc_mc_chi_e_read_sep` (ReadNoSnpSep,
  E-only: DataSepResp on ReturnTxnID with correct data).
- **Protocol equivalence** (§10.1 stage 3): a protocol-neutral golden model
  (`mc_equiv_model`, sparse byte image) plus one deterministic program
  (`mc_equiv_program`: full-line writes, byte-enabled partial writes, reads)
  replayed by `tc_mc_equiv_axi4` / `_chi_d` / `_chi_e`, each checked against a
  fresh model — a transitive proof that AXI4, CHI-D, and CHI-E land byte-identical
  device state and read data (partial-write ops make AXI4 WSTRB and CHI
  WriteNoSnpPtl merges apples-to-apples).
- **Mixed-protocol concurrency:** `tc_mc_mixed_concurrent` builds one `vip_mc`
  with port 0 = AXI4 and port 1 = CHI-D over a single shared backend + `vip_dram`
  (`mc_mixed_tb_env`, `MIXED_PORTS_C = '{AXI4, CHI}` with both representative
  cfgs on every entry per the `PORTS[0]` convention), driving both legs
  concurrently (`fork`) to disjoint address windows — proving the shared backend
  arbitrates cross-protocol traffic without deadlock or data interference.
- **Multi-beat / narrow bus:** the host bus may be narrower than the DRAM row
  (`WDATA_BYTES_P` / `DATA_BYTES_P` ≤ and evenly dividing `ROW_BYTES_P`) — several
  host beats gather into one row word and a sub-row beat scatters into part of a
  row. Both front-ends keep the host bus lane (`addr % BUS_BYTES`) distinct from the
  DRAM row lane (`addr % ROW_BYTES`); the CHI driver separates the link DAT-beat
  count (`chi_dat_beats`) from the DRAM-row count (`beats`). `tc_mc_narrow_axi4`
  (64 B bus over a 128 B row: 2-beat gather + sub-row lane placement) and
  `tc_mc_chi_d_narrow` (32 B DAT over a 64 B row: 2-beat gather/scatter) cover
  it.
- **Broader CHI opcodes** (persist + reject coverage): a memory SN never executes
  atomics / snoop / DVM / stash — those are RN/HN transactions — so the front-end
  rejects the ones that can reach it. Persist is the one exception a memory target
  completes: `CleanSharedPersist` → Comp and `CleanSharedPersistSep` →
  Persist+CompPersist (no device access, `persist_count`), see
  `tc_mc_chi_d_persist`. `tc_mc_chi_d_reject` covers the atomic families
  (Store/Load/Swap/Compare), each rejected with Comp(NONDATA_ERROR); snoop/DVM are
  not receivable by an SN (no SNP channel), so there is no reject path for them.

### 14.2 Refresh and initialization

- **`VIP_MC_REFRESH_DEFERRED_E`** (`vip_mc_refresh.sv`) postpones refreshes (one
  unit of debt per `tREFI`) up to `refresh_max_deferred` (default 8, JEDEC's max
  postponement), then drains the debt in a forced catch-up burst — same average
  rate as periodic, bursty arrival. It exposes `get_deferred_debt` /
  `get_peak_deferred_debt` / `get_deferred_catchup_count`, covered by
  `tc_mc_refresh_deferred`. Deeper refresh/FR-FCFS coordination (opportunistic
  pull-in on idle) is future work (§11.1).
- **`init_delay_enabled` / `init_delay_ns`** model a tINIT-like bring-up hold-off:
  the backend gates all device issue (`init_gate_arm()` on posedge rst_n) until
  `init_delay_ns` after reset deassert, while requests still admit/queue. It re-arms
  on every reset and is covered by `tc_mc_init_delay` (first post-reset write
  held off, second prompt).

### 14.3 Out of scope

Burst splitting, multi-channel striping, and device-side ECC/SLVERR injection
beyond the SECDED model of §11.3 remain out of scope (§11.4).

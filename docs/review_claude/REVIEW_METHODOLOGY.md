# Memory-controller review methodology

A runbook for auditing `vip_mc` as a behavioral memory-controller VIP. It is
written for the complete system, not just the AXI4 face: host protocol
front-ends, the shared command queue and scheduler, `vip_dram` timing and
memory state, refresh, reset, error handling, telemetry, and the SystemVerilog
and pyUVM/cocotb implementations.

Run this **after** a feature or review closes, as the acceptance pass — or
periodically, one contract at a time. It is written to be executed. Each phase
has commands, questions, and an exit gate.

The central claim to audit is:

```text
host protocol traffic -> vip_mc front-end -> neutral DRAM request/response
                     -> shared scheduler -> vip_dram timing and memory state
```

The AXI4 and CHI front-ends may differ in wire shape, but they must agree on
the neutral request semantics wherever the feature is shared. The SV and
Python ports must agree on the same behavior and testcase intent.

---

## 1. What you are looking for

There are two classes of defect, and the second is usually larger.

### Class A — the controller is wrong

The implementation violates a protocol or design contract. Examples include a
WRAP burst being issued to the device at `AWADDR` instead of the wrap-window
base, a same-stream request being reordered, a response tag being delivered to
the wrong port, or refresh/reset allowing stale work to escape.

### Class B — the test did not test

The implementation may be right or wrong; **the test cannot distinguish the two**
and reports success either way. A read-after-write, a green timing scoreboard,
or a high coverage percentage is not evidence on its own.

| Shape | What it looks like | Memory-controller instance or risk |
| --- | --- | --- |
| **Mirrored corruption** | Write and read use the same wrong address calculation | A WRAP write and matching read can both rotate identically; only an independent device-address or backdoor check finds the bug |
| **Predicted by the DUT** | The expected response is calculated from the same config/helper as the implementation | A soak test that avoids DECERR windows, or predicts DECERR by calling the front-end's own classifier, cannot find a bad classifier |
| **Only the final data is checked** | Read-back matches but no request, timing, response, or side effect is checked | A request can bypass the scheduler, hit the wrong rank, or complete with the wrong response while the final byte image still matches |
| **Only one ordering regime** | Serial or same-ID traffic passes | AXI4 same-ID order may be correct while inter-ID completion, QoS, FR-FCFS, aging, or starvation behavior is wrong |
| **Unbounded by default** | Backpressure tests pass with no stalls | A response-buffer or W-data-buffer limit is configured as zero/unbounded, so `READY` never proves a finite-resource contract |
| **Synthetic refresh** | A shortened override makes a refresh appear | The native `tREFI` path can be broken while the test only proves the override path; deferred debt and catch-up can remain untested |
| **Waiver-shaped pass** | A scoreboard or coverage collector is disabled and the test stays green | Coalesced writes and ECC paths intentionally bypass the one-to-one timing predictor; directed data and counter checks must replace it |
| **One-language drift** | SV passes, Python passes, or both compile | A feature exists in one port only, or the two ports use different transaction packing, reset, or response semantics |
| **Shared-model agreement** | AXI4, CHI-D, and CHI-E all pass one golden model | The golden model may share the same address, byte-enable, or response transformation mistake as the DUT |
| **Silent zero result** | A test discovery, coverage, or catalog command returns nothing and looks successful | A missing Python import, UVM registration, or filtered test list can make a regression smaller without making it fail |
| **Stale inventory** | Documented test counts and discovered tests disagree | `TEST_CASES.md` and historical review notes have carried different totals; count the tree, do not trust a copied number |
| **Truncated evidence** | A shortened log shows a clean process exit | The final UVM error/fatal summary, Python assertion, or coverage report may be outside the captured tail |

**The discipline that follows:** every behavior needs an independent oracle,
an observed stimulus, and a measured result. A green regression is only one
piece of that evidence.

---

## 2. Phase 0 — establish the authority

Do this before changing RTL, drivers, or tests. `vip_mc` has several layers of
authority; confusing them is a reliable way to review the wrong behavior.

1. **Separate delivered behavior from intended behavior.** Read
   [`README.md`](../../README.md) for the public delivered slice and
   [`IMPLEMENTATION_PLAN.md`](../IMPLEMENTATION_PLAN.md) for architectural
   intent. A plan statement is not proof that the code implements it, and an
   implemented follow-up is not necessarily still an open item.
2. **Treat `vip_dram` as the authority for device timing and bank state.**
   `tRCD`, `tCL`, `tRP`, `tRFC`, page hit/miss/empty classification, and
   `first_beat_ready_time` / `last_beat_ready_time` belong to the device model.
   `vip_mc` owns admission, mapping policy, scheduling, refresh requests, and
   host-side retiming. Do not re-derive DRAM timing in a test and call that an
   independent check.
3. **Use the protocol specifications for protocol obligations.** The stock
   `vip_axi4_agent` and `vip_chi_agent` provide useful stimulus and observation,
   but their behavior is not authority for what a controller is allowed to
   accept or how the neutral request must be formed. Cite AXI4 or CHI for the
   wire-level rule, then cite the `vip_mc` design contract for the translation.
4. **Read the current test catalog as an inventory, not as proof.**
   [`testbench/TEST_CASES.md`](../../testbench/TEST_CASES.md) is intended to be
   the authoritative list of testcase intent. Derive the actual list from the
   SV registrations and Python imports and reconcile it with the catalog. The
   historical totals in [`FURTHER_WORK.md`](../FURTHER_WORK.md) are review
   notes, not a current count.
5. **Read the testbench architecture before interpreting a pass.** The SV
   default environment is a two-port AXI4 system; CHI, mixed-protocol, and
   narrow-bus tests construct separate environments. The Python flow has a
   Verilator shell and a flow-only pure-core test. A test using the default
   environment does not automatically exercise CHI, multiple ranks, or the
   narrow geometry.
6. **Record the boundary of each oracle.** The timing scoreboard is an AXI4
   B/R checker keyed by `{port, id}` and `backend.issued_port`; it is not a
   complete CHI checker and is intentionally insufficient for transformed
   completions such as write coalescing and ECC fault handling. The equivalence
   model checks byte state and read data; it does not prove timing, ordering, or
   refresh.
7. **Verify figures, tables, and formulas in their original authority.** If a
   design document says that a helper, address map, or timing equation is
   normative, inspect the source definition and the `vip_dram` contract. A
   converted summary or a copied comment can preserve the words while losing
   the condition that makes them true.

For each feature under review, make a small authority record:

| Contract | Authority | Implementation | Independent evidence |
| --- | --- | --- | --- |
| AXI4 handshake, burst, response | AXI4 specification + native `vip_mc` interface contract | `sv/vip_mc_axi4_*`, `py/vip_mc_axi4_*` | directed AXI4 test and monitor observation |
| CHI SN request/response shape | CHI issue D/E specification + reused CHI types | `sv/vip_mc_chi_*`, `py/vip_mc_chi_*` | CHI-D and CHI-E observations |
| Address mapping and burst placement | MC plan + DRAM address-map contract | `vip_mc_config`, `vip_mc_cmd_entry`, front-end pack/unpack | issued request tap and device/backdoor check |
| Queue ordering and arbitration | MC plan and queue contract | `vip_mc_cmd_queue`, `vip_mc_backend` | grant-order collector, response order, counters |
| DRAM timing and refresh effect | `vip_dram` contract | backend/refresh bridge | `predict()` scoreboard plus device response tap |
| Reset and initialization | MC reset contract + device reset handshake | `vip_mc::handle_reset`, front-ends, refresh | mid-flight reset and post-reset access |
| SV/Python parity | shared catalog and explicit feature contract | `sv/` and `py/` pairs | same testcase intent in both flows |

**Exit:** every claim in the review has a named authority, an implementation
location, and an oracle that does not merely repeat the implementation.

---

## 3. Phase 1 — inventory and instrument before repairing

Do not fix anything yet. Establish what exists, what is discovered, and what
actually runs.

Run from the `vip_memory_controller` repository root:

```bash
# Source and documentation inventory
rg --files sv py testbench docs | sort
rg -n "class tc_mc_|uvm_component_(param_)?utils\(tc_mc_|@.*test|TestFactory|run_test" \
  testbench/sv testbench/py

# Current test discovery, including the flow-only Python core slice
grep -rhoE 'uvm_component_(param_)?utils\(tc_mc_[a-z0-9_]+' testbench/sv/tc/ \
  | sort -u
rg -n '^class tc_mc_|^def test_|@cocotb\.test' testbench/py/tc testbench/py/tb

# Dependency/version and pure-core checks
python3 testbench/py/check_versions.py
python3 -m pytest testbench/py/tc/test_mc_core.py

# Static and simulation entry points
./testbench/py/run_fusesoc.sh --target lint
fusesoc --cores-root=. run --clean --setup --build --target=default --tool=vcs \
  akerlund::vip_mc_example:0
./testbench/py/run_fusesoc.sh --target sim
```

Before a full run, inventory the harness and its opt-outs:

```bash
rg -n 'mc_coverage_enabled|scoreboard|timing_check|refresh_enabled|perf_counters|write_coalescing|ecc_enable|VIP_MC_ENABLE_CHI|tREFI|init_delay|rsp_buf|max_inflight|reset' testbench/sv testbench/py sv py
```

Read three counts separately:

- **Discovered tests** — registered/imported and runnable.
- **Catalogued tests** — named in `TEST_CASES.md`.
- **Executed tests** — present in the full-run log, with a pass/fail summary.

Do not collapse them into one number. A missing import, a testcase that is
registered but not invoked, and a catalog-only row are three different defects.
The current repository has intentionally evolved beyond older review counts;
the count check must expose stale documentation instead of normalizing it.

For each behavior, classify the evidence as:

- **NEVER exercised** — no request, response, counter increment, or coverage
  sample demonstrates that the path ran.
- **ONE REGIME ONLY** — tested only with one ID, one port, one protocol, one
  geometry, one response state, or one timing preset.
- **WAIVED** — the normal oracle is disabled; record the replacement oracle and
  why the waiver is necessary.
- **UNOBSERVABLE** — the test cannot see the relevant boundary, for example a
  host-only readback test that cannot see the issued DRAM address.

Instrument before repairing. If you suspect that a command is not being issued,
add or use a counter/tap and measure the grant count, device response count,
front-end completion count, and per-port result first. The mismatch is the
finding; the code change is only a possible fix.

**Exit:** a written inventory of discovered/catalogued/executed tests and a
list of dead or thin feature-to-observation paths, split by front-end, backend,
device, and language.

---

## 4. Phase 2 — audit each contract and translation boundary

Audit in this order. Stop at the first missing evidence and repair the test or
contract before concluding that the implementation is correct.

### 4.1 Front-end legality and response semantics

For AXI4, check independently:

- AW/W and AR handshakes, including gaps and backpressure;
- `INCR`, `FIXED`, and `WRAP`, aligned and unaligned starts, narrow transfers,
  byte strobes, and 4 KB boundary legality;
- same-ID ordering and emergent inter-ID completion order;
- exclusive read/write success and failed-exclusive no-write behavior;
- `USER` preservation where the native contract promises it;
- unmapped/illegal accesses returning the documented DECERR behavior;
- unsupported transfer shapes returning the documented local error and never
  issuing to `vip_dram`.

For CHI SN, check both issue D and issue E where the feature is shared:

- link activation and credit exchange;
- ReadNoSnp and WriteNoSnp variants, including partial and zero writes;
- completion opcode, response error, transaction identity, and data shape;
- narrow DAT configuration and the D/E width/optional-field boundary;
- persist/CMO and unsupported operations taking the intended local path;
- decode errors being completed without a device request;
- any `ExpCompAck` contract being either validated or explicitly recorded as
  an open limitation. Do not silently treat a consumed credit as a validated
  protocol acknowledgement.

Do not infer that AXI4 and CHI must have identical response encodings. Prove
that each front-end maps its legal and rejected operations to the intended
neutral command and completion semantics.

### 4.2 Command construction and address placement

Every accepted host request should be traceable through a command entry to one
or more neutral device operations. Audit that the entry preserves:

- origin port and, where applicable, protocol-specific completion metadata;
- host ID / TxnID and the completion tag;
- operation, byte count, beat count, QoS class, and admission order;
- address, rank selection, and the configured address-map result;
- write data and byte enables, including partial overlays;
- `USER` or equivalent metadata where it is part of the contract;
- exclusive state, pre-resolved status, and response classification.

Check the **device-facing address separately from the protocol start address**.
For AXI4 WRAP, `addr` is the bus start address but the device payload window is
indexed from the wrap-window base. The issued request must use the same base as
the pack/unpack logic. A read-after-write is not sufficient: inspect
`backend.issued_port` or the device request and verify an independent memory
location/backdoor.

Also test:

- the first and last byte of each mapped region;
- holes and DECERR ranges;
- 4 KB boundary crossings with an independently calculated expected response;
- rank/bank-group/bank/row/column placement under each geometry used by the
  catalog;
- a narrow host bus over a wider DRAM row and the CHI narrow-DAT case.

### 4.3 Shared scheduler and finite resources

The backend is protocol-agnostic by design. Prove that property with both
front-ends and with direct backend observations.

Audit these invariants:

1. Same-stream ordering is preserved even when QoS classes differ.
2. QoS priority selects the intended class, while aging promotes an old low
   class within the documented bound.
3. FR-FCFS readiness selection is based on the device prediction/state it is
   allowed to use, not on a test-only hint.
4. The starvation cap eventually force-serves a bypassed request.
5. Read/write grouping improves the intended direction without starving the
   opposite direction or violating the configured run limit.
6. Inter-ID reordering is allowed only where the contract allows it; whole
   read bursts remain contiguous on AXI4.
7. The finite device window blocks new issue at its limit and resumes after
   response retirement.
8. The response buffer blocks admission/issue when B/R is stalled, and the
   W-data buffer makes `WREADY` toggle at the configured bound.
9. Write coalescing overlays newer enabled lanes, creates one device access,
   and fans out the correct number of host completions.
10. Every issued tag completes once, on the originating port, or is explicitly
    discarded by reset with no later host response.

The Python pure-core tests are useful for queue/config algorithms, but they do
not replace end-to-end tests: a correct queue unit test can coexist with a bad
front-end marshalling path or a wrong SV port.

### 4.4 Device timing, refresh, reset, ECC, and telemetry

Keep ownership clear:

- `vip_dram` owns bank state and physical timing;
- `vip_mc` owns when a command is admitted/issued, how refresh enters the
  queue, and how device ready times are re-timed onto the host clock;
- the host front-end owns valid/ready driving and completion shape.

Audit:

- `dram.predict()` is side-effect free and receives independently reconstructed
  request fields;
- normal responses use `first_beat_ready_time` and
  `last_beat_ready_time` according to `honor_beat_timing`;
- refresh blocks the affected rank for `tRFC`, leaves the documented bank state,
  and is visible both in MC counters and device observations;
- periodic refresh is tested with native `tREFI`, not only an override;
- deferred refresh debt cannot exceed its cap and catch-up emits the expected
  number per rank;
- reset flushes front-end, backend, queue, and refresh state, calls the
  blocking device reset, and suppresses stale B/R or CHI completions;
- init delay blocks issue, including refresh where the contract says so, while
  still allowing the documented admission behavior;
- correctable ECC repairs data and counts it, uncorrectable ECC returns SLVERR
  with the documented poisoned data, and ECC-disabled behavior is explicitly
  checked as silent corruption rather than accidentally treated as success;
- telemetry is independently cross-checked against grant/response taps, not
  only against getters called by the same implementation.

The timing scoreboard has an important boundary: it predicts in grant order and
correlates AXI4 B/R per `{port, id}`. If the feature transforms one device
access into several host completions, as coalescing does, or changes the data
and classification through ECC, either extend the scoreboard or replace it
with exact directed checks. A disabled scoreboard is not evidence of correct
timing.

### 4.5 Configuration and compile-time boundaries

For every configuration knob, test all three states where meaningful:

- feature disabled/default;
- feature enabled with the smallest finite limit or simplest geometry;
- feature enabled at a non-default value that changes behavior.

Validate language boundaries at the boundary itself:

- a missing compile-time field or issue-specific type must not be read as a
  runtime value;
- CHI is gated consistently by `VIP_MC_ENABLE_CHI` and does not contaminate
  the AXI4-only core path;
- mixed `PORTS[]` tables do not depend on an accidental representative config
  in `PORTS[0]` without a test proving that convention;
- width, row, rank, and address-map parameters are validated before issue;
- zero/unbounded settings are intentional and asserted, not silently selected
  because a limit was omitted;
- `perf_counters_enabled` semantics are consistent across AXI4, CHI, backend,
  queue, and refresh counters, or the inconsistency is documented as a known
  contract decision.

### 4.6 SystemVerilog/Python parity

For each shared testcase, compare intent and oracle, not just the filename:

- same transactions, addresses, IDs, QoS, gaps, widths, and error cases;
- same reset and initialization sequence;
- same expected data, response, issued-request, and counter assertions;
- same feature knobs and waivers;
- same randomized program and seed semantics where the test is randomized;
- same end-of-test success criteria.

It is acceptable for SV and Python coverage percentages to differ; their bin
weighting and accumulation models differ. It is not acceptable for one flow to
omit the behavior or use a weaker oracle without saying so.

**Exit:** each contract is traced through front-end → command entry → backend
→ device → completion, with an independent check at every boundary that matters.

---

## 5. Phase 3 — prove every important branch fires

A test with no negative control or branch count proves only that its chosen
traffic completed.

Use this control shape for each rejection, transformation, or scheduling rule:

1. Drive a compliant baseline and assert the expected data/response and at
   least one relevant observation count.
2. Assert the target counter/tap is quiet before the provocation. For example,
   clear or snapshot `issued_port`, `dram.rsp_port`, `decerr_count`, or the
   relevant front-end count.
3. Inject exactly one changed condition: one bad address, one 4 KB crossing,
   one unsupported opcode, one ECC fault, one stalled response channel, or one
   queue candidate. Leave unrelated fields legal.
4. Assert the exact response, exact side effect, and exact issue/no-issue count.
   “At least one error” hides duplicate completions and collateral rules.
5. Assert that unrelated counters and paths stayed quiet. A DECERR must not
   also look like an unsupported operation; a CHI persist operation must not
   increment the unsupported count; a failed exclusive write must not mutate
   memory or issue a device write.
6. Assert the provocation itself happened. A random generator or helper that is
   later changed to avoid the bad case must fail the test rather than turn the
   negative control into an idle pass.
7. Repeat at every applicable vantage: each port, AXI4 and CHI where shared,
   issue D and E, and both SV and Python where the feature is advertised as
   shared.

Prefer raw or minimally processed injection to a DUT configuration knob. For
example, use an independently built address to reach a DECERR window, observe
the actual neutral request to prove it was not issued, and use a device fault
injection only to create the physical ECC condition. If a configuration knob is
the only way to reach a branch, document why and assert that the knob was
actually consumed.

Required negative-control families include:

- AXI4 unmapped/DECERR and 4 KB crossing;
- unsupported AXI4 shape and unsupported CHI operation;
- CHI persist/CMO local handling;
- failed exclusive write;
- finite AW/AR, W-data, response-buffer, and device-window limits;
- low-QoS aging, FR-FCFS bypass, starvation-cap force service, and direction
  grouping;
- WRAP with a non-base start address;
- correctable, uncorrectable, and ECC-disabled reads;
- refresh collision and deferred catch-up;
- reset while a read/write/refresh is in flight, followed by a fresh access;
- multi-port and mixed AXI4+CHI tag/response demultiplexing;
- CHI-D/CHI-E and narrow-DAT response/data differences;
- at least one native timing-preset and one multi-rank geometry.

For the constrained-random soak:

- keep the program deterministic and seed-reproducible;
- predict DECERR from an independent span/window calculation, not by calling
  the front-end classifier;
- assert that WRAP, narrow, unaligned, backpressure, QoS, and reject cases are
  actually present in the generated program;
- check the written image through an independent device/backdoor view, not only
  read-after-write;
- replay any failing seed in both language flows;
- do not use generator filtering to remove the condition under test unless the
  test explicitly proves the filter's coverage contract.

**Exit:** every important branch has an observed positive path and a deliberate
negative/transformation control, with exact counts and no accidental collateral
activity.

---

## 6. Phase 4 — sequencing and the commit gate

**Stimulus before rule, always.** Land or prove the traffic that exercises a
feature before enabling a strict new check across the regression. Otherwise a
correct check can create broad noise and obscure whether the issue is missing
traffic or an implementation defect.

For a behavior, keep the implementation change, both-language stimulus, and
the catalog/test documentation together. Split only when sequencing requires a
temporary stimulus-first commit.

Run one flow at a time when it shares build or run directories. Capture all
output; do not inspect a streaming run through `tail -N`.

The full gate is:

```bash
# From vip_memory_controller/
python3 testbench/py/check_versions.py
python3 -m pytest testbench/py/tc/test_mc_core.py
./testbench/py/run_fusesoc.sh --target lint

fusesoc --cores-root=. run --clean --setup --build --target=default --tool=vcs \
  akerlund::vip_mc_example:0

# Run the full SV catalog, capturing the complete simulator output.
# The exact executable path is printed by FuseSoC; run every discovered
# +UVM_TESTNAME separately because one simv runs one UVM testcase.

./testbench/py/run_fusesoc.sh --target sim

# Evidence and repository hygiene
git diff --check
rg -n "UVM_ERROR|UVM_FATAL|FAIL|ERROR|assertion|Traceback" \
  testbench/sv/rundir testbench/py/rundir
```

Interpret the gate this way:

- A build exit code is necessary but not sufficient; inspect per-test
  `UVM_ERROR : 0` and `UVM_FATAL : 0`, Python assertion failures, and the final
  coverage/status reports.
- A clean lint run does not prove runtime behavior; a clean runtime does not
  prove that the test discovered all intended cases.
- Count SV registrations, Python test imports, catalog rows, and executed log
  summaries separately. Fail the gate on unexplained differences.
- Do not run two regressions concurrently when they share `rundir`, build
  products, logs, or accumulated coverage.
- If counters or coverage accumulate across a Python process, clear them or
  aggregate by testcase/epoch before comparing totals. An appended result is
  not a fresh result.
- For each feature, record the actual number of grants, device responses, host
  completions, negative controls, and coverage samples. Estimate nothing that
  can be measured from a tap or log.

The commit message should carry the evidence, for example:

```text
AXI4 WRAP placement: SV/Python parity

Evidence: directed WRAP issued device base checked independently; backdoor
image checked; soak seed replayed; AXI4/CHI equivalence unchanged; SV and
Python lint/core/full runs passed. Grants=..., device responses=...,
negative controls=.... Scoreboard waived only for coalescing tests; exact
directed fan-out assertions remain enabled.
```

**Exit:** both advertised flows pass, the discovered/catalogued/executed counts
reconcile, all waivers have replacement evidence, and the commit records
measured behavior rather than only a green command.

---

## 7. What to write down, and where

**In the source, at the behavior:**

- cite the design/protocol/device requirement in its formal form;
- state what is asserted and what is deliberately not asserted;
- identify assumptions about width, geometry, clock, reset, ordering, and
  `vip_dram` response shape;
- explain why a classifier, prediction, or waiver is independent enough for the
  intended claim;
- name the corresponding SV and Python tests.

**In the testcase:**

- describe the condition being created;
- assert that the condition was reached;
- assert the expected data, response, issue count, completion count, and
  counter deltas;
- state any scoreboard/coverage waiver beside the replacement oracle;
- preserve the seed or deterministic program for random failures.

**In the catalog:**

- one row per discovered testcase;
- environment/protocol/geometry;
- the exact behavior proved;
- whether evidence is data, timing, issue/response taps, counters, coverage,
  equivalence, or a combination;
- whether the test runs in both language flows.

**In review notes:** record every negative result. Examples are:

- “CHI `CompAck` is consumed for credit but not validated”;
- “timing scoreboard does not model coalesced fan-out”;
- “ECC telemetry is response-level, not per-beat”;
- “mixed protocol config currently depends on the representative config
  convention”;
- “native `tREFI` was not exercised; only the override path ran”;
- “this geometry has no independent device-address observation.”

An explicit exclusion closes a review task. An unrecorded exclusion is
rediscovered as if it were forgotten.

**Never in the source:** the review conversation, temporary conversion tools,
or finding identifiers. Finding IDs belong in review notes and commit messages.

---

## 8. Repository-specific traps

Keep these close to the runbook because they recur:

- **Read-after-write can hide address bugs.** Always pair payload checks with an
  independent issued-address or device/backdoor check for WRAP, mapping, rank,
  and narrow geometry.
- **The scoreboard is not universal.** It observes AXI4 B/R, not every CHI
  completion, and its one-device-entry/one-host-completion assumption does not
  hold for coalescing or all ECC outcomes.
- **`dram.predict()` has a lock-step caveat.** It reads live device scheduler
  state. Back-to-back issue at the same simulation time can make strict timing
  prediction diverge even if the controller is correct; characterize that case
  and do not turn a known predictor limitation into a false implementation
  failure.
- **A waived scoreboard must leave an exact oracle.** Coalescing needs one
  device-access assertion plus two host-completion/data checks. ECC needs fault
  severity, restored/poisoned data, response, and counter checks.
- **Native and overridden refresh are different paths.** A shortened `tREFI`
  proves timer plumbing; a realistic-duration test proves elapsed-time behavior.
- **Reset is a transaction boundary.** A post-reset read that returns correct
  data does not prove that a pre-reset response was suppressed. Assert no stale
  B/R or CHI response and verify the documented post-reset page state.
- **Same-ID order is not inter-ID order.** Use at least two IDs and make the
  device timing or scheduler select a different completion order.
- **A low-QoS aging test can pass without aging.** Assert the old request's
  measured wait/bypass count and force-service counter, not just eventual
  completion.
- **A backpressure test can pass with an accidental infinite resource.** Set a
  finite depth, hold the consumer inactive, and assert the exact `READY` stall
  and resume transition.
- **Do not use the generator's own policy as the oracle.** A soak generator may
  arrange hot pages or legal starts, but the test must independently check
  legality, wrap-window placement, DECERR span, and expected bytes.
- **SV and Python coverage are not numerically comparable.** Treat them as
  independent evidence over the same intent; Python accumulation and SV
  per-test reporting must not be mixed.
- **CHi issue is configuration, not an interface name.** Verify issue D/E in the
  actual config and width types; do not infer the issue from an enum suffix or
  file name.
- **The CHI front-end has known open edges.** `CompAck` validation, counter
  gating consistency, and any issue-specific response obligations must be
  either covered or listed as open; credit return alone is not proof.
- **Mixed `PORTS[]` representative configuration is a real integration risk.**
  Exercise a table where port 0 is CHI and a later port is AXI4 if the current
  convention remains in use.
- **Documentation counts drift.** Recompute counts from discovery and logs
  whenever tests are added; do not copy the total from an older review note.
- **One test per SV simulator matters.** A compiled UVM package can contain all
  tests while only the selected `+UVM_TESTNAME` executes. Confirm the selected
  name and the final report for every invocation.

---

## 9. The three questions

If there is only time for three questions, ask these:

1. **What did the independent observation see?** Not just the final read-back:
   which command was issued, to which device address, with which tag, and what
   completed on the host?
2. **Has the failing or transforming branch actually run?** If not, the test
   proves only that an idle or compliant path is green.
3. **Can I state the contract and its oracle separately?** If the expected
   result comes from the same helper, classifier, or transformed value as the
   implementation, the check is not independent enough.

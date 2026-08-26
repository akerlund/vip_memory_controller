# Upgrading `vip_chi_agent`: what breaks, what it will report, and what to do

**Pinned:** `ce6449e` · **Agent head:** `142a9dd` · **Gap: 83 commits**, 49 files,
+22012 / −1065 lines under `sv/` and `py/`.

Written by reading both trees, not by reading changelogs. Every number below has
the command that produced it in [Appendix: how this was measured](#appendix-how-this-was-measured).

---

## Verdict in three lines

1. **The upgrade barely breaks compilation.** The parameter struct is
   byte-identical, the flit types are *derived* rather than copied, and every
   sequence setter this testbench calls still exists. Expect an afternoon, not a
   week.
2. **It also buys nothing on its own**, because this testbench never binds the
   agent's protocol checker. All 89 checks are dead here today.
3. **Once bound, it will report four real conformance defects in the MC's own CHI
   front-end**, three of them on every single run. Those are the actual work.

The ordering matters and is not negotiable: bind first, then fix what it says.
Bumping the submodule without task **B1** produces a green run that means exactly
as much as today's does.

---

## A. What does NOT break — do not spend time here

Recorded so nobody re-derives it.

- [x] **`vip_chi_cfg_t` is byte-identical** — same 8 fields, same order. The named
      `'{ ISSUE_P : ..., ... }` construction at
      `testbench/sv/tb/mc_tb_pkg.sv:107` and `:166` still compiles. (A named
      struct literal must name every member, so a single added field *would* have
      broken it — this was worth checking rather than assuming.)
- [x] **The flit types are derived, not vendored.** `sv/vip_mc_chi_if.sv:69-72`
      does `typedef vip_chi_types #(CHI_CFG_C)` and takes `req/rsp/dat_flit_t`
      from it, so every width and field-order change propagates automatically.
- [x] **The SNP flit changes do not reach the MC.** `donotdatapull` was removed,
      `mpam` and `donotgotosd` added, and the field order changed in all three
      issue variants — but `vip_mc_chi_if.sv` declares only REQ/RSP/DAT, which is
      correct for an SN. Nothing to do.
- [x] **The `dodwt` → `snpattr` REQ-field rename does not reach the MC either.**
      The only hits in this repo are inside `testbench/sv/rundir/` — FuseSoC's
      copied sources, i.e. build output. No MC source names the field.
- [x] **The sequence API is stable.** All 15 setters called from
      `testbench/{sv,py}/tc/tc_mc_chi_*` still exist under the same names, and
      `set_allow_retry`'s signature is unchanged. (Its *semantics* did change —
      see **C1**.)
- [x] **No filelist work.** `vip_chi_sva.sv` and `vip_chi_snp_sva.sv` are already
      in the library core (`vip_chi_agent.core:15-16`) as include files, so
      `testbench/sv/vip_mc_example.core`'s existing
      `depend: akerlund::vip_chi_agent:1.0.0` picks them up.
- [x] **80 check IDs were added and none removed.** Registry 9 → 89. No
      `VIP_CHI_CHK_*` name this repo could reference has disappeared.

---

## B. Bind the checker — everything else depends on this

> **This is the F-CHK-002 defect from the agent's own review, reproduced here.**
> There, coherent SVA binds sat behind an `ifdef` nothing defined: 3243 tally
> rows, 0 passes, 0 fails, and the dead bind reported as a clean link for the
> whole life of the project. Here the bind simply does not exist. The failure
> mode is identical — *silence reads as success* — and it is why B1 comes before
> every fix below.

- [ ] **B1. Bind `vip_chi_sva` to the MC's CHI interface, both flows.**
      Nothing in `testbench/sv/tb/` or `testbench/py/tb/` instantiates it today.
      Recipe from the agent's own top (`testbench/sv/tb/chi_tb_top.sv:195`):

      ```systemverilog
      vip_chi_sva #(.CFG_P(VIP_CHI_CFG_C),
                    .FLIT_TYPES_T(chi_types_t),
                    .ROLE_P(VIP_CHI_ROLE_SNF_E))
        mc_chi_sva (.vif(<the MC's chi if>),
          .checks_enable((<if>.txlinkactivereq === 1'b1) ||
                         (<if>.rxlinkactivereq === 1'b1)),
          .dat_reorder_allowed(...), .dat_interleave_allowed(...),
          .txsactive_extend_max_cycles(...),
          .link_activation_timeout_cycles(...),
          .link_deactivation_timeout_cycles(...));
      ```

      Bind at **both** ends — the RN-I side and the MC side. A rule whose
      evidence can only appear at one end of a link is dead at the other by
      polarity, and one-ended binding is how half a registry goes quiet without
      anyone noticing.

- [ ] **B2. Fail the run on a checker report.** The agent counts violations into
      `vif.check_fail_count[]` and expects the environment to raise; an SVA
      `$error` alone does **not** fail a UVM run (exit 0, no UVM_ERROR). Mirror
      what `chi_tb_env`/`chi_tb_pkg` do: sum both binds' counts in
      `report_phase` and assert zero. Without B2 the bind is decoration.

- [ ] **B3. Export per-rule tallies and check for vacuity.** The agent ships
      `scripts/check_vacuity.py` and a CSV export (`VIP_CHI_CHECK_CSV`). Wire it
      in, or the MC has no way to tell "this rule passed" from "this rule never
      ran". Expect a long NOT-EXERCISED list on first run — an SN link cannot
      reach snoop, atomic or coherent-read rules, and that is correct rather
      than a gap.

---

## C. Conformance defects the checker will report

Each of these is in the MC's own CHI implementation and is a **DUT fix**, not a
testbench waiver. All four have Python twins that must move together.

- [ ] **C1. Every RSP flit goes out with FLITPEND low.** *(fires on every
      response, both flows)*

      `sv/vip_mc_chi_driver.sv:957-958` drives `txrspflitpend <= 1'b0` in the
      same cycle as `txrspflitv <= 1'b1`, and nothing asserts it beforehand.
      Python twin: `py/vip_mc_chi_driver.py:604`,
      `self.vif.drive(txrspflitpend=0, txrspflitv=1)`.

      IHI 0050 E §14.4 / D §13.4: *"It is required that the signal is asserted
      exactly one cycle before a flit is sent from the transmitter."* The agent
      now checks it as `CHI_RSP_VALID_REQUIRES_PEND` (`flitv |-> $past(flitpend)`).

      **Fix shape:** route every send site through one `announce_flit` helper that
      raises FLITPEND, waits a cycle, then drives the flit. When the agent made
      this change internally it touched **31 send sites in SV and 26 in Python
      across five driver families** — expect the helper, not a local patch. Note
      that every beat of a burst needs announcing, not just the first.

- [ ] **C2. DAT FLITPEND is being used as a "more beats coming" marker.**
      *(fires once per transfer)*

      `sv/vip_mc_chi_driver.sv:991` drives `txdatflitpend <= !is_last` *with* the
      beat. Python twin: `py/vip_mc_chi_driver.py:619`.

      That happens to satisfy the rule for beats 2..N — beat k asserts it and
      beat k+1 arrives next cycle — so the failures are exactly the **first beat
      of every transfer** and **every single-beat transfer**, where nothing
      announced. The signal means "a flit *might* be sent next cycle", not "more
      beats follow"; the two coincide often enough to hide the difference, which
      is why this needs correcting rather than shifting by a cycle.

- [ ] **C3. The SN advertises 16 receive credits; the protocol maximum is 15.**
      *(fires on all three channels, every run)*

      `sv/vip_mc_chi_cfg.sv:44-46` and `py/vip_mc_chi_cfg.py:36-38` both default
      `initial_{req,rsp,dat}_credits = 16`.

      IHI 0050 E §14.2.1 / D §13.2.1: *"The maximum number of L-Credits that a
      receiver can provide is 15."* One LCRDV per channel, so the bound is per
      channel. `CHI_LCRD_OVERFLOW`'s bound was **64** when this submodule was
      pinned — a number the specification does not contain — and is 15 as of the
      agent's `27c534d`. A receiver granting 16 was over-granting all along and
      every grant was reported as fine.

      **Fix:** default to 15 (or lower) in both ports, and extend the validator —
      `sv/vip_mc_chi_cfg.sv:65-75` and the Python twin currently check only
      `>= 1`, so the upper bound is unguarded. *Decide deliberately* whether to
      make 16 impossible or merely non-default: the agent kept its own knob able
      to express 16 on purpose, because a configuration that cannot model a
      broken peer cannot be used to control the checker that catches one.

- [ ] **C4. TXSACTIVE is pulsed per flit.** *(fires where the sideband rules are
      live)*

      `sv/vip_mc_chi_driver.sv:999` drives `txsactive <= sending` — high only in
      cycles the MC actually transmits.

      IHI 0050 E §14.7.2: an SN *"must assert TXSACTIVE after receiving a
      transaction initiating flit and it must be asserted before or in the same
      cycle in which its first Response flit is sent. It must keep TXSACTIVE
      asserted until after the final completing flit is sent or received."* A
      per-flit pulse under-asserts, and **under-assertion is the violation** —
      over-assertion is legal, because the signal is permissive ("may have
      outstanding"). So the fix is a counted outstanding window, not a wider
      pulse.

      This is the same defect as F-CORR-005 in the agent's HN-F, where the fix
      was a `tx_activity_begin`/`_end`/`_tick` triple with the drop deferred to a
      per-cycle tick. Reuse that shape.

---

## D. Testbench-side fixes

- [ ] **D1. Remove the 29 `set_allow_retry(1'b0)` calls.** *(29 sites across 13
      files, both flows)*

      IHI 0050 E §2.6.5: a request may clear AllowRetry only when it is spending
      a **pre-allocated P-Credit**, and §2.10 closes the loophole — a credit's
      TgtID must come from the RetryAck's SrcID or the original TgtID, so no
      credit can exist outside the retry flow. This MC issues **no RetryAck and
      no PCrdGrant anywhere** (`grep RETRY_ACK|PCRD_GRANT sv/vip_mc_chi_driver.sv`
      is empty), so no P-Credit can ever exist here and every one of these calls
      is a non-conformant first attempt.

      The agent now reports it as `CHI_REQ_RETRY_SPENDS_GRANTED_CREDIT`. The same
      cleanup inside the agent (`676bf14`) found **83 files per port**, and two
      lessons transfer:
      - The determinism these calls were reaching for is already provided by a
        completer that never retries. Deleting them changes no behaviour.
      - **Search for the call, not the argument.** A regex matching the literal
        `0` left the agent's two ports asymmetric and the straggler survived a
        full sweep.

- [ ] **D2. Re-check the CHI testcase expectations against the new defaults.**
      The agent's base sequence now stamps `allowretry = 1` where it previously
      left the field at whatever the caller set. Any MC testcase asserting on
      observed REQ field values needs re-reading, not just re-running.

---

## E. Gates before calling it done

- [ ] **E1.** Both flows green: SV regression and the pyUVM/cocotb sweep.
- [ ] **E2.** `scripts/check_vacuity.py` exits 0, and every rule that *should*
      be reachable on an SN link has non-zero passes. **A new rule that records
      zero passes is not "clean", it is unevaluated** — read the tally, put the
      number in the commit message.
- [ ] **E3.** Each of C1–C4 has something that **fails before the fix and passes
      after**. A conformance fix with no failing observation is indistinguishable
      from a comment.
- [ ] **E4.** Re-pin the submodule and update `docs/IMPLEMENTATION_PLAN.md` /
      `docs/FURTHER_WORK.md` with whatever is deliberately left open.

---

## Sequencing

```
B1 ──> B2 ──> B3            bind, make it fail, make it measurable
        │
        ├──> C3   (one-line default + validator; do it first, it is free)
        ├──> D1   (mechanical, 29 sites; unblocks clean runs)
        ├──> C1 ─> C2   (same send path — one helper, one commit)
        └──> C4   (independent; counted window)
                    │
                    └──> E1..E4
```

C3 and D1 first: both are cheap and each removes a class of report that would
otherwise bury C1/C2's output. C1 and C2 are one commit because they are the same
code path and a partial fix leaves FLITPEND meaning two different things on two
channels.

---

## Appendix: how this was measured

```bash
# gap
cd vip_chi_agent && git rev-list --count ce6449e..HEAD          # 83
git diff --stat ce6449e..HEAD -- sv/ py/ | tail -1              # 49 files, +22012 -1065

# check registry
diff <(git show ce6449e:sv/vip_chi_types_pkg.sv | grep -oE 'VIP_CHI_CHK_\w+_E' | sort -u) \
     <(grep -oE 'VIP_CHI_CHK_\w+_E' sv/vip_chi_types_pkg.sv | sort -u)   # 80 added, 0 removed

# cfg struct and flit structs: extracted and compared field-by-field, in order
# (a text diff is not enough -- the SNP change was a REORDER, which a set
#  comparison would have missed entirely)

# MC side
grep -rn 'flitpend' sv/vip_mc_chi_driver.sv py/vip_mc_chi_driver.py
grep -rn 'initial_.*credits' sv/vip_mc_chi_cfg.sv py/vip_mc_chi_cfg.py
grep -rc 'set_allow_retry' testbench/sv/tc/*.sv testbench/py/tc/*.py   # 29 / 13 files
grep -rn 'vip_chi_sva' testbench/                                      # nothing
```

**Not measured, and stated as unknown rather than guessed:** whether C1–C4 are
the *only* reports. Three of them fire on every run and will mask whatever sits
behind them, and roughly 40 of the 80 new checks judge completer-side behaviour.
The honest expectation is that B1 produces a second list — RSP field legality
(Table A-4), `DAT_HOME_NID_LEGAL`, `DAT_CBUSY_LEGAL`,
`ORDERED_READ_RECEIPT_BEFORE_DAT` and the LASM family are all plausible — and
that list cannot be written before the bind exists. Do not treat C1–C4 as a
closed set.

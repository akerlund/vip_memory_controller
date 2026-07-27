# vip_mc example — test-case catalog

The shared regression runs **56** testcases across both flows: the SystemVerilog
UVM example in [sv/](sv/) and the pyUVM/cocotb port in [py/](py/). Each builds
its env (only one test runs per `simv`, see [sv/UVM_TB.md](sv/UVM_TB.md) §1/§3),
drives a full `manager → vip_mc → vip_dram` scenario, and checks read-back data,
telemetry counters, and/or the timing scoreboard. This catalog is the
authoritative list; the per-flow READMEs do not duplicate it.

The Python flow adds one flow-only testcase, `tc_mc_core_slice` — a pure
controller-core unit slice with no HDL activity — for 57 total.

Build and run the SV flow from the repository root with:

```sh
fusesoc --cores-root=. run --clean --setup --build --target=default --tool=vcs \
  akerlund::vip_mc_example:0
./build/akerlund__vip_mc_example_0/default-vcs/akerlund__vip_mc_example_0 \
  +UVM_TESTNAME=<name>
```

Run the Python flow with:

```sh
./testbench/py/run_fusesoc.sh --target sim
```

Legend for the **Env** column:

- `AXI4` — default two-port AXI4 env (`mc_tb_env`, timing scoreboard on).
- `CHI-D` / `CHI-E` / `CHI-N32` — self-contained one-port CHI SN env
  (`mc_chi_tb_env`), issue D / issue E / 32 B-DAT respectively.
- `MIXED` — self-contained AXI4 + CHI-D env over one shared device.
- `NARROW` — self-contained one-port AXI4 env over a 128 B-row device.
- `MULTIRANK` — self-contained one-port AXI4 env over a 2-rank device.

## Runtime

Measured from fresh logs in `testbench/sv/rundir/vcs` and
`testbench/py/rundir/verilator/default`. The SV flow uses the
`clk_rst_agent` 10 ns clock, and the Python flow starts cocotb with the
same 10 ns clock period. Clock columns are simulator time / 10 ns;
half-clock values are possible because test completion can occur between
active clock edges. Every testcase below runs in both flows. The Python-only
`tc_mc_core_slice` measured 0.0 ns — it drives no clock — and is not part of
the SV UVM catalog.

The last two rows are deliberately long. `tc_mc_axi4_soak` replays a randomized
program rather than one directed scenario, and `tc_mc_refresh_realistic` has to
span several native `tREFI` windows for a refresh to fire at all. Together they
are roughly half the regression's simulated time; the rest of the suite still
runs in tens to hundreds of clocks per test.

| Test | Env | SV time | SV clocks | PY time | PY clocks |
| --- | --- | ---: | ---: | ---: | ---: |
| `tc_mc_axi4_single_beat` | AXI4 | 325.0 ns | 32.5 | 210.0 ns | 21.0 |
| `tc_mc_axi4_burst` | AXI4 | 345.0 ns | 34.5 | 420.0 ns | 42.0 |
| `tc_mc_axi4_wrap` | AXI4 | 345.0 ns | 34.5 | 280.0 ns | 28.0 |
| `tc_mc_axi4_fixed` | AXI4 | 295.0 ns | 29.5 | 270.0 ns | 27.0 |
| `tc_mc_axi4_narrow_unaligned` | AXI4 | 295.0 ns | 29.5 | 210.0 ns | 21.0 |
| `tc_mc_axi4_exclusive` | AXI4 | 635.0 ns | 63.5 | 530.0 ns | 53.0 |
| `tc_mc_axi4_read_multi_id` | AXI4 | 390.0 ns | 39.0 | 320.0 ns | 32.0 |
| `tc_mc_axi4_user_passthrough` | AXI4 | 275.0 ns | 27.5 | 210.0 ns | 21.0 |
| `tc_mc_axi4_outstanding_limit` | AXI4 | 360.0 ns | 36.0 | 320.0 ns | 32.0 |
| `tc_mc_axi4_aw_backpressure` | AXI4 | 270.0 ns | 27.0 | 260.0 ns | 26.0 |
| `tc_mc_axi4_rsp_backpressure` | AXI4 | 360.0 ns | 36.0 | 320.0 ns | 32.0 |
| `tc_mc_axi4_bresp_backpressure` | AXI4 | 270.0 ns | 27.0 | 330.0 ns | 33.0 |
| `tc_mc_axi4_wready_backpressure` | AXI4 | 305.0 ns | 30.5 | 240.0 ns | 24.0 |
| `tc_mc_qos_scheduling` | AXI4 | 500.0 ns | 50.0 | 460.0 ns | 46.0 |
| `tc_mc_qos_aging` | AXI4 | 530.0 ns | 53.0 | 490.0 ns | 49.0 |
| `tc_mc_axi4_ooo_inter_id` | AXI4 | 590.0 ns | 59.0 | 520.0 ns | 52.0 |
| `tc_mc_axi4_fr_fcfs_mixed_rd_wr` | AXI4 | 820.0 ns | 82.0 | 750.0 ns | 75.0 |
| `tc_mc_fr_fcfs_starvation_cap` | AXI4 | 870.0 ns | 87.0 | 800.0 ns | 80.0 |
| `tc_mc_rd_wr_grouping` | AXI4 | 1530.0 ns | 153.0 | 1460.0 ns | 146.0 |
| `tc_mc_axi4_page_hit_streak` | AXI4 | 2445.0 ns | 244.5 | 2380.0 ns | 238.0 |
| `tc_mc_axi4_write_coalesce` | AXI4 | 1950.0 ns | 195.0 | 1890.0 ns | 189.0 |
| `tc_mc_axi4_read_pipeline` | AXI4 | 320.0 ns | 32.0 | 280.0 ns | 28.0 |
| `tc_mc_cfg` | AXI4 | 120.0 ns | 12.0 | 90.0 ns | 9.0 |
| `tc_mc_axi4_agent` | AXI4 | 260.0 ns | 26.0 | 220.0 ns | 22.0 |
| `tc_mc_axi4_multi_port` | AXI4 | 415.0 ns | 41.5 | 320.0 ns | 32.0 |
| `tc_mc_axi4_unsupported_reject` | AXI4 | 530.0 ns | 53.0 | 430.0 ns | 43.0 |
| `tc_mc_ecc_slverr` | AXI4 | 615.0 ns | 61.5 | 500.0 ns | 50.0 |
| `tc_mc_refresh` | AXI4 | 265.0 ns | 26.5 | 220.0 ns | 22.0 |
| `tc_mc_refresh_deferred` | AXI4 | 1335.0 ns | 133.5 | 1290.0 ns | 129.0 |
| `tc_mc_refresh_collision` | AXI4 | 660.0 ns | 66.0 | 960.0 ns | 96.0 |
| `tc_mc_reset_recovery` | AXI4 | 310.0 ns | 31.0 | 230.0 ns | 23.0 |
| `tc_mc_init_delay` | AXI4 | 525.0 ns | 52.5 | 450.0 ns | 45.0 |
| `tc_mc_multi_rank` | MULTIRANK | 3645.0 ns | 364.5 | 3570.0 ns | 357.0 |
| `tc_mc_preset_sweep` | AXI4 | 945.0 ns | 94.5 | 790.0 ns | 79.0 |
| `tc_mc_telemetry_counters` | AXI4 | 370.0 ns | 37.0 | 330.0 ns | 33.0 |
| `tc_mc_status_probe` | AXI4 | 8315.0 ns | 831.5 | 2050.0 ns | 205.0 |
| `tc_mc_observability` | AXI4 | 525.0 ns | 52.5 | 440.0 ns | 44.0 |
| `tc_mc_chi_d_write_read` | CHI-D | 470.0 ns | 47.0 | 410.0 ns | 41.0 |
| `tc_mc_chi_d_read` | CHI-D | 380.0 ns | 38.0 | 320.0 ns | 32.0 |
| `tc_mc_chi_d_write_ptl` | CHI-D | 550.0 ns | 55.0 | 500.0 ns | 50.0 |
| `tc_mc_chi_d_decerr` | CHI-D | 420.0 ns | 42.0 | 360.0 ns | 36.0 |
| `tc_mc_chi_d_combined_write` | CHI-D | 430.0 ns | 43.0 | 370.0 ns | 37.0 |
| `tc_mc_chi_d_unsupported` | CHI-D | 530.0 ns | 53.0 | 470.0 ns | 47.0 |
| `tc_mc_chi_d_persist` | CHI-D | 740.0 ns | 74.0 | 690.0 ns | 69.0 |
| `tc_mc_chi_d_reject` | CHI-D | 1160.0 ns | 116.0 | 1130.0 ns | 113.0 |
| `tc_mc_chi_e_write_read` | CHI-E | 470.0 ns | 47.0 | 410.0 ns | 41.0 |
| `tc_mc_chi_e_write_zero` | CHI-E | 580.0 ns | 58.0 | 530.0 ns | 53.0 |
| `tc_mc_chi_e_read_sep` | CHI-E | 480.0 ns | 48.0 | 420.0 ns | 42.0 |
| `tc_mc_narrow_axi4` | NARROW | 470.0 ns | 47.0 | 420.0 ns | 42.0 |
| `tc_mc_chi_d_narrow` | CHI-N32 | 500.0 ns | 50.0 | 440.0 ns | 44.0 |
| `tc_mc_mixed_concurrent` | MIXED | 1490.0 ns | 149.0 | 1470.0 ns | 147.0 |
| `tc_mc_equiv_axi4` | AXI4 | 755.0 ns | 75.5 | 660.0 ns | 66.0 |
| `tc_mc_equiv_chi_d` | CHI-D | 1050.0 ns | 105.0 | 1040.0 ns | 104.0 |
| `tc_mc_equiv_chi_e` | CHI-E | 1050.0 ns | 105.0 | 1040.0 ns | 104.0 |
| `tc_mc_axi4_soak` | AXI4 | 12045.0 ns | 1204.5 | 11330.0 ns | 1133.0 |
| `tc_mc_refresh_realistic` | AXI4 | 39145.0 ns | 3914.5 | 39450.0 ns | 3945.0 |

---

## AXI4 datapath

| Test | Env | Proves |
| --- | --- | --- |
| `tc_mc_axi4_single_beat` | AXI4 | write-then-read reaches `vip_dram`; DECERR short-circuits at the FE. |
| `tc_mc_axi4_burst` | AXI4 | one aligned full-width INCR write burst + matching read burst replay beat-for-beat; FE/backend counters agree. |
| `tc_mc_axi4_wrap` | AXI4 | WRAP burst preserves wrapped beat order on the bus while the backend stores rows in wrap-region address order, **and** the device access is issued at the wrap-region base rather than the AXI start address. The burst starts mid-region so the two differ; the address check is explicit because a WRAP read-back rotates the same way a misplaced write does and cannot catch it (see Notes). |
| `tc_mc_axi4_fixed` | AXI4 | a narrow unaligned FIXED burst packs to one DRAM row access; repeated FIXED reads replay the final stored bytes. |
| `tc_mc_axi4_narrow_unaligned` | AXI4 | a 2-beat 4 B INCR burst at an unaligned base packs into one row access and unpacks correctly on read-back. |
| `tc_mc_axi4_exclusive` | AXI4 | exclusive read→write returns EXOKAY + updates memory; an intervening normal write makes the exclusive write return OKAY and not modify memory. |
| `tc_mc_axi4_read_multi_id` | AXI4 | two concurrent reads with distinct ARIDs both complete with correct data; AXI4 has no read-data interleaving, so each burst's beats return contiguously while whole-burst order across IDs follows device timing. |
| `tc_mc_axi4_user_passthrough` | AXI4 | BUSER/RUSER echo AxUSER and WUSER is preserved inside the FE command entry. |

## AXI4 backpressure & outstanding limits

| Test | Env | Proves |
| --- | --- | --- |
| `tc_mc_axi4_outstanding_limit` | AXI4 | saturating the read outstanding limit holds ARREADY low until the oldest read completes (no response-buffer pressure involved). |
| `tc_mc_axi4_aw_backpressure` | AXI4 | saturating the write outstanding limit holds AWREADY low until the oldest write response completes. |
| `tc_mc_axi4_rsp_backpressure` | AXI4 | a depth-1 response buffer with stalled RREADY drops ARREADY until the blocked read response is consumed. |
| `tc_mc_axi4_bresp_backpressure` | AXI4 | a depth-1 response buffer with stalled BREADY holds AWREADY low until the blocked BRESP is consumed. |
| `tc_mc_axi4_wready_backpressure` | AXI4 | a one-slot W-buffer drops WREADY mid-burst before a 2-beat burst completes. |

## AXI4 scheduling (QoS / FR-FCFS / page)

| Test | Env | Proves |
| --- | --- | --- |
| `tc_mc_qos_scheduling` | AXI4 | the backend QoS-class arbiter grants a higher class ahead of older lower-class requests; same-stream order preserved; `qos_class_count == 1` reverts to FCFS. |
| `tc_mc_qos_aging` | AXI4 | a low-class request behind a saturating high-class stream is aging-promoted and issued within ≈`(class_count-1)·aging_ns` rather than starved. |
| `tc_mc_axi4_ooo_inter_id` | AXI4 | with the device window held full, a younger page hit queued behind an older page miss is granted and completes first once credit returns (FR-FCFS tie-break); the §11 `observed_reorder_count` records the out-of-order retirement (≥ 1). |
| `tc_mc_axi4_fr_fcfs_mixed_rd_wr` | AXI4 | the op-agnostic FR-FCFS selector grants a younger write hit before an older read miss when its predicted completion is earlier. |
| `tc_mc_fr_fcfs_starvation_cap` | AXI4 | §11 item 1 fairness cap: with `fr_fcfs_starvation_cap = 2`, an old page miss behind a younger page-hit streak is reordered past exactly twice, then force-served (FCFS override) before the remaining hits; `get_fr_fcfs_forced_count()` advances. |
| `tc_mc_rd_wr_grouping` | AXI4 | §11 item 1 turnaround-aware grouping: with `rd_wr_grouping_enable` and a read as the last issued command, expensive read page-misses and cheap write page-hits sit co-pending behind a held device window; grouping drains all reads before either write (pure readiness would grant the cheaper writes first), `get_rd_wr_grouped_count()` advances, and `get_bus_turnaround_count()` is exactly 1. |
| `tc_mc_axi4_page_hit_streak` | AXI4 | a long same-row burst is governed device-side by `tCCD_L` per column access while AXI completion still matches the scoreboard. |
| `tc_mc_axi4_write_coalesce` | AXI4 | with `write_coalescing_enable` + a pipelined manager (`man_wr_outstanding_max>1`), two same-line writes co-pending behind a held device window merge into one device access; both still get an OKAY BRESP (fan-out), the byte-lane overlay is correct, and `coalesced_write_count==1`. |
| `tc_mc_axi4_soak` | AXI4 | the suite's one constrained-random test: ~96 randomized transactions (INCR/WRAP/FIXED, narrow and full-width, 1..16 beats, 4 ids, full QoS range, 0..8-clock gaps) replayed concurrently on both ports, every read byte checked against a golden model and the whole written image swept through the device backdoor at the end. Stimulus comes from `mc_soak_gen`, a shared explicit LCG that emits byte-identical programs in both flows, so a failure reproduces in both. `+MC_SOAK_SEED` / `+MC_SOAK_TXNS` / `+MC_SOAK_WRAP_PCT` (env vars of the same name in the Python flow). |
| `tc_mc_axi4_read_pipeline` | AXI4 | with a pipelined manager (`man_rd_outstanding_max>1`), N reads-with-response are issued via `vip_axi4_pipelined_seq`; all return their own correct data and the FE's peak in-flight read count exceeds 1 (a serial manager never would). |

## AXI4 config, agent & reject

| Test | Env | Proves |
| --- | --- | --- |
| `tc_mc_cfg` | AXI4 | the AXI4 config object, per-port runtime map, and `env_cfg` holder / device-handle path against a real `vip_dram`. |
| `tc_mc_axi4_agent` | AXI4 | the stock `vip_axi4` MANAGER driving 1:1 into `vip_mc`'s owned interfaces through `vip_mc_axi4_connect`. |
| `tc_mc_axi4_multi_port` | AXI4 | both AXI4 front-ends register, issue through the shared backend, and return data on the correct port. |
| `tc_mc_axi4_unsupported_reject` | AXI4 | unsupported transfer shapes terminate locally with SLVERR and never forward a request to the backend/device. |
| `tc_mc_ecc_slverr` | AXI4 | §11 item 5 ECC/SECDED: the device physically corrupts a read-fault row injected via `vip_dram::inject_fault`, and `cfg.ecc_enable` repairs/classifies it — a CORRECTABLE row is un-flipped and reads OKAY with data restored byte-for-byte (`ecc_corrected_count`), an UNCORRECTABLE row returns SLVERR carrying poisoned data (`ecc_uncorrectable_count`), and disabling ECC returns the corrupted bytes as OKAY (silent data corruption, counters frozen). |

## Refresh, reset, init & geometry

| Test | Env | Proves |
| --- | --- | --- |
| `tc_mc_refresh` | AXI4 | controller-emitted refreshes (shortened `tREFI`) match the device-observed refresh count. |
| `tc_mc_refresh_realistic` | AXI4 | the only test where a refresh fires because time passed: no `tREFI` override, continuous checked traffic across 5 native 7800 ns intervals (~39 us). Emitted refresh count matches elapsed time / `tREFI` within one interval, the device executed every one, and no access across a refresh loses or corrupts data. `+MC_REFRESH_INTERVALS` (env var of the same name in the Python flow) lengthens it. |
| `tc_mc_refresh_deferred` | AXI4 | `DEFERRED` policy postpones refreshes (debt ≤ `refresh_max_deferred = 4`) then drains a catch-up burst; ≥1 catch-up, debt never exceeds the limit, MC count == device count. |
| `tc_mc_refresh_collision` | AXI4 | a REF forced between two reads (short `tREFI` + 1-deep window) makes the second read issue only after REF and pick up `tRFC`. |
| `tc_mc_reset_recovery` | AXI4 | a mid-flight read cancelled by `rst_n` never appears on R; the post-reset read to the same address completes and is classified page-empty again. |
| `tc_mc_init_delay` | AXI4 | a 300 ns bring-up hold-off keeps the first post-reset write from completing until bring-up ends, while a later write completes promptly. |
| `tc_mc_multi_rank` | MULTIRANK | a 2-rank geometry accepts traffic on both ranks and emits REF for both ranks (observed off `issued_port`). |
| `tc_mc_preset_sweep` | AXI4 | for every `vip_dram` timing preset, one write+read keeps matching `dram.predict()` — no hard-coded per-preset latencies. |

## Observability

| Test | Env | Proves |
| --- | --- | --- |
| `tc_mc_telemetry_counters` | AXI4 | the §8.8 telemetry getters cross-check against an independent `issued_port` + `dram.rsp_port` observation path under a mixed empty/hit/miss read stream. |
| `tc_mc_status_probe` | AXI4 | the optional `status_vif` fields track queueing/backpressure, block-reason, and hit/miss regimes for wave debug (§8.8A). |
| `tc_mc_observability` | AXI4 | the §11 residual telemetry: pending-depth occupancy histogram (buckets sum to sample count, peak depth ≥ 1), completion-latency stats (0 < min ≤ mean ≤ max, one sample per completion), and per-port completed/byte breakdown; the in-order stream leaves `observed_reorder_count == 0`. |

## CHI SN front-end (issue D)

| Test | Env | Proves |
| --- | --- | --- |
| `tc_mc_chi_d_write_read` | CHI-D | end-to-end: RN-I `WriteNoSnp` then `ReadNoSnp` of the same line; read-back matches through backend + `vip_dram`. |
| `tc_mc_chi_d_read` | CHI-D | a `ReadNoSnp` of an untouched line returns a well-formed `CompData` (opcode, beat count, TxnID echo). |
| `tc_mc_chi_d_write_ptl` | CHI-D | `WriteNoSnpPtl` byte-enables: enabled bytes update, disabled bytes unchanged — per-byte strobes reach the device. |
| `tc_mc_chi_d_decerr` | CHI-D | a read/write into the installed DECERR window returns `NONDATA_ERROR` with no device access; `decerr_count` corroborates. |
| `tc_mc_chi_d_combined_write` | CHI-D | with `split_write_rsp = 0` the FE completes a write in a single `CompDBIDResp`; the write still lands (read-back matches). |
| `tc_mc_chi_d_unsupported` | CHI-D | a raw `AtomicStore0` REQ is rejected with `Comp(NONDATA_ERROR)`, bumps `unsupported_count`, and never reaches the device. |
| `tc_mc_chi_d_persist` | CHI-D | `CleanSharedPersist` → `Comp` and `CleanSharedPersistSep` → `Persist` + `CompPersist`; both bump `persist_count`, no device access, `unsupported_count == 0`. |
| `tc_mc_chi_d_reject` | CHI-D | atomic families (Store/Load/Swap/Compare) are each rejected with `Comp(NONDATA_ERROR)` and never touch the device (SN has no SNP channel, so snoop/DVM have no reject path). |

## CHI-E matrix (issue E)

| Test | Env | Proves |
| --- | --- | --- |
| `tc_mc_chi_e_write_read` | CHI-E | the same logical write/read as the CHI-D case runs under issue = E and matches byte-for-byte — the D/E equivalence point. |
| `tc_mc_chi_e_write_zero` | CHI-E | `WriteNoSnpZero` (no data phase) writes a full line of zeros and completes with `Comp`; `write_count` advances for both the seeding write and the zero. |
| `tc_mc_chi_e_read_sep` | CHI-E | `ReadNoSnpSep` returns data as `DataSepResp` (not `CompData`) routed to ReturnNID/ReturnTxnID with the correct payload. |

## Multi-beat / narrow-bus

| Test | Env | Proves |
| --- | --- | --- |
| `tc_mc_narrow_axi4` | NARROW | 64 B host bus over a 128 B row: a 2-beat gather fills one row; a single 64 B beat scatters into the correct row half with lane-correct placement. |
| `tc_mc_chi_d_narrow` | CHI-N32 | 32 B DAT over a 64 B row: a 64 B `WriteNoSnp` gathers two DAT beats into one row word and a `ReadNoSnp` scatters the row word back into two beats, per-beat lane-checked. |

## Cross-protocol

| Test | Env | Proves |
| --- | --- | --- |
| `tc_mc_mixed_concurrent` | MIXED | an AXI4 port and a CHI-D port on one `vip_mc`/backend/device, driven concurrently to disjoint windows, both read back correctly — concurrent cross-protocol arbitration with no interference. |
| `tc_mc_equiv_axi4` | AXI4 | the shared deterministic program (full / partial-BE writes + reads) replayed through AXI4, every read checked against a fresh golden model. |
| `tc_mc_equiv_chi_d` | CHI-D | the identical program replayed through the CHI-D SN front-end against the same model logic. |
| `tc_mc_equiv_chi_e` | CHI-E | the identical program replayed through the CHI-E SN front-end. All three equiv legs passing proves byte-identical device state + read data across the protocols. |

---

## Notes

- The `tc_mc_equiv_chi_d` / `_chi_e` leaves are parameterized
  specializations of one `mc_equiv_chi_base_test #(...)` body; likewise the CHI-E
  and narrow-DAT tests are `mc_chi_base_test #(...)` leaves over one
  parameterized CHI env/base. See [sv/UVM_TB.md](sv/UVM_TB.md) §1.
- **Functional coverage** is collected by every AXI4/CHI/mixed test and reported
  at `report_phase` under a `[COV]` prefix. Three collectors, all opt-out with
  `mc_coverage_enabled = 0`:
  - `vip_axi4_coverage` per manager port — AXI4 protocol coverage (size, burst,
    len, resp, alignment, 4 KB crossing, narrow, WSTRB, backpressure,
    outstanding, out-of-order). Ships with the agent; the `vip_mc` envs simply
    never instantiated it before.
  - `vip_chi_coverage` on the CHI and mixed envs — CHI REQ/RSP/DAT opcodes,
    write flow, QoS, alignment.
  - `mc_coverage` (`tb/mc_coverage.sv`, `tb/mc_coverage.py`) — the
    controller-specific layer the agents cannot see: scheduling decisions off
    the backend grant tap (op, burst, QoS class, starvation bypass, coalesce
    fan-out, rank/bank-group/bank), device outcome joined back by tag (page
    hit/miss/empty, ECC severity), bus turnaround between consecutive grants
    including the refresh-adjacent transitions, and host completion responses
    per port.
  SV and Python percentages are **not** comparable — pyvsc and SV covergroups
  weight bins differently. Treat them as two independent scores over the same
  intent. The Python numbers also accumulate across the whole regression (one
  process), while each SV test is its own `simv` and reports only its own.
- **Fixed: WRAP device placement.** Found by `tc_mc_axi4_soak` on its first run.
  The device request went out at the AXI start address (`vip_mc_backend`
  `req.addr = entry.addr`) while `pack_write_beat` / `unpack_read_beat` index the
  payload rows from the wrap-region base. A WRAP burst not starting at its region
  base was therefore written rotated by the start offset, with its last row one
  row past the region — corrupting a neighbour it never touched. A WRAP read of
  the same shape rotated identically, so read-after-write hid it, and the
  directed `tc_mc_axi4_wrap` passed throughout; only a non-WRAP observer (the
  soak's backdoor sweep) could see it.
  The device address is now taken from `vip_mc_cmd_entry::get_dev_addr()` — the
  burst window base, which is where the payload rows are indexed from — with the
  window arithmetic defined once in `vip_mc_axi4_types_pkg`. Guarded two ways:
  `tc_mc_axi4_wrap` asserts the issued device address directly (seed-independent),
  and the soak carries WRAP at 15% of its default mix. Regression case: seed 1,
  port 1 txn 12 (WRAP, 4 x 64 B, start `0xbbdc40`, region base `0xbbdc00`).
- Coverage still owed (tracked in `vip_mc/IMPLEMENTATION_PLAN.md` §11):
  multi-channel striping, sub/pseudo-channel dispatch, a DFI face, and a dynamic
  timing-retune wrapper. (Write coalescing, the first residual-observability
  batch, and the ECC/SECDED read-fault slice have landed.)

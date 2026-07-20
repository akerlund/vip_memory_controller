# vip_mc example — test-case catalog

The shared regression runs **53** UVM testcases. Each builds its env (only one
test runs per `simv`, see [UVM_TB.md](UVM_TB.md) §1/§3), drives a full
`manager → vip_mc → vip_dram` scenario, and checks read-back data, telemetry
counters, and/or the timing scoreboard. Run one with
`./build/akerlund__vip_mc_example_0/default-vcs/akerlund__vip_mc_example_0 +UVM_TESTNAME=<name>`;
build from the repository root with
`fusesoc --cores-root=. run --clean --setup --build --target=default --tool=vcs akerlund::vip_mc_example:0`.

Legend for the **Env** column:

- `AXI4` — default two-port AXI4 env (`vip_mc_tb_env`, timing scoreboard on).
- `CHI-D` / `CHI-E` / `CHI-N32` — self-contained one-port CHI SN env
  (`vip_mc_chi_tb_env`), issue D / issue E / 32 B-DAT respectively.
- `MIXED` — self-contained AXI4 + CHI-D env over one shared device.
- `NARROW` — self-contained one-port AXI4 env over a 128 B-row device.
- `MULTIRANK` — self-contained one-port AXI4 env over a 2-rank device.

---

## AXI4 datapath

| Test | Env | Proves |
| --- | --- | --- |
| `tc_vip_mc_axi4_single_beat` | AXI4 | write-then-read reaches `vip_dram`; DECERR short-circuits at the FE. |
| `tc_vip_mc_axi4_burst` | AXI4 | one aligned full-width INCR write burst + matching read burst replay beat-for-beat; FE/backend counters agree. |
| `tc_vip_mc_axi4_wrap` | AXI4 | WRAP burst preserves wrapped beat order on the bus while the backend stores rows in wrap-region address order. |
| `tc_vip_mc_axi4_fixed` | AXI4 | a narrow unaligned FIXED burst packs to one DRAM row access; repeated FIXED reads replay the final stored bytes. |
| `tc_vip_mc_axi4_narrow_unaligned` | AXI4 | a 2-beat 4 B INCR burst at an unaligned base packs into one row access and unpacks correctly on read-back. |
| `tc_vip_mc_axi4_exclusive` | AXI4 | exclusive read→write returns EXOKAY + updates memory; an intervening normal write makes the exclusive write return OKAY and not modify memory. |
| `tc_vip_mc_axi4_read_multi_id` | AXI4 | two concurrent reads with distinct ARIDs both complete with correct data; AXI4 has no read-data interleaving, so each burst's beats return contiguously while whole-burst order across IDs follows device timing. |
| `tc_vip_mc_axi4_user_passthrough` | AXI4 | BUSER/RUSER echo AxUSER and WUSER is preserved inside the FE command entry. |

## AXI4 backpressure & outstanding limits

| Test | Env | Proves |
| --- | --- | --- |
| `tc_vip_mc_axi4_outstanding_limit` | AXI4 | saturating the read outstanding limit holds ARREADY low until the oldest read completes (no response-buffer pressure involved). |
| `tc_vip_mc_axi4_aw_backpressure` | AXI4 | saturating the write outstanding limit holds AWREADY low until the oldest write response completes. |
| `tc_vip_mc_axi4_rsp_backpressure` | AXI4 | a depth-1 response buffer with stalled RREADY drops ARREADY until the blocked read response is consumed. |
| `tc_vip_mc_axi4_bresp_backpressure` | AXI4 | a depth-1 response buffer with stalled BREADY holds AWREADY low until the blocked BRESP is consumed. |
| `tc_vip_mc_axi4_wready_backpressure` | AXI4 | a one-slot W-buffer drops WREADY mid-burst before a 2-beat burst completes. |

## AXI4 scheduling (QoS / FR-FCFS / page)

| Test | Env | Proves |
| --- | --- | --- |
| `tc_vip_mc_qos_scheduling` | AXI4 | the backend QoS-class arbiter grants a higher class ahead of older lower-class requests; same-stream order preserved; `qos_class_count == 1` reverts to FCFS. |
| `tc_vip_mc_qos_aging` | AXI4 | a low-class request behind a saturating high-class stream is aging-promoted and issued within ≈`(class_count-1)·aging_ns` rather than starved. |
| `tc_vip_mc_axi4_ooo_inter_id` | AXI4 | with the device window held full, a younger page hit queued behind an older page miss is granted and completes first once credit returns (FR-FCFS tie-break); the §11 `observed_reorder_count` records the out-of-order retirement (≥ 1). |
| `tc_vip_mc_axi4_fr_fcfs_mixed_rd_wr` | AXI4 | the op-agnostic FR-FCFS selector grants a younger write hit before an older read miss when its predicted completion is earlier. |
| `tc_vip_mc_fr_fcfs_starvation_cap` | AXI4 | §11 item 1 fairness cap: with `fr_fcfs_starvation_cap = 2`, an old page miss behind a younger page-hit streak is reordered past exactly twice, then force-served (FCFS override) before the remaining hits; `get_fr_fcfs_forced_count()` advances. |
| `tc_vip_mc_rd_wr_grouping` | AXI4 | §11 item 1 turnaround-aware grouping: with `rd_wr_grouping_enable` and a read as the last issued command, expensive read page-misses and cheap write page-hits sit co-pending behind a held device window; grouping drains all reads before either write (pure readiness would grant the cheaper writes first), `get_rd_wr_grouped_count()` advances, and `get_bus_turnaround_count()` is exactly 1. |
| `tc_vip_mc_axi4_page_hit_streak` | AXI4 | a long same-row burst is governed device-side by `tCCD_L` per column access while AXI completion still matches the scoreboard. |
| `tc_vip_mc_axi4_write_coalesce` | AXI4 | with `write_coalescing_enable` + a pipelined manager (`man_wr_outstanding_max>1`), two same-line writes co-pending behind a held device window merge into one device access; both still get an OKAY BRESP (fan-out), the byte-lane overlay is correct, and `coalesced_write_count==1`. |
| `tc_vip_mc_axi4_read_pipeline` | AXI4 | with a pipelined manager (`man_rd_outstanding_max>1`), N reads-with-response are issued via `vip_axi4_pipelined_seq`; all return their own correct data and the FE's peak in-flight read count exceeds 1 (a serial manager never would). |

## AXI4 config, agent & reject

| Test | Env | Proves |
| --- | --- | --- |
| `tc_vip_mc_cfg` | AXI4 | the AXI4 config object, per-port runtime map, and `env_cfg` holder / device-handle path against a real `vip_dram`. |
| `tc_vip_mc_axi4_agent` | AXI4 | the stock `vip_axi4` MANAGER driving 1:1 into `vip_mc`'s owned interfaces through `vip_mc_axi4_connect`. |
| `tc_vip_mc_axi4_multi_port` | AXI4 | both AXI4 front-ends register, issue through the shared backend, and return data on the correct port. |
| `tc_vip_mc_axi4_unsupported_reject` | AXI4 | unsupported transfer shapes terminate locally with SLVERR and never forward a request to the backend/device. |
| `tc_vip_mc_ecc_slverr` | AXI4 | §11 item 5 ECC/SECDED: the device physically corrupts a read-fault row injected via `vip_dram::inject_fault`, and `cfg.ecc_enable` repairs/classifies it — a CORRECTABLE row is un-flipped and reads OKAY with data restored byte-for-byte (`ecc_corrected_count`), an UNCORRECTABLE row returns SLVERR carrying poisoned data (`ecc_uncorrectable_count`), and disabling ECC returns the corrupted bytes as OKAY (silent data corruption, counters frozen). |

## Refresh, reset, init & geometry

| Test | Env | Proves |
| --- | --- | --- |
| `tc_vip_mc_refresh` | AXI4 | controller-emitted refreshes (shortened `tREFI`) match the device-observed refresh count. |
| `tc_vip_mc_refresh_deferred` | AXI4 | `DEFERRED` policy postpones refreshes (debt ≤ `refresh_max_deferred = 4`) then drains a catch-up burst; ≥1 catch-up, debt never exceeds the limit, MC count == device count. |
| `tc_vip_mc_refresh_collision` | AXI4 | a REF forced between two reads (short `tREFI` + 1-deep window) makes the second read issue only after REF and pick up `tRFC`. |
| `tc_vip_mc_reset_recovery` | AXI4 | a mid-flight read cancelled by `rst_n` never appears on R; the post-reset read to the same address completes and is classified page-empty again. |
| `tc_vip_mc_init_delay` | AXI4 | a 300 ns bring-up hold-off keeps the first post-reset write from completing until bring-up ends, while a later write completes promptly. |
| `tc_vip_mc_multi_rank` | MULTIRANK | a 2-rank geometry accepts traffic on both ranks and emits REF for both ranks (observed off `issued_port`). |
| `tc_vip_mc_preset_sweep` | AXI4 | for every `vip_dram` timing preset, one write+read keeps matching `dram.predict()` — no hard-coded per-preset latencies. |

## Observability

| Test | Env | Proves |
| --- | --- | --- |
| `tc_vip_mc_telemetry_counters` | AXI4 | the §8.8 telemetry getters cross-check against an independent `issued_port` + `dram.rsp_port` observation path under a mixed empty/hit/miss read stream. |
| `tc_vip_mc_status_probe` | AXI4 | the optional `status_vif` fields track queueing/backpressure, block-reason, and hit/miss regimes for wave debug (§8.8A). |
| `tc_vip_mc_observability` | AXI4 | the §11 residual telemetry: pending-depth occupancy histogram (buckets sum to sample count, peak depth ≥ 1), completion-latency stats (0 < min ≤ mean ≤ max, one sample per completion), and per-port completed/byte breakdown; the in-order stream leaves `observed_reorder_count == 0`. |

## CHI SN front-end (issue D)

| Test | Env | Proves |
| --- | --- | --- |
| `tc_vip_mc_chi_d_write_read` | CHI-D | end-to-end: RN-I `WriteNoSnp` then `ReadNoSnp` of the same line; read-back matches through backend + `vip_dram`. |
| `tc_vip_mc_chi_d_read` | CHI-D | a `ReadNoSnp` of an untouched line returns a well-formed `CompData` (opcode, beat count, TxnID echo). |
| `tc_vip_mc_chi_d_write_ptl` | CHI-D | `WriteNoSnpPtl` byte-enables: enabled bytes update, disabled bytes unchanged — per-byte strobes reach the device. |
| `tc_vip_mc_chi_d_decerr` | CHI-D | a read/write into the installed DECERR window returns `NONDATA_ERROR` with no device access; `decerr_count` corroborates. |
| `tc_vip_mc_chi_d_combined_write` | CHI-D | with `split_write_rsp = 0` the FE completes a write in a single `CompDBIDResp`; the write still lands (read-back matches). |
| `tc_vip_mc_chi_d_unsupported` | CHI-D | a raw `AtomicStore0` REQ is rejected with `Comp(NONDATA_ERROR)`, bumps `unsupported_count`, and never reaches the device. |
| `tc_vip_mc_chi_d_persist` | CHI-D | `CleanSharedPersist` → `Comp` and `CleanSharedPersistSep` → `Persist` + `CompPersist`; both bump `persist_count`, no device access, `unsupported_count == 0`. |
| `tc_vip_mc_chi_d_reject` | CHI-D | atomic families (Store/Load/Swap/Compare) are each rejected with `Comp(NONDATA_ERROR)` and never touch the device (SN has no SNP channel, so snoop/DVM have no reject path). |

## CHI-E matrix (issue E)

| Test | Env | Proves |
| --- | --- | --- |
| `tc_vip_mc_chi_e_write_read` | CHI-E | the same logical write/read as the CHI-D case runs under issue = E and matches byte-for-byte — the D/E equivalence point. |
| `tc_vip_mc_chi_e_write_zero` | CHI-E | `WriteNoSnpZero` (no data phase) writes a full line of zeros and completes with `Comp`; `write_count` advances for both the seeding write and the zero. |
| `tc_vip_mc_chi_e_read_sep` | CHI-E | `ReadNoSnpSep` returns data as `DataSepResp` (not `CompData`) routed to ReturnNID/ReturnTxnID with the correct payload. |

## Multi-beat / narrow-bus

| Test | Env | Proves |
| --- | --- | --- |
| `tc_vip_mc_narrow_axi4` | NARROW | 64 B host bus over a 128 B row: a 2-beat gather fills one row; a single 64 B beat scatters into the correct row half with lane-correct placement. |
| `tc_vip_mc_chi_d_narrow` | CHI-N32 | 32 B DAT over a 64 B row: a 64 B `WriteNoSnp` gathers two DAT beats into one row word and a `ReadNoSnp` scatters the row word back into two beats, per-beat lane-checked. |

## Cross-protocol

| Test | Env | Proves |
| --- | --- | --- |
| `tc_vip_mc_mixed_concurrent` | MIXED | an AXI4 port and a CHI-D port on one `vip_mc`/backend/device, driven concurrently to disjoint windows, both read back correctly — concurrent cross-protocol arbitration with no interference. |
| `tc_vip_mc_equiv_axi4` | AXI4 | the shared deterministic program (full / partial-BE writes + reads) replayed through AXI4, every read checked against a fresh golden model. |
| `tc_vip_mc_equiv_chi_d` | CHI-D | the identical program replayed through the CHI-D SN front-end against the same model logic. |
| `tc_vip_mc_equiv_chi_e` | CHI-E | the identical program replayed through the CHI-E SN front-end. All three equiv legs passing proves byte-identical device state + read data across the protocols. |

---

## Notes

- The `tc_vip_mc_equiv_chi_d` / `_chi_e` leaves are parameterized
  specializations of one `vip_mc_equiv_chi_base_test #(...)` body; likewise the CHI-E
  and narrow-DAT tests are `vip_mc_chi_base_test #(...)` leaves over one
  parameterized CHI env/base. See [UVM_TB.md](UVM_TB.md) §1.
- Coverage still owed (tracked in `vip_mc/IMPLEMENTATION_PLAN.md` §11):
  multi-channel striping, sub/pseudo-channel dispatch, a DFI face, and a dynamic
  timing-retune wrapper. (Write coalescing, the first residual-observability
  batch, and the ECC/SECDED read-fault slice have landed.)

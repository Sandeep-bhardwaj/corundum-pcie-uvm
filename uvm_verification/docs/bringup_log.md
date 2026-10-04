# Bring-up Log

Running record of gates, deviations and cross-checks.
Implements: VERIFICATION_STRATEGY.md §19 (exit criteria), §19 E6 (cocotb cross-check).

---

## Step 0 - Infrastructure

**Status:** complete, with one gate blocked on tooling (see below).

### Delivered
| File | Spec |
|---|---|
| `uvc/common/mqnic_vrf_pkg.sv` | §12.3, §8.2, §8.3 |
| `uvc/common/mqnic_reset_if.sv` | §4.3 rule 6 |
| `env/mqnic_scoreboard_base.sv` | §11, §17.4 |
| `seq/mqnic_base_seq.sv` | §12.1 |
| `tests/mqnic_base_test.sv` | §4.1, §19 E8 |
| `seq/seq_pkg.sv`, `env/env_pkg.sv`, `tests/test_pkg.sv` | §6 |
| `tb/dut_wrapper_queue_manager.sv` | §0.4, §2.3 |
| `tb/tb_top_smoke.sv` | §18 Step 0 gate |
| `sim/Makefile`, `sim/filelists/*.f` | §16.1, §16.3 |
| `sim/scripts/sim_run.py` | §16.2 |
| `sim/scripts/run_regression.py` | §16.4 |
| `sim/scripts/slang_check.py` | §16 (added - see deviations) |
| `sim/scripts/merge_coverage.sh` | §14.6 |
| `sim/regress/tier1.list`, `nightly.list` | §16.4 |

### Gate status
| Check | Result |
|---|---|
| `mqnic_vrf_pkg` elaborates standalone | PASS - 0 errors, 0 warnings |
| `mqnic_reset_if` elaborates standalone | PASS - 0 errors, 0 warnings |
| DUT wrapper elaborates against real `queue_manager.v` | PASS - 0 errors (26 warnings, all pre-existing Corundum RTL) |
| Filelists parse; `+incdir+` resolves package includes | PASS |
| TB syntax check | PASS except UVM macros (see blocker) |
| Both Tier 1a DUTs + all non-UVM TB files elaborate | PASS - 0 errors, 0 warnings (scope=tb) |
| `sim_run.py` command construction (vcs/questa/xcelium) | PASS - verified by `--dry-run` |
| `run_regression.py` end to end | PASS - list parsed, run dispatched, missing simulator correctly reported, JUnit + HTML emitted |
| Full TB + UVM 1800.2 + both Tier 1a DUTs elaborate | **PASS - 0 errors, 0 warnings** |
| **Empty test prints TEST PASSED in simulation** | **BLOCKED - no UVM-capable simulator on this host** |

### Blocker (partially resolved)
Only Icarus Verilog is installed; it does not support UVM. No VCS / Questa /
Xcelium on PATH.

**Resolved:** Accellera UVM (`Accellera:1800.2:UVM:2020.3.1`) was cloned to
`ext/uvm` from github.com/accellera-official/uvm-core with the user's approval.
`slang_check.py --mode elab --uvm-home ext/uvm` now performs FULL semantic
elaboration of the testbench - macro expansion, type resolution, name binding -
with no simulator licence. This is the standing correctness loop:

    cd sim && make elab

**Still blocked:** the RUNTIME gate. Static elaboration cannot execute
`run_test()`, so "empty test prints TEST PASSED" awaits a VCS / Questa /
Xcelium licence. Everything up to and including elaboration is verified.

### Deviations from the strategy document
1. **`slang_check.py` added to Step 0** (not in the original §18 manifest).
   Provides syntax and semantic checking via pyslang with no simulator licence.
   Given the tooling situation this is the primary correctness feedback loop,
   so it is now a first-class deliverable. STRATEGY §16 to be updated.
2. **`sim_run.py` holds simulator command construction**, with the Makefile as a
   thin wrapper. Reason: `make` is not present on the development host. Single
   source of truth either way.
3. **`tb_top_smoke.sv` and `dut_wrapper_queue_manager.sv` created in Step 0**
   rather than Step 1, to give the Step 0 gate something to elaborate against.
   The wrapper is the same file Step 1 will use.
4. **`mqnic_vrf_pkg` does not import `uvm_pkg`.** The compile check showed the
   import was unused. Removing it makes the package dependency-free as its own
   header claims, and lets it be statically checked without UVM present.
   Matches the §4.3 intent that low-level types carry no framework dependency.

### Findings
* `queue_manager.v` and `cpl_queue_manager.v` instantiate no submodules -
  confirmed by inspection. `rtl_tier1a.f` therefore needs no library paths.
* Corundum RTL produces 51 slang warnings across the two Tier 1a DUTs (width
  truncation, missing case defaults). All pre-existing and intentional in this
  coding style. Use `--scope tb` to keep testbench diagnostics visible.
* **Mixed timescale caught by the compile check.** `mqnic_vrf_pkg.sv` and
  `mqnic_reset_if.sv` declared no timescale while every Corundum RTL file issues
  `` `resetall `` + `` `timescale 1ns / 1ps ``. Mixed timescales are an
  elaboration error under slang and produce silently wrong delays under VCS and
  Questa. Fixed by declaring `` `timescale 1ns / 1ps `` explicitly in all five
  package/interface files. **Convention added: every testbench file declares its
  own timescale** - to be folded into STRATEGY §17.2 (file header rules).

---

### Bugs caught by elaboration (would have been silent until first simulation)
1. **`factory.print()` - undeclared identifier.** The global `factory` handle
   was removed in IEEE 1800.2; UVM 2020.3.1 requires
   `uvm_coreservice_t::get().get_factory()`. Fixed in `mqnic_base_test.sv`.
2. **`m_timeout_ns * 1ns` - integer/realtime mismatch.** Multiplying an integer
   count by a realtime literal changes precision silently. Replaced with a
   `localparam time ONE_NS` so the arithmetic stays integral.
3. **`uvm_report_enabled()` used as a boolean** - returns int; now compared
   explicitly against 0.
4. **Signedness mismatches** on `get_severity_count()` results and
   `m_reset_cycles`. All severity counters are `int`, not `int unsigned`.

Testbench now elaborates at **0 errors, 0 warnings**.

### Deviation 5
`ext/` added to hold third-party sources and excluded from the `--scope tb`
diagnostic filter, so UVM's own warnings (UVM ships with a large number under
strict lint) cannot mask testbench diagnostics. `ext/` is gitignored.

---

## Step 1 - Tier 1a

**Status:** in progress. AXI-Lite UVC complete and elaborating clean.

### Delivered - `uvc/axil/` (8 files, STRATEGY §7.1)
| File | Notes |
|---|---|
| `axil_if.sv` | Signals, 3 clocking blocks, 3 modports, 13 protocol assertions |
| `axil_item.sv` | Max-width fields, delay shaping, AW/W ordering control |
| `axil_cfg.sv` | Mode, widths, backpressure profile, error-injection rates |
| `axil_driver.sv` | Master; independent AW/W processes |
| `axil_slave_driver.sv` | Reactive slave with sparse backing memory + backdoor |
| `axil_monitor.sv` | 5 independent collectors, out-of-order AW/W association |
| `axil_agent.sv` | 3 modes, sequencer/driver selection, analysis re-export |
| `axil_seq_lib.sv` | write / read / write_read / random |
| `axil_pkg.sv` | Package |

**Elaboration: 0 errors, 0 warnings** (12 files, with UVM 1800.2 + Tier 1a RTL).

### Design decisions worth recording
1. **`axil_if` is deliberately NOT parameterized.** A parameterized virtual
   interface yields a distinct type per parameterization, which makes
   `uvm_config_db` keys type-specific and blocks the §5.1 reuse of this agent at
   Tiers 3/5/6. The interface is declared at maximum width (64-bit addr/data);
   each DUT wrapper connects only the bits its DUT has, and real widths reach
   the agent through `axil_cfg`. Directly implements §4.3 rule 1.
2. **`MODE_ACTIVE_SLAVE` is not optional.** `m_axil_csr_*` on `mqnic_core_pcie`
   has the DUT as master (§3.2), so the agent must respond. The slave driver
   runs its AW/W/B/AR-R servers as independent forever-processes: a slave that
   waits for AW before accepting W deadlocks against a W-first master.
3. **Monitor publishes a write only when AW + W + B have all been seen.**
   Publishing on AW would report writes the DUT never accepted. In-flight beats
   are discarded on reset rather than reported, so reset tests do not
   manufacture phantom transactions for the scoreboard.
4. **Reads of never-written slave addresses return
   `cfg.slave_default_data`**, not X, so a scoreboard mismatch is legible
   instead of propagating unknowns.

### Delivered - `uvc/queue_op/` (6 files, STRATEGY §7.8)
| File | Notes |
|---|---|
| `queue_op_if.sv` | Neutral req/resp/commit/notify signals, 2 clocking blocks, 9 assertions |
| `queue_op_item.sv` | Item + cfg, with `apply_flavor()` |
| `queue_op_driver.sv` | Drives req/commit; free-running resp/notify ready |
| `queue_op_monitor.sv` | 4 independent collectors, 4 analysis ports |
| `queue_op_agent.sv` | Agent + sequencer + 4 sequences |
| `queue_op_pkg.sv` | Package |

**Elaboration: 0 errors, 0 warnings** (14 files total).

### ONE UVC covers BOTH Tier 1a DUTs
`queue_manager` and `cpl_queue_manager` are structurally parallel but differ in
exactly three places, verified against the RTL:

| `queue_manager` (dequeue) | `cpl_queue_manager` (enqueue) |
|---|---|
| `resp_block_size` (LOG_BLOCK_SIZE_WIDTH) | `resp_event` (EVENT_WIDTH) |
| `resp_cpl` (CPL_INDEX_WIDTH) | *(absent)* |
| `resp_empty` | `resp_full` |
| `m_axis_doorbell_{queue,valid}` - **pulse, no ready** | `m_axis_event{,_source,_valid,_ready}` - **full handshake** |

The interface therefore uses neutral names (`resp_aux`, `resp_cpl`,
`resp_blocked`, `notify_*`) and each DUT wrapper maps its own signal names on.
`queue_op_cfg.apply_flavor()` sets widths and notify behaviour together, so the
two cannot drift apart.

### The doorbell trap
The dequeue doorbell has **no ready signal**. A collector written in the usual
`wait(valid && ready)` style drops every doorbell in the run - and `t1a_doorbell`
would then pass while observing nothing. `collect_notify()` qualifies on
`notify_valid` ALONE when `cfg.notify_has_ready == 0`, sampling every cycle.
This is the specific hazard STRATEGY §7.8 flags.

Also deliberate: **no stability assertion on the notify channel**, because
"valid held until ready" is meaningless for a single-cycle pulse.

### Driver: response/notify ready are free-running
`resp_ready` and `notify_ready` are driven by forever-processes rather than
per-item, because they belong to no single transaction - the DUT produces
responses at its own rate. Randomizing them is what lets `t1a_op_table_full`
actually fill the op table.

### Delivered - `model/ref_queue.sv` + `model/model_pkg.sv` (STRATEGY §10)
Derived by READING `queue_manager.v`, not by assumption. Elaboration: 0 errors,
0 warnings (15 files).

Queue RAM layout and the exact decision logic are documented in the file header
with line references. Three semantics that a guessed model would get wrong:

1. **Speculative `active_cons_ptr` (`queue_manager.v:272`).** A queue with an
   outstanding uncommitted operation reports `op_table_queue_ptr[op_index]`, NOT
   the committed `cons_ptr`. A model returning `cons_ptr` unconditionally passes
   every single-operation test and fails everything with two ops in flight.
2. **Retirement is IN ORDER (`:394`).** An op retires only when the op at
   `finish_ptr` is both active and committed. Committing op 5 before op 4
   advances nothing until 4 commits. This is what `t1a_commit_ordering` checks.
3. **`error` and `empty` are distinct outcomes (`:437`, `:443`).** A request to
   a *disabled* queue returns `error=1, empty=0`. A request to an *enabled but
   empty* queue returns `empty=1, error=0`. No operation starts in either case.

### STRATEGY DOCUMENT CORRECTION - doorbell semantics
The test plan (§13) said *"Doorbell fires exactly once per enable transition."*
**That is wrong.** `queue_manager.v:509-519` shows the doorbell fires on a
**producer-pointer write** (command `0x8080_zzzz`), gated by the queue's enable
bit - it has nothing to do with the enable bit changing.

Corrected in VERIFICATION_STRATEGY.md §13 (`t1a_doorbell`), §11 (`sb_queue`
checks) and §15.2 (`sva_queue_manager` properties). Had this not been caught,
`t1a_doorbell` would have been written to an expectation the DUT never
implements, and would have failed for the wrong reason - or been "fixed" by
weakening it until it passed.

**Process note:** this is the second strategy-level error found by reading RTL
before writing the model. Both were assumptions carried from general NIC
knowledge rather than from this DUT. Continue deriving every predictor from the
source.

### Delivered - Tier 1a glue + EDA Playground bundle
| File | Purpose |
|---|---|
| `env/sb_queue.sv` | Scoreboard: 5 analysis imps, ref_queue comparison, op_tag uniqueness |
| `env/tier1a_env.sv` | axil_agent + queue_op_agent + sb_queue + virtual sequencer |
| `tb/tb_top_tier1a.sv` | Real agent connections; replaces the Step 0 tie-offs |
| `tests/tier1a/tier1a_tests.sv` | `tier1a_base_test` + `t1a_reset`, `t1a_reg_access`, `t1a_dequeue_basic` |
| `sim/scripts/gen_edaplayground.py` | Bundles the TB into EDA Playground's two panes |
| `edaplayground/tier1a/{design,testbench}.sv` | Generated bundle (1421 / 4431 lines) |
| `edaplayground/README.md` | Setup, expected output, failure-triage table |

Elaboration: **0 errors, 0 warnings**, both for the repository filelists (15
files) and for the generated bundle - the latter is a self-check that the
generator's `include inlining is faithful.

### BUG FOUND - filelist compile order (would have failed on VCS)
`axil_pkg` and `queue_op_pkg` import `mqnic_seq_pkg` (they extend
`mqnic_base_seq`), but `sim/filelists/tb_common.f` listed them BEFORE
`seq_pkg.sv`.

slang resolves package references across the whole compilation regardless of
file order, so this elaborated cleanly for four consecutive checks. **VCS,
Questa and Xcelium resolve imports in file order and would all have failed.**

Corrected order, now documented in the filelist header:

    mqnic_vrf_pkg -> mqnic_seq_pkg -> axil_pkg -> queue_op_pkg
      -> model_pkg -> mqnic_env_pkg -> mqnic_test_pkg -> wrappers -> tops

**Lesson:** static elaboration and simulator compilation are not the same check.
This class of bug is invisible until a real tool runs, which is exactly why the
EDA Playground step is worth doing before Step 2.

### Open risk carried into the first simulation
The `SET_ENABLE` opcode encoding (`0x4000_0100 | 1`, with the enable value in
`data[0]`) was taken from `modules/mqnic/mqnic_hw.h` and the Linux driver's
usage, NOT read directly out of `queue_manager.v`'s command decode. If
`t1a_dequeue_basic` reports `error=1` where `0` is expected, this is the first
thing to check. Recorded in the EDA Playground triage table.

### BUG FOUND BY VCS - illegal `interface::PARAM` scope resolution
First real compile on VCS X-2025.06-SP1 rejected `tb_top_tier1a.sv:125-127`:

    Error-[SV-LCM-PND] Package not defined
    tb_top_tier1a, "queue_op_if"
    Package scope resolution failed. Token 'queue_op_if' is not a package.

Cause: the tie-off block used `queue_op_if::MAX_QUEUE_WIDTH`. **The `::`
scope-resolution operator applies to packages and classes ONLY - never to an
interface definition.** slang resolved it happily; VCS, Questa and Xcelium all
reject it.

Fix: the interface maxima are restated as localparams in `tb_top_tier1a`, plus
an `initial` block that compares them against the interface instance
hierarchically (`qop_vif.MAX_QUEUE_WIDTH`) and `$fatal`s on drift. A
hierarchical read is legal in a procedural context but NOT inside a constant
bit-select range, which is why both halves are needed.

### slang_check gained a portability lint
Because slang structurally cannot catch this class of bug, `slang_check.py` now
runs a text-level portability pass alongside elaboration. First rule: flag
`<interface_name>::` anywhere in the sources. Verified in both directions -
fires on a probe containing the construct, silent on the corrected tree.
Disable with `--no-portability`.

**Running tally of bugs that static elaboration could not catch:**
1. Filelist compile order (packages before importers) - found while preparing
   the export.
2. `interface::PARAM` scope resolution - found by VCS itself.

Both were invisible to four-plus clean slang runs. The lint now covers (2);
(1) is covered by the ordering comment in the filelist header.

### FIRST SIMULATION - three tests PASS on VCS X-2025.06-SP1
`t1a_reset`, `t1a_reg_access` and `t1a_dequeue_basic` all pass. This is the
first execution of any of this code; up to now everything was static
elaboration only.

What the passes actually confirm, beyond "it runs":

1. **`ref_queue`'s speculative `active_cons_ptr` is correct.**
   `t1a_dequeue_basic` issues two dequeues with no commit between them. It only
   passes if the model reproduces `queue_manager.v:272` - a queue with an
   outstanding uncommitted op reports `op_table_queue_ptr[op_index]`, not
   `cons_ptr`. This was the single highest-risk piece of the model.
2. **The `SET_ENABLE` encoding is right.** `0x4000_0100 | 1` with the value in
   `data[0]` was the one register command taken from `mqnic_hw.h` and the Linux
   driver rather than read out of the RTL decode - the open risk carried into
   the run. Had it been wrong every response would have returned `error=1`.
3. **Doorbell-on-producer-pointer-write is confirmed**, vindicating the
   strategy correction recorded above.
4. The UVCs work at runtime: clocking-block timing, the AW/W fork/join in
   `axil_driver`, and the four independent collectors in `queue_op_monitor`.

### Delivered - remaining seven Tier 1a tests
`tests/tier1a/tier1a_tests2.sv`, elaborating clean (0 errors, 0 warnings):

| Test | Targets |
|---|---|
| `t1a_enable_disable` | `error=1` on a disabled queue; NO doorbell while disabled; recovery after enable |
| `t1a_dequeue_empty` | `empty=1, error=0`, no op_tag allocated, repeated empties change nothing |
| `t1a_commit_ordering` | Commit 2 then 1 retires NOTHING until 0 commits (`:394`) |
| `t1a_op_table_full` | Fills all 32 entries, then 8 more requests unblocked only by a parallel commit process |
| `t1a_ptr_wrap` | 3 laps of a 4-entry ring; `phase = !ptr[log_queue_size]` flips at each crossing |
| `t1a_doorbell` | One doorbell per producer-pointer write while enabled, none while disabled, correct source across queues 0 / 100 / 4095 |
| `t1a_random_stress` | 20 rounds x 8 requests over 4 scattered queues |

Two deliberate design points:
* **Op-tag prediction without observing responses.** The DUT allocates op tags
  sequentially from `op_table_start_ptr` and only on a *successful* start, so
  the k-th successful request carries `op_tag == k % OP_TABLE_SIZE`. Every
  request in these tests is arranged to succeed. The scoreboard independently
  checks the returned op_tag, so a wrong assumption surfaces as a mismatch, not
  a silent pass.
* **`t1a_op_table_full` hangs if back-pressure or retirement is broken**, and
  the UVM watchdog then fails it. That is the correct outcome - a test that
  quietly completed would be worse.

`sim/regress/tier1.list` now carries all ten tests in bring-up-ladder order.

### Delivered - coverage and design-intent assertions (Step 1 complete)
| File | Purpose |
|---|---|
| `cov/cg_queue.sv` | 3 covergroups, 3 crosses (STRATEGY §14.2) |
| `sva/sva_queue_manager.sv` | 7 assertions + 5 cover properties, bound to the RTL (§15.2) |

Elaboration: 0 errors, 0 warnings (16 files). Both exports regenerated and
self-checked; the multi-file export is now **35 tabs**.

**Coverage samples only monitor output** (§14.1) - never driver stimulus, which
would measure the testbench rather than the DUT. It shares `sb_queue`'s
`ref_queue` handle so coverage and checking can never disagree about op-table
occupancy. `cp_outcome` declares `illegal_bins both = {2'b11}`, so an
`error && empty` response fails rather than quietly filling a bin.

**The assertions are deliberately BLACK-BOX.** Reaching into `op_table_active` /
`op_table_start_ptr_reg` would have been easier, but it couples the properties to
internal names that are free to change and lets a refactor silently disable them.
The outstanding-tag set is instead reconstructed from observable handshakes,
keyed on the fact that a tag is allocated only on a *successful* response
(`queue_manager.v:451`).

Seven properties: op_tag uniqueness while outstanding; commit references an
outstanding tag; error/empty mutually exclusive; occupancy never exceeds
OP_TABLE_SIZE; no unsolicited responses; every accepted request answered within
1000 clocks; **doorbell is a single-cycle pulse** - that last one guards the
assumption `queue_op_monitor.collect_notify()` depends on.

### Remaining in Step 1
- [ ] Run the seven new tests + assertions + coverage on EDA Playground
- [ ] 20-seed runs (§19 E1) and coverage closure to >=98% (E2)
- [ ] cocotb cross-check (E6)
- [ ] `sva/sva_queue_manager.sv` (§15.2)
- [ ] `tests/tier1a/*` - remaining 7 of 10 tests (§13)
- [ ] `cov/cg_queue.sv` (§14.2)


---

## Step 3 - Tier 1c (offload blocks)

**Status:** UVC and reference models complete; envs/tops/tests pending.

### Delivered - `uvc/axis/` (6 files, STRATEGY §7.3)
`axis_if.sv`, `axis_item.sv` (item+cfg), `axis_driver.sv` (source + sink),
`axis_monitor.sv`, `axis_agent.sv` (agent + sequencer + 3 sequences),
`axis_pkg.sv`. Elaboration: 0 errors, 0 warnings (18 files).

Reused later at Tiers 2, 5 and 6 (§5.1), so it is worth more than the Tier 1c
DUTs alone justify.

### The Tier 1c DUTs are NOT uniform - verified against RTL
| DUT | Input | Output |
|---|---|---|
| `rx_checksum.v` | `s_axis_{tdata,tkeep,tvalid,tlast}` - **NO tready** | `m_axis_csum`, `m_axis_csum_valid` - no ready |
| `rx_hash.v` | same, **NO tready** | `m_axis_hash`, `m_axis_hash_type`, `m_axis_hash_valid` |
| `tx_checksum.v` | full AXI-S **with** tready | full AXI-S out + `s_axis_cmd_*` control |

A sink with no tready must accept a beat on EVERY cycle tvalid is high. This is
the same hazard as the queue_manager doorbell: a driver or monitor written
around a valid/ready handshake silently drops every beat and the test passes
having observed nothing. `axis_cfg.has_tready` selects the behaviour, and the
stability assertions are guarded on it because "valid held until ready" is
meaningless without a ready.

### Delivered - reference models
**`model/ref_checksum.sv`** - `rx_checksum` computes a one's-complement SUM, not
the complemented checksum. The cocotb reference asserts
`rx_checksum == ~scapy.checksum(frame[14:]) & 0xffff`, and scapy's `checksum()`
already complements, so the `~` recovers the raw sum. A model that complements
is wrong by exactly one bitwise-not - the easiest error to make here and the
hardest to spot in a waveform.

**`model/ref_hash.sv`** - Toeplitz/RSS, derived from `rx_hash.v`:
* `hash_toep` (:135-147) is textbook Toeplitz walking the input MSB-first.
* The RTL computes the IP part over 8 bytes with `key` and the port part over 4
  bytes with `key << 64`, then XORs (:151-152, :312-318). Shifting the key and
  restarting the index is identical to continuing the same key stream, and
  Toeplitz is linear, so this equals ONE pass over the concatenated 12 bytes.
  The model relies on that equivalence - it is exact, not an approximation.
* `hash_type` is `{udp, tcp, 1'b0, ipv4}` (:268): `0001` IPv4, `0101` IPv4+TCP,
  `1001` IPv4+UDP, `0000` otherwise with the hash forced to 0 (:317).
* **Only IPv4 is hashed.** IPv6 is detected as an ethertype (:189) but produces
  no hash, so the expected result for an IPv6 frame is hash=0, type=0.

### Deliberately NOT modelled yet
`tx_checksum` modifies the datapath rather than computing a value - it sums over
`[csum_start, end)` and writes the result at `csum_offset`. Its insertion
semantics have not been read out of the RTL, so no model was written. Absent
rather than guessed.

### Tier 1c COMPLETE (rx_checksum + rx_hash)
| File | Purpose |
|---|---|
| `env/sb_offload.sv` | Predicts checksum AND hash from one observed packet |
| `env/tier1c_env.sv` | Stimulus agent + 2 passive result agents + scoreboard |
| `tb/tb_top_tier1c.sv` | Both DUTs on ONE shared stimulus stream |
| `tests/tier1c/tier1c_tests.sv` | Base + 5 tests |
| `sim/filelists/rtl_tier1c.f`, `tb_tier1c.f` | Build |

Elaboration: 0 errors, 0 warnings. Tier 1a re-checked and still clean.

**One stimulus stream feeds both DUTs**, mirroring `mqnic_ingress.v` where
`rx_hash` (:97) and `rx_checksum` (:166) are tapped off the same ingress path.
Neither has a tready, so the identical tvalid/tdata/tkeep/tlast drives both and
one packet produces one checksum result plus one hash result.

**The result outputs reuse `axis_agent`** rather than adding a UVC for two
non-streaming outputs: `has_tready=0, has_tlast=0`, so the monitor publishes one
item per valid beat - 16 bits of checksum, or 32 bits of hash with the 4-bit
type on tuser.

**The RSS key has one source.** `MQNIC_RSS_KEY_DEFAULT` lives in
`mqnic_vrf_pkg`; `tb_top_tier1c` drives it into `rx_hash.hash_key` and
`tier1c_env` hands the same bytes to `ref_hash`. Two copies would make every
hash mismatch for an uninteresting reason.

Tests: `t1c_checksum_known_vectors`, `t1c_checksum_odd_length` (sweeps 15..80
bytes across two beat boundaries), `t1c_hash_known_vectors` (IPv4+TCP, IPv4+UDP,
IPv4-only, non-IP), `t1c_hash_flow_spread`, `t1c_random_stress`.

### `tx_checksum` - model written, not yet instantiated
`ref_checksum.tx_expected()` now models it, derived from the RTL: sum over
`[csum_start, end)` seeded with `csum_init`, COMPLEMENTED (:354-358), inserted
big-endian at `csum_offset` (:412-413).

One derived assumption is flagged in the code: the RTL swaps the result bytes
when `csum_start` is odd (:292, :354-355). That swap undoes the bus-alignment
shift the hardware sees, so the net result is the ordinary checksum and the
model performs NO swap. **If an odd-start test ever fails, that is the line to
revisit.**

Not instantiated yet because it needs a command agent for `s_axis_cmd_*` and a
second AXI-S output path - deliberately deferred rather than half-wired.

### I repeated my own bug, and the lint caught it
`tb_top_tier1c` was written with `axis_if::MAX_DATA_WIDTH` - the same illegal
`interface::PARAM` construct VCS rejected in `tb_top_tier1a`. Fixed the same
way: local constants plus a hierarchical drift guard. The portability lint added
after the first occurrence is what surfaced it before it reached a simulator.

### Remaining for Tier 1 as a whole
- [ ] Tier 1b: `pcie_tlp_agent` UVC - the highest-value UVC in the plan (§5.1,
      reused at Tiers 3/4/5) - plus `pcie_tlp_demux_bar`, `pcie_tlp_mux`,
      `pcie_tlp_fifo` envs and 7 tests
- [ ] Tier 1a: wire `cpl_queue_manager` (the queue_op UVC already supports its
      enqueue flavour via `apply_flavor(QOP_ENQUEUE)`; no top instantiates it)


---

## Step 2 - Tier 1b (TLP routing and buffering) - COMPLETE

`uvc/pcie_tlp/` (6 files) - **the highest-value UVC in the plan**. §5.1 reuses it
at Tier 3 (dma_if_pcie), Tier 4 (pcie_us_if equivalence) and Tier 5
(mqnic_core_pcie). Building it here on stateless routing DUTs is the whole point
of §2.1: segmented TLP packing gets debugged where a failure has one plausible
cause, not inside the DMA engine.

| File | Purpose |
|---|---|
| `uvc/pcie_tlp/*` | Interface, item+cfg, driver+sink, monitor, agent+3 sequences, package |
| `env/sb_tlp.sv` | One scoreboard for both DUT shapes (routed / pass-through) |
| `env/tier1b_env.sv` | demux (1 in, 2 out) + fifo (1 in, 1 out), 4 agents, 2 scoreboards |
| `tb/tb_top_tier1b.sv` | `pcie_tlp_demux_bar` + `pcie_tlp_fifo`, both unmodified |
| `tests/tier1b/tier1b_tests.sv` | 6 tests |

### Decisions
* **The header is carried RAW at this tier.** Demux, mux and fifo route and
  buffer TLPs without interpreting them, so the property under test is that the
  header arrives bit-identical. Field-level decode is deferred to Step 5, where
  a wrong field means a wrong request rather than a wrong route.
* **Sidebands are captured ONCE, on sop.** The RTL only presents hdr/bar_id/
  func_num/error/seq on the sop beat; later beats carry stale values. Capturing
  on eop instead works for single-beat TLPs and silently corrupts every
  multi-beat one.
* **`FIFO_ENABLE = 0` on the demux.** With output FIFOs enabled, a demux failure
  and a FIFO failure are indistinguishable.
* **Unmatched BARs must be DROPPED, and the model predicts that.** With
  BAR_BASE=0 / BAR_STRIDE=2 (mqnic's own configuration, `mqnic_core_pcie.v`
  :730-732) BAR 0 -> port 0, BAR 2 -> port 1, and BARs 1/3/4/5 match nothing.
  A demux that leaked unmatched traffic to port 0 would otherwise pass
  everything. `t1b_bar_route` drives all six.

---

## Tier 1 status

| Sub-tier | DUTs | Tests | Elaboration |
|---|---|---|---|
| 1a | `queue_manager` | 10 | 0 errors, 0 warnings |
| 1b | `pcie_tlp_demux_bar`, `pcie_tlp_fifo` | 6 | 0 errors, 0 warnings |
| 1c | `rx_checksum`, `rx_hash` | 5 | 0 errors, 0 warnings |

**21 tests. 4 UVCs** (axil, queue_op, axis, pcie_tlp) - every one of which §5.1
reuses at a higher tier. 3 reference models, 3 scoreboards, 1 coverage model,
1 bound assertion module.

### EDA Playground exports - all three tiers
`edaplayground/tier{1a,1b,1c}_multifile/`, each self-checked by elaborating its
own generated manifests: 0 errors, 0 warnings.

**The three exports share an identical set of 36 `.svh` fragment tabs.** Only
`design.sv`, `testbench.sv`, the TB top and the RTL differ. So the tabs can be
pasted once and reused: switching tier means replacing the two manifest panes,
the top, and the RTL tabs.

### Two DUTs still not instantiated
Both are "RTL not wired", not "UVC missing" - the UVCs already support them:
1. **`cpl_queue_manager`** - `queue_op_cfg.apply_flavor(QOP_ENQUEUE)` handles its
   enqueue flavour, event channel and full/empty naming. Needs a wrapper and a
   second agent instance in the Tier 1a top.
2. **`tx_checksum`** - `ref_checksum.tx_expected()` models it. Needs a command
   agent for `s_axis_cmd_*` and a second AXI-S output path.


---

## Wiring the two remaining DUTs - partial, with a finding

### `cpl_queue_manager`: more different than the RTL's symmetry suggests

`ref_queue` now carries a `flavor` (`REF_Q_DEQUEUE` / `REF_Q_ENQUEUE`) and models
the enqueue RESPONSE path, verified against `cpl_queue_manager.v`:

1. **FULL replaces EMPTY** (:269-271):
   `full = ((prod - cons) & (~0 << log_size)) != 0` - occupancy has reached the
   ring size, not `prod == cons`.
2. **The speculative pointer is the PRODUCER side** (:272, :420), and
   retirement advances `prod_ptr`, not `cons_ptr`.
3. **Address is `base + (ptr & size_mask) * CPL_SIZE`** (:423) - a MULTIPLY by
   the fixed 32-byte completion size, not a shift by `log_block_size`.
4. **RAM [47:32] is `event`**, and there is no `log_block_size` at [53:52].

**Then reading the register decode showed the estimate was wrong.** Two further
differences that a "structurally identical" assumption would have got wrong:

5. **The address layout differs.** `queue_manager` uses a 3-bit register select
   (8 dwords per queue, `AXIL_ADDR_WIDTH = QUEUE_INDEX_WIDTH+5`).
   `cpl_queue_manager`'s decode `case` has only `2'd0..2'd3` - a 2-bit select,
   4 dwords per queue, `+4`. Using the wrong shift silently addresses the WRONG
   QUEUE, which would have produced mismatches that looked like DUT bugs.
6. **`SET_PROD_PTR` is gated on `!enable`** on the enqueue side - the DUT owns
   the producer pointer once the queue is running - and `SET_CONS_PTR` is
   writable while enabled, the reverse of the dequeue side.

Both are now modelled. `ref_queue` elaborates clean.

### Still NOT wired, and why
`cpl_queue_manager` also has state `ref_queue` does not yet model: an `armed`
bit at RAM [54], a `continuous` bit, and EVENT generation that fires on commit
when armed, on `SET_CONS_PTR_ARM` when armed and non-empty, and on `SET_ARM`
under the same condition - with the armed bit self-clearing unless continuous.

That is a genuine state machine, not a naming difference. Instantiating the DUT
now would mean a scoreboard that mispredicts every event, so the top and env
changes are deliberately NOT made. Modelling it is one focused pass:
armed/continuous state plus three event-generation rules.

`tx_checksum` is unchanged from the previous entry: `ref_checksum.tx_expected()`
models it, but it needs a command agent for `s_axis_cmd_*`.

### Current state
| | Status |
|---|---|
| Tier 1a `queue_manager` | 10 tests, coverage, SVA - complete |
| Tier 1a `cpl_queue_manager` | Response + register model done; event/armed model and wiring outstanding |
| Tier 1b | Complete, 6 tests |
| Tier 1c `rx_checksum` / `rx_hash` | Complete, 5 tests |
| Tier 1c `tx_checksum` | Model done; command agent and wiring outstanding |


---

## VCS rejected pcie_tlp_fifo - a Corundum RTL portability limit

First compile of the unified Tier 1 export failed with 10 errors, all inside
`pcie_tlp_fifo_raw.v`. **Not testbench code.**

```
Error-[IRIPS] Illegal range in part select
pcie_tlp_fifo_raw.v, 450
  seg_mem_wr_sel[(cur_seg * SEG_SEL_WIDTH)+:SEG_SEL_WIDTH]
Warning-[SIOB] Select index out of bounds
pcie_tlp_fifo_raw.v, 444   wr_ptr_cur_reg[(SEG_SEL_WIDTH - 1):0]
```

### Cause
`pcie_tlp_fifo_raw.v:51` derives `SEG_SEL_WIDTH = $clog2(OUT_TLP_SEG_COUNT)`,
which is **0** when there is a single segment. The zero-width part selects at
:450-468 sit inside a plain

    if (OUT_TLP_SEG_COUNT > 1) begin ... end

which is a RUNTIME branch inside an always block, **not a generate**. VCS
elaborates the dead code and rejects it. slang and Icarus tolerate zero-width
selects, which is why four clean elaborations never saw this.

### Why it was not simply parameterised around
`SEG_SEL_WIDTH` is declared in the BODY of `pcie_tlp_fifo` (:106), not in its
parameter port list, so it cannot be overridden from an instantiation. The only
clean fix is to run the DUT at SEG_COUNT=2 - which requires a segment-aware
driver and monitor, i.e. exactly the multi-segment/straddling work STRATEGY
§5.1 schedules for **Tier 4**.

### Decision
`pcie_tlp_fifo` is removed from Tier 1 rather than rushed. Building multi-segment
support under time pressure risks a subtly wrong `pcie_tlp` UVC, and Tiers 3, 4
and 5 all depend on that UVC being correct - the single worst place to take a
shortcut. The reason and the conditions for reinstating it are recorded in
`tb_top_tier1b.sv`.

`pcie_tlp_demux_bar` is unaffected: it is instantiated with `FIFO_ENABLE=0` and
`pcie_tlp_demux.v:164` guards the FIFO with a GENERATE if, so it is never
elaborated. Tier 1b keeps 5 of its 6 tests; only `t1b_fifo_passthrough` is gone.

**Third bug class that static elaboration could not catch**, after filelist
compile order and `interface::PARAM`. All three needed a real simulator.

---

## Tier 1 final state

| Export | DUTs | Tabs | Elaboration |
|---|---|---|---|
| `tier1_multifile` (recommended) | 6 | 65 | 0 errors, 0 warnings |
| `tier1a_multifile` | 2 | 57 | 0 errors, 0 warnings |
| `tier1b_multifile` | 1 | 57 | 0 errors, 0 warnings |
| `tier1c_multifile` | 3 | 57 | 0 errors, 0 warnings |

23 tests, 5 UVCs, 6 DUTs. The unified export runs every test from one paste by
changing `+UVM_TESTNAME` alone; top module `tb_top_tier1`.


---

## VCS bug 4: interface array indexed by a procedural loop variable

```
Error-[IIXMR] Invalid index in cross-module reference
tb_top_tier1.sv, 433   dmx_out_vif[p].tlp_data[511:TLP_DATA_WIDTH] = '0;
  Invalid index in cross-module reference due to index is not constant.
```

**My bug, not the RTL's.** The tie-off block used

    initial begin
        for (int p = 0; p < DEMUX_PORTS; p++) begin
            dmx_out_vif[p].tlp_data[...] = '0;

`p` is a procedural variable, so `dmx_out_vif[p]` is a cross-module reference
with a non-constant index into an interface ARRAY. That is illegal: the index
must be resolvable at elaboration. slang accepts it.

Fixed by moving the tie-offs INSIDE the existing `for (genvar p ...)` generate
block, where `p` is an elaboration-time constant per generated instance.

`slang_check.py` gained **portability rule 2**: flag a procedural
`for (int VAR ...)` loop whose body contains `ident[VAR].`. Verified in both
directions - fires on a probe, silent on the corrected tree.

### Running tally of bugs static elaboration could not catch
1. Filelist compile order (packages before importers)
2. `interface::PARAM` scope resolution - VCS SV-LCM-PND
3. `pcie_tlp_fifo_raw` zero-width part selects at SEG_COUNT=1 - VCS IRIPS (RTL)
4. Interface array indexed by a procedural loop variable - VCS IIXMR

Two of the four are now covered by the portability lint. (1) is covered by the
filelist header note; (3) is a Corundum RTL limit, not something a lint can fix.


---

## VCS bug 5: X on undriven interfaces fails an unconditional assertion

Running `t1a_random_stress` on the UNIFIED Tier 1 top:

```
tb_top_tier1.dmx_in_vif.a_sop_implies_valid failed at 82000 ps
  Offending '((tlp_sop & (~tlp_valid)) == '0)'
```

**My bug.** A test builds only its own environment, so the agents for every
other interface never exist and nothing drives their TB-side signals. Undriven
they sit at X, and

    a_sop_implies_valid : (tlp_sop & ~tlp_valid) == '0

is an UNCONDITIONAL assertion - with X operands it evaluates to X, which is not
true, so it FAILS. Implication-style assertions (`tvalid |-> ...`) went vacuous
and stayed quiet, which is why only these two fired.

The time-zero initialisation in `tb_top_tier1.sv` covered `tlp_valid` but not
`tlp_sop` / `tlp_eop`, and was incomplete on the other interfaces too.

**The assertion is correct and unchanged** - it caught a real defect in the
testbench. Fixed by initialising EVERY TB-driven signal of EVERY interface at
time 0, and only those: DUT-driven signals are left alone, since assigning to
them would create a second driver.

### Pattern to carry forward
Any top that instantiates more DUTs than a single test exercises has this
problem. From Tier 3 on, a top must initialise all TB-driven signals of all
interfaces, not just the ones the current test happens to use. A reusable
`init_idle()` task per interface would make this systematic - worth adding when
the Tier 3 top is written.

### Running tally of bugs static elaboration could not catch
1. Filelist compile order
2. `interface::PARAM` - VCS SV-LCM-PND          (lint rule 1)
3. `pcie_tlp_fifo_raw` zero-width selects - IRIPS (Corundum RTL limit)
4. Interface array + procedural index - IIXMR   (lint rule 2)
5. X on undriven interfaces failing an unconditional assertion - RUNTIME, not
   even a compile error. Only a simulation could have found this one.


---

## First real simulation result: DUT correct, scoreboard wrong

`t1a_random_stress` on VCS: **161 matches, 3 mismatches** - and all 160
request/response/commit triples matched exactly. Every mismatch was a doorbell,
lagging by exactly one:

```
@1954000  unexpected doorbell for queue 37   (expected: none)
@2098000  expected queue 37, actual queue 74
@2186000  expected queue 74, actual queue 111
end       1 expected item never matched
```

### Cause - a testbench ordering assumption, not a DUT bug
The register-write stream and the doorbell stream are INDEPENDENT analysis
channels with no guaranteed relative order. `queue_manager` raises the doorbell
inside the register-write pipeline (:509-519), so `queue_op_monitor` can observe
it BEFORE `axil_monitor` publishes the write - the write is only published once
its B handshake completes, which is later.

`sb_queue` matched the two as a strict FIFO, so the first doorbell arrived to an
empty expectation list and everything after was one behind.

### Fix
Two lists, reconciled in BOTH directions:
* `observe_doorbell()` - if the source is already expected, match and remove;
  otherwise hold it as an early arrival.
* `expect_doorbell()` - if an early arrival matches, match and remove; otherwise
  push the expectation.

Matching is by SOURCE QUEUE rather than strictly positional. That is the correct
relaxation: what must hold is that each predicted doorbell occurs exactly once,
not that it occurs at a particular position relative to an unrelated channel.
Per-queue counts are still enforced, so a missing, extra or wrong-source
doorbell still fails, and anything left in either list at end of test fails the
drain check.

Request/response/commit matching stays strictly FIFO - that channel IS ordered,
and it matched 160/160.

### What the run already proves
* `ref_queue`'s speculative pointer, in-order retirement and op-tag allocation
  are correct across 160 randomized operations on 4 scattered queues.
* The AXI-Lite and queue_op UVCs work under randomized backpressure.
* Coverage is being collected: response 43.5%, commit 66.7%, doorbell 40.0%.


---

## VCS bug 6: the EXPORT GENERATOR reordered the compile manifest

```
Error-[SE] Syntax error
  token 'dma_ram_cfg' should be a valid type.
  "sb_dma_ram.svh", 42:  dma_ram_cfg cfg;
```

**Not a source bug - a tooling bug.** The repository filelist had the right
order (`dma_ram_pkg` before `env_pkg`), and the repo build elaborated clean. The
EXPORT was wrong.

`make_eda_playground.py` grouped manifest entries by a hard-coded SECTIONS list
and appended anything unrecognised at the END. `dma_ram_if.sv` / `dma_ram_pkg.sv`
were new and not in that list, so they landed AFTER `env_pkg.sv` - which imports
them. Every previously-added UVC happened to be in the list, so the flaw stayed
hidden until Tier 2 added one that was not.

### Fix
The manifest now emits **in filelist order**; SECTIONS only supplies comments and
can never reorder. That restores the invariant stated in `tb_common.f`: the
filelist is the single source of truth for compile order.

A regression guard was added to the verification pass: for every tier, the
`include sequence in the generated manifest is compared element-by-element with
the parsed filelist. All five tiers now report identical order.

**This class of bug would have recurred on every new UVC** - Tier 3 adds
`dma_desc`, Tier 4 adds `pcie_us_axis`, Tier 5 adds `pcie_cfg`. Worth the fix.

### Running tally of bugs static elaboration could not catch
1. Filelist compile order (packages before importers)
2. `interface::PARAM` - VCS SV-LCM-PND            (lint rule 1)
3. `pcie_tlp_fifo_raw` zero-width selects - IRIPS (Corundum RTL limit)
4. Interface array + procedural index - IIXMR     (lint rule 2)
5. X on undriven interfaces - RUNTIME assertion failure
6. Export generator reordering the manifest       (regression guard added)


---

## VCS bug 7: Tier 2 filelist carried Tier 1a's wrapper and bind

```
Top Level Modules:
       dut_wrapper_queue_manager      <-- should not be a top
       tb_top_tier2
Error-[SVA-COBMMI] Can only bind to modules or instances.
  sva_queue_manager.sv, 179:  bind queue_manager sva_queue_manager ...
```

**My bug.** `tb_tier2.f` was derived from `tb_tier1.f` with sed, so it still
listed `dut_wrapper_queue_manager.sv` and `sva_queue_manager.sv`. Neither
belongs in a Tier 2 build: `queue_manager.v` is not in `rtl_tier2.f`, so the
wrapper had nothing to instantiate (leaving it a stray top-level module) and the
`bind` had no target.

slang elaborated it happily - an unbound wrapper and a bind to an absent module
are both acceptable to it.

### Fix and guard
Removed both from `tb_tier2.f`, with a header note explaining the rule.

Added `sim/scripts/check_filelists.py`, which for every tier verifies that each
`dut_wrapper_<mod>.sv` and each `bind <mod>` target named in the testbench
filelist has `<mod>.v` present in the matching RTL filelist. The bind targets are
read from the SVA source, not guessed from the filename. All five tiers pass.

Deriving one filelist from another with sed is what caused this; the guard makes
the resulting mismatch impossible to ship.

### Running tally of bugs static elaboration could not catch
1. Filelist compile order
2. `interface::PARAM` - SV-LCM-PND                 (lint rule 1)
3. `pcie_tlp_fifo_raw` zero-width selects - IRIPS  (Corundum RTL limit)
4. Interface array + procedural index - IIXMR      (lint rule 2)
5. X on undriven interfaces - runtime assertion    (init_idle pattern)
6. Export generator reordering the manifest        (order regression guard)
7. tb filelist referencing RTL not in the build    (check_filelists.py)

Four of the seven now have an automated guard.


---

## Tier 2 first run: DUT correct, test too impatient

`t2_seg_independent_backpressure` on VCS: **92 matches, 0 mismatches** - every
data check passed. One error:

```
rd=62  data=60
UVM_ERROR dma_ram_monitor: seg 1: 2 read command(s) never answered
```

### Cause - a test bug the monitor caught
Segment 1 runs BP_AGGRESSIVE read-response backpressure. The test issued 64
reads and then waited a FIXED idle(300); the last two responses had not drained
when the run ended.

A fixed delay long enough for one backpressure profile is too short for another,
so the value was never going to be right for all of them. The DUT behaved
correctly throughout.

### Fix
`dma_ram_monitor.outstanding_reads()` is now exposed through the agent, and the
Tier 2 base test gained `wait_ram_drained()`, which polls that count instead of
guessing a delay. Applied at all 8 end-of-read-burst points, including the CDC
test's read-domain agent.

The wait has a bounded timeout that reports a clear error rather than hanging -
if the DUT genuinely stops answering, that must not look like a testbench hang.

### Worth noting
`dma_ram_monitor.check_phase` found this, not a scoreboard mismatch. The check
was written as routine hygiene - "read commands that never got data" - and it
turned out to be the only thing standing between a fragile test and a green run
that proved less than it appeared to.


---

## The real cause: sequence completion is not traffic completion

The drain fix above did not work. Second run:

```
rd=5  data=3        seg 1: 2 read command(s) never answered
```

Only 5 of 64 reads were issued - `wait_ram_drained()` returned IMMEDIATELY.

### Why
`dma_ram_driver` accepts an item, routes it into a per-segment queue and calls
`item_done()` at once. That is what allows the segment servers to run
concurrently - but it means **seq.start() returns when every item has been
QUEUED, not when the DUT has seen it**. At that instant nothing is on the bus,
so a drain-wait on `outstanding_reads()` alone finds zero and exits.

The first run's fixed `idle(300)` had masked this by covering 62 of 64 reads.
The apparent bug ("2 responses missing") was a symptom; the actual defect was
that the test never waited for its own traffic to be issued at all.

### Fix
* `dma_ram_driver.pending_items()` - queued items plus the one a server has
  popped and is mid-handshake on, tracked by a per-segment busy flag.
* `dma_ram_agent.is_idle()` - `pending_items() == 0 && outstanding_reads() == 0`.
* `wait_ram_drained()` waits on `is_idle()`, not on bus activity alone.

### The lesson, recorded because it will recur
Any driver that decouples acceptance from execution - which every per-channel or
per-segment driver does - breaks the usual assumption that a finished sequence
means finished traffic. Tier 3's `dma_if_pcie` driver and Tier 5's DMA clients
will have the same shape, so `is_idle()` belongs on those agents from the start
rather than after a confusing run.

A green-looking "35 matches, 0 mismatches" for traffic that had barely started is
the failure mode this guards against.


---

# Step 5 - Tier 3a: dma_if_pcie_rd

Tier 3a is built. 25 files elaborate with the single known baseline diagnostic
(the vendored UVM has no `timescale`, which every tier reports identically);
the portability lint is clean at 0/0 and `check_filelists.py` passes for all
six tiers.

## What the earlier tiers bought

Every UVC in `tier3_env` was built and debugged lower down: `pcie_tlp` at Tier
1b, `dma_ram` and `dma_desc` at Tier 2. Tier 3 added models, checking and a
configuration interface - no new bus plumbing. That is the return §5.1 promised
for the bottom-up ordering, and it is the first tier where it is visible.

The Tier 2 lesson was applied before it could bite again: `tier3_env.is_idle()`
was designed in from the start, and its load-bearing term is
`sb_dma.outstanding_desc()` - descriptors accepted but not yet answered. Waiting
on bus quiet alone would have reproduced Tier 2's failure exactly.


## Bug 1 - TLP header decode was wrong (found by reading RTL, before any run)

The first version put the tag at `[103:96]` and the length at `[9:0]`. Both are
plausible and both are wrong. `dma_if_pcie_rd.v:752-783` (build) and `:971-990`
(decode) put the tag at `[79:72]`, the length at `[105:96]`, and the address at
`[63:34]` for a 3DW request but `[63:2]` for a 4DW one.

Fixed by putting encode and decode helpers in `mqnic_vrf_pkg` - one definition
that the item, the scoreboard and the RC model all share, so they cannot drift.

Caught by reading the RTL rather than by a failing test. A wrong decode would
have produced a mismatch on every single request, which reads like a broken DUT.


## Bug 2 - completions would have carried random payload

`pcie_tlp_single_seq` randomizes `payload`, which is correct for stimulus and
wrong for a completion: the bytes must be the ones the host memory model holds.
Added `pcie_tlp_verbatim_seq`, which carries a fully-formed item through
untouched, and pointed `rc_responder.emit()` at it.

Every data check would have failed, for a reason with nothing to do with the DUT.


## Bug 3 - the reorder shuffle generated ILLEGAL traffic

`mqnic_rc_model.reorder()` guarded a swap with `q[i].tag != q[j].tag`. That is
not sufficient:

```
[ tagA_0 , tagA_1 , tagB ]     i=0, j=2, tags differ -> swap
[ tagB   , tagA_1 , tagA_0 ]   tagA is now out of order
```

PCIe fixes the order of same-tag completions. The queue above is illegal traffic,
and the DUT would have been blamed for mishandling it.

Fixed with `swap_legal()`: the exchange is permitted only when nothing strictly
between `i` and `j` shares a tag with either endpoint, which is what makes the
swap invisible to every same-tag subsequence.


## Bug 4 - the DUT has no completion timeout, so t3_cpl_timeout was unreachable

The test was written to withhold completions and wait for the DUT to time out.
It never would have. `dma_if_pcie_rd` HAS NO INTERNAL TIMER: the only route to
`DMA_ERROR_TIMEOUT` is an inbound completion whose error sideband reads
`PCIE_ERROR_TIMEOUT` (`:1117-1122`), which is how the hard IP forwards a timeout
it detected itself.

As written the test would have hung until the global watchdog and reported
nothing useful.

Fixed by splitting the two questions, because they are genuinely different:

* `timeout_pct` injects the real event - a no-data completion with the timeout
  sideband set. `t3_cpl_timeout` checks the DUT reports `DMA_ERROR_TIMEOUT`.
* `drop_pct` withholds the completion entirely. The new `t3_cpl_dropped` asserts
  what actually happens: the descriptor stays outstanding, and the DUT must not
  invent a status, a RAM write, or a reuse of the stranded tag.

The two liveness properties in `sva_dma_if_pcie` had to become switchable
(`+MQNIC_NO_LIVENESS`) for the second test, since "every descriptor is eventually
answered" is the very thing it arranges not to happen.

### Worth noting
This was found by reading the RTL for the error-code values, not by running
anything. A test that cannot reach its target path is worse than a missing test:
it occupies the slot and reports a pass.


## Bug 5 - the descriptor tag pool only ever shrank

`dma_desc_driver` tracked in-flight tags but nothing ever called
`release_tag()`. Tier 2's tests each used fewer descriptors than there are tags,
so it never showed. Tier 3's stress tests issue hundreds and would have reported
every legitimate reuse as illegal stimulus - a testbench fault dressed as a DUT
bug.

Fixed with `dma_desc_tag_release`, a subscriber on the status channel, wired in
the agent.

The same defect existed in `sb_dma`, differently: it cleared EVERY tag on any
descriptor status, which is wrong the moment two descriptors overlap - i.e. for
most of this tier. It would have silently disabled the duplicate-tag check.
Fixed by retiring a PCIe tag from the COMPLETION side, using the rule the DUT
itself uses (`:988`): a completion whose `byte_count` equals its own payload
length is the last one for that tag.


## Bug 6 - three tests were configuration-shaped but could not change configuration

`max_read_request_size`, `rcb_128b` and `ext_tag_enable` are static input pins.
Tied to constants in the top, `t3_mps_mrrs_matrix`, `t3_rcb_64_128` and
`t3_ext_tag_off` would have documented configurations they never reached, and
§14.3's cross would only ever be filled on one slice.

Added `dma_if_cfg_if` and `tier3_base_test.set_config()`, which drives the pins
AND both models together. Routing all three through one function is what makes
it impossible to check the DUT against a configuration it was never in.


## Tooling defects fixed alongside

* `make_eda_playground.py` discovered test names with `[a-z_]+`, silently
  dropping `t3_4k_boundary`, `t3_addr_3dw` and `t3_rcb_64_128` from the
  generated run doc. Worse than an error - the tabs were right and the
  documentation quietly under-reported the tier. Now `[a-z0-9_]+`.
* The same script hardcoded "queue_manager" as the DUT and "tb_common.f" as the
  source filelist in every generated header, regardless of tier.
* `check_filelists.py` had a hardcoded tier list and did not know about Tier 3.


## Verification status

| Gate | Result |
|---|---|
| slang elaboration, all six tiers | 1 error each - the known UVM `timescale` baseline |
| portability lint (VCS rules 1 and 2) | 0 errors, 0 warnings |
| `check_filelists.py` | 6/6 OK |
| export fidelity vs repo sources | 67/76 byte-identical; the 9 package files differ only by the intended `.sv` -> `.svh` include rewrite |
| VCS simulation | NOT RUN - requires the user's EDA Playground session |

19 tests are registered for this tier. None has been simulated; elaboration and
lint are not evidence of correctness, only of compilability.


---

## Bug 7 - method call on a cast expression (VCS SE)

First VCS compile of Tier 3:

```
Error-[SE] Syntax error
  "sb_dma.svh", 301 (expanding macro): token is '.'
    mqnic_dma_error_e'(t.error).name()), UVM_MEDIUM)
```

`some_enum_e'(expr).name()` parses in slang and is rejected by VCS. The
diagnostic points into the `uvm_info` macro expansion rather than at the source
construct, which makes it harder to place than it should be.

### Fix
Assign the cast to a variable and call the method on that.

### Guard
Added as **portability lint rule 3**. It matches a method call applied directly
to a cast expression and is quiet on the ordinary width casts this environment
uses everywhere (`16'(vif.mon_cb.req_len)`, `32'(a + b)`), which is what makes
it usable rather than noisy.

This is the eighth construct slang accepts and VCS does not. Five now have
automated guards: lint rules 1, 2 and 3, the manifest-order regression check,
and `check_filelists.py`.


---

## Bug 8 - a_sop_implies_valid was too strong (TB bug, reported as a DUT bug)

First simulated run of `t3_read_basic`, failing from the very first request:

```
"pcie_tlp_if.sv", 102: tb_top_tier3.rd_req_vif.a_sop_implies_valid: failed at 82000ps
  Offending '((tlp_sop & (~tlp_valid)) == '0)'
TLP: sop asserted on an invalid segment
```

### The DUT is right and the assertion was wrong

```verilog
// dma_if_pcie_rd.v:483-485
assign tx_rd_req_tlp_valid = tx_rd_req_tlp_valid_reg;
assign tx_rd_req_tlp_sop   = 1'b1;
assign tx_rd_req_tlp_eop   = 1'b1;
```

Both framing bits are tied to a constant. The read-request channel is
single-segment and header-only, so every beat is trivially one whole packet and
`valid` alone qualifies it.

The protocol says sop and eop are MEANINGLESS when valid is low. It does not say
they must be low. The assertion asserted the stronger reading, which happened to
hold for the Tier 1b DUTs it was written against (`pcie_tlp_demux/mux/fifo` all
gate their framing) and does not generalise.

### Fix
`pcie_tlp_if` gained `bit sop_eop_gated = 1'b1`, and the two properties are now
implications on it. The default preserves the stronger check wherever it is
true; `tb_top_tier3` clears it for `rd_req_vif` with the RTL line reference.

### A wrong fix, caught before it shipped
The first replacement added "a valid segment must carry some framing":

```
|tlp_valid |-> |(tlp_valid & (tlp_sop | tlp_eop))
```

That is false for any TLP longer than one beat - interior beats have valid
asserted with neither sop nor eop, which is simply what a multi-beat packet
looks like. It would have failed on every payload-carrying TLP at Tier 1b. There
is no salvageable weaker form, so the property was dropped and the reason
recorded in the interface instead.

### The lesson
An assertion written against one family of DUTs encodes that family's idioms.
This one had been green across three tiers, which is not evidence it was right -
only that every producer so far had happened to share a convention. Reuse is
where an over-strong property first shows, and it shows as a DUT bug.


---

## Bug 9 - the root complex model discarded the byte enables

First long simulated run. Data lands in RAM shifted by a constant 3 bytes:

```
context : DMA data at RAM 0x331d (seg 0 seg_addr 0xcc byte 29)
  expected: 0x7e   actual: 0x43        <- 0x43 is what belongs at 0x3320
context : DMA data at RAM 0x333d (seg 1 seg_addr 0xcc byte 29)
  expected: 0x5e   actual: 0x23        <- 0x23 is what belongs at 0x3340
```

Uniformly `actual(A) == expected(A+3)`. A constant offset, not corruption.

### Cause

`rc_responder` built the completion from the request header's DWORD-ALIGNED
address and DWORD count:

```systemverilog
addr = t.hdr_req_addr();        // low 2 bits forced to 0
len  = t.hdr_length_dw() * 4;   // rounded up to whole DWORDs
```

That throws away the byte enables, which are the only thing that says where the
transfer really starts and ends. The DUT places completion data using

```verilog
offset_next = pcie_tag_table_ram_addr[tag] - (byte_count + lower_addr[1:0]);
                                            // dma_if_pcie_rd.v:1008
```

so `byte_count` must be the BYTE-EXACT remaining count and `lower_addr[1:0]`
the byte offset within the first payload DWORD. The model supplied a byte_count
too large by the end padding and a lower_addr always zero, displacing the whole
transfer by `-(end padding)` - 0 to 3 bytes. Hence a clean constant shift.

### Fix
* `mqnic_vrf_pkg` gained `tlp_hdr_req_byte_addr()` / `tlp_hdr_req_byte_len()`,
  which decode first_be and last_be.
* `mqnic_rc_model` carries `pad_front` and emits the leading bytes of the first
  DWORD on the wire while reporting the byte-exact `lower_address` and
  `byte_count`. That is what PCIe actually specifies; the previous version was
  self-consistent but did not match the wire format.
* `sb_dma` compares requests in byte-exact terms.

### Two further bugs the same investigation exposed

**Request comparison was positional.** `sb_dma` popped the front of the expected
queue and compared. From Tier 3 on, several descriptors are in flight and the
DUT interleaves their requests as tags come free, so legal interleaving read as
a mismatch. Now it searches the outstanding set and removes the earliest match -
which still enforces order WITHIN a descriptor, because the queue is in
prediction order.

**`ref_dma.split_read` did not match the RTL.** It applied MRRS, then 4 KB, then
an RCB-alignment shortening of the first request only. The RTL
(`dma_if_pcie_rd.v:662-720`) selects one branch of four, and two details were
wrong:

* the MRRS test is `remaining + addr[1:0] <= MRRS` - an unaligned start eats
  into the budget;
* the alignment term is `addr[6:0]`, a **fixed 128-byte boundary** (`:710`),
  not the RCB, and it applies to every oversized request rather than only the
  first.

`split_read` is now transcribed from the RTL. Both fixes were verified before
re-running by re-implementing the RTL arithmetic independently in Python:
**270,570 split cases and 10,368 end-to-end placement configurations, zero
divergent.**

### Worth noting
The scoreboard reported this as a DUT data-integrity failure. It was a model
bug, and the shape of the evidence - a CONSTANT offset rather than scattered
corruption - is what said so. Random-looking data errors suggest the DUT;
a uniform displacement suggests whoever computed the address.


---

# Step 5 continued - Tiers 3b and 3c

Both built and elaborating clean on the first attempt: 3b at 25 files, 3c at 28,
zero errors beyond the known UVM `timescale` baseline, lint 0/0, and the
filelist guard passing for all eight configurations.

Elaborating clean first time is worth noting only because of WHY: every bug
found in 3a - the byte-enable decode, the DWORD-rounding, the positional request
matching, the interface-array and cast-expression constructs - was fixed in
shared code, so 3b and 3c inherited the fixes rather than repeating the
discoveries. That is the return the tiering was supposed to produce, arriving
one tier later than hoped.

## The write split is a DIFFERENT rule

`ref_dma.split_write` is not `split_read` with a different constant
(`dma_if_pcie_wr.v:546-565`):

* the limit is **max_payload_size**, not MRRS - a write carries its data;
* the alignment term is **addr[1:0]**, a DWORD, not addr[6:0]. There are no
  completions coming back, so there is no RCB to align to.

Verified the same way as the read split, against an independent transcription
of the RTL: **268,830 cases, zero divergent.**

## What Tier 3b deliberately does NOT test

A posted write gets no completion, so there is no reordering, no tag in flight,
no timeout and no host-side error injection. The 3b list is 9 tests against 3a's
19, and padding it to match would have meant writing tests that cannot fail.

`IMM_ENABLE` is set to 1 in `tb_top_tier3b`. At the RTL default of 0 the imm and
imm_en ports are dead wires and `t3b_immediate` would pass while exercising
nothing - the same class of silent-pass the drain checks exist to prevent.

## Tier 3c: the loopback is the point

`dma_if_pcie` is a thin wrapper around the two engines sharing one RAM, so 3c
adds almost no plumbing. It deliberately does NOT repeat 3a's and 3b's sweeps.

The new component is `host_mem_writer`, which commits observed write TLPs back
into the host memory model. That closes the loop and makes the one check
available nowhere else possible:

    host[src] --read engine--> RAM --write engine--> host[dst],  then compare.

No reference model sits between the two directions. **A model that is wrong in a
self-consistent way cannot hide there** - which matters because that is exactly
what bug 9 was: `mqnic_rc_model` and `sb_dma` agreed with each other and both
disagreed with the DUT. The loopback would have caught it without any RTL
reading at all.

## Status

| Gate | Result |
|---|---|
| slang elaboration, 8 configurations | 0 errors beyond the UVM `timescale` baseline |
| portability lint (rules 1-3) | 0 / 0 on 3, 3b, 3c |
| `check_filelists.py` | 8/8 OK |
| split-rule cross-checks vs RTL | 270,570 read + 268,830 write cases, 0 divergent |
| export fidelity | 3/3 tiers: all files byte-identical bar the 9 intended include rewrites |
| **VCS simulation** | **3b and 3c: NOT RUN. 3a: partial.** |

34 Tier 3 tests exist. Elaboration and lint are evidence of compilability, not
of correctness, and §19's gate is not met for any sub-tier.


---

## Bug 10 - the same wrong assumption, on the other engine

First run of `t3b_random_stress`:

```
"pcie_tlp_if.sv", 123: tb_top_tier3b.wr_req_vif.a_sop_implies_valid: failed at 222000ps
TLP: sop asserted on an invalid segment
```

The Tier 3b top said, in a comment I wrote without checking:

```
// dma_if_pcie_wr ties tx_wr_req_tlp_sop/eop from its own framing state,
// so unlike the read engine this channel DOES gate them - the default stands.
```

That was an assumption stated as fact. The RTL (`dma_if_pcie_wr.v:839-841`):

```verilog
tx_wr_req_tlp_valid_next = tx_wr_req_tlp_valid_reg && !tx_wr_req_tlp_ready;  // clears
tx_wr_req_tlp_sop_next   = tx_wr_req_tlp_sop_reg;   // HELD
tx_wr_req_tlp_eop_next   = tx_wr_req_tlp_eop_reg;   // HELD
```

valid clears on the handshake; sop and eop are latched. So the write engine does
not gate its framing either - by a different mechanism from the read engine,
which ties them to a constant, but with the same consequence.

### Fix
`wr_req_vif.sop_eop_gated = 1'b0` in `tb_top_tier3b`, and the same for
`wr_req_vif` in `tb_top_tier3c` where the identical latent bug was waiting.

### Guard - and why a comment was not enough
This is bug 8 a second time. Bug 8 added the per-instance flag; it did not stop
the mistake recurring, because the flag DEFAULTS, and a default is an answer
given without asking the question.

**Portability lint rule 4** now requires every `pcie_tlp_if` instance in a
testbench top to assign `sop_eop_gated` explicitly. It immediately found three
more instances relying on the default - `dmx_in_vif` in the Tier 1 and 1b tops
and `rx_cpl_vif` in Tier 3 and 3c. All four are correct at 1, but none of them
SAID so, and the next person to attach one of those channels to a different
producer would have inherited the same trap.

The rule is a convention check rather than a portability one, and the lint's
docstring now says so.

### The lesson
The rule of thumb on this codebase is that ROUTING blocks gate their framing and
DMA ENGINES do not. That is worth knowing and worth writing down - which it now
is, in `pcie_tlp_if` - but it is not worth relying on. A default that is right
three times out of four is worse than no default, because the fourth case
presents as a DUT bug.


---

# Step 6 - Tier 4 (PCIe shim): the tuser codec

§22 R2 names the `tuser` decode "the single most error-prone piece of the whole
TB". It was built first, transcribed from RTL rather than PG213, and validated
against an independent Python transcription BEFORE any UVC was written -
the same discipline that caught the Tier 3 split-rule bugs.

## Three findings that change the shape of Tier 4

**1. RC is the only channel that straddles at the golden width.**
`mqnic_core_pcie_us.v:163-166` sets `RC_STRADDLE = DATA_WIDTH >= 256` but
`RQ/CQ/CC_STRADDLE = DATA_WIDTH >= 512`, and mqnic builds at **256**. So at the
width Corundum actually ships, straddling exists on ONE channel. The risk is
concentrated, not spread over four.

**2. The DUTs read very little of tuser.** `pcie_us_if_rc.v` samples framing
bits only - `byte_en[31:0]`, discontinue and parity are never read.
`pcie_us_if_cq.v` samples the byte enables and framing. The 75/85/137/161/183-bit
layouts are mostly fields the DUT ignores, so the TB has far fewer bits to get
right than the widths suggest.

**3. RQ's width is 62 in mqnic, not the module default 60.** That makes
`RQ_SEQ_NUM_WIDTH` 6 and **splits seq_num across `[27:24]` and `[61:60]`**.
Reading only the low nibble truncates every sequence number above 15 - which
would present as the DUT reusing sequence numbers. §7.6 has been corrected;
it stated the mqnic widths as if they were the module's.

## Bug 11 - the RC straddle encoder, caught by the cross-check

The first `rc_tuser_encode` assigned the two is_sop bits POSITIONALLY - first
sop to bit 32, second to bit 33. The RTL addresses them **by lane**:

```verilog
if (s_axis_rc_tuser[32]) begin
    if (rc_frame_reg) rc_strb_sop[4] = 1'b1;   // continuing -> slot 1
    else              rc_strb_sop[0] = 1'b1;   // fresh      -> slot 0
end
if (s_axis_rc_tuser[33]) rc_strb_sop[4] = 1'b1;
```

Bit 32 means lane 0, bit 33 means lane 4. A lone TLP starting at lane 4 must set
bit 33; the positional encoder set bit 32 and the DUT placed it at lane 0. Every
straddled second TLP would have landed at the wrong offset.

The sweep also surfaced a constraint that is nowhere stated explicitly:
**straddle slots are quantised to 128 bits**. `is_sop_ptr` is 2 bits and is
multiplied by 4 (`rc:301`), so a TLP may begin only at lane 0 or 4 at 256-bit
data. That is a hard constraint on the DRIVER - stimulus starting at lane 1 is
not representable, and a driver that generates it is producing illegal traffic,
not testing anything.

Final: **308 framing cases, 0 divergent**, across both widths and both the
single-TLP and straddled-pair shapes.

## Status

Delivered: the codec in `mqnic_vrf_pkg` (encode for the TB-driven channels RC
and CQ, decode for the DUT-driven RQ and CC), plus `us_user_width()` and
`us_straddles()` so a testbench cannot pick a mismatched width/straddle pair by
hand. Elaborates clean.

Remaining for Tier 4: `pcie_us_axis_if` and the agent, `ref_tlp_shim`,
`sb_shim`, `tier4a_env`, five testbench tops, ~14 tests, `cg_straddle`.


---

## Tier 4: the AXI-Stream UVC

Four files, compiling clean and wired into all eight existing configurations:

| File | Role |
|---|---|
| `pcie_us_axis_if.sv` | one interface for all four channels |
| `pcie_us_axis_item.sv` | item + cfg |
| `pcie_us_axis_driver.sv` | source driver (RC/CQ) and sink driver (RQ/CC) |
| `pcie_us_axis_monitor.sv` | lane-wise reassembly |
| `pcie_us_axis_agent.sv` | agent + Level 0 sequences |

## One interface, not four

The wires are identical on all four channels - tdata, tkeep, tvalid, tready,
tlast, tuser - and only the tuser LAYOUT differs. Four near-identical interfaces
would mean four copies of the same AXI-S assertions and four places for them to
drift; the layout difference belongs in the codec and the direction in cfg.

`pcie_us_axis_cfg` derives `user_width()` and `straddles()` from the RTL's own
rules via `us_user_width()` / `us_straddles()` rather than taking them as
fields, so a testbench cannot pick a mismatched pair by hand. It also derives
`tb_is_source()` from the channel, and both drivers FATAL if instantiated on the
wrong side - RC and CQ flow host to DUT, RQ and CC the other way, and the
channel names do not say which.

## The monitor works in lanes, not beats

On a straddling channel a beat can end one TLP and begin another, so waiting for
tlast reassembles garbage. Each accepted beat is walked lane by lane: a lane
carrying a start opens a TLP, a lane carrying an end closes one. Same shape as
`pcie_tlp_monitor`, driven from tuser instead of sop/eop wires, and it is the
only structure that handles two TLPs per beat without special cases.

No bit position appears in the driver or the monitor. Both call the codec.

## Two assertions deliberately NOT written

* **tkeep contiguity.** On a straddling channel the lanes between two TLPs
  belong to different packets, so a gap is legal. Asserting contiguity would
  fail on exactly the traffic Tier 4 exists to test.
* **anything about tuser bits beyond the framing.** The DUTs do not read them,
  so the TB has nothing to be right about.

## Status

Done: the codec (validated, 308 cases) and the UVC. All 8 configurations
elaborate clean, lint 0/0, exports regenerated.

Remaining for Tier 4: `ref_tlp_shim`, `sb_shim`, `tier4a_env`, the testbench
tops, ~14 tests and `cg_straddle`. The next piece needs the RQ/RC/CQ/CC
DESCRIPTOR layouts - the Xilinx TLP header carried in the first DWORDs of the
payload - read out of the RTL with the same care as the tuser codec.


---

## Tier 4: ref_tlp_shim

The second half of the R2 risk. The Xilinx side carries the TLP header as a
DESCRIPTOR IN THE FIRST DWORDS OF THE PAYLOAD - 3 DWORDs for RC, 4 for
RQ/CQ/CC - rather than on a separate header bus. Converting between that and the
generic 128-bit `tlp_hdr` is the whole of Tier 4.

Transcribed from RTL, with the source line recorded for every field group:

| Direction | Source |
|---|---|
| RC parse (Xilinx -> generic) | `pcie_us_if_rc.v:346-374` |
| CQ parse (Xilinx -> generic) | `pcie_us_if_cq.v:365-408` |
| RQ build (generic -> Xilinx) | `pcie_us_if_rq.v:654-678` |
| CC build (generic -> Xilinx) | `pcie_us_if_cc.v:390-407` |

## Why one model for both directions

§10 asks for one model serving both directions, and it earns its keep for a
reason beyond tidiness: the two families are INVERSES.

    CC build  is the inverse of  RC parse   (completion descriptor)
    RQ build  is the inverse of  CQ parse   (request descriptor)

So each direction can be checked against the other. **20,000 randomized
completion headers and 20,000 request headers, encode-then-parse, zero
divergent.** A single-direction model has nothing to check itself against.

## Bug 12 - two request types with the same encoding

The first version of the request-type constants guessed:

```systemverilog
localparam bit [3:0] REQ_MEM_READ_LOCKED = 4'b0001;
localparam bit [3:0] REQ_MEM_WRITE       = 4'b0001;   // collision
```

`pcie_us_if_rq.v:207-214` gives `REQ_MEM_READ_LOCKED = 4'b0111`. With the
collision every locked read would have decoded as a memory write and been given
a phantom payload. The round-trip did not catch it because both directions used
the same wrong constant - a reminder that a self-consistent pair of models
proves consistency, not correctness. Reading the RTL is what caught it, as with
bug 9.

The RQ type derivation also needed the `5'b00001` case (locked read) that the
first version folded into the default.

## Fields deliberately NOT preserved

* **AT** survives generic -> Xilinx but RC hardwires it to 0 on the way back
  (`rc:365`).
* **EP / poisoned** reaches the RQ descriptor but CQ does not reproduce it
  (`cq:394`).

Both are RTL behaviour, not model limitations, and both are excluded from the
round-trip. A scoreboard comparing them would report the DUT for doing what it
is written to do - the same trap as the `a_sop_implies_valid` assertion.

## Status

Done: the tuser codec (308 cases), the AXI-S UVC, and `ref_tlp_shim`
(40,000 cases). All 8 configurations elaborate clean, lint 0/0.

Remaining for Tier 4: `sb_shim`, `tier4a_env`, the testbench tops, ~14 tests
and `cg_straddle`.


---

## Tier 4a complete - and a blocker in the RTL

Built: `sb_shim`, `cg_straddle`, `tier4a_env`, `tb_top_tier4a`, 10 tests. All nine
configurations elaborate clean, lint 0/0, `check_filelists.py` 9/9.

## Bug 13 - the shipped configuration does not elaborate

`pcie_us_if_{rc,cq}` instantiate `pcie_tlp_fifo`, which instantiates
`pcie_tlp_fifo_raw`. That module computes

```verilog
parameter SEG_SEL_WIDTH = $clog2(OUT_TLP_SEG_COUNT);
...
seg_mem_wr_sel[cur_seg*SEG_SEL_WIDTH +: SEG_SEL_WIDTH] = seg;   // :450
```

At `TLP_SEG_COUNT = 1` - which is what mqnic builds
(`mqnic_core_pcie_us.v:562`) - `SEG_SEL_WIDTH` is **zero**, and that is a
zero-width part select. **slang rejects it** ("value must be positive") and
**VCS rejects it** (IRIPS). Vivado tolerates it, which is why the RTL ships
this way and why nobody has hit it.

`SEG_SEL_WIDTH` is a body parameter, so it cannot be overridden from the
testbench. This is the SAME defect that removed `pcie_tlp_fifo_raw` from Tier 1,
but there it could be dropped; here the shims instantiate it, so it cannot.

### What was done, and what it costs
`tb_top_tier4a` runs at `TLP_SEG_COUNT = 2`. That elaborates.

**It also means Tier 4a verifies a configuration Corundum does not build**, and
that qualifier belongs in any report of the result. It is recorded in the
testbench top, in `rtl_tier4a.f` and here rather than in one place, because it is
the kind of caveat that gets lost.

### Consequence still open
At `SEG_COUNT = 2` the generic-side monitor (`pcie_tlp_monitor`) still keys on
`tlp_sop[0]` alone - it was written at Tier 1b for the single-segment
configuration every tier below Tier 4 uses. It will therefore MISS TLPs
presented on segment 1. Until that is fixed the Tier 4 scoreboard sees only half
the traffic, and a green run would prove less than it appears - the Tier 2
failure mode exactly.

That is the next piece of work on this tier, and it is a real gap, not a
tidy-up.

## Tier 4a test list

10 tests: `t4a_reset`, `t4a_rc_basic`, `t4a_rc_straddle`, `t4a_rc_len_sweep`,
`t4a_rc_status`, `t4a_cq_basic`, `t4a_cq_addr_sweep`, `t4a_backpressure`,
`t4a_both_channels`, `t4a_random_stress`.

`sb_shim.check_phase` fails a run in which RC never straddled: a straddling
channel that never straddled has not been tested for the thing it exists to be
tested for, and §14.4 makes that coverage mandatory.


---

## Multi-segment support in pcie_tlp_monitor

The gap flagged when Tier 4a moved to `TLP_SEG_COUNT = 2`, now closed.

### What was wrong
`collect()` keyed on `tlp_sop[0]` and `tlp_eop[0]` alone. Correct for
`TLP_SEG_COUNT = 1` - which is every tier below Tier 4 - and it would have
**silently dropped every TLP presented on segment 1**. The scoreboard would have
seen half the traffic and reported the other half as matching. That is the Tier 2
failure mode ("a green-looking run for traffic that had barely started") one tier
up, and it is why this was fixed before running rather than after.

### The fix
`collect()` now iterates segments. Each segment owns a contiguous slice of the
strobe lanes, `seg_strb_width()` wide, and carries its own header, sidebands and
framing bits; the segment index from a lane is `lane / seg_strb_width`, the same
mapping the RTL uses (`pcie_us_if_rc.v:308-320`).

Only ONE TLP is open at a time: the segments form a single ordered stream, not
independent channels. That is what distinguishes this interface from
`dma_ram_if`, where the segments really are independent and the UVC has to model
them as such. Getting that distinction wrong in either direction produces a
monitor that looks reasonable and is wrong.

### The driver was NOT extended, on purpose
`pcie_tlp_driver` still presents a whole TLP on segment 0. Tier 4's generic-side
agents are SINKS, so nothing needs it yet - but a future multi-segment master
would leave the upper segments idle and the DUT would see a fraction of the
traffic.

It now FATALs on `cfg.seg_count > 1` with a message pointing at the reason. The
difference between "not yet needed" and "silently broken" is whether it says so,
and this project has now been bitten three times by things that defaulted
quietly (bugs 8, 10, and this one).

## Status after Tier 4a

| Gate | Result |
|---|---|
| slang elaboration, 9 configurations | 0 real errors |
| portability + convention lint (rules 1-4) | 0 / 0 |
| `check_filelists.py` | 9/9 |
| model cross-checks vs RTL | 308 framing + 40,000 descriptor + 539,400 split cases |
| exports | 9 tiers regenerated |
| **VCS simulation** | Tiers 1-3 partial; **Tier 4 not run** |

Still open on Tier 4: the `SEG_COUNT = 1` RTL blocker (bug 13) means this tier
verifies a configuration Corundum does not build. Tier 4b (the transmit shims
`pcie_us_if_rq` and `pcie_us_if_cc`) is not started.


---

## Bug 14 - the CQ byte enables were never recovered from the wire

First run of `t4a_random_stress`:

```
expected: 0x6000000802001f0000000001ba9e089c
actual  : 0x6000000802001fff00000001ba9e089c
                          ^^
```

One byte differs: `h[71:64]`, which is `{last_be, first_be}`. The model said
0x00; the DUT said 0xFF. The DUT was right - the sequence drove 0xF/0xF, the
driver encoded them into tuser and the shim read them back correctly.

### Cause
`pcie_us_axis_monitor.publish()` recovered `first_be`/`last_be` for the
DUT-driven channels (RQ, CC) and not for CQ, because the TB drives CQ and "we
already know what we sent" felt true.

**It is not true. The scoreboard is fed by the MONITOR, not by the sequence**,
and the monitor only knows what is on the wire. `sb_shim` therefore called
`cq_parse(desc, 0, 0)` and predicted zero byte enables.

The codec had `us_cq_tuser_encode` from the start and no decode, for the same
reason. Both are now present.

### The lesson
A TB-driven field still has to be OBSERVED. The moment a scoreboard is fed from
a monitor - which is the whole point of a monitor - "the testbench knows" stops
being an argument. This is the mirror image of the Tier 3 lesson that a finished
sequence is not finished traffic.

## Bug 15 - the rule of thumb was wrong

`a_sop_implies_valid` fired on `cq_tlp_vif`, the third time this assertion has
caught a producer that does not gate its framing.

After bug 10 I recorded a rule of thumb in `pcie_tlp_if`: routing blocks gate
their framing, DMA engines do not. `tb_top_tier4a` was written from that rule -
the shims are routers, so both channels were set to `gated = 1`.

**The rule is wrong.** `pcie_us_if_{rc,cq}` drive their generic side from
`pcie_tlp_fifo_raw`, which latches sop/eop and clears only valid
(`pcie_tlp_fifo_raw.v:546-547, 587-588`) - the same shape as the DMA engines, by
way of a module they share.

The real predictor is whether the producer's output stage is
`pcie_tlp_fifo_raw`. That is not something to infer from a block's ROLE, which
is exactly what the rule of thumb invited.

### What changed
Both Tier 4 channels set `sop_eop_gated = 1'b0`, and the note in `pcie_tlp_if`
now says there is NO reliable rule of thumb and explains why. slang_check rule 4
already forced the value to be stated explicitly per instance; what it could not
do was stop me stating it from a bad heuristic instead of from the RTL.

Guessing this has now cost three simulation rounds (bugs 8, 10, 15). The
mechanism that would actually have prevented all three is the one used for the
tuser codec and the split rules: read the RTL, and write down the line number.


---

## Bug 16 - the straddle driver deadlocked at the end of every burst

`t4a_random_stress` timed out four times, and the message said the interesting
part:

```
did not drain in 100000 cycles: rc 0 unconverted, cq 0 unconverted
```

Both scoreboards EMPTY, yet `is_idle()` false. So the stall was not in the
checking - it was in `pcie_us_axis_agent.pending_items()`, i.e. a TLP stuck in
the driver's `m_held`.

### Cause
The driver holds a TLP back so it can straddle it with the next one, and used
`seq_item_port.get_next_item()`, which BLOCKS. At the end of a burst there is no
next one: the held TLP waits forever, is never driven, and `pending_items()`
never returns to zero.

The counters said so plainly once read together:

```
driver : drove 119 TLP(s)
monitor: 117 TLP(s)
```

### Fix
`try_next_item()` instead, so the driver can notice the sequencer has gone quiet
and flush the held TLP on its own. `flush_held()` clears `m_held` BEFORE calling
`send_one`, because `send_one` blocks and `pending_items()` must not count the
same TLP twice while it is being driven.

### Bug 17 (same run) - two counters, two different meanings

```
driver : 34 of them straddled
monitor: 17 straddled
```

Not lost traffic: the driver marked BOTH members of a straddled pair, the
monitor marks only the one that BEGINS mid-beat - which is the only one it can
observe as such. Exactly a factor of two, which is what made it look like data
loss on top of a real data loss and cost time separating them.

Both now count the TLP that begins mid-beat, and the driver's message spells out
the relationship ("N of which began mid-beat, i.e. N straddled pairs").

### The lesson
A counter is a measurement, and two measurements of "the same" thing that use
different definitions are worse than one. This masked bug 16 rather than
revealing it.

### Encouraging, in the same run
CQ was completely clean: 120 driven, 120 monitored, 120 converted, 0 header and
0 payload mismatches. RC converted all 117 TLPs it received with 0 mismatches,
including 17 straddled ones - so the tuser codec, ref_tlp_shim and the lane-wise
monitor are all doing their job. Straddle coverage reached 65.83% on one run of
one test.


---

## Bug 18 - the deadlock fix overshot and killed straddling

`t4a_backpressure` came back with every datum clean - 48/48 on both channels, 0
header and 0 payload mismatches - and one failure, my own check:

```
RC straddles at this width but no straddled TLP was driven
driver: drove 48 TLP(s), 0 of which began mid-beat
```

Bug 16's fix replaced the blocking `get_next_item()` with `try_next_item()` and
flushed the held TLP the moment the sequencer went quiet. `t4a_backpressure`
interleaves RC and CQ sends, so the RC sequencer is empty for a cycle between
EVERY pair of items - and the partner was flushed away before it could arrive.
Straddling fell from 17 pairs to zero.

The previous run had hidden this: `t4a_random_stress` sends 12 RC back to back,
which is the one pattern where an immediate flush still leaves time to pair.

### Fix
`cfg.straddle_hold_cycles` (default 16). The driver counts consecutive idle
cycles while holding and flushes only after that many. Long enough to survive
the gap an interleaved test leaves, far shorter than any drain-wait, and drain
is still guaranteed because the flush always eventually fires.

### Bug 19 - a mandatory check on the wrong scope

`sb_shim` failed any run in which RC never straddled. §14.4 makes straddle
coverage mandatory FOR THE TIER, and I applied it to EVERY TEST. `t4a_backpressure`
is about backpressure; it legitimately produced no straddled TLP, and failing it
taught nothing.

A check that fires on correct runs is worse than no check: it trains people to
scroll past the failure. `require_straddle` now defaults off and is set by the
two tests that exist to straddle - `t4a_rc_straddle` and `t4a_random_stress` -
where a zero really does mean the driver stopped pairing.

### Worth recording
Three consecutive Tier 4 runs have come back with ZERO data mismatches on both
channels. Every failure has been in test/driver plumbing or in my own checks.
The dense bit-field work that §22 R2 warned about - the tuser codec, the
descriptor layouts - has not produced a single functional error, which is what
the 348,000 cross-check cases were for.


---

# Tier 4b - started: sb_shim is now bidirectional

Tier 4a (RC, CQ) flows Xilinx -> generic. Tier 4b (RQ, CC) flows the other way,
so the roles of the two analysis ports SWAP: the generic TLP becomes the
stimulus and the AXI-S item the result.

`sb_shim` now carries a `tx_direction` bit and routes accordingly. ONE
scoreboard serves both directions because the check is the same equivalence and
`ref_tlp_shim` already models both - a second scoreboard would be a second place
for the field list to drift, which is the failure mode §22 R2 is about.

The transmit-direction comparison reports descriptor DWORDs and payload DWORDs
under SEPARATE counters. A descriptor-build bug and a data-path bug look nothing
alike and should not share a number - the same argument that split header from
payload in the receive direction, and the same one bug 17 taught about counters
that mean different things.

## What remains, and one piece is not plumbing

* `tier4b_env`, `tb_top_tier4b`, tests - straightforward, the pattern is set.
* **pcie_us_if_cc** is a clean transmit shim: TLP in, AXI-S out, nothing else.
* **pcie_us_if_rq is NOT.** It takes TWO TLP inputs (read requests and write
  requests), arbitrates between them, emits transmit sequence numbers, and -
  the part that is genuinely new - is GATED BY FLOW CONTROL:

      input tx_fc_ph_av, tx_fc_pd_av, tx_fc_nph_av, tx_fc_npd_av

  `pcie_us_if_rq.v:870-872` holds off transmission until posted/non-posted
  header and data credits are available. Nothing below Tier 4 has a credit
  model, so one has to be built, and a testbench that ties the credits high
  would verify the shim only in the case where flow control never binds -
  which is the case that never fails.

That is worth calling out before it is written rather than after: it is the
first Tier 4 component that is not a pure function of its input.


---

## pcie_tlp_driver: multi-segment, and the guard that forced it

Building Tier 4b hit the `uvm_fatal` added when the monitor went multi-segment:
the TB must DRIVE the generic side for RQ and CC, and the driver was segment-0
only.

That is the guard working exactly as intended. It converted "this will quietly
drive a fraction of the traffic" into "this stops, and says why" - the
distinction bugs 8, 10 and 15 all turned on.

### The change
A beat spans `cfg.seg_count` segments, each owning `seg_strb_width()` lanes. A
TLP now occupies the segments its bytes actually reach: sop on the first, eop on
the last one used, and any segment between them valid with neither.

The header and sidebands still ride segment 0. This driver never starts a TLP
mid-beat - straddled STIMULUS is a Xilinx-side shape, produced by
`pcie_us_axis_driver`, and putting it in both places would be two models of one
behaviour.

### Why segment-0-only was not good enough
It is legal stimulus. It is also weak: it never presents a TLP that SPANS
segments, which is precisely the case a multi-segment consumer gets wrong. And
it could not drive Tier 4b at all, since that tier runs at SEG_COUNT = 2 to work
around bug 13.

All nine configurations still elaborate clean and lint 0/0, including Tiers 1b
and 3 which continue to run at SEG_COUNT = 1 through the same code path.


---

# Tier 4b (CC) - built, with a larger caveat than Tier 4a

`tier4b_env`, `tb_top_tier4b`, 7 tests. Elaborates clean; 10 configurations now
build.

## Bug 13 bites harder here, and the Tier 4a workaround does not apply

Tier 4a escaped the zero-width part select by raising `TLP_SEG_COUNT`, because
`pcie_us_if_{rc,cq}` pass it straight through:

```verilog
.OUT_TLP_SEG_COUNT(TLP_SEG_COUNT)
```

`pcie_us_if_cc` does not:

```verilog
.OUT_TLP_SEG_COUNT(INT_TLP_SEG_COUNT)
parameter INT_TLP_SEG_COUNT = (CC_STRADDLE && AXIS_PCIE_DATA_WIDTH >= 512) ? 2 : 1;
                                                          // pcie_us_if_cc.v:82
```

`INT_TLP_SEG_COUNT` is DERIVED FROM THE DATA WIDTH. At 256 it is 1 no matter
what `TLP_SEG_COUNT` is set to, so `SEG_SEL_WIDTH` is 0 and the module does not
elaborate. The only escape is 512-bit data.

### The cost, stated plainly
At 512, `CC_STRADDLE` becomes true. So Tier 4b exercises a STRADDLING CC channel
that Corundum never builds, and does NOT exercise the non-straddling 256-bit CC
that it does. That is a bigger caveat than Tier 4a's and it belongs on any
result taken from this tier.

## The monitor now REFUSES rather than mis-decodes

Straddling CC brought out a real gap: `pcie_us_axis_monitor.decode_framing`
implements the RC/CQ tuser shape (is_sop at [64+seg] or [80+seg] with a separate
pointer). CC packs it differently - `[1:0]` is_sop, `[3:2]` is_sop0_ptr, `[7:6]`
is_eop, `[11:8]` is_eop0_ptr (`pcie_us_if_cc.v:484-520`) - and RQ differently
again.

Applying the wrong layout would not fail. It would silently reassemble the wrong
bytes, which is exactly the §22 R2 failure mode. The monitor therefore FATALs on
a straddling CC or RQ channel rather than guessing.

**Tier 4b will hit that fatal on the first run.** That is intended: the layout
has to be transcribed from the RTL and cross-checked the way the RC/CQ codec was
(308 cases) before it can be trusted. Shipping a plausible guess is what bugs 9,
12 and 15 all were.

## Status

| | |
|---|---|
| Tier 4a (RC, CQ) | built, simulated, 0 data mismatches over three runs |
| Tier 4b (CC) | built, elaborates; **blocked on the CC straddle tuser layout** |
| Tier 4b (RQ) | not started; needs a flow-control credit model |


---

## Bug 13 - RESOLVED by patch, and the first patch was not enough

`rtl_patched/` now holds TWO files, each one line different from `fpga/`:

```verilog
// pcie_tlp_fifo_raw.v  (parameter list)
-  parameter SEG_SEL_WIDTH = $clog2(OUT_TLP_SEG_COUNT),
+  parameter SEG_SEL_WIDTH = $clog2(OUT_TLP_SEG_COUNT) > 0 ? $clog2(OUT_TLP_SEG_COUNT) : 1,

// pcie_tlp_fifo.v      (body parameter, ~:106)
-  parameter SEG_SEL_WIDTH = $clog2(INT_TLP_SEG_COUNT);
+  parameter SEG_SEL_WIDTH = $clog2(INT_TLP_SEG_COUNT) > 0 ? $clog2(INT_TLP_SEG_COUNT) : 1;
```

### Why the second file was needed
Patching `pcie_tlp_fifo_raw` alone changed NOTHING, and the reason is worth
recording: `pcie_tlp_fifo` passes its own copy down as an explicit override -

```verilog
pcie_tlp_fifo_raw #( ... .SEG_SEL_WIDTH(SEG_SEL_WIDTH), ... )    // :155
```

so the floored default in the child was overridden by the zero from the parent.
The patch looked right, elaborated, and did nothing. Tier 4b happened to work
because `pcie_us_if_cc` instantiates `pcie_tlp_fifo_raw` DIRECTLY and does not
pass the parameter - which is exactly the kind of asymmetry that makes a partial
fix look like a complete one.

A defaulted parameter is only a default until somebody overrides it. That is the
same lesson as bugs 8, 10 and 15, in a different costume.

### What the patch bought

| | Before | After |
|---|---|---|
| Tier 4a | SEG_COUNT = 2, a config Corundum does not build | **SEG_COUNT = 1, the shipped config** |
| Tier 4b | forced to 512-bit, CC straddling | **256-bit, CC not straddling - the shipped config** |
| CC straddle tuser transcription | required | **not needed** |

Both caveats are gone and one task disappeared with them. The
`pcie_us_axis_monitor` guard that refuses to decode a straddling CC/RQ stays in
place - unreachable at 256, but it records why the transcription is absent
instead of leaving a silent gap.

### Scope
`rtl_patched/` is the ONLY modified RTL in the project - two files, one line
each, both with headers stating the change, the reason and the effect.
Everything else under `fpga/` is used verbatim, and the export generator now
says so in the Design pane header. If upstream fixes this, delete the directory
and repoint two filelists.

### Worth reporting upstream
`$clog2(1) == 0` yields a zero-width part select, which IEEE 1800 does not
permit. slang and VCS both reject it; Vivado accepts it. Corundum ships
`TLP_SEG_COUNT = 1` (`mqnic_core_pcie_us.v:562`), so anyone simulating
`pcie_us_if` outside Vivado hits this.

## Status

| Gate | Result |
|---|---|
| slang elaboration, 10 configurations | 0 real errors |
| portability + convention lint (rules 1-4) | 0 / 0 |
| `check_filelists.py` | 10/10 |
| model cross-checks vs RTL | 348,000+ cases |
| exports | 10 tiers regenerated |

Tier 4a and 4b both now run the configuration Corundum actually builds.
Remaining: RQ (needs a flow-control credit model), then the §19 Tier 4 gate and
the §23 scope decision.


---

## Rename: tier4 -> tier4a, and a guard that was not guarding

"Where is tier4a?" was a fair question: §5 splits the tier into 4a and 4b, the
prose said 4a throughout, and the tooling called it plain `4`. Renamed
consistently - filelists, testbench top, env, tests directory, class names and
test names (`t4_*` -> `t4a_*`, matching `t4b_*`).

## Bug 20 - the filelist guard silently stopped checking the renamed tier

`check_filelists.py` keeps a hand-maintained `PAIRS` table. The rename updated
the files but not the table, so the script simply **skipped tier4a** - and
printed OK for all nine others. A green result meaning "I did not look at the
one thing you just changed".

That is the same class of failure as bugs 8, 10, 15 and 18: something defaulted
or was omitted quietly, and the quiet is what did the damage.

### Fix
The script now audits its own table. Any `*.f` in `sim/filelists/` not covered by
`PAIRS` is reported as `UNCHECKED` and fails the run. Verified by removing an
entry and confirming it fires.

That immediately found a second, older gap: **`rtl_smoke.f` had never been
covered** - the Step 0 smoke filelist, unchecked since it was written. It has no
tb pair and no wrappers or binds, so there was nothing to check, but that is now
an explicit exemption with a reason rather than an omission nobody noticed.

### The principle
A checker that can be bypassed by forgetting to update it is not a checker. If
it has a hand-maintained list, it has to verify the list covers the ground.

## Status after the rename

| Gate | Result |
|---|---|
| slang elaboration, 10 configurations | 0 real errors |
| portability + convention lint (rules 1-4) | 0 / 0 |
| `check_filelists.py` | 10/10, self-audit active |
| exports | 10 tiers regenerated, `tier4a_multifile` replaces `tier4_multifile` |

Tier 4a and 4b both run the configuration Corundum ships. Remaining for Tier 4:
RQ, which needs a flow-control credit model - then the §19 gate and the §23
scope decision.


---

# Tier 4c (pcie_us_if_rq) - the credit and arbitration model

The last DUT in Tier 4, and the only one that is not a pure function of its
input. Two pieces built and cross-checked before any environment was written:

* `uvc/common/pcie_us_fc_if.sv` - the four transmit credit counters
* `model/ref_rq_arb.sv` - credit availability and port arbitration

## What the RTL actually does

Two ports drawing on DIFFERENT credit pools (`pcie_us_if_rq.v:381, 448`):

| port | stream | class | gate |
|---|---|---|---|
| 0 | read requests | non-posted | `tx_fc_nph_av > 8` |
| 1 | write requests | posted | `tx_fc_ph_av > 8 && tx_fc_pd_av > (mps_fc << 1)` |

`mps_fc = 8 << min(max_payload_size, 5)` (`:871`) - CREDIT units, not bytes.

Arbitration is FIXED PRIORITY starting at port 0 (`:523-536`), so a read request
beats a write request whenever both are ready.

## Two things that would have been easy to get wrong

**The thresholds are strict inequalities.** A credit count of exactly 8 BLOCKS.
The cross-check asserts both sides of both boundaries, which is where an
off-by-one would otherwise sit unnoticed.

**Fixed priority makes the write path nearly untestable by default.** With both
credit pools full, reads always win and writes are barely exercised. A test that
wants to see the posted path has to STARVE THE POSTED POOL - hence
`starve_p()` in the interface, alongside `starve_np()` and `starve_all()`.

That is also why the credits are an interface rather than a tie-off. Tying them
high verifies the shim only in the case where flow control never binds, which is
the case that never fails - the same trap as a completion-timeout test that
cannot reach the timeout (bug 4).

## Remaining for Tier 4c
`sb_rq` (two input streams merging into one output, so matching cannot be
positional), `tier4c_env`, `tb_top_tier4c`, tests.


---

## Tier 4c complete - all four shims built

`sb_rq`, `tier4c_env`, `tb_top_tier4c`, 8 tests. Eleven configurations now
elaborate clean, lint 0/0, filelist guard 11/11.

## What makes 4c different, and why it is its own sub-tier

§5 planned Tier 4 as 4a/4b. RQ forced a third: it is the only shim that is not a
pure function of its input. Two streams merge onto one output under fixed
priority, and both are gated by credits.

`sb_rq` therefore differs from `sb_shim` in two ways:

* **Matching cannot be positional.** An observed TLP is matched against the head
  of EITHER expected queue by content - the same set-versus-sequence argument as
  `sb_dma`, reached for a different reason (a merge rather than concurrency).
* **Arbitration is checked, not tolerated.** Matching against either queue would
  accept a DUT with the priority reversed, since every individual TLP would
  still be correct. The grant is compared against `ref_rq_arb` before the match
  is taken.

`t4c_starve_all` checks SILENCE. When neither pool has credit the DUT must
transmit nothing, and a scoreboard that only inspects what did appear passes
that trivially - so `expect_silence` turns the absence into a positive check.
Same shape as the drain checks at Tier 2 and the straddle mandate at Tier 4a:
the failures that matter are the ones where nothing happens.

## Bug 21 - hex literals, third occurrence

`8'(0x40 + i)` again. Python syntax in SystemVerilog, caught by the compiler
each time and costing a round trip each time. Worth noting the pattern rather
than the instance: three identical slips means it is not carelessness in the
moment, it is a habit that needs a lint rule if it recurs again.

## Tier 4 status

| | built | elaborates | simulated |
|---|---|---|---|
| 4a  RC + CQ | yes | yes | yes - 0 data mismatches over 3 runs |
| 4b  CC      | yes | yes | yes |
| 4c  RQ      | yes | yes | **not yet** |

§19's Tier 4 gate is NOT met: 4c unrun, and no tier anywhere has multi-seed
regression, coverage closure, the cocotb cross-check (E6) or a nightly (E7).


---

## Bug 22 - checking a property the testbench cannot observe

First run of `t4c_random_stress`:

```
read in=30  write in=30  RQ out=60
match=60  mismatch=17
priority errors=17
```

**Every TLP converted correctly and none was lost.** All 17 failures were the
arbitration check.

### Cause
`sb_rq` asserted "a read was pending with credit, so a read must come out",
using its OWN queue depth as the definition of pending.

The DUT's arbiter does not look at that. `pcie_us_if_rq` instantiates a
`pcie_tlp_fifo_raw` PER PORT (`:314`, `:384`) and arbitrates on
`fifo_tlp_valid[port]` (`:513`). A TLP accepted at the input has not reached the
arbiter yet, so "pending in the scoreboard" and "available to the arbiter" are
separated by a FIFO whose occupancy is not visible from outside.

The check was measuring the model's ignorance of the pipeline, not the DUT.

### Fix
Removed. Replaced with the CREDIT rule, which is genuinely observable and
timing-independent: a TLP from a port whose credit is below threshold must never
appear. If the credit is unavailable it is unavailable for the whole window, so
no pipeline knowledge is required.

`t4c_priority` became `t4c_both_streams` and now checks what it can - that every
TLP from both streams converts correctly and none is lost under contention. The
per-port counts are REPORTED, not asserted: a distribution is a fact about this
DUT's arbitration, not a requirement the interface can express.

### The lesson, and it is a different one from the earlier bugs
Bugs 8, 10 and 15 were WRONG FACTS about the RTL, fixed by reading it. This was
a well-formed check of a property the testbench has no way to see. Reading the
RTL would not have prevented writing it - `ref_rq_arb` models the arbitration
correctly, and the model is fine. What was wrong was believing the scoreboard's
queue stood for the DUT's internal state.

Before asserting a property, ask what OBSERVES the terms in it. Here one term
was two FIFOs away from anything on an interface.

### Worth recording
A white-box SVA bound to `pcie_us_if_rq` could check the priority properly -
`fifo_tlp_valid[port]` is right there in the module. That would be a legitimate
future addition under §15.1, which already allows bind-based assertions. It is
not a gap in the black-box scoreboard; it is a different tool for a property
the black box cannot reach.


---

# §19 E6 - cross-check against the cocotb block testbenches

11 of the DUTs verified here also have a cocotb TB. `cocotbext-pcie` is not
installed and no simulator is available in this environment, so the cross-check
was done by COMPARING TEST INTENT AND MODEL BEHAVIOUR against the cocotb source
rather than by running both. That is weaker than a live comparison and it still
found a real bug on the first DUT examined.

## Bug 23 - zero-length descriptors were unmodelled, and untested

`fpga/lib/pcie/tb/dma_if_pcie_rd/test_dma_if_pcie_rd.py:175` sweeps

```python
for length in list(range(0, byte_lanes+3)) + list(range(128-4, 128+4)) + [1024]:
```

**Starting at 0.** Every length sweep in our Tier 3 suite started at 1.

The RTL special-cases it (`dma_if_pcie_rd.v:795-798`): `len == 0` sets
`op_count = 1` and `zero_len`, and the request is emitted with BOTH byte enables
zero - the standard PCIe zero-length read. One request, carrying no data.

`ref_dma.split_read` is a `while (rem > 0)` loop. At `len == 0` it emits
**nothing**. The scoreboard would have predicted no request, seen one, and
reported the DUT for doing exactly what it is required to do.

### Why nothing here could have caught it
The model and the scoreboard agreed with each other, and no test supplied the
input that would have separated them. This is the same shape as bug 12, where a
round-trip through two inverse functions proved consistency rather than
correctness - and it is precisely the failure mode §19 E6 exists to catch. An
outside opinion found it in one file.

### Fixed
* `ref_dma.split_read` and `split_write` both emit a single zero-length request.
* `sb_dma` skips the 4 KB and MRRS legality checks for a zero-length request -
  they are vacuous, and `crosses_4k(addr, 0)` would read past the end.
* `t3_len_sweep` and `t3b_len_sweep` start at 0.

## Coverage gap - destination alignment

cocotb sweeps `ram_offset` over `range(byte_lanes+1)` - 0 to 64 at our geometry.
`t3_alignment_sweep` covered 0 to 7.

The realignment path depends on the DIFFERENCE between source and destination
offsets, so an 8-wide destination sweep leaves most of the shift network
untested. Widened to 0..63 in steps of 8, crossed against the full source range.

## What could NOT be checked without running cocotb
The deep comparison - our `mqnic_rc_model` completion generation against
`cocotbext-pcie`'s RootComplex - needs the package and a simulator. That remains
open, and it is the part most likely to find a second disagreement, since it is
the largest piece of behaviour we model independently.

## Status
E6 is PARTIALLY met: static cross-check done on the DMA read path, one real bug
found and fixed, one coverage gap closed. A live run against cocotb is still
required for the gate.


---

# Regression infrastructure - lists derived, not remembered

The Step 0 scaffolding (`run_regression.py`, `sim_run.py`, `merge_coverage.sh`,
Makefile targets) was already in place. What was stale was the INVENTORY:
`nightly.list` contained one smoke test and `tier1.list` covered Tier 1a only,
while the suite had grown to **93 tests across 10 tiers**.

## Generated, for the same reason check_filelists.py now self-audits

A regression list is a hand-maintained inventory and fails the way bug 20 did,
only worse. `check_filelists.py` at least printed OK for the tiers it did check;
a missing test in a regression list produces NO output at all. The test is
written, it passes when run by hand, and it contributes nothing to the
regression forever - there is no error to notice, the list is simply shorter
than the suite.

`sim/scripts/gen_regress_lists.py` derives the lists from the registered
`uvm_component_utils` classes. `--check` fails if they have drifted, and it is
wired into the `regress` and `nightly` Makefile targets so a stale list stops a
regression rather than quietly shrinking it. Verified by appending a bogus entry
and confirming the check fails.

| list | tests |
|---|---|
| tier1a / 1b / 1c | 12 / 5 / 6 |
| tier2 | 10 |
| tier3 / 3b / 3c | 19 / 10 / 6 |
| tier4a / 4b / 4c | 10 / 7 / 8 |
| **nightly** | **93** |

`nightly.list` is labelled a CANDIDATE list, not a signoff list, because no tier
has met its §19 gate.

## The constraint worth stating plainly

**There is no simulator in this environment.** VCS is available to the user
through EDA Playground, one test at a time through a web UI.

§19's remaining criteria are not reachable that way:

* **E1** - every test across >=20 seeds. 93 tests x 20 seeds = 1,860 runs.
* **E3** - code coverage >=95%, which needs a coverage-instrumented build.
* **E7** - a nightly, green three nights running.

These need a batch simulator with a filesystem: `make regress TIER=3`,
`make nightly`, `make coverage`. The infrastructure is now in place and correct
for that flow; it cannot be exercised here.

That is a tooling gap, not a verification gap, and it is the gating item for
signoff. Everything upstream of it - the tests, the checks, the models, the
lists - is ready to be run the moment a batch simulator is available.


---

# Step 7 - Tier 5 begins: the register model

`sim/scripts/gen_ral.py` generates `ral/mqnic_ral_pkg.sv` from
`modules/mqnic/mqnic_hw.h`: **26 block types, 140 register offsets, from 299
`#define`s.** Elaborates clean. `--check` is wired into the Makefile's
`check-lists` target alongside the regression-list and filelist audits.

## What it deliberately is NOT

Not a flat `uvm_reg_block`. §8.2 called this correctly: Corundum's map is a
**walked linked list**, each block carrying its type, version and the offset of
the next.

```
+0x00  type       +0x04  version       +0x08  next_ptr  (0 terminates)
```

Where a block LANDS depends on how the DUT was parameterised. Baking one build's
offsets into the model would make it wrong for every other build - and would
hide the very bug that walking the list exists to find: a block missing, or at
an unexpected offset.

So what is generated is what the header actually fixes: the type IDs, and each
register's offset WITHIN its block. Base addresses come from the walker at run
time.

That distinction matters more than it looks. A generated flat map would have
been easy, would have compiled, and would have been a testbench that agrees with
one synthesis of the DUT and silently disagrees with the next.

## Third generated inventory, same reason

`check_filelists.py` (self-auditing), `gen_regress_lists.py`, and now
`gen_ral.py` - all three derive from a source of truth and all three have a
`--check` mode that fails on drift.

Bug 20 is the reason: an inventory kept by memory stops covering what it forgets
and produces no error when it does. A stale RAL is worse than a stale filelist,
because the testbench and the Linux driver would then disagree about the device
while both appear to work.

## Remaining for Tier 5
`mqnic_rb_walker` (the discovery model), `uvc/pcie_cfg/*` (§7.7),
`seq/driver_model/*` (§12.2, 10 sequences), `sb_csr`, `sb_irq`, `tier5_env`,
`tb_top_tier5`, 11 tests. `mqnic_core_pcie.v` is 2,141 lines - by a wide margin
the largest DUT so far.


---

## Tier 5: host register access is a SPLIT TRANSACTION over PCIe

`seq/driver_model/mqnic_csr_seq.sv` - `mqnic_csr_ctx`, `mqnic_csr_read_seq`,
`mqnic_csr_write_seq`, `mqnic_rb_walker`. Compiles clean; all 11 existing
configurations still build.

### The fact that shaped it
**mqnic_core_pcie has no AXI-Lite slave for the host.** I expected one and went
looking for it. `m_axil_csr_*` is an OUTPUT - the core's own master towards
application logic, not a way in.

The host reaches registers by issuing PCIe MEMORY REQUESTS TO A BAR
(`pcie_rx_req_tlp_*`); answers return as COMPLETIONS (`pcie_tx_cpl_tlp_*`).

So a register read is a split transaction, and this layer exists to make it look
like a function call. That is a different shape from the AXI-Lite register
access at Tier 1a, and reusing `axil_seq_lib` here would not have worked at all.

### Tag matching, again, in the other direction
Completions may return out of order, so pairing them positionally would silently
return another register's value whenever two reads overlap. `mqnic_csr_ctx`
keys them by tag.

This is the same rule the DMA engine relies on at Tier 3 - but there the DUT was
the requester and the testbench the completer. Here the roles are swapped and
the testbench has to keep the discipline itself.

### The walker
`mqnic_rb_walker` follows the linked list from a base address, reading type,
version and next_ptr from each block. The walk IS the check:

* a type the RAL has never heard of - stale RAL, or garbage from the DUT
* a version that disagrees with `mqnic_hw.h`
* a `next_ptr` that revisits a base - a loop, detected rather than spun on
* a list that does not terminate within `max_blocks`

Bounded and reported, rather than hanging until the global watchdog with no
explanation.

Walking is also how the Linux driver finds its registers, so a testbench that
walks is exercising the software's real path rather than a convenient shortcut.

### A dependency cycle avoided
`mqnic_csr_seq` needs `pcie_tlp_item`, and `pcie_tlp_pkg` imports
`mqnic_seq_pkg` - so putting the driver model in `mqnic_seq_pkg`, where §12.2
nominally places it, would close a cycle. It lives in `mqnic_env_pkg`, the first
package that already has everything it needs. Recorded because the §12.2
directory layout (`seq/driver_model/`) is kept while the package membership
differs.

### Remaining for Tier 5
`tier5_env`, `tb_top_tier5`, `test_rb_walk`, `uvc/pcie_cfg/*` (§7.7), the
remaining driver-model sequences (§12.2), `sb_csr`, `sb_irq`, 11 tests.
`mqnic_core_pcie.v` is 2,141 lines and instantiates the entire Tier 3 and Tier 4
stack plus the queue managers, schedulers and datapath.


---

## Tier 5: the port map is generated, not transcribed

`mqnic_core_pcie` has **250 ports and 162 parameters** - the port list alone is
larger than most of the DUTs below it.

Every testbench top up to now was hand-written, which was fine at 30-50 ports.
At 250 it is a transcription exercise, and transcription has cost this project
three bugs already (9: header fields; 12: request-type constants; 15: framing
assumptions).

The difference here is worse: **a mis-wired port usually still compiles.** It
connects the wrong signal or leaves an input floating, and shows up as
inexplicable behaviour hours later rather than as an error.

`sim/scripts/gen_tb_ports.py` derives the port map from the RTL, taking each
port's DIRECTION from the source rather than from memory:

* inputs the DUT reads  -> the testbench must DRIVE (tied off if unused)
* outputs the DUT drives -> the testbench must SINK (left open if unused)

Getting that backwards is the commonest way a large top goes wrong.

Verified against the RTL: **250 of 250 ports captured, no duplicates.** Unused
inputs are tied off EXPLICITLY so that "unconnected" is a decision in the file
rather than an omission from it.

## Stopping point, stated deliberately

`tb_top_tier5` is roughly 500 lines of wiring on top of that skeleton, plus
`tier5_env` and `test_rb_walk`. That is a single careful pass, not something to
half-finish - and every rushed increment in this project has cost a round trip
(bugs 16/18 in one evening, 8/10/15 across three).

Built and verified this session:
* `sim/scripts/gen_ral.py` + `ral/mqnic_ral_pkg.sv` - 26 block types, 140 offsets
* `seq/driver_model/mqnic_csr_seq.sv` - split-transaction register access, tag
  matched, plus `mqnic_rb_walker`
* `sim/scripts/gen_tb_ports.py` - verified against all 250 ports

Next, as one piece: `tb_top_tier5`, `tier5_env`, `test_rb_walk`.


---

# Tier 5 - built, and blocked on two more RTL non-conformances

`tb_top_tier5` (382 lines, port map generated), `tier5_env`, `tests/tier5` with
`t5_reset` and `t5_rb_walk`. `rtl_tier5.f` resolved by ELABORATION rather than
by guessing: 6 rounds, **71 dependency modules** added automatically.

That number is the headline. `mqnic_core_pcie` pulls in the entire design -
`mqnic_core`, both interfaces, the schedulers, the PTP stack, every DMA block
and every AXI/AXIS library module. 101 files elaborate together.

## Two errors remain, and neither is ours

**1. Parameter used before declaration** (`mqnic_interface_tx.v:87`,
`mqnic_interface_rx.v:215`)

```verilog
output wire [DMA_CLIENT_LEN_WIDTH-1:0]  m_axis_tx_req_status_len,   // :87
...
parameter DMA_CLIENT_LEN_WIDTH = DMA_LEN_WIDTH;                     // :192
```

The parameter is used in the PORT LIST and declared 105 lines later in the body.
Illegal in Verilog-2001; Vivado accepts it, slang does not.

**2. Zero-width part select, again** (`mqnic_rx_queue_map.v:259`)

```verilog
if (PORTS > 1) begin
    indir_tbl_index_reg[INDIR_TBL_ADDR_WIDTH +: CL_PORTS] <= req_id;
end
```

`CL_PORTS = $clog2(PORTS)`, which is 0 at PORTS = 1. The guard is a RUNTIME if,
not a generate, so the select is still elaborated - **exactly bug 13's pattern,
in a different file.**

## The pattern is now worth naming

Three separate instances of the same thing: RTL that Vivado accepts and every
standards-conformant front end rejects. `pcie_tlp_fifo_raw`, `pcie_tlp_fifo`,
and now `mqnic_rx_queue_map` all compute a width with `$clog2(N)` that goes to
zero at N = 1 - the configuration Corundum ships - and use it in a part select
guarded by a runtime `if`.

This is not a Corundum quirk so much as a Vivado-only codebase meeting a
standards checker for the first time. It is worth reporting upstream as a set
rather than three separate issues.

## Decision needed
Fixing these means growing `rtl_patched/` from 2 files to 4. That is the same
decision already taken for bug 13, applied consistently - but it doubles the
patched footprint, so it is the user's call rather than mine to make silently.

Everything else for Tier 5 is in place and elaborates: the RAL, the CSR access
layer, the walker, the environment, the top, and the first two tests.


---

# Tier 5 COMPLETE - the whole design elaborates

**101 files. 12 configurations. 0 real errors. 99 tests across 11 tiers.**

`mqnic_core_pcie` instantiates essentially all of Corundum: `mqnic_core`, both
interfaces, the schedulers, the PTP stack, every DMA block, every AXI/AXIS
library module. The dependency closure was resolved by ELABORATION rather than
by reading instantiation lists - 6 rounds, 71 modules added automatically.

## Bugs 24-26: the same non-conformance, three more times

Tier 5 needed two more patched files, bringing `rtl_patched/` to four.

**Parameter used before declaration** (`mqnic_interface_tx.v`, `_rx.v`):
`DMA_CLIENT_LEN_WIDTH` appears in the PORT LIST at :87 and is declared at :192,
105 lines later in the body. Verilog-2001 requires declaration first. Moved into
the module parameter list - same default, same value, not overridden anywhere in
the tree.

**Zero-width part select, third occurrence** (`mqnic_rx_queue_map.v:259`):
`CL_PORTS = $clog2(PORTS)` is 0 at PORTS = 1, used in a part select guarded by a
RUNTIME `if` rather than a generate. Identical in form to bug 13.

### The pattern, now with four data points
`pcie_tlp_fifo_raw`, `pcie_tlp_fifo`, `mqnic_rx_queue_map`,
`mqnic_interface_tx/rx` - all RTL that Vivado accepts and every
standards-conformant front end rejects, and all in the configuration Corundum
SHIPS (N = 1). This is a Vivado-only codebase meeting a standards checker for
the first time, and it is worth reporting upstream as one issue rather than four.

`rtl_patched/` is four files, one change each, every one with a header stating
the change, the reason and the effect. Everything else under `fpga/` is verbatim.

## What the tiering bought

The environment for the first Tier 5 test is TWO AGENTS - the `pcie_tlp` UVC
built at Tier 1b on a stateless demux, unchanged. On a 2,141-line DUT wrapping
four tiers of verified logic, that is the §5.1 argument paying out in full.

## The register path is not what I expected

`mqnic_core_pcie` has NO AXI-Lite slave for the host. `m_axil_csr_*` is an
OUTPUT - the core's master towards application logic. Host register access
arrives as PCIe BAR REQUESTS and leaves as COMPLETIONS, so it is a SPLIT
TRANSACTION, matched by tag.

Reusing Tier 1a's `axil_seq_lib` here would not have worked at all. I went and
checked rather than assuming, which is the habit bugs 8, 10 and 15 taught.

## Tier 5 tests (6)
`t5_reset`, `t5_rb_walk`, `t5_rb_walk_repeat`, `t5_fw_id`, `t5_csr_outstanding`,
`t5_csr_bad_addr`.

Deliberately register-focused. `uvc/pcie_cfg`, `sb_csr` and `sb_irq` are
deferred rather than dropped: they belong with the interrupt work, and building
them now would mean an environment whose checks nothing yet exercises.

## Status

| Gate | Result |
|---|---|
| slang elaboration, 12 configurations | 0 real errors |
| portability + convention lint | 0 / 0 |
| `check_filelists.py` | 12/12, self-auditing |
| `gen_ral.py --check` | 26 block types |
| `gen_regress_lists.py --check` | 99 tests, 11 tiers |
| exports | 12 tiers; Tier 5 is 177 tabs |
| **simulation** | **Tiers 1-4 partial; Tier 5 NOT RUN** |


---

## EDA Playground tab limit - lossless splitting

Playground rejects any tab over 100,000 characters. Two Corundum files exceed
it: `mqnic_core.v` (216,760) and `mqnic_interface.v` (141,527).

### The approach
The export generator now splits an oversized file at LINE BOUNDARIES into
`<stem>_pN.vh` fragments, and the tab keeping the original name contains
nothing but `include directives in order.

`include is preprocessor CONCATENATION, so what the compiler sees is exactly the
original file. Splitting cannot change behaviour - it is not a rewrite, it is
the same bytes delivered in pieces.

**The real files are untouched.** `sim/filelists/*.f` still point at
`fpga/common/rtl/`, so a batch simulator compiles the originals and never sees a
fragment. The Playground copy remains a build artifact, not a second source.

### Bug 27 - my own verification was wrong first time

The generator checked the split by reading the fragments back and comparing to
the source. It reported "verified identical". An independent byte comparison
said otherwise:

```
mqnic_core.v: original 216,760  rebuilt 221,221  identical=False
```

`read_text`/`write_text` translate line endings. On Windows every LF became
CRLF, so the rebuilt file was 4,461 bytes larger - and the generator's own check
compared AFTER translation, which hides exactly that.

Functionally the CRLF makes no difference to Verilog. That is not the point: a
check that reports "identical" while the bytes differ is worse than no check,
because it converts an unverified claim into a believed one. It is the same
class as bug 22 - a well-formed check measuring something other than what it
claimed.

Now the split reads, writes and compares BYTES, with no text mode anywhere.
Verified independently against the originals: 216,760 -> 3 fragments -> 216,760,
identical; 141,527 -> 2 fragments -> 141,527, identical.

### Result
Tier 5 exports 177 tabs, largest 84,151 characters, none over the limit. All 12
tier exports regenerated; Tier 5 still elaborates from the real files.


---

## EDA Playground total-size limit - and where it genuinely stops

Playground caps the TOTAL across all tabs at 1,000,000 characters. Three exports
were already over and the rest were within 5% of it.

### The real cause was not the RTL
Every export was compiling ALL ELEVEN TIERS' environments and tests - about
900 KB, roughly 90% of the budget, for code the tier never instantiates. A Tier
4a export carried Tier 1a's queue tests, Tier 3's DMA scoreboards and Tier 5's
register walker.

That was always waste; the size cap merely made it visible. Splitting oversized
files (the previous fix) did nothing for it, because the total is the total.

### Fixed by exporting only what the tier uses
A file whose name carries a tier number is tier-specific and is kept only for
its own tier. Anything without one is shared infrastructure - scoreboard base,
models, UVCs, coverage - and is always kept; guessing at those dependencies
would be fragile and they are small.

The packages that `include the dropped fragments have those lines replaced with
a comment saying why, so a reader of the export can see what was removed rather
than wondering what is missing.

| | before | after |
|---|---|---|
| tier1 | 1,073,002 **OVER** | 785,369 |
| tier3c | 1,066,398 **OVER** | 806,878 |
| every other block tier | 917k - 996k | 641k - 806k |

Eleven of twelve now fit, with 20-35% headroom instead of 0-8%. Verified that
every `include in every export resolves to a file the export contains.

### Tier 5 does NOT fit, and cannot be made to

| | |
|---|---|
| RTL | 1,712,970 |
| TB | 644,929 |
| total | 2,357,899 |
| limit | 1,000,000 |

**The RTL alone exceeds the budget by 71%**, across 74 modules every one of
which is reached from `mqnic_core_pcie` by elaboration. There is nothing to
drop: verifying the full core requires the full core.

No amount of testbench trimming closes a 713 KB gap in the design pane. This is
not a packaging problem to solve - it is the point where the web IDE stops being
the right tool.

**Tier 5 requires a batch simulator.** That is the same conclusion the §19 gates
reached from a different direction: E1, E2, E3 and E7 all need one too. The
filelists, the Makefile targets and the regression lists are already correct for
that flow.

Tiers 1 through 4 remain fully runnable on Playground, now with comfortable
margin.


---

## Can Tier 5 run here? Two questions, two answers

### EDA Playground: NO, and it cannot be made to
Total budget 1,000,000 characters. Tier 5 needs 2,357,899 - and **the RTL alone
is 1,712,970**, 71% over the limit by itself, across 74 modules every one of
which is reached from `mqnic_core_pcie` by elaboration. Nothing can be dropped
without verifying a different device.

Per-tier filtering fixed the other eleven exports (all now 641k-807k, 20-35%
headroom). It cannot fix this one, because the problem is in the design pane.

### This machine: RTL yes, UVM no
`iverilog` 12.0 is installed. Nothing else - no VCS, Questa, Xcelium, Vivado.

**Icarus elaborates the ENTIRE Tier 5 design cleanly: 74 files, 0 errors**, a
5.5 MB elaborated image, including all four `rtl_patched/` files. That is a
SECOND INDEPENDENT FRONT END agreeing with slang - two different parsers on the
same 74 modules is worth considerably more than one parser agreeing with itself,
and it is the strongest evidence yet that the patches are sound.

The remaining warnings are port-width pruning and padding at instantiation - a
Corundum idiom throughout the codebase, present in unpatched files as much as
patched ones, and not errors.

**Icarus cannot compile UVM.** Confirmed directly rather than assumed:

```
ext/uvm/src/dpi/uvm_hdl.svh:77: syntax error
```

So the DESIGN is verifiable here and the TESTBENCH is not.

### Added: `make rtl-elab TIER=n`
The Icarus check is now a Makefile target. It costs nothing, runs locally, and
catches RTL-level problems without a licence - a genuinely useful gate below the
UVM one.

### What would unblock Tier 5's testbench
A UVM-capable simulator. In rough order of likely availability:

1. **Vivado XSim** - free with Vivado, supports UVM 1.2 from 2020.2. This is a
   Xilinx design, so Vivado is the most likely thing already to hand.
2. **Questa Intel FPGA Starter Edition** - free, UVM-capable, line-limited.
3. VCS / Questa / Xcelium under licence.

Any of them also unblocks §19 E1, E2, E3 and E7, which need batch runs for the
same reason.


---

# UVM RUNS LOCALLY - pyuvm + cocotb + Icarus

The blocker was stated flatly a few entries ago: Tier 5 cannot run on EDA
Playground (RTL alone is 71% over the 1 MB budget) and this machine has no
UVM-capable simulator. Both were true. Neither is the whole picture.

**cocotb 2.0.1 and pyuvm 4.0.1 were already installed.** pyuvm is IEEE 1800.2 in
Python running on cocotb, and cocotb drives Icarus. So UVM SEMANTICS - phases,
factory, components, sequencers, sequences, objections - are available on this
machine right now, against the real unmodified RTL.

## Proven bottom-up, like everything else

1. `test_smoke_psdpram.py` - pyuvm test, env, sequencer, driver and sequence
   driving `dma_psdpram` (the Tier 2 DUT). **PASS**, 184 ns.
2. `test_tier5_rb_walk.py` - the §8.2 register walk against the FULL
   `mqnic_core_pcie`. Icarus builds all 74 modules; the design **simulates for
   16.1 us** under pyuvm control.

The smallest DUT first, then the largest. Same discipline as the tiering.

## What works, and what does not yet

**Works:** the toolchain, end to end. Icarus compiles the entire Tier 5 design,
cocotb loads it, pyuvm runs real phases against it, and the register-access
agent drives BAR request TLPs onto `pcie_rx_req_tlp_*`.

**Does not yet:** the DUT returns no completion, so the walk discovers zero
blocks. That is a bring-up item, not a toolchain failure - most likely the core
needs enabling or BAR aperture setup before it answers, or the request header or
handshake timing needs work. It is the expected state for the first attempt at a
74-module DUT and it is now DEBUGGABLE, which it was not an hour ago.

## Bug 28 - the first version reported PASS having checked nothing

```
ERROR  no completion for the type read at 0x0 - the BAR path is not responding
INFO   discovered 0 register block(s), 0 register read(s)
** test_tier5_rb_walk.rb_walk     PASS **
```

A pyuvm `logger.error` does not fail a cocotb test. The run found nothing,
said so, and passed.

That is precisely the silent pass every drain check, straddle mandate and
`m_min_comparisons` rule in this project exists to prevent - and I reproduced it
in the first file written under a new framework, because the framework's failure
semantics are not the ones I had internalised.

The verdict is now asserted explicitly: no reads completed, no blocks
discovered, or no FW ID block, all fail. The test now correctly reports FAIL.

**A new tool brings its own silent-pass modes, and they are not the ones you
already know.** That is the lesson worth carrying more than the toolchain itself.

## What this unblocks

| | before | now |
|---|---|---|
| Tier 5 execution | impossible anywhere | runs locally |
| §19 E1 multi-seed | blocked | reachable - cocotb takes a seed |
| §19 E7 nightly | blocked | reachable - it is a Python process |
| RTL second front end | slang only | slang + Icarus, both clean on 74 modules |

The SystemVerilog UVM environment is unchanged and remains the primary
deliverable for a licensed simulator. This is a SECOND EXECUTION PATH for the
machine that has no licence - not a replacement, and the two check each other.


---

## Tier 5 BAR path debugged - the testbench was starving the core

The first pyuvm run of `t5_rb_walk` discovered zero blocks. Bisected in three
probes:

```
after reset: rx_req_ready = 1
request accepted after 0 cycles          <- the core TAKES the request
pcie_ctrl_rx_req_tlp_valid = 1           <- the demux routes it correctly
axil_master.m_axil_arvalid = 0
axil_master.m_axil_arready = 0           <- nothing downstream will accept
m_axil_rvalid = X
completion after -1 cycles               <- never
```

### The cause
`m_axil_csr_*` is the core's own AXI-Lite MASTER towards application logic, so
its handshake and response signals - `awready`, `wready`, `bvalid`, `arready`,
`rvalid`, `rdata` - are INPUTS to the core. The generated port map tied every
unused input to '0', which is the right default for an unused input and the
wrong one here: with `arready` permanently low and `rvalid` never asserted, any
register access routed to the CSR region stalls forever, and the AXI-Lite
crossbar backs up behind it.

The core was not broken and the toolchain was not broken. **The testbench was
holding a bus permanently not-ready and then complaining that nothing came
back.**

### Worth noting about the tie-off policy
`gen_tb_ports.py` ties unused inputs off explicitly precisely so that
"unconnected" is a visible decision rather than an omission - and that is what
made this findable in three probes rather than by staring at a waveform. The
policy was right; this port simply is not unused.

### The fix, and it is real work
Tier 5 needs a minimal AXI-Lite SLAVE on `m_axil_csr_*` - accept a write, accept
a read, return data. That is a small responder, and the `axil` UVC from Tier 1a
already has `MODE_ACTIVE_SLAVE` for exactly this shape. It is the next piece,
in both the SystemVerilog environment and the pyuvm one.

That the SystemVerilog testbench has the same hole is the useful part: **the
pyuvm path found a defect in the SystemVerilog testbench that no available
simulator could have run.** That is the entire argument for building the second
execution path.


---

## Tier 5 BAR path - narrowed further, not yet closed

Adding the `m_axil_csr_*` responder was necessary but not sufficient. The chain
is now traced precisely:

```
rx_req accepted                     cycle 0     OK
pcie_ctrl_rx_req_tlp_valid = 1                  OK - the demux routes it
pcie_axil_master m_axil_arvalid     cycle 0     OK - the read IS issued
pcie_axil_master m_axil_arready     NEVER       <-- the blockage
m_axil_csr_arvalid                  never seen  -- it does not get that far
completion                          NEVER
```

So `pcie_axil_master` converts the TLP correctly and drives an AXI-Lite read.
The AXI-Lite CROSSBAR inside `mqnic_core` never accepts it. The CSR responder
sits idle because the transaction never reaches the far side.

### What this rules out
* the TLP header encoding - the request is accepted and routed
* the TLP demux configuration
* `pcie_axil_master` itself
* the missing CSR responder as the SOLE cause (it was one of at least two)

### The remaining candidate
Other core inputs that my generated port map tied to '0'. `m_axil_csr_*` was one
family; `ctrl_reg_*` is another the core drives outward, and there are further
application and statistics interfaces. Any of them held permanently not-ready
can stall the crossbar that serves the register blocks, with the symptom
appearing three levels upstream.

The tie-off-everything default is right for a first bring-up and wrong for the
handful of ports where the core is the MASTER. Those need enumerating from the
RTL - which direction each family runs - rather than discovering one at a time.

### Next probe
Walk `mqnic_core`'s AXI-Lite crossbar slave ports and find which one is holding
`arready` low. cocotb reaches the hierarchy directly
(`dut.core_inst.axil_crossbar_inst...`), so this is a five-minute question now
that the design simulates - and it was not answerable at all before today.

### Status, stated plainly
UVM runs locally. The full Tier 5 design simulates. The register path is traced
to a specific stalled handshake inside the core. The walk does not yet complete,
and `t5_rb_walk` correctly FAILS rather than reporting a green run that checked
nothing.


---

## Tier 5 BAR path - one stage further, still open

With the `m_axil_csr_*` responder driving its handshake signals:

```
before:  s_axil_ctrl_arvalid=1  s_axil_ctrl_arready=0   <- stalled, never accepted
after:   s_axil_ctrl_arvalid=0  s_axil_ctrl_arready=1   <- ACCEPTED
completion: still never
```

The AXI-Lite read is now taken by the crossbar inside `mqnic_core`. It was
stalled at the address phase before; it is not any more. The read DATA response
never comes back, so the stall has moved one stage downstream - from "the
crossbar will not accept the address" to "no slave returns the data".

### What that means
Two separate blockages, and the first is fixed. The remaining one is a slave
behind `mqnic_core`'s crossbar not completing a read of address 0. Candidates,
in order:

1. Another core input family tied to '0' by the generated port map, on an
   interface where the core is the MASTER. `ctrl_reg_*` is the obvious next one:
   the core drives `ctrl_reg_rd_addr` outward and expects `ctrl_reg_rd_data`,
   `ctrl_reg_rd_wait` and `ctrl_reg_rd_ack` back. With `ack` tied low, a read
   routed there never completes - exactly this symptom.
2. Address 0 decoding to a slave that needs configuration first.

### The generator change this argues for
Discovering these one at a time is the wrong method, and it is the third time
the same shape of problem has appeared. `gen_tb_ports.py` should classify port
FAMILIES by direction - where the core is master, its `*_ready`/`*_ack` inputs
want a responder or a tie to 1, not a tie to 0 - rather than defaulting every
input to zero and leaving each one to be found by simulation.

That is a real improvement to make before the next bring-up, not a workaround.

### Status
Genuine progress: a stall that had never been reached before is now diagnosed
and half-cleared, on a design that could not be executed at all yesterday.
`t5_rb_walk` still FAILS, correctly and loudly.


---

## Generator fix: tie-off by port family

`gen_tb_ports.py` now classifies inputs rather than defaulting all of them to
zero:

```
*_ready, *_ack   -> 1'b1    the peer always accepts / acknowledges
everything else  -> '0      quiescent
```

Rationale, recorded because it cost three rounds of probing twice: defaulting
every input to '0' is right for a genuinely unused input and WRONG wherever the
DUT is the MASTER of an interface. There the inputs are the far side's
handshake, and a permanently-low ready stalls the DUT waiting for a peer the
testbench never provides - three levels away from where the symptom appears.

`tb_top_tier5.sv` regenerated: 15 inputs now tied high. Still elaborates clean
across 101 files. The same policy applied in the pyuvm probe drives 57
ready/ack signals.

### Result: the AXI-Lite address phase is fixed, the data phase is not

```
s_axil_ctrl_arvalid=0  s_axil_ctrl_arready=1     <- address ACCEPTED
s_axil_ctrl_rvalid=0                             <- data never returns
completion: never
```

The read address is consumed. No slave answers it. That is a different problem
from the two already fixed, and it is where this stops for now.

### Honest assessment of the method
Four rounds have gone into this bring-up, each fixing a real defect and each
revealing the next one downstream. The generator change is the valuable
outcome - it is a fix to the CLASS rather than the instance, and it is what
should have been done after the first occurrence rather than the third.

The remaining question is narrow and well-posed: which slave owns address 0 in
`mqnic_core`'s AXI-Lite space, and what does it need before it will answer.
That is a question about the DESIGN's expected initialisation, not about the
testbench plumbing - a different kind of investigation from the last four, and
the right point to stop and choose deliberately rather than continue probing.


---

## The driver answers the initialisation question: there is none

`mqnic_main.c:623` maps BAR 0, and `:255` immediately enumerates the register
block list from offset 0:

```c
mqnic->hw_addr = pci_ioremap_bar(pdev, 0);       // :623
...
mqnic->rb_list = mqnic_enumerate_reg_block_list(mqnic->hw_addr, 0, ...);  // :255
```

Nothing between them touches the device. **A correctly-driven core must answer a
read of BAR0 + 0 with no prior setup.**

That rules out the hypothesis of the last round. The remaining fault is in the
STIMULUS or the testbench, not in a missing initialisation sequence - which is a
different and much better-bounded place to look than "what does this 2,141-line
core need first".

### Where that leaves the bring-up
Established, in order:

| | |
|---|---|
| TLP accepted and routed by the demux | works |
| `pcie_axil_master` issues the AXI-Lite read | works |
| AXI-Lite address phase accepted by the crossbar | works, after the tie-off fix |
| AXI-Lite read data returned | **does not happen** |
| No init sequence is required | confirmed from the driver |

So a read address enters `mqnic_core`'s AXI-Lite space, is accepted, and no
slave answers. With initialisation excluded, the candidates are the ADDRESS the
core actually sees (the TLP-to-AXIL address translation in `pcie_axil_master`,
including how the BAR aperture is stripped) and the crossbar's decode of it.

### Method note
Five rounds. Each found something real, and the last two found progressively
less. The valuable outcomes were the two CLASS fixes - tie-off by port family,
and the assertion that made a silent pass loud - not the individual stalls.

Reading the driver was worth more than any single probe: it eliminated a whole
branch of the search in two greps. That should have come earlier.


---

## Bring-up: the read is absorbed inside the core

Final probe of this session. Neither core master port sees the transaction:

```
core master-port activity: {}     (m_axil_csr_arvalid, ctrl_reg_rd_en: never)
```

So the AXI-Lite read at address 0 is consumed by a slave INSIDE `mqnic_core`,
not routed out to the application interfaces. That is the correct destination -
the FW ID and other register blocks live inside the core - and it means the
remaining fault is an internal decode or an internal slave that never responds.

Also confirmed this round, from `pcie_axil_master.v:443`:

* the address passes through UNMODIFIED (`m_axil_addr_next = rx_req_tlp_hdr_addr`)
  - no BAR aperture stripping, so address 0 in means address 0 out;
* the request IS recognised as a read (`!fmt[1] && type == 5'b00000` matches the
  header being driven).

Both hypotheses from the previous round are therefore eliminated.

### Honest close on this thread
Six rounds. The infrastructure work is done and sound; the bring-up is not
finished. What remains is one question - which internal slave owns address 0 in
`mqnic_core`'s AXI-Lite space and why it does not respond - and answering it
means reading `mqnic_core.v`'s crossbar wiring rather than probing further.

The probing method has now returned less on each of the last three rounds. The
right next step is a structural read of `mqnic_core.v`'s AXI-Lite topology, or
comparing against the cocotb `mqnic_core_pcie` testbench if one exists, which
would show a known-good stimulus directly.

### What is genuinely delivered
* UVM runs locally: pyuvm + cocotb + Icarus, proven on `dma_psdpram` (PASS)
* The full 74-module Tier 5 design simulates
* Two class-level fixes: tie-off by port family, and a silent pass made loud
* Four stages of the register path proven working, one remaining


---

## The structural answer: the control path runs THROUGH the interface

Reading `mqnic_core.v`'s topology answered in minutes what six rounds of probing
had not:

```
axil_crossbar #( .M_COUNT(IF_COUNT), ... ) axil_crossbar_inst      // :1033
axil_crossbar #( .S_COUNT(IF_COUNT), ... ) axil_csr_crossbar_inst  // :1285
axil_reg_if   #( ... )                     axil_reg_if_inst        // :683
                                            fed by axil_csr_*
```

The main control crossbar's masters are the INTERFACES, not the register blocks.
The core's own blocks (FW ID, PHC at 0x100, CLK at 0x200) sit behind
`axil_reg_if_inst`, which is fed from `axil_csr_crossbar_inst`, whose SLAVES are
the interfaces.

So the full path for a BAR register read is:

    pcie_axil_master -> axil_crossbar -> mqnic_interface[0]
                     -> interface CSR master -> axil_csr_crossbar
                     -> axil_reg_if -> register blocks

**Every register access traverses `mqnic_interface`.** The read is absorbed
there and never emerges - which is consistent with every probe: it leaves
pcie_axil_master, is accepted by the crossbar, and reaches neither core master
port because it is sitting inside the interface.

### Why this took six rounds and should not have
Each probe answered "where is it now" and none answered "where is it supposed to
go". The topology was readable from the start; three greps settled it.

The lesson is not about this DUT. Probing tells you where a transaction stopped;
it cannot tell you where it should have gone. On an unfamiliar design, read the
structure first and probe second - the reverse of what I did.

### Next, concretely
`mqnic_interface` is a large block with its own crossbar and its own tie-off
surface. The likely cause is the same class already fixed twice: a handshake
input the generated port map holds low. But it is now a bounded question about
ONE module rather than an open one about 74.


---

# CONSOLIDATION - state of the project

## Delivered and verified

| | |
|---|---|
| Tiers built | 1a 1b 1c, 2, 3a 3b 3c, 4a 4b 4c, 5 |
| Configurations elaborating | **12 / 12, zero real errors** |
| Portability + convention lint | 0 / 0 |
| UVCs | 10, each built at the lowest tier that exercises it |
| Tests | **99 across 11 tiers** |
| Bugs found and fixed | **28** - 24 testbench, 4 RTL |
| Cross-check cases against RTL | ~390,000 |
| Generated inventories | RAL, regression lists, port maps - all with `--check` |
| EDA Playground exports | 12 tiers, 11 within the size budget |
| Second RTL front end | Icarus, clean on all 74 Tier 5 modules |
| UVM executing locally | pyuvm + cocotb + Icarus, PASS on `dma_psdpram` |

## Not delivered, stated plainly

* **No tier meets its §19 gate.** Five of eight criteria (multi-seed, both
  coverage measures, nightly) need a batch simulator. The Makefile targets,
  filelists and regression lists are correct for that flow and have never run.
* **Tier 5 does not pass.** The design simulates; the register walk stops inside
  `mqnic_interface`. Diagnosed, not fixed.
* **Tier 5 cannot run on EDA Playground** - RTL alone is 71% over the size cap.
* **§19 E6** is partially met: static cocotb cross-check found bug 23; a live
  comparison still requires `cocotbext-pcie` and a simulator.

## The four RTL defects found

All the same class - RTL that Vivado accepts and standards-conformant front ends
reject, all in the configuration Corundum SHIPS:

* `pcie_tlp_fifo_raw.v` - `$clog2(1)` zero-width part select
* `pcie_tlp_fifo.v` - passes the zero down as an override
* `mqnic_rx_queue_map.v` - same construct, runtime-guarded
* `mqnic_interface_tx/rx.v` - parameter used in the port list, declared later

`rtl_patched/` holds four files, one line changed each, every one documented.
Worth reporting upstream as a single issue.

## What the tiering bought, measured

The Tier 5 environment for the first register test is TWO AGENTS - the
`pcie_tlp` UVC built at Tier 1b on a stateless demux, unchanged. Tiers 3b, 3c
and 4b elaborated clean on the first attempt because every bug found at 3a and
4a was fixed in shared code.

## The lessons worth keeping

1. **Read the structure before probing it.** Six rounds of bisection did not
   find what three greps of `mqnic_core.v` did. Probing says where a transaction
   stopped; only the design says where it should have gone.
2. **Fix the class, not the instance.** Tie-off by port family, and the
   self-auditing filelist checker, each prevented a category. The instance fixes
   before them each bought one round.
3. **A check that cannot fail is worse than no check.** Bugs 19, 22 and 28 were
   all checks that passed while proving nothing - including one written under a
   new framework whose failure semantics differed from the familiar one.
4. **Verify against bytes, not against your own transformation.** The export
   splitter reported "identical" while the bytes differed.


---

# TIER 5 PASSES

```
test_tier5_csr.rb_walk_checked    PASS     7 blocks, 21 reads, all types known,
                                           all versions match mqnic_hw.h
test_tier5_csr.fw_id              PASS     FPGA_ID=0xdeadbeef BOARD_ID=0x12340000
test_tier5_csr.rb_walk_repeat     PASS     two walks identical field by field
test_tier5_csr.csr_outstanding    PASS     56 reads, every tag matched its request
test_tier5_csr.csr_bad_addr       PASS     unmapped reads complete, none dropped
test_tier5_rb_walk.rb_walk        PASS
```

The discovered map, every value checked against the RTL:

| offset | type | block | version | next |
|--------|------|-------|---------|------|
| 0x000 | 0xffffffff | FW_ID | 0x100 | 0x40 |
| 0x040 | 0x0000c007 | IRQ | 0x100 | 0x50 |
| 0x050 | 0x0000c000 | IF | 0x100 | 0x70 |
| 0x070 | 0x00000000 | App info, **disabled** | - | 0x80 |
| 0x080 | 0x0000c006 | STATS | 0x100 | 0x100 |
| 0x100 | 0x0000c080 | PHC | 0x200 | 0x200 |
| 0x200 | 0x0000c008 | CLK_INFO | 0x100 | 0 |

Type 0 at 0x70 is correct, not a defect: `mqnic_core.v:800` reads
`APP_ENABLE ? 32'h0000C005 : 0`, and APP_ENABLE is 0 in this build.

## The four bugs that were blocking it - all four were MINE

Six earlier rounds of probing had produced a confident diagnosis that the DUT
absorbed the request inside `mqnic_interface`. That diagnosis was wrong.

**Bug 29 - the tie-off sweep drove OUTPUTS.**
```python
for name in dir(dut):
    if name.endswith("ready") or name.endswith("ack"):
        getattr(dut, name).value = 1
```
`dir(dut)` returns all ports. 13 of mqnic_core_pcie's ready/ack ports are
outputs, including `pcie_rx_req_tlp_ready` - the handshake the probe itself
read - and `m_axil_csr_bready`/`rready`, directly on the register path. Forcing
a driven net is contention, and contention is X.

**Bug 30 - every unnamed input was floating.**
The cocotb runner drives mqnic_core_pcie with no port map, so inputs the test
did not mention were X. Two of them are `ctrl_reg_rd_data` and
`ctrl_reg_rd_wait`, and `mqnic_core.v:752-753` ORs them into the register
interface. `X | anything` is X, so one floating 1-bit input made the entire
core register file return X. The generated SystemVerilog top had tied all 250
ports for exactly this reason; the Python path had no equivalent.

**Bug 31 - `always @*` never executed.**
The real one, and worth knowing beyond this project. IEEE 1364 `always @*` is an
event control: it WAITS for a change before its first execution. The AXI library
is full of

```verilog
reg x_reg = 1'b0, x_next;                 // x_next has NO initialiser
always @* x_next = x_reg;
always @(posedge clk) if (rst) x_reg <= 1'b0; else x_reg <= x_next;
```

In a quiescent design nothing ever changes, so the block never runs, `x_next`
stays X, and the instant reset is released `x_reg <= X`. The X is then
self-sustaining because `x_next` is computed from `x_reg`. Reproduced in 25
lines (`scratchpad/atstar/t.v`).

The fix is a **two-pulse reset**: release, re-assert, release. The first release
makes `x_reg` change, which is the event the block was waiting for; the
re-assert drives it back to a known 0 and the now-live block recomputes cleanly.
No RTL change. `always_comb` is guaranteed to run at time zero and would not
need this - `always @*` is not, and this is Verilog-2001.

**Bug 32 - a tie-off that INVENTED responses.**
`*ready` and `*ack` are not one family. `*ready` is flow control and tying it
high is right for an absent peer. `*ack` means "a slave has ANSWERED", and it
travels with a data bus:

```verilog
assign ctrl_reg_rd_ack_int  = ctrl_reg_rd_ack  | ctrl_reg_rd_ack_reg | ...
assign ctrl_reg_rd_data_int = ctrl_reg_rd_data | ctrl_reg_rd_data_reg | ...
```

Tied high, the absent application block answered every register read instantly
with its tied-off data of 0, beating the core's own register file. **The walk
completed, three reads "succeeded", and every value was wrong.** That is worse
than the stall the tie-off was added to prevent, because nothing looks broken.
Fixed in `pyuvm/tieoff.py` AND `sim/scripts/gen_tb_ports.py` AND the two
already-generated lines in `tb/tb_top_tier5.sv`, which had the same defect and
would have failed the same silent way.

**Bug 33** - the completion tag was read at the request's bit position.
`uvc/common/mqnic_vrf_pkg.sv:496` already had it right; re-deriving it in Python
rather than reading the package cost a round.

## The RTL patches I made and then removed

While chasing bug 31 I found `$clog2(1) == 0` zero-width selects in `arbiter`,
`priority_encoder`, `axil_crossbar_rd`, `axil_crossbar_wr` and
`axil_crossbar_addr`, concluded they were the cause, and patched all five into
`rtl_patched/`.

**They were not the cause.** After bugs 29-32 were fixed I re-ran the suite
against the ORIGINAL, UNMODIFIED files: identical pass, 7 blocks, same values.
All five patches are deleted and `rtl_tier5.f` points back at `fpga/`.

Patching a DUT to chase a testbench bug is precisely what this project's rules
exist to prevent, and it nearly shipped. What saved it was running the
experiment both ways instead of trusting that the fix that coincided with
success had caused it. **Four RTL patches remain, all four independently
justified by elaboration failures, none by a simulation result.**

## What actually cost the time

Six rounds of "probe the next signal upstream" produced a wrong answer with
high confidence, because the X sat in a handshake LOOP - an X valid makes an X
ready makes an X valid - and stepping around a loop does not terminate. What
worked was scanning the subtree for X and asking which instance had clean
inputs and a dirty output.

And the diagnosis I recorded with confidence one message earlier - "the read is
absorbed inside mqnic_interface" - was an artifact of a probe that skipped X
values and reported them as "never". A probe that cannot represent the failure
mode will confidently describe the wrong one.


---

# The write path

Everything above came from READS. The write channel has its own crossbar with
the same `always @*` structure that stalled the read side (bug 31), and "the
two-pulse reset covers it too" was an assumption, not a result. Two tests turn
it into one.

The target is the only writable location in the core's control block:

```verilog
mqnic_core.v:748  reg [15:0] irq_rate_limit_min_interval_reg = 10;
mqnic_core.v:766  8'h4C: irq_rate_limit_min_interval_reg <= ctrl_reg_wr_data;
mqnic_core.v:791  8'h4C: ctrl_reg_rd_data_reg <= irq_rate_limit_min_interval_reg;
```

Three independent properties make it a good one:

* it **resets to a non-zero constant**, so the first read proves the path is not
  inventing zeros - the exact failure bug 32 produced;
* it is **16 bits wide**, so a 32-bit write that reads back TRUNCATED proves the
  data reached the real register rather than a cache or the testbench's own
  bookkeeping;
* it is the **only** writable address, so every other location doubles as a
  read-only check.

```
wrote 0x12345678 -> read 0x5678
wrote 0x0000abcd -> read 0xabcd
wrote 0x00000000 -> read 0x0000
wrote 0xffffffff -> read 0xffff        <- truncation is the proof
```

`csr_write_readonly` then writes 0xDEADBEEF to five read-only addresses,
confirms the FW ID constants are unchanged, and re-walks the whole list -
because a wedged write channel shows up as a READ that stops completing.

## A defect this found in the SystemVerilog side

Writing the Python header builder against `mqnic_vrf_pkg.sv:443-470` made it
obvious that `mqnic_csr_write_seq` did not follow the same rule:

```systemverilog
-  h[127:125] = TLP_FMT_4DW_DATA;   // always 4DW, even for a 16-bit address
-  h[71:64]   = 8'hFF;              // last_be = 4'hF on a ONE-DWORD write
-  h[63:2]    = addr[63:2];         // 4DW address placement, unconditionally
```

PCIe requires **last BE == 0** when the length is 1; `8'hFF` is malformed and a
compliant receiver may reject it or infer the wrong length. And a 3DW request
carries `addr[31:2]` at `[63:34]`, not `[63:2]`. The read path had all of this
right because it went through the package helper; the write path open-coded it
and drifted - which is the argument for the helpers, made again.

Fixed to mirror `tlp_hdr_read_req` exactly. Tier 5 SystemVerilog still
elaborates clean.

## State

```
12/12 configurations elaborate, 0 errors
99 SystemVerilog tests, guards all green
pyuvm local suite: 3 targets, 9 tests, ALL PASS
  psdpram                 1 test
  tier5 rb_walk           1 test
  tier5 csr               7 tests  (walk+checks, fw_id, repeat, outstanding,
                                    bad_addr, write, write_readonly)
```


---

# Item 2 - tiers running locally

Before this, 92 of 99 tests only ELABORATED. They ran nowhere: the
SystemVerilog flow needs a UVM simulator this machine does not have, and EDA
Playground takes one tier at a time by hand. "Elaborates" is not "passes".

## What runs now

```
tier 1a-qm  queue_manager        6 tests
tier 1a     cpl_queue_manager    5 tests
tier 1b     pcie_tlp_demux_bar   5 tests
tier 1c     rx_checksum          5 tests
tier 2      dma_psdpram          1 test
tier 5      mqnic_core_pcie      7 tests
                                29 tests, one command: python runner.py all
```

`check_icarus.py` additionally elaborates **13/13** tier DUTs under Icarus - a
second front end agreeing with slang, which is how three of the four RTL defects
in this project were found.

## What each tier actually checks

* **1a queue_manager** - descriptors handed out in order, consumer pointer wraps
  cleanly over three laps of a 4-entry ring, tags echoed across 6 concurrent
  queues, and an unconfigured or disabled queue ANSWERS rather than stalling.
  The last one is the one that matters: the descriptor fetch path blocks on that
  response.
* **1a cpl_queue_manager** - slots in order, `full` asserted at the ring
  boundary and released when the consumer advances, and the ARM/EVENT one-shot:
  an armed queue fires exactly once and disarms. A queue that stayed armed would
  storm the event path; one that never re-armed would stop interrupting the host.
* **1b demux** - BAR 0 to port 0, BAR 2 to port 1, and BARs 1/3/4/5 DROPPED. The
  drop path is the point: a demux that stalled on a stray BAR ID takes the whole
  PCIe ingress down with it.
* **1c rx_checksum** - ~90 frames against the ref_checksum model, including
  all-0xFF data that forces the end-around carry on nearly every word. Random
  data reaches that fold too rarely to fail a broken implementation.
* **5** - the register suite already logged above.

## Two bugs found doing it

**Bug 34 (mine, avoided)** - `check_icarus.py` first reported Tier 1b as missing
`pcie_tlp_fifo`. It is not missing: the tb passes `FIFO_ENABLE(0)`, so that
generate branch is not taken. I had elaborated the DUT with DEFAULT parameters.
A DUT elaborated with its defaults is a DIFFERENT DESIGN from the same DUT as
configured, and I nearly filed the difference as a filelist defect.

**Bug 35 (mine, real)** - the same mistake, but in the test path and it did not
announce itself. `tiers.py` carried only `FIFO_ENABLE` for Tier 1b, so
`BAR_STRIDE` took its default of 1 instead of the tb's 2. The demux matched BAR
0/1 instead of BAR 0/2 and **four tests failed accusing the RTL of misrouting**.

That is the fourth time in this project a second copy of an inventory has
drifted - after the filelist tier table (bug 20), the regression lists, and the
RAL. So it is now checked rather than trusted:

```
python check_tier_params.py --check
37 parameter(s) verified against the SystemVerilog tops, 0 problem(s)
```

It resolves the SystemVerilog tops' localparams and instantiation overrides -
including through `dut_wrapper_queue_manager`, two levels deep - and compares
them with `tiers.py`. Verified to FAIL by flipping BAR_STRIDE back to 1. It
reports a parameter it cannot resolve rather than skipping it, because a check
that quietly stops checking is precisely the failure it exists to prevent.

It immediately found three more: `LOG_QUEUE_SIZE_WIDTH`, `DESC_SIZE` and
`PIPELINE` were absent from `tiers.py` and were coming from the RTL defaults.
Those defaults happen to equal the tb's values today, so nothing was wrong -
which is exactly why it would not have been noticed when one of them changed.

## State

```
12/12 SystemVerilog configurations elaborate, 0 errors
13/13 tier DUTs elaborate under Icarus
 6/6  local tiers pass, 29 tests
 guards: filelists, RAL, regression lists, tier parameters - all green
```

Still elaborate-only locally: **3a, 3b, 3c** (need the ref_dma split model - the
most cross-checked model in the project, 390k cases) and **4a, 4b, 4c** (need the
Xilinx tuser codec). Those are the two substantial models, not thin harnesses,
and porting them is the remaining work for item 2.


---

# Tier 4 complete - pcie_us_if

## What was actually missing

VERIFICATION_STRATEGY.md §5 assigns:

```
Tier 4a  pcie_us_if_{cq,cc,rq,rc}   all four shims
Tier 4b  pcie_us_if                 the integration
```

This environment split the four shims across its OWN tiers 4a (rc + cq), 4b (cc)
and 4c (rq) - and in doing so **took over the label "4b" that the plan had given
to the integration**. "Tier 4b exists" stayed true while meaning something else,
and `pcie_us_if` was never built. It appeared in no filelist at all.

Tier 4a itself turned out to be complete: `pcie_us_if_cq` is instantiated at
tb_top_tier4a.sv:116 with its own tests. Only the wrapper was missing.

Added as **Tier 4d** rather than by renumbering, which would churn three tiers of
filelists, regression lists, port maps and exports for a cosmetic gain.

## What Tier 4d checks that no isolation tier can

**The configuration path.** `pcie_us_cfg` exists ONLY in this wrapper. It polls
PCIe config space over `cfg_mgmt_*` and extracts (pcie_us_cfg.v:121-123):

```verilog
ext_tag_enable        <- cfg_mgmt_read_data[8]
max_read_request_size <- cfg_mgmt_read_data[14:12]
max_payload_size      <- cfg_mgmt_read_data[7:5]
```

MPS and MRRS are the INPUTS to the DMA split rules that Tier 3 verified against
~390k cases. **Tier 3 is handed those limits directly, so it can never see them
being read out of the wrong bits.** If this extraction is wrong, every split in
the design is computed against the wrong limit and every lower tier still
passes. This is the seam between two halves that are each already correct, and
it is the reason the tier exists.

Swept across five (MPS, MRRS, ext_tag) combinations, in SystemVerilog and in
pyuvm. The testbench plays config space; without a responder the DUT polls
forever and `max_payload_size` stays 0, which looks exactly like a DUT that
cannot read its own configuration.

**All four channels concurrently.** The shims share only this wrapper, so
interference between them is invisible to every isolation tier.

## Delivered

```
sim/filelists/rtl_tier4d.f      11 RTL files, elaborates under slang AND Icarus
sim/filelists/tb_tier4d.f
tb/tb_top_tier4d.sv             136 ports, generated port map, ICPSD throughout
env/tier4d_env.sv               7 agents, ALL reused unchanged from earlier tiers
tests/tier4d/tier4d_tests.sv    6 tests
uvc/common/pcie_us_cfg_status_if.sv
pyuvm/test_tier4d_us_if.py      5 tests, PASSING locally
```

Every agent in `tier4d_env` was built at an earlier tier and reused without
modification - §5.1's argument at its last stop before Tier 5.

## Four bugs found doing it, all mine

**Bug 36 - the strategy and the environment had never been compared.**
Every existing guard checks the environment against ITSELF: the filelists agree
with the tests, the tests agree with the regression lists. All of them agreed
about a set that was missing a DUT. `sim/scripts/check_strategy_duts.py` now
parses §5's tier table and checks each named DUT appears in some `rtl_tier*.f`.
It immediately found the two real gaps:

```
UNBUILT: strategy Tier 1b names `pcie_tlp_mux`
UNBUILT: strategy Tier 6 names `mqnic_core_pcie_us`
```

**A package cannot make a hierarchical reference.** The obvious way to check
three status pins is `tb_top_tier4d.max_payload_size` from the test - and that
does not compile, because tests live in a package (IEEE 1800). Correctly so: it
would bind the package to one testbench and make it unreusable at Tier 6. Fixed
with `pcie_us_cfg_status_if`, which carries both the pins AND the config-space
value the TB returns, so stimulus and response cannot drift apart.

**`matches` is a SystemVerilog keyword** (`case ... matches`). Naming an
interface function that produces a parse error several lines from the cause.

**Adding to a shared package breaks every tier that does not carry the new
file.** `test_pkg.sv` includes `tier4d_tests.sv` for ALL tiers, so 12 of 13
configurations stopped elaborating until every tb filelist gained the tier4d
incdir and the new interface. Caught immediately by the 13-configuration sweep -
which is the argument for running all of them rather than the one being worked
on.

**A second copy of an evaluator drifts like a second copy of an inventory.**
`check_tier_params.py` had two expression evaluators; teaching one about the
`?:` ternary left the other behind, and every width localparam in
`tb_top_tier4d.sv` silently stayed unresolved. Now there is one.

## State

```
13/13 SystemVerilog configurations elaborate, 0 errors
13/13 tier DUTs elaborate under Icarus
105 SystemVerilog tests across 12 tiers
 7/7 local tiers pass, 34 tests
 guards: filelists, RAL, regression lists, tier parameters, STRATEGY DUTs
```

Remaining against the strategy: `pcie_tlp_mux` (Tier 1b) and Tier 6
(`mqnic_core_pcie_us`) - both now reported by a guard rather than remembered.


---

# TIER 6 - mqnic_core_pcie_us, THE STRATEGY'S TOP DUT

VERIFICATION_STRATEGY.md is titled after this module and §3.1 marks it
`★ TIER 6 DUT`. It is now built, elaborates on both front ends, and passes.

```
test_tier6_regwalk.t6_reset        PASS   the whole stack comes up idle
test_tier6_regwalk.t6_cfg_sources  PASS   MPS/MRRS from pins, ext_tag from polling
test_tier6_regwalk.t6_rb_walk      PASS   7 blocks, 21 reads THROUGH THE XILINX SHIM
test_tier6_regwalk.t6_seam         PASS   map identical to mqnic_core.v
```

## What is actually new at this tier

Both halves already passed:

```
mqnic_core_pcie_us
  |- pcie_us_if        Tier 4d
  \- mqnic_core_pcie   Tier 5
```

What only exists here is the SEAM. At Tier 5 a register read was driven straight
onto the generic TLP interface. Here the same read must arrive as a XILINX CQ
DESCRIPTOR, cross pcie_us_if_cq, the demux, pcie_axil_master, three AXI-Lite
crossbars, mqnic_interface and axil_reg_if, and return as a CC descriptor built
by pcie_us_if_cc.

Two independently correct halves can still disagree - about byte enables, about
straddling, about where a tag lives - and neither half's own testbench can see
that. `t6_seam` is the first thing in the project that can: it compares the map
read over the Xilinx transport against the one `mqnic_core.v:776-812` defines,
written out rather than re-read, because reading it twice would compare the
transport with itself.

The CHECKS are Tier 5's, unchanged. Only the transport underneath differs, so a
failure here is a statement about the joint and nothing else.

## A real finding: the config values are not wired the way Tier 4d suggests

Tier 4d proved `pcie_us_cfg` polls config space and extracts MPS, MRRS and
ext_tag correctly. At Tier 6 two of those three are **thrown away**:

```verilog
mqnic_core_pcie_us.v:861-862   pcie_us_if .max_read_request_size()   // DISCARDED
                               pcie_us_if .max_payload_size()        // DISCARDED
mqnic_core_pcie_us.v:1159-60   core takes cfg_max_read_req / cfg_max_payload
mqnic_core_pcie_us.v:283-284   which are INPUT PINS from the hard IP
```

Only `ext_tag_enable` survives the trip (:860 -> :1157). So the extraction path
Tier 4d verified is **not the one this configuration uses** for MPS and MRRS -
those come from dedicated pins instead.

That is worth stating because a Tier 6 test written on the Tier 4d assumption
would have passed *for the wrong reason*: it would have been checking pins it
happened to be driving itself. `t6_cfg_sources` checks both paths for what they
actually are - the pins for MPS/MRRS, the polling for ext_tag.

## Delivered

```
sim/filelists/rtl_tier6.f    83 RTL files - the union of Tier 5 and Tier 4d
sim/filelists/tb_tier6.f
tb/tb_top_tier6.sv           252 ports, generated, NO parameter overrides
env/tier6_env.sv             4 agents, every one reused unchanged from Tier 4a
tests/tier6/tier6_tests.sv   4 tests
pyuvm/test_tier6_regwalk.py  4 tests, PASSING locally
```

`tier6_env` is §5.1's argument at its terminus: four `pcie_us_axis_agent`
instances built at Tier 4a, reused without a line of change, against a DUT two
integration levels above the one they were written for. The `pcie_tlp` agent
that every tier from 1b to 5 used is ABSENT - not a regression, but the
interface disappearing inside the DUT, which is what integrating the shim means.

## State

```
14/14 SystemVerilog configurations elaborate, 0 errors, 0 lint findings
15/15 tier DUTs elaborate under Icarus
109 SystemVerilog tests across 13 tiers
 8/8 local tiers pass, 38 tests
 guards: filelists, RAL, regression lists, tier parameters, strategy DUTs
21 of 22 strategy DUTs built
```

## What remains against the strategy

* **`pcie_tlp_mux`** (Tier 1b) - the one DUT still unbuilt, and reported by
  `check_strategy_duts.py` rather than remembered.
* **G5 (end-to-end datapath) and G7 (MSI-X)** - §5 lists `eth_{rx,tx}_agent`,
  `ptp_agent` and `stats_agent` as new at Tier 6. They are NOT built. The
  register tests need none of them, and building four agents to leave them
  unused would be ceremony. The Ethernet, PTP and scheduler ports are tied off
  and those two objectives remain open - stated plainly rather than implied by
  an empty agent.
* **Tier 7** - coverage closure, parameter sweeps, §21 signoff. Needs a batch
  simulator for the coverage measures.


---

# EDA Playground: Tier 6 cannot run there, and now says so

## The answer

**No, Tier 6 is not implemented on EDA Playground, and it cannot be.**

| tier | export size | vs 1,000,000 budget |
|---|---|---|
| 4d | 864,732 | 86% - runnable |
| **5** | **2,345,270** | **235% - impossible** |
| **6** | **2,566,041** | **257% - impossible** |

Tier 6's DESIGN pane alone is 1,928,478 characters, 193% of the budget for the
whole submission, before a line of testbench. And it cannot be reduced:

```
mqnic_core.v        216,760 chars   twice the 100,000 PER-TAB cap
mqnic_interface.v   141,527 chars
```

A module has to live in one file, so no splitting fixes either. That limit is
exactly why the local Icarus path exists.

## Three real defects found answering the question

**The tier-detection regex had gone stale.** `^(tier\d[a-c]?)_` was written when
4c was the deepest suffix. When Tier 4d arrived, `tier4d_env.sv` and
`tier4d_tests.sv` stopped matching and silently reclassified as SHARED - so
every export began carrying a tier it never instantiates, on exports already at
70-86% of budget. Widened to `[a-z]?`.

**Nothing checked the total budget.** The script happily produced a
complete-looking export at 257% of the cap. The only way to discover that was to
paste ~90 tabs into a browser and get a validation error. It now measures the
export and exits non-zero.

**An unusable export still shipped instructions for using it.** Printing a
warning to a console nobody reads again is not telling anyone. The over-budget
path now prepends a banner to EDA_PLAYGROUND_RUN.md itself - the file someone
actually opens - saying it cannot run and pointing at `pyuvm/runner.py`.

## Also fixed

All fourteen exports regenerated and verified in sync with their sources. Tier 5's
had been stale by 46 lines since the bug-32 `ctrl_reg_*_ack` fix: it would have
pasted a testbench that ties the application register block's acknowledge HIGH,
so every register read returns 0 and the walk "succeeds" with every value wrong.

Tiers 4d and 6 had no export at all; both now have one, with Tier 6's marked
NOT RUNNABLE.

## Where each tier runs

```
1, 1a, 1b, 1c, 2, 3, 3b, 3c, 4a, 4b, 4c, 4d    EDA Playground (63-86% of budget)
5, 6                                            LOCAL ONLY - python pyuvm/runner.py N
```

Both of the local-only tiers pass there.


---

# Full-tier audit - findings

A systematic review of all 14 tiers against VERIFICATION_STRATEGY.md. No code
changed; this records what is missing or wrong.

## A. Tiers 5 and 6 are far thinner than §5 specifies  [HIGHEST IMPACT]

Agents actually instantiated per environment:

```
tier1a   axil_agent queue_op_agent          tier4a   pcie_tlp pcie_us_axis
tier1b   pcie_tlp_agent                     tier4b   pcie_tlp pcie_us_axis
tier1c   axis_agent csum_cmd_agent          tier4c   pcie_tlp pcie_us_axis
tier2    axis dma_desc dma_ram              tier4d   pcie_tlp pcie_us_axis
tier3    dma_desc dma_ram pcie_tlp          tier5    pcie_tlp_agent      <-- ONE
tier3b   dma_desc dma_ram pcie_tlp          tier6    pcie_us_axis_agent  <-- ONE
tier3c   dma_desc dma_ram pcie_tlp
```

§5 says Tier 5 reuses **all** of axil, pcie_tlp, axis, dma_ram, dma_desc plus a
new pcie_cfg_agent, RAL and driver sequence library. It has one agent.

**Neither Tier 5 nor Tier 6 has a scoreboard.** Every tier from 1a to 4d does.
They rely entirely on in-test value checks against mqnic_hw.h - which is a real
check, and for registers arguably a stronger one, but it means no
transaction-level comparison and no end-of-test drain check at the two highest
tiers.

Consequence: at the top two tiers only the PCIe BAR register path is exercised.
The DMA interfaces, the AXI-Stream datapath and MSI-X are tied off. That is why
G5 and G7 are untouched - not an oversight in the tests, but a missing
environment.

## B. The §5.1 UVC reuse matrix is not met

| UVC | plan | actual |
|---|---|---|
| `axil_agent` | 1a -> 3, 5, 6 | **1a only** |
| `axis_agent` | 1c -> 2, 5, 6 | 1c, 2 - missing 5, 6 |
| `dma_ram_agent` | 2 -> 3, 5 | 2, 3, 3b, 3c - **missing 5** |
| `dma_desc_agent` | 3a -> 5 | 2, 3, 3b, 3c - **missing 5** (and built at 2, not 3a) |
| `pcie_tlp_agent` | 1b -> 3, 4, 5 | 1b, 3, 3b, 3c, 4a-4d, 5 - exceeds plan |
| `pcie_us_axis_agent` | 4a -> 6 | 4a-4d, 6 - exceeds plan |
| `pcie_cfg_agent` | new at 5, reused at 6 | **NEVER BUILT** |

§7.7 specifies `pcie_cfg_agent` and it does not exist. G9 ("every UVC used at
>= 2 tiers") is met for 5 of 7 UVCs; `axil_agent` is used at one tier and
`pcie_cfg_agent` at none.

`check_strategy_duts.py` does not catch this - it compares DUTs, not UVCs.

## C. Two Tier 4a tests disable the "did we check anything" guard

```
t4a_rc_basic  :188   m_rc_sb.m_enable_end_check = 0   <- drives RC
t4a_rc_status :323   m_rc_sb.m_enable_end_check = 0   <- drives RC
```

Every other disable in the suite targets the channel the test does NOT drive,
which is correct. These two disable the channel they DO drive.

The stated reason does not hold. `t4a_rc_basic`'s comment says it is avoiding a
straddle-coverage failure, but `sb_shim.sv:71` has `require_straddle = 1'b0` by
default and only `t4a_rc_straddle` turns it on. The check was never going to
fire.

What is actually lost: `m_enable_end_check` gates THREE separate things in
`mqnic_scoreboard_base.check_phase` - the pending-item drain, the
`m_min_comparisons` guard, and (in sb_shim) the straddle requirement. Suppressing
one suppresses all three.

Severity is moderate, not high: `wait_drained()` still fails if expected items
never match, so a DUT that converted nothing is caught. What is lost is the
guard against a scoreboard that was never exercised at all - whose own error
message reads "the scoreboard was connected but never exercised". That is the
exact class of bug 19, 22 and 28.

The correct fix is one line per test - set `require_straddle = 1'b0` explicitly
(or nothing, since it is the default) instead of disabling the end check. The
deeper fix is to split the flag so relaxing one check cannot silently relax
three.

## D. G2's rules are verified, but not as SVA

G2 asks for "0 SVA failures; 4 KB / MPS / RCB / tag rules". `pcie_tlp_if` has
seven assertions and they are all FRAMING - sop/eop/valid/data stability. The
4 KB boundary, MPS, RCB and tag rules are checked in `ref_dma.sv` and the
scoreboards instead, against ~390k cross-checked cases.

That is a legitimate and arguably stronger way to check them - a model computes
the exact expected split rather than asserting a property about it - but it is
not the form the strategy specifies, and G2 should be restated or SVA added.

Module-level SVA exists for 3 of 14 DUTs: `queue_manager`, `dma_if_pcie`,
`dma_if_pcie_wr`. Nothing for the routing blocks, the offloads, `dma_psdpram`,
any `pcie_us_if_*`, `mqnic_core_pcie` or `mqnic_core_pcie_us`.

## E. Functional coverage is thin

Two covergroups exist: `cg_dma` (2 envs) and `cg_straddle` (3 envs). Tiers 1a,
1b, 1c, 5 and 6 instantiate no coverage at all. G8 asks for >= 98% functional
coverage; there is not enough defined to measure against.

## F. Still open from earlier

`pcie_tlp_mux` (Tier 1b) unbuilt - already reported by `check_strategy_duts.py`.

## What the audit found to be sound

* All 14 filelists are complete - both slang and Icarus resolve every module.
* Every tier from 1a to 4d has a scoreboard with a drain check and a
  minimum-comparison guard.
* The interface protocol assertions (59 across 8 interfaces) are carried by
  every tb filelist and are live wherever the interface is instantiated.
* Tier parameters match the SystemVerilog tops exactly (63 verified).
* The reset tests that disable end checks all do so legitimately - they perform
  no transactions by design, which is the documented §11 exception.

---

# Vivado xsim - the SystemVerilog environment runs locally

Vivado 2026.1 is installed (`D:\AMDDesignTools\2026.1\Vivado`, not on PATH). xsim
with its bundled UVM 1.2 is the first UVM-capable simulator this host has had.
`sim/scripts/xsim_run.py <tier> [tests]` compiles and runs a tier; logs go to
`results/xsim/tier<N>/`.

## First results (seed 1)

```
tier1a   11/12   t1a_op_table_full hits the 10 ms watchdog after filling 32 ops - OPEN
tier6     3/4    t6_seam: blocks at 0x100/0x200 read 0 - xsim port-width semantics, OPEN
```

Tier 6's SystemVerilog tests had never executed before this. Neither had
t1a_cpl_enqueue_basic / t1a_cpl_event.

## xsim limitations worked around (environment, not DUT)

1. **`default disable iff` is not simulatable** (XSIM 43-3980). Written out as an
   explicit `disable iff (rst)` on all 88 affected assertions in 8 UVC interfaces
   and 3 SVA modules - identical meaning (IEEE 1800-2017 16.15). The 4 liveness
   properties already carried their own `disable iff` and are unchanged.
2. **`inside` on `size()` with variable bounds** (XSIM 43-3980) in
   `axis_random_seq` - rewritten as two comparisons.
3. **Interface subprograms are only generated for instantiated interfaces.** Every
   tier compiles the whole class library, which calls e.g.
   `vif.init_idle_initiator()`; xelab then fails to link (XSIM 43-3238, undefined
   `subprog_m_*`). `sim/xsim/xsim_vif_anchor.sv` instantiates one idle copy of each
   interface and is elaborated as a second top. No tier top changed.
4. **A cast inside a `while` condition is mis-evaluated.** Isolated with probes:
   `while (c < int'(n))` runs 0 times; the same condition in a `for`, or without
   the cast, is correct. `ref_queue.clog2_int(16)` returned 0, so every predicted
   dequeue address lost its descriptor shift - 9 of 12 Tier 1a tests "failed".
   Replaced with `$clog2`. It was the only cast-in-while in the tree.
5. `xsim.bat` splits arguments on `=` (plusargs go through a `-f` file), and a
   freshly linked `xsimk.exe` is intermittently unlaunchable ("child exe not
   found") - the runner retries.

## The patched FIFO is WRONG on xsim - shipped RTL used instead

`pcie_us_if_cc` declares `wire [SEG_SEL_WIDTH-1:0] fifo_seg_offset` with
SEG_SEL_WIDTH = $clog2(1) = 0, i.e. `[-1:0]`. The rtl_patched FIFO widens its
`out_seg_offset` to 1 bit; on xsim the connection leaves the net at Z,
`fifo_tlp_valid[X]` is never true, and every completion is swallowed - the BAR
read reaches the register file, returns data, and never leaves CC. Traced
signal by signal. xsim accepts the SHIPPED `pcie_tlp_fifo{,_raw}.v`, so
`xsim_run.py` compiles those (and the shipped `mqnic_rx_queue_map.v`) from fpga/.
`mqnic_interface_{rx,tx}.v` stay patched: xsim rejects the shipped files too
(VRFC 10-3380). `--patched-rtl` restores the filelist exactly.

## Testbench bugs found by running (never simulated before)

* **Bug 37 - Tier 6 built CQ requests with the RQ encoder.** `csr_read` used
  `ref_tlp_shim.rq_encode()` on a 3DW header; the RQ shim copies `hdr[63:2]`
  (`pcie_us_if_rq.v:655`), so a read of 0x8 went out as 0x8_0000_0000. Every read
  hit address 0 and returned the FW ID type 0xFFFFFFFF. Added
  `ref_tlp_shim.cq_encode()`, the inverse of `cq_parse`. **Tier 4a and 4d tests
  use the same `rq_encode` for CQ stimulus** - not changed; review them.
* **Bug 38 - t6_rb_walk passed on garbage.** Before bug 37 was fixed it walked
  64 "blocks" of 0xFFFFFFFF and PASSED, because that value equals the FW ID type
  it anchors on. It needs a guard (e.g. next pointer must advance / stay in the
  BAR) - not added yet.
* **Bug 39 - enqueue flavour predicted `cpl`.** `cpl_queue_manager` has no
  resp_cpl port and `queue_op_monitor` records 0; `ref_queue` predicted
  cpl_queue. Now 0 for REF_Q_ENQUEUE.
* **Tiers 5/6 now use the two-pulse reset** (`mqnic_reset_if.pulse_reset_x_safe`,
  opt-in via `m_x_safe_reset`), matching the pyuvm flow's bug-31 fix. Other
  tiers keep the single pulse they were proven with.

## RESOLVED (see below): xsim leaves narrow-to-wide input bits at Z

`mqnic_core.v:850` connects the 16-bit `ctrl_reg_rd_addr` to `mqnic_ptp`'s
`reg_rd_addr`, whose width is `AXIL_CTRL_ADDR_WIDTH` (24, :831). xsim drives the
8 extra bits Z (it warns VRFC 10-3091); Icarus zero-extends, as synthesis does.
With Z in the address the PHC (0x100) and clock-info (0x200) blocks never
decode, so t6_seam sees type 0 there. The testbench is right; passing this on
xsim needs a one-line rtl_patched change (zero-extend at the connection) or
acceptance as a known xsim limitation.


---

# xsim - every tier run to completion

The patch above was approved and added; then every tier was run on xsim and each
failure traced to its cause. Final regression, seed 1:

```
tier  1a 12/12   1b  5/5   1c  6/6    2 10/10
tier   3 18/19   3b 10/10  3c  6/6
tier  4a 10/10   4b  7/7   4c  8/8   4d  6/6
tier   5  6/6     6  4/4   (unified Tier 1 top: 10/10)
                                         108 / 109
```

The one failure, t3_cpl_timeout, is a DUT finding (below), not a testbench bug.
Also re-checked after all changes: 14/14 configurations elaborate under slang
with 0 errors / 0 warnings / 0 lint findings, 15/15 DUTs elaborate under Icarus,
the pyuvm flow passes 8/8 tiers, and every generator's --check is clean.

## RTL patch 5 - rtl_patched/mqnic_core.v

The 16-bit `ctrl_reg_{rd,wr}_addr` into the 24-bit PTP and clock-info ports is
now zero-extended explicitly at all four connections (:844, :850, :900, :906).
That is what IEEE 1800 already specifies, so conformant tools and hardware are
unchanged. rtl_tier5.f and rtl_tier6.f point at the patched copy. t6_seam passes.

## RTL FINDING - a completion timeout hangs the DMA read engine

t3_cpl_timeout fails deterministically, and the testbench is faithful to the
shipped RTL:

* `pcie_us_if_rc.v:347-350` turns a completion descriptor with a dword count of
  0 - which is what a completion-timeout report carries - into a NO-DATA 3DW
  header with SC status, and sets PCIE_ERROR_TIMEOUT on the error sideband (:387).
* `dma_if_pcie_rd.v:1069` checks "SC status but no data" FIRST and drops such a
  completion as unexpected (status_error_cor only).
* So the DMA_ERROR_TIMEOUT branch at :1117 is unreachable for it; the tag never
  retires and the descriptor never gets a status. The engine hangs instead of
  reporting the timeout.

Worth reporting upstream with the patch-set issue. The model was deliberately
NOT bent to make the test pass. t3_cpl_timeout runs to the watchdog; run it with
`--plusarg MQNIC_TIMEOUT_NS=1000000` to record it quickly.

## Testbench bugs found by running (40-49)

* **40 - queue_op driver deadlocked on a full op table.** One serial loop drove
  requests and commits; a request blocked on req_ready held the commit that would
  free it. Request and commit now have independent servers, items carry a
  `driven` flag, and every queue_op sequence waits on it. t1a_op_table_full:
  40 req / 40 resp / 40 commits, 0 mismatches.
* **41 - t6_rb_walk guards** added: terminates on next=0, never revisits an
  address, exactly one FW ID and it is at 0x0.
* **42 - Tier 4a/4d CQ stimulus used rq_encode** - both now use cq_encode (4d
  was wrong for every 3DW header; 4a only built 4DW headers, so was unaffected).
* **43 - sb_dma_client checked sink RAM writes before they were predicted.** The
  sink writes each beat as it lands; the packet is published at tlast. Early
  writes are now held and checked once predicted, and count as pending.
* **44 - t2_random_stress read before its writes were issued** (fixed idle(120)
  instead of wait_ram_drained - the Tier 2 lesson, one place it was missed).
* **45 - t4d_cq_to_rx_req / t4d_tx_cpl_to_cc** did not disable the end checks of
  channels they never drive.
* **46 - t4d_concurrent checked a configuration it never waited for.** It now
  establishes and waits for the Device Control extraction before the traffic.
* **47 - Tier 5 walker stopped at address 0**, which is where the list STARTS
  (FW ID at BAR offset 0). It read nothing, so t5_rb_walk, t5_fw_id and
  t5_csr_outstanding all failed. It now always reads the head. Type 0 with
  version 0 is accepted as a disabled block (mqnic_core.v:800-801, App info).
* **48 - sb_offload paired results strictly after their stimulus.** rx_hash needs
  only the headers and emits mid-packet; the stim monitor publishes at tlast.
  Early results are held and paired positionally.
* **49 - ref_checksum applied csum_init unconditionally.** tx_checksum ignores it
  unless USE_INIT_VALUE=1, and both tb_top_tier1c and mqnic_egress use 0. The
  model now has `use_init_value` (default 0). This run also confirmed the old
  "odd csum_start needs no swap" derivation: starts 12..22 all match.

## More xsim limitations

* `{a, b}[3:0]` (select on a concatenation) is rejected - tb_top_tier1c:149.
* Portability lint rules 5-7 now flag `default disable iff`, a cast inside a
  `while` condition, and a select on a concatenation.
* UNEXPLAINED: in t4d_concurrent, `pcie_us_cfg_status_if.is_extracted()` returned
  0 while the same three `===` comparisons made inline returned 1 at the same
  instant. Three isolated probes did not reproduce it. Tier 4d now compares in
  the test class (`cfg_is`). If an interface function misbehaves on xsim again,
  suspect this first.


---

# pcie_tlp_mux built; 5-seed regression with functional coverage

## pcie_tlp_mux (Tier 1b) - the last unbuilt strategy DUT

Instantiated in tb_top_tier1b exactly as mqnic_core_pcie.v:778-785 uses it
(2 ports, round-robin, LSB priority), with `pause` driven rather than tied.
`check_strategy_duts.py`: **22 of 22 strategy DUTs built.**

* sb_tlp gained a MERGE mode: every output TLP must equal the next TLP of
  exactly one input (header, payload, bar/func/error/seq), so loss, duplication,
  corruption and per-port reordering all fail; a fairness bound flags one port
  winning repeatedly while the other waits.
* SVA in the top: a paused port is never selected, checked on the DUT's own
  `sel_tlp_seq_valid` (pcie_tlp_mux.v:244, :282, :327).
* 4 tests: t1b_mux_basic, t1b_mux_arbitration, t1b_mux_pause,
  t1b_mux_random_stress. Round-robin measured: longest same-port run while the
  other port waited = 1 (220 TLPs, 110 per port).
* The mux does NOT gate sop/eop with valid (:349-350), so its output interface
  sets sop_eop_gated = 0.

## Audit item C closed

t4a_rc_basic and t4a_rc_status no longer disable the RC scoreboard's end check
(the straddle requirement it dodged is off by default). Both pass, 8 and 4
comparisons.

## 5-seed regression (seeds 1-5, Vivado xsim 2026.1, normal builds)

```
tier  tests  runs     functional coverage (merged over all runs)
1a     12    60/60    79.8%   cg_response 72.7  cg_commit 86.7  cg_doorbell 80.0
1b      9    45/45      -
1c      6    30/30      -
2      10    50/50      -
3      19    90/95    74.4%   cg_descriptor 82.1  cg_status 66.7
3b     10    50/50      -
3c      6    30/30    33.9%   cg_descriptor 51.2  cg_status 16.7
4a     10    50/50    70.7%   cg_straddle 70.7
4b      7    35/35    52.4%   cg_straddle 52.4
4c      8    40/40      -
4d      6    30/30    71.4%   cg_straddle 71.4
5       6    30/30      -
6       4    20/20      -
TOTAL 113   570/575
```

The 5 failures are t3_cpl_timeout on every seed, all with the identical
signature (one descriptor never gets a status) - the RTL completion-timeout
finding above, not a flaky test. Every other test passes on all 5 seeds.

"-" means the tier instantiates no covergroup: functional coverage exists only
in Tiers 1a, 3, 3c and the 4a/4b/4d straddle model (audit item E). Nothing is
at the strategy's 98% goal; the covergroups that exist are 17-87%.

## xsim regression-tooling defects found and fixed

* `--cov_db_dir` with an absolute Windows path is pasted into xelab's
  generated C, where the backslashes become escapes (`\u`, `\x`) and the C
  compile fails (XSIM 43-3409). Paths are now relative to the work dir.
* xcrg given only a directory reported "No Functional Coverage Databases have
  been found". The runner now lists every database with `-file`.
* The exit-time coverage write lost 7 of 24 databases under parallel runs; it is
  now an explicit `write_xsim_coverage` in a tclbatch after `$finish`.
* An uncaught Tcl error in that write dropped xsim to its interactive prompt,
  where it waited on stdin for ~2 h (t3_reset s4, after its test had passed).
  The write is now in `catch`, retried 5x, and every run has a 90-min wall
  timeout that kills the whole xsim process tree.
* The first run of a tier sometimes could not create cov/xsim.covdb/<name>
  ("Unable to create output directory"); the parent is now created up front.
* `--cc_type sbct` (code coverage) MIS-SIMULATED t2_seg_independent_backpressure
  on every seed (a null handle at time 0 that the normal build never hits), and
  parallel instrumented runs lost databases. Code coverage is therefore a
  separate `--code-coverage` build in tier<N>_cc/, run with --jobs 1, and its
  verdicts are never used.


## Code coverage (instrumented builds, seeds 1-2, DUT files only)

```
tier  statement  branch  condition  toggle   DUT files
1a     87.3%     61.7%    70.0%      3.6%    2
1b     90.2%     73.4%    70.8%     41.6%    3
1c     83.3%     72.1%    73.1%     41.0%    4
2      90.2%     79.2%    78.1%     10.7%    4
3      95.2%     84.9%    79.0%     53.7%    1
3b     95.4%     84.6%    78.6%     55.2%    1
3c     90.1%     74.1%    71.7%     50.1%    3
4a     87.5%     49.9%    50.8%     22.2%    4
4b     62.0%     44.1%    47.5%     65.3%    2
4c     59.8%     38.3%    44.8%     11.4%    2
4d     91.7%     41.4%    42.8%      5.6%    8
```

Summed over the DUT's own files (fpga/ and rtl_patched/); testbench and UVM
excluded. Tiers 5/6 are not instrumented (STRATEGY R6). Tier 2 lacks
t2_seg_independent_backpressure, which the instrumented build mis-simulates.

Reading it:
* Statements are mostly 83-95%; branches and conditions are the real gaps,
  worst in the Xilinx shims (4a-4d at 38-51% branch): mostly the multi-segment
  / straddle paths of configurations these tiers do not instantiate.
* TOGGLE is dominated by wide RAMs and data buses. 1a's 3.6% is
  cpl_queue_manager: 69,720 bits of queue RAM against 4,622 in queue_manager.
  Toggle needs exclusions for storage arrays before it means anything.
* No metric is at the 98% signoff goal. The next step is per-file review of the
  uncovered branches (text reports in results/xsim/tier<N>_cc/cov_report/).


---

# 20-seed regression (seeds 1-20)

Seeds 6-20 added for every test except t3_cpl_dropped (~25 min per seed) and
t3_cpl_timeout (known RTL failure); both have seeds 1-5 only.

```
tier  tests  seeds  runs
1a     12     20    240/240
1b      9     20    180/180
1c      6     20    120/120
2      10     20    200/200
3      19     20    345/350   (t3_cpl_dropped: 5 seeds; t3_cpl_timeout: 0/5)
3b     10     20    200/200
3c      6     20    120/120
4a     10     20    200/200
4b      7     20    140/140
4c      8     20    160/160
4d      6     20    120/120
5       6     20    120/120
6       4     20     80/80
TOTAL               2235/2240
```

Every failure is t3_cpl_timeout (the RTL completion-timeout hang). No other test
failed on any of 20 seeds.

**Functional coverage did not move from 5 to 20 seeds** - every covergroup reads
exactly as it did at 5. The random stimulus has saturated what it can reach; the
remaining bins need directed stimulus or new tests, not more seeds.

> CORRECTION (coverage closure, below): this was partly a tooling artefact.
> xcrg APPENDS to an existing report directory and the summary parsed the first
> (stale) report in the file, and covergroup instances were auto-named
> differently per run so merged databases did not line up. With the report
> directory cleared and stable instance names, 20 seeds DO add a little over 5.
> The conclusion stands - the holes needed directed tests - but the "exactly as
> it did" evidence was wrong.

## Infrastructure failures during the run, none a test result

* xsim wedged after "Unable to create output directory" on the coverage write
  (t1a_reset s6, t3_reset s9) - even into a per-run directory, so the conflict is
  inside xsim; it strikes when two very short runs finish in the same second.
  The runner now detects the failed write in the log, kills, and reruns.
* Simulations stalled at time 0 (t4b_random_stress s16/s17,
  t4d_random_stress s12/s13); the 90-min wall timeout cost ~10 h overnight.
  The runner now kills a run whose log has not passed time 0 in 5 minutes.
* xelab died with no ERROR line during "Compiling package uvm.uvm_pkg" (Tier 4b
  earlier, Tier 5 here) with ~0.5 GB RAM free on the shared host. The runner now
  retries an elaboration that dies without an error. Tier 5 then ran 90/90.
* Every affected run passed when rerun with the same seed.


---

# Functional coverage closure

Covergroups were added to every tier that had none (1b, 1c, 2, 3b, 4c, 5, 6),
the straddle model was split per channel, and each tier's remaining holes were
either closed with a directed `t<tier>_cov_closure` test or proven unreachable
and excluded with a comment saying why. Per-bin holes: `sim/scripts/cov_holes.py`.

## Coverage tooling defects (fixed)

* xcrg appends to an existing report; the summary read the stale first report.
  The runner now deletes the report directory first.
* Covergroup instances were auto-named per run (`cg_dma_descriptor_5`), so a
  model change left old and new instances side by side in a merge. Every
  covergroup now calls `set_inst_name` with its component path, and each run's
  database directory is deleted before the run.
* xcrg prints the SAME bin table under every cross of a covergroup
  (`x_outcome_queue` three times in Tier 1a); cross holes have to be read from
  the summary counts, not the per-cross tables.

## Testbench defects found by closing coverage

Each of these let a test pass while checking less than it claimed:

* **pcie_tlp_mux tests never sent payload** - `send_mux` built zero-length
  TLPs, so the mux's data path was unexercised. Lengths are now explicit.
* **Immediate-data DMA writes were never checked** - t3b_immediate disabled the
  payload check. sb_dma_wr now compares the payload against the descriptor's
  immediate field.
* **t5_csr_outstanding was never concurrent** - its reads were issued one at a
  time. Now fork/join_none rounds with `wait fork`.
* **Straddle coverage measured the wrong thing** - the us_axis monitor set
  `straddled` but never `start_lane`, so every TLP was sampled at slot 0 and the
  "straddled at slot 0" bins were reported as hit for TLPs that actually began
  in slot 1. The end lane also ignored the start offset. Both fixed; the cross
  now excludes the combinations the monitor's definition makes impossible.
* **cov_queue misclassified commit order** - it advanced its expected-retire tag
  by one per in-order commit, but the DUT retires a whole run of committed tags
  at once (queue_manager.v:394), so after any out-of-order run every later
  in-order commit was counted as out of order. Now models retirement.

## Stimulus that was illegal, not a DUT bug

* DMA client RAM addresses must be 16-byte aligned (SEG_DATA_WIDTH/8): the RTL
  masks the low bits. Unaligned bins are `illegal_bins`.
* Runt (<14 byte) IPv4 frames make rx_hash hash stale bytes - outside its
  contract; closure uses short non-IP frames instead.

## Unreachable by construction (excluded, with reason in the covergroup)

* 4 KB crossing: a 1-byte transfer never crosses; >4096 bytes always does.
* Immediate writes are at most 4 bytes (IMM_WIDTH = 32).
* CSR: the DUT never returns Completer Abort; UR comes only from the request
  type (I/O), so status is not crossed with block.
* Straddle: only RC straddles at 256 bits; CQ/RQ/CC bins are plain.

## Holes left open, deliberately

* cg_dma status `timeout` / `flr` (Tier 3): reaching them needs the completion
  timeout path, which hangs the read engine - the open RTL finding
  (dma_if_pcie_rd.v:1069). They stay as holes, not exclusions.
* Tier 3c's read-split cross: closed at Tier 3 where the engine is isolated.

## RTL FINDING 2 - a spurious 4 KB read at MRRS 4096 (dma_if_pcie_rd)

Found by t3_cov_closure, the first test ever to configure MRRS = 4096
(t3_mps_mrrs_matrix stops at 1024). 514 scoreboard mismatches on every seed,
all inside the MRRS-4096 section; the ten smaller MRRS/RCB configurations of the
same sweep were clean.

    expected: addr=0x400062000 len=4096   (next descriptor)
    actual  : addr=0x400061000 len=4096   (no descriptor asked for this)

Mechanism, from the RTL (fpga/lib/pcie/rtl/dma_if_pcie_rd.v):

* Remaining count exactly 4096 at a 4 KB-aligned address, MRRS 4096: the count
  fits in MRRS, so the first branch (:663) is taken, and `req_op_count_reg >> 12
  != 0` sends it down the "crosses 4k" path (:665). The 4096-byte request it
  issues is correct.
* That path sets `req_last_tlp` (:675) with `&& req_op_count_reg >> 12 == 0` -
  false for exactly 4096 - so the request is not marked last.
* The engine iterates with 0 bytes left. The non-crossing branch gives
  `req_dword_count = 0`, and a TLP length field of 0 means 1024 DWORDs: a 4 KB
  read of the next page. Its completion is then written into RAM past the
  descriptor's destination.

Not reachable at MRRS <= 2048: there a 4096-byte remainder exceeds MRRS and takes
the other branch. Reached by a 4096-byte aligned descriptor or by any longer one
whose remainder is 4096 at a page boundary (8192 aligned). The write engine
(dma_if_pcie_wr) has no last-request flag and is not affected.

A likely one-line fix is to mark the request last when it ends the descriptor
exactly at the boundary, e.g. `req_last_tlp = ({1'b0, req_pcie_addr_reg[11:0]} +
req_op_count_reg) == 13'h1000;` - NOT applied: RTL changes need approval. DECIDED 2026-10-03: not
patched locally; the fix goes into the upstream report only.

Confirmed in isolation (t3_mrrs4096_exact seed 1, run alone): after the correct
4096-byte read at 0x400070000 the DUT issued `addr=0x400071000 len=4096` with no
descriptor outstanding, and 256 RAM bytes of the transfer then read back 0x00 -
the spurious completion OVERWROTE data already delivered. So this is silent data
corruption, not only an extra bus read.

Test: t3_mrrs4096_exact (expected to fail, kept in the regression like
t3_cpl_timeout). t3_cov_closure skips that one case so it can pass; the x_split
cells it would fill (4 KB length, aligned, MRRS 4096) stay as holes.

## OPEN - DMA RAM interface assertions fire but do not fail tests

`dma_ram_if.sv` a_wr_addr_stable / a_wr_data_stable report "changed while
stalled" in 9 of 21 Tier 3 tests, all of which PASS: an SVA `$error` is not a
UVM_ERROR, so the pass/fail rule never sees it. Two problems:

* The messages look like FALSE positives. The DUT's output register reloads only
  when `!valid || ready` (dma_if_pcie_rd.v:1719), so address/data cannot change
  while stalled; the responder drives ready through a clocking block with a 1 ns
  output skew, so there is no obvious race. Suspected: xsim sampling of `$stable`
  on a genvar part-select. Not yet isolated; valid-dropped never fires.
* Whatever the cause, assertion failures must reach the verdict. Next step:
  route interface assertion failures to `uvm_error` (or count `Error:` lines in
  xsim_run.py's classify) - after the false positive is understood, or every
  affected test turns red for a testbench reason.

## RUNNER DEFECT - parallel xsim launches ran each other's tests (8% of logs)

The first confirmation run of t3_mrrs4096_exact "passed" - because it never
ran: its log held t3_cov_closure. Two xsim front ends started together on one
snapshot can hand their kernels each other's arguments; each log lands at the
requested path, but holds the other run's test/seed (and the kernel writes the
other run's coverage database).

Audit of every log under results/xsim: **206 of 2,499 (8%) ran a different
(test, seed) than their name** - mostly the neighbouring seed of the same test,
sometimes another test. Consequences for earlier results:

* No failure was hidden: every verdict is a real run of SOME test/seed. But the
  pass counts include duplicates - about 8% of the (test, seed) pairs reported
  in the 5-seed and 20-seed tables were never run. The 20-seed numbers are
  therefore "2235/2240 runs, of which ~8% duplicate another seed", not 2240
  distinct runs.
* It is the likely cause of the "Unable to create output directory" coverage
  wedges: two kernels writing the same per-run database.

Fixed in xsim_run.py: launches are serialised until the kernel has started
(UVM's [RNTST] line in the log), and every log's echoed UVM_TESTNAME/-sv_seed is
checked against the request - a mismatch is rerun, and after four mismatches the
run is reported MISLAUNCH rather than a verdict. The final coverage re-measure
was restarted with the fix.

## Final coverage-closure measurement (seeds 1-5, launch-checked runner)

```
tier  tests  runs     func cov   holes left
1a     13    65/65    100%
1b      9    45/45    100%
1c      7    35/35    100%
2      11    55/55    100%
3      21    95/105    83%       cg_status timeout/flr (RTL finding 1);
                                   x_split 4K x aligned x MRRS4096 x RCB128 (finding 2)
3b     11    55/55    100%
3c      6    30/30     34%       not chased - its split cross is closed at Tier 3
4a     11    55/55    100%
4b      7    35/35    100%
4c      9    45/45    100%
4d      7    35/35    100%
5       7    35/35    100%
6       5    25/25    100%
TOTAL        620/630
```

The 10 failures are t3_cpl_timeout and t3_mrrs4096_exact on every seed - the two
RTL findings. All 629 checkable 5-seed logs were audited for crossed launches:
one remains (t3_cpl_timeout seed 1 holds a seed-2 run of the same deterministic
failure); every other log ran exactly its labelled test and seed.

Tier 4d needed one more pass after this run started: x_len's (straddled, long)
cell was hidden by the xcrg table quirk; t4d_cov_closure now sends a short+long
RC pair, and sim/scripts/cov_holes.py falls back to the summary counts so a
hidden cross hole is still listed.

---

# G5 - end-to-end datapath (Tier 6, mqnic_core_pcie_us)

The whole NIC, used the way software uses it. Built on the real top RTL with
the Tier 6 testbench extended rather than replaced:

| piece | file | what it is |
|---|---|---|
| host | `env/us_host.sv` | BAR master (CQ/CC) and DMA target (RQ/RC) over `mqnic_host_mem_model` + `mqnic_rc_model` |
| driver | `env/mqnic_drv.sv` | transcription of upstream's `fpga/common/tb/mqnic.py` (EQ/CQ/TXQ/RXQ, ports, scheduler), polling instead of MSI-X |
| scoreboard | `env/sb_e2e.sv` | byte-exact TX (host memory -> wire) and RX (wire -> host memory), queue/RSS/checksum checks, `cg_e2e` coverage |
| MAC | `axis_agent` x2 | 512-bit TX sink and RX source, paced at 100 Gb/s line rate |
| top | `tb/tb_top_tier6.sv` | Ethernet and PTP clock domains, TX completions, RQ sequence numbers, flow-control credits |

12 tests (`tests/tier6/tier6_e2e_tests.sv`): init, tx, rx, loopback (upstream's
queue-mapping test), csum (TX offload + RX checksum, with an independent UDP
checksum validation), rss (64 flows over 4 queues), jumbo (to 9214 B),
ring_wrap (16-entry rings and event queue), desc_block1, bad_frame,
rx_overload, stress (4+4 queues, concurrent, random, MAC back-pressure,
completion reordering, credit starvation).

## What the datapath needed that the register tests never did

Each of these left the DUT silently idle - no error, just no traffic:

* **Flow-control credits.** `cfg_fc_ph/pd/nph/npd` were tied to 0. pcie_us_if
  passes them to the RQ shim as available credits (pcie_us_if.v:419-422,
  :506-509) and the shim sends nothing without them (pcie_us_if_rq.v:872-873).
  The first descriptor read sat in the shim's FIFO forever. **This corrects an
  earlier statement in this project** that the zeroed credits were harmless
  because mqnic_core_pcie_us.v:850 leaves the credit OUTPUTS unconnected - the
  inputs are live. Now driven from `pcie_us_fc_if` (unlimited by default; the
  stress test starves them in windows).
* **RQ sequence numbers.** TX_SEQ_NUM_ENABLE = 1 at this level
  (mqnic_core_pcie_us.v:1017): the DMA engines stop after 32 read and 32 write
  TLPs until the hard IP returns their sequence numbers. The top now returns
  each one at the end of its TLP.
* **RQ tuser width.** The top declared 60 bits; the DUT's default is 62
  (RQ_SEQ_NUM_WIDTH 6). The truncated bits [61:60] include the flag the shim
  uses to route returned sequence numbers to the read or write engine.
* **TX completions.** TX_CPL_ENABLE = PTP_TS_ENABLE = 1: a transmit descriptor
  completes only when the MAC returns the frame's tag (tuser[1 +: 6],
  mqnic_port_tx.v:190). The top returns {timestamp, tag} for every frame.
* **Ethernet and PTP clocks** were held at 0. Now 3.102 ns (100G MAC, as
  upstream) and 4 ns, distinct from the core clock, so the port CDC FIFOs are
  crossed for real.

## Testbench defects found by the end-to-end tests

* **pcie_us_axis_monitor read first-beat tuser fields on the last beat.** Byte
  enables and the RQ sequence number are first-beat fields; pcie_us_if_rq
  recomputes tuser per beat and drives them as 0 afterwards. Every multi-beat
  DMA write decoded as a 1-DWORD write - the first RX packet reached host
  memory as 4 correct bytes and 96 zeros. Fixed (latched at start of packet).
* **sb_shim never compared RQ byte enables.** It predicted them (Tier 4c) and
  dropped the prediction, which is why the monitor bug passed every Tier 4c
  test. Now compared.
* **slang_check's xsim rules never saw class code.** They scanned the filelist
  only, and env/, tests/, model/ are `include`d into packages. A cast in a
  while condition in us_host.sv (xsim rule 6) turned a 20000-cycle timeout into
  ~20 cycles. The rules now follow includes (rules 5-8; the testbench-top
  heuristics 1-4 stay on the filelist, where they are meaningful).
* **`flush()` is a uvm_component virtual function**; a task of that name in a
  component is rejected by xsim and accepted by slang.

## DUT behaviour the tests had to respect (not bugs)

* **RX cannot push back on the MAC** (AXIS_ETH_RX_USE_READY = 0). Under
  overload the 2 KB port CDC FIFO overflows, marks the frame in flight bad, and
  the 32 KB frame FIFO drops it - whole frames only. t6_e2e_rx_overload checks
  exactly that (18 of 48 dropped at bus rate, every delivered frame intact and
  in order, full recovery afterwards).
* **A MAC model must pace inside a frame, not only between frames.** Driving
  a 64-byte beat every 3.1 ns is 165 Gb/s; the core side drains 64 bytes every
  4 ns. A 9000-byte frame then overflows the 2 KB CDC FIFO by itself and is
  dropped. The AXI-S driver now has `line_rate_gbps` (beat-level pacing plus
  20 bytes of preamble/IFG per frame), set to 100 for the RX MAC.
* **Per-packet cost ~150-250 ns** (descriptor fetch, data DMA, completion and
  event writes), measured on t6_e2e_rx. A 100G burst of small frames therefore
  builds a backlog; the functional tests keep at most 16 KB of RX data in
  flight.
* **RX order is per queue.** Several queues are processed concurrently and
  the driver drains them in event order; only order within a queue is
  guaranteed. sb_e2e matches per predicted queue.

## Not covered by G5 (stated, not implied)

* Interrupts: the driver polls; MSI-X is objective G7.
* PTP timestamps are carried but not checked; TCP (as opposed to UDP) RSS
  hashing is not exercised; one port, one interface (the built configuration).
* Throughput is not a pass criterion.

## Upstream report (docs/upstream_report.md)

Drafted for review, three issues: the completion-timeout/FLR drop
(dma_if_pcie_rd.v:1069 - earlier entries said :1068, off by one, corrected), the
MRRS-4096 extra read (:675), and the portability constructs. Both RTL fixes were
verified on a SCRATCH copy of dma_if_pcie_rd.v outside the project tree: Tier 3,
20/20 including t3_cpl_timeout and t3_mrrs4096_exact. Nothing under fpga/ or
rtl_patched/ was changed.

Found while checking the report: **ref_tlp_shim.rc_error() mapped the RC
completion-timeout code as 15**; the RTL (pcie_us_if_rc.v:140) and PG156 use
4'b1001. Only Tier 4a's scoreboard uses the mapping and no test sends that code,
so nothing had failed. Fixed.

---

# G7 - MSI-X interrupts (Tier 6)

Built on the G5 environment:

| piece | file | what it is |
|---|---|---|
| interface | `uvc/common/pcie_us_msix_if.sv` | the hard IP's `cfg_interrupt_msix_*` handshake plus the function's MSI-X Enable / Function Mask |
| hard IP | `env/us_msix.sv` `us_msix_hip` | answers each request with `_sent` (or `_fail` on request) after a random latency; flags a second request while one is pending, or address/data changing while pending |
| checker | `env/us_msix.sv` `sb_msix` | every message must carry the address/data of a programmed, unmasked table entry, from PF0, while the function is enabled and unmasked; `cg_msix` |
| driver | `env/mqnic_drv.sv` | MSI-X table programming (BAR0 + 0x10000, PBA + 0x18000), up to 32 event queues with EQ k on vector k, and an interrupt-driven mode that runs mqnic.py's handler (process EQ, re-arm) per delivered message |

On UltraScale the DUT does not send MSI-X writes on RQ: pcie_us_if hands each
message to the hard IP and holds it until `_sent` or `_fail`
(pcie_us_if.v:573-610). pcie_msix keeps the table and the pending-bit array;
a masked vector, or a masked or disabled function, sets the vector's PBA bit,
and the PBA is rescanned and delivered once unmasked (pcie_msix.v:300-370).

Six tests (`tests/tier6/tier6_msix_tests.sv`): table (32 vectors read back,
mask bits, PBA clear), irq (the datapath with polling off), multi_vector
(8 event queues on 8 vectors, every vector fires with its own address/data),
vector_mask (held in the PBA while masked, delivered on unmask, bit cleared),
function_mask (the same via Function Mask and via MSI-X Enable), fail (the hard
IP refuses one message: the DUT is released and recovers after a watchdog pass).

Order matters, as for an OS: pcie_msix resets its table to all-zero and
UNMASKED, so the table is programmed before MSI-X Enable is set.

Found on the way:
* xsim 2026.1 kernel crash (FATAL_ERROR, no message, a meaningless HDL line)
  from `use_enable ? "with MSI-X disabled" : "with the function masked"` - a
  ?: between string literals of different lengths, passed as a string task
  argument. Assigning through a `string` variable avoids it.
* The `before`-as-identifier rule (8) caught a third occurrence, now that the
  lint rules see class code.

No RTL defect found in the MSI-X path.

## Runner defect: the startup-stall detector killed silent-but-healthy runs

The detector (no log line past `@ 0` for 5 minutes => stalled launch) cannot
tell a stuck kernel from a test that is simply quiet. t3_cpl_timeout hangs by
design and says nothing until its watchdog; on the loaded shared host it was
killed four times per seed and reported NO-SUMMARY instead of FAIL. Fixed with
a one-time heartbeat at 1 us of simulated time in mqnic_base_test, and the
runner now prints every kill. (An indentation slip while adding the comment
briefly made the detector kill EVERY coverage run; caught by the kill logging
within one tier, fixed, and the affected runs repeated.)

## Final regression after G5 and G7 (seeds 1-5)

```
tier  tests  runs      func cov
1a     13    65/65     100%
1b      9    45/45     100%
1c      7    35/35     100%
2      11    55/55     100%
3      21    95/105    83%   (t3_cpl_timeout, t3_mrrs4096_exact: the two RTL findings)
3b     11    55/55     100%
3c      6    30/30     34%   (closed at Tier 3)
4a     11    55/55     100%
4b      7    35/35     100%
4c      9    45/45     100%
4d      7    35/35     100%
5       7    35/35     100%
6      23   115/115    100%  (cg_access, cg_e2e, cg_msix)
TOTAL       710/720
```

All 719 checkable logs ran exactly their labelled test and seed. Lists,
filelists, RAL, strategy-DUT and pyuvm-parameter drift checks all clean.

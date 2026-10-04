# Corundum PCIe — UVM Verification Environment

A tiered UVM verification environment for the PCIe host interface of
[Corundum](https://github.com/corundum/corundum), an open-source FPGA network
interface card.

**This repository is a fork of upstream Corundum.** Everything outside
`uvm_verification/` — `fpga/`, `modules/`, `lib/`, `utils/` — is upstream
Corundum source (BSD-2-Clause-Views) and is **not** my work. The verification
environment in `uvm_verification/` is.

The RTL is **not modified**. Five files carry a documented one-line change and
live separately in [`rtl_patched/`](rtl_patched/); see
[Patched RTL](#patched-rtl) for why, and note that each is a defect worth
reporting upstream.

---

## What it verifies

The DUT is `mqnic_core_pcie_us` — the top of Corundum's PCIe host interface,
one level below the board-specific `fpga_core`. Board tops, the Xilinx PCIe hard
IP, DDR/HBM controllers and CMAC are out of scope: their serial and vendor-IP
interfaces cannot be meaningfully driven in simulation.

Verification is **bottom-up**. Each tier is a real DUT with its own testbench,
and every UVC is built at the smallest block that exercises it and reused
upward.

| tier | DUT | tier | DUT |
|---|---|---|---|
| 1a | `queue_manager`, `cpl_queue_manager` | 4a | `pcie_us_if_rc`, `_cq` |
| 1b | `pcie_tlp_demux_bar` | 4b | `pcie_us_if_cc` |
| 1c | `rx_checksum`, `rx_hash`, `tx_checksum` | 4c | `pcie_us_if_rq` |
| 2 | `dma_psdpram`, `dma_client_axis_*` | 4d | `pcie_us_if` |
| 3a | `dma_if_pcie_rd` | 5 | `mqnic_core_pcie` |
| 3b | `dma_if_pcie_wr` | **6** | **`mqnic_core_pcie_us`** |
| 3c | `dma_if_pcie` | | |

---

## Status

```
14/14   SystemVerilog configurations elaborate     0 errors, 0 lint findings
15/15   tier DUTs elaborate under Icarus           second, independent front end
140/142 SystemVerilog UVM tests pass on xsim       all 13 tiers, Vivado 2026.1
710/720 coverage-regression runs pass              every test x seeds 1-5, 2 RTL findings
 12/12  end-to-end datapath tests (G5)             real top RTL, byte-exact through host memory
  6/6   MSI-X interrupt tests (G7)                 table, masking, multi-vector, hard-IP fail
22/22   strategy DUTs built                        incl. pcie_tlp_mux (Tier 1b)
  8/8   pyuvm tiers pass locally                   38 tests, python pyuvm/runner.py all
   64   bugs found                                 57 testbench, 7 RTL
```

**End-to-end datapath (objective G5) runs on `mqnic_core_pcie_us`.** A
transcription of upstream's own driver model (`fpga/common/tb/mqnic.py`, as
`env/mqnic_drv.sv`) discovers the device over the BAR, builds event,
completion, transmit and receive rings in host memory and moves frames; the DUT
fetches descriptors and data by DMA through its real Xilinx PCIe interface, and
a 100G MAC model sits on the Ethernet port. `sb_e2e` checks every frame
byte-exactly against the other end, plus queue selection, RSS hash and receive
checksum. Twelve tests: bring-up, TX, RX, loopback with queue mapping (as
upstream's test), checksum offload, RSS, jumbo, ring wrap, single-descriptor
blocks, bad-frame drop, RX overload, and a randomized multi-queue stress with
MAC back-pressure, completion reordering and credit starvation. Details and the
defects found on the way: "G5" at the end of the bring-up log.

**MSI-X interrupts (objective G7)** are verified at the same top. A hard-IP
model answers the DUT's `cfg_interrupt_msix_*` requests; `sb_msix` checks every
message against the MSI-X table the driver programmed (address and data of an
unmasked vector, function enabled and unmasked), and the driver can run the
whole datapath interrupt-driven. Six tests: table read/write, interrupt-driven
traffic, eight event queues on eight vectors, vector masking (held in the
pending-bit array, delivered on unmask), function mask and MSI-X Enable, and a
hard-IP `fail` the DUT must recover from. No RTL defect was found in the MSI-X
path. "G7" in the bring-up log.

The two RTL findings and the portability fixes are written up for upstream in
[`docs/upstream_report.md`](docs/upstream_report.md) (draft, not filed); both
proposed RTL fixes were verified in simulation on a scratch copy.

The two failing tests are RTL findings, each failing identically on every seed:

* `t3_cpl_timeout` - a completion-timeout report from the Xilinx RC interface is
  dropped as an unexpected completion (`dma_if_pcie_rd.v:1069`) before the
  timeout branch, so the DMA read engine hangs instead of reporting
  `DMA_ERROR_TIMEOUT`.
* `t3_mrrs4096_exact` - at a max read request size of 4096, a 4096-byte remainder
  at a 4 KB-aligned address is not marked as the last request
  (`dma_if_pcie_rd.v:675`); the engine issues an unrequested 4 KB read of the next
  page whose completion overwrites data already delivered. Silent corruption.

Neither is patched (`fpga/` is read-only); both, with proposed fixes, are at the
end of [`docs/bringup_log.md`](docs/bringup_log.md).

**Functional coverage** (5 seeds, every tier, regenerate with
`sim/scripts/coverage_summary.py --seeds 1,2,3,4,5`):

```
tier  runs     func cov   holes left
1a    65/65    100%
1b    45/45    100%
1c    35/35    100%
2     55/55    100%
3     95/105   83%        DMA status timeout/FLR (RTL finding 1), 1 MRRS-4096 cell (finding 2)
3b    55/55    100%
3c    30/30    34%        not chased: its split cross is closed at Tier 3
4a    55/55    100%
4b    35/35    100%
4c    45/45    100%
4d    35/35    100%
5     35/35    100%
6     115/115  100%       register access, end-to-end datapath (cg_e2e), MSI-X (cg_msix)
```

Closed with one directed `t<tier>_cov_closure` test per tier plus exclusions
that are proven unreachable, each with its reason in the covergroup. DUT code
coverage (Tiers 1-4): statement 60-95%, branch 38-85%, condition 43-79%.

**What this does not claim.** Code coverage is short of the 98% goal, mostly
branches in the Xilinx shims' multi-segment paths; there are no
consecutive-nightly runs; PTP timestamps are carried but not checked, and
throughput is not a pass criterion. Results before 2026-10-02 include ~8% runs that executed a different
seed or test than their label (an xsim parallel-launch race, now detected and
rerun) - see the bring-up log. Interface SVA failures do not yet fail a test
(open item in the log).

---

## Setup

Third-party sources are fetched, not vendored:

```bash
git clone --depth 1 --branch 2020.3.1 \
    https://github.com/accellera-official/uvm-core.git uvm_verification/ext/uvm
```

For the local (no-licence) flow:

```bash
pip install cocotb==2.0.1 pyuvm==4.0.1
# plus Icarus Verilog 12.0 on PATH
```

---

## Running

### Locally — no licence required

[cocotb](https://cocotb.org) + [pyuvm](https://github.com/pyuvm/pyuvm) + Icarus
run real UVM phases, sequences and components against the real RTL:

```bash
cd uvm_verification/pyuvm
python runner.py            # list runnable tiers
python runner.py 6          # one tier
python runner.py all        # all of them, non-zero exit on failure
```

This path exists because tiers 5 and 6 can run nowhere else — see
[EDA Playground](#eda-playground).

### Locally — Vivado xsim (SystemVerilog UVM)

```bash
python uvm_verification/sim/scripts/xsim_run.py 6              # one tier, every test in its list
python uvm_verification/sim/scripts/xsim_run.py 1a t1a_reset   # named tests
```

Uses xsim's bundled UVM 1.2; finds Vivado through `$XILINX_VIVADO`. Logs go to
`results/xsim/tier<N>/`. The script's header lists the xsim limitations it
works around.

Regression and coverage (this machine: 2 cores, so at most `--jobs 2`):

```bash
python sim/scripts/xsim_run.py 3 --seeds 1,2,3,4,5 --jobs 2 --coverage   # verdicts + functional coverage
python sim/scripts/xsim_run.py 3 --seeds 1,2 --jobs 1 --code-coverage    # Tiers 1-4 code coverage
python sim/scripts/coverage_summary.py --seeds 1,2,3,4,5 --md summary.md # statistics table
```

`--code-coverage` builds a separate instrumented snapshot (`tier<N>_cc/`). Take
verdicts only from normal runs: the instrumented build mis-simulated one test,
and parallel instrumented runs lost coverage databases.

### Elaboration and lint

```bash
cd uvm_verification/sim/scripts
python slang_check.py --mode elab --scope all \
       -f ../filelists/tb_tier6.f -f ../filelists/rtl_tier6.f \
       --uvm-home ../../ext/uvm
python check_icarus.py      # every tier DUT, second front end
```

### EDA Playground

Twelve of fourteen tiers export as pasteable tabbed projects. The exports are
generated on demand (into `edaplayground/`) and not kept in the repository,
since xsim now runs every tier locally:

```bash
python sim/scripts/make_eda_playground.py --tier 4d
```

**Tiers 5 and 6 cannot run there.** Playground caps a submission at 1,000,000
characters and a single tab at 100,000; Tier 6 is 2,566,041 characters, and
`mqnic_core.v` alone is 216,760 — twice the per-tab cap, and a module cannot be
split across files. The exporter measures this, exits non-zero, and marks the
generated `EDA_PLAYGROUND_RUN.md` as NOT RUNNABLE rather than producing
something that looks finished and is not.

---

## Layout

```
uvm_verification/
  VERIFICATION_STRATEGY.md   the plan: goals, tiers, UVC specs, signoff criteria
  docs/bringup_log.md        every bug, why it happened, and what it cost
  uvc/                       10 reusable verification components
  env/                       per-tier environments and scoreboards
  tests/                     142 tests
  model/                     reference models (DMA split rules, TLP shim, checksum)
  ral/                       register model, GENERATED from modules/mqnic/mqnic_hw.h
  sva/                       module-level assertions
  tb/                        testbench tops, port maps GENERATED
  sim/filelists/             one RTL + one TB filelist per tier
  sim/scripts/               generators and drift checks (see below)
  pyuvm/                     the local cocotb/pyuvm flow (second, independent testbench)
  rtl_patched/               five one-line RTL fixes, each documented
  results/                   simulation output (not source; safe to delete)
```

### Generated, with drift detection

Nothing that can be derived is maintained by hand. Every generator has a
`--check` mode that fails CI when its output has gone stale:

```bash
python sim/scripts/gen_ral.py --check             # RAL vs mqnic_hw.h
python sim/scripts/gen_regress_lists.py --check   # lists vs test sources
python sim/scripts/check_filelists.py             # filelists, with self-audit
python sim/scripts/check_strategy_duts.py --check # strategy vs what is built
python pyuvm/check_tier_params.py --check         # tier params vs the SV tops
```

This is not ceremony. A hand-maintained inventory has drifted **four times** in
this project — the filelist tier table, the regression lists, the RAL, and the
cocotb parameter table — and each time it failed silently, still reporting OK
while covering less than it claimed.

---

## Patched RTL

Five files in [`rtl_patched/`](rtl_patched/) differ from upstream by one line
each (applied at every site that shares the defect), and every one is a defect
in the configuration Corundum **ships**:

| file | change |
|---|---|
| `pcie_tlp_fifo_raw.v` | `$clog2(1)` → zero-width part select |
| `pcie_tlp_fifo.v` | passes the same zero down as an override |
| `mqnic_rx_queue_map.v` | same construct |
| `mqnic_interface_tx/rx.v` | parameter used in the port list, declared later |
| `mqnic_core.v` | 16-bit `ctrl_reg_*_addr` into 24-bit PTP / clock-info ports - zero-extended explicitly |

The first four are constructs Vivado accepts and standards-conformant front
ends reject. `mqnic_core.v` is the reverse: conformant tools zero-extend the
narrower address, but Vivado xsim leaves the extra bits Z, so the PHC and
clock-info register blocks never answer. The explicit extension is what the
standard already specifies. The filelists point at the real `fpga/` sources
everywhere else, so the environment still proves something about shipped RTL.
Worth reporting upstream as a single issue.

On xsim, `xsim_run.py` compiles the **shipped** `pcie_tlp_fifo{,_raw}.v` and
`mqnic_rx_queue_map.v`: xsim accepts them, and the patched FIFO's widened port
leaves `pcie_us_if_cc`'s `[-1:0]` offset wire at Z (every completion is lost).

---

## License

`uvm_verification/` is BSD-2-Clause-Views, matching upstream Corundum.
Accellera UVM under `ext/` is Apache-2.0 and is fetched, not redistributed here.

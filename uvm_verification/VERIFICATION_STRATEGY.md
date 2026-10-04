# Corundum `mqnic_core_pcie_us` — UVM Verification Strategy

**Document version:** 1.0
**Status:** Baseline — approved for code generation
**DUT repository:** Corundum / mqnic, upstream `github.com/corundum/corundum`
**Testbench root:** `uvm_verification/` (all paths in this document are relative to it)

---

## 0. How To Use This Document

This is the **single source of truth** for building the UVM testbench from an empty
directory to signoff. It is written to be executed top-to-bottom.

| If you want to… | Read section |
|---|---|
| Understand what we are building and why | §1, §2 |
| Understand the DUT | §3 |
| See the overall TB architecture | §4, §5 |
| Know exactly which files to create, in order | **§18 — Generation Manifest** |
| Write a specific agent | §7 (per-UVC specs) |
| Write the register model | §8 |
| Write the reference models | §10 |
| Write the scoreboards | §11 |
| Know which tests to write | §13 |
| Know when a phase is done | §19 |
| Know when the project is done | §21 |

**Rule for generation:** never create a file that is not listed in §18, and never
create files out of the §18 order. Every file in §18 has a spec section
reference; read that section before generating the file.

---

## 1. Goals

### 1.1 Primary Goal

Build a reusable, tier-structured UVM verification environment that proves the
functional correctness of the Corundum PCIe host-interface subsystem, culminating
in full-DUT verification of `mqnic_core_pcie_us`.

### 1.2 Concrete Objectives

| ID | Objective | Measure |
|---|---|---|
| G1 | Verify PCIe DMA data integrity in both directions | 0 mismatches over 10k randomized descriptors, all alignments |
| G2 | Verify PCIe protocol legality of all DUT-generated TLPs | 0 SVA failures; 4 KB / MPS / RCB / tag rules |
| G3 | Verify Xilinx↔generic TLP shim equivalence | Bidirectional equivalence, all straddle modes |
| G4 | Verify queue/descriptor/completion state machines | Reference-model match on all pointer/phase/op-tag transitions |
| G5 | Verify end-to-end NIC datapath (TX + RX) | Byte-exact packet match through host memory model |
| G6 | Verify offloads: RX checksum, RX hash/RSS, TX checksum, PTP timestamp | Algorithmic reference-model match |
| G7 | Verify interrupt delivery | MSI-X TLP address/data match table contents |
| G8 | Achieve coverage closure | ≥98% functional, ≥95% code (line/branch/toggle) on target blocks |
| G9 | Produce a reusable UVC library | Every UVC used at ≥2 tiers |

### 1.3 Non-Goals (explicitly out of scope)

* Verification of the Xilinx PCIe hard IP (`pcie4_uscale_plus_0`) — encrypted vendor IP.
* Verification of DDR4 / HBM controllers and CMAC — vendor IP.
* Gate-level / timing verification, DFT, power-aware (UPF) simulation.
* Board-level top (`fpga.v`) — serial lanes cannot be meaningfully driven.
* The Linux driver ([modules/mqnic/](../modules/mqnic/)) — used only as a *specification source*.
* Formal property verification (may be added later; §22 R6).
* Intel variants (`pcie_s10_if`, `pcie_ptile_if`) — architecture supports them, not scheduled.

### 1.4 Success Criteria

The project is complete when §21 (Signoff Checklist) is fully satisfied.

---

## 2. Strategy Rationale

### 2.1 Why bottom-up

`mqnic_core_pcie_us` is ~9 hierarchy levels deep with dozens of concurrent
state machines. Debugging a data-integrity failure at that level means tracing
a corrupted byte through TLP reassembly → segmented RAM → DMA client → packet
FIFO. Bottom-up inverts the cost:

* Each UVC is **debugged on the smallest DUT that exercises it**, where a failure
  has one plausible cause.
* Simulation turnaround at Tier 1-2 is seconds; at Tier 6 it is minutes to hours.
* By Tier 6 the environment is *assembly only* — no new agents, no new protocol
  debug.

### 2.2 Prior art in the repository — use it

Corundum ships a mature cocotb testbench. **Treat it as an executable
specification, not as competition.**

| Asset | Path | How we use it |
|---|---|---|
| Full-DUT test | [fpga/common/tb/mqnic_core_pcie_us/test_mqnic_core_pcie_us.py](../fpga/common/tb/mqnic_core_pcie_us/test_mqnic_core_pcie_us.py) | Source of system-level scenarios and expected values |
| Driver model | [fpga/common/tb/mqnic.py](../fpga/common/tb/mqnic.py) | Specification for our SV driver sequence library (§12) |
| Block TBs (≈50) | [fpga/lib/pcie/tb/](https://github.com/corundum/corundum/tree/master/fpga/lib/pcie/tb) | Per-tier stimulus/check reference |
| Register map | [modules/mqnic/mqnic_hw.h](../modules/mqnic/mqnic_hw.h) | Source for RAL generation (§8) |

**Mutual cross-check:** when our UVM scoreboard and the cocotb test disagree on a
scenario, one of the two has a bug. This is a free, high-value verification of
the *testbench itself*, and it must be performed at each tier (§19 exit criteria).

### 2.3 Golden configuration

Corundum is aggressively parameterized. Development uses **one** configuration;
sweeping is deferred to Phase 6.

```
AXIS_PCIE_DATA_WIDTH = 512      TLP_SEG_COUNT       = 1
TLP_DATA_WIDTH       = 512      TLP_HDR_WIDTH       = 128
TLP_STRB_WIDTH       = 16       RAM_SEG_COUNT       = 8
IF_COUNT             = 1        PORTS_PER_IF        = 2
PF_COUNT             = 1        VF_COUNT            = 0
PCIE_TAG_COUNT       = 256      MSIX_COUNT          = 32
TX_QUEUE_INDEX_WIDTH = 13       RX_QUEUE_INDEX_WIDTH = 8
```

Rationale for 512-bit: it is the only width that enables **straddling** on all
four Xilinx channels, which is the highest-risk feature in the design (§22 R2).
Verifying the hardest configuration first prevents late-discovered architectural
gaps in the UVCs.

---

## 3. Design Under Verification

### 3.1 RTL hierarchy (verified against source)

```
fpga                                        fpga/mqnic/VCU118/fpga_100g/rtl/fpga.v
├── pcie4_uscale_plus_0                     :748   ← Xilinx hard IP    [OUT OF SCOPE]
├── ddr4_0                              ×2  :1282, :1424               [OUT OF SCOPE]
├── cmac_usplus                         ×2  :1001, :1135               [OUT OF SCOPE]
└── fpga_core                               rtl/fpga_core.v
    ├── rb_drp                          ×2  :721, :763
    ├── mqnic_port_map_mac_axis             :874
    └── mqnic_core_pcie_us                  ★ TIER 6 DUT
        ├── pcie_us_if                      :627   ★ TIER 4 DUT
        │   ├── pcie_us_if_rc  :308                ★ TIER 4a
        │   ├── pcie_us_if_rq  :346                ★ TIER 4a
        │   ├── pcie_us_if_cq  :430                ★ TIER 4a
        │   └── pcie_us_if_cc  :469                ★ TIER 4a
        └── mqnic_core_pcie                 :872   ★ TIER 5 DUT
            ├── pcie_tlp_demux_bar  :730           ★ TIER 1b
            ├── pcie_axil_master    :981
            ├── dma_if_pcie         :1084          ★ TIER 3 DUT
            │   ├── dma_if_pcie_rd  :248           ★ TIER 3a
            │   └── dma_if_pcie_wr  :370           ★ TIER 3b
            ├── pcie_msix           :1270
            ├── stats_pcie_if       :1376
            ├── stats_dma_if_pcie   :1453
            ├── pulse_merge     ×2  :1331, :1344
            └── mqnic_core                  :1581
                ├── axil_reg_if     :683
                ├── mqnic_ptp       :825
                ├── mqnic_rb_clk_info :881
                ├── axil_crossbar ×2 :1023, :1275
                ├── dma_if_mux      :1532
                ├── irq_rate_limit  :2334
                ├── mqnic_dram_if ×2 :2521, :2708
                ├── mqnic_app_block  :3675
                └── mqnic_interface  :3034   [generate × IF_COUNT]
                    ├── queue_manager     ×2  :1845, :1930   ★ TIER 1a
                    ├── cpl_queue_manager ×2  :1370, :1606   ★ TIER 1a
                    ├── desc_fetch  :2095  + desc_op_mux :2015
                    ├── cpl_write ×2 :1456, :1743 + cpl_op_mux :1692
                    ├── dma_if_mux_wr  :1284
                    ├── mqnic_tx_scheduler_block :2247
                    ├── mqnic_interface_tx  :2467
                    │   ├── tx_engine :263
                    │   ├── dma_psdpram :428               ★ TIER 2
                    │   ├── dma_client_axis_source :470    ★ TIER 2
                    │   └── mqnic_egress :540 → tx_checksum :120   ★ TIER 1c
                    ├── mqnic_interface_rx  :2655
                    │   ├── rx_engine :330
                    │   ├── dma_psdpram :534               ★ TIER 2
                    │   ├── dma_client_axis_sink :625      ★ TIER 2
                    │   └── mqnic_ingress :576 → rx_hash :97, rx_checksum :166  ★ TIER 1c
                    └── mqnic_port  :3189   [generate × PORTS_PER_IF]
                        ├── mqnic_port_tx :602 → mqnic_l2_egress  :536
                        └── mqnic_port_rx :737 → mqnic_l2_ingress :156
```

Line numbers refer to instantiation sites in the named parent file.

### 3.2 Tier 6 DUT interface summary — `mqnic_core_pcie_us`

| Group | Signals | TB role |
|---|---|---|
| Clock/reset | `clk`, `rst` | Generated by TB top |
| PCIe RC (in) | `s_axis_rc_{tdata,tkeep,tvalid,tready,tlast,tuser}` | TB drives (completions) |
| PCIe RQ (out) | `m_axis_rq_{tdata,tkeep,tvalid,tready,tlast,tuser}` | TB monitors + backpressures |
| PCIe CQ (in) | `s_axis_cq_{tdata,tkeep,tvalid,tready,tlast,tuser}` | TB drives (host BAR access) |
| PCIe CC (out) | `m_axis_cc_{tdata,tkeep,tvalid,tready,tlast,tuser}` | TB monitors + backpressures |
| TX seq num | `s_axis_rq_seq_num_{0,1}`, `s_axis_rq_seq_num_valid_{0,1}` | TB drives |
| Config mgmt | `cfg_mgmt_{addr,function_number,write,write_data,byte_enable,read}` / `cfg_mgmt_read_data`, `cfg_mgmt_read_write_done` | TB responds |
| Config status | `cfg_max_read_req[2:0]`, `cfg_max_payload[2:0]`, `cfg_rcb_status[3:0]` | TB drives |
| Flow control | `cfg_fc_{ph,pd,nph,npd,cplh,cpld}` / `cfg_fc_sel[2:0]` | TB drives credits |
| MSI-X | `cfg_interrupt_msix_{enable,mask,vf_enable,vf_mask}` / `..._{address,data,int,vec_pending}`, `..._sent`, `..._fail` | TB responds |
| Errors | `status_error_cor`, `status_error_uncor` | TB monitors |
| AXI-Lite CSR | `m_axil_csr_*` — **DUT is master** | TB is reactive slave |
| Ctrl register | `ctrl_reg_{wr,rd}_*` | TB responds |
| PTP | `ptp_clk`, `ptp_rst`, `ptp_sample_clk`, `ptp_sync_ts_tod`, `ptp_pps`, … | TB clocks + monitors |
| Ethernet TX | `tx_clk[N]`, `tx_rst[N]`, `m_axis_tx_*`, `s_axis_tx_cpl_*`, `tx_enable/status/lfc/pfc` | TB monitors TX, drives cpl |
| Ethernet RX | `rx_clk[N]`, `rx_rst[N]`, `s_axis_rx_*`, `rx_enable/status/lfc/pfc` | TB drives frames |
| Statistics | `s_axis_stat_{tdata,tid,tvalid,tready}` | TB drives |
| Application | `app_gpio_*`, `app_jtag_*` | Tied off |

### 3.3 Key parameters (from RTL)

```
AXIS_PCIE_RC_USER_WIDTH = DW < 512 ?  75 : 161
AXIS_PCIE_RQ_USER_WIDTH = DW < 512 ?  62 : 137
AXIS_PCIE_CQ_USER_WIDTH = DW < 512 ?  85 : 183
AXIS_PCIE_CC_USER_WIDTH = DW < 512 ?  33 :  81
RQ_SEQ_NUM_WIDTH        = RQ_USER_WIDTH == 60 ? 4 : 6
PCIE_TAG_COUNT          = RQ_USER_WIDTH == 60 ? 64 : 256
TLP_DATA_WIDTH = AXIS_PCIE_DATA_WIDTH ; TLP_STRB_WIDTH = DW/32
TLP_HDR_WIDTH  = 128                  ; TLP_SEG_COUNT  = 1
```

The `tuser` width switch at 512 bits is the straddle enable — see §22 R2.

---

## 4. Verification Architecture

### 4.1 Layered view

```
┌──────────────────────────────────────────────────────────────────┐
│ TEST LAYER            mqnic_*_test  (extends mqnic_base_test)    │
├──────────────────────────────────────────────────────────────────┤
│ SCENARIO LAYER        virtual sequences (driver model, traffic)  │
├──────────────────────────────────────────────────────────────────┤
│ FUNCTIONAL LAYER      RAL │ predictors │ scoreboards │ coverage   │
├──────────────────────────────────────────────────────────────────┤
│ COMMAND LAYER         UVC agents (sequencer/driver/monitor)      │
├──────────────────────────────────────────────────────────────────┤
│ SIGNAL LAYER          SV interfaces + clocking blocks + SVA      │
└──────────────────────────────────────────────────────────────────┘
                              DUT (Verilog-2001)
```

### 4.2 Tier 6 environment topology

```
                          mqnic_core_pcie_us_env
                                    │
      ┌──────────────┬──────────────┼──────────────┬──────────────┐
      │              │              │              │              │
 pcie_us_agent  pcie_cfg_agent  axil_agent    eth_rx_agent   eth_tx_agent
 (composite)      (active)      (reactive       (active)      (passive)
      │                           slave)          ×2             ×2
      ├─ rq_uvc (passive+bp)                       │              │
      ├─ rc_uvc (active)                           │              │
      ├─ cq_uvc (active)                           │              │
      └─ cc_uvc (passive+bp)                       │              │
                    │                                             │
                    ▼                                             ▼
        ┌───────────────────────┐                   ┌──────────────────────┐
        │  Root Complex Model   │◄──────────────────│  ptp_agent (passive) │
        │  + Host Memory Model  │                   │  stats_agent (active)│
        └───────────┬───────────┘                   └──────────────────────┘
                    │
        ┌───────────▼────────────────────────────────────────────┐
        │ PREDICTORS: dma_predictor, rx_predictor, tx_predictor, │
        │             cpl_predictor, msix_predictor              │
        └───────────┬────────────────────────────────────────────┘
                    ▼
        ┌────────────────────────────────────────────────────────┐
        │ SCOREBOARDS: sb_dma, sb_rx_path, sb_tx_path, sb_csr,   │
        │              sb_irq, sb_protocol                       │
        └────────────────────────────────────────────────────────┘
```

### 4.3 Architectural rules

1. **Agents are never parameterized as UVM classes.** Widths arrive via
   `uvm_config_db` from the SV wrapper. Transaction items use maximally-sized
   fields (`bit [1023:0] data`) plus a `len` field.
2. **Every monitor has an analysis port.** Drivers never publish; only monitors do.
3. **Scoreboards never touch the DUT.** All input comes from analysis ports.
4. **Predictors are transaction-level and simulator-independent** — no `$root`,
   no hierarchical references, no `force`.
5. **One interface per protocol boundary**, bound in the TB top, passed by
   `uvm_config_db` with a documented instance-path string (§17.3).
6. **Reset is a sequence, not an `initial` block** — enables mid-test reset tests.

---

## 5. Tier Plan

| Tier | DUT | New UVCs | Reused UVCs | Est. |
|---|---|---|---|---|
| **1a** | `queue_manager`, `cpl_queue_manager` | `axil_agent`, `queue_op_agent`, `doorbell_monitor` | — | 2 wk |
| **1b** | `pcie_tlp_demux_bar`, `pcie_tlp_mux`, `pcie_tlp_fifo` | `pcie_tlp_agent` | — | 2 wk |
| **1c** | `rx_hash`, `rx_checksum`, `tx_checksum` | `axis_agent` | — | 1.5 wk |
| **2** | `dma_psdpram`, `dma_psdpram_async`, `dma_client_axis_{source,sink}` | `dma_ram_agent` | `axis_agent` | 2.5 wk |
| **3a** | `dma_if_pcie_rd` | `dma_desc_agent`, host memory model | `pcie_tlp_agent`, `dma_ram_agent` | 3 wk |
| **3b** | `dma_if_pcie_wr` | — | all above | 2 wk |
| **3c** | `dma_if_pcie` | — | all above | 2 wk |
| **4a** | `pcie_us_if_{cq,cc,rq,rc}` | `pcie_us_axis_agent` | `pcie_tlp_agent` | 3 wk |
| **4b** | `pcie_us_if` | — | all above | 1.5 wk |
| **5** | `mqnic_core_pcie` | `pcie_cfg_agent`, driver sequence library, RAL | all above | 5 wk |
| **6** | `mqnic_core_pcie_us` | `eth_{rx,tx}_agent`, `ptp_agent`, `stats_agent` | all above | 6 wk |
| **7** | Coverage closure, param sweeps, signoff | — | all | 4 wk |

**Total ≈ 34.5 engineer-weeks sequential; ≈ 18-20 calendar weeks with 2-3 engineers**
(Tiers 1a/1b/1c parallelize; Tier 4 overlaps Tier 3; driver sequence library
starts during Tier 3).

### 5.1 UVC reuse matrix — the payoff

| UVC | Built at | Reused at |
|---|---|---|
| `axil_agent` | 1a | 3, 5, 6 |
| `pcie_tlp_agent` | 1b | 3, 4, 5 |
| `axis_agent` | 1c | 2, 5, 6 |
| `dma_ram_agent` | 2 | 3, 5 |
| `dma_desc_agent` | 3a | 5 |
| host memory model | 3a | 5, 6 |
| `pcie_us_axis_agent` | 4a | 6 |
| `pcie_cfg_agent` | 5 | 6 |
| RAL | 5 | 6 |
| driver sequence library | 5 | 6 |

---

## 6. Testbench Directory Structure

All paths relative to `uvm_verification/`.

```
uvm_verification/
├── VERIFICATION_STRATEGY.md          ← this document
├── docs/
│   ├── testplan.md                   ← §13 expanded, tracked per-test
│   ├── coverage_plan.md              ← §14 expanded
│   └── bringup_log.md                ← running log, per §19
├── uvc/                              ← reusable verification components
│   ├── common/
│   │   ├── mqnic_vrf_pkg.sv          ← typedefs, enums, utility functions
│   │   └── mqnic_reset_if.sv
│   ├── axil/
│   │   ├── axil_if.sv
│   │   ├── axil_item.sv
│   │   ├── axil_cfg.sv
│   │   ├── axil_driver.sv            ← master mode
│   │   ├── axil_slave_driver.sv      ← reactive slave mode
│   │   ├── axil_monitor.sv
│   │   ├── axil_sequencer.sv
│   │   ├── axil_agent.sv
│   │   ├── axil_seq_lib.sv
│   │   └── axil_pkg.sv
│   ├── axis/                         ← same 9-file pattern
│   ├── pcie_tlp/                     ← same 9-file pattern
│   ├── pcie_us_axis/                 ← same 9-file pattern
│   ├── dma_ram/                      ← same 9-file pattern
│   ├── dma_desc/                     ← same 9-file pattern
│   ├── queue_op/                     ← same 9-file pattern
│   ├── pcie_cfg/                     ← same 9-file pattern
│   ├── eth/                          ← eth_rx + eth_tx agents
│   ├── ptp/
│   └── stats/
├── model/                            ← non-UVC functional models
│   ├── mqnic_host_mem_model.sv
│   ├── mqnic_rc_model.sv             ← root complex behavior
│   ├── mqnic_tlp_pkt.sv              ← TLP abstraction class
│   ├── ref_dma.sv
│   ├── ref_queue.sv
│   ├── ref_checksum.sv
│   ├── ref_hash.sv
│   ├── ref_tlp_shim.sv
│   └── model_pkg.sv
├── ral/
│   ├── mqnic_ral_pkg.sv
│   ├── mqnic_reg_block.sv            ← generated from mqnic_hw.h
│   └── mqnic_reg_adapter.sv
├── env/
│   ├── tier1a_env.sv … tier6_env.sv
│   ├── mqnic_scoreboard_base.sv
│   ├── sb_dma.sv, sb_rx_path.sv, sb_tx_path.sv,
│   │   sb_csr.sv, sb_irq.sv, sb_protocol.sv
│   ├── mqnic_coverage.sv
│   └── env_pkg.sv
├── seq/
│   ├── mqnic_base_seq.sv
│   ├── driver_model/                 ← §12: ring setup, doorbell, completion
│   ├── traffic/                      ← packet generators
│   └── seq_pkg.sv
├── tests/
│   ├── mqnic_base_test.sv
│   ├── tier1a/ … tier6/
│   └── test_pkg.sv
├── sva/
│   ├── sva_pcie_tlp.sv
│   ├── sva_dma_if_pcie.sv
│   ├── sva_queue_manager.sv
│   └── sva_axis.sv
├── tb/
│   ├── tb_top_tier1a.sv … tb_top_tier6.sv
│   └── dut_wrapper_*.sv               ← parameter binding wrappers
├── sim/
│   ├── Makefile
│   ├── filelists/
│   │   ├── rtl_tier1a.f … rtl_tier6.f
│   │   └── tb_common.f
│   ├── scripts/
│   │   ├── run_regression.py
│   │   ├── merge_coverage.sh
│   │   └── waveform.tcl
│   └── regress/
│       ├── tier1.list … tier6.list
│       └── nightly.list
└── results/                          ← gitignored
```

**Naming conventions:** §17.

---

## 7. UVC Specifications

Each UVC follows the identical 9-file pattern:
`*_if.sv`, `*_item.sv`, `*_cfg.sv`, `*_driver.sv`, `*_monitor.sv`,
`*_sequencer.sv`, `*_agent.sv`, `*_seq_lib.sv`, `*_pkg.sv`.

### 7.1 `axil_agent` — AXI-Lite (Tier 1a)

* **Interface signals:** `awaddr`, `awprot`, `awvalid`, `awready`, `wdata`,
  `wstrb`, `wvalid`, `wready`, `bresp`, `bvalid`, `bready`, `araddr`, `arprot`,
  `arvalid`, `arready`, `rdata`, `rresp`, `rvalid`, `rready`.
  Reference: [queue_manager.v:90-108](../fpga/common/rtl/queue_manager.v#L90-L108)
* **Item fields:** `kind` (READ/WRITE), `addr`, `data`, `strb`, `prot`, `resp`,
  `delay_aw`, `delay_w`, `delay_ar`, `delay_b`, `delay_r`.
* **Modes:** `MASTER` (drives, Tier 1a/3), `SLAVE` (reactive, Tier 5/6 — DUT is
  master on `m_axil_csr_*`), `PASSIVE`.
* **Driver:** independent AW/W channel timing (must randomize AW-before-W,
  W-before-AW, simultaneous). Slave mode returns data from a backing memory
  or from a sequence response.
* **Monitor:** reconstructs complete transactions; publishes on write-response
  and read-data completion. Must handle out-of-order AW/W arrival.
* **Config:** `is_master`, `addr_width`, `data_width`, `min/max_delay`,
  `resp_error_rate`.

### 7.2 `pcie_tlp_agent` — generic TLP (Tier 1b) — **highest-value UVC**

* **Interface signals (per channel):** `tlp_data[TLP_DATA_WIDTH-1:0]`,
  `tlp_strb[TLP_STRB_WIDTH-1:0]`, `tlp_hdr[SEG*128-1:0]`, `tlp_valid[SEG-1:0]`,
  `tlp_sop[SEG-1:0]`, `tlp_eop[SEG-1:0]`, `tlp_ready`; plus channel-specific
  `tlp_bar_id[SEG*3-1:0]`, `tlp_func_num[SEG*8-1:0]`, `tlp_error[SEG*4-1:0]`,
  `tlp_seq[SEG*SEQ_W-1:0]`.
  Reference: [mqnic_core_pcie.v:221-297](../fpga/common/rtl/mqnic_core_pcie.v#L221-L297)
* **Item = `mqnic_tlp_pkt`:** `fmt`, `type`, `tc`, `attr`, `ep`, `td`, `length`,
  `requester_id`, `tag`, `last_be`, `first_be`, `address[63:0]`, `at`,
  `completer_id`, `status`, `byte_count`, `lower_address`, `payload[]` (dynamic
  byte array), `bar_id`, `func_num`, `error`, `seq`.
* **Channel enum:** `RX_REQ`, `RX_CPL`, `TX_RD_REQ`, `TX_WR_REQ`, `TX_CPL`,
  `TX_MSIX_WR_REQ` — one agent instance per channel, `channel` in config.
* **Driver:** packs a `mqnic_tlp_pkt` into segments; randomizes gaps, and (when
  `SEG>1`) straddling patterns.
* **Monitor:** unpacks segments into `mqnic_tlp_pkt`; must handle a packet
  spanning arbitrary beat counts and multiple packets per beat.
* **Config:** `channel`, `data_width`, `seg_count`, `hdr_width`, `seq_width`,
  `is_active`, `backpressure_profile` (NONE / RANDOM / AGGRESSIVE / BURSTY).

### 7.3 `axis_agent` — AXI-Stream (Tier 1c)

* **Signals:** `tdata`, `tkeep`, `tvalid`, `tready`, `tlast`, `tuser`.
* **Item:** `data[]` (byte queue), `user`, `id`, `dest`, plus per-beat
  `tready` gap profile.
* Used for: `rx_hash`/`rx_checksum`/`tx_checksum` I/O (Tier 1c), DMA client
  interfaces (Tier 2), Ethernet TX/RX (Tier 6 — subclassed as `eth_*_agent`).

### 7.4 `dma_ram_agent` — segmented memory interface (Tier 2)

* **Signals:** `wr_cmd_sel`, `wr_cmd_be[SEG*SEG_BE_W]`,
  `wr_cmd_addr[SEG*SEG_ADDR_W]`, `wr_cmd_data[SEG*SEG_DATA_W]`,
  `wr_cmd_valid[SEG]`, `wr_cmd_ready[SEG]`, `wr_done[SEG]`,
  `rd_cmd_sel`, `rd_cmd_addr[SEG*SEG_ADDR_W]`, `rd_cmd_valid[SEG]`,
  `rd_cmd_ready[SEG]`, `rd_resp_data[SEG*SEG_DATA_W]`, `rd_resp_valid[SEG]`,
  `rd_resp_ready[SEG]`.
  Reference: [dma_psdpram.v:50-71](../fpga/lib/pcie/rtl/dma_psdpram.v#L50-L71)
* **Critical:** every segment is an independent valid/ready channel. The driver
  and monitor must handle *any subset* of segments active in a cycle, and the
  backpressure profile must be **independently randomized per segment**.
* **Modes:** `RESPONDER` (models the RAM, Tier 3) and `INITIATOR` (drives
  commands, Tier 2).

### 7.5 `dma_desc_agent` — DMA descriptor (Tier 3a)

* **Read descriptor in:** `s_axis_read_desc_{pcie_addr,ram_sel,ram_addr,len,tag,valid,ready}`
* **Read status out:** `m_axis_read_desc_status_{tag,error,valid}`
* **Write descriptor in:** `s_axis_write_desc_{pcie_addr,ram_sel,ram_addr,imm,imm_en,len,tag,valid,ready}`
* **Write status out:** `m_axis_write_desc_status_{tag,error,valid}`
  Reference: [dma_if_pcie.v:139-172](../fpga/lib/pcie/rtl/dma_if_pcie.v#L139-L172)
* **Item:** `dir` (READ/WRITE), `pcie_addr[63:0]`, `ram_sel`, `ram_addr`, `len`,
  `tag`, `imm`, `imm_en`, and expected `status_error[3:0]`.
* **Driver must maintain a free-tag pool** — issuing a duplicate in-flight tag
  is illegal stimulus, not a DUT bug.

### 7.6 `pcie_us_axis_agent` — Xilinx RQ/RC/CQ/CC (Tier 4a)

* **Signals:** `tdata`, `tkeep`, `tvalid`, `tready`, `tlast`, `tuser` with
  channel-specific `tuser` layout and width (§3.3).
* **`tuser` field decode must be implemented per channel and per width**
  (75 vs 161 for RC, 62 vs 137 for RQ, 85 vs 183 for CQ, 33 vs 81 for CC).
  *Correction from RTL:* `pcie_us_if_rq.v:41` defaults RQ to **60**, not 62, and
  accepts either; mqnic parameterises it to 62 (`mqnic_core_pcie_us.v:160`),
  which is what makes `RQ_SEQ_NUM_WIDTH` 6 and splits `seq_num` across
  `[27:24]` and `[61:60]`. The widths above are correct for mqnic, not for the
  module in isolation.
* **RC is the only channel that straddles at the golden 256-bit width**
  (`mqnic_core_pcie_us.v:163-166`: RC from 256, RQ/CQ/CC only from 512). Tier 4's
  straddle risk is therefore concentrated in one channel, not spread over four.
* **Straddle slots are quantised to 128 bits** — a TLP may begin only at lane 0
  or 4 at 256-bit data, 0/4/8/12 at 512-bit. A constraint on the DRIVER, not a
  decode detail.
  This decode table is the single most error-prone piece of the whole TB —
  cross-check against `cocotbext-pcie`'s `UltraScalePlusPcieDevice` and
  against Xilinx PG213.
* **Straddle support is mandatory** — see §22 R2 and Tier 4 coverage (§14.4).

### 7.7 `pcie_cfg_agent` — configuration/sideband (Tier 5)

* **Drives:** `bus_num[7:0]`, `ext_tag_enable`, `rcb_128b`,
  `max_read_request_size[2:0]`, `max_payload_size[2:0]`, `msix_enable`,
  `msix_mask`. Reference: [mqnic_core_pcie.v:302-308](../fpga/common/rtl/mqnic_core_pcie.v#L302-L308)
* **Tier 6 additionally:** `cfg_mgmt_*` handshake responder, `cfg_fc_*` credit
  supply, `cfg_interrupt_msix_*` responder (`_sent` / `_fail`).
* **Monitors:** `pcie_error_cor`, `pcie_error_uncor` /
  `status_error_cor`, `status_error_uncor`.

### 7.8 `queue_op_agent`, `doorbell_monitor` (Tier 1a)

* **Dequeue request:** `s_axis_dequeue_req_{queue,tag,valid,ready}`
* **Dequeue response:** `m_axis_dequeue_resp_{queue,ptr,phase,addr,block_size,cpl,tag,op_tag,empty,error,valid,ready}`
* **Dequeue commit:** `s_axis_dequeue_commit_{op_tag,valid,ready}`
* **Doorbell:** `m_axis_doorbell_{queue,valid}` — **note: no `ready`**, it is a
  pulse output; the monitor must sample every cycle.

### 7.9 `eth_rx_agent` / `eth_tx_agent` (Tier 6)

Subclasses of `axis_agent` that additionally construct/parse Ethernet frames and
carry the mqnic `tuser` sidebands (PTP tag on TX, timestamp/error on RX).
Frame construction library must support: Ether/IP/UDP, Ether/IP/TCP, VLAN,
jumbo, runt (<64 B), and max-size frames.

### 7.10 `ptp_agent`, `stats_agent` (Tier 6)

* `ptp_agent` — passive. Monitors `ptp_sync_ts_tod[96:0]`, `ptp_sync_ts_rel[63:0]`,
  `ptp_pps`, `ptp_perout_pulse`. Checks monotonicity and period.
* `stats_agent` — active on `s_axis_stat_{tdata,tid,tvalid,tready}`.

---

## 8. Register Abstraction Layer (RAL)

### 8.1 Source of truth

[modules/mqnic/mqnic_hw.h](../modules/mqnic/mqnic_hw.h). Do **not** hand-transcribe
— write a generator script (`sim/scripts/gen_ral.py`) that parses the `#define`s
so the RAL stays in sync when the RTL is updated.

### 8.2 Register-block discovery model

Corundum uses a **walked linked list of register blocks**, not a flat map:

```
MQNIC_RB_REG_TYPE      0x00   ← block type ID
MQNIC_RB_REG_VER       0x04   ← block version
MQNIC_RB_REG_NEXT_PTR  0x08   ← offset of next block, 0 = end of list
```

The RAL must model this as a **discoverable** structure. The Tier 5 first test
(`test_rb_walk`) walks the list and asserts the discovered set matches the
configured DUT parameters.

Known block types to model:

| Type ID | Block | Key registers |
|---|---|---|
| `0xFFFFFFFF` | FW ID | `FPGA_ID` 0x0C, `FW_ID` 0x10, `FW_VER` 0x14, `BOARD_ID` 0x18, `BOARD_VER` 0x1C, `BUILD_DATE` 0x20, `GIT_HASH` 0x24, `REL_INFO` 0x28 |
| `0x0000C080` | PHC (PTP clock) | `CTRL` 0x0C, `CUR_*` 0x10-0x2C, `SNAP_*` 0x30-0x4C, `SET_*`/`OFFSET_*` 0x50-0x6C, `PERIOD_*` 0x70-0x7C |
| `0x0000C081` | PHC perout | `CTRL` 0x0C, `START_*` 0x10-0x1C, `PERIOD_*` 0x20-… |
| `0x0000C005` | App info | `ID` 0x0C |
| `0x0000C100` | GPIO | `GPIO_IN` 0x0C, `GPIO_OUT` 0x10 |
| `0x0000C110` | I2C | `CTRL` 0x0C |
| `0x0000C120` | SPI flash | `FORMAT` 0x0C, `CTRL_0` 0x10, `CTRL_1` 0x14 |

Plus interface / port / scheduler / queue-manager blocks — enumerate the full set
from `mqnic_hw.h` during generation.

### 8.3 Queue control registers (indirect command interface)

Queues are **not** flat register arrays; they use a command/status protocol.

```
MQNIC_QUEUE_BASE_ADDR_VF_REG  0x00
MQNIC_QUEUE_CTRL_STATUS_REG   0x08
MQNIC_QUEUE_SIZE_CQN_REG      0x0C
MQNIC_QUEUE_PROD_PTR_REG      0x10
MQNIC_QUEUE_CONS_PTR_REG      0x12

Commands written to CTRL_STATUS:
  SET_VF_ID     0x80010000     SET_SIZE      0x80020000
  SET_CQN       0xC0000000     SET_PROD_PTR  0x80800000
  SET_CONS_PTR  0x80900000     SET_ENABLE    0x40000100
Masks: ENABLE 0x00000001, ACTIVE 0x00000008, PTR 0xFFFF
```

CQ and EQ use the same pattern with their own command set
(`MQNIC_CQ_CMD_*` / `MQNIC_EQ_CMD_*`, incl. `SET_ARM` `0x40000200`,
`SET_CONS_PTR_ARM` `0x80910000`).

**Implication:** model these as `uvm_reg` with custom `pre_write`/`post_read`
callbacks, or as a dedicated `mqnic_queue_ctrl_seq` layer above the RAL. The
latter is recommended — a plain `uvm_reg` mirror cannot express command
semantics.

---

## 9. Host Memory Model

**File:** `model/mqnic_host_mem_model.sv`. Built at Tier 3a, reused at Tiers 5-6.

Requirements:

* Sparse storage — `byte mem[longint unsigned]` associative array. The DUT
  addresses a 64-bit space; dense allocation is impossible.
* API: `write_bytes(addr, byte q[])`, `read_bytes(addr, len)`,
  `alloc_region(size, align)`, `compare_region(addr, expected[])`.
* **Access log with timestamps** — required by the DMA scoreboard to correlate
  TLP activity against memory state.
* **Region attributes** for error injection: a region may be marked
  `UNSUPPORTED_REQUEST`, `COMPLETER_ABORT`, or `POISONED` so the RC model
  returns the corresponding completion status.
* Configurable completion behavior: split size, RCB (64/128 B), max reorder
  depth, min/max completion latency.

---

## 10. Reference Models (Predictors)

| Model | File | Predicts | Notes |
|---|---|---|---|
| `ref_dma` | `model/ref_dma.sv` | For a descriptor: the exact set of TLPs the DUT must emit, and the resulting memory/RAM state | Must model 4 KB boundary splitting, MPS/MRRS splitting, RCB alignment |
| `ref_queue` | `model/ref_queue.sv` | Queue pointer/phase/op-tag state after each operation | Mirror of `queue_manager` semantics |
| `ref_checksum` | `model/ref_checksum.sv` | 16-bit 1's-complement checksum | `~checksum(frame[14:]) & 0xFFFF` — matches [test:469](../fpga/common/tb/mqnic_core_pcie_us/test_mqnic_core_pcie_us.py#L469) |
| `ref_hash` | `model/ref_hash.sv` | 32-bit Toeplitz hash + RSS queue index | Validate against known RSS test vectors first |
| `ref_tlp_shim` | `model/ref_tlp_shim.sv` | Xilinx AXI-S ↔ generic TLP, both directions | One model serves both Tier 4 directions |

**Rule:** predictors are pure functions of observed transactions. No time
dependence, no DUT peeking. If a prediction needs internal state, that state is
built from previously observed transactions only.

---

## 11. Scoreboards

| Scoreboard | Tier | Inputs | Checks |
|---|---|---|---|
| `sb_protocol` | 1b+ | `pcie_tlp_agent` monitors | 4 KB boundary, MPS, MRRS, RCB, tag uniqueness/range, fmt/type legality, no reordering within channel |
| `sb_queue` | 1a | `queue_op_agent`, `axil_agent`, `doorbell_monitor` | vs `ref_queue`: in-order retirement (ptr advances only when the op at finish_ptr is committed), speculative `active_cons_ptr` while an op is outstanding, phase = `!ptr[log_queue_size]`, `resp_error` when disabled vs `resp_empty` when enabled-but-empty, `op_tag` uniqueness |
| `sb_dma` | 3+ | `dma_desc_agent`, `pcie_tlp_agent`, `dma_ram_agent`, host memory | vs `ref_dma`: byte-exact data integrity, `status_error` correctness, completion reassembly across reorder |
| `sb_shim` | 4 | both `pcie_us_axis_agent` and `pcie_tlp_agent` monitors | Bidirectional equivalence, all straddle modes |
| `sb_csr` | 5+ | `axil_agent`, RAL | Mirror vs actual; RB linked-list integrity |
| `sb_rx_path` | 6 | `eth_rx_agent`, host memory, `pcie_tlp_agent` | Frame bytes in memory, `cpl` fields (len/queue/`rx_csum`/`rx_hash`/`port`), RSS distribution |
| `sb_tx_path` | 6 | host memory, `eth_tx_agent`, `ptp_agent` | Byte-exact frame on wire, `tkeep`/`tlast` correctness, TX completion + timestamp |
| `sb_irq` | 5+ | `pcie_tlp_agent` (MSIX channel), RAL | MSI-X TLP address/data match table entry for the EQ; masking honored |

All scoreboards extend `mqnic_scoreboard_base`, which provides:
match/mismatch counters, `check_phase` end-of-test drain check, configurable
out-of-order matching window, and consistent mismatch reporting format.

---

## 12. Sequence Library

### 12.1 Layering

```
Level 3  virtual sequences   (system scenarios — Tier 5/6)
Level 2  driver model seqs   (ring init, doorbell, cpl consumption)
Level 1  RAL access seqs     (register read/write, RB walk)
Level 0  UVC seqs            (per-agent primitives)
```

### 12.2 Driver model sequences (Tier 5, port from [mqnic.py](../fpga/common/tb/mqnic.py))

| Sequence | Responsibility |
|---|---|
| `seq_probe_device` | Walk register blocks, build the device topology object |
| `seq_alloc_rings` | Allocate TXQ/RXQ/CQ/EQ ring memory in the host memory model |
| `seq_init_eq` | Program EQ base addr, size, IRQN; enable; arm |
| `seq_init_cq` | Program CQ base addr, size, EQN; enable; arm |
| `seq_init_txq` / `seq_init_rxq` | Program base addr, size, CQN; enable |
| `seq_post_rx_desc` | Write `mqnic_desc` to RX ring, advance producer ptr |
| `seq_post_tx_desc` | Write packet + `mqnic_desc` to TX ring, ring doorbell |
| `seq_consume_cq` | Read `mqnic_cpl` entries, advance consumer ptr, re-arm |
| `seq_consume_eq` | Read `mqnic_event` entries, dispatch to CQ handler |
| `seq_enable_port` | Enable TX/RX on a port, configure scheduler |

### 12.3 Data structures (from `mqnic_hw.h`)

```
MQNIC_DESC_SIZE  = 16 bytes
struct mqnic_desc  { le16 rsvd0; le16 tx_csum_cmd; le32 len; le64 addr; }

MQNIC_CPL_SIZE   = 32 bytes
struct mqnic_cpl   { le16 queue; le16 index; le16 len; le16 rsvd0;
                     le32 ts_ns; le16 ts_s; le16 rx_csum; le32 rx_hash;
                     u8 rx_hash_type; u8 port; u8 rsvd2; u8 rsvd3;
                     le32 rsvd4; le32 phase; }

MQNIC_EVENT_SIZE = 32 bytes
struct mqnic_event { le16 type; le16 source; le32 rsvd0..rsvd5; le32 phase; }
MQNIC_EVENT_TYPE_CPL = 0x0000
```

All fields are **little-endian**; the packing/unpacking helpers live in
`uvc/common/mqnic_vrf_pkg.sv`.

---

## 13. Test Plan

### Tier 1a — `queue_manager` / `cpl_queue_manager`
| Test | Intent |
|---|---|
| `t1a_reset` | All outputs quiescent after reset; no spurious doorbell |
| `t1a_reg_access` | RAL mirror vs actual, all queue control registers |
| `t1a_enable_disable` | Ops rejected when disabled; `ACTIVE` mask behavior |
| `t1a_dequeue_basic` | Single dequeue, correct `addr`/`ptr`/`phase`/`cpl` |
| `t1a_dequeue_empty` | `resp_empty=1`, no pointer advance |
| `t1a_commit_ordering` | Out-of-order commits; ptr advances only when contiguous |
| `t1a_op_table_full` | `OP_TABLE_SIZE` concurrent ops; back-pressure correctness |
| `t1a_ptr_wrap` | Wrap at ring boundary; phase bit toggles |
| `t1a_doorbell` | Doorbell fires on each producer-pointer write while the queue is enabled; no doorbell when disabled |
| `t1a_random_stress` | 10k randomized ops across all queues |

### Tier 1b — TLP mux/demux/fifo
`t1b_reset`, `t1b_bar_route` (each BAR ID → correct output, `BAR_STRIDE=2`),
`t1b_mux_arbitration` (fairness, no starvation), `t1b_fifo_full`,
`t1b_backpressure` (all profiles), `t1b_straddle_pack`,
`t1b_random_stress`.

### Tier 1c — offload blocks
`t1c_checksum_known_vectors`, `t1c_checksum_random`, `t1c_checksum_odd_length`,
`t1c_hash_known_vectors` (RSS reference vectors), `t1c_hash_ipv4_ipv6`,
`t1c_hash_no_l4`, `t1c_tx_csum_offset_sweep`, `t1c_runt_and_jumbo`.

### Tier 2 — segmented RAM
`t2_reset`, `t2_wr_rd_all_segs`, `t2_wr_rd_single_seg`,
`t2_seg_independent_backpressure`, `t2_cdc_async` (`dma_psdpram_async`),
`t2_client_source_alignment`, `t2_client_sink_alignment`, `t2_random_stress`.

### Tier 3 — DMA engine (**highest-value tier**)
| Test | Intent |
|---|---|
| `t3_read_basic` / `t3_write_basic` | Single descriptor, aligned, small |
| `t3_alignment_sweep` | All 64 × 64 combinations of `pcie_addr[5:0]` × `ram_addr[5:0]` |
| `t3_len_sweep` | 1 B → max length, incl. boundaries at MPS/MRRS multiples |
| `t3_4k_boundary` | Descriptors deliberately straddling 4 KB boundaries |
| `t3_mps_mrrs_matrix` | Cross MPS {128,256,512,1024} × MRRS {128,…,4096} |
| `t3_rcb_64_128` | Both RCB settings |
| `t3_cpl_reorder` | Completions returned out of order, max reorder depth |
| `t3_cpl_split_max` | Every completion split to the minimum legal size |
| `t3_tag_exhaustion` | Saturate `PCIE_TAG_COUNT` outstanding tags |
| `t3_ext_tag_off` | `ext_tag_enable=0` → 5-bit tags only |
| `t3_err_ur` / `t3_err_ca` / `t3_err_poison` | Correct `desc_status_error`, no hang |
| `t3_cpl_timeout` | Completion never returned → graceful behavior |
| `t3_imm_write` | `imm_en=1` immediate-data writes |
| `t3_backpressure_matrix` | RAM and TLP backpressure profiles crossed |
| `t3_random_stress` | 10k randomized descriptors, mixed R/W |

### Tier 4 — PCIe shim
`t4_cq_basic`, `t4_cc_basic`, `t4_rq_basic`, `t4_rc_basic`,
`t4_straddle_cq`, `t4_straddle_cc`, `t4_straddle_rq`, `t4_straddle_rc`,
`t4_straddle_rc_4tlp`, `t4_straddle_mixed` (straddled sop + non-straddled eop),
`t4_tuser_field_sweep`, `t4_fc_credits`, `t4_cfg_mgmt`,
`t4_equivalence_random` (bidirectional, 10k TLPs).

### Tier 5 — `mqnic_core_pcie`
`t5_reset`, `t5_rb_walk`, `t5_csr_access`, `t5_bar_demux` (NIC vs app BAR),
`t5_ring_init`, `t5_rx_single_packet`, `t5_tx_single_packet`,
`t5_msix_delivery`, `t5_eq_cq_chain`, `t5_multi_queue_4`, `t5_random_traffic`.

### Tier 6 — `mqnic_core_pcie_us`
| Test | Expected result |
|---|---|
| `t6_smoke` | Device probes, rings init, link up |
| `t6_rx_single` | Frame bytes in host memory; `rx_csum == ~checksum(frame[14:]) & 0xFFFF`; `cpl.len` correct; MSI-X fired |
| `t6_rx_rss_spread` | 4 distinct flows land in 4 distinct queues |
| `t6_tx_single` | Byte-exact frame on `m_axis_tx`; `tkeep`/`tlast` correct; TX completion with PTP timestamp |
| `t6_tx_csum_offload` | Inserted checksum matches reference at the specified offset |
| `t6_bidir_traffic` | Simultaneous TX+RX, no corruption |
| `t6_multi_port` | Both ports concurrent at line rate |
| `t6_many_queues` | 1000+ active queues; no descriptor leak; op tables drain |
| `t6_backpressure_sweep` | `tready` duty 100/50/10% on every interface |
| `t6_frame_size_sweep` | 60 B runt → 9000 B jumbo |
| `t6_err_injection` | UR/CA/poison completions → correct `status_error_*`, no hang |
| `t6_reset_inflight` | Reset asserted mid-DMA; re-init; full recovery |
| `t6_ptp_timestamp` | Monotonic timestamps, correct PPS period |
| `t6_msix_mask` | Masked vectors do not generate TLPs; pending bit set |
| `t6_long_random` | 1 M packets mixed, overnight regression |

---

## 14. Functional Coverage Model

### 14.1 Principles
* Coverage is written **with** the test, never retrofitted.
* Every covergroup is sampled from a **monitor analysis port**, never from
  driver stimulus (stimulus coverage measures the TB, not the DUT).
* Illegal bins are declared explicitly; `ignore_bins` require a written
  justification comment.

### 14.2 Tier 1a
`queue_index` (0, 1, mid, max) × `enable` × `empty/full/wrap` ×
`op_table_occupancy` (0, 1, mid, `OP_TABLE_SIZE-1`, full) ×
`commit_order` (in-order, out-of-order).

### 14.3 Tier 3 — the critical cross
```
len            : {1, 2..63, 64, 65..255, 256, 257..MPS, MPS+1..4095, 4096, >4096}
pcie_addr[5:0] : {0, 1..31, 32, 33..63}
ram_addr[5:0]  : {0, 1..31, 32, 33..63}
max_payload    : {128, 256, 512, 1024}
max_read_req   : {128, 256, 512, 1024, 2048, 4096}
rcb            : {64, 128}
cpl_order      : {in_order, reordered, max_split}
crosses_4k     : {yes, no}
tag_occupancy  : {1, mid, max}
error_status   : {OK, UR, CA, POISON}
CROSS: len × pcie_addr × ram_addr × max_payload × rcb × cpl_order
```

### 14.4 Tier 4 — straddle coverage (mandatory)
```
channel        : {CQ, CC, RQ, RC}
straddle_mode  : {none, 2tlp, 4tlp}
sop_position   : {seg0, seg1, seg2, seg3}
eop_position   : {seg0, seg1, seg2, seg3}
tlp_size       : {1DW, 2DW, .. , max}
CROSS: channel × straddle_mode × sop_position × eop_position
```

### 14.5 Tier 6
`frame_size` × `port` × `queue_class` (low/mid/high index) ×
`direction` × `offload` (csum on/off, hash type) ×
`backpressure_profile` × `concurrent_ports`.

### 14.6 Code coverage
Line, branch, toggle, FSM on the RTL files listed in each tier's filelist.
Condition/expression coverage on `dma_if_pcie_*` and `pcie_us_if_*` only.

---

## 15. Assertions (SVA)

### 15.1 Placement rule
* **Interface protocol** assertions live in the UVC `*_if.sv` (valid/ready
  stability, no `tvalid` drop before `tready`, sop/eop framing legality).
* **Design intent** assertions live in `sva/*.sv` and are attached with `bind` —
  never edited into the DUT source.

### 15.2 Required assertion set

`sva_pcie_tlp.sv`
* No read request crosses a 4 KB boundary.
* Request length ≤ `max_read_request_size`; write payload ≤ `max_payload_size`.
* Tag unique while outstanding; tag within legal range for `ext_tag_enable`.
* `sop`/`eop` framing: no `eop` without a preceding `sop`; `strb` contiguous.
* No `tvalid` deassertion before `tready` within a packet.

`sva_dma_if_pcie.sv`
* Every issued descriptor eventually produces exactly one status.
* `status_error` ≠ 0 implies at least one non-successful completion was observed.
* No RAM write command without a corresponding completion.

`sva_queue_manager.sv`
* Consumer pointer advances only on IN-ORDER retirement of the op table.
* `op_tag` never reissued while outstanding.
* Phase bit is `!ptr[log_queue_size]` and therefore toggles at ring wrap.
* A request to a disabled queue returns `error`, never `empty`.

`sva_axis.sv`
* `tlast` implies `tkeep` contiguous from LSB.
* `tvalid` stable until `tready`.

---

## 16. Build and Run Infrastructure

### 16.1 Filelists
One RTL filelist per tier (`sim/filelists/rtl_tier*.f`) built from the
`SYN_FILES` list in [fpga/mqnic/VCU118/fpga_100g/fpga/Makefile](https://github.com/corundum/corundum/blob/master/fpga/mqnic/VCU118/fpga_100g/fpga/Makefile),
trimmed to the tier's DUT cone. TB files in `sim/filelists/tb_common.f`.

### 16.2 Compile notes for this RTL
* Verilog-2001; compile with `-timescale=1ns/1ps`.
* The RTL uses `` `default_nettype none `` and `` `resetall `` — do not let TB
  files leak defines into the RTL compilation unit; compile RTL and TB as
  separate units where the simulator allows.
* Include dirs: `fpga/common/rtl`, `fpga/lib/pcie/rtl`, `fpga/lib/eth/rtl`,
  `fpga/lib/axi/rtl`, `fpga/lib/axis/rtl`.

### 16.3 Makefile targets
```
make TIER=3 TEST=t3_alignment_sweep SEED=1234        # single run
make TIER=3 TEST=t3_random_stress WAVES=1            # with waveform dump
make regress TIER=3                                  # tier regression
make nightly                                         # full regression
make coverage                                        # merge + report
make clean
```

### 16.4 Regression runner
`sim/scripts/run_regression.py` — reads a `.list` file, launches parallel runs,
collects pass/fail + coverage, emits a JUnit XML and an HTML summary.
Random seeds: fixed set for reproducibility + a rolling random set per night.

### 16.5 Waveform policy
Waves off by default. `WAVES=1` enables. Failing regression runs auto-rerun once
with waves and the same seed.

---

## 17. Conventions

### 17.1 Naming
| Kind | Pattern | Example |
|---|---|---|
| Package | `<name>_pkg` | `pcie_tlp_pkg` |
| Interface | `<name>_if` | `pcie_tlp_if` |
| Item | `<name>_item` | `pcie_tlp_item` |
| Agent | `<name>_agent` | `pcie_tlp_agent` |
| Config | `<name>_cfg` | `pcie_tlp_cfg` |
| Sequence | `<name>_seq` | `t3_alignment_seq` |
| Test | `t<tier><letter>_<intent>` | `t3_4k_boundary` |
| Scoreboard | `sb_<domain>` | `sb_dma` |
| Covergroup | `cg_<domain>` | `cg_dma_alignment` |
| SVA file | `sva_<block>` | `sva_dma_if_pcie` |

### 17.2 File header
Every generated file starts with: SPDX line, one-paragraph purpose, the
strategy-document section it implements, and the tier it is introduced at.

### 17.3 `uvm_config_db` paths
Interfaces are set at `uvm_test_top` scope with the key
`"<uvc_name>_vif_<instance>"`, e.g. `"pcie_tlp_vif_rx_req"`,
`"axis_vif_eth_rx_0"`. Document every key in `docs/testplan.md`.

### 17.4 Messaging
`UVM_INFO` at `UVM_MEDIUM` for scenario milestones, `UVM_HIGH` for
transaction-level, `UVM_DEBUG` for beat-level. Scoreboard mismatches are
`UVM_ERROR` with a fixed 3-line format: expected / actual / context.

---

## 18. Generation Manifest — Build Order

**This is the execution order. Do not deviate.**
Each step lists the files to create and the spec section to read first.

### Step 0 — Infrastructure (no UVM yet)
- [ ] `sim/Makefile`, `sim/filelists/tb_common.f`, `sim/filelists/rtl_tier1a.f` — §16
- [ ] `sim/scripts/run_regression.py`, `merge_coverage.sh` — §16.4
- [ ] `uvc/common/mqnic_vrf_pkg.sv` (typedefs, enums, LE pack/unpack helpers) — §12.3
- [ ] `uvc/common/mqnic_reset_if.sv`
- [ ] `tests/mqnic_base_test.sv`, `seq/mqnic_base_seq.sv`, `env/mqnic_scoreboard_base.sv` — §4.3, §11
- [ ] **Gate:** empty test elaborates and prints `TEST PASSED` against `queue_manager`.

### Step 1 — Tier 1a (`queue_manager`)
- [ ] `uvc/axil/*` — 9 files — §7.1
- [ ] `uvc/queue_op/*` — 9 files — §7.8
- [ ] `sva/sva_queue_manager.sv` — §15.2
- [ ] `model/ref_queue.sv` — §10
- [ ] `env/sb_queue.sv`, `env/tier1a_env.sv` — §11
- [ ] `tb/tb_top_tier1a.sv`, `tb/dut_wrapper_queue_manager.sv`
- [ ] `tests/tier1a/*` — 10 tests — §13
- [ ] `cov/cg_queue.sv` — §14.2
- [ ] **Gate:** §19 Tier 1a exit criteria.

### Step 2 — Tier 1b (TLP mux/demux/fifo)
- [ ] `model/mqnic_tlp_pkt.sv` — §7.2
- [ ] `uvc/pcie_tlp/*` — 9 files — §7.2
- [ ] `sva/sva_pcie_tlp.sv` — §15.2
- [ ] `env/sb_protocol.sv`, `env/tier1b_env.sv`
- [ ] `tb/tb_top_tier1b.sv` + DUT wrappers ×3
- [ ] `tests/tier1b/*` — 7 tests
- [ ] **Gate:** §19 Tier 1b.

### Step 3 — Tier 1c (offloads)
- [ ] `uvc/axis/*` — 9 files — §7.3
- [ ] `model/ref_checksum.sv`, `model/ref_hash.sv` — §10
- [ ] `sva/sva_axis.sv`
- [ ] `env/tier1c_env.sv`, `tb/tb_top_tier1c.sv`
- [ ] `tests/tier1c/*` — 8 tests
- [ ] **Gate:** §19 Tier 1c.

### Step 4 — Tier 2 (segmented RAM)
- [ ] `uvc/dma_ram/*` — 9 files — §7.4
- [ ] `env/tier2_env.sv`, `tb/tb_top_tier2.sv`
- [ ] `tests/tier2/*` — 8 tests
- [ ] **Gate:** §19 Tier 2.

### Step 5 — Tier 3 (DMA engine)

**All three sub-tiers are built and elaborate clean: 3a (`dma_if_pcie_rd`),
3b (`dma_if_pcie_wr`) and 3c (full `dma_if_pcie`). 34 tests in total.
Nothing beyond a handful of 3a tests has been simulated.**

- [x] `uvc/dma_desc/*` — §7.5 — *built early, at Step 4; see the file header*
- [x] `model/mqnic_host_mem_model.sv` — §9
- [x] `model/mqnic_rc_model.sv` — §9
- [x] `model/ref_dma.sv` — §10
- [x] `sva/sva_dma_if_pcie.sv` — §15.2
- [x] `env/rc_responder.sv` — the active half of the root complex
- [x] `env/sb_dma.sv`, `env/tier3_env.sv`
- [x] `uvc/common/dma_if_cfg_if.sv` — the quasi-static configuration pins
- [x] `tb/tb_top_tier3.sv` — 3a
- [x] `env/sb_dma_wr.sv`, `env/tier3b_env.sv`, `tb/tb_top_tier3b.sv`,
      `sva/sva_dma_if_pcie_wr.sv` — 3b
- [x] `env/host_mem_writer.sv`, `env/tier3c_env.sv`, `tb/tb_top_tier3c.sv` — 3c
- [x] `tests/tier3/*` — **19 tests** (§13 asked for 15; `t3_addr_3dw`,
      `t3_cpl_dropped`, `t3_reset` and a split of the error tests were added
      during bring-up — see `docs/bringup_log.md`)
- [x] `tests/tier3b/*` — **9 tests**
- [x] `tests/tier3c/*` — **6 tests**
- [x] `cov/cg_dma.sv` — §14.3
- [ ] **Gate:** §19 Tier 3 — *the most important gate in the project.*
      **NOT MET: nothing has been simulated.** Elaboration and lint are
      evidence of compilability, not of correctness.

**Deviation from this manifest, recorded deliberately.** `dma_if_cfg_if` was
not in the plan. It became necessary because §14.3 crosses length and alignment
against MRRS and RCB, but those are static input pins: tied to constants,
`t3_mps_mrrs_matrix`, `t3_rcb_64_128` and `t3_ext_tag_off` would have documented
configurations they could never reach.

**Tier 3b is deliberately smaller than 3a, and that is not a gap.** A posted
write gets no completion, so reordering, tags in flight, timeouts and host-side
error injection do not exist on that side. Padding the list to match 3a would
have meant writing tests that cannot fail.

**Tier 3c does NOT repeat 3a's and 3b's sweeps.** Re-proving alignment and
length handling on the integrated DUT burns regression time to learn nothing
new; §2.1's argument for small DUTs applies here too. 3c asks only what the
sub-tiers cannot: do the two engines interfere over the shared RAM, and does a
byte survive the full round trip. The loopback tests are the strongest checks
in the tier because no reference model sits between the two directions — a
model that is wrong self-consistently, which is exactly what bug 9 was, cannot
hide there.

**Correction to §13's timeout test.** `dma_if_pcie_rd` has no internal
completion timer. `DMA_ERROR_TIMEOUT` is reachable only through an inbound
completion whose error sideband reads `PCIE_ERROR_TIMEOUT`
(`dma_if_pcie_rd.v:1117-1122`) — the hard IP is what times out. Withholding a
completion is a different question and now has its own test.

### Step 6 — Tier 4 (PCIe shim)

**All four shims are built and elaborate clean. 4a and 4b are simulated with
zero data mismatches; 4c has not been run.**

- [x] `uvc/pcie_us_axis/*` — §7.6 — **tuser codec cross-checked, 308 cases**
- [x] `model/ref_tlp_shim.sv` — §10 — **both directions, 40,000 cases**
- [x] `model/ref_rq_arb.sv` — credit + arbitration (4c; not in the original plan)
- [x] `uvc/common/pcie_us_fc_if.sv` — transmit credits (4c)
- [x] `env/sb_shim.sv` (bidirectional), `env/sb_rq.sv`
- [x] `env/tier4a_env.sv`, `tier4b_env.sv`, `tier4c_env.sv`
- [x] `tb/tb_top_tier4a.sv` (RC+CQ), `tier4b` (CC), `tier4c` (RQ)
- [x] `tests/tier4a/*` — 10 · `tests/tier4b/*` — 7 · `tests/tier4c/*` — 8
- [x] `cov/cg_straddle.sv` — §14.4
- [ ] **Gate:** §19 Tier 4 — **NOT MET.** 4c unrun; no multi-seed, no coverage
      closure, no cocotb cross-check (E6), no nightly (E7).

**Deviation: the tier split three ways, not two.** §5 anticipated 4a/4b. RQ
turned out to be unlike the other three shims — it arbitrates two input streams
and is gated by flow-control credits, so it is not a pure function of its input
and needed its own model and its own scoreboard. Separating it as 4c kept the
other three simple.

**One RTL defect required a patch** (`rtl_patched/`, two files, one line each).
`$clog2(1) == 0` produces a zero-width part select in `pcie_tlp_fifo_raw`,
which slang and VCS reject and Vivado tolerates. Without it Tier 4 could only
run configurations Corundum does not build. See bug 13.

### Step 7 — Tier 5 (`mqnic_core_pcie`)

**Built and elaborating: 101 files, the entire Corundum design. 6 tests.
Nothing simulated.**

- [x] `sim/scripts/gen_ral.py` + `ral/mqnic_ral_pkg.sv` — §8 — 26 block types,
      140 register offsets, generated from `mqnic_hw.h`, `--check` in CI
- [x] `seq/driver_model/mqnic_csr_seq.sv` — §12.2 — split-transaction register
      access over PCIe BAR, tag-matched, plus `mqnic_rb_walker` (§8.2)
- [x] `sim/scripts/gen_tb_ports.py` — the 250-port map, generated
- [x] `env/tier5_env.sv`, `tb/tb_top_tier5.sv`
- [x] `tests/tier5/*` — 6 tests
- [ ] `uvc/pcie_cfg/*` — §7.7 — not needed by the register tests; deferred to
      the interrupt work
- [ ] `env/sb_csr.sv`, `env/sb_irq.sv` — deferred with the same reasoning
- [ ] **Gate:** §19 Tier 5 — not met; nothing simulated.

**Correction to §12.2's placement.** The driver model cannot live in
`mqnic_seq_pkg`: it needs `pcie_tlp_item`, and `pcie_tlp_pkg` imports
`mqnic_seq_pkg`, which would close a dependency cycle. The directory layout
(`seq/driver_model/`) is kept; package membership is `mqnic_env_pkg`.

**§8.2 was right about the hard part.** The register map is a walked linked
list, not a flat map, and `mqnic_core_pcie` has NO AXI-Lite slave for the host —
register access arrives as PCIe BAR requests and leaves as completions. A flat
`uvm_reg_block` would have compiled and been wrong.


- [ ] `sim/scripts/gen_ral.py` + `ral/*` — §8
- [ ] `uvc/pcie_cfg/*` — 9 files — §7.7
- [ ] `seq/driver_model/*` — 10 sequences — §12.2
- [ ] `env/sb_csr.sv`, `env/sb_irq.sv`, `env/tier5_env.sv`
- [ ] `tb/tb_top_tier5.sv`, `tb/dut_wrapper_mqnic_core_pcie.sv`
- [ ] `tests/tier5/*` — 11 tests
- [ ] **Gate:** §19 Tier 5.

### Step 8 — Tier 6 (full DUT)
- [ ] `uvc/eth/*`, `uvc/ptp/*`, `uvc/stats/*` — §7.9, §7.10
- [ ] `seq/traffic/*` — packet generators
- [ ] `env/sb_rx_path.sv`, `env/sb_tx_path.sv`, `env/tier6_env.sv`
- [ ] `tb/tb_top_tier6.sv`, `tb/dut_wrapper_mqnic_core_pcie_us.sv`
- [ ] `tests/tier6/*` — 15 tests
- [ ] `cov/cg_system.sv` — §14.5
- [ ] **Gate:** §19 Tier 6.

### Step 9 — Closure
- [ ] Parameter sweep configs — §20
- [ ] Coverage closure iterations
- [ ] `docs/testplan.md`, `docs/coverage_plan.md` finalized
- [ ] Signoff review — §21

---

## 19. Milestones and Exit Criteria

A tier is complete only when **all** of the following hold:

| # | Criterion |
|---|---|
| E1 | All tier tests pass across ≥20 random seeds |
| E2 | Tier functional coverage ≥98%; every uncovered bin has a written waiver |
| E3 | Code coverage ≥95% line/branch on the tier's DUT files |
| E4 | Zero SVA failures across the tier regression |
| E5 | All new UVCs reviewed against their §7 spec |
| E6 | **Cross-check performed** against the corresponding cocotb TB; any behavioral disagreement resolved and documented in `docs/bringup_log.md` |
| E7 | Tier regression added to `nightly.list` and green for 3 consecutive nights |
| E8 | No open UVM_ERROR/UVM_FATAL; no `$finish` outside the UVM end-of-test flow |

**Tier 3 additionally:** zero data-integrity mismatches over ≥10,000 randomized
descriptors covering all 4096 alignment combinations.

**Tier 4 additionally:** bidirectional equivalence proven for all straddle modes
on all four channels.

---

## 20. Parameter Sweep Plan (Phase 7 only)

| Parameter | Values | Applied at tier |
|---|---|---|
| `AXIS_PCIE_DATA_WIDTH` / `TLP_DATA_WIDTH` | 64, 128, 256, 512 | 1b, 3, 4 (full); 6 (512 + one narrow) |
| `RAM_SEG_COUNT` | 2, 4, 8 | 2, 3 |
| `PCIE_TAG_COUNT` | 64, 256 | 3 |
| `IF_COUNT` | 1, 2 | 5, 6 |
| `PORTS_PER_IF` | 1, 2, 4 | 6 |
| `TX/RX_QUEUE_INDEX_WIDTH` | 8, 13 | 1a, 5 |
| `*_OP_TABLE_SIZE` | 8, 32 | 1a, 3 |

**Rule:** sweep the *cheap* lower tiers exhaustively; run the top DUT at the
golden config plus one narrow config only. Lower-tier sweeps find
width-dependent bugs at a fraction of the runtime.

---

## 21. Signoff Checklist

- [ ] All tiers meet §19 exit criteria
- [ ] Full nightly regression green for 10 consecutive nights
- [ ] Functional coverage ≥98% overall, all waivers reviewed and signed
- [ ] Code coverage ≥95% line/branch/toggle on in-scope RTL
- [ ] Parameter sweep (§20) complete, all configs green
- [ ] Zero open high/critical bugs; all closed bugs have a regression test
- [ ] `t6_long_random` (1 M packets) passes on 5 distinct seeds
- [ ] Cross-check vs cocotb complete at every tier (§19 E6)
- [ ] All UVCs documented; reuse matrix (§5.1) fully satisfied
- [ ] `docs/testplan.md` and `docs/coverage_plan.md` current
- [ ] Reproducibility: any regression failure reproducible from seed alone

---

## 22. Risks and Mitigations

| ID | Risk | Impact | Mitigation |
|---|---|---|---|
| **R1** | Host memory model + driver sequence library are the true schedule risk (SV equivalent of `cocotbext-pcie` + [mqnic.py](../fpga/common/tb/mqnic.py) — thousands of lines) | High | Start both during Tier 3, not Tier 5. Staff them as a dedicated parallel work item. |
| **R2** | Xilinx `tuser` straddle decode is intricate and width-dependent; an error here corrupts data silently three tiers up | High | Build and close it at Tier 4a on isolated `pcie_us_if_*` blocks. Mandatory straddle coverage §14.4. Cross-check decode against `cocotbext-pcie` and Xilinx PG213. |
| **R3** | Parameter explosion consumes the schedule | High | Golden config only until Phase 7 (§2.3). Sweeps on cheap tiers only (§20). |
| **R4** | Segmented memory interface (per-segment independent handshake) is unlike AXI; naive UVC design will not model it | Medium | Build at Tier 2 on `dma_psdpram` where the DUT is trivial. Per-segment independent backpressure randomization is a hard requirement. |
| **R5** | Queue registers use a command protocol, not a flat map — plain `uvm_reg` cannot express it | Medium | Model as a sequence layer above RAL (§8.3), not as `uvm_reg` fields. |
| **R6** | Tier 6 simulation runtime makes coverage closure slow | Medium | Close coverage at Tiers 1-4 where runs are seconds. Tier 6 targets scenario coverage only. Consider formal for `pcie_tlp_mux`/`demux` (§1.3). |
| **R7** | Effort duplicates the existing cocotb TB | Medium | Accepted, deliberately: the deliverable is a UVM signoff flow. Mitigate by using cocotb as cross-check (§2.2) rather than rewriting its scenarios blindly. Consider stopping after Tier 4 if the goal is PCIe-subsystem coverage only — see §23. |
| **R8** | CDC paths (`dma_psdpram_async`, port async FIFOs) cause nondeterministic failures | Medium | Expose CDC at Tier 2 on a small DUT. Use asynchronous, non-integer-ratio clock ratios in randomization. |
| **R9** | RTL updates from upstream break the RAL | Low | Generate RAL from `mqnic_hw.h` (§8.1); never hand-transcribe. |
| **R10** | UVM requires a commercial simulator; the repo's Icarus flow will not run it | Low | Confirm VCS/Questa/Xcelium licensing before Step 0. |

---

## 23. Decision Point — Scope Options

Recorded here so the tradeoff is explicit and revisitable at the Tier 4 gate.

| Option | Scope | Effort | Delivers |
|---|---|---|---|
| **A — PCIe subsystem** | Tiers 1-4 | ~16 wk | Rigorous, parameter-swept coverage of the PCIe/DMA logic — where the bugs actually are. Existing cocotb TB continues to cover system level. |
| **B — Full NIC (this plan)** | Tiers 1-7 | ~34.5 wk | Complete UVM signoff flow for the whole DUT. |

**Baseline for this document is Option B.** If the objective is UVM coverage of
the PCIe host interface specifically, Option A is a defensible stopping point at
roughly half the cost. Revisit at the Tier 4 gate.

---

## 24. Appendix — Quick Reference

### 24.1 Key DUT source files
| Purpose | Path |
|---|---|
| Tier 6 DUT | [fpga/common/rtl/mqnic_core_pcie_us.v](../fpga/common/rtl/mqnic_core_pcie_us.v) |
| Tier 5 DUT | [fpga/common/rtl/mqnic_core_pcie.v](../fpga/common/rtl/mqnic_core_pcie.v) |
| Tier 4 DUT | [fpga/lib/pcie/rtl/pcie_us_if.v](../fpga/lib/pcie/rtl/pcie_us_if.v) |
| Tier 3 DUT | [fpga/lib/pcie/rtl/dma_if_pcie.v](../fpga/lib/pcie/rtl/dma_if_pcie.v) |
| Tier 2 DUT | [fpga/lib/pcie/rtl/dma_psdpram.v](../fpga/lib/pcie/rtl/dma_psdpram.v) |
| Tier 1a DUT | [fpga/common/rtl/queue_manager.v](../fpga/common/rtl/queue_manager.v) |
| Register map | [modules/mqnic/mqnic_hw.h](../modules/mqnic/mqnic_hw.h) |
| Reference TB | [fpga/common/tb/mqnic_core_pcie_us/](../fpga/common/tb/mqnic_core_pcie_us/) |
| Driver model | [fpga/common/tb/mqnic.py](../fpga/common/tb/mqnic.py) |
| Block TBs | [fpga/lib/pcie/tb/](https://github.com/corundum/corundum/tree/master/fpga/lib/pcie/tb) |
| Build reference | [fpga/mqnic/VCU118/fpga_100g/fpga/Makefile](https://github.com/corundum/corundum/blob/master/fpga/mqnic/VCU118/fpga_100g/fpga/Makefile) |

### 24.2 Agent census at Tier 6
7 agent types / 9 instances / 12 UVCs counting PCIe sub-agents:
`pcie_us_agent` (composite ×1 = 4 UVCs), `pcie_cfg_agent` ×1,
`axil_agent` ×1 (reactive slave), `eth_rx_agent` ×2, `eth_tx_agent` ×2,
`ptp_agent` ×1, `stats_agent` ×1.
Add one AXI slave agent per DDR/HBM channel if DRAM is enabled.

### 24.3 Golden expected-value formulas
```
RX checksum : rx_csum == (~checksum(frame[14:])) & 0xFFFF
RX hash     : Toeplitz over (src_ip, dst_ip, src_port, dst_port)
RSS queue   : hash & (indirection_table_size - 1)
TX frame    : m_axis_tx bytes == host_mem[desc.addr +: desc.len]
MSI-X TLP   : addr == msix_table[eqn].addr, data == msix_table[eqn].data
```

---

*End of document. Generation begins at §18 Step 0.*

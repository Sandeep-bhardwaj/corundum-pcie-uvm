# Corundum PCIe host interface — UVM verification

A SystemVerilog/UVM verification environment for the PCIe host interface of
[Corundum](https://github.com/corundum/corundum), the open-source FPGA NIC.
It verifies the shipped RTL bottom-up, from the queue managers to the top of the
host interface, `mqnic_core_pcie_us`, and at the top moves packets end to end
through a host-memory model and delivers MSI-X interrupts.

## Status

| | |
|---|---|
| Tests | 142, of which 140 pass; the other 2 reproduce RTL bugs |
| Regression | 710/720 runs pass over seeds 1–5 (Vivado xsim 2026.1) |
| Functional coverage | 100% on every tier except the two limited by RTL findings |
| End-to-end datapath | 12 tests: TX/RX through host memory, checksum offload, RSS, jumbo, overload, stress |
| MSI-X interrupts | 6 tests: table, masking, multiple vectors, hard-IP failure |
| Bugs found | 64: 57 in the testbench and tools, 7 in the RTL |

Two RTL findings in `dma_if_pcie_rd` are open, both with fixes verified in
simulation: a completion timeout hangs the read engine, and at a 4096-byte max
read request size an extra 4 KB read corrupts delivered data. See
[`uvm_verification/docs/upstream_report.md`](uvm_verification/docs/upstream_report.md).

## Layout

```
fpga/                 Corundum RTL used by the testbenches (unmodified upstream files)
  common/rtl/         mqnic core
  lib/{pcie,axi,eth}/ PCIe, AXI and AXI-Stream libraries
  common/tb/          upstream's driver model (mqnic.py), the reference for env/mqnic_drv.sv
modules/mqnic/        mqnic_hw.h, source of the generated register model
uvm_verification/     the verification environment - start with its README
  tb/ env/ tests/ uvc/ model/ cov/ seq/ ral/ sva/
  rtl_patched/        one-line portability fixes, each documented
  sim/                filelists, regression lists, runner and checks
  docs/               bring-up log (every bug and its cause), upstream report
  pyuvm/              a second, independent cocotb/pyuvm flow on Icarus
```

## Running

Requirements: Vivado 2026.1 (xsim) for the SystemVerilog flow; Python 3.10+;
optionally slang (pyslang) for lint and Icarus/cocotb for the pyuvm flow.
The Accellera UVM sources used for lint go in `uvm_verification/ext/uvm`
(not committed; see the setup section of the verification README).

```bash
cd uvm_verification
python sim/scripts/xsim_run.py 6 t6_e2e_tx          # one test
python sim/scripts/xsim_run.py 6 --seeds 1,2,3 --jobs 2 --coverage
python sim/scripts/coverage_summary.py --seeds 1,2,3,4,5
```

Full instructions, the tier map and the checks are in
[`uvm_verification/README.md`](uvm_verification/README.md).

## License

The Corundum RTL and driver header are © The Regents of the University of
California, BSD-2-Clause-Views (see [`LICENSE`](LICENSE) and
[`AUTHORS`](AUTHORS)); some library files carry their own MIT notice from Alex
Forencich. The verification environment is BSD-2-Clause-Views, as marked in
each file.

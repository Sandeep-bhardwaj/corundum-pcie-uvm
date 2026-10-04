// SPDX-License-Identifier: BSD-2-Clause-Views
// Tier 3a RTL filelist - PCIe DMA read engine.
// Implements : VERIFICATION_STRATEGY.md  §16.1
//
// dma_if_pcie_rd is self-contained: it instantiates no submodules and pulls in
// no library files. Everything it needs is in the one file.
//
// dma_if_pcie_wr and dma_if_pcie are Tiers 3b and 3c and are NOT listed here -
// a tb filelist may only carry wrappers and bind files whose RTL is present in
// its matching rtl_*.f, and sim/scripts/check_filelists.py enforces that.

+incdir+../../../fpga/lib/pcie/rtl

../../../fpga/lib/pcie/rtl/dma_if_pcie_rd.v

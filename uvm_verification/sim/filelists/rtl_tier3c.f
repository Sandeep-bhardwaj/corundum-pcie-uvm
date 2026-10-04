// SPDX-License-Identifier: BSD-2-Clause-Views
// Tier 3c RTL filelist - full PCIe DMA interface.
// Implements : VERIFICATION_STRATEGY.md  §16.1
//
// dma_if_pcie is a wrapper: it instantiates dma_if_pcie_rd and dma_if_pcie_wr,
// so BOTH must be listed. Their bind files (sva_dma_if_pcie.sv and
// sva_dma_if_pcie_wr.sv) therefore both have targets here and both appear in
// tb_tier3c.f - the assertions written for the sub-DUT tiers run unchanged
// against the integrated design.

+incdir+../../../fpga/lib/pcie/rtl

../../../fpga/lib/pcie/rtl/dma_if_pcie_rd.v
../../../fpga/lib/pcie/rtl/dma_if_pcie_wr.v
../../../fpga/lib/pcie/rtl/dma_if_pcie.v

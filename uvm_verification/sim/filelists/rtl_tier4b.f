// SPDX-License-Identifier: BSD-2-Clause-Views
// Tier 4b RTL filelist - the PCIe completer-completion shim.
// Implements : VERIFICATION_STRATEGY.md  §16.1
//
// pcie_us_if_cc instantiates pcie_tlp_fifo_raw directly (not via
// pcie_tlp_fifo), so only the raw FIFO is needed here.
//
// pcie_us_if_rq is NOT listed: it is the other transmit shim and needs a
// flow-control credit model that does not exist yet. See docs/bringup_log.md.

+incdir+../../../fpga/lib/pcie/rtl

../../rtl_patched/pcie_tlp_fifo_raw.v
../../../fpga/lib/pcie/rtl/pcie_us_if_cc.v

// -----------------------------------------------------------------------------
// pcie_tlp_fifo_raw comes from rtl_patched/, NOT from fpga/. One line differs:
// SEG_SEL_WIDTH is floored at 1 so that OUT_TLP_SEG_COUNT = 1 does not produce a
// zero-width part select. See the header of that file and bug 13 in
// docs/bringup_log.md.
//
// It is the ONLY patched RTL file in the project; everything else under fpga/ is
// verbatim. With it, this tier runs the configuration Corundum actually builds.
// -----------------------------------------------------------------------------

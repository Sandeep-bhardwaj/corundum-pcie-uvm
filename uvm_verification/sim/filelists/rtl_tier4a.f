// SPDX-License-Identifier: BSD-2-Clause-Views
// Tier 4a RTL filelist - the PCIe receive shims.
// Implements : VERIFICATION_STRATEGY.md  §16.1
//
// The ISOLATED blocks, not the pcie_us_if wrapper. §22 R2 asks for the tuser
// risk to be closed here, where a mismatch has exactly one plausible cause.
// NOT self-contained: both instantiate pcie_tlp_fifo, which instantiates
// pcie_tlp_fifo_raw. That chain matters - see the VCS note below and
// docs/bringup_log.md.
//
// The transmit shims (pcie_us_if_rq, pcie_us_if_cc) are Tier 4b and are NOT
// listed - a tb filelist may only carry wrappers and binds whose RTL is
// present, and check_filelists.py enforces it.

+incdir+../../../fpga/lib/pcie/rtl

../../rtl_patched/pcie_tlp_fifo_raw.v
../../rtl_patched/pcie_tlp_fifo.v
../../../fpga/lib/pcie/rtl/pcie_us_if_rc.v
../../../fpga/lib/pcie/rtl/pcie_us_if_cq.v


// -----------------------------------------------------------------------------
// pcie_tlp_fifo AND pcie_tlp_fifo_raw come from rtl_patched/, NOT from fpga/.
// One line differs in each:
// SEG_SEL_WIDTH is floored at 1 so that OUT_TLP_SEG_COUNT = 1 does not produce a
// zero-width part select. See the header of that file and bug 13 in
// docs/bringup_log.md.
//
// It is the ONLY patched RTL file in the project; everything else under fpga/ is
// verbatim. With it, this tier runs the configuration Corundum actually builds.
// -----------------------------------------------------------------------------

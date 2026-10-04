// SPDX-License-Identifier: BSD-2-Clause-Views
// Tier 4c RTL filelist - the PCIe requester-request shim.
// Implements : VERIFICATION_STRATEGY.md  §16.1
//
// pcie_us_if_rq is the last Tier 4 DUT and the only one that arbitrates: two
// generic TLP inputs merge onto one Xilinx RQ stream, gated by transmit
// flow-control credits.

+incdir+../../../fpga/lib/pcie/rtl

../../rtl_patched/pcie_tlp_fifo_raw.v
../../rtl_patched/pcie_tlp_fifo.v
../../../fpga/lib/pcie/rtl/pcie_us_if_rq.v

// -----------------------------------------------------------------------------
// pcie_tlp_fifo and pcie_tlp_fifo_raw come from rtl_patched/, NOT from fpga/.
// One line differs in each: SEG_SEL_WIDTH is floored at 1 so OUT_TLP_SEG_COUNT
// = 1 does not produce a zero-width part select. See those files' headers and
// bug 13 in docs/bringup_log.md. Every other RTL file here is verbatim.
// -----------------------------------------------------------------------------

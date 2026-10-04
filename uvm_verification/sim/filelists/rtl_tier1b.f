// SPDX-License-Identifier: BSD-2-Clause-Views
// Tier 1b RTL filelist - TLP routing and buffering.
// Implements : VERIFICATION_STRATEGY.md  §16.1
//
// pcie_tlp_demux_bar wraps pcie_tlp_demux; priority_encoder and arbiter are
// pulled in by the demux. pcie_tlp_fifo is excluded - see tb_top_tier1b.sv
// for why (VCS rejects it at SEG_COUNT=1).

+incdir+../../../fpga/lib/pcie/rtl

../../../fpga/lib/pcie/rtl/pcie_tlp_demux_bar.v
../../../fpga/lib/pcie/rtl/pcie_tlp_demux.v
../../../fpga/lib/pcie/rtl/pcie_tlp_mux.v
../../../fpga/lib/pcie/rtl/priority_encoder.v
../../../fpga/lib/pcie/rtl/arbiter.v

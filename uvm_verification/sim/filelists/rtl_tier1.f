// SPDX-License-Identifier: BSD-2-Clause-Views
// Unified Tier 1 RTL filelist - all seven DUTs.
// Implements : VERIFICATION_STRATEGY.md  §16.1
//
// One design pane for the whole tier. All files are unmodified Corundum RTL.

+incdir+../../../fpga/common/rtl
+incdir+../../../fpga/lib/pcie/rtl
+incdir+../../../fpga/lib/eth/lib/axis/rtl

// Tier 1a
../../../fpga/common/rtl/queue_manager.v
../../../fpga/common/rtl/cpl_queue_manager.v

// Tier 1b
../../../fpga/lib/pcie/rtl/pcie_tlp_demux_bar.v
../../../fpga/lib/pcie/rtl/pcie_tlp_demux.v
../../../fpga/lib/pcie/rtl/priority_encoder.v
../../../fpga/lib/pcie/rtl/arbiter.v

// Tier 1c
../../../fpga/common/rtl/rx_checksum.v
../../../fpga/common/rtl/rx_hash.v
../../../fpga/common/rtl/tx_checksum.v
../../../fpga/lib/eth/lib/axis/rtl/axis_fifo.v

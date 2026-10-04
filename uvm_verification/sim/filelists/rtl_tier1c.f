// SPDX-License-Identifier: BSD-2-Clause-Views
// Tier 1c RTL filelist - offload blocks.
// Implements : VERIFICATION_STRATEGY.md  §16.1
//
// rx_checksum and rx_hash are self-contained. tx_checksum instantiates
// axis_fifo from lib/axis, which is why that file is listed too.

+incdir+../../../fpga/common/rtl
+incdir+../../../fpga/lib/eth/lib/axis/rtl

../../../fpga/common/rtl/rx_checksum.v
../../../fpga/common/rtl/rx_hash.v
../../../fpga/common/rtl/tx_checksum.v
../../../fpga/lib/eth/lib/axis/rtl/axis_fifo.v

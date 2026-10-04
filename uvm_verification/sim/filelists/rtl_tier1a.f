// SPDX-License-Identifier: BSD-2-Clause-Views
// Tier 1a RTL filelist - queue_manager / cpl_queue_manager.
// Implements : VERIFICATION_STRATEGY.md  §16.1
// Introduced : Step 0
//
// Both DUTs are self-contained: neither instantiates a submodule, so this
// filelist needs no library dependencies. Verified against the RTL.

+incdir+../../../fpga/common/rtl

../../../fpga/common/rtl/queue_manager.v
../../../fpga/common/rtl/cpl_queue_manager.v

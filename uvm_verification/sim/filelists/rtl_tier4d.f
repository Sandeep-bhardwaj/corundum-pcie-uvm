// SPDX-License-Identifier: BSD-2-Clause-Views
// Tier 4d RTL filelist - pcie_us_if, the Xilinx shim INTEGRATION.
// Implements : VERIFICATION_STRATEGY.md  §16.1, §5 (this is the plan's Tier 4b)
//
// NAMING - READ THIS BEFORE ASSUMING 4b MEANS WHAT IT SAYS
// --------------------------------------------------------
// VERIFICATION_STRATEGY.md §5 assigns:
//     Tier 4a = pcie_us_if_{cq,cc,rq,rc}   (all four shims)
//     Tier 4b = pcie_us_if                 (the integration)
//
// This environment instead split the four shims across tiers 4a (rc + cq),
// 4b (cc) and 4c (rq) - and in doing so TOOK OVER THE LABEL "4b" that the plan
// had given to the integration. "Tier 4b exists" stayed true while meaning
// something else entirely, and pcie_us_if was silently never built.
//
// It is added here as 4d rather than by renumbering, because renaming three
// tiers would churn the filelists, regression lists, port maps and exports for
// a cosmetic gain. sim/scripts/check_strategy_duts.py now compares §5's DUT
// list against the filelists so this class of omission cannot recur.
//
// WHAT THIS TIER ADDS OVER 4a/4b/4c
// ---------------------------------
// The four shims are verified individually. pcie_us_if wires them together and
// adds what no single-shim testbench can see:
//   * all four channels running CONCURRENTLY - RC and CQ inbound, RQ and CC
//     outbound - with no cross-channel interference
//   * the configuration/status pass-through (max payload, max read request,
//     bus number, flow control) that every shim reads
//   * transmit sequence number return routing

+incdir+../../../fpga/lib/pcie/rtl

../../rtl_patched/pcie_tlp_fifo_raw.v
../../rtl_patched/pcie_tlp_fifo.v
../../../fpga/lib/pcie/rtl/pcie_us_if.v
../../../fpga/lib/pcie/rtl/pcie_us_if_rc.v
../../../fpga/lib/pcie/rtl/pcie_us_if_rq.v
../../../fpga/lib/pcie/rtl/pcie_us_if_cq.v
../../../fpga/lib/pcie/rtl/pcie_us_if_cc.v
../../../fpga/lib/pcie/rtl/pcie_us_cfg.v
../../../fpga/lib/pcie/rtl/pcie_tlp_fifo_mux.v
../../../fpga/lib/pcie/rtl/pcie_tlp_fc_count.v
../../../fpga/lib/pcie/rtl/arbiter.v
../../../fpga/lib/pcie/rtl/priority_encoder.v

// -----------------------------------------------------------------------------
// pcie_tlp_fifo and pcie_tlp_fifo_raw come from rtl_patched/, NOT from fpga/.
// One line differs in each: SEG_SEL_WIDTH is floored at 1 so OUT_TLP_SEG_COUNT
// = 1 does not produce a zero-width part select. See those files' headers and
// bug 13 in docs/bringup_log.md. Every other RTL file here is verbatim.
// -----------------------------------------------------------------------------

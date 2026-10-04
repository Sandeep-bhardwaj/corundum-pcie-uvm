// SPDX-License-Identifier: BSD-2-Clause-Views
//
// pcie_us_axis_pkg - Xilinx UltraScale+ PCIe AXI-Stream UVC
//
// Implements : VERIFICATION_STRATEGY.md  §7.6, §22 R2
// Introduced : Step 6 (Tier 4); reused at Tier 6
//
// Compile order: mqnic_vrf_pkg -> mqnic_seq_pkg -> pcie_us_axis_pkg
//
// EVERY tuser BIT POSITION LIVES IN mqnic_vrf_pkg, not here. §22 R2 names the
// tuser decode the most error-prone piece in the whole testbench, and the
// mitigation is one cross-checked definition that the driver, the monitor and
// the scoreboard all read - rather than three that can drift apart.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

package pcie_us_axis_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    import mqnic_vrf_pkg::*;
    import mqnic_seq_pkg::*;

    `include "pcie_us_axis_item.sv"
    `include "pcie_us_axis_driver.sv"
    `include "pcie_us_axis_monitor.sv"
    `include "pcie_us_axis_agent.sv"

endpackage : pcie_us_axis_pkg

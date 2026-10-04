// SPDX-License-Identifier: BSD-2-Clause-Views
//
// pcie_tlp_pkg - generic PCIe TLP UVC package
//
// Implements : VERIFICATION_STRATEGY.md  §7.2
// Introduced : Step 2 (Tier 1b); reused at Tiers 3, 4, 5 (§5.1)
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

package pcie_tlp_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    import mqnic_vrf_pkg::*;
    import mqnic_seq_pkg::*;

    `include "pcie_tlp_item.sv"
    `include "pcie_tlp_driver.sv"
    `include "pcie_tlp_monitor.sv"
    `include "pcie_tlp_agent.sv"

endpackage : pcie_tlp_pkg

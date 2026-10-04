// SPDX-License-Identifier: BSD-2-Clause-Views
//
// axil_pkg - AXI4-Lite UVC package
//
// Implements : VERIFICATION_STRATEGY.md  §7.1
// Introduced : Step 1 (Tier 1a); reused at Tiers 3, 5, 6 (§5.1)
//
// Compile order within the package matters: types before the components that
// use them, driver/monitor before the agent that builds them, and the sequence
// library last because it references mqnic_base_seq from mqnic_seq_pkg.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

package axil_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    import mqnic_vrf_pkg::*;
    import mqnic_seq_pkg::*;

    `include "axil_item.sv"
    `include "axil_cfg.sv"
    `include "axil_driver.sv"
    `include "axil_slave_driver.sv"
    `include "axil_monitor.sv"
    `include "axil_agent.sv"
    `include "axil_seq_lib.sv"

endpackage : axil_pkg

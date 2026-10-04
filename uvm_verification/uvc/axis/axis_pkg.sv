// SPDX-License-Identifier: BSD-2-Clause-Views
//
// axis_pkg - AXI4-Stream UVC package
//
// Implements : VERIFICATION_STRATEGY.md  §7.3
// Introduced : Step 3 (Tier 1c); reused at Tiers 2, 5, 6 (§5.1)
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

package axis_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    import mqnic_vrf_pkg::*;
    import mqnic_seq_pkg::*;

    `include "axis_item.sv"
    `include "axis_driver.sv"
    `include "axis_monitor.sv"
    `include "axis_agent.sv"

endpackage : axis_pkg

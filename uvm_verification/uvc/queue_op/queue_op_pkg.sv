// SPDX-License-Identifier: BSD-2-Clause-Views
//
// queue_op_pkg - queue manager operation UVC package
//
// Implements : VERIFICATION_STRATEGY.md  §7.8
// Introduced : Step 1 (Tier 1a)
//
// One UVC serves both Tier 1a DUTs - queue_manager (dequeue) and
// cpl_queue_manager (enqueue) - selected by queue_op_cfg.apply_flavor().
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

package queue_op_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    import mqnic_vrf_pkg::*;
    import mqnic_seq_pkg::*;

    `include "queue_op_item.sv"
    `include "queue_op_driver.sv"
    `include "queue_op_monitor.sv"
    `include "queue_op_agent.sv"

endpackage : queue_op_pkg

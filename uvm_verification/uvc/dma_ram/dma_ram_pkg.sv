// SPDX-License-Identifier: BSD-2-Clause-Views
//
// dma_ram_pkg - segmented DMA RAM UVC package
//
// Implements : VERIFICATION_STRATEGY.md  §7.4
// Introduced : Step 4 (Tier 2); reused at Tiers 3 and 5 (§5.1)
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

package dma_ram_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    import mqnic_vrf_pkg::*;
    import mqnic_seq_pkg::*;

    `include "dma_ram_item.sv"
    `include "dma_ram_driver.sv"
    `include "dma_ram_monitor.sv"
    `include "dma_ram_agent.sv"

endpackage : dma_ram_pkg

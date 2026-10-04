// SPDX-License-Identifier: BSD-2-Clause-Views
//
// model_pkg - reference models and functional models
//
// Implements : VERIFICATION_STRATEGY.md  §9 (host memory model), §10 (predictors)
// Introduced : Step 1 (Tier 1a)
//
// Compile order: mqnic_vrf_pkg -> <uvc pkgs> -> mqnic_seq_pkg -> model_pkg
//
// Step 1 added ref_queue; Step 3 (Tier 1c) added ref_checksum and ref_hash.
// Step 5 (Tier 3) added mqnic_host_mem_model and ref_dma; mqnic_rc_model
// follows, and ref_tlp_shim at Step 6.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

package model_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    import mqnic_vrf_pkg::*;

    `include "ref_queue.sv"
    `include "ref_checksum.sv"
    `include "ref_hash.sv"
    `include "mqnic_host_mem_model.sv"
    `include "mqnic_rc_model.sv"
    `include "ref_dma.sv"
    `include "ref_tlp_shim.sv"
    `include "ref_rq_arb.sv"

endpackage : model_pkg

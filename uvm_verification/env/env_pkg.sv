// SPDX-License-Identifier: BSD-2-Clause-Views
//
// mqnic_env_pkg - environment and scoreboard package
//
// Implements : VERIFICATION_STRATEGY.md  §11 (scoreboards), §4.2 (topology)
// Introduced : Step 0; Tier 1a content added at Step 1
//
// Compile order (STRICT - VCS/Questa resolve packages in file order):
//   mqnic_vrf_pkg -> mqnic_seq_pkg -> axil_pkg -> queue_op_pkg -> model_pkg
//   -> mqnic_env_pkg -> mqnic_test_pkg
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

package mqnic_env_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    import mqnic_vrf_pkg::*;
    import mqnic_seq_pkg::*;
    import axil_pkg::*;
    import queue_op_pkg::*;
    import axis_pkg::*;
    import csum_cmd_pkg::*;
    import pcie_tlp_pkg::*;
    import pcie_us_axis_pkg::*;
    import dma_ram_pkg::*;
    import dma_desc_pkg::*;
    import model_pkg::*;
    import mqnic_ral_pkg::*;

    // Driver model (§12.2). Lives HERE, not in mqnic_seq_pkg: it needs
    // pcie_tlp_item, and pcie_tlp_pkg imports mqnic_seq_pkg - putting it
    // there would close a dependency cycle.
    `include "mqnic_csr_seq.sv"

    `include "mqnic_scoreboard_base.sv"
    `include "sb_queue.sv"
    `include "cg_queue.sv"
    `include "cg_offload.sv"
    `include "sb_offload.sv"
    `include "tier1c_env.sv"
    `include "cg_tlp.sv"
    `include "sb_tlp.sv"
    `include "tier1b_env.sv"
    `include "cg_ram.sv"
    `include "sb_dma_ram.sv"
    `include "sb_dma_client.sv"
    `include "tier2_env.sv"
    `include "cg_dma.sv"
    `include "rc_responder.sv"
    `include "sb_dma.sv"
    `include "tier3_env.sv"
    `include "cg_dma_wr.sv"
    `include "sb_dma_wr.sv"
    `include "tier3b_env.sv"
    `include "host_mem_writer.sv"
    `include "tier3c_env.sv"
    `include "cg_straddle.sv"
    `include "sb_shim.sv"
    `include "tier4a_env.sv"
    `include "tier4b_env.sv"
    `include "cg_rq.sv"
    `include "sb_rq.sv"
    `include "tier4c_env.sv"
    `include "tier4d_env.sv"
    `include "cg_csr.sv"
    `include "tier5_env.sv"
    `include "us_host.sv"
    `include "sb_e2e.sv"
    `include "us_msix.sv"
    `include "mqnic_drv.sv"
    `include "tier6_env.sv"
    `include "tier1a_env.sv"

endpackage : mqnic_env_pkg

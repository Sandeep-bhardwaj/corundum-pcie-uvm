// SPDX-License-Identifier: BSD-2-Clause-Views
//
// mqnic_test_pkg - test library package
//
// Implements : VERIFICATION_STRATEGY.md  §13 (test plan)
// Introduced : Step 0 (infrastructure)
//
// Compile order: ... -> mqnic_seq_pkg -> mqnic_env_pkg -> mqnic_test_pkg
//
// Step 0 contains the base test only. Tier test suites are added from Step 1
// onward, one `include per tier directory.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

package mqnic_test_pkg;

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
    import mqnic_env_pkg::*;

    `include "mqnic_base_test.sv"
    `include "tier1a_tests.sv"
    `include "tier1a_tests2.sv"
    `include "tier1c_tests.sv"
    `include "tier1b_tests.sv"
    `include "tier2_tests.sv"
    `include "tier3_tests.sv"
    `include "tier3b_tests.sv"
    `include "tier3c_tests.sv"
    `include "tier4a_tests.sv"
    `include "tier4b_tests.sv"
    `include "tier4c_tests.sv"
    `include "tier4d_tests.sv"
    `include "tier5_tests.sv"
    `include "tier5_tests2.sv"
    `include "tier6_tests.sv"
    `include "tier6_e2e_tests.sv"
    `include "tier6_msix_tests.sv"

endpackage : mqnic_test_pkg

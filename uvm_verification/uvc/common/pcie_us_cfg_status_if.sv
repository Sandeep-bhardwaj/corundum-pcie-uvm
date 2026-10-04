// SPDX-License-Identifier: BSD-2-Clause-Views
//
// pcie_us_cfg_status_if - the values pcie_us_cfg extracts from config space
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §13 Tier 4
// Introduced : Tier 4d (pcie_us_if)
//
// WHY AN INTERFACE FOR THREE PINS
// -------------------------------
// These are static status outputs, not a transaction stream, so the obvious
// thing is to read them straight out of the testbench hierarchy from the test:
//
//     if (tb_top_tier4d.max_payload_size !== ...)      // ILLEGAL
//
// That does not compile. Tests live in a PACKAGE, and IEEE 1800 forbids a
// hierarchical reference from inside one - for good reason, since it would bind
// the package to one particular testbench instance and make it unreusable at
// the next tier. An interface published through the config DB is the same
// mechanism every other signal in this environment already uses.
//
// The interface also carries the CONFIG-SPACE VALUE THE TESTBENCH RETURNS, so a
// test can sweep it. Keeping the stimulus and the response side by side is
// deliberate: the check is "what the TB said" against "what the DUT extracted",
// and splitting those across two files is how they drift.
//
// WHAT THESE THREE VALUES ARE FOR
// -------------------------------
// pcie_us_cfg.v:121-123 reads them out of the Device Control register:
//
//     ext_tag_enable        <- cfg_mgmt_read_data[8]
//     max_read_request_size <- cfg_mgmt_read_data[14:12]
//     max_payload_size      <- cfg_mgmt_read_data[7:5]
//
// MPS and MRRS are the inputs to the DMA split rules verified at Tier 3 against
// ~390k cases. Tier 3 is HANDED those limits, so it cannot see them being read
// from the wrong bits. This interface exists so that seam can be checked.
// -----------------------------------------------------------------------------

`ifndef PCIE_US_CFG_STATUS_IF_SV
`define PCIE_US_CFG_STATUS_IF_SV

`timescale 1ns / 1ps

interface pcie_us_cfg_status_if (input logic clk, input logic rst);

    // Driven by the DUT.
    logic [2:0] max_payload_size;
    logic [2:0] max_read_request_size;
    logic       ext_tag_enable;

    // Driven by the testbench - the Device Control value returned to the DUT's
    // config-management polling loop.
    logic [31:0] dev_ctrl_value;

    // Build a Device Control value from the three fields, so no test has to
    // remember the bit positions.
    function automatic void set_dev_ctrl(input logic [2:0] mps,
                                         input logic [2:0] mrrs,
                                         input logic       ext_tag);
        dev_ctrl_value = (32'(mrrs) << 12) | (32'(ext_tag) << 8) | (32'(mps) << 5);
    endfunction

    // True when the DUT has extracted exactly what the testbench is offering.
    // NOT named `matches`: that is a SystemVerilog keyword (case ... matches)
    // and using it produces a parse error several lines away from the cause.
    function automatic bit is_extracted(input logic [2:0] mps,
                                   input logic [2:0] mrrs,
                                   input logic       ext_tag);
        return (max_payload_size      === mps)
            && (max_read_request_size === mrrs)
            && (ext_tag_enable        === ext_tag);
    endfunction

endinterface : pcie_us_cfg_status_if

`endif // PCIE_US_CFG_STATUS_IF_SV

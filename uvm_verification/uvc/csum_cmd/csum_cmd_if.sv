// SPDX-License-Identifier: BSD-2-Clause-Views
//
// csum_cmd_if - tx_checksum command interface
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.3 (Tier 1c offloads)
// Introduced : Step 3 (Tier 1c), when tx_checksum was wired in
//
// tx_checksum takes one command per packet on a simple valid/ready channel
// (tx_checksum.v s_axis_cmd_*). It is small and DUT-specific, so it gets a
// minimal UVC rather than being forced into axis_agent.
// -----------------------------------------------------------------------------

`ifndef CSUM_CMD_IF_SV
`define CSUM_CMD_IF_SV

`timescale 1ns / 1ps

interface csum_cmd_if (input logic clk, input logic rst);

    logic        csum_enable;
    logic [7:0]  csum_start;
    logic [7:0]  csum_offset;
    logic [15:0] csum_init;
    logic        valid;
    logic        ready;

    clocking drv_cb @(posedge clk);
        default input #1step output #1ns;
        output csum_enable, csum_start, csum_offset, csum_init, valid;
        input  ready;
    endclocking

    clocking mon_cb @(posedge clk);
        default input #1step;
        input csum_enable, csum_start, csum_offset, csum_init, valid, ready;
    endclocking

    modport drv (clocking drv_cb, input clk, input rst);
    modport mon (clocking mon_cb, input clk, input rst);

`ifndef CSUM_CMD_IF_NO_SVA
`ifndef MQNIC_NO_SVA
    // synopsys translate_off
    default clocking mon_cb;
    // `default disable iff (rst)` is written out on each assertion below:
    // Vivado xsim cannot simulate the default form (XSIM 43-3980), and the
    // explicit form is identical in meaning (IEEE 1800-2017 16.15).

    a_valid_stable : assert property (disable iff (rst) valid && !ready |=> valid)
        else $error("CSUM_CMD: valid deasserted before ready");
    a_payload_stable : assert property (disable iff (rst)
        valid && !ready |=> $stable({csum_enable, csum_start, csum_offset, csum_init})
    ) else $error("CSUM_CMD: command changed while valid && !ready");
    // synopsys translate_on
`endif // MQNIC_NO_SVA
`endif // CSUM_CMD_IF_NO_SVA

endinterface : csum_cmd_if

`endif // CSUM_CMD_IF_SV

// SPDX-License-Identifier: BSD-2-Clause-Views
//
// pcie_us_msix_if - the UltraScale hard IP's MSI-X interrupt interface
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §1 G7
// Introduced : G7 MSI-X
//
// On UltraScale the DUT does not put an MSI-X write on RQ. pcie_us_if hands the
// message to the hard IP - cfg_interrupt_msix_int with address and data - and
// waits for cfg_interrupt_msix_sent or _fail before taking the next one
// (pcie_us_if.v:573-610). The hard IP sends the write itself. This interface
// carries both halves; us_msix_hip plays the hard IP.
//
// enable/mask are the function's MSI-X Enable and Function Mask bits from
// configuration space, which the hard IP reflects onto
// cfg_interrupt_msix_enable/mask (pcie_us_if.v:564-565). Bit 0 is PF0.
// -----------------------------------------------------------------------------

`ifndef PCIE_US_MSIX_IF_SV
`define PCIE_US_MSIX_IF_SV

`timescale 1ns / 1ps

interface pcie_us_msix_if (input logic clk, input logic rst);

    // Testbench (hard IP / config space) -> DUT
    logic [3:0]  enable;
    logic [3:0]  mask;
    logic        sent;
    logic        fail;

    // DUT -> hard IP
    logic        int_req;          // cfg_interrupt_msix_int
    logic [63:0] address;
    logic [31:0] data;
    logic [7:0]  function_number;  // cfg_interrupt_msi_function_number

    initial begin
        enable = '0;
        mask   = '0;
        sent   = 1'b0;
        fail   = 1'b0;
    end

endinterface : pcie_us_msix_if

`endif // PCIE_US_MSIX_IF_SV

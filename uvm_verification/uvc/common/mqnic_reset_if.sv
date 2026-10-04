// SPDX-License-Identifier: BSD-2-Clause-Views
//
// mqnic_reset_if
// -----------------------------------------------------------------------------
// Clock-referenced reset driver interface.
//
// Implements : VERIFICATION_STRATEGY.md  §4.3 rule 6 - "reset is a sequence,
//                                        not an initial block", which is what
//                                        makes t6_reset_inflight possible.
// Introduced : Step 0 (infrastructure)
//
// Corundum uses ACTIVE HIGH synchronous resets named `rst` throughout
// (see fpga/common/rtl/queue_manager.v:48). The tasks below assert
// asynchronously and deassert synchronously to the driving clock, which is the
// standard safe pattern and matches how the RTL is used on real boards.
//
// The interface is deliberately UVM-free so it elaborates standalone.
// -----------------------------------------------------------------------------

`ifndef MQNIC_RESET_IF_SV
`define MQNIC_RESET_IF_SV

`timescale 1ns / 1ps

interface mqnic_reset_if (input logic clk);

    // Active-high reset driven to the DUT
    logic rst;

    // Set once the first reset sequence has completed. Components may wait on
    // this rather than guessing a delay.
    bit   reset_done;

    initial begin
        rst        = 1'b1;
        reset_done = 1'b0;
    end

    // -------------------------------------------------------------------------
    // Assert reset immediately (asynchronous assertion).
    // -------------------------------------------------------------------------
    task automatic assert_reset();
        rst        <= 1'b1;
        reset_done  = 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // Deassert reset on a clock edge (synchronous deassertion).
    // -------------------------------------------------------------------------
    task automatic deassert_reset();
        @(posedge clk);
        rst        <= 1'b0;
        @(posedge clk);
        reset_done  = 1'b1;
    endtask

    // -------------------------------------------------------------------------
    // Standard power-on reset: hold for `cycles` clocks, then release.
    // -------------------------------------------------------------------------
    task automatic pulse_reset(int cycles = 10);
        assert_reset();
        repeat (cycles) @(posedge clk);
        deassert_reset();
    endtask

    // -------------------------------------------------------------------------
    // Power-on reset for designs built from `always @*` + un-initialised *_next
    // regs (the Forencich AXI/AXI-Lite library inside mqnic_core): assert,
    // release, RE-ASSERT, release.
    //
    // `always @*` waits for an event before it first runs, so in a quiescent
    // design x_next stays X while reset holds x_reg at 0, and a single release
    // latches that X into x_reg for good. The first release is the event that
    // wakes the block; the re-assert then recomputes x_next from a known 0.
    // Same fix as pyuvm/tieoff.py power_on_reset() - bug 31 in bringup_log.md.
    // -------------------------------------------------------------------------
    task automatic pulse_reset_x_safe(int cycles = 10);
        pulse_reset(cycles);
        repeat (4) @(posedge clk);
        pulse_reset(cycles);
    endtask

    // -------------------------------------------------------------------------
    // Mid-test reset. Identical timing to pulse_reset but named separately so
    // reset-in-flight tests read clearly and so a waveform reviewer can tell
    // the two apart from the call stack.
    // -------------------------------------------------------------------------
    task automatic inject_reset(int cycles = 5);
        pulse_reset(cycles);
    endtask

    // -------------------------------------------------------------------------
    // Block until the DUT is out of reset.
    // -------------------------------------------------------------------------
    task automatic wait_out_of_reset();
        while (rst === 1'b1) @(posedge clk);
        @(posedge clk);
    endtask

    // -------------------------------------------------------------------------
    // Block for a number of clocks. Convenience for sequences that need to
    // pace themselves without owning a clock handle.
    // -------------------------------------------------------------------------
    task automatic wait_clks(int n = 1);
        repeat (n) @(posedge clk);
    endtask

endinterface : mqnic_reset_if

`endif // MQNIC_RESET_IF_SV

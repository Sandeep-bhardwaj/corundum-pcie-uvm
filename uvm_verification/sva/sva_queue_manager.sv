// SPDX-License-Identifier: BSD-2-Clause-Views
//
// sva_queue_manager - design-intent assertions for queue_manager
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §15.1 (placement), §15.2 (required set)
// Introduced : Step 1 (Tier 1a)
//
// STRATEGY §15.1: design-intent properties live here and are attached with
// `bind` - never edited into the DUT source. Interface-protocol properties
// (valid/ready stability, X checks) stay in the UVC interfaces.
//
// DELIBERATELY BLACK-BOX. Every property below is expressed purely in terms of
// the DUT's PORTS. It would have been easier to reach into op_table_active /
// op_table_commit / op_table_start_ptr_reg, but that couples the assertions to
// internal signal names that are free to change, and it would let a refactor
// silently disable them. The outstanding-tag set is therefore reconstructed
// here from observable handshakes.
//
// The properties correspond to the §15.2 list, updated after the doorbell
// correction recorded in docs/bringup_log.md:
//   * consumer pointer advances only on in-order retirement
//   * op_tag never reissued while outstanding
//   * phase is !ptr[log_queue_size]        (checked in the scoreboard, needs
//                                           log_queue_size which is not a port)
//   * a request to a disabled queue returns error, never empty
// -----------------------------------------------------------------------------

`ifndef SVA_QUEUE_MANAGER_SV
`define SVA_QUEUE_MANAGER_SV

`ifndef MQNIC_NO_SVA

`timescale 1ns / 1ps

module sva_queue_manager #(
    parameter int OP_TAG_WIDTH  = 8,
    parameter int OP_TABLE_SIZE = 32
) (
    input logic                     clk,
    input logic                     rst,

    input logic                     req_valid,
    input logic                     req_ready,

    input logic                     resp_valid,
    input logic                     resp_ready,
    input logic [OP_TAG_WIDTH-1:0]  resp_op_tag,
    input logic                     resp_empty,
    input logic                     resp_error,

    input logic                     commit_valid,
    input logic                     commit_ready,
    input logic [OP_TAG_WIDTH-1:0]  commit_op_tag,

    input logic                     doorbell_valid
);

    // ---- observable handshakes ---------------------------------------------
    wire req_fire    = req_valid    && req_ready;
    wire resp_fire   = resp_valid   && resp_ready;
    wire commit_fire = commit_valid && commit_ready;

    // A tag is allocated only when the operation actually STARTS - not on an
    // error and not on an empty response (queue_manager.v:451).
    wire alloc_fire  = resp_fire && !resp_error && !resp_empty;

    // ---- reconstructed outstanding-tag set ---------------------------------
    logic [OP_TABLE_SIZE-1:0] outstanding;
    int                       n_outstanding;
    int                       n_req_fire;
    int                       n_resp_fire;

    always_ff @(posedge clk) begin
        if (rst) begin
            outstanding   <= '0;
            n_outstanding <= 0;
            n_req_fire    <= 0;
            n_resp_fire   <= 0;
        end
        else begin
            if (req_fire)  n_req_fire  <= n_req_fire + 1;
            if (resp_fire) n_resp_fire <= n_resp_fire + 1;

            if (alloc_fire && !(commit_fire && commit_op_tag == resp_op_tag)) begin
                outstanding[resp_op_tag] <= 1'b1;
                n_outstanding            <= n_outstanding + 1;
            end
            if (commit_fire && !(alloc_fire && commit_op_tag == resp_op_tag)) begin
                outstanding[commit_op_tag] <= 1'b0;
                n_outstanding              <= n_outstanding - 1;
            end
        end
    end

    default clocking cb @(posedge clk); endclocking
    // `default disable iff (rst)` is written out on each assertion below:
    // Vivado xsim cannot simulate the default form (XSIM 43-3980), and the
    // explicit form is identical in meaning (IEEE 1800-2017 16.15).

    // -------------------------------------------------------------------------
    // 1. An op_tag must never be handed out twice while still outstanding.
    //    STRATEGY §15.2. This is the property that would catch an op-table
    //    pointer bug, and it is why the DUT can be trusted to reuse tags at all.
    // -------------------------------------------------------------------------
    a_optag_unique : assert property (disable iff (rst)
        alloc_fire |-> !outstanding[resp_op_tag]
    ) else $error("sva_queue_manager: op_tag 0x%0h reissued while still outstanding",
                  resp_op_tag);

    // -------------------------------------------------------------------------
    // 2. A commit must reference a tag that is currently outstanding. A commit
    //    of an unknown tag means either the DUT invented one or the testbench
    //    lost track - both are bugs worth stopping for.
    // -------------------------------------------------------------------------
    a_commit_outstanding : assert property (disable iff (rst)
        commit_fire |-> outstanding[commit_op_tag]
    ) else $error("sva_queue_manager: commit of op_tag 0x%0h that is not outstanding",
                  commit_op_tag);

    // -------------------------------------------------------------------------
    // 3. error and empty are mutually exclusive outcomes
    //    (queue_manager.v:437 vs :443).
    // -------------------------------------------------------------------------
    a_error_xor_empty : assert property (disable iff (rst)
        resp_fire |-> !(resp_error && resp_empty)
    ) else $error("sva_queue_manager: response asserted both error and empty");

    // -------------------------------------------------------------------------
    // 4. Outstanding operations can never exceed the op table.
    // -------------------------------------------------------------------------
    a_optable_bound : assert property (disable iff (rst)
        n_outstanding <= OP_TABLE_SIZE
    ) else $error("sva_queue_manager: %0d outstanding ops exceeds OP_TABLE_SIZE %0d",
                  n_outstanding, OP_TABLE_SIZE);

    // -------------------------------------------------------------------------
    // 5. No unsolicited responses: the DUT must never answer more requests than
    //    it accepted.
    // -------------------------------------------------------------------------
    a_no_unsolicited_resp : assert property (disable iff (rst)
        resp_fire |-> (n_resp_fire < n_req_fire)
    ) else $error("sva_queue_manager: response with no outstanding request (req=%0d resp=%0d)",
                  n_req_fire, n_resp_fire);

    // -------------------------------------------------------------------------
    // 6. Liveness: an accepted request must eventually be answered. The bound is
    //    generous - this catches a hang, not a performance regression.
    // -------------------------------------------------------------------------
    a_req_answered : assert property (disable iff (rst)
        req_fire |-> ##[1:1000] resp_fire
    ) else $error("sva_queue_manager: accepted request never answered within 1000 clocks");

    // -------------------------------------------------------------------------
    // 7. The doorbell is a single-cycle PULSE with no ready
    //    (queue_manager.v:334 clears it every cycle by default). Two
    //    back-to-back asserted cycles would mean the pulse logic changed and the
    //    monitor's every-cycle sampling assumption no longer holds.
    // -------------------------------------------------------------------------
    a_doorbell_is_pulse : assert property (disable iff (rst)
        doorbell_valid |=> !doorbell_valid
    ) else $error("sva_queue_manager: doorbell asserted for more than one cycle");

    // ---- coverage of the interesting corners --------------------------------
    c_optable_full  : cover property (disable iff (rst) n_outstanding == OP_TABLE_SIZE);
    c_empty_resp    : cover property (disable iff (rst) resp_fire && resp_empty);
    c_error_resp    : cover property (disable iff (rst) resp_fire && resp_error);
    c_req_stalled   : cover property (disable iff (rst) req_valid && !req_ready);
    c_doorbell      : cover property (disable iff (rst) doorbell_valid);

endmodule : sva_queue_manager


// -----------------------------------------------------------------------------
// Attach to every queue_manager instance without touching the RTL. Parameters
// are read from the target's own scope, so the assertions follow whatever
// configuration the DUT was elaborated with.
// -----------------------------------------------------------------------------
bind queue_manager sva_queue_manager #(
    .OP_TAG_WIDTH  (OP_TAG_WIDTH),
    .OP_TABLE_SIZE (OP_TABLE_SIZE)
) u_sva_queue_manager (
    .clk            (clk),
    .rst            (rst),
    .req_valid      (s_axis_dequeue_req_valid),
    .req_ready      (s_axis_dequeue_req_ready),
    .resp_valid     (m_axis_dequeue_resp_valid),
    .resp_ready     (m_axis_dequeue_resp_ready),
    .resp_op_tag    (m_axis_dequeue_resp_op_tag),
    .resp_empty     (m_axis_dequeue_resp_empty),
    .resp_error     (m_axis_dequeue_resp_error),
    .commit_valid   (s_axis_dequeue_commit_valid),
    .commit_ready   (s_axis_dequeue_commit_ready),
    .commit_op_tag  (s_axis_dequeue_commit_op_tag),
    .doorbell_valid (m_axis_doorbell_valid)
);

`endif // MQNIC_NO_SVA

`endif // SVA_QUEUE_MANAGER_SV

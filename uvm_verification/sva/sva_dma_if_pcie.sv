// SPDX-License-Identifier: BSD-2-Clause-Views
//
// sva_dma_if_pcie - design-intent assertions for dma_if_pcie_rd
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §15.1 (placement), §15.2 (required set)
// Introduced : Step 5 (Tier 3)
//
// BLACK-BOX, like sva_queue_manager. Every property is expressed in terms of the
// DUT's ports; nothing reaches into the op table or the tag allocator. Reaching
// in is easier but couples the assertions to internal names, and a refactor then
// disables them silently.
//
// These duplicate some of what sb_dma checks, deliberately. The scoreboard
// reports with full context and can be disabled per test; the assertions fire at
// the exact cycle and survive with `+define+`-free default builds. When a run
// fails, having both is what distinguishes "the model is wrong" from "the DUT is
// wrong" - if the assertion is silent and only the scoreboard complains, suspect
// the model first.
//
// §15.2 required set for this DUT:
//   * every issued descriptor eventually produces exactly one status
//   * status_error != 0 implies a non-successful completion was seen
//   * no RAM write command without a corresponding completion
// -----------------------------------------------------------------------------

`ifndef SVA_DMA_IF_PCIE_SV
`define SVA_DMA_IF_PCIE_SV

`ifndef MQNIC_NO_SVA

`timescale 1ns / 1ps

module sva_dma_if_pcie #(
    parameter int TAG_WIDTH  = 8,
    parameter int LEN_WIDTH  = 16,
    parameter int RAM_SEG_COUNT = 2
) (
    input logic                     clk,
    input logic                     rst,

    input logic                     desc_valid,
    input logic                     desc_ready,
    input logic [TAG_WIDTH-1:0]     desc_tag,
    input logic [LEN_WIDTH-1:0]     desc_len,

    input logic                     sts_valid,
    input logic [TAG_WIDTH-1:0]     sts_tag,
    input logic [3:0]               sts_error,

    input logic                     rd_req_valid,
    input logic                     rd_req_ready,
    input logic                     rd_req_sop,
    input logic                     rd_req_eop,

    input logic                     cpl_valid,
    input logic                     cpl_ready,
    input logic [3:0]               cpl_error,

    input logic [RAM_SEG_COUNT-1:0] ram_wr_valid,
    input logic [RAM_SEG_COUNT-1:0] ram_wr_ready
);

    wire desc_fire   = desc_valid   && desc_ready;
    wire req_fire    = rd_req_valid && rd_req_ready;
    wire cpl_fire    = cpl_valid    && cpl_ready;

    // ---- reconstructed state, from ports only -------------------------------
    int n_desc;
    int n_sts;
    int n_req;
    int n_cpl;
    int n_ram_wr;
    int n_err_cpl;

    always_ff @(posedge clk) begin
        if (rst) begin
            n_desc <= 0; n_sts <= 0; n_req <= 0;
            n_cpl  <= 0; n_ram_wr <= 0; n_err_cpl <= 0;
        end
        else begin
            if (desc_fire) n_desc <= n_desc + 1;
            if (sts_valid) n_sts  <= n_sts + 1;
            if (req_fire && rd_req_sop) n_req <= n_req + 1;
            if (cpl_fire) begin
                n_cpl <= n_cpl + 1;
                if (cpl_error != 4'd0) n_err_cpl <= n_err_cpl + 1;
            end
            for (int s = 0; s < RAM_SEG_COUNT; s++)
                if (ram_wr_valid[s] && ram_wr_ready[s]) n_ram_wr <= n_ram_wr + 1;
        end
    end

    // -------------------------------------------------------------------------
    // LIVENESS SWITCH.
    //
    // "Every descriptor is eventually answered" is only true when completions
    // eventually arrive. dma_if_pcie_rd has NO internal completion timer - a
    // withheld completion strands the request forever, and that is correct
    // behaviour, not a bug. t3_cpl_dropped exercises exactly that, so the two
    // eventuality properties below have to be switchable off.
    //
    // A plusarg rather than a parameter because the bind is elaborated once for
    // every test, and rather than a UVM field because an SVA module is not
    // reachable from the class hierarchy. Run with +MQNIC_NO_LIVENESS.
    // -------------------------------------------------------------------------
    bit liveness_en = 1'b1;
    initial if ($test$plusargs("MQNIC_NO_LIVENESS")) liveness_en = 1'b0;

    default clocking cb @(posedge clk); endclocking
    // `default disable iff (rst)` is written out on each assertion below:
    // Vivado xsim cannot simulate the default form (XSIM 43-3980), and the
    // explicit form is identical in meaning (IEEE 1800-2017 16.15).

    // -------------------------------------------------------------------------
    // 1. Never more statuses than descriptors. One descriptor produces exactly
    //    one status; an extra means a spurious completion of work never asked
    //    for.
    // -------------------------------------------------------------------------
    a_sts_le_desc : assert property (disable iff (rst)
        sts_valid |-> (n_sts < n_desc)
    ) else $error("sva_dma_if_pcie: status with no outstanding descriptor (desc=%0d sts=%0d)",
                  n_desc, n_sts);

    // -------------------------------------------------------------------------
    // 2. A descriptor with non-zero length must produce at least one read
    //    request. A DUT that returned status without fetching anything would
    //    otherwise look like a fast, correct DMA.
    // -------------------------------------------------------------------------
    //    The window is wide because it is not a performance bound: under tag
    //    exhaustion the DUT legitimately waits for a tag to come free before it
    //    can issue anything, and that wait scales with completion latency.
    a_desc_causes_request : assert property (
        disable iff (rst || !liveness_en)
        (desc_fire && desc_len != 0) |-> ##[1:100000] (req_fire && rd_req_sop)
    ) else $error("sva_dma_if_pcie: descriptor of %0d bytes produced no read request",
                  desc_len);

    // -------------------------------------------------------------------------
    // 3. No RAM write before any completion has arrived. Data has to come from
    //    somewhere; writing first means the DUT invented it.
    // -------------------------------------------------------------------------
    a_ram_needs_cpl : assert property (disable iff (rst)
        (|(ram_wr_valid & ram_wr_ready)) |-> (n_cpl > 0)
    ) else $error("sva_dma_if_pcie: RAM write before any completion was received");

    // -------------------------------------------------------------------------
    // 4. status_error != 0 must be explainable by a completion that carried an
    //    error. §15.2.
    // -------------------------------------------------------------------------
    a_error_has_cause : assert property (disable iff (rst)
        (sts_valid && sts_error != 4'd0) |-> (n_err_cpl > 0)
    ) else $error("sva_dma_if_pcie: status reports error %0d but no errored completion was seen",
                  sts_error);

    // -------------------------------------------------------------------------
    // 5. TLP framing on the request channel: eop only inside a packet.
    // -------------------------------------------------------------------------
    a_req_framing : assert property (disable iff (rst)
        (req_fire && rd_req_eop && !rd_req_sop) |-> $past(rd_req_valid)
    ) else $error("sva_dma_if_pcie: read request eop with no preceding sop");

    // -------------------------------------------------------------------------
    // 6. Liveness: every descriptor is eventually answered.
    // -------------------------------------------------------------------------
    a_desc_answered : assert property (
        disable iff (rst || !liveness_en)
        desc_fire |-> ##[1:200000] sts_valid
    ) else $error("sva_dma_if_pcie: descriptor never produced a status within 200000 clocks");

    // ---- coverage of the corners --------------------------------------------
    c_multi_request : cover property (disable iff (rst) req_fire && rd_req_sop && n_req > 0);
    c_err_cpl       : cover property (disable iff (rst) cpl_fire && cpl_error != 4'd0);
    c_err_status    : cover property (disable iff (rst) sts_valid && sts_error != 4'd0);
    c_req_stalled   : cover property (disable iff (rst) rd_req_valid && !rd_req_ready);
    c_cpl_stalled   : cover property (disable iff (rst) cpl_valid && !cpl_ready);

endmodule : sva_dma_if_pcie


bind dma_if_pcie_rd sva_dma_if_pcie #(
    .TAG_WIDTH     (TAG_WIDTH),
    .LEN_WIDTH     (LEN_WIDTH),
    .RAM_SEG_COUNT (RAM_SEG_COUNT)
) u_sva_dma_if_pcie (
    .clk          (clk),
    .rst          (rst),
    .desc_valid   (s_axis_read_desc_valid),
    .desc_ready   (s_axis_read_desc_ready),
    .desc_tag     (s_axis_read_desc_tag),
    .desc_len     (s_axis_read_desc_len),
    .sts_valid    (m_axis_read_desc_status_valid),
    .sts_tag      (m_axis_read_desc_status_tag),
    .sts_error    (m_axis_read_desc_status_error),
    .rd_req_valid (tx_rd_req_tlp_valid),
    .rd_req_ready (tx_rd_req_tlp_ready),
    .rd_req_sop   (tx_rd_req_tlp_sop),
    .rd_req_eop   (tx_rd_req_tlp_eop),
    .cpl_valid    (rx_cpl_tlp_valid),
    .cpl_ready    (rx_cpl_tlp_ready),
    .cpl_error    (rx_cpl_tlp_error),
    .ram_wr_valid (ram_wr_cmd_valid),
    .ram_wr_ready (ram_wr_cmd_ready)
);

`endif // MQNIC_NO_SVA

`endif // SVA_DMA_IF_PCIE_SV

// SPDX-License-Identifier: BSD-2-Clause-Views
//
// sva_dma_if_pcie_wr - design-intent assertions for dma_if_pcie_wr
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §15.1 (placement), §15.2 (required set)
// Introduced : Step 5 (Tier 3b)
//
// BLACK-BOX, expressed only in terms of the DUT's ports - the same discipline
// as sva_dma_if_pcie and sva_queue_manager.
//
// The required set differs from the read side because the direction differs. A
// posted write gets no completion, so there is no reassembly to check and no
// error status to explain. What matters here is that the engine does not invent
// traffic and does not lose a descriptor:
//
//   * every descriptor produces exactly one status
//   * a non-immediate descriptor with data must read RAM before it can send
//   * a write TLP must carry payload (strb non-zero on the first beat)
// -----------------------------------------------------------------------------

`ifndef SVA_DMA_IF_PCIE_WR_SV
`define SVA_DMA_IF_PCIE_WR_SV

`ifndef MQNIC_NO_SVA

`timescale 1ns / 1ps

module sva_dma_if_pcie_wr #(
    parameter int TAG_WIDTH     = 8,
    parameter int LEN_WIDTH     = 16,
    parameter int RAM_SEG_COUNT = 2,
    parameter int TLP_STRB_WIDTH = 8
) (
    input logic                       clk,
    input logic                       rst,

    input logic                       desc_valid,
    input logic                       desc_ready,
    input logic [TAG_WIDTH-1:0]       desc_tag,
    input logic [LEN_WIDTH-1:0]       desc_len,
    input logic                       desc_imm_en,

    input logic                       sts_valid,
    input logic [TAG_WIDTH-1:0]       sts_tag,
    input logic [3:0]                 sts_error,

    input logic                       wr_req_valid,
    input logic                       wr_req_ready,
    input logic                       wr_req_sop,
    input logic                       wr_req_eop,
    input logic [TLP_STRB_WIDTH-1:0]  wr_req_strb,

    input logic [RAM_SEG_COUNT-1:0]   ram_rd_cmd_valid,
    input logic [RAM_SEG_COUNT-1:0]   ram_rd_cmd_ready,
    input logic [RAM_SEG_COUNT-1:0]   ram_rd_resp_valid,
    input logic [RAM_SEG_COUNT-1:0]   ram_rd_resp_ready
);

    wire desc_fire = desc_valid   && desc_ready;
    wire req_fire  = wr_req_valid && wr_req_ready;

    int n_desc;
    int n_sts;
    int n_req;
    int n_ram_rd;
    int n_ram_data;

    always_ff @(posedge clk) begin
        if (rst) begin
            n_desc <= 0; n_sts <= 0; n_req <= 0;
            n_ram_rd <= 0; n_ram_data <= 0;
        end
        else begin
            if (desc_fire) n_desc <= n_desc + 1;
            if (sts_valid) n_sts  <= n_sts + 1;
            if (req_fire && wr_req_sop) n_req <= n_req + 1;
            for (int s = 0; s < RAM_SEG_COUNT; s++) begin
                if (ram_rd_cmd_valid[s]  && ram_rd_cmd_ready[s])  n_ram_rd   <= n_ram_rd + 1;
                if (ram_rd_resp_valid[s] && ram_rd_resp_ready[s]) n_ram_data <= n_ram_data + 1;
            end
        end
    end

    // See sva_dma_if_pcie for why this is a plusarg rather than a parameter.
    bit liveness_en = 1'b1;
    initial if ($test$plusargs("MQNIC_NO_LIVENESS")) liveness_en = 1'b0;

    default clocking cb @(posedge clk); endclocking
    // `default disable iff (rst)` is written out on each assertion below:
    // Vivado xsim cannot simulate the default form (XSIM 43-3980), and the
    // explicit form is identical in meaning (IEEE 1800-2017 16.15).

    // -------------------------------------------------------------------------
    // 1. Never more statuses than descriptors.
    // -------------------------------------------------------------------------
    a_sts_le_desc : assert property (disable iff (rst)
        sts_valid |-> (n_sts < n_desc)
    ) else $error("sva_dma_if_pcie_wr: status with no outstanding descriptor (desc=%0d sts=%0d)",
                  n_desc, n_sts);

    // -------------------------------------------------------------------------
    // 2. A descriptor that must fetch from RAM has to actually read it.
    //    Immediate descriptors are excluded - their data comes from the
    //    descriptor, and requiring a read would fail t3b_immediate for doing
    //    exactly what it is supposed to do.
    // -------------------------------------------------------------------------
    a_desc_reads_ram : assert property (
        disable iff (rst || !liveness_en)
        (desc_fire && desc_len != 0 && !desc_imm_en) |->
            ##[1:100000] (|(ram_rd_cmd_valid & ram_rd_cmd_ready))
    ) else $error("sva_dma_if_pcie_wr: descriptor of %0d bytes never read RAM", desc_len);

    // -------------------------------------------------------------------------
    // 3. A write TLP must carry data. A write request with an all-zero strobe
    //    on its first beat is a packet with no payload, which for a posted
    //    memory write means the transfer was lost.
    // -------------------------------------------------------------------------
    a_write_has_payload : assert property (disable iff (rst)
        (req_fire && wr_req_sop) |-> (wr_req_strb != '0)
    ) else $error("sva_dma_if_pcie_wr: write request with an empty strobe");

    // -------------------------------------------------------------------------
    // 4. No TLP before any RAM data has arrived, for the non-immediate path.
    //    Sending first would mean the engine invented the payload.
    // -------------------------------------------------------------------------
    a_tlp_needs_ram_data : assert property (disable iff (rst)
        (req_fire && wr_req_sop && n_ram_rd > 0) |-> (n_ram_data > 0)
    ) else $error("sva_dma_if_pcie_wr: write TLP sent before any RAM data returned");

    // -------------------------------------------------------------------------
    // 5. Liveness: every descriptor is eventually answered.
    // -------------------------------------------------------------------------
    a_desc_answered : assert property (
        disable iff (rst || !liveness_en)
        desc_fire |-> ##[1:200000] sts_valid
    ) else $error("sva_dma_if_pcie_wr: descriptor never produced a status");

    // ---- coverage of the corners --------------------------------------------
    c_multi_request : cover property (disable iff (rst) req_fire && wr_req_sop && n_req > 0);
    c_immediate     : cover property (disable iff (rst) desc_fire && desc_imm_en);
    c_req_stalled   : cover property (disable iff (rst) wr_req_valid && !wr_req_ready);
    c_ram_stalled   : cover property (disable iff (rst) |ram_rd_cmd_valid && !(|ram_rd_cmd_ready));
    c_err_status    : cover property (disable iff (rst) sts_valid && sts_error != 4'd0);

endmodule : sva_dma_if_pcie_wr


bind dma_if_pcie_wr sva_dma_if_pcie_wr #(
    .TAG_WIDTH      (TAG_WIDTH),
    .LEN_WIDTH      (LEN_WIDTH),
    .RAM_SEG_COUNT  (RAM_SEG_COUNT),
    .TLP_STRB_WIDTH (TLP_STRB_WIDTH)
) u_sva_dma_if_pcie_wr (
    .clk               (clk),
    .rst               (rst),
    .desc_valid        (s_axis_write_desc_valid),
    .desc_ready        (s_axis_write_desc_ready),
    .desc_tag          (s_axis_write_desc_tag),
    .desc_len          (s_axis_write_desc_len),
    .desc_imm_en       (s_axis_write_desc_imm_en),
    .sts_valid         (m_axis_write_desc_status_valid),
    .sts_tag           (m_axis_write_desc_status_tag),
    .sts_error         (m_axis_write_desc_status_error),
    .wr_req_valid      (tx_wr_req_tlp_valid),
    .wr_req_ready      (tx_wr_req_tlp_ready),
    .wr_req_sop        (tx_wr_req_tlp_sop),
    .wr_req_eop        (tx_wr_req_tlp_eop),
    .wr_req_strb       (tx_wr_req_tlp_strb),
    .ram_rd_cmd_valid  (ram_rd_cmd_valid),
    .ram_rd_cmd_ready  (ram_rd_cmd_ready),
    .ram_rd_resp_valid (ram_rd_resp_valid),
    .ram_rd_resp_ready (ram_rd_resp_ready)
);

`endif // MQNIC_NO_SVA

`endif // SVA_DMA_IF_PCIE_WR_SV

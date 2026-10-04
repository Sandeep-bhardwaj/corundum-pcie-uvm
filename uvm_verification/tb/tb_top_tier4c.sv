// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tb_top_tier4c - Tier 4c testbench top (pcie_us_if_rq)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §18 Step 6
// Introduced : Step 6 (Tier 4c)
//
// The requester-request shim: TWO generic TLP inputs merged onto one Xilinx RQ
// stream, gated by transmit flow-control credits.
//
// The credits come from pcie_us_fc_if rather than being tied high. Tying them
// high verifies the shim only where flow control never binds, and the fixed
// priority (read over write) means an unstarved run barely exercises the write
// port at all - see ref_rq_arb.
//
// 256-bit, TLP_SEG_COUNT = 1: the configuration Corundum builds, reachable
// because rtl_patched/ floors SEG_SEL_WIDTH (bug 13).
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_top_tier4c;

    import uvm_pkg::*;
`include "uvm_macros.svh"
    import mqnic_vrf_pkg::*;
    import mqnic_test_pkg::*;

    localparam int AXIS_PCIE_DATA_WIDTH    = 256;
    localparam int AXIS_PCIE_KEEP_WIDTH    = AXIS_PCIE_DATA_WIDTH / 32;
    localparam int AXIS_PCIE_RQ_USER_WIDTH = AXIS_PCIE_DATA_WIDTH < 512 ? 62 : 137;
    localparam int RQ_STRADDLE             = AXIS_PCIE_DATA_WIDTH >= 512;
    localparam int RQ_SEQ_NUM_WIDTH        = AXIS_PCIE_RQ_USER_WIDTH == 60 ? 4 : 6;

    localparam int TLP_DATA_WIDTH   = AXIS_PCIE_DATA_WIDTH;
    localparam int TLP_STRB_WIDTH   = TLP_DATA_WIDTH / 32;
    localparam int TLP_HDR_WIDTH    = 128;
    localparam int TLP_SEG_COUNT    = 1;
    localparam int TX_SEQ_NUM_COUNT = AXIS_PCIE_DATA_WIDTH < 512 ? 1 : 2;
    localparam int TX_SEQ_NUM_WIDTH = RQ_SEQ_NUM_WIDTH - 1;

    localparam int TLP_MAX_SEG_COUNT  = 4;
    localparam int TLP_MAX_DATA_WIDTH = 512;
    localparam int TLP_MAX_STRB_WIDTH = 16;

    localparam time CLK_HALF_PERIOD = 2ns;

    logic clk;
    initial clk = 1'b0;
    always #CLK_HALF_PERIOD clk = ~clk;

    mqnic_reset_if rst_if (.clk(clk));
    wire rst = rst_if.rst;

    pcie_tlp_if     rd_tlp_vif  (.clk(clk), .rst(rst));
    pcie_tlp_if     wr_tlp_vif  (.clk(clk), .rst(rst));
    pcie_us_axis_if rq_axis_vif (.clk(clk), .rst(rst));
    pcie_us_fc_if   fc_vif      ();
    initial fc_vif.init_unlimited();

    // ---- DUT-driven nets ------------------------------------------------------
    wire [AXIS_PCIE_DATA_WIDTH-1:0]    d_rq_tdata;
    wire [AXIS_PCIE_KEEP_WIDTH-1:0]    d_rq_tkeep;
    wire                               d_rq_tvalid;
    wire                               d_rq_tlast;
    wire [AXIS_PCIE_RQ_USER_WIDTH-1:0] d_rq_tuser;
    wire                               d_rd_ready;
    wire                               d_wr_ready;

    // ---- DUT ------------------------------------------------------------------
    pcie_us_if_rq #(
        .AXIS_PCIE_DATA_WIDTH    (AXIS_PCIE_DATA_WIDTH),
        .AXIS_PCIE_KEEP_WIDTH    (AXIS_PCIE_KEEP_WIDTH),
        .AXIS_PCIE_RQ_USER_WIDTH (AXIS_PCIE_RQ_USER_WIDTH),
        .RQ_STRADDLE             (RQ_STRADDLE),
        .RQ_SEQ_NUM_WIDTH        (RQ_SEQ_NUM_WIDTH),
        .TLP_DATA_WIDTH          (TLP_DATA_WIDTH),
        .TLP_STRB_WIDTH          (TLP_STRB_WIDTH),
        .TLP_HDR_WIDTH           (TLP_HDR_WIDTH),
        .TLP_SEG_COUNT           (TLP_SEG_COUNT),
        .TX_SEQ_NUM_COUNT        (TX_SEQ_NUM_COUNT),
        .TX_SEQ_NUM_WIDTH        (TX_SEQ_NUM_WIDTH)
    ) u_pcie_us_if_rq (
        .clk (clk),
        .rst (rst),

        .m_axis_rq_tdata  (d_rq_tdata),
        .m_axis_rq_tkeep  (d_rq_tkeep),
        .m_axis_rq_tvalid (d_rq_tvalid),
        .m_axis_rq_tready (rq_axis_vif.tready),
        .m_axis_rq_tlast  (d_rq_tlast),
        .m_axis_rq_tuser  (d_rq_tuser),

        .s_axis_rq_seq_num_0       ('0),
        .s_axis_rq_seq_num_valid_0 ('0),
        .s_axis_rq_seq_num_1       ('0),
        .s_axis_rq_seq_num_valid_1 ('0),

        // read requests - non-posted, port 0, higher priority
        .tx_rd_req_tlp_hdr   (rd_tlp_vif.tlp_hdr[TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]),
        .tx_rd_req_tlp_seq   (rd_tlp_vif.tlp_seq[TLP_SEG_COUNT*TX_SEQ_NUM_WIDTH-1:0]),
        .tx_rd_req_tlp_valid (rd_tlp_vif.tlp_valid[TLP_SEG_COUNT-1:0]),
        .tx_rd_req_tlp_sop   (rd_tlp_vif.tlp_sop[TLP_SEG_COUNT-1:0]),
        .tx_rd_req_tlp_eop   (rd_tlp_vif.tlp_eop[TLP_SEG_COUNT-1:0]),
        .tx_rd_req_tlp_ready (d_rd_ready),

        .m_axis_rd_req_tx_seq_num       (),
        .m_axis_rd_req_tx_seq_num_valid (),

        // write requests - posted, port 1
        .tx_wr_req_tlp_data  (wr_tlp_vif.tlp_data[TLP_DATA_WIDTH-1:0]),
        .tx_wr_req_tlp_strb  (wr_tlp_vif.tlp_strb[TLP_STRB_WIDTH-1:0]),
        .tx_wr_req_tlp_hdr   (wr_tlp_vif.tlp_hdr[TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]),
        .tx_wr_req_tlp_seq   (wr_tlp_vif.tlp_seq[TLP_SEG_COUNT*TX_SEQ_NUM_WIDTH-1:0]),
        .tx_wr_req_tlp_valid (wr_tlp_vif.tlp_valid[TLP_SEG_COUNT-1:0]),
        .tx_wr_req_tlp_sop   (wr_tlp_vif.tlp_sop[TLP_SEG_COUNT-1:0]),
        .tx_wr_req_tlp_eop   (wr_tlp_vif.tlp_eop[TLP_SEG_COUNT-1:0]),
        .tx_wr_req_tlp_ready (d_wr_ready),

        .m_axis_wr_req_tx_seq_num       (),
        .m_axis_wr_req_tx_seq_num_valid (),

        .tx_fc_ph_av  (fc_vif.tx_fc_ph_av),
        .tx_fc_pd_av  (fc_vif.tx_fc_pd_av),
        .tx_fc_nph_av (fc_vif.tx_fc_nph_av),
        .tx_fc_npd_av (fc_vif.tx_fc_npd_av),

        .max_payload_size (3'd1)
    );

    // ---- DUT outputs -> interfaces --------------------------------------------
    assign rd_tlp_vif.tlp_ready = d_rd_ready;
    assign wr_tlp_vif.tlp_ready = d_wr_ready;

    assign rq_axis_vif.tdata =
        {{(mqnic_vrf_pkg::US_MAX_DATA_WIDTH-AXIS_PCIE_DATA_WIDTH){1'b0}}, d_rq_tdata};
    assign rq_axis_vif.tkeep =
        {{(mqnic_vrf_pkg::US_MAX_KEEP_WIDTH-AXIS_PCIE_KEEP_WIDTH){1'b0}}, d_rq_tkeep};
    assign rq_axis_vif.tvalid = d_rq_tvalid;
    assign rq_axis_vif.tlast  = d_rq_tlast;
    assign rq_axis_vif.tuser  =
        {{(mqnic_vrf_pkg::US_MAX_USER_WIDTH-AXIS_PCIE_RQ_USER_WIDTH){1'b0}}, d_rq_tuser};

    // ---- idle the TB-driven halves -------------------------------------------
    initial begin
        // Both generic inputs are TB-driven by pcie_tlp_driver, which clears sop
        // and eop with valid, so the stronger framing check applies.
        rd_tlp_vif.sop_eop_gated = 1'b1;
        wr_tlp_vif.sop_eop_gated = 1'b1;

        rq_axis_vif.straddling = mqnic_vrf_pkg::us_straddles(PCIE_CH_RQ,
                                                              AXIS_PCIE_DATA_WIDTH);
        rq_axis_vif.init_idle_sink();
    end

    // ---- UVM ------------------------------------------------------------------
    initial begin
        uvm_config_db #(virtual mqnic_reset_if)::set(null, "uvm_test_top", "rst_vif", rst_if);
        uvm_config_db #(virtual pcie_tlp_if)::set    (null, "uvm_test_top.m_env.m_rd_tlp*",  "vif", rd_tlp_vif);
        uvm_config_db #(virtual pcie_tlp_if)::set    (null, "uvm_test_top.m_env.m_wr_tlp*",  "vif", wr_tlp_vif);
        uvm_config_db #(virtual pcie_us_axis_if)::set(null, "uvm_test_top.m_env.m_rq_axis*", "vif", rq_axis_vif);
        uvm_config_db #(virtual pcie_us_fc_if)::set  (null, "uvm_test_top", "fc_vif", fc_vif);
        run_test();
    end

    initial begin
        if ($test$plusargs("WAVES")) begin
            $dumpfile("dump.vcd");
            $dumpvars(0, tb_top_tier4c);
        end
    end

endmodule : tb_top_tier4c

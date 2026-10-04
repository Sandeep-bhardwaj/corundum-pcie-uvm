// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tb_top_tier4a - Tier 4a testbench top (pcie_us_if_rc, pcie_us_if_cq)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §18 Step 6, §22 R2
// Introduced : Step 6 (Tier 4a)
//
// TWO DUTs, unmodified, side by side - the isolated receive shims. §22 R2 asks
// for the tuser risk to be closed here rather than inside the full pcie_us_if
// wrapper, because on these blocks a mismatch has exactly one plausible cause.
//
// GOLDEN GEOMETRY: AXIS_PCIE_DATA_WIDTH = 256 (mqnic_core_pcie_us.v:157), which
// gives RC_STRADDLE = 1 and CQ_STRADDLE = 0. Those are not free choices - they
// are the RTL's own expressions of the width - so they are written here as the
// expressions rather than as constants, and cannot drift from the DUT.
//
// Every DUT output reaches its interface through a continuous assign over the
// full width. The ICPSD rule, applied from the start.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_top_tier4a;

    import uvm_pkg::*;
`include "uvm_macros.svh"
    import mqnic_vrf_pkg::*;
    import mqnic_test_pkg::*;

    localparam int AXIS_PCIE_DATA_WIDTH    = 256;
    localparam int AXIS_PCIE_KEEP_WIDTH    = AXIS_PCIE_DATA_WIDTH / 32;   // 8
    localparam int AXIS_PCIE_RC_USER_WIDTH = AXIS_PCIE_DATA_WIDTH < 512 ? 75 : 161;
    localparam int AXIS_PCIE_CQ_USER_WIDTH = AXIS_PCIE_DATA_WIDTH < 512 ? 85 : 183;
    localparam int RC_STRADDLE             = AXIS_PCIE_DATA_WIDTH >= 256;
    localparam int CQ_STRADDLE             = AXIS_PCIE_DATA_WIDTH >= 512;

    localparam int TLP_DATA_WIDTH = AXIS_PCIE_DATA_WIDTH;
    localparam int TLP_STRB_WIDTH = TLP_DATA_WIDTH / 32;
    localparam int TLP_HDR_WIDTH  = 128;
    // TLP_SEG_COUNT = 1 - the configuration mqnic builds
    // (mqnic_core_pcie_us.v:562). Reachable because rtl_patched/ floors
    // SEG_SEL_WIDTH at 1; without that patch this does not elaborate at all
    // (bug 13).
    localparam int TLP_SEG_COUNT  = 1;

    localparam int TLP_MAX_SEG_COUNT  = 4;
    localparam int TLP_MAX_DATA_WIDTH = 512;
    localparam int TLP_MAX_STRB_WIDTH = 16;

    localparam time CLK_HALF_PERIOD = 2ns;

    logic clk;
    initial clk = 1'b0;
    always #CLK_HALF_PERIOD clk = ~clk;

    mqnic_reset_if rst_if (.clk(clk));
    wire rst = rst_if.rst;

    pcie_us_axis_if rc_axis_vif (.clk(clk), .rst(rst));
    pcie_us_axis_if cq_axis_vif (.clk(clk), .rst(rst));
    pcie_tlp_if     rc_tlp_vif  (.clk(clk), .rst(rst));
    pcie_tlp_if     cq_tlp_vif  (.clk(clk), .rst(rst));

    // ---- DUT-driven nets ------------------------------------------------------
    wire                                       d_rc_axis_tready;
    wire [TLP_DATA_WIDTH-1:0]                  d_rc_tlp_data;
    wire [TLP_STRB_WIDTH-1:0]                  d_rc_tlp_strb;
    wire [TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]     d_rc_tlp_hdr;
    wire [TLP_SEG_COUNT*4-1:0]                 d_rc_tlp_error;
    wire [TLP_SEG_COUNT-1:0]                   d_rc_tlp_valid;
    wire [TLP_SEG_COUNT-1:0]                   d_rc_tlp_sop;
    wire [TLP_SEG_COUNT-1:0]                   d_rc_tlp_eop;

    wire                                       d_cq_axis_tready;
    wire [TLP_DATA_WIDTH-1:0]                  d_cq_tlp_data;
    wire [TLP_STRB_WIDTH-1:0]                  d_cq_tlp_strb;
    wire [TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]     d_cq_tlp_hdr;
    wire [TLP_SEG_COUNT*3-1:0]                 d_cq_tlp_bar_id;
    wire [TLP_SEG_COUNT*8-1:0]                 d_cq_tlp_func_num;
    wire [TLP_SEG_COUNT-1:0]                   d_cq_tlp_valid;
    wire [TLP_SEG_COUNT-1:0]                   d_cq_tlp_sop;
    wire [TLP_SEG_COUNT-1:0]                   d_cq_tlp_eop;

    // ---- DUT 1: RC - the straddling one ---------------------------------------
    pcie_us_if_rc #(
        .AXIS_PCIE_DATA_WIDTH    (AXIS_PCIE_DATA_WIDTH),
        .AXIS_PCIE_KEEP_WIDTH    (AXIS_PCIE_KEEP_WIDTH),
        .AXIS_PCIE_RC_USER_WIDTH (AXIS_PCIE_RC_USER_WIDTH),
        .RC_STRADDLE             (RC_STRADDLE),
        .TLP_DATA_WIDTH          (TLP_DATA_WIDTH),
        .TLP_STRB_WIDTH          (TLP_STRB_WIDTH),
        .TLP_HDR_WIDTH           (TLP_HDR_WIDTH),
        .TLP_SEG_COUNT           (TLP_SEG_COUNT)
    ) u_pcie_us_if_rc (
        .clk (clk),
        .rst (rst),

        .s_axis_rc_tdata  (rc_axis_vif.tdata[AXIS_PCIE_DATA_WIDTH-1:0]),
        .s_axis_rc_tkeep  (rc_axis_vif.tkeep[AXIS_PCIE_KEEP_WIDTH-1:0]),
        .s_axis_rc_tvalid (rc_axis_vif.tvalid),
        .s_axis_rc_tready (d_rc_axis_tready),
        .s_axis_rc_tlast  (rc_axis_vif.tlast),
        .s_axis_rc_tuser  (rc_axis_vif.tuser[AXIS_PCIE_RC_USER_WIDTH-1:0]),

        .rx_cpl_tlp_data  (d_rc_tlp_data),
        .rx_cpl_tlp_strb  (d_rc_tlp_strb),
        .rx_cpl_tlp_hdr   (d_rc_tlp_hdr),
        .rx_cpl_tlp_error (d_rc_tlp_error),
        .rx_cpl_tlp_valid (d_rc_tlp_valid),
        .rx_cpl_tlp_sop   (d_rc_tlp_sop),
        .rx_cpl_tlp_eop   (d_rc_tlp_eop),
        .rx_cpl_tlp_ready (rc_tlp_vif.tlp_ready)
    );

    // ---- DUT 2: CQ ------------------------------------------------------------
    pcie_us_if_cq #(
        .AXIS_PCIE_DATA_WIDTH    (AXIS_PCIE_DATA_WIDTH),
        .AXIS_PCIE_KEEP_WIDTH    (AXIS_PCIE_KEEP_WIDTH),
        .AXIS_PCIE_CQ_USER_WIDTH (AXIS_PCIE_CQ_USER_WIDTH),
        .CQ_STRADDLE             (CQ_STRADDLE),
        .TLP_DATA_WIDTH          (TLP_DATA_WIDTH),
        .TLP_STRB_WIDTH          (TLP_STRB_WIDTH),
        .TLP_HDR_WIDTH           (TLP_HDR_WIDTH),
        .TLP_SEG_COUNT           (TLP_SEG_COUNT)
    ) u_pcie_us_if_cq (
        .clk (clk),
        .rst (rst),

        .s_axis_cq_tdata  (cq_axis_vif.tdata[AXIS_PCIE_DATA_WIDTH-1:0]),
        .s_axis_cq_tkeep  (cq_axis_vif.tkeep[AXIS_PCIE_KEEP_WIDTH-1:0]),
        .s_axis_cq_tvalid (cq_axis_vif.tvalid),
        .s_axis_cq_tready (d_cq_axis_tready),
        .s_axis_cq_tlast  (cq_axis_vif.tlast),
        .s_axis_cq_tuser  (cq_axis_vif.tuser[AXIS_PCIE_CQ_USER_WIDTH-1:0]),

        .rx_req_tlp_data     (d_cq_tlp_data),
        .rx_req_tlp_strb     (d_cq_tlp_strb),
        .rx_req_tlp_hdr      (d_cq_tlp_hdr),
        .rx_req_tlp_bar_id   (d_cq_tlp_bar_id),
        .rx_req_tlp_func_num (d_cq_tlp_func_num),
        .rx_req_tlp_valid    (d_cq_tlp_valid),
        .rx_req_tlp_sop      (d_cq_tlp_sop),
        .rx_req_tlp_eop      (d_cq_tlp_eop),
        .rx_req_tlp_ready    (cq_tlp_vif.tlp_ready)
    );

    // ---- DUT outputs -> interfaces --------------------------------------------
    assign rc_axis_vif.tready = d_rc_axis_tready;
    assign cq_axis_vif.tready = d_cq_axis_tready;

    assign rc_tlp_vif.tlp_data =
        {{(TLP_MAX_DATA_WIDTH-TLP_DATA_WIDTH){1'b0}}, d_rc_tlp_data};
    assign rc_tlp_vif.tlp_strb =
        {{(TLP_MAX_STRB_WIDTH-TLP_STRB_WIDTH){1'b0}}, d_rc_tlp_strb};
    assign rc_tlp_vif.tlp_hdr =
        {{(TLP_MAX_SEG_COUNT*TLP_HDR_WIDTH - TLP_SEG_COUNT*TLP_HDR_WIDTH){1'b0}},
         d_rc_tlp_hdr};
    assign rc_tlp_vif.tlp_error =
        {{(TLP_MAX_SEG_COUNT*4 - TLP_SEG_COUNT*4){1'b0}}, d_rc_tlp_error};
    assign rc_tlp_vif.tlp_valid =
        {{(TLP_MAX_SEG_COUNT-TLP_SEG_COUNT){1'b0}}, d_rc_tlp_valid};
    assign rc_tlp_vif.tlp_sop =
        {{(TLP_MAX_SEG_COUNT-TLP_SEG_COUNT){1'b0}}, d_rc_tlp_sop};
    assign rc_tlp_vif.tlp_eop =
        {{(TLP_MAX_SEG_COUNT-TLP_SEG_COUNT){1'b0}}, d_rc_tlp_eop};
    assign rc_tlp_vif.tlp_seq      = '0;
    assign rc_tlp_vif.tlp_bar_id   = '0;
    assign rc_tlp_vif.tlp_func_num = '0;

    assign cq_tlp_vif.tlp_data =
        {{(TLP_MAX_DATA_WIDTH-TLP_DATA_WIDTH){1'b0}}, d_cq_tlp_data};
    assign cq_tlp_vif.tlp_strb =
        {{(TLP_MAX_STRB_WIDTH-TLP_STRB_WIDTH){1'b0}}, d_cq_tlp_strb};
    assign cq_tlp_vif.tlp_hdr =
        {{(TLP_MAX_SEG_COUNT*TLP_HDR_WIDTH - TLP_SEG_COUNT*TLP_HDR_WIDTH){1'b0}},
         d_cq_tlp_hdr};
    assign cq_tlp_vif.tlp_bar_id =
        {{(TLP_MAX_SEG_COUNT*3 - TLP_SEG_COUNT*3){1'b0}}, d_cq_tlp_bar_id};
    assign cq_tlp_vif.tlp_func_num =
        {{(TLP_MAX_SEG_COUNT*8 - TLP_SEG_COUNT*8){1'b0}}, d_cq_tlp_func_num};
    assign cq_tlp_vif.tlp_valid =
        {{(TLP_MAX_SEG_COUNT-TLP_SEG_COUNT){1'b0}}, d_cq_tlp_valid};
    assign cq_tlp_vif.tlp_sop =
        {{(TLP_MAX_SEG_COUNT-TLP_SEG_COUNT){1'b0}}, d_cq_tlp_sop};
    assign cq_tlp_vif.tlp_eop =
        {{(TLP_MAX_SEG_COUNT-TLP_SEG_COUNT){1'b0}}, d_cq_tlp_eop};
    assign cq_tlp_vif.tlp_seq   = '0;
    assign cq_tlp_vif.tlp_error = '0;

    // ---- idle the TB-driven halves -------------------------------------------
    initial begin
        // NEITHER shim gates its framing. Both drive the generic side from
        // pcie_tlp_fifo_raw, which latches sop/eop and clears only valid
        // (pcie_tlp_fifo_raw.v:546-547, 587-588) - the same shape as the DMA
        // engines, by way of a module they share.
        //
        // This disproves the rule of thumb recorded in pcie_tlp_if after bug 10
        // ("routing blocks gate, DMA engines do not"). The real predictor is
        // whether the producer's output stage is pcie_tlp_fifo_raw, and that is
        // not something to infer - it is why slang_check rule 4 makes the
        // answer mandatory per instance rather than defaulted.
        rc_tlp_vif.sop_eop_gated = 1'b0;
        cq_tlp_vif.sop_eop_gated = 1'b0;

        // Straddling is a property of the RTL's own expression of the width,
        // not a testbench choice - hence us_straddles() rather than a literal.
        rc_axis_vif.straddling = mqnic_vrf_pkg::us_straddles(PCIE_CH_RC, AXIS_PCIE_DATA_WIDTH);
        cq_axis_vif.straddling = mqnic_vrf_pkg::us_straddles(PCIE_CH_CQ, AXIS_PCIE_DATA_WIDTH);

        rc_axis_vif.init_idle_source();
        cq_axis_vif.init_idle_source();

        rc_tlp_vif.tlp_ready = 1'b0;
        cq_tlp_vif.tlp_ready = 1'b0;
    end

    // ---- UVM ------------------------------------------------------------------
    initial begin
        uvm_config_db #(virtual mqnic_reset_if)::set(null, "uvm_test_top", "rst_vif", rst_if);
        uvm_config_db #(virtual pcie_us_axis_if)::set(null, "uvm_test_top.m_env.m_rc_axis*", "vif", rc_axis_vif);
        uvm_config_db #(virtual pcie_us_axis_if)::set(null, "uvm_test_top.m_env.m_cq_axis*", "vif", cq_axis_vif);
        uvm_config_db #(virtual pcie_tlp_if)::set    (null, "uvm_test_top.m_env.m_rc_tlp*",  "vif", rc_tlp_vif);
        uvm_config_db #(virtual pcie_tlp_if)::set    (null, "uvm_test_top.m_env.m_cq_tlp*",  "vif", cq_tlp_vif);
        run_test();
    end

    initial begin
        if ($test$plusargs("WAVES")) begin
            $dumpfile("dump.vcd");
            $dumpvars(0, tb_top_tier4a);
        end
    end

endmodule : tb_top_tier4a

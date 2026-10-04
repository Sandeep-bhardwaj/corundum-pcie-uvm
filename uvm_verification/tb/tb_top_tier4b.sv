// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tb_top_tier4b - Tier 4b testbench top (pcie_us_if_cc)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §18 Step 6, §19 Tier 4
// Introduced : Step 6 (Tier 4b)
//
// The clean transmit shim: generic TLP in, Xilinx AXI-Stream out, nothing else
// in the path. Its sibling pcie_us_if_rq is not clean - it arbitrates two TLP
// inputs and is gated by flow-control credits - which is why CC is separated
// out and done first.
//
// 256-BIT, the configuration mqnic builds (mqnic_core_pcie_us.v:157).
//
// Reachable only because rtl_patched/ floors SEG_SEL_WIDTH. pcie_us_if_cc feeds
// pcie_tlp_fifo_raw with OUT_TLP_SEG_COUNT(INT_TLP_SEG_COUNT), and
// INT_TLP_SEG_COUNT is DERIVED from the data width (pcie_us_if_cc.v:82) - so
// unlike Tier 4a this could never have been worked around by raising
// TLP_SEG_COUNT. Without the patch the only configuration that elaborates is
// 512, where CC straddles and Corundum never does.
//
// At 256 CC_STRADDLE is false, which is also why no CC straddle tuser
// transcription is needed - the patch removed a task as well as a caveat.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_top_tier4b;

    import uvm_pkg::*;
`include "uvm_macros.svh"
    import mqnic_vrf_pkg::*;
    import mqnic_test_pkg::*;

    localparam int AXIS_PCIE_DATA_WIDTH    = 256;
    localparam int AXIS_PCIE_KEEP_WIDTH    = AXIS_PCIE_DATA_WIDTH / 32;
    localparam int AXIS_PCIE_CC_USER_WIDTH = AXIS_PCIE_DATA_WIDTH < 512 ? 33 : 81;
    localparam int CC_STRADDLE             = AXIS_PCIE_DATA_WIDTH >= 512;

    localparam int TLP_DATA_WIDTH = AXIS_PCIE_DATA_WIDTH;
    localparam int TLP_STRB_WIDTH = TLP_DATA_WIDTH / 32;
    localparam int TLP_HDR_WIDTH  = 128;
    localparam int TLP_SEG_COUNT  = 1;   // IN_ side; OUT is derived - see header

    localparam int TLP_MAX_SEG_COUNT  = 4;
    localparam int TLP_MAX_DATA_WIDTH = 512;
    localparam int TLP_MAX_STRB_WIDTH = 16;

    localparam time CLK_HALF_PERIOD = 2ns;

    logic clk;
    initial clk = 1'b0;
    always #CLK_HALF_PERIOD clk = ~clk;

    mqnic_reset_if rst_if (.clk(clk));
    wire rst = rst_if.rst;

    pcie_tlp_if     cc_tlp_vif  (.clk(clk), .rst(rst));
    pcie_us_axis_if cc_axis_vif (.clk(clk), .rst(rst));

    // ---- DUT-driven nets ------------------------------------------------------
    wire                                 d_cc_tlp_ready;
    wire [AXIS_PCIE_DATA_WIDTH-1:0]      d_cc_axis_tdata;
    wire [AXIS_PCIE_KEEP_WIDTH-1:0]      d_cc_axis_tkeep;
    wire                                 d_cc_axis_tvalid;
    wire                                 d_cc_axis_tlast;
    wire [AXIS_PCIE_CC_USER_WIDTH-1:0]   d_cc_axis_tuser;

    // ---- DUT ------------------------------------------------------------------
    pcie_us_if_cc #(
        .AXIS_PCIE_DATA_WIDTH    (AXIS_PCIE_DATA_WIDTH),
        .AXIS_PCIE_KEEP_WIDTH    (AXIS_PCIE_KEEP_WIDTH),
        .AXIS_PCIE_CC_USER_WIDTH (AXIS_PCIE_CC_USER_WIDTH),
        .CC_STRADDLE             (CC_STRADDLE),
        .TLP_DATA_WIDTH          (TLP_DATA_WIDTH),
        .TLP_STRB_WIDTH          (TLP_STRB_WIDTH),
        .TLP_HDR_WIDTH           (TLP_HDR_WIDTH),
        .TLP_SEG_COUNT           (TLP_SEG_COUNT)
    ) u_pcie_us_if_cc (
        .clk (clk),
        .rst (rst),

        .m_axis_cc_tdata  (d_cc_axis_tdata),
        .m_axis_cc_tkeep  (d_cc_axis_tkeep),
        .m_axis_cc_tvalid (d_cc_axis_tvalid),
        .m_axis_cc_tready (cc_axis_vif.tready),
        .m_axis_cc_tlast  (d_cc_axis_tlast),
        .m_axis_cc_tuser  (d_cc_axis_tuser),

        .tx_cpl_tlp_data  (cc_tlp_vif.tlp_data[TLP_DATA_WIDTH-1:0]),
        .tx_cpl_tlp_strb  (cc_tlp_vif.tlp_strb[TLP_STRB_WIDTH-1:0]),
        .tx_cpl_tlp_hdr   (cc_tlp_vif.tlp_hdr[TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]),
        .tx_cpl_tlp_valid (cc_tlp_vif.tlp_valid[TLP_SEG_COUNT-1:0]),
        .tx_cpl_tlp_sop   (cc_tlp_vif.tlp_sop[TLP_SEG_COUNT-1:0]),
        .tx_cpl_tlp_eop   (cc_tlp_vif.tlp_eop[TLP_SEG_COUNT-1:0]),
        .tx_cpl_tlp_ready (d_cc_tlp_ready)
    );

    // ---- DUT outputs -> interfaces --------------------------------------------
    assign cc_tlp_vif.tlp_ready = d_cc_tlp_ready;

    assign cc_axis_vif.tdata =
        {{(mqnic_vrf_pkg::US_MAX_DATA_WIDTH-AXIS_PCIE_DATA_WIDTH){1'b0}}, d_cc_axis_tdata};
    assign cc_axis_vif.tkeep =
        {{(mqnic_vrf_pkg::US_MAX_KEEP_WIDTH-AXIS_PCIE_KEEP_WIDTH){1'b0}}, d_cc_axis_tkeep};
    assign cc_axis_vif.tvalid = d_cc_axis_tvalid;
    assign cc_axis_vif.tlast  = d_cc_axis_tlast;
    assign cc_axis_vif.tuser  =
        {{(mqnic_vrf_pkg::US_MAX_USER_WIDTH-AXIS_PCIE_CC_USER_WIDTH){1'b0}}, d_cc_axis_tuser};

    // ---- idle the TB-driven halves -------------------------------------------
    initial begin
        // The TB drives the generic side here and pcie_tlp_driver clears sop and
        // eop with valid, so the stronger framing check applies.
        cc_tlp_vif.sop_eop_gated = 1'b1;

        cc_axis_vif.straddling = mqnic_vrf_pkg::us_straddles(PCIE_CH_CC,
                                                             AXIS_PCIE_DATA_WIDTH);
        cc_axis_vif.init_idle_sink();
    end

    // ---- UVM ------------------------------------------------------------------
    initial begin
        uvm_config_db #(virtual mqnic_reset_if)::set(null, "uvm_test_top", "rst_vif", rst_if);
        uvm_config_db #(virtual pcie_tlp_if)::set    (null, "uvm_test_top.m_env.m_cc_tlp*",  "vif", cc_tlp_vif);
        uvm_config_db #(virtual pcie_us_axis_if)::set(null, "uvm_test_top.m_env.m_cc_axis*", "vif", cc_axis_vif);
        run_test();
    end

    initial begin
        if ($test$plusargs("WAVES")) begin
            $dumpfile("dump.vcd");
            $dumpvars(0, tb_top_tier4b);
        end
    end

endmodule : tb_top_tier4b

// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tb_top_smoke
// -----------------------------------------------------------------------------
// Step 0 bring-up top level.
//
// Implements : VERIFICATION_STRATEGY.md  §18 Step 0 gate
// Introduced : Step 0 (infrastructure)
//
// Purpose: prove the toolchain end to end before any UVC exists -
//   * UVM elaborates and mqnic_base_test runs to completion
//   * the Verilog-2001 DUT elaborates underneath a SystemVerilog TB
//   * clock and reset plumbing works and rst_vif reaches the test
//
// The DUT inputs are tied off here on purpose. Step 1 replaces the tie-offs
// with axil_agent and queue_op_agent connections and this file is superseded by
// tb_top_tier1a.sv. Nothing in the strategy depends on this file after Step 1;
// it is kept as a fast toolchain smoke check.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_top_smoke;

    import uvm_pkg::*;
`include "uvm_macros.svh"
    import mqnic_test_pkg::*;

    // ---- Tier 1a golden configuration (STRATEGY §2.3) -----------------------
    localparam int ADDR_WIDTH           = 64;
    localparam int REQ_TAG_WIDTH        = 8;
    localparam int OP_TABLE_SIZE        = 32;
    localparam int OP_TAG_WIDTH         = 8;
    localparam int QUEUE_INDEX_WIDTH    = 13;
    localparam int CPL_INDEX_WIDTH      = 8;
    localparam int QUEUE_PTR_WIDTH      = 16;
    localparam int LOG_BLOCK_SIZE_WIDTH = 2;
    localparam int AXIL_DATA_WIDTH      = 32;
    localparam int AXIL_ADDR_WIDTH      = QUEUE_INDEX_WIDTH + 5;
    localparam int AXIL_STRB_WIDTH      = AXIL_DATA_WIDTH / 8;

    // ---- clock: 250 MHz, matching CLK_PERIOD_NS_NUM/DENOM = 4/1 -------------
    localparam time CLK_HALF_PERIOD = 2ns;

    logic clk;

    initial clk = 1'b0;
    always #CLK_HALF_PERIOD clk = ~clk;

    // ---- reset --------------------------------------------------------------
    mqnic_reset_if rst_if (.clk(clk));

    // ---- DUT nets -----------------------------------------------------------
    logic [QUEUE_INDEX_WIDTH-1:0]    s_axis_dequeue_req_queue;
    logic [REQ_TAG_WIDTH-1:0]        s_axis_dequeue_req_tag;
    logic                            s_axis_dequeue_req_valid;
    logic                            s_axis_dequeue_req_ready;

    logic [QUEUE_INDEX_WIDTH-1:0]    m_axis_dequeue_resp_queue;
    logic [QUEUE_PTR_WIDTH-1:0]      m_axis_dequeue_resp_ptr;
    logic                            m_axis_dequeue_resp_phase;
    logic [ADDR_WIDTH-1:0]           m_axis_dequeue_resp_addr;
    logic [LOG_BLOCK_SIZE_WIDTH-1:0] m_axis_dequeue_resp_block_size;
    logic [CPL_INDEX_WIDTH-1:0]      m_axis_dequeue_resp_cpl;
    logic [REQ_TAG_WIDTH-1:0]        m_axis_dequeue_resp_tag;
    logic [OP_TAG_WIDTH-1:0]         m_axis_dequeue_resp_op_tag;
    logic                            m_axis_dequeue_resp_empty;
    logic                            m_axis_dequeue_resp_error;
    logic                            m_axis_dequeue_resp_valid;
    logic                            m_axis_dequeue_resp_ready;

    logic [OP_TAG_WIDTH-1:0]         s_axis_dequeue_commit_op_tag;
    logic                            s_axis_dequeue_commit_valid;
    logic                            s_axis_dequeue_commit_ready;

    logic [QUEUE_INDEX_WIDTH-1:0]    m_axis_doorbell_queue;
    logic                            m_axis_doorbell_valid;

    logic [AXIL_ADDR_WIDTH-1:0]      s_axil_awaddr;
    logic [2:0]                      s_axil_awprot;
    logic                            s_axil_awvalid;
    logic                            s_axil_awready;
    logic [AXIL_DATA_WIDTH-1:0]      s_axil_wdata;
    logic [AXIL_STRB_WIDTH-1:0]      s_axil_wstrb;
    logic                            s_axil_wvalid;
    logic                            s_axil_wready;
    logic [1:0]                      s_axil_bresp;
    logic                            s_axil_bvalid;
    logic                            s_axil_bready;
    logic [AXIL_ADDR_WIDTH-1:0]      s_axil_araddr;
    logic [2:0]                      s_axil_arprot;
    logic                            s_axil_arvalid;
    logic                            s_axil_arready;
    logic [AXIL_DATA_WIDTH-1:0]      s_axil_rdata;
    logic [1:0]                      s_axil_rresp;
    logic                            s_axil_rvalid;
    logic                            s_axil_rready;

    logic                            enable;

    // ---- tie-offs (replaced by agents at Step 1) ---------------------------
    initial begin
        s_axis_dequeue_req_queue     = '0;
        s_axis_dequeue_req_tag       = '0;
        s_axis_dequeue_req_valid     = 1'b0;
        m_axis_dequeue_resp_ready    = 1'b1;
        s_axis_dequeue_commit_op_tag = '0;
        s_axis_dequeue_commit_valid  = 1'b0;
        s_axil_awaddr                = '0;
        s_axil_awprot                = '0;
        s_axil_awvalid               = 1'b0;
        s_axil_wdata                 = '0;
        s_axil_wstrb                 = '0;
        s_axil_wvalid                = 1'b0;
        s_axil_bready                = 1'b1;
        s_axil_araddr                = '0;
        s_axil_arprot                = '0;
        s_axil_arvalid               = 1'b0;
        s_axil_rready                = 1'b1;
        enable                       = 1'b0;
    end

    // ---- DUT ----------------------------------------------------------------
    dut_wrapper_queue_manager #(
        .ADDR_WIDTH           (ADDR_WIDTH),
        .REQ_TAG_WIDTH        (REQ_TAG_WIDTH),
        .OP_TABLE_SIZE        (OP_TABLE_SIZE),
        .OP_TAG_WIDTH         (OP_TAG_WIDTH),
        .QUEUE_INDEX_WIDTH    (QUEUE_INDEX_WIDTH),
        .CPL_INDEX_WIDTH      (CPL_INDEX_WIDTH),
        .QUEUE_PTR_WIDTH      (QUEUE_PTR_WIDTH),
        .LOG_BLOCK_SIZE_WIDTH (LOG_BLOCK_SIZE_WIDTH),
        .AXIL_DATA_WIDTH      (AXIL_DATA_WIDTH),
        .AXIL_ADDR_WIDTH      (AXIL_ADDR_WIDTH),
        .AXIL_STRB_WIDTH      (AXIL_STRB_WIDTH)
    ) u_dut_wrapper (
        .clk                            (clk),
        .rst                            (rst_if.rst),

        .s_axis_dequeue_req_queue       (s_axis_dequeue_req_queue),
        .s_axis_dequeue_req_tag         (s_axis_dequeue_req_tag),
        .s_axis_dequeue_req_valid       (s_axis_dequeue_req_valid),
        .s_axis_dequeue_req_ready       (s_axis_dequeue_req_ready),

        .m_axis_dequeue_resp_queue      (m_axis_dequeue_resp_queue),
        .m_axis_dequeue_resp_ptr        (m_axis_dequeue_resp_ptr),
        .m_axis_dequeue_resp_phase      (m_axis_dequeue_resp_phase),
        .m_axis_dequeue_resp_addr       (m_axis_dequeue_resp_addr),
        .m_axis_dequeue_resp_block_size (m_axis_dequeue_resp_block_size),
        .m_axis_dequeue_resp_cpl        (m_axis_dequeue_resp_cpl),
        .m_axis_dequeue_resp_tag        (m_axis_dequeue_resp_tag),
        .m_axis_dequeue_resp_op_tag     (m_axis_dequeue_resp_op_tag),
        .m_axis_dequeue_resp_empty      (m_axis_dequeue_resp_empty),
        .m_axis_dequeue_resp_error      (m_axis_dequeue_resp_error),
        .m_axis_dequeue_resp_valid      (m_axis_dequeue_resp_valid),
        .m_axis_dequeue_resp_ready      (m_axis_dequeue_resp_ready),

        .s_axis_dequeue_commit_op_tag   (s_axis_dequeue_commit_op_tag),
        .s_axis_dequeue_commit_valid    (s_axis_dequeue_commit_valid),
        .s_axis_dequeue_commit_ready    (s_axis_dequeue_commit_ready),

        .m_axis_doorbell_queue          (m_axis_doorbell_queue),
        .m_axis_doorbell_valid          (m_axis_doorbell_valid),

        .s_axil_awaddr                  (s_axil_awaddr),
        .s_axil_awprot                  (s_axil_awprot),
        .s_axil_awvalid                 (s_axil_awvalid),
        .s_axil_awready                 (s_axil_awready),
        .s_axil_wdata                   (s_axil_wdata),
        .s_axil_wstrb                   (s_axil_wstrb),
        .s_axil_wvalid                  (s_axil_wvalid),
        .s_axil_wready                  (s_axil_wready),
        .s_axil_bresp                   (s_axil_bresp),
        .s_axil_bvalid                  (s_axil_bvalid),
        .s_axil_bready                  (s_axil_bready),
        .s_axil_araddr                  (s_axil_araddr),
        .s_axil_arprot                  (s_axil_arprot),
        .s_axil_arvalid                 (s_axil_arvalid),
        .s_axil_arready                 (s_axil_arready),
        .s_axil_rdata                   (s_axil_rdata),
        .s_axil_rresp                   (s_axil_rresp),
        .s_axil_rvalid                  (s_axil_rvalid),
        .s_axil_rready                  (s_axil_rready),

        .enable                         (enable)
    );

    // ---- UVM ----------------------------------------------------------------
    initial begin
        uvm_config_db #(virtual mqnic_reset_if)::set(null, "uvm_test_top", "rst_vif", rst_if);
        run_test("mqnic_base_test");
    end

    // ---- waveform dump ------------------------------------------------------
    initial begin
        if ($test$plusargs("WAVES")) begin
            $dumpfile("waves.vcd");
            $dumpvars(0, tb_top_smoke);
        end
    end

endmodule : tb_top_smoke

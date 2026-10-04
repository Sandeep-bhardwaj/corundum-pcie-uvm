// SPDX-License-Identifier: BSD-2-Clause-Views
//
// dut_wrapper_queue_manager
// -----------------------------------------------------------------------------
// Parameter-binding wrapper around the Tier 1a DUT.
//
// Implements : VERIFICATION_STRATEGY.md  §0.4 (parameter strategy),
//                                        §2.3 (golden configuration),
//                                        §18 Step 1
// Introduced : Step 0 (serves the Step 0 gate: prove the Verilog-2001 RTL
//              elaborates cleanly underneath a SystemVerilog testbench)
//
// Why a wrapper exists at all (STRATEGY §0.4): the UVM classes are NOT
// parameterized. Widths are fixed here, in one place per tier, and published to
// the environment through uvm_config_db. Changing the tier configuration means
// editing this file and nothing else.
//
// DUT: fpga/common/rtl/queue_manager.v
//
// Golden configuration for Tier 1a - QUEUE_INDEX_WIDTH tracks
// TX_QUEUE_INDEX_WIDTH=13 from STRATEGY §2.3 so the queue count matches the
// configuration the upper tiers will use.
// -----------------------------------------------------------------------------

`ifndef DUT_WRAPPER_QUEUE_MANAGER_SV
`define DUT_WRAPPER_QUEUE_MANAGER_SV

`timescale 1ns / 1ps

module dut_wrapper_queue_manager #(
    parameter int ADDR_WIDTH           = 64,
    parameter int REQ_TAG_WIDTH        = 8,
    parameter int OP_TABLE_SIZE        = 32,
    parameter int OP_TAG_WIDTH         = 8,
    parameter int QUEUE_INDEX_WIDTH    = 13,
    parameter int CPL_INDEX_WIDTH      = 8,
    parameter int QUEUE_PTR_WIDTH      = 16,
    parameter int LOG_QUEUE_SIZE_WIDTH = $clog2(QUEUE_PTR_WIDTH),
    parameter int DESC_SIZE            = 16,
    parameter int LOG_BLOCK_SIZE_WIDTH = 2,
    parameter int PIPELINE             = 2,
    parameter int AXIL_DATA_WIDTH      = 32,
    parameter int AXIL_ADDR_WIDTH      = QUEUE_INDEX_WIDTH + 5,
    parameter int AXIL_STRB_WIDTH      = AXIL_DATA_WIDTH / 8
) (
    input  logic                            clk,
    input  logic                            rst,

    // Dequeue request
    input  logic [QUEUE_INDEX_WIDTH-1:0]    s_axis_dequeue_req_queue,
    input  logic [REQ_TAG_WIDTH-1:0]        s_axis_dequeue_req_tag,
    input  logic                            s_axis_dequeue_req_valid,
    output logic                            s_axis_dequeue_req_ready,

    // Dequeue response
    output logic [QUEUE_INDEX_WIDTH-1:0]    m_axis_dequeue_resp_queue,
    output logic [QUEUE_PTR_WIDTH-1:0]      m_axis_dequeue_resp_ptr,
    output logic                            m_axis_dequeue_resp_phase,
    output logic [ADDR_WIDTH-1:0]           m_axis_dequeue_resp_addr,
    output logic [LOG_BLOCK_SIZE_WIDTH-1:0] m_axis_dequeue_resp_block_size,
    output logic [CPL_INDEX_WIDTH-1:0]      m_axis_dequeue_resp_cpl,
    output logic [REQ_TAG_WIDTH-1:0]        m_axis_dequeue_resp_tag,
    output logic [OP_TAG_WIDTH-1:0]         m_axis_dequeue_resp_op_tag,
    output logic                            m_axis_dequeue_resp_empty,
    output logic                            m_axis_dequeue_resp_error,
    output logic                            m_axis_dequeue_resp_valid,
    input  logic                            m_axis_dequeue_resp_ready,

    // Dequeue commit
    input  logic [OP_TAG_WIDTH-1:0]         s_axis_dequeue_commit_op_tag,
    input  logic                            s_axis_dequeue_commit_valid,
    output logic                            s_axis_dequeue_commit_ready,

    // Doorbell - note: pulse output, no ready handshake (STRATEGY §7.8)
    output logic [QUEUE_INDEX_WIDTH-1:0]    m_axis_doorbell_queue,
    output logic                            m_axis_doorbell_valid,

    // AXI-Lite slave
    input  logic [AXIL_ADDR_WIDTH-1:0]      s_axil_awaddr,
    input  logic [2:0]                      s_axil_awprot,
    input  logic                            s_axil_awvalid,
    output logic                            s_axil_awready,
    input  logic [AXIL_DATA_WIDTH-1:0]      s_axil_wdata,
    input  logic [AXIL_STRB_WIDTH-1:0]      s_axil_wstrb,
    input  logic                            s_axil_wvalid,
    output logic                            s_axil_wready,
    output logic [1:0]                      s_axil_bresp,
    output logic                            s_axil_bvalid,
    input  logic                            s_axil_bready,
    input  logic [AXIL_ADDR_WIDTH-1:0]      s_axil_araddr,
    input  logic [2:0]                      s_axil_arprot,
    input  logic                            s_axil_arvalid,
    output logic                            s_axil_arready,
    output logic [AXIL_DATA_WIDTH-1:0]      s_axil_rdata,
    output logic [1:0]                      s_axil_rresp,
    output logic                            s_axil_rvalid,
    input  logic                            s_axil_rready,

    input  logic                            enable
);

    queue_manager #(
        .ADDR_WIDTH           (ADDR_WIDTH),
        .REQ_TAG_WIDTH        (REQ_TAG_WIDTH),
        .OP_TABLE_SIZE        (OP_TABLE_SIZE),
        .OP_TAG_WIDTH         (OP_TAG_WIDTH),
        .QUEUE_INDEX_WIDTH    (QUEUE_INDEX_WIDTH),
        .CPL_INDEX_WIDTH      (CPL_INDEX_WIDTH),
        .QUEUE_PTR_WIDTH      (QUEUE_PTR_WIDTH),
        .LOG_QUEUE_SIZE_WIDTH (LOG_QUEUE_SIZE_WIDTH),
        .DESC_SIZE            (DESC_SIZE),
        .LOG_BLOCK_SIZE_WIDTH (LOG_BLOCK_SIZE_WIDTH),
        .PIPELINE             (PIPELINE),
        .AXIL_DATA_WIDTH      (AXIL_DATA_WIDTH),
        .AXIL_ADDR_WIDTH      (AXIL_ADDR_WIDTH),
        .AXIL_STRB_WIDTH      (AXIL_STRB_WIDTH)
    ) u_dut (
        .clk                            (clk),
        .rst                            (rst),

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

endmodule : dut_wrapper_queue_manager

`endif // DUT_WRAPPER_QUEUE_MANAGER_SV

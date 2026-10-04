// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tb_top_tier1 - unified Tier 1 testbench top
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §18 Steps 1-3
// Introduced : after Tier 1 was complete, to collapse three EDA Playground
//              exports into one
//
// WHY ONE TOP. EDA Playground has a single "Top module" setting, so three
// per-tier tops meant three separate pastes of a nearly identical 57-tab set.
// This top instantiates ALL SEVEN Tier 1 DUTs; `+UVM_TESTNAME` then selects the
// test, the test creates only its own environment, and that environment binds
// only the interfaces it needs. Every other DUT sits idle.
//
// That works without touching a single existing test because each tier's base
// test names its environment `m_env`, so the config_db paths below
// (uvm_test_top.m_env.<agent>*) resolve for whichever env was actually built.
//
// IDLE DUTS ARE DRIVEN, NOT LEFT FLOATING. Every interface signal is
// initialised to 0 at time 0. Without that, an unused DUT's inputs sit at X,
// which propagates into the $isunknown assertions of interfaces that are not
// even in use and produces failures that have nothing to do with the test.
// Active drivers overwrite these values on their first clock.
//
// All DUTs are UNMODIFIED Corundum RTL.
//
// pcie_tlp_fifo IS DELIBERATELY ABSENT. VCS rejects it at OUT_TLP_SEG_COUNT=1:
// pcie_tlp_fifo_raw.v derives SEG_SEL_WIDTH = $clog2(OUT_TLP_SEG_COUNT), which
// is 0 for a single segment, and the resulting zero-width part selects
// (pcie_tlp_fifo_raw.v:450-468) sit inside a plain `if (OUT_TLP_SEG_COUNT > 1)`
// - a RUNTIME branch, not a generate - so VCS elaborates the dead code and
// errors with IRIPS. slang and Icarus tolerate it.
//
// SEG_SEL_WIDTH is a body parameter of pcie_tlp_fifo (:106), so it cannot be
// overridden from an instantiation. The only clean fix is to run that DUT at
// SEG_COUNT=2, which needs a segment-aware driver and monitor - exactly the
// multi-segment work STRATEGY §5.1 schedules for Tier 4 (straddling). Rushing
// it here would risk a subtly wrong pcie_tlp UVC, and Tiers 3, 4 and 5 all
// depend on that UVC being right.
//
// pcie_tlp_demux_bar is unaffected: it is instantiated with FIFO_ENABLE=0 and
// pcie_tlp_demux.v:164 guards the FIFO with a GENERATE if, so it is never
// elaborated.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_top_tier1;

    import uvm_pkg::*;
`include "uvm_macros.svh"
    import mqnic_vrf_pkg::*;
    import mqnic_test_pkg::*;

    // ---- Tier 1a: queue_manager ---------------------------------------------
    localparam int ADDR_WIDTH           = 64;
    localparam int REQ_TAG_WIDTH        = 8;
    localparam int OP_TABLE_SIZE        = 32;
    localparam int OP_TAG_WIDTH         = 8;
    localparam int QUEUE_INDEX_WIDTH    = 13;
    localparam int CPL_INDEX_WIDTH      = 8;
    localparam int QUEUE_PTR_WIDTH      = 16;
    localparam int LOG_BLOCK_SIZE_WIDTH = 2;
    localparam int AXIL_DATA_WIDTH      = 32;
    localparam int AXIL_ADDR_WIDTH      = QUEUE_INDEX_WIDTH + 5;   // 18
    localparam int AXIL_STRB_WIDTH      = AXIL_DATA_WIDTH / 8;

    // ---- Tier 1a: cpl_queue_manager (4-dword register map, hence +4) --------
    localparam int CQ_QUEUE_INDEX_WIDTH = 8;
    localparam int CQ_EVENT_WIDTH       = 8;
    localparam int CQ_OP_TABLE_SIZE     = 32;
    localparam int CQ_CPL_SIZE          = 32;
    localparam int CQ_AXIL_ADDR_WIDTH   = CQ_QUEUE_INDEX_WIDTH + 4;

    // ---- Tier 1b: TLP routing -----------------------------------------------
    localparam int TLP_DATA_WIDTH = 256;
    localparam int TLP_STRB_WIDTH = TLP_DATA_WIDTH / 32;
    localparam int TLP_HDR_WIDTH  = 128;
    localparam int SEQ_NUM_WIDTH  = 6;
    localparam int SEG_COUNT      = 1;
    localparam int DEMUX_PORTS    = 2;

    // ---- Tier 1c: offloads ---------------------------------------------------
    localparam int DATA_WIDTH   = 256;
    localparam int KEEP_WIDTH   = DATA_WIDTH / 8;
    localparam int START_OFFSET = 14;

    // ---- interface maxima (see tb_top_tier1a.sv for why these are restated) --
    localparam int QOP_MAX_QUEUE_WIDTH  = 32;
    localparam int QOP_MAX_PTR_WIDTH    = 32;
    localparam int QOP_MAX_AUX_WIDTH    = 64;
    localparam int QOP_MAX_CPL_WIDTH    = 32;
    localparam int QOP_MAX_TAG_WIDTH    = 16;
    localparam int QOP_MAX_OP_TAG_WIDTH = 16;
    localparam int AXIL_MAX_DATA_WIDTH  = 64;
    localparam int AXIS_MAX_DATA_WIDTH  = 512;
    localparam int AXIS_MAX_USER_WIDTH  = 128;

    localparam time CLK_HALF_PERIOD = 2ns;   // 250 MHz

    logic clk;
    initial clk = 1'b0;
    always #CLK_HALF_PERIOD clk = ~clk;

    mqnic_reset_if rst_if (.clk(clk));
    wire rst = rst_if.rst;

    // =========================================================================
    // Interfaces
    // =========================================================================
    axil_if     axil_vif    (.clk(clk), .rst(rst));   // queue_manager
    queue_op_if qop_vif     (.clk(clk), .rst(rst));
    axil_if     cq_axil_vif (.clk(clk), .rst(rst));   // cpl_queue_manager
    queue_op_if cq_qop_vif  (.clk(clk), .rst(rst));

    pcie_tlp_if dmx_in_vif   (.clk(clk), .rst(rst));  // Tier 1b
    pcie_tlp_if dmx_out_vif [DEMUX_PORTS] (.clk(clk), .rst(rst));

    axis_if     stim_vif   (.clk(clk), .rst(rst));    // Tier 1c
    axis_if     csum_vif   (.clk(clk), .rst(rst));
    axis_if     hash_vif   (.clk(clk), .rst(rst));
    axis_if     tx_in_vif  (.clk(clk), .rst(rst));
    axis_if     tx_out_vif (.clk(clk), .rst(rst));
    csum_cmd_if tx_cmd_vif (.clk(clk), .rst(rst));

    logic [40*8-1:0] hash_key;
    initial hash_key = MQNIC_RSS_KEY_DEFAULT;

    // =========================================================================
    // DUT 1: queue_manager
    // =========================================================================
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
        .clk (clk), .rst (rst),
        .s_axis_dequeue_req_queue       (qop_vif.req_queue[QUEUE_INDEX_WIDTH-1:0]),
        .s_axis_dequeue_req_tag         (qop_vif.req_tag[REQ_TAG_WIDTH-1:0]),
        .s_axis_dequeue_req_valid       (qop_vif.req_valid),
        .s_axis_dequeue_req_ready       (qop_vif.req_ready),
        .m_axis_dequeue_resp_queue      (qop_vif.resp_queue[QUEUE_INDEX_WIDTH-1:0]),
        .m_axis_dequeue_resp_ptr        (qop_vif.resp_ptr[QUEUE_PTR_WIDTH-1:0]),
        .m_axis_dequeue_resp_phase      (qop_vif.resp_phase),
        .m_axis_dequeue_resp_addr       (qop_vif.resp_addr[ADDR_WIDTH-1:0]),
        .m_axis_dequeue_resp_block_size (qop_vif.resp_aux[LOG_BLOCK_SIZE_WIDTH-1:0]),
        .m_axis_dequeue_resp_cpl        (qop_vif.resp_cpl[CPL_INDEX_WIDTH-1:0]),
        .m_axis_dequeue_resp_tag        (qop_vif.resp_tag[REQ_TAG_WIDTH-1:0]),
        .m_axis_dequeue_resp_op_tag     (qop_vif.resp_op_tag[OP_TAG_WIDTH-1:0]),
        .m_axis_dequeue_resp_empty      (qop_vif.resp_blocked),
        .m_axis_dequeue_resp_error      (qop_vif.resp_error),
        .m_axis_dequeue_resp_valid      (qop_vif.resp_valid),
        .m_axis_dequeue_resp_ready      (qop_vif.resp_ready),
        .s_axis_dequeue_commit_op_tag   (qop_vif.commit_op_tag[OP_TAG_WIDTH-1:0]),
        .s_axis_dequeue_commit_valid    (qop_vif.commit_valid),
        .s_axis_dequeue_commit_ready    (qop_vif.commit_ready),
        .m_axis_doorbell_queue          (qop_vif.notify_source[QUEUE_INDEX_WIDTH-1:0]),
        .m_axis_doorbell_valid          (qop_vif.notify_valid),
        .s_axil_awaddr                  (axil_vif.awaddr[AXIL_ADDR_WIDTH-1:0]),
        .s_axil_awprot                  (axil_vif.awprot),
        .s_axil_awvalid                 (axil_vif.awvalid),
        .s_axil_awready                 (axil_vif.awready),
        .s_axil_wdata                   (axil_vif.wdata[AXIL_DATA_WIDTH-1:0]),
        .s_axil_wstrb                   (axil_vif.wstrb[AXIL_STRB_WIDTH-1:0]),
        .s_axil_wvalid                  (axil_vif.wvalid),
        .s_axil_wready                  (axil_vif.wready),
        .s_axil_bresp                   (axil_vif.bresp),
        .s_axil_bvalid                  (axil_vif.bvalid),
        .s_axil_bready                  (axil_vif.bready),
        .s_axil_araddr                  (axil_vif.araddr[AXIL_ADDR_WIDTH-1:0]),
        .s_axil_arprot                  (axil_vif.arprot),
        .s_axil_arvalid                 (axil_vif.arvalid),
        .s_axil_arready                 (axil_vif.arready),
        .s_axil_rdata                   (axil_vif.rdata[AXIL_DATA_WIDTH-1:0]),
        .s_axil_rresp                   (axil_vif.rresp),
        .s_axil_rvalid                  (axil_vif.rvalid),
        .s_axil_rready                  (axil_vif.rready),
        .enable                         (1'b1)
    );

    // =========================================================================
    // DUT 2: cpl_queue_manager
    // =========================================================================
    cpl_queue_manager #(
        .ADDR_WIDTH        (ADDR_WIDTH),
        .REQ_TAG_WIDTH     (REQ_TAG_WIDTH),
        .OP_TABLE_SIZE     (CQ_OP_TABLE_SIZE),
        .OP_TAG_WIDTH      (OP_TAG_WIDTH),
        .QUEUE_INDEX_WIDTH (CQ_QUEUE_INDEX_WIDTH),
        .EVENT_WIDTH       (CQ_EVENT_WIDTH),
        .QUEUE_PTR_WIDTH   (QUEUE_PTR_WIDTH),
        .CPL_SIZE          (CQ_CPL_SIZE),
        .PIPELINE          (2),
        .AXIL_DATA_WIDTH   (AXIL_DATA_WIDTH),
        .AXIL_ADDR_WIDTH   (CQ_AXIL_ADDR_WIDTH),
        .AXIL_STRB_WIDTH   (AXIL_STRB_WIDTH)
    ) u_cpl_queue_manager (
        .clk (clk), .rst (rst),
        .s_axis_enqueue_req_queue     (cq_qop_vif.req_queue[CQ_QUEUE_INDEX_WIDTH-1:0]),
        .s_axis_enqueue_req_tag       (cq_qop_vif.req_tag[REQ_TAG_WIDTH-1:0]),
        .s_axis_enqueue_req_valid     (cq_qop_vif.req_valid),
        .s_axis_enqueue_req_ready     (cq_qop_vif.req_ready),
        .m_axis_enqueue_resp_queue    (cq_qop_vif.resp_queue[CQ_QUEUE_INDEX_WIDTH-1:0]),
        .m_axis_enqueue_resp_ptr      (cq_qop_vif.resp_ptr[QUEUE_PTR_WIDTH-1:0]),
        .m_axis_enqueue_resp_phase    (cq_qop_vif.resp_phase),
        .m_axis_enqueue_resp_addr     (cq_qop_vif.resp_addr[ADDR_WIDTH-1:0]),
        .m_axis_enqueue_resp_event    (cq_qop_vif.resp_aux[CQ_EVENT_WIDTH-1:0]),
        .m_axis_enqueue_resp_tag      (cq_qop_vif.resp_tag[REQ_TAG_WIDTH-1:0]),
        .m_axis_enqueue_resp_op_tag   (cq_qop_vif.resp_op_tag[OP_TAG_WIDTH-1:0]),
        .m_axis_enqueue_resp_full     (cq_qop_vif.resp_blocked),
        .m_axis_enqueue_resp_error    (cq_qop_vif.resp_error),
        .m_axis_enqueue_resp_valid    (cq_qop_vif.resp_valid),
        .m_axis_enqueue_resp_ready    (cq_qop_vif.resp_ready),
        .s_axis_enqueue_commit_op_tag (cq_qop_vif.commit_op_tag[OP_TAG_WIDTH-1:0]),
        .s_axis_enqueue_commit_valid  (cq_qop_vif.commit_valid),
        .s_axis_enqueue_commit_ready  (cq_qop_vif.commit_ready),
        .m_axis_event                 (cq_qop_vif.notify_data[CQ_EVENT_WIDTH-1:0]),
        .m_axis_event_source          (cq_qop_vif.notify_source[CQ_QUEUE_INDEX_WIDTH-1:0]),
        .m_axis_event_valid           (cq_qop_vif.notify_valid),
        .m_axis_event_ready           (cq_qop_vif.notify_ready),
        .s_axil_awaddr   (cq_axil_vif.awaddr[CQ_AXIL_ADDR_WIDTH-1:0]),
        .s_axil_awprot   (cq_axil_vif.awprot),
        .s_axil_awvalid  (cq_axil_vif.awvalid),
        .s_axil_awready  (cq_axil_vif.awready),
        .s_axil_wdata    (cq_axil_vif.wdata[AXIL_DATA_WIDTH-1:0]),
        .s_axil_wstrb    (cq_axil_vif.wstrb[AXIL_STRB_WIDTH-1:0]),
        .s_axil_wvalid   (cq_axil_vif.wvalid),
        .s_axil_wready   (cq_axil_vif.wready),
        .s_axil_bresp    (cq_axil_vif.bresp),
        .s_axil_bvalid   (cq_axil_vif.bvalid),
        .s_axil_bready   (cq_axil_vif.bready),
        .s_axil_araddr   (cq_axil_vif.araddr[CQ_AXIL_ADDR_WIDTH-1:0]),
        .s_axil_arprot   (cq_axil_vif.arprot),
        .s_axil_arvalid  (cq_axil_vif.arvalid),
        .s_axil_arready  (cq_axil_vif.arready),
        .s_axil_rdata    (cq_axil_vif.rdata[AXIL_DATA_WIDTH-1:0]),
        .s_axil_rresp    (cq_axil_vif.rresp),
        .s_axil_rvalid   (cq_axil_vif.rvalid),
        .s_axil_rready   (cq_axil_vif.rready),
        .enable          (1'b1)
    );

    // =========================================================================
    // DUT 3: pcie_tlp_demux_bar   (BAR_BASE=0, BAR_STRIDE=2 - mqnic's own config)
    // =========================================================================
    wire [DEMUX_PORTS*TLP_DATA_WIDTH-1:0]          dmx_out_data;
    wire [DEMUX_PORTS*TLP_STRB_WIDTH-1:0]          dmx_out_strb;
    wire [DEMUX_PORTS*SEG_COUNT*TLP_HDR_WIDTH-1:0] dmx_out_hdr;
    wire [DEMUX_PORTS*SEG_COUNT*SEQ_NUM_WIDTH-1:0] dmx_out_seq;
    wire [DEMUX_PORTS*SEG_COUNT*3-1:0]             dmx_out_bar_id;
    wire [DEMUX_PORTS*SEG_COUNT*8-1:0]             dmx_out_func_num;
    wire [DEMUX_PORTS*SEG_COUNT*4-1:0]             dmx_out_error;
    wire [DEMUX_PORTS*SEG_COUNT-1:0]               dmx_out_valid;
    wire [DEMUX_PORTS*SEG_COUNT-1:0]               dmx_out_sop;
    wire [DEMUX_PORTS*SEG_COUNT-1:0]               dmx_out_eop;
    wire [DEMUX_PORTS-1:0]                         dmx_out_ready;

    pcie_tlp_demux_bar #(
        .PORTS             (DEMUX_PORTS),
        .TLP_DATA_WIDTH    (TLP_DATA_WIDTH),
        .TLP_STRB_WIDTH    (TLP_STRB_WIDTH),
        .TLP_HDR_WIDTH     (TLP_HDR_WIDTH),
        .SEQ_NUM_WIDTH     (SEQ_NUM_WIDTH),
        .IN_TLP_SEG_COUNT  (SEG_COUNT),
        .OUT_TLP_SEG_COUNT (SEG_COUNT),
        .FIFO_ENABLE       (0),
        .BAR_BASE          (0),
        .BAR_STRIDE        (2),
        .BAR_IDS           (0)
    ) u_demux (
        .clk (clk), .rst (rst),
        .in_tlp_data      (dmx_in_vif.tlp_data[TLP_DATA_WIDTH-1:0]),
        .in_tlp_strb      (dmx_in_vif.tlp_strb[TLP_STRB_WIDTH-1:0]),
        .in_tlp_hdr       (dmx_in_vif.tlp_hdr[SEG_COUNT*TLP_HDR_WIDTH-1:0]),
        .in_tlp_seq       (dmx_in_vif.tlp_seq[SEG_COUNT*SEQ_NUM_WIDTH-1:0]),
        .in_tlp_bar_id    (dmx_in_vif.tlp_bar_id[SEG_COUNT*3-1:0]),
        .in_tlp_func_num  (dmx_in_vif.tlp_func_num[SEG_COUNT*8-1:0]),
        .in_tlp_error     (dmx_in_vif.tlp_error[SEG_COUNT*4-1:0]),
        .in_tlp_valid     (dmx_in_vif.tlp_valid[SEG_COUNT-1:0]),
        .in_tlp_sop       (dmx_in_vif.tlp_sop[SEG_COUNT-1:0]),
        .in_tlp_eop       (dmx_in_vif.tlp_eop[SEG_COUNT-1:0]),
        .in_tlp_ready     (dmx_in_vif.tlp_ready),
        .out_tlp_data     (dmx_out_data),
        .out_tlp_strb     (dmx_out_strb),
        .out_tlp_hdr      (dmx_out_hdr),
        .out_tlp_seq      (dmx_out_seq),
        .out_tlp_bar_id   (dmx_out_bar_id),
        .out_tlp_func_num (dmx_out_func_num),
        .out_tlp_error    (dmx_out_error),
        .out_tlp_valid    (dmx_out_valid),
        .out_tlp_sop      (dmx_out_sop),
        .out_tlp_eop      (dmx_out_eop),
        .out_tlp_ready    (dmx_out_ready),
        .enable           (1'b1),
        .fifo_half_full   (),
        .fifo_watermark   ()
    );

    for (genvar p = 0; p < DEMUX_PORTS; p++) begin : g_dmx_out
        assign dmx_out_vif[p].tlp_data[TLP_DATA_WIDTH-1:0] =
                   dmx_out_data[p*TLP_DATA_WIDTH +: TLP_DATA_WIDTH];
        assign dmx_out_vif[p].tlp_strb[TLP_STRB_WIDTH-1:0] =
                   dmx_out_strb[p*TLP_STRB_WIDTH +: TLP_STRB_WIDTH];
        assign dmx_out_vif[p].tlp_hdr[TLP_HDR_WIDTH-1:0] =
                   dmx_out_hdr[p*SEG_COUNT*TLP_HDR_WIDTH +: TLP_HDR_WIDTH];
        assign dmx_out_vif[p].tlp_seq[SEQ_NUM_WIDTH-1:0] =
                   dmx_out_seq[p*SEG_COUNT*SEQ_NUM_WIDTH +: SEQ_NUM_WIDTH];
        assign dmx_out_vif[p].tlp_bar_id[2:0]   = dmx_out_bar_id[p*SEG_COUNT*3 +: 3];
        assign dmx_out_vif[p].tlp_func_num[7:0] = dmx_out_func_num[p*SEG_COUNT*8 +: 8];
        assign dmx_out_vif[p].tlp_error[3:0]    = dmx_out_error[p*SEG_COUNT*4 +: 4];
        assign dmx_out_vif[p].tlp_valid[SEG_COUNT-1:0] = dmx_out_valid[p*SEG_COUNT +: SEG_COUNT];
        assign dmx_out_vif[p].tlp_sop[SEG_COUNT-1:0]   = dmx_out_sop[p*SEG_COUNT +: SEG_COUNT];
        assign dmx_out_vif[p].tlp_eop[SEG_COUNT-1:0]   = dmx_out_eop[p*SEG_COUNT +: SEG_COUNT];
        assign dmx_out_ready[p] = dmx_out_vif[p].tlp_ready;

        // tlp_ready is TB-driven; define it before any agent exists.
        initial dmx_out_vif[p].tlp_ready = 1'b0;

        // Tie off the bits above the DUT's width. This MUST live inside the
        // genvar block: `p` is then an elaboration-time constant. A procedural
        // `for (int p...)` loop indexing an interface ARRAY is an illegal
        // cross-module reference - VCS rejects it with IIXMR "index is not
        // constant". slang accepts it, so it only shows up on a real simulator.
        initial begin
            dmx_out_vif[p].tlp_data[511:TLP_DATA_WIDTH] = '0;
            dmx_out_vif[p].tlp_strb[15:TLP_STRB_WIDTH]  = '0;
            dmx_out_vif[p].tlp_hdr[511:TLP_HDR_WIDTH]   = '0;
            dmx_out_vif[p].tlp_seq[23:SEQ_NUM_WIDTH]    = '0;
            dmx_out_vif[p].tlp_bar_id[11:3]             = '0;
            dmx_out_vif[p].tlp_func_num[31:8]           = '0;
            dmx_out_vif[p].tlp_error[15:4]              = '0;
            dmx_out_vif[p].tlp_valid[3:SEG_COUNT]       = '0;
            dmx_out_vif[p].tlp_sop[3:SEG_COUNT]         = '0;
            dmx_out_vif[p].tlp_eop[3:SEG_COUNT]         = '0;
        end
    end

    // =========================================================================
    // DUTs 5 and 6: rx_checksum + rx_hash, sharing one ingress stream
    // =========================================================================
    wire [15:0] csum_value;
    wire        csum_valid;
    wire [31:0] hash_value;
    wire [3:0]  hash_type;
    wire        hash_valid;

    rx_checksum #(
        .DATA_WIDTH (DATA_WIDTH), .KEEP_WIDTH (KEEP_WIDTH), .START_OFFSET (START_OFFSET)
    ) u_rx_checksum (
        .clk (clk), .rst (rst),
        .s_axis_tdata      (stim_vif.tdata[DATA_WIDTH-1:0]),
        .s_axis_tkeep      (stim_vif.tkeep[KEEP_WIDTH-1:0]),
        .s_axis_tvalid     (stim_vif.tvalid),
        .s_axis_tlast      (stim_vif.tlast),
        .m_axis_csum       (csum_value),
        .m_axis_csum_valid (csum_valid)
    );

    rx_hash #(
        .DATA_WIDTH (DATA_WIDTH), .KEEP_WIDTH (KEEP_WIDTH)
    ) u_rx_hash (
        .clk (clk), .rst (rst),
        .s_axis_tdata      (stim_vif.tdata[DATA_WIDTH-1:0]),
        .s_axis_tkeep      (stim_vif.tkeep[KEEP_WIDTH-1:0]),
        .s_axis_tvalid     (stim_vif.tvalid),
        .s_axis_tlast      (stim_vif.tlast),
        .hash_key          (hash_key),
        .m_axis_hash       (hash_value),
        .m_axis_hash_type  (hash_type),
        .m_axis_hash_valid (hash_valid)
    );

    assign csum_vif.tdata[15:0] = csum_value;
    assign csum_vif.tvalid      = csum_valid;
    assign hash_vif.tdata[31:0] = hash_value;
    assign hash_vif.tuser[3:0]  = hash_type;
    assign hash_vif.tvalid      = hash_valid;

    // =========================================================================
    // DUT 7: tx_checksum
    // =========================================================================
    tx_checksum #(
        .DATA_WIDTH          (DATA_WIDTH),
        .KEEP_WIDTH          (KEEP_WIDTH),
        .ID_ENABLE           (0),
        .DEST_ENABLE         (0),
        .USER_ENABLE         (1),
        .USER_WIDTH          (1),
        .USE_INIT_VALUE      (0),
        .DATA_FIFO_DEPTH     (4096),
        .CHECKSUM_FIFO_DEPTH (64)
    ) u_tx_checksum (
        .clk (clk), .rst (rst),
        .s_axis_tdata  (tx_in_vif.tdata[DATA_WIDTH-1:0]),
        .s_axis_tkeep  (tx_in_vif.tkeep[KEEP_WIDTH-1:0]),
        .s_axis_tvalid (tx_in_vif.tvalid),
        .s_axis_tready (tx_in_vif.tready),
        .s_axis_tlast  (tx_in_vif.tlast),
        .s_axis_tid    (tx_in_vif.tid),
        .s_axis_tdest  (tx_in_vif.tdest),
        .s_axis_tuser  (tx_in_vif.tuser[0]),
        .m_axis_tdata  (tx_out_vif.tdata[DATA_WIDTH-1:0]),
        .m_axis_tkeep  (tx_out_vif.tkeep[KEEP_WIDTH-1:0]),
        .m_axis_tvalid (tx_out_vif.tvalid),
        .m_axis_tready (tx_out_vif.tready),
        .m_axis_tlast  (tx_out_vif.tlast),
        .m_axis_tid    (tx_out_vif.tid),
        .m_axis_tdest  (tx_out_vif.tdest),
        .m_axis_tuser  (tx_out_vif.tuser[0]),
        .s_axis_cmd_csum_enable (tx_cmd_vif.csum_enable),
        .s_axis_cmd_csum_start  (tx_cmd_vif.csum_start),
        .s_axis_cmd_csum_offset (tx_cmd_vif.csum_offset),
        .s_axis_cmd_csum_init   (tx_cmd_vif.csum_init),
        .s_axis_cmd_valid       (tx_cmd_vif.valid),
        .s_axis_cmd_ready       (tx_cmd_vif.ready)
    );

    // =========================================================================
    // Time-zero initialisation. See the file header: an idle DUT's inputs must
    // be 0, not X, or its interface assertions fire during someone else's test.
    // =========================================================================
    initial begin
        // Driven by pcie_tlp_driver, which clears sop/eop with valid.
        // The Tier 1b routing DUTs downstream gate them as well, so the
        // stronger framing check is correct on this channel.
        dmx_in_vif.sop_eop_gated = 1'b1;

        // Tier 1a - DUT-driven upper bits
        qop_vif.resp_queue   [QOP_MAX_QUEUE_WIDTH-1:QUEUE_INDEX_WIDTH]       = '0;
        qop_vif.resp_ptr     [QOP_MAX_PTR_WIDTH-1:QUEUE_PTR_WIDTH]           = '0;
        qop_vif.resp_aux     [QOP_MAX_AUX_WIDTH-1:LOG_BLOCK_SIZE_WIDTH]      = '0;
        qop_vif.resp_cpl     [QOP_MAX_CPL_WIDTH-1:CPL_INDEX_WIDTH]           = '0;
        qop_vif.resp_tag     [QOP_MAX_TAG_WIDTH-1:REQ_TAG_WIDTH]             = '0;
        qop_vif.resp_op_tag  [QOP_MAX_OP_TAG_WIDTH-1:OP_TAG_WIDTH]           = '0;
        qop_vif.notify_source[QOP_MAX_QUEUE_WIDTH-1:QUEUE_INDEX_WIDTH]       = '0;
        qop_vif.notify_data                                                  = '0;
        axil_vif.rdata       [AXIL_MAX_DATA_WIDTH-1:AXIL_DATA_WIDTH]         = '0;

        cq_qop_vif.resp_queue   [QOP_MAX_QUEUE_WIDTH-1:CQ_QUEUE_INDEX_WIDTH] = '0;
        cq_qop_vif.resp_ptr     [QOP_MAX_PTR_WIDTH-1:QUEUE_PTR_WIDTH]        = '0;
        cq_qop_vif.resp_aux     [QOP_MAX_AUX_WIDTH-1:CQ_EVENT_WIDTH]         = '0;
        cq_qop_vif.resp_cpl                                                  = '0;
        cq_qop_vif.resp_tag     [QOP_MAX_TAG_WIDTH-1:REQ_TAG_WIDTH]          = '0;
        cq_qop_vif.resp_op_tag  [QOP_MAX_OP_TAG_WIDTH-1:OP_TAG_WIDTH]        = '0;
        cq_qop_vif.notify_source[QOP_MAX_QUEUE_WIDTH-1:CQ_QUEUE_INDEX_WIDTH] = '0;
        cq_qop_vif.notify_data  [QOP_MAX_AUX_WIDTH-1:CQ_EVENT_WIDTH]         = '0;
        cq_axil_vif.rdata       [AXIL_MAX_DATA_WIDTH-1:AXIL_DATA_WIDTH]      = '0;

        // Tier 1b - DUT-driven upper bits

        // Tier 1c - result interfaces have no tready/tlast
        csum_vif.tdata[AXIS_MAX_DATA_WIDTH-1:16] = '0;
        csum_vif.tkeep = '1; csum_vif.tlast = 1'b0; csum_vif.tready = 1'b1;
        csum_vif.tuser = '0; csum_vif.tid = '0; csum_vif.tdest = '0;
        hash_vif.tdata[AXIS_MAX_DATA_WIDTH-1:32] = '0;
        hash_vif.tuser[AXIS_MAX_USER_WIDTH-1:4]  = '0;
        hash_vif.tkeep = '1; hash_vif.tlast = 1'b0; hash_vif.tready = 1'b1;
        hash_vif.tid = '0;   hash_vif.tdest = '0;
        stim_vif.tready = 1'b1;
        tx_out_vif.tdata[AXIS_MAX_DATA_WIDTH-1:DATA_WIDTH] = '0;
        tx_out_vif.tkeep[63:KEEP_WIDTH]                    = '0;
        tx_out_vif.tuser[AXIS_MAX_USER_WIDTH-1:1]          = '0;
    end

    // -------------------------------------------------------------------------
    // Idle stimulus interfaces.
    //
    // A test builds only its own environment, so the agents for every OTHER
    // interface never exist and nothing drives their TB-side signals. Left
    // undriven they sit at X, and pcie_tlp_if's
    //
    //     a_sop_implies_valid : (tlp_sop & ~tlp_valid) == '0
    //
    // is an UNCONDITIONAL assertion - with X operands it evaluates to X, which
    // is not true, so it FAILS. That is exactly what happened running
    // t1a_random_stress: the Tier 1b TLP interfaces had no driver.
    //
    // The assertion is right and stays as it is; the interfaces are what needed
    // fixing. Every TB-DRIVEN signal of every interface is therefore given a
    // defined value here. DUT-driven signals are deliberately NOT touched -
    // assigning to those would create a second driver.
    // -------------------------------------------------------------------------
    initial begin
        // ---- AXI-Lite (master side is TB-driven) ---------------------------
        axil_vif.awaddr  = '0; axil_vif.awprot  = '0; axil_vif.awvalid = 1'b0;
        axil_vif.wdata   = '0; axil_vif.wstrb   = '0; axil_vif.wvalid  = 1'b0;
        axil_vif.bready  = 1'b0;
        axil_vif.araddr  = '0; axil_vif.arprot  = '0; axil_vif.arvalid = 1'b0;
        axil_vif.rready  = 1'b0;

        cq_axil_vif.awaddr  = '0; cq_axil_vif.awprot  = '0; cq_axil_vif.awvalid = 1'b0;
        cq_axil_vif.wdata   = '0; cq_axil_vif.wstrb   = '0; cq_axil_vif.wvalid  = 1'b0;
        cq_axil_vif.bready  = 1'b0;
        cq_axil_vif.araddr  = '0; cq_axil_vif.arprot  = '0; cq_axil_vif.arvalid = 1'b0;
        cq_axil_vif.rready  = 1'b0;

        // ---- queue_op (request/commit in, response/notify consumed) --------
        qop_vif.req_queue     = '0; qop_vif.req_tag      = '0;
        qop_vif.req_valid     = 1'b0;
        qop_vif.resp_ready    = 1'b0;
        qop_vif.commit_op_tag = '0; qop_vif.commit_valid = 1'b0;
        qop_vif.notify_ready  = 1'b1;   // dequeue doorbell has no ready

        cq_qop_vif.req_queue     = '0; cq_qop_vif.req_tag      = '0;
        cq_qop_vif.req_valid     = 1'b0;
        cq_qop_vif.resp_ready    = 1'b0;
        cq_qop_vif.commit_op_tag = '0; cq_qop_vif.commit_valid = 1'b0;
        cq_qop_vif.notify_ready  = 1'b0;

        // ---- generic TLP: the demux input is entirely TB-driven ------------
        // Framing (valid/sop/eop) is the part the assertions check, so all
        // three must be defined, not just valid.
        dmx_in_vif.tlp_data     = '0;
        dmx_in_vif.tlp_strb     = '0;
        dmx_in_vif.tlp_hdr      = '0;
        dmx_in_vif.tlp_seq      = '0;
        dmx_in_vif.tlp_bar_id   = '0;
        dmx_in_vif.tlp_func_num = '0;
        dmx_in_vif.tlp_error    = '0;
        dmx_in_vif.tlp_valid    = '0;
        dmx_in_vif.tlp_sop      = '0;
        dmx_in_vif.tlp_eop      = '0;

        // ---- AXI-Stream ----------------------------------------------------
        stim_vif.tdata = '0; stim_vif.tkeep = '0; stim_vif.tvalid = 1'b0;
        stim_vif.tlast = 1'b0; stim_vif.tuser = '0;
        stim_vif.tid   = '0; stim_vif.tdest = '0;

        tx_in_vif.tdata = '0; tx_in_vif.tkeep = '0; tx_in_vif.tvalid = 1'b0;
        tx_in_vif.tlast = 1'b0; tx_in_vif.tuser = '0;
        tx_in_vif.tid   = '0; tx_in_vif.tdest = '0;

        tx_out_vif.tready = 1'b0;

        // ---- tx_checksum command -------------------------------------------
        tx_cmd_vif.csum_enable = 1'b0;
        tx_cmd_vif.csum_start  = '0;
        tx_cmd_vif.csum_offset = '0;
        tx_cmd_vif.csum_init   = '0;
        tx_cmd_vif.valid       = 1'b0;
    end

    // =========================================================================
    // UVM. Every interface is published; the test builds only its own
    // environment, so only the matching agents ever claim one.
    // =========================================================================
    initial begin
        uvm_config_db #(virtual mqnic_reset_if)::set(null, "uvm_test_top", "rst_vif", rst_if);

        uvm_config_db #(virtual axil_if)::set    (null, "uvm_test_top.m_env.m_axil*",    "vif", axil_vif);
        uvm_config_db #(virtual queue_op_if)::set(null, "uvm_test_top.m_env.m_qop*",     "vif", qop_vif);
        uvm_config_db #(virtual axil_if)::set    (null, "uvm_test_top.m_env.m_cq_axil*", "vif", cq_axil_vif);
        uvm_config_db #(virtual queue_op_if)::set(null, "uvm_test_top.m_env.m_cq_qop*",  "vif", cq_qop_vif);

        uvm_config_db #(virtual pcie_tlp_if)::set(null, "uvm_test_top.m_env.m_dmx_in*",   "vif", dmx_in_vif);
        uvm_config_db #(virtual pcie_tlp_if)::set(null, "uvm_test_top.m_env.m_dmx_out0*", "vif", dmx_out_vif[0]);
        uvm_config_db #(virtual pcie_tlp_if)::set(null, "uvm_test_top.m_env.m_dmx_out1*", "vif", dmx_out_vif[1]);

        uvm_config_db #(virtual axis_if)::set    (null, "uvm_test_top.m_env.m_stim*",   "vif", stim_vif);
        uvm_config_db #(virtual axis_if)::set    (null, "uvm_test_top.m_env.m_csum*",   "vif", csum_vif);
        uvm_config_db #(virtual axis_if)::set    (null, "uvm_test_top.m_env.m_hash*",   "vif", hash_vif);
        uvm_config_db #(virtual axis_if)::set    (null, "uvm_test_top.m_env.m_tx_in*",  "vif", tx_in_vif);
        uvm_config_db #(virtual axis_if)::set    (null, "uvm_test_top.m_env.m_tx_out*", "vif", tx_out_vif);
        uvm_config_db #(virtual csum_cmd_if)::set(null, "uvm_test_top.m_env.m_tx_cmd*", "vif", tx_cmd_vif);

        run_test();
    end

    initial begin
        if ($test$plusargs("WAVES")) begin
            $dumpfile("dump.vcd");
            $dumpvars(0, tb_top_tier1);
        end
    end

endmodule : tb_top_tier1

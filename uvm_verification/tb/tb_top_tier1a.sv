// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tb_top_tier1a - Tier 1a testbench top
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §18 Step 1
// Introduced : Step 1 (Tier 1a)
//
// Replaces the Step 0 tie-offs with real agent connections. The UVC interfaces
// are declared at maximum width (STRATEGY §4.3 rule 1) and only the bits the DUT
// actually has are wired through; the rest are left unconnected on the DUT side.
//
// DUT: fpga/common/rtl/queue_manager.v via dut_wrapper_queue_manager.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_top_tier1a;

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
    localparam int AXIL_ADDR_WIDTH      = QUEUE_INDEX_WIDTH + 5;   // 18
    localparam int AXIL_STRB_WIDTH      = AXIL_DATA_WIDTH / 8;     // 4

    localparam time CLK_HALF_PERIOD = 2ns;   // 250 MHz

    // ---- clock and reset ----------------------------------------------------
    logic clk;
    initial clk = 1'b0;
    always #CLK_HALF_PERIOD clk = ~clk;

    mqnic_reset_if rst_if (.clk(clk));

    wire rst = rst_if.rst;

    // ---- Tier 1a second DUT: cpl_queue_manager ------------------------------
    // Narrower index and a 4-dword register map (AXIL_ADDR_WIDTH =
    // QUEUE_INDEX_WIDTH+4, not +5 as on queue_manager). CPL_SIZE is set to 32 to
    // match mqnic's completion record; ref_queue.cpl_size must agree.
    localparam int CQ_QUEUE_INDEX_WIDTH = 8;
    localparam int CQ_EVENT_WIDTH       = 8;
    localparam int CQ_OP_TABLE_SIZE     = 32;
    localparam int CQ_CPL_SIZE          = 32;
    localparam int CQ_AXIL_ADDR_WIDTH   = CQ_QUEUE_INDEX_WIDTH + 4;

    // ---- UVC interfaces -----------------------------------------------------
    axil_if     axil_vif (.clk(clk), .rst(rst));
    queue_op_if qop_vif  (.clk(clk), .rst(rst));
    axil_if     cq_axil_vif (.clk(clk), .rst(rst));
    queue_op_if cq_qop_vif  (.clk(clk), .rst(rst));

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
        .clk (clk),
        .rst (rst),

        // ---- dequeue request : queue_op_if req_* ----------------------------
        .s_axis_dequeue_req_queue       (qop_vif.req_queue[QUEUE_INDEX_WIDTH-1:0]),
        .s_axis_dequeue_req_tag         (qop_vif.req_tag[REQ_TAG_WIDTH-1:0]),
        .s_axis_dequeue_req_valid       (qop_vif.req_valid),
        .s_axis_dequeue_req_ready       (qop_vif.req_ready),

        // ---- dequeue response : queue_op_if resp_* --------------------------
        // aux <- block_size, blocked <- empty  (see queue_op_if.sv header)
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

        // ---- commit ----------------------------------------------------------
        .s_axis_dequeue_commit_op_tag   (qop_vif.commit_op_tag[OP_TAG_WIDTH-1:0]),
        .s_axis_dequeue_commit_valid    (qop_vif.commit_valid),
        .s_axis_dequeue_commit_ready    (qop_vif.commit_ready),

        // ---- doorbell : PULSE, no ready (STRATEGY §7.8) ---------------------
        .m_axis_doorbell_queue          (qop_vif.notify_source[QUEUE_INDEX_WIDTH-1:0]),
        .m_axis_doorbell_valid          (qop_vif.notify_valid),

        // ---- AXI-Lite --------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Interface maxima.
    //
    // These MUST match the localparams declared in queue_op_if.sv and axil_if.sv.
    // They are restated here rather than referenced because `interface::PARAM`
    // is NOT legal SystemVerilog - the :: scope-resolution operator applies to
    // packages and classes only, never to an interface definition. (slang
    // accepts it; VCS correctly rejects it with SV-LCM-PND "Package not
    // defined".) A hierarchical reference through the instance is legal in a
    // procedural context but not portable inside a constant bit-select range,
    // so constants here plus the runtime check below is the safe combination.
    // -------------------------------------------------------------------------
    localparam int QOP_MAX_QUEUE_WIDTH  = 32;
    localparam int QOP_MAX_PTR_WIDTH    = 32;
    localparam int QOP_MAX_AUX_WIDTH    = 64;
    localparam int QOP_MAX_CPL_WIDTH    = 32;
    localparam int QOP_MAX_TAG_WIDTH    = 16;
    localparam int QOP_MAX_OP_TAG_WIDTH = 16;
    localparam int AXIL_MAX_DATA_WIDTH  = 64;

    // Guard against the constants above drifting from the interfaces. A
    // hierarchical read of an interface localparam is legal here because this is
    // a procedural context, not a constant expression.
    initial begin
        if (QOP_MAX_QUEUE_WIDTH  !== qop_vif.MAX_QUEUE_WIDTH  ||
            QOP_MAX_PTR_WIDTH    !== qop_vif.MAX_PTR_WIDTH    ||
            QOP_MAX_AUX_WIDTH    !== qop_vif.MAX_AUX_WIDTH    ||
            QOP_MAX_CPL_WIDTH    !== qop_vif.MAX_CPL_WIDTH    ||
            QOP_MAX_TAG_WIDTH    !== qop_vif.MAX_TAG_WIDTH    ||
            QOP_MAX_OP_TAG_WIDTH !== qop_vif.MAX_OP_TAG_WIDTH ||
            AXIL_MAX_DATA_WIDTH  !== axil_vif.MAX_DATA_WIDTH)
            $fatal(1, {"tb_top_tier1a: interface maxima are out of step with ",
                       "queue_op_if.sv / axil_if.sv - update the localparams here"});
    end

    // Bits above the DUT's width are never driven by the DUT; hold them at 0 so
    // the monitor's masking has something defined to mask, and so the
    // $isunknown() assertions in the interfaces do not fire on undriven bits.
    initial begin
        qop_vif.resp_queue   [QOP_MAX_QUEUE_WIDTH-1:QUEUE_INDEX_WIDTH]    = '0;
        qop_vif.resp_ptr     [QOP_MAX_PTR_WIDTH-1:QUEUE_PTR_WIDTH]        = '0;
        qop_vif.resp_aux     [QOP_MAX_AUX_WIDTH-1:LOG_BLOCK_SIZE_WIDTH]   = '0;
        qop_vif.resp_cpl     [QOP_MAX_CPL_WIDTH-1:CPL_INDEX_WIDTH]        = '0;
        qop_vif.resp_tag     [QOP_MAX_TAG_WIDTH-1:REQ_TAG_WIDTH]          = '0;
        qop_vif.resp_op_tag  [QOP_MAX_OP_TAG_WIDTH-1:OP_TAG_WIDTH]        = '0;
        qop_vif.notify_source[QOP_MAX_QUEUE_WIDTH-1:QUEUE_INDEX_WIDTH]    = '0;
        qop_vif.notify_data                                               = '0;
        axil_vif.rdata       [AXIL_MAX_DATA_WIDTH-1:AXIL_DATA_WIDTH]      = '0;
    end

    // ---- DUT 2: cpl_queue_manager (enqueue side) ---------------------------
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
        .clk (clk),
        .rst (rst),

        .s_axis_enqueue_req_queue     (cq_qop_vif.req_queue[CQ_QUEUE_INDEX_WIDTH-1:0]),
        .s_axis_enqueue_req_tag       (cq_qop_vif.req_tag[REQ_TAG_WIDTH-1:0]),
        .s_axis_enqueue_req_valid     (cq_qop_vif.req_valid),
        .s_axis_enqueue_req_ready     (cq_qop_vif.req_ready),

        // aux <- event, blocked <- full  (see queue_op_if.sv header)
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

        // The event channel HAS a ready, unlike the dequeue doorbell.
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

    // Hold the cpl_queue_manager's undriven upper bits defined.
    initial begin
        cq_qop_vif.resp_queue   [QOP_MAX_QUEUE_WIDTH-1:CQ_QUEUE_INDEX_WIDTH] = '0;
        cq_qop_vif.resp_ptr     [QOP_MAX_PTR_WIDTH-1:QUEUE_PTR_WIDTH]        = '0;
        cq_qop_vif.resp_aux     [QOP_MAX_AUX_WIDTH-1:CQ_EVENT_WIDTH]         = '0;
        cq_qop_vif.resp_cpl                                                  = '0;
        cq_qop_vif.resp_tag     [QOP_MAX_TAG_WIDTH-1:REQ_TAG_WIDTH]          = '0;
        cq_qop_vif.resp_op_tag  [QOP_MAX_OP_TAG_WIDTH-1:OP_TAG_WIDTH]        = '0;
        cq_qop_vif.notify_source[QOP_MAX_QUEUE_WIDTH-1:CQ_QUEUE_INDEX_WIDTH] = '0;
        cq_qop_vif.notify_data  [QOP_MAX_AUX_WIDTH-1:CQ_EVENT_WIDTH]         = '0;
        cq_axil_vif.rdata       [AXIL_MAX_DATA_WIDTH-1:AXIL_DATA_WIDTH]      = '0;
    end

    // ---- UVM ----------------------------------------------------------------
    initial begin
        uvm_config_db #(virtual mqnic_reset_if)::set(null, "uvm_test_top", "rst_vif", rst_if);
        uvm_config_db #(virtual axil_if)::set(null, "uvm_test_top.m_env.m_cq_axil*", "vif", cq_axil_vif);
        uvm_config_db #(virtual queue_op_if)::set(null, "uvm_test_top.m_env.m_cq_qop*", "vif", cq_qop_vif);
        uvm_config_db #(virtual axil_if)::set(null, "uvm_test_top.m_env.m_axil*", "vif", axil_vif);
        uvm_config_db #(virtual queue_op_if)::set(null, "uvm_test_top.m_env.m_qop*", "vif", qop_vif);
        run_test();
    end

    initial begin
        if ($test$plusargs("WAVES")) begin
            $dumpfile("dump.vcd");
            $dumpvars(0, tb_top_tier1a);
        end
    end

endmodule : tb_top_tier1a

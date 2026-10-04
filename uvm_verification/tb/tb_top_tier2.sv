// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tb_top_tier2 - Tier 2 testbench top (segmented memory)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §18 Step 4
// Introduced : Step 4
//
// DUTs: dma_psdpram.v, dma_psdpram_async.v, dma_client_axis_sink.v and
// dma_client_axis_source.v - all unmodified.
// geometry - SEG_COUNT=2, SEG_DATA_WIDTH=128, SIZE=4096, so SEG_ADDR_WIDTH is
// $clog2(4096/(2*16)) = 7.
//
// init_idle_initiator() is called at time 0 rather than enumerating signals by
// hand. That is the Tier 1 lesson applied: an interface left at X fails
// unconditional assertions, and hand-written tie-off lists are exactly what
// missed tlp_sop/tlp_eop last time.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_top_tier2;

    import uvm_pkg::*;
`include "uvm_macros.svh"
    import mqnic_vrf_pkg::*;
    import mqnic_test_pkg::*;

    localparam int SIZE           = 4096;
    localparam int SEG_COUNT      = 2;
    localparam int SEG_DATA_WIDTH = 128;
    localparam int SEG_BE_WIDTH   = SEG_DATA_WIDTH / 8;          // 16
    localparam int SEG_ADDR_WIDTH = 7;                            // $clog2(128)
    localparam int PIPELINE       = 2;

    localparam int AXIS_MAX_DATA_WIDTH_T2 = 512;

    localparam time CLK_HALF_PERIOD = 2ns;

    logic clk;
    initial clk = 1'b0;
    always #CLK_HALF_PERIOD clk = ~clk;

    mqnic_reset_if rst_if (.clk(clk));
    wire rst = rst_if.rst;

    dma_ram_if ram_vif (.clk(clk), .rst(rst));

    // ---- second DUT: dma_psdpram_async --------------------------------------
    // Write and read clocks are DELIBERATELY at an awkward ratio. A 1:1 or 2:1
    // ratio lets edges line up in a repeating pattern and hides CDC bugs; 4ns
    // against 6ns never repeats a phase relationship, which is the entire point
    // of testing a clock-domain crossing. STRATEGY §5 puts this on a small DUT
    // so a CDC failure has one plausible cause.
    localparam time CLK_WR_HALF = 2ns;   // 250 MHz
    localparam time CLK_RD_HALF = 3ns;   // ~167 MHz

    logic clk_wr, clk_rd;
    initial clk_wr = 1'b0;
    initial clk_rd = 1'b0;
    always #CLK_WR_HALF clk_wr = ~clk_wr;
    always #CLK_RD_HALF clk_rd = ~clk_rd;

    mqnic_reset_if rst_wr_if (.clk(clk_wr));
    mqnic_reset_if rst_rd_if (.clk(clk_rd));
    wire rst_wr = rst_wr_if.rst;
    wire rst_rd = rst_rd_if.rst;

    // One interface per clock domain: a virtual interface carries a single
    // clock, so the write and read halves of the async RAM cannot share one.
    dma_ram_if aram_wr_vif (.clk(clk_wr), .rst(rst_wr));
    dma_ram_if aram_rd_vif (.clk(clk_rd), .rst(rst_rd));

    // ---- DMA stream clients --------------------------------------------------
    // RAM_ADDR_WIDTH=16, SEG_COUNT=2, SEG_DATA_WIDTH=64 gives
    // SEG_BE_WIDTH=8 and SEG_ADDR_WIDTH = 16 - $clog2(2*8) = 12, and an
    // AXI-Stream width of SEG_DATA_WIDTH*SEG_COUNT/2 = 64 bits.
    localparam int CLI_RAM_ADDR_WIDTH = 16;
    localparam int CLI_SEG_COUNT      = 2;
    localparam int CLI_SEG_DATA_WIDTH = 64;
    localparam int CLI_SEG_BE_WIDTH   = CLI_SEG_DATA_WIDTH / 8;      // 8
    localparam int CLI_SEG_ADDR_WIDTH = 12;
    localparam int CLI_AXIS_DATA_WIDTH = CLI_SEG_DATA_WIDTH * CLI_SEG_COUNT / 2;
    localparam int CLI_AXIS_KEEP_WIDTH = CLI_AXIS_DATA_WIDTH / 8;    // 8
    localparam int CLI_LEN_WIDTH      = 16;
    localparam int CLI_TAG_WIDTH      = 8;

    // sink : stream -> RAM      source : RAM -> stream
    dma_desc_if cli_wr_desc_vif (.clk(clk), .rst(rst));
    axis_if     cli_wr_pkt_vif  (.clk(clk), .rst(rst));
    dma_ram_if  cli_wr_ram_vif  (.clk(clk), .rst(rst));

    dma_desc_if cli_rd_desc_vif (.clk(clk), .rst(rst));
    axis_if     cli_rd_pkt_vif  (.clk(clk), .rst(rst));
    dma_ram_if  cli_rd_ram_vif  (.clk(clk), .rst(rst));


    // The interface is declared at maxima; the DUT gets only the bits it has.
    // Segment n's field lives at n*MAX_* in the interface, so each segment is
    // sliced out individually rather than passing one packed vector.
    wire [SEG_COUNT*SEG_BE_WIDTH-1:0]   dut_wr_cmd_be;
    wire [SEG_COUNT*SEG_ADDR_WIDTH-1:0] dut_wr_cmd_addr;
    wire [SEG_COUNT*SEG_DATA_WIDTH-1:0] dut_wr_cmd_data;
    wire [SEG_COUNT*SEG_ADDR_WIDTH-1:0] dut_rd_cmd_addr;
    wire [SEG_COUNT*SEG_DATA_WIDTH-1:0] dut_rd_resp_data;

    for (genvar s = 0; s < SEG_COUNT; s++) begin : g_seg
        assign dut_wr_cmd_be[s*SEG_BE_WIDTH +: SEG_BE_WIDTH] =
                   ram_vif.wr_cmd_be[s*DMA_RAM_MAX_SEG_BE_WIDTH +: SEG_BE_WIDTH];
        assign dut_wr_cmd_addr[s*SEG_ADDR_WIDTH +: SEG_ADDR_WIDTH] =
                   ram_vif.wr_cmd_addr[s*DMA_RAM_MAX_SEG_ADDR_WIDTH +: SEG_ADDR_WIDTH];
        assign dut_wr_cmd_data[s*SEG_DATA_WIDTH +: SEG_DATA_WIDTH] =
                   ram_vif.wr_cmd_data[s*DMA_RAM_MAX_SEG_DATA_WIDTH +: SEG_DATA_WIDTH];
        assign dut_rd_cmd_addr[s*SEG_ADDR_WIDTH +: SEG_ADDR_WIDTH] =
                   ram_vif.rd_cmd_addr[s*DMA_RAM_MAX_SEG_ADDR_WIDTH +: SEG_ADDR_WIDTH];
        assign ram_vif.rd_resp_data[s*DMA_RAM_MAX_SEG_DATA_WIDTH +: SEG_DATA_WIDTH] =
                   dut_rd_resp_data[s*SEG_DATA_WIDTH +: SEG_DATA_WIDTH];

        // Bits above the DUT's width are never driven by it.
        initial begin
            ram_vif.rd_resp_data[s*DMA_RAM_MAX_SEG_DATA_WIDTH + SEG_DATA_WIDTH
                                 +: (DMA_RAM_MAX_SEG_DATA_WIDTH - SEG_DATA_WIDTH)] = '0;
        end
    end

    dma_psdpram #(
        .SIZE           (SIZE),
        .SEG_COUNT      (SEG_COUNT),
        .SEG_DATA_WIDTH (SEG_DATA_WIDTH),
        .SEG_BE_WIDTH   (SEG_BE_WIDTH),
        .SEG_ADDR_WIDTH (SEG_ADDR_WIDTH),
        .PIPELINE       (PIPELINE)
    ) u_dma_psdpram (
        .clk           (clk),
        .rst           (rst),
        .wr_cmd_be     (dut_wr_cmd_be),
        .wr_cmd_addr   (dut_wr_cmd_addr),
        .wr_cmd_data   (dut_wr_cmd_data),
        .wr_cmd_valid  (ram_vif.wr_cmd_valid[SEG_COUNT-1:0]),
        .wr_cmd_ready  (ram_vif.wr_cmd_ready[SEG_COUNT-1:0]),
        .wr_done       (ram_vif.wr_done[SEG_COUNT-1:0]),
        .rd_cmd_addr   (dut_rd_cmd_addr),
        .rd_cmd_valid  (ram_vif.rd_cmd_valid[SEG_COUNT-1:0]),
        .rd_cmd_ready  (ram_vif.rd_cmd_ready[SEG_COUNT-1:0]),
        .rd_resp_data  (dut_rd_resp_data),
        .rd_resp_valid (ram_vif.rd_resp_valid[SEG_COUNT-1:0]),
        .rd_resp_ready (ram_vif.rd_resp_ready[SEG_COUNT-1:0])
    );

    // ---- dma_psdpram_async ---------------------------------------------------
    wire [SEG_COUNT*SEG_BE_WIDTH-1:0]   a_wr_cmd_be;
    wire [SEG_COUNT*SEG_ADDR_WIDTH-1:0] a_wr_cmd_addr;
    wire [SEG_COUNT*SEG_DATA_WIDTH-1:0] a_wr_cmd_data;
    wire [SEG_COUNT*SEG_ADDR_WIDTH-1:0] a_rd_cmd_addr;
    wire [SEG_COUNT*SEG_DATA_WIDTH-1:0] a_rd_resp_data;

    for (genvar s = 0; s < SEG_COUNT; s++) begin : g_aseg
        assign a_wr_cmd_be[s*SEG_BE_WIDTH +: SEG_BE_WIDTH] =
                   aram_wr_vif.wr_cmd_be[s*DMA_RAM_MAX_SEG_BE_WIDTH +: SEG_BE_WIDTH];
        assign a_wr_cmd_addr[s*SEG_ADDR_WIDTH +: SEG_ADDR_WIDTH] =
                   aram_wr_vif.wr_cmd_addr[s*DMA_RAM_MAX_SEG_ADDR_WIDTH +: SEG_ADDR_WIDTH];
        assign a_wr_cmd_data[s*SEG_DATA_WIDTH +: SEG_DATA_WIDTH] =
                   aram_wr_vif.wr_cmd_data[s*DMA_RAM_MAX_SEG_DATA_WIDTH +: SEG_DATA_WIDTH];
        assign a_rd_cmd_addr[s*SEG_ADDR_WIDTH +: SEG_ADDR_WIDTH] =
                   aram_rd_vif.rd_cmd_addr[s*DMA_RAM_MAX_SEG_ADDR_WIDTH +: SEG_ADDR_WIDTH];
        assign aram_rd_vif.rd_resp_data[s*DMA_RAM_MAX_SEG_DATA_WIDTH +: SEG_DATA_WIDTH] =
                   a_rd_resp_data[s*SEG_DATA_WIDTH +: SEG_DATA_WIDTH];
        initial
            aram_rd_vif.rd_resp_data[s*DMA_RAM_MAX_SEG_DATA_WIDTH + SEG_DATA_WIDTH
                                     +: (DMA_RAM_MAX_SEG_DATA_WIDTH - SEG_DATA_WIDTH)] = '0;
    end

    dma_psdpram_async #(
        .SIZE           (SIZE),
        .SEG_COUNT      (SEG_COUNT),
        .SEG_DATA_WIDTH (SEG_DATA_WIDTH),
        .SEG_BE_WIDTH   (SEG_BE_WIDTH),
        .SEG_ADDR_WIDTH (SEG_ADDR_WIDTH),
        .PIPELINE       (PIPELINE)
    ) u_dma_psdpram_async (
        .clk_wr        (clk_wr),
        .rst_wr        (rst_wr),
        .wr_cmd_be     (a_wr_cmd_be),
        .wr_cmd_addr   (a_wr_cmd_addr),
        .wr_cmd_data   (a_wr_cmd_data),
        .wr_cmd_valid  (aram_wr_vif.wr_cmd_valid[SEG_COUNT-1:0]),
        .wr_cmd_ready  (aram_wr_vif.wr_cmd_ready[SEG_COUNT-1:0]),
        .wr_done       (aram_wr_vif.wr_done[SEG_COUNT-1:0]),
        .clk_rd        (clk_rd),
        .rst_rd        (rst_rd),
        .rd_cmd_addr   (a_rd_cmd_addr),
        .rd_cmd_valid  (aram_rd_vif.rd_cmd_valid[SEG_COUNT-1:0]),
        .rd_cmd_ready  (aram_rd_vif.rd_cmd_ready[SEG_COUNT-1:0]),
        .rd_resp_data  (a_rd_resp_data),
        .rd_resp_valid (aram_rd_vif.rd_resp_valid[SEG_COUNT-1:0]),
        .rd_resp_ready (aram_rd_vif.rd_resp_ready[SEG_COUNT-1:0])
    );


    // ---- DUT 3: dma_client_axis_sink  (stream -> RAM) -----------------------
    //
    // EVERY DUT OUTPUT GOES THROUGH A LOCAL WIRE and reaches the interface by
    // continuous assign covering the FULL width. Two reasons, both learned from
    // VCS:
    //   * a procedural assignment to a signal the DUT also drives is an illegal
    //     mix of structural and procedural drivers (ICPSD) - a hard error;
    //   * driving only part of a variable structurally and the rest
    //     procedurally trips the same rule, because the driver check is per
    //     VARIABLE, not per bit.
    // So the upper bits are zero-extended inside the assign rather than being
    // initialised separately.
    wire                                        cw_tready;
    wire [CLI_SEG_COUNT-1:0]                    cw_ram_wr_valid;
    wire [CLI_SEG_COUNT*CLI_SEG_BE_WIDTH-1:0]   cw_ram_be;
    wire [CLI_SEG_COUNT*CLI_SEG_ADDR_WIDTH-1:0] cw_ram_addr;
    wire [CLI_SEG_COUNT*CLI_SEG_DATA_WIDTH-1:0] cw_ram_data;

    for (genvar s = 0; s < CLI_SEG_COUNT; s++) begin : g_cw
        assign cli_wr_ram_vif.wr_cmd_be[s*DMA_RAM_MAX_SEG_BE_WIDTH +: CLI_SEG_BE_WIDTH] =
                   cw_ram_be[s*CLI_SEG_BE_WIDTH +: CLI_SEG_BE_WIDTH];
        assign cli_wr_ram_vif.wr_cmd_addr[s*DMA_RAM_MAX_SEG_ADDR_WIDTH +: CLI_SEG_ADDR_WIDTH] =
                   cw_ram_addr[s*CLI_SEG_ADDR_WIDTH +: CLI_SEG_ADDR_WIDTH];
        assign cli_wr_ram_vif.wr_cmd_data[s*DMA_RAM_MAX_SEG_DATA_WIDTH +: CLI_SEG_DATA_WIDTH] =
                   cw_ram_data[s*CLI_SEG_DATA_WIDTH +: CLI_SEG_DATA_WIDTH];
    end

    dma_client_axis_sink #(
        .RAM_ADDR_WIDTH  (CLI_RAM_ADDR_WIDTH),
        .SEG_COUNT       (CLI_SEG_COUNT),
        .SEG_DATA_WIDTH  (CLI_SEG_DATA_WIDTH),
        .SEG_BE_WIDTH    (CLI_SEG_BE_WIDTH),
        .SEG_ADDR_WIDTH  (CLI_SEG_ADDR_WIDTH),
        .AXIS_DATA_WIDTH (CLI_AXIS_DATA_WIDTH),
        .AXIS_KEEP_WIDTH (CLI_AXIS_KEEP_WIDTH),
        .AXIS_ID_ENABLE  (0),
        .AXIS_DEST_ENABLE(0),
        .AXIS_USER_ENABLE(1),
        .AXIS_USER_WIDTH (1),
        .LEN_WIDTH       (CLI_LEN_WIDTH),
        .TAG_WIDTH       (CLI_TAG_WIDTH)
    ) u_dma_client_axis_sink (
        .clk (clk), .rst (rst),
        .s_axis_write_desc_ram_addr   (cli_wr_desc_vif.req_ram_addr[CLI_RAM_ADDR_WIDTH-1:0]),
        .s_axis_write_desc_len        (cli_wr_desc_vif.req_len[CLI_LEN_WIDTH-1:0]),
        .s_axis_write_desc_tag        (cli_wr_desc_vif.req_tag[CLI_TAG_WIDTH-1:0]),
        .s_axis_write_desc_valid      (cli_wr_desc_vif.req_valid),
        .s_axis_write_desc_ready      (cli_wr_desc_vif.req_ready),
        .m_axis_write_desc_status_len (cli_wr_desc_vif.sts_len[CLI_LEN_WIDTH-1:0]),
        .m_axis_write_desc_status_tag (cli_wr_desc_vif.sts_tag[CLI_TAG_WIDTH-1:0]),
        .m_axis_write_desc_status_id  (cli_wr_desc_vif.sts_id),
        .m_axis_write_desc_status_dest(cli_wr_desc_vif.sts_dest),
        .m_axis_write_desc_status_user(cli_wr_desc_vif.sts_user[0]),
        .m_axis_write_desc_status_error(cli_wr_desc_vif.sts_error),
        .m_axis_write_desc_status_valid(cli_wr_desc_vif.sts_valid),
        .s_axis_write_data_tdata      (cli_wr_pkt_vif.tdata[CLI_AXIS_DATA_WIDTH-1:0]),
        .s_axis_write_data_tkeep      (cli_wr_pkt_vif.tkeep[CLI_AXIS_KEEP_WIDTH-1:0]),
        .s_axis_write_data_tvalid     (cli_wr_pkt_vif.tvalid),
        .s_axis_write_data_tready     (cw_tready),
        .s_axis_write_data_tlast      (cli_wr_pkt_vif.tlast),
        .s_axis_write_data_tid        (cli_wr_pkt_vif.tid),
        .s_axis_write_data_tdest      (cli_wr_pkt_vif.tdest),
        .s_axis_write_data_tuser      (cli_wr_pkt_vif.tuser[0]),
        .ram_wr_cmd_be                (cw_ram_be),
        .ram_wr_cmd_addr              (cw_ram_addr),
        .ram_wr_cmd_data              (cw_ram_data),
        .ram_wr_cmd_valid             (cw_ram_wr_valid),
        .ram_wr_cmd_ready             (cli_wr_ram_vif.wr_cmd_ready[CLI_SEG_COUNT-1:0]),
        .ram_wr_done                  (cli_wr_ram_vif.wr_done[CLI_SEG_COUNT-1:0]),
        .enable                       (1'b1),
        .abort                        (1'b0)
    );


    assign cli_wr_pkt_vif.tready = cw_tready;
    assign cli_wr_ram_vif.wr_cmd_valid =
               {{(DMA_RAM_MAX_SEG_COUNT-CLI_SEG_COUNT){1'b0}}, cw_ram_wr_valid};

    // ---- DUT 4: dma_client_axis_source  (RAM -> stream) ---------------------
    wire [CLI_SEG_COUNT*CLI_SEG_ADDR_WIDTH-1:0] cr_ram_addr;
    wire [CLI_SEG_COUNT*CLI_SEG_DATA_WIDTH-1:0] cr_ram_data;
    wire [CLI_SEG_COUNT-1:0]                    cr_ram_rd_valid;
    wire [CLI_SEG_COUNT-1:0]                    cr_ram_resp_ready;
    wire [CLI_AXIS_DATA_WIDTH-1:0]              cr_tdata;
    wire [CLI_AXIS_KEEP_WIDTH-1:0]              cr_tkeep;
    wire                                        cr_tvalid;
    wire                                        cr_tlast;
    wire                                        cr_tuser;

    for (genvar s = 0; s < CLI_SEG_COUNT; s++) begin : g_cr
        assign cli_rd_ram_vif.rd_cmd_addr[s*DMA_RAM_MAX_SEG_ADDR_WIDTH +: CLI_SEG_ADDR_WIDTH] =
                   cr_ram_addr[s*CLI_SEG_ADDR_WIDTH +: CLI_SEG_ADDR_WIDTH];
        assign cr_ram_data[s*CLI_SEG_DATA_WIDTH +: CLI_SEG_DATA_WIDTH] =
                   cli_rd_ram_vif.rd_resp_data[s*DMA_RAM_MAX_SEG_DATA_WIDTH +: CLI_SEG_DATA_WIDTH];
    end

    dma_client_axis_source #(
        .RAM_ADDR_WIDTH  (CLI_RAM_ADDR_WIDTH),
        .SEG_COUNT       (CLI_SEG_COUNT),
        .SEG_DATA_WIDTH  (CLI_SEG_DATA_WIDTH),
        .SEG_BE_WIDTH    (CLI_SEG_BE_WIDTH),
        .SEG_ADDR_WIDTH  (CLI_SEG_ADDR_WIDTH),
        .AXIS_DATA_WIDTH (CLI_AXIS_DATA_WIDTH),
        .AXIS_KEEP_WIDTH (CLI_AXIS_KEEP_WIDTH),
        .AXIS_ID_ENABLE  (0),
        .AXIS_DEST_ENABLE(0),
        .AXIS_USER_ENABLE(1),
        .AXIS_USER_WIDTH (1),
        .LEN_WIDTH       (CLI_LEN_WIDTH),
        .TAG_WIDTH       (CLI_TAG_WIDTH)
    ) u_dma_client_axis_source (
        .clk (clk), .rst (rst),
        .s_axis_read_desc_ram_addr    (cli_rd_desc_vif.req_ram_addr[CLI_RAM_ADDR_WIDTH-1:0]),
        .s_axis_read_desc_len         (cli_rd_desc_vif.req_len[CLI_LEN_WIDTH-1:0]),
        .s_axis_read_desc_tag         (cli_rd_desc_vif.req_tag[CLI_TAG_WIDTH-1:0]),
        .s_axis_read_desc_id          (cli_rd_desc_vif.req_id),
        .s_axis_read_desc_dest        (cli_rd_desc_vif.req_dest),
        .s_axis_read_desc_user        (cli_rd_desc_vif.req_user[0]),
        .s_axis_read_desc_valid       (cli_rd_desc_vif.req_valid),
        .s_axis_read_desc_ready       (cli_rd_desc_vif.req_ready),
        .m_axis_read_desc_status_tag  (cli_rd_desc_vif.sts_tag[CLI_TAG_WIDTH-1:0]),
        .m_axis_read_desc_status_error(cli_rd_desc_vif.sts_error),
        .m_axis_read_desc_status_valid(cli_rd_desc_vif.sts_valid),
        .m_axis_read_data_tdata       (cr_tdata),
        .m_axis_read_data_tkeep       (cr_tkeep),
        .m_axis_read_data_tvalid      (cr_tvalid),
        .m_axis_read_data_tready      (cli_rd_pkt_vif.tready),
        .m_axis_read_data_tlast       (cr_tlast),
        .m_axis_read_data_tid         (),
        .m_axis_read_data_tdest       (),
        .m_axis_read_data_tuser       (cr_tuser),
        .ram_rd_cmd_addr              (cr_ram_addr),
        .ram_rd_cmd_valid             (cr_ram_rd_valid),
        .ram_rd_cmd_ready             (cli_rd_ram_vif.rd_cmd_ready[CLI_SEG_COUNT-1:0]),
        .ram_rd_resp_data             (cr_ram_data),
        .ram_rd_resp_valid            (cli_rd_ram_vif.rd_resp_valid[CLI_SEG_COUNT-1:0]),
        .ram_rd_resp_ready            (cr_ram_resp_ready),
        .enable                       (1'b1)
    );


    assign cli_rd_pkt_vif.tdata  = {{(AXIS_MAX_DATA_WIDTH_T2-CLI_AXIS_DATA_WIDTH){1'b0}},
                                    cr_tdata};
    assign cli_rd_pkt_vif.tkeep  = {{(64-CLI_AXIS_KEEP_WIDTH){1'b0}}, cr_tkeep};
    assign cli_rd_pkt_vif.tvalid = cr_tvalid;
    assign cli_rd_pkt_vif.tlast  = cr_tlast;
    assign cli_rd_pkt_vif.tuser  = {127'd0, cr_tuser};
    assign cli_rd_pkt_vif.tid    = '0;
    assign cli_rd_pkt_vif.tdest  = '0;

    assign cli_rd_ram_vif.rd_cmd_valid =
               {{(DMA_RAM_MAX_SEG_COUNT-CLI_SEG_COUNT){1'b0}}, cr_ram_rd_valid};
    assign cli_rd_ram_vif.rd_resp_ready =
               {{(DMA_RAM_MAX_SEG_COUNT-CLI_SEG_COUNT){1'b0}}, cr_ram_resp_ready};

    initial begin
        // One call instead of a hand-written signal list. See the file header.
        ram_vif.init_idle_initiator();
        // The clients DRIVE the RAM side, so the TB responds there: only the
        // responder half needs idling, and the requester half of the desc
        // interfaces is TB-driven.
        cli_wr_desc_vif.init_idle_requester();
        cli_rd_desc_vif.init_idle_requester();
        cli_wr_ram_vif.init_idle_responder();
        cli_rd_ram_vif.init_idle_responder();

        // Channels each client does not use.
        cli_wr_ram_vif.rd_cmd_ready  = '0;
        cli_wr_ram_vif.rd_resp_data  = '0;
        cli_wr_ram_vif.rd_resp_valid = '0;
        cli_rd_ram_vif.wr_cmd_ready  = '0;
        cli_rd_ram_vif.wr_done       = '0;



        aram_wr_vif.init_idle_initiator();
        aram_rd_vif.init_idle_initiator();

        // Each async interface uses only half the signals; the other half has
        // no driver at all, so give it a defined value.
        aram_wr_vif.rd_cmd_ready  = '0;
        aram_wr_vif.rd_resp_data  = '0;
        aram_wr_vif.rd_resp_valid = '0;
        aram_rd_vif.wr_cmd_ready  = '0;
        aram_rd_vif.wr_done       = '0;

        aram_wr_vif.wr_cmd_ready [DMA_RAM_MAX_SEG_COUNT-1:SEG_COUNT] = '0;
        aram_wr_vif.wr_done      [DMA_RAM_MAX_SEG_COUNT-1:SEG_COUNT] = '0;
        aram_rd_vif.rd_cmd_ready [DMA_RAM_MAX_SEG_COUNT-1:SEG_COUNT] = '0;
        aram_rd_vif.rd_resp_valid[DMA_RAM_MAX_SEG_COUNT-1:SEG_COUNT] = '0;
        // Segments the DUT does not have: hold their DUT-driven bits defined.
        ram_vif.wr_cmd_ready [DMA_RAM_MAX_SEG_COUNT-1:SEG_COUNT] = '0;
        ram_vif.wr_done      [DMA_RAM_MAX_SEG_COUNT-1:SEG_COUNT] = '0;
        ram_vif.rd_cmd_ready [DMA_RAM_MAX_SEG_COUNT-1:SEG_COUNT] = '0;
        ram_vif.rd_resp_valid[DMA_RAM_MAX_SEG_COUNT-1:SEG_COUNT] = '0;
    end

    initial begin
        uvm_config_db #(virtual mqnic_reset_if)::set(null, "uvm_test_top", "rst_vif", rst_if);
        uvm_config_db #(virtual dma_ram_if)::set(null, "uvm_test_top.m_env.m_ram*",     "vif", ram_vif);
        uvm_config_db #(virtual dma_ram_if)::set(null, "uvm_test_top.m_env.m_aram_wr*", "vif", aram_wr_vif);
        uvm_config_db #(virtual dma_ram_if)::set(null, "uvm_test_top.m_env.m_aram_rd*", "vif", aram_rd_vif);
        uvm_config_db #(virtual dma_desc_if)::set(null, "uvm_test_top.m_env.m_cli_wr_desc*", "vif", cli_wr_desc_vif);
        uvm_config_db #(virtual axis_if)::set    (null, "uvm_test_top.m_env.m_cli_wr_pkt*",  "vif", cli_wr_pkt_vif);
        uvm_config_db #(virtual dma_ram_if)::set (null, "uvm_test_top.m_env.m_cli_wr_ram*",  "vif", cli_wr_ram_vif);
        uvm_config_db #(virtual dma_desc_if)::set(null, "uvm_test_top.m_env.m_cli_rd_desc*", "vif", cli_rd_desc_vif);
        uvm_config_db #(virtual axis_if)::set    (null, "uvm_test_top.m_env.m_cli_rd_pkt*",  "vif", cli_rd_pkt_vif);
        uvm_config_db #(virtual dma_ram_if)::set (null, "uvm_test_top.m_env.m_cli_rd_ram*",  "vif", cli_rd_ram_vif);
        uvm_config_db #(virtual mqnic_reset_if)::set(null, "uvm_test_top", "rst_wr_vif", rst_wr_if);
        uvm_config_db #(virtual mqnic_reset_if)::set(null, "uvm_test_top", "rst_rd_vif", rst_rd_if);
        run_test();
    end

    initial begin
        if ($test$plusargs("WAVES")) begin
            $dumpfile("dump.vcd");
            $dumpvars(0, tb_top_tier2);
        end
    end

endmodule : tb_top_tier2

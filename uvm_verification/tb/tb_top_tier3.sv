// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tb_top_tier3 - Tier 3a testbench top (dma_if_pcie_rd)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §18 Step 5
// Introduced : Step 5
//
// DUT: fpga/lib/pcie/rtl/dma_if_pcie_rd.v, unmodified, at 256-bit TLP data with
// one segment - the configuration mqnic_core_pcie uses. The RAM side is
// DOUBLE WIDTH by construction (RAM_SEG_COUNT = TLP_SEG_COUNT*2), which is what
// lets the DMA realign data in a single cycle.
//
// Every DUT output reaches its interface by a CONTINUOUS ASSIGN over the full
// width, never by procedural assignment. VCS rejects the mixture (ICPSD) and the
// check is per variable, not per bit - the Tier 2 lesson, applied from the start
// here rather than after a failed compile.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_top_tier3;

    import uvm_pkg::*;
`include "uvm_macros.svh"
    import mqnic_vrf_pkg::*;
    import mqnic_test_pkg::*;

    // ---- golden configuration ------------------------------------------------
    localparam int TLP_DATA_WIDTH     = 256;
    localparam int TLP_STRB_WIDTH     = TLP_DATA_WIDTH / 32;      // 8
    localparam int TLP_HDR_WIDTH      = 128;
    localparam int TLP_SEG_COUNT      = 1;
    localparam int TX_SEQ_NUM_COUNT   = 1;
    localparam int TX_SEQ_NUM_WIDTH   = 6;
    localparam int RAM_SEL_WIDTH      = 2;
    localparam int RAM_ADDR_WIDTH     = 16;
    localparam int RAM_SEG_COUNT      = TLP_SEG_COUNT * 2;        // 2
    localparam int RAM_SEG_DATA_WIDTH = TLP_DATA_WIDTH * 2 / RAM_SEG_COUNT;  // 256
    localparam int RAM_SEG_BE_WIDTH   = RAM_SEG_DATA_WIDTH / 8;   // 32
    localparam int RAM_SEG_ADDR_WIDTH = 10;                       // 16 - clog2(2*32)
    localparam int PCIE_ADDR_WIDTH    = 64;
    localparam int PCIE_TAG_COUNT     = 256;
    localparam int LEN_WIDTH          = 16;
    localparam int TAG_WIDTH          = 8;

    localparam int TLP_MAX_DATA_WIDTH = 512;
    localparam int TLP_MAX_STRB_WIDTH = 16;
    localparam int TLP_MAX_SEG_COUNT  = 4;

    localparam time CLK_HALF_PERIOD = 2ns;

    logic clk;
    initial clk = 1'b0;
    always #CLK_HALF_PERIOD clk = ~clk;

    mqnic_reset_if rst_if (.clk(clk));
    wire rst = rst_if.rst;

    // ---- interfaces -----------------------------------------------------------
    dma_desc_if desc_vif   (.clk(clk), .rst(rst));
    pcie_tlp_if rd_req_vif (.clk(clk), .rst(rst));
    pcie_tlp_if rx_cpl_vif (.clk(clk), .rst(rst));
    dma_ram_if  ram_vif    (.clk(clk), .rst(rst));

    // Quasi-static configuration pins. An interface rather than constants so a
    // test can actually reach the MRRS / RCB / ext-tag axes of the §14.3 cross.
    dma_if_cfg_if cfg_vif ();
    initial cfg_vif.init_golden();

    // ---- DUT-driven nets ------------------------------------------------------
    wire [TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]      d_rd_req_hdr;
    wire [TLP_SEG_COUNT*TX_SEQ_NUM_WIDTH-1:0]   d_rd_req_seq;
    wire [TLP_SEG_COUNT-1:0]                    d_rd_req_valid;
    wire [TLP_SEG_COUNT-1:0]                    d_rd_req_sop;
    wire [TLP_SEG_COUNT-1:0]                    d_rd_req_eop;

    wire [TAG_WIDTH-1:0]                        d_sts_tag;
    wire [3:0]                                  d_sts_error;
    wire                                        d_sts_valid;
    wire                                        d_desc_ready;

    wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]      d_ram_sel;
    wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]   d_ram_be;
    wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0] d_ram_addr;
    wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] d_ram_data;
    wire [RAM_SEG_COUNT-1:0]                    d_ram_valid;

    wire                                        d_rx_cpl_ready;

    // ---- DUT ------------------------------------------------------------------
    dma_if_pcie_rd #(
        .TLP_DATA_WIDTH     (TLP_DATA_WIDTH),
        .TLP_HDR_WIDTH      (TLP_HDR_WIDTH),
        .TLP_SEG_COUNT      (TLP_SEG_COUNT),
        .TX_SEQ_NUM_COUNT   (TX_SEQ_NUM_COUNT),
        .TX_SEQ_NUM_WIDTH   (TX_SEQ_NUM_WIDTH),
        .TX_SEQ_NUM_ENABLE  (0),
        .RAM_SEL_WIDTH      (RAM_SEL_WIDTH),
        .RAM_ADDR_WIDTH     (RAM_ADDR_WIDTH),
        .RAM_SEG_COUNT      (RAM_SEG_COUNT),
        .RAM_SEG_DATA_WIDTH (RAM_SEG_DATA_WIDTH),
        .RAM_SEG_BE_WIDTH   (RAM_SEG_BE_WIDTH),
        .RAM_SEG_ADDR_WIDTH (RAM_SEG_ADDR_WIDTH),
        .PCIE_ADDR_WIDTH    (PCIE_ADDR_WIDTH),
        .PCIE_TAG_COUNT     (PCIE_TAG_COUNT),
        .LEN_WIDTH          (LEN_WIDTH),
        .TAG_WIDTH          (TAG_WIDTH),
        .CHECK_BUS_NUMBER   (0)
    ) u_dma_if_pcie_rd (
        .clk (clk),
        .rst (rst),

        // completions in
        .rx_cpl_tlp_data   (rx_cpl_vif.tlp_data[TLP_DATA_WIDTH-1:0]),
        .rx_cpl_tlp_hdr    (rx_cpl_vif.tlp_hdr[TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]),
        .rx_cpl_tlp_error  (rx_cpl_vif.tlp_error[TLP_SEG_COUNT*4-1:0]),
        .rx_cpl_tlp_valid  (rx_cpl_vif.tlp_valid[TLP_SEG_COUNT-1:0]),
        .rx_cpl_tlp_sop    (rx_cpl_vif.tlp_sop[TLP_SEG_COUNT-1:0]),
        .rx_cpl_tlp_eop    (rx_cpl_vif.tlp_eop[TLP_SEG_COUNT-1:0]),
        .rx_cpl_tlp_ready  (d_rx_cpl_ready),

        // read requests out
        .tx_rd_req_tlp_hdr   (d_rd_req_hdr),
        .tx_rd_req_tlp_seq   (d_rd_req_seq),
        .tx_rd_req_tlp_valid (d_rd_req_valid),
        .tx_rd_req_tlp_sop   (d_rd_req_sop),
        .tx_rd_req_tlp_eop   (d_rd_req_eop),
        .tx_rd_req_tlp_ready (rd_req_vif.tlp_ready),

        // TX_SEQ_NUM_ENABLE=0, so the DUT does not wait on these.
        .s_axis_tx_seq_num       ('0),
        .s_axis_tx_seq_num_valid ('0),

        // descriptor in
        .s_axis_read_desc_pcie_addr (desc_vif.req_pcie_addr[PCIE_ADDR_WIDTH-1:0]),
        .s_axis_read_desc_ram_sel   (desc_vif.req_ram_sel[RAM_SEL_WIDTH-1:0]),
        .s_axis_read_desc_ram_addr  (desc_vif.req_ram_addr[RAM_ADDR_WIDTH-1:0]),
        .s_axis_read_desc_len       (desc_vif.req_len[LEN_WIDTH-1:0]),
        .s_axis_read_desc_tag       (desc_vif.req_tag[TAG_WIDTH-1:0]),
        .s_axis_read_desc_valid     (desc_vif.req_valid),
        .s_axis_read_desc_ready     (d_desc_ready),

        // status out
        .m_axis_read_desc_status_tag   (d_sts_tag),
        .m_axis_read_desc_status_error (d_sts_error),
        .m_axis_read_desc_status_valid (d_sts_valid),

        // RAM out
        .ram_wr_cmd_sel   (d_ram_sel),
        .ram_wr_cmd_be    (d_ram_be),
        .ram_wr_cmd_addr  (d_ram_addr),
        .ram_wr_cmd_data  (d_ram_data),
        .ram_wr_cmd_valid (d_ram_valid),
        .ram_wr_cmd_ready (ram_vif.wr_cmd_ready[RAM_SEG_COUNT-1:0]),
        .ram_wr_done      (ram_vif.wr_done[RAM_SEG_COUNT-1:0]),

        // configuration
        .enable                (cfg_vif.enable),
        .ext_tag_enable        (cfg_vif.ext_tag_enable),
        .rcb_128b              (cfg_vif.rcb_128b),
        .requester_id          (cfg_vif.requester_id),
        .max_read_request_size (cfg_vif.max_read_request_size),

        // status_busy is deliberately not routed to the TB. A test drains on
        // "every descriptor produced a status", which is a CHECK the DUT must
        // pass, not a hint it volunteers about its own state.
        .status_busy        (),
        .status_error_cor   (),
        .status_error_uncor (),

        .stat_rd_op_start_tag        (),
        .stat_rd_op_start_len        (),
        .stat_rd_op_start_valid      (),
        .stat_rd_op_finish_tag       (),
        .stat_rd_op_finish_status    (),
        .stat_rd_op_finish_valid     (),
        .stat_rd_req_start_tag       (),
        .stat_rd_req_start_len       (),
        .stat_rd_req_start_valid     (),
        .stat_rd_req_finish_tag      (),
        .stat_rd_req_finish_status   (),
        .stat_rd_req_finish_valid    (),
        .stat_rd_req_timeout         (),
        .stat_rd_op_table_full       (),
        .stat_rd_no_tags             (),
        .stat_rd_tx_limit            (),
        .stat_rd_tx_stall            ()
    );

    // ---- DUT outputs -> interfaces, continuous assigns over the full width ----
    assign rd_req_vif.tlp_hdr =
        {{(TLP_MAX_SEG_COUNT*TLP_HDR_WIDTH - TLP_SEG_COUNT*TLP_HDR_WIDTH){1'b0}},
         d_rd_req_hdr};
    assign rd_req_vif.tlp_seq =
        {{(TLP_MAX_SEG_COUNT*6 - TLP_SEG_COUNT*TX_SEQ_NUM_WIDTH){1'b0}}, d_rd_req_seq};
    assign rd_req_vif.tlp_valid =
        {{(TLP_MAX_SEG_COUNT-TLP_SEG_COUNT){1'b0}}, d_rd_req_valid};
    assign rd_req_vif.tlp_sop =
        {{(TLP_MAX_SEG_COUNT-TLP_SEG_COUNT){1'b0}}, d_rd_req_sop};
    assign rd_req_vif.tlp_eop =
        {{(TLP_MAX_SEG_COUNT-TLP_SEG_COUNT){1'b0}}, d_rd_req_eop};
    assign rd_req_vif.tlp_data     = '0;   // read requests carry no payload
    assign rd_req_vif.tlp_strb     = '0;
    assign rd_req_vif.tlp_bar_id   = '0;
    assign rd_req_vif.tlp_func_num = '0;
    assign rd_req_vif.tlp_error    = '0;

    assign rx_cpl_vif.tlp_ready = d_rx_cpl_ready;

    assign desc_vif.req_ready = d_desc_ready;
    assign desc_vif.sts_tag   = {{(DMA_DESC_MAX_TAG_WIDTH-TAG_WIDTH){1'b0}}, d_sts_tag};
    assign desc_vif.sts_error = d_sts_error;
    assign desc_vif.sts_valid = d_sts_valid;
    assign desc_vif.sts_len   = '0;   // the read side reports no length
    assign desc_vif.sts_id    = '0;
    assign desc_vif.sts_dest  = '0;
    assign desc_vif.sts_user  = '0;

    for (genvar s = 0; s < RAM_SEG_COUNT; s++) begin : g_ram
        assign ram_vif.wr_cmd_sel[s*DMA_RAM_MAX_SEL_WIDTH +: DMA_RAM_MAX_SEL_WIDTH] =
            {{(DMA_RAM_MAX_SEL_WIDTH-RAM_SEL_WIDTH){1'b0}},
             d_ram_sel[s*RAM_SEL_WIDTH +: RAM_SEL_WIDTH]};
        assign ram_vif.wr_cmd_be[s*DMA_RAM_MAX_SEG_BE_WIDTH +: DMA_RAM_MAX_SEG_BE_WIDTH] =
            d_ram_be[s*RAM_SEG_BE_WIDTH +: RAM_SEG_BE_WIDTH];
        assign ram_vif.wr_cmd_addr[s*DMA_RAM_MAX_SEG_ADDR_WIDTH +: DMA_RAM_MAX_SEG_ADDR_WIDTH] =
            {{(DMA_RAM_MAX_SEG_ADDR_WIDTH-RAM_SEG_ADDR_WIDTH){1'b0}},
             d_ram_addr[s*RAM_SEG_ADDR_WIDTH +: RAM_SEG_ADDR_WIDTH]};
        assign ram_vif.wr_cmd_data[s*DMA_RAM_MAX_SEG_DATA_WIDTH +: DMA_RAM_MAX_SEG_DATA_WIDTH] =
            d_ram_data[s*RAM_SEG_DATA_WIDTH +: RAM_SEG_DATA_WIDTH];
    end
    assign ram_vif.wr_cmd_valid =
        {{(DMA_RAM_MAX_SEG_COUNT-RAM_SEG_COUNT){1'b0}}, d_ram_valid};

    // ---- idle the TB-driven halves -------------------------------------------
    initial begin
        // dma_if_pcie_rd ties tx_rd_req_tlp_sop/eop to constant 1'b1
        // (dma_if_pcie_rd.v:484-485): the request channel is single-segment and
        // header-only, so valid alone qualifies a beat. Legal, but it means the
        // "sop implies valid" property does not apply to this instance.
        rd_req_vif.sop_eop_gated = 1'b0;

        desc_vif.init_idle_requester();
        // TB-driven by pcie_tlp_driver, which clears sop/eop with valid,
        // so the stronger framing check applies here.
        rx_cpl_vif.sop_eop_gated = 1'b1;

        rx_cpl_vif.tlp_data     = '0;
        rx_cpl_vif.tlp_strb     = '0;
        rx_cpl_vif.tlp_hdr      = '0;
        rx_cpl_vif.tlp_seq      = '0;
        rx_cpl_vif.tlp_bar_id   = '0;
        rx_cpl_vif.tlp_func_num = '0;
        rx_cpl_vif.tlp_error    = '0;
        rx_cpl_vif.tlp_valid    = '0;
        rx_cpl_vif.tlp_sop      = '0;
        rx_cpl_vif.tlp_eop      = '0;

        ram_vif.init_idle_responder();
        ram_vif.rd_cmd_valid  = '0;
        ram_vif.rd_cmd_addr   = '0;
        ram_vif.rd_cmd_sel    = '0;
        ram_vif.rd_resp_ready = '0;
    end

    // ---- UVM ------------------------------------------------------------------
    initial begin
        uvm_config_db #(virtual mqnic_reset_if)::set(null, "uvm_test_top", "rst_vif", rst_if);
        uvm_config_db #(virtual dma_desc_if)::set(null, "uvm_test_top.m_env.m_desc*",   "vif", desc_vif);
        uvm_config_db #(virtual pcie_tlp_if)::set(null, "uvm_test_top.m_env.m_rd_req*", "vif", rd_req_vif);
        uvm_config_db #(virtual pcie_tlp_if)::set(null, "uvm_test_top.m_env.m_rx_cpl*", "vif", rx_cpl_vif);
        uvm_config_db #(virtual dma_ram_if)::set (null, "uvm_test_top.m_env.m_ram*",    "vif", ram_vif);
        uvm_config_db #(virtual dma_if_cfg_if)::set(null, "uvm_test_top", "cfg_vif", cfg_vif);
        run_test();
    end

    initial begin
        if ($test$plusargs("WAVES")) begin
            $dumpfile("dump.vcd");
            $dumpvars(0, tb_top_tier3);
        end
    end

endmodule : tb_top_tier3

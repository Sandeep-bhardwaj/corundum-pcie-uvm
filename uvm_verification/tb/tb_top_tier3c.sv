// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tb_top_tier3c - Tier 3c testbench top (full dma_if_pcie)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §18 Step 5
// Introduced : Step 5 (Tier 3c)
//
// DUT: fpga/lib/pcie/rtl/dma_if_pcie.v, unmodified. It instantiates
// dma_if_pcie_rd and dma_if_pcie_wr, so the Tier 3a and 3b bind files BOTH
// attach here and their assertions run against the integrated design without
// any change - which is the return on writing them black-box.
//
// TX_SEQ_NUM_WIDTH is 5 here, not 6. That is the wrapper's own default
// (dma_if_pcie.v:46) and it changes READ_TX_LIMIT and WRITE_OP_TABLE_SIZE,
// which are 2**TX_SEQ_NUM_WIDTH. Carrying 6 over from Tier 3a would silently
// verify a configuration the wrapper never instantiates.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_top_tier3c;

    import uvm_pkg::*;
`include "uvm_macros.svh"
    import mqnic_vrf_pkg::*;
    import mqnic_test_pkg::*;

    localparam int TLP_DATA_WIDTH     = 256;
    localparam int TLP_STRB_WIDTH     = TLP_DATA_WIDTH / 32;      // 8
    localparam int TLP_HDR_WIDTH      = 128;
    localparam int TLP_SEG_COUNT      = 1;
    localparam int TX_SEQ_NUM_COUNT   = 1;
    localparam int TX_SEQ_NUM_WIDTH   = 5;                        // wrapper default
    localparam int RAM_SEL_WIDTH      = 2;
    localparam int RAM_ADDR_WIDTH     = 16;
    localparam int RAM_SEG_COUNT      = TLP_SEG_COUNT * 2;
    localparam int RAM_SEG_DATA_WIDTH = TLP_DATA_WIDTH * 2 / RAM_SEG_COUNT;
    localparam int RAM_SEG_BE_WIDTH   = RAM_SEG_DATA_WIDTH / 8;
    localparam int RAM_SEG_ADDR_WIDTH = 10;
    localparam int PCIE_ADDR_WIDTH    = 64;
    localparam int PCIE_TAG_COUNT     = 256;
    localparam int IMM_ENABLE         = 1;
    localparam int IMM_WIDTH          = 32;
    localparam int LEN_WIDTH          = 16;
    localparam int TAG_WIDTH          = 8;

    localparam int TLP_MAX_SEG_COUNT  = 4;
    localparam int TLP_MAX_DATA_WIDTH = 512;
    localparam int TLP_MAX_STRB_WIDTH = 16;

    localparam time CLK_HALF_PERIOD = 2ns;

    logic clk;
    initial clk = 1'b0;
    always #CLK_HALF_PERIOD clk = ~clk;

    mqnic_reset_if rst_if (.clk(clk));
    wire rst = rst_if.rst;

    dma_desc_if   rd_desc_vif (.clk(clk), .rst(rst));
    dma_desc_if   wr_desc_vif (.clk(clk), .rst(rst));
    pcie_tlp_if   rd_req_vif  (.clk(clk), .rst(rst));
    pcie_tlp_if   rx_cpl_vif  (.clk(clk), .rst(rst));
    pcie_tlp_if   wr_req_vif  (.clk(clk), .rst(rst));
    dma_ram_if    ram_vif     (.clk(clk), .rst(rst));
    dma_if_cfg_if cfg_vif     ();
    initial cfg_vif.init_golden();

    // ---- DUT-driven nets ------------------------------------------------------
    wire                                        d_rx_cpl_ready;

    wire [TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]      d_rd_req_hdr;
    wire [TLP_SEG_COUNT*TX_SEQ_NUM_WIDTH-1:0]   d_rd_req_seq;
    wire [TLP_SEG_COUNT-1:0]                    d_rd_req_valid;
    wire [TLP_SEG_COUNT-1:0]                    d_rd_req_sop;
    wire [TLP_SEG_COUNT-1:0]                    d_rd_req_eop;

    wire [TLP_DATA_WIDTH-1:0]                   d_wr_req_data;
    wire [TLP_STRB_WIDTH-1:0]                   d_wr_req_strb;
    wire [TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]      d_wr_req_hdr;
    wire [TLP_SEG_COUNT*TX_SEQ_NUM_WIDTH-1:0]   d_wr_req_seq;
    wire [TLP_SEG_COUNT-1:0]                    d_wr_req_valid;
    wire [TLP_SEG_COUNT-1:0]                    d_wr_req_sop;
    wire [TLP_SEG_COUNT-1:0]                    d_wr_req_eop;

    wire                                        d_rd_desc_ready;
    wire [TAG_WIDTH-1:0]                        d_rd_sts_tag;
    wire [3:0]                                  d_rd_sts_error;
    wire                                        d_rd_sts_valid;

    wire                                        d_wr_desc_ready;
    wire [TAG_WIDTH-1:0]                        d_wr_sts_tag;
    wire [3:0]                                  d_wr_sts_error;
    wire                                        d_wr_sts_valid;

    wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]      d_ram_rd_sel;
    wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0] d_ram_rd_addr;
    wire [RAM_SEG_COUNT-1:0]                    d_ram_rd_valid;
    wire [RAM_SEG_COUNT-1:0]                    d_ram_resp_ready;

    wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]      d_ram_wr_sel;
    wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]   d_ram_wr_be;
    wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0] d_ram_wr_addr;
    wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] d_ram_wr_data;
    wire [RAM_SEG_COUNT-1:0]                    d_ram_wr_valid;

    // ---- DUT ------------------------------------------------------------------
    dma_if_pcie #(
        .TLP_DATA_WIDTH     (TLP_DATA_WIDTH),
        .TLP_STRB_WIDTH     (TLP_STRB_WIDTH),
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
        .IMM_ENABLE         (IMM_ENABLE),
        .IMM_WIDTH          (IMM_WIDTH),
        .LEN_WIDTH          (LEN_WIDTH),
        .TAG_WIDTH          (TAG_WIDTH),
        .CHECK_BUS_NUMBER   (0)
    ) u_dma_if_pcie (
        .clk (clk),
        .rst (rst),

        .rx_cpl_tlp_data  (rx_cpl_vif.tlp_data[TLP_DATA_WIDTH-1:0]),
        .rx_cpl_tlp_hdr   (rx_cpl_vif.tlp_hdr[TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]),
        .rx_cpl_tlp_error (rx_cpl_vif.tlp_error[TLP_SEG_COUNT*4-1:0]),
        .rx_cpl_tlp_valid (rx_cpl_vif.tlp_valid[TLP_SEG_COUNT-1:0]),
        .rx_cpl_tlp_sop   (rx_cpl_vif.tlp_sop[TLP_SEG_COUNT-1:0]),
        .rx_cpl_tlp_eop   (rx_cpl_vif.tlp_eop[TLP_SEG_COUNT-1:0]),
        .rx_cpl_tlp_ready (d_rx_cpl_ready),

        .tx_rd_req_tlp_hdr   (d_rd_req_hdr),
        .tx_rd_req_tlp_seq   (d_rd_req_seq),
        .tx_rd_req_tlp_valid (d_rd_req_valid),
        .tx_rd_req_tlp_sop   (d_rd_req_sop),
        .tx_rd_req_tlp_eop   (d_rd_req_eop),
        .tx_rd_req_tlp_ready (rd_req_vif.tlp_ready),

        .tx_wr_req_tlp_data  (d_wr_req_data),
        .tx_wr_req_tlp_strb  (d_wr_req_strb),
        .tx_wr_req_tlp_hdr   (d_wr_req_hdr),
        .tx_wr_req_tlp_seq   (d_wr_req_seq),
        .tx_wr_req_tlp_valid (d_wr_req_valid),
        .tx_wr_req_tlp_sop   (d_wr_req_sop),
        .tx_wr_req_tlp_eop   (d_wr_req_eop),
        .tx_wr_req_tlp_ready (wr_req_vif.tlp_ready),

        .s_axis_rd_req_tx_seq_num       ('0),
        .s_axis_rd_req_tx_seq_num_valid ('0),
        .s_axis_wr_req_tx_seq_num       ('0),
        .s_axis_wr_req_tx_seq_num_valid ('0),

        .s_axis_read_desc_pcie_addr (rd_desc_vif.req_pcie_addr[PCIE_ADDR_WIDTH-1:0]),
        .s_axis_read_desc_ram_sel   (rd_desc_vif.req_ram_sel[RAM_SEL_WIDTH-1:0]),
        .s_axis_read_desc_ram_addr  (rd_desc_vif.req_ram_addr[RAM_ADDR_WIDTH-1:0]),
        .s_axis_read_desc_len       (rd_desc_vif.req_len[LEN_WIDTH-1:0]),
        .s_axis_read_desc_tag       (rd_desc_vif.req_tag[TAG_WIDTH-1:0]),
        .s_axis_read_desc_valid     (rd_desc_vif.req_valid),
        .s_axis_read_desc_ready     (d_rd_desc_ready),

        .m_axis_read_desc_status_tag   (d_rd_sts_tag),
        .m_axis_read_desc_status_error (d_rd_sts_error),
        .m_axis_read_desc_status_valid (d_rd_sts_valid),

        .s_axis_write_desc_pcie_addr (wr_desc_vif.req_pcie_addr[PCIE_ADDR_WIDTH-1:0]),
        .s_axis_write_desc_ram_sel   (wr_desc_vif.req_ram_sel[RAM_SEL_WIDTH-1:0]),
        .s_axis_write_desc_ram_addr  (wr_desc_vif.req_ram_addr[RAM_ADDR_WIDTH-1:0]),
        .s_axis_write_desc_imm       (wr_desc_vif.req_imm[IMM_WIDTH-1:0]),
        .s_axis_write_desc_imm_en    (wr_desc_vif.req_imm_en),
        .s_axis_write_desc_len       (wr_desc_vif.req_len[LEN_WIDTH-1:0]),
        .s_axis_write_desc_tag       (wr_desc_vif.req_tag[TAG_WIDTH-1:0]),
        .s_axis_write_desc_valid     (wr_desc_vif.req_valid),
        .s_axis_write_desc_ready     (d_wr_desc_ready),

        .m_axis_write_desc_status_tag   (d_wr_sts_tag),
        .m_axis_write_desc_status_error (d_wr_sts_error),
        .m_axis_write_desc_status_valid (d_wr_sts_valid),

        .ram_rd_cmd_sel    (d_ram_rd_sel),
        .ram_rd_cmd_addr   (d_ram_rd_addr),
        .ram_rd_cmd_valid  (d_ram_rd_valid),
        .ram_rd_cmd_ready  (ram_vif.rd_cmd_ready[RAM_SEG_COUNT-1:0]),
        .ram_rd_resp_data  (ram_vif.rd_resp_data[RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]),
        .ram_rd_resp_valid (ram_vif.rd_resp_valid[RAM_SEG_COUNT-1:0]),
        .ram_rd_resp_ready (d_ram_resp_ready),

        .ram_wr_cmd_sel   (d_ram_wr_sel),
        .ram_wr_cmd_be    (d_ram_wr_be),
        .ram_wr_cmd_addr  (d_ram_wr_addr),
        .ram_wr_cmd_data  (d_ram_wr_data),
        .ram_wr_cmd_valid (d_ram_wr_valid),
        .ram_wr_cmd_ready (ram_vif.wr_cmd_ready[RAM_SEG_COUNT-1:0]),
        .ram_wr_done      (ram_vif.wr_done[RAM_SEG_COUNT-1:0]),

        .read_enable           (cfg_vif.enable),
        .write_enable          (cfg_vif.enable),
        .ext_tag_enable        (cfg_vif.ext_tag_enable),
        .rcb_128b              (cfg_vif.rcb_128b),
        .requester_id          (cfg_vif.requester_id),
        .max_read_request_size (cfg_vif.max_read_request_size),
        .max_payload_size      (cfg_vif.max_payload_size),

        .status_rd_busy     (),
        .status_wr_busy     (),
        .status_error_cor   (),
        .status_error_uncor (),

        .stat_rd_op_start_tag      (),
        .stat_rd_op_start_len      (),
        .stat_rd_op_start_valid    (),
        .stat_rd_op_finish_tag     (),
        .stat_rd_op_finish_status  (),
        .stat_rd_op_finish_valid   (),
        .stat_rd_req_start_tag     (),
        .stat_rd_req_start_len     (),
        .stat_rd_req_start_valid   (),
        .stat_rd_req_finish_tag    (),
        .stat_rd_req_finish_status (),
        .stat_rd_req_finish_valid  (),
        .stat_rd_req_timeout       (),
        .stat_rd_op_table_full     (),
        .stat_rd_no_tags           (),
        .stat_rd_tx_limit          (),
        .stat_rd_tx_stall          (),
        .stat_wr_op_start_tag      (),
        .stat_wr_op_start_len      (),
        .stat_wr_op_start_valid    (),
        .stat_wr_op_finish_tag     (),
        .stat_wr_op_finish_status  (),
        .stat_wr_op_finish_valid   (),
        .stat_wr_req_start_tag     (),
        .stat_wr_req_start_len     (),
        .stat_wr_req_start_valid   (),
        .stat_wr_req_finish_tag    (),
        .stat_wr_req_finish_status (),
        .stat_wr_req_finish_valid  (),
        .stat_wr_op_table_full     (),
        .stat_wr_tx_limit          (),
        .stat_wr_tx_stall          ()
    );

    // ---- read request channel -------------------------------------------------
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
    assign rd_req_vif.tlp_data     = '0;
    assign rd_req_vif.tlp_strb     = '0;
    assign rd_req_vif.tlp_bar_id   = '0;
    assign rd_req_vif.tlp_func_num = '0;
    assign rd_req_vif.tlp_error    = '0;

    // ---- write request channel ------------------------------------------------
    assign wr_req_vif.tlp_data =
        {{(TLP_MAX_DATA_WIDTH-TLP_DATA_WIDTH){1'b0}}, d_wr_req_data};
    assign wr_req_vif.tlp_strb =
        {{(TLP_MAX_STRB_WIDTH-TLP_STRB_WIDTH){1'b0}}, d_wr_req_strb};
    assign wr_req_vif.tlp_hdr =
        {{(TLP_MAX_SEG_COUNT*TLP_HDR_WIDTH - TLP_SEG_COUNT*TLP_HDR_WIDTH){1'b0}},
         d_wr_req_hdr};
    assign wr_req_vif.tlp_seq =
        {{(TLP_MAX_SEG_COUNT*6 - TLP_SEG_COUNT*TX_SEQ_NUM_WIDTH){1'b0}}, d_wr_req_seq};
    assign wr_req_vif.tlp_valid =
        {{(TLP_MAX_SEG_COUNT-TLP_SEG_COUNT){1'b0}}, d_wr_req_valid};
    assign wr_req_vif.tlp_sop =
        {{(TLP_MAX_SEG_COUNT-TLP_SEG_COUNT){1'b0}}, d_wr_req_sop};
    assign wr_req_vif.tlp_eop =
        {{(TLP_MAX_SEG_COUNT-TLP_SEG_COUNT){1'b0}}, d_wr_req_eop};
    assign wr_req_vif.tlp_bar_id   = '0;
    assign wr_req_vif.tlp_func_num = '0;
    assign wr_req_vif.tlp_error    = '0;

    assign rx_cpl_vif.tlp_ready = d_rx_cpl_ready;

    // ---- descriptors ----------------------------------------------------------
    assign rd_desc_vif.req_ready = d_rd_desc_ready;
    assign rd_desc_vif.sts_tag   = {{(DMA_DESC_MAX_TAG_WIDTH-TAG_WIDTH){1'b0}}, d_rd_sts_tag};
    assign rd_desc_vif.sts_error = d_rd_sts_error;
    assign rd_desc_vif.sts_valid = d_rd_sts_valid;
    assign rd_desc_vif.sts_len   = '0;
    assign rd_desc_vif.sts_id    = '0;
    assign rd_desc_vif.sts_dest  = '0;
    assign rd_desc_vif.sts_user  = '0;

    assign wr_desc_vif.req_ready = d_wr_desc_ready;
    assign wr_desc_vif.sts_tag   = {{(DMA_DESC_MAX_TAG_WIDTH-TAG_WIDTH){1'b0}}, d_wr_sts_tag};
    assign wr_desc_vif.sts_error = d_wr_sts_error;
    assign wr_desc_vif.sts_valid = d_wr_sts_valid;
    assign wr_desc_vif.sts_len   = '0;
    assign wr_desc_vif.sts_id    = '0;
    assign wr_desc_vif.sts_dest  = '0;
    assign wr_desc_vif.sts_user  = '0;

    // ---- RAM, both channels ---------------------------------------------------
    for (genvar s = 0; s < RAM_SEG_COUNT; s++) begin : g_ram
        assign ram_vif.wr_cmd_sel[s*DMA_RAM_MAX_SEL_WIDTH +: DMA_RAM_MAX_SEL_WIDTH] =
            {{(DMA_RAM_MAX_SEL_WIDTH-RAM_SEL_WIDTH){1'b0}},
             d_ram_wr_sel[s*RAM_SEL_WIDTH +: RAM_SEL_WIDTH]};
        assign ram_vif.wr_cmd_be[s*DMA_RAM_MAX_SEG_BE_WIDTH +: DMA_RAM_MAX_SEG_BE_WIDTH] =
            d_ram_wr_be[s*RAM_SEG_BE_WIDTH +: RAM_SEG_BE_WIDTH];
        assign ram_vif.wr_cmd_addr[s*DMA_RAM_MAX_SEG_ADDR_WIDTH +: DMA_RAM_MAX_SEG_ADDR_WIDTH] =
            {{(DMA_RAM_MAX_SEG_ADDR_WIDTH-RAM_SEG_ADDR_WIDTH){1'b0}},
             d_ram_wr_addr[s*RAM_SEG_ADDR_WIDTH +: RAM_SEG_ADDR_WIDTH]};
        assign ram_vif.wr_cmd_data[s*DMA_RAM_MAX_SEG_DATA_WIDTH +: DMA_RAM_MAX_SEG_DATA_WIDTH] =
            d_ram_wr_data[s*RAM_SEG_DATA_WIDTH +: RAM_SEG_DATA_WIDTH];
        assign ram_vif.rd_cmd_sel[s*DMA_RAM_MAX_SEL_WIDTH +: DMA_RAM_MAX_SEL_WIDTH] =
            {{(DMA_RAM_MAX_SEL_WIDTH-RAM_SEL_WIDTH){1'b0}},
             d_ram_rd_sel[s*RAM_SEL_WIDTH +: RAM_SEL_WIDTH]};
        assign ram_vif.rd_cmd_addr[s*DMA_RAM_MAX_SEG_ADDR_WIDTH +: DMA_RAM_MAX_SEG_ADDR_WIDTH] =
            {{(DMA_RAM_MAX_SEG_ADDR_WIDTH-RAM_SEG_ADDR_WIDTH){1'b0}},
             d_ram_rd_addr[s*RAM_SEG_ADDR_WIDTH +: RAM_SEG_ADDR_WIDTH]};
    end
    assign ram_vif.wr_cmd_valid =
        {{(DMA_RAM_MAX_SEG_COUNT-RAM_SEG_COUNT){1'b0}}, d_ram_wr_valid};
    assign ram_vif.rd_cmd_valid =
        {{(DMA_RAM_MAX_SEG_COUNT-RAM_SEG_COUNT){1'b0}}, d_ram_rd_valid};
    assign ram_vif.rd_resp_ready =
        {{(DMA_RAM_MAX_SEG_COUNT-RAM_SEG_COUNT){1'b0}}, d_ram_resp_ready};

    // ---- idle the TB-driven halves -------------------------------------------
    initial begin
        // NEITHER engine gates its framing, by two different mechanisms:
        // dma_if_pcie_rd ties sop/eop to a constant 1'b1 (:484-485), and
        // dma_if_pcie_wr latches them, clearing only valid on the handshake
        // (dma_if_pcie_wr.v:839-841). Both leave sop high while valid is low.
        //
        // rx_cpl is TB-driven and DOES gate them, so it keeps the default -
        // which is what makes this a per-instance flag rather than a global.
        rd_req_vif.sop_eop_gated = 1'b0;
        wr_req_vif.sop_eop_gated = 1'b0;

        rd_desc_vif.init_idle_requester();
        wr_desc_vif.init_idle_requester();

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
    end

    // ---- UVM ------------------------------------------------------------------
    initial begin
        uvm_config_db #(virtual mqnic_reset_if)::set(null, "uvm_test_top", "rst_vif", rst_if);
        uvm_config_db #(virtual dma_desc_if)::set(null, "uvm_test_top.m_env.m_rd_desc*", "vif", rd_desc_vif);
        uvm_config_db #(virtual dma_desc_if)::set(null, "uvm_test_top.m_env.m_wr_desc*", "vif", wr_desc_vif);
        uvm_config_db #(virtual pcie_tlp_if)::set(null, "uvm_test_top.m_env.m_rd_req*",  "vif", rd_req_vif);
        uvm_config_db #(virtual pcie_tlp_if)::set(null, "uvm_test_top.m_env.m_rx_cpl*",  "vif", rx_cpl_vif);
        uvm_config_db #(virtual pcie_tlp_if)::set(null, "uvm_test_top.m_env.m_wr_req*",  "vif", wr_req_vif);
        uvm_config_db #(virtual dma_ram_if)::set (null, "uvm_test_top.m_env.m_ram*",     "vif", ram_vif);
        uvm_config_db #(virtual dma_if_cfg_if)::set(null, "uvm_test_top", "cfg_vif", cfg_vif);
        run_test();
    end

    initial begin
        if ($test$plusargs("WAVES")) begin
            $dumpfile("dump.vcd");
            $dumpvars(0, tb_top_tier3c);
        end
    end

endmodule : tb_top_tier3c

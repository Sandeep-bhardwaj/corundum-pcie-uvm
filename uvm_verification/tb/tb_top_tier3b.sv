// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tb_top_tier3b - Tier 3b testbench top (dma_if_pcie_wr)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §18 Step 5
// Introduced : Step 5 (Tier 3b)
//
// DUT: fpga/lib/pcie/rtl/dma_if_pcie_wr.v, unmodified, at the same golden
// geometry as Tier 3a - 256-bit TLP data, one segment, double-width RAM.
//
// IMM_ENABLE is turned ON here. It defaults to 0, and left at the default the
// descriptor's imm/imm_en fields are dead wires and t3b_immediate would be
// testing nothing. mqnic_core_pcie enables it, so 1 is also the configuration
// that matters downstream.
//
// Every DUT output reaches its interface through a continuous assign over the
// full width - the ICPSD rule, applied from the start.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_top_tier3b;

    import uvm_pkg::*;
`include "uvm_macros.svh"
    import mqnic_vrf_pkg::*;
    import mqnic_test_pkg::*;

    localparam int TLP_DATA_WIDTH     = 256;
    localparam int TLP_STRB_WIDTH     = TLP_DATA_WIDTH / 32;      // 8
    localparam int TLP_HDR_WIDTH      = 128;
    localparam int TLP_SEG_COUNT      = 1;
    localparam int TX_SEQ_NUM_COUNT   = 1;
    localparam int TX_SEQ_NUM_WIDTH   = 6;
    localparam int RAM_SEL_WIDTH      = 2;
    localparam int RAM_ADDR_WIDTH     = 16;
    localparam int RAM_SEG_COUNT      = TLP_SEG_COUNT * 2;        // 2
    localparam int RAM_SEG_DATA_WIDTH = TLP_DATA_WIDTH * 2 / RAM_SEG_COUNT;
    localparam int RAM_SEG_BE_WIDTH   = RAM_SEG_DATA_WIDTH / 8;   // 32
    localparam int RAM_SEG_ADDR_WIDTH = 10;
    localparam int PCIE_ADDR_WIDTH    = 64;
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

    dma_desc_if   desc_vif   (.clk(clk), .rst(rst));
    pcie_tlp_if   wr_req_vif (.clk(clk), .rst(rst));
    dma_ram_if    ram_vif    (.clk(clk), .rst(rst));
    dma_if_cfg_if cfg_vif    ();
    initial cfg_vif.init_golden();

    // ---- DUT-driven nets ------------------------------------------------------
    wire [TLP_DATA_WIDTH-1:0]                   d_wr_req_data;
    wire [TLP_STRB_WIDTH-1:0]                   d_wr_req_strb;
    wire [TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]      d_wr_req_hdr;
    wire [TLP_SEG_COUNT*TX_SEQ_NUM_WIDTH-1:0]   d_wr_req_seq;
    wire [TLP_SEG_COUNT-1:0]                    d_wr_req_valid;
    wire [TLP_SEG_COUNT-1:0]                    d_wr_req_sop;
    wire [TLP_SEG_COUNT-1:0]                    d_wr_req_eop;

    wire                                        d_desc_ready;
    wire [TAG_WIDTH-1:0]                        d_sts_tag;
    wire [3:0]                                  d_sts_error;
    wire                                        d_sts_valid;

    wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]      d_ram_rd_sel;
    wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0] d_ram_rd_addr;
    wire [RAM_SEG_COUNT-1:0]                    d_ram_rd_valid;
    wire [RAM_SEG_COUNT-1:0]                    d_ram_resp_ready;

    // ---- DUT ------------------------------------------------------------------
    dma_if_pcie_wr #(
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
        .IMM_ENABLE         (IMM_ENABLE),
        .IMM_WIDTH          (IMM_WIDTH),
        .LEN_WIDTH          (LEN_WIDTH),
        .TAG_WIDTH          (TAG_WIDTH)
    ) u_dma_if_pcie_wr (
        .clk (clk),
        .rst (rst),

        .tx_wr_req_tlp_data  (d_wr_req_data),
        .tx_wr_req_tlp_strb  (d_wr_req_strb),
        .tx_wr_req_tlp_hdr   (d_wr_req_hdr),
        .tx_wr_req_tlp_seq   (d_wr_req_seq),
        .tx_wr_req_tlp_valid (d_wr_req_valid),
        .tx_wr_req_tlp_sop   (d_wr_req_sop),
        .tx_wr_req_tlp_eop   (d_wr_req_eop),
        .tx_wr_req_tlp_ready (wr_req_vif.tlp_ready),

        .s_axis_tx_seq_num       ('0),
        .s_axis_tx_seq_num_valid ('0),

        .s_axis_write_desc_pcie_addr (desc_vif.req_pcie_addr[PCIE_ADDR_WIDTH-1:0]),
        .s_axis_write_desc_ram_sel   (desc_vif.req_ram_sel[RAM_SEL_WIDTH-1:0]),
        .s_axis_write_desc_ram_addr  (desc_vif.req_ram_addr[RAM_ADDR_WIDTH-1:0]),
        .s_axis_write_desc_imm       (desc_vif.req_imm[IMM_WIDTH-1:0]),
        .s_axis_write_desc_imm_en    (desc_vif.req_imm_en),
        .s_axis_write_desc_len       (desc_vif.req_len[LEN_WIDTH-1:0]),
        .s_axis_write_desc_tag       (desc_vif.req_tag[TAG_WIDTH-1:0]),
        .s_axis_write_desc_valid     (desc_vif.req_valid),
        .s_axis_write_desc_ready     (d_desc_ready),

        .m_axis_write_desc_status_tag   (d_sts_tag),
        .m_axis_write_desc_status_error (d_sts_error),
        .m_axis_write_desc_status_valid (d_sts_valid),

        .ram_rd_cmd_sel    (d_ram_rd_sel),
        .ram_rd_cmd_addr   (d_ram_rd_addr),
        .ram_rd_cmd_valid  (d_ram_rd_valid),
        .ram_rd_cmd_ready  (ram_vif.rd_cmd_ready[RAM_SEG_COUNT-1:0]),
        .ram_rd_resp_data  (ram_vif.rd_resp_data[RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]),
        .ram_rd_resp_valid (ram_vif.rd_resp_valid[RAM_SEG_COUNT-1:0]),
        .ram_rd_resp_ready (d_ram_resp_ready),

        .enable           (cfg_vif.enable),
        .requester_id     (cfg_vif.requester_id),
        .max_payload_size (cfg_vif.max_payload_size),

        .status_busy (),

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

    // ---- DUT outputs -> interfaces, continuous assigns ------------------------
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

    assign desc_vif.req_ready = d_desc_ready;
    assign desc_vif.sts_tag   = {{(DMA_DESC_MAX_TAG_WIDTH-TAG_WIDTH){1'b0}}, d_sts_tag};
    assign desc_vif.sts_error = d_sts_error;
    assign desc_vif.sts_valid = d_sts_valid;
    assign desc_vif.sts_len   = '0;
    assign desc_vif.sts_id    = '0;
    assign desc_vif.sts_dest  = '0;
    assign desc_vif.sts_user  = '0;

    for (genvar s = 0; s < RAM_SEG_COUNT; s++) begin : g_ram
        assign ram_vif.rd_cmd_sel[s*DMA_RAM_MAX_SEL_WIDTH +: DMA_RAM_MAX_SEL_WIDTH] =
            {{(DMA_RAM_MAX_SEL_WIDTH-RAM_SEL_WIDTH){1'b0}},
             d_ram_rd_sel[s*RAM_SEL_WIDTH +: RAM_SEL_WIDTH]};
        assign ram_vif.rd_cmd_addr[s*DMA_RAM_MAX_SEG_ADDR_WIDTH +: DMA_RAM_MAX_SEG_ADDR_WIDTH] =
            {{(DMA_RAM_MAX_SEG_ADDR_WIDTH-RAM_SEG_ADDR_WIDTH){1'b0}},
             d_ram_rd_addr[s*RAM_SEG_ADDR_WIDTH +: RAM_SEG_ADDR_WIDTH]};
    end
    assign ram_vif.rd_cmd_valid =
        {{(DMA_RAM_MAX_SEG_COUNT-RAM_SEG_COUNT){1'b0}}, d_ram_rd_valid};
    assign ram_vif.rd_resp_ready =
        {{(DMA_RAM_MAX_SEG_COUNT-RAM_SEG_COUNT){1'b0}}, d_ram_resp_ready};

    // ---- idle the TB-driven halves -------------------------------------------
    initial begin
        // dma_if_pcie_wr does NOT gate its framing either. valid clears on the
        // handshake but sop/eop are HELD at their last value
        // (dma_if_pcie_wr.v:839-841), so sop reads high while valid is low
        // between packets. Same idiom as the read engine, different mechanism:
        // the read engine ties them to a constant, this one latches them.
        wr_req_vif.sop_eop_gated = 1'b0;

        desc_vif.init_idle_requester();

        // The write engine drives rd_cmd_* and rd_resp_ready; the TB owns
        // rd_cmd_ready, rd_resp_data and rd_resp_valid. The write channel is
        // unused on this DUT and is held idle so its interface assertions stay
        // vacuous rather than evaluating X.
        ram_vif.rd_cmd_ready  = '0;
        ram_vif.rd_resp_data  = '0;
        ram_vif.rd_resp_valid = '0;
        ram_vif.wr_cmd_sel    = '0;
        ram_vif.wr_cmd_be     = '0;
        ram_vif.wr_cmd_addr   = '0;
        ram_vif.wr_cmd_data   = '0;
        ram_vif.wr_cmd_valid  = '0;
        ram_vif.wr_cmd_ready  = '0;
        ram_vif.wr_done       = '0;
    end

    // ---- UVM ------------------------------------------------------------------
    initial begin
        uvm_config_db #(virtual mqnic_reset_if)::set(null, "uvm_test_top", "rst_vif", rst_if);
        uvm_config_db #(virtual dma_desc_if)::set(null, "uvm_test_top.m_env.m_desc*",   "vif", desc_vif);
        uvm_config_db #(virtual pcie_tlp_if)::set(null, "uvm_test_top.m_env.m_wr_req*", "vif", wr_req_vif);
        uvm_config_db #(virtual dma_ram_if)::set (null, "uvm_test_top.m_env.m_ram*",    "vif", ram_vif);
        uvm_config_db #(virtual dma_if_cfg_if)::set(null, "uvm_test_top", "cfg_vif", cfg_vif);
        run_test();
    end

    initial begin
        if ($test$plusargs("WAVES")) begin
            $dumpfile("dump.vcd");
            $dumpvars(0, tb_top_tier3b);
        end
    end

endmodule : tb_top_tier3b

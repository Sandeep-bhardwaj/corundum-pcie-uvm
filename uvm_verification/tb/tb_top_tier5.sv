// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tb_top_tier5 - Tier 5 testbench top (mqnic_core_pcie)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §18 Step 7, §8.2
// Introduced : Step 7 (Tier 5)
//
// THE FIRST DUT THAT CONTAINS THE WHOLE STACK. mqnic_core_pcie instantiates the
// Tier 3 DMA engine, the Tier 4 shims are one level above it, and inside are the
// queue managers verified at Tier 1a, the offloads from Tier 1c and the
// segmented RAM from Tier 2. 250 ports, 162 parameters, 2,141 lines.
//
// THE PORT MAP IS GENERATED. sim/scripts/gen_tb_ports.py derives it from the
// RTL, taking each port's DIRECTION from the source. At this size a mis-wired
// port usually still COMPILES - it connects the wrong signal or floats an input
// and shows up as inexplicable behaviour much later. Regenerate with:
//
//   python sim/scripts/gen_tb_ports.py //       ../fpga/common/rtl/mqnic_core_pcie.v mqnic_core_pcie --inst u_mqnic_core_pcie
//
// UNUSED INPUTS ARE TIED OFF BY FAMILY, not uniformly to zero: *_ready and
// *_ack go HIGH because the core is the MASTER of those interfaces and a
// permanently not-ready peer stalls it three levels away. See tie_off() in
// gen_tb_ports.py - this cost three rounds of probing to find, twice.
// Everything else is tied off explicitly rather than left out. "Unconnected"
// is then a decision visible in the file instead of an omission from it - and a
// floating input on a DUT this size is not something a waveform makes obvious.
//
// ONLY THE PCIe BAR PATH IS LIVE. test_rb_walk needs to issue memory reads to a
// BAR and collect completions; that is the whole of what the first Tier 5 test
// exercises (§8.2). The datapath, scheduler and PTP interfaces are tied off and
// come alive as later tests need them.
//
// Parameters: only the handful the testbench depends on are overridden. The
// other ~150 take their RTL defaults, so this top tracks the DUT rather than
// pinning a configuration the RTL may move on from.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_top_tier5;

    import uvm_pkg::*;
`include "uvm_macros.svh"
    import mqnic_vrf_pkg::*;
    import mqnic_test_pkg::*;

    // Golden PCIe geometry, matching mqnic_core_pcie_us.v:559-562.
    localparam int TLP_DATA_WIDTH = 256;
    localparam int TLP_STRB_WIDTH = TLP_DATA_WIDTH / 32;
    localparam int TLP_HDR_WIDTH  = 128;
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

    // Host -> DUT BAR requests, and the completions that come back.
    pcie_tlp_if req_vif (.clk(clk), .rst(rst));
    pcie_tlp_if cpl_vif (.clk(clk), .rst(rst));

    // ---- DUT-driven nets ------------------------------------------------------
    wire                                    d_req_ready;
    wire [TLP_DATA_WIDTH-1:0]               d_cpl_data;
    wire [TLP_STRB_WIDTH-1:0]               d_cpl_strb;
    wire [TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]  d_cpl_hdr;
    wire [TLP_SEG_COUNT-1:0]                d_cpl_valid;
    wire [TLP_SEG_COUNT-1:0]                d_cpl_sop;
    wire [TLP_SEG_COUNT-1:0]                d_cpl_eop;

    // ---- DUT ------------------------------------------------------------------
    mqnic_core_pcie #(
        .TLP_DATA_WIDTH (TLP_DATA_WIDTH),
        .TLP_STRB_WIDTH (TLP_STRB_WIDTH),
        .TLP_HDR_WIDTH  (TLP_HDR_WIDTH),
        .TLP_SEG_COUNT  (TLP_SEG_COUNT)
    ) u_mqnic_core_pcie (
        .clk                                   (clk),   // input  
        .rst                                   (rst),   // input  
        .pcie_rx_req_tlp_data                  (req_vif.tlp_data[TLP_DATA_WIDTH-1:0]),   // input  [TLP_DATA_WIDTH-1:0]
        .pcie_rx_req_tlp_strb                  (req_vif.tlp_strb[TLP_STRB_WIDTH-1:0]),   // input  [TLP_STRB_WIDTH-1:0]
        .pcie_rx_req_tlp_hdr                   (req_vif.tlp_hdr[TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]),   // input  [TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]
        .pcie_rx_req_tlp_bar_id                (req_vif.tlp_bar_id[TLP_SEG_COUNT*3-1:0]),   // input  [TLP_SEG_COUNT*3-1:0]
        .pcie_rx_req_tlp_func_num              (req_vif.tlp_func_num[TLP_SEG_COUNT*8-1:0]),   // input  [TLP_SEG_COUNT*8-1:0]
        .pcie_rx_req_tlp_valid                 (req_vif.tlp_valid[TLP_SEG_COUNT-1:0]),   // input  [TLP_SEG_COUNT-1:0]
        .pcie_rx_req_tlp_sop                   (req_vif.tlp_sop[TLP_SEG_COUNT-1:0]),   // input  [TLP_SEG_COUNT-1:0]
        .pcie_rx_req_tlp_eop                   (req_vif.tlp_eop[TLP_SEG_COUNT-1:0]),   // input  [TLP_SEG_COUNT-1:0]
        .pcie_rx_req_tlp_ready                 (d_req_ready),   // output 
        .pcie_rx_cpl_tlp_data                  ('0),      // input  [TLP_DATA_WIDTH-1:0]
        .pcie_rx_cpl_tlp_strb                  ('0),      // input  [TLP_STRB_WIDTH-1:0]
        .pcie_rx_cpl_tlp_hdr                   ('0),      // input  [TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]
        .pcie_rx_cpl_tlp_error                 ('0),      // input  [TLP_SEG_COUNT*4-1:0]
        .pcie_rx_cpl_tlp_valid                 ('0),      // input  [TLP_SEG_COUNT-1:0]
        .pcie_rx_cpl_tlp_sop                   ('0),      // input  [TLP_SEG_COUNT-1:0]
        .pcie_rx_cpl_tlp_eop                   ('0),      // input  [TLP_SEG_COUNT-1:0]
        .pcie_rx_cpl_tlp_ready                 (),        // output 
        .pcie_tx_rd_req_tlp_hdr                (),        // output [TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]
        .pcie_tx_rd_req_tlp_seq                (),        // output [TLP_SEG_COUNT*TX_SEQ_NUM_WIDTH-1:0]
        .pcie_tx_rd_req_tlp_valid              (),        // output [TLP_SEG_COUNT-1:0]
        .pcie_tx_rd_req_tlp_sop                (),        // output [TLP_SEG_COUNT-1:0]
        .pcie_tx_rd_req_tlp_eop                (),        // output [TLP_SEG_COUNT-1:0]
        .pcie_tx_rd_req_tlp_ready              (1'b1),      // input     // peer always ready - see tie_off()
        .s_axis_pcie_rd_req_tx_seq_num         ('0),      // input  [TX_SEQ_NUM_COUNT*TX_SEQ_NUM_WIDTH-1:0]
        .s_axis_pcie_rd_req_tx_seq_num_valid   ('0),      // input  [TX_SEQ_NUM_COUNT-1:0]
        .pcie_tx_wr_req_tlp_data               (),        // output [TLP_DATA_WIDTH-1:0]
        .pcie_tx_wr_req_tlp_strb               (),        // output [TLP_STRB_WIDTH-1:0]
        .pcie_tx_wr_req_tlp_hdr                (),        // output [TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]
        .pcie_tx_wr_req_tlp_seq                (),        // output [TLP_SEG_COUNT*TX_SEQ_NUM_WIDTH-1:0]
        .pcie_tx_wr_req_tlp_valid              (),        // output [TLP_SEG_COUNT-1:0]
        .pcie_tx_wr_req_tlp_sop                (),        // output [TLP_SEG_COUNT-1:0]
        .pcie_tx_wr_req_tlp_eop                (),        // output [TLP_SEG_COUNT-1:0]
        .pcie_tx_wr_req_tlp_ready              (1'b1),      // input     // peer always ready - see tie_off()
        .s_axis_pcie_wr_req_tx_seq_num         ('0),      // input  [TX_SEQ_NUM_COUNT*TX_SEQ_NUM_WIDTH-1:0]
        .s_axis_pcie_wr_req_tx_seq_num_valid   ('0),      // input  [TX_SEQ_NUM_COUNT-1:0]
        .pcie_tx_cpl_tlp_data                  (d_cpl_data),   // output [TLP_DATA_WIDTH-1:0]
        .pcie_tx_cpl_tlp_strb                  (d_cpl_strb),   // output [TLP_STRB_WIDTH-1:0]
        .pcie_tx_cpl_tlp_hdr                   (d_cpl_hdr),   // output [TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]
        .pcie_tx_cpl_tlp_valid                 (d_cpl_valid),   // output [TLP_SEG_COUNT-1:0]
        .pcie_tx_cpl_tlp_sop                   (d_cpl_sop),   // output [TLP_SEG_COUNT-1:0]
        .pcie_tx_cpl_tlp_eop                   (d_cpl_eop),   // output [TLP_SEG_COUNT-1:0]
        .pcie_tx_cpl_tlp_ready                 (cpl_vif.tlp_ready),   // input     // peer always ready - see tie_off()
        .pcie_tx_msix_wr_req_tlp_data          (),        // output [31:0]
        .pcie_tx_msix_wr_req_tlp_strb          (),        // output 
        .pcie_tx_msix_wr_req_tlp_hdr           (),        // output [TLP_HDR_WIDTH-1:0]
        .pcie_tx_msix_wr_req_tlp_valid         (),        // output 
        .pcie_tx_msix_wr_req_tlp_sop           (),        // output 
        .pcie_tx_msix_wr_req_tlp_eop           (),        // output 
        .pcie_tx_msix_wr_req_tlp_ready         (1'b1),      // input     // peer always ready - see tie_off()
        .bus_num                               ('0),      // input  [7:0]
        .ext_tag_enable                        ('0),      // input  [F_COUNT-1:0]
        .rcb_128b                              ('0),      // input  [F_COUNT-1:0]
        .max_read_request_size                 ('0),      // input  [F_COUNT*3-1:0]
        .max_payload_size                      ('0),      // input  [F_COUNT*3-1:0]
        .msix_enable                           ('0),      // input  [F_COUNT-1:0]
        .msix_mask                             ('0),      // input  [F_COUNT-1:0]
        .pcie_error_cor                        (),        // output 
        .pcie_error_uncor                      (),        // output 
        .m_axil_csr_awaddr                     (),        // output [AXIL_CSR_ADDR_WIDTH-1:0]
        .m_axil_csr_awprot                     (),        // output [2:0]
        .m_axil_csr_awvalid                    (),        // output 
        .m_axil_csr_awready                    (1'b1),      // input     // peer always ready - see tie_off()
        .m_axil_csr_wdata                      (),        // output [AXIL_CTRL_DATA_WIDTH-1:0]
        .m_axil_csr_wstrb                      (),        // output [AXIL_CTRL_STRB_WIDTH-1:0]
        .m_axil_csr_wvalid                     (),        // output 
        .m_axil_csr_wready                     (1'b1),      // input     // peer always ready - see tie_off()
        .m_axil_csr_bresp                      ('0),      // input  [1:0]
        .m_axil_csr_bvalid                     ('0),      // input  
        .m_axil_csr_bready                     (),        // output 
        .m_axil_csr_araddr                     (),        // output [AXIL_CSR_ADDR_WIDTH-1:0]
        .m_axil_csr_arprot                     (),        // output [2:0]
        .m_axil_csr_arvalid                    (),        // output 
        .m_axil_csr_arready                    (1'b1),      // input     // peer always ready - see tie_off()
        .m_axil_csr_rdata                      ('0),      // input  [AXIL_CTRL_DATA_WIDTH-1:0]
        .m_axil_csr_rresp                      ('0),      // input  [1:0]
        .m_axil_csr_rvalid                     ('0),      // input  
        .m_axil_csr_rready                     (),        // output 
        .ctrl_reg_wr_addr                      (),        // output [AXIL_CSR_ADDR_WIDTH-1:0]
        .ctrl_reg_wr_data                      (),        // output [AXIL_CTRL_DATA_WIDTH-1:0]
        .ctrl_reg_wr_strb                      (),        // output [AXIL_CTRL_STRB_WIDTH-1:0]
        .ctrl_reg_wr_en                        (),        // output 
        .ctrl_reg_wr_wait                      ('0),      // input  
        .ctrl_reg_wr_ack                       ('0),        // input     // NOT 1'b1: this is the
                                                        // application register block's acknowledge. Tied high it answers every
                                                        // register read instantly with its tied-off data of 0, beating the core's
                                                        // own register file - reads then SUCCEED AND RETURN THE WRONG VALUE.
                                                        // mqnic_core.v:754. See tie_off() and bug 32.
        .ctrl_reg_rd_addr                      (),        // output [AXIL_CSR_ADDR_WIDTH-1:0]
        .ctrl_reg_rd_en                        (),        // output 
        .ctrl_reg_rd_data                      ('0),      // input  [AXIL_CTRL_DATA_WIDTH-1:0]
        .ctrl_reg_rd_wait                      ('0),      // input  
        .ctrl_reg_rd_ack                       ('0),        // input     // NOT 1'b1: this is the
                                                        // application register block's acknowledge. Tied high it answers every
                                                        // register read instantly with its tied-off data of 0, beating the core's
                                                        // own register file - reads then SUCCEED AND RETURN THE WRONG VALUE.
                                                        // mqnic_core.v:754. See tie_off() and bug 32.
        .ptp_clk                               ('0),      // input  
        .ptp_rst                               ('0),      // input  
        .ptp_sample_clk                        ('0),      // input  
        .ptp_td_sd                             (),        // output 
        .ptp_pps                               (),        // output 
        .ptp_pps_str                           (),        // output 
        .ptp_sync_locked                       (),        // output 
        .ptp_sync_ts_rel                       (),        // output [63:0]
        .ptp_sync_ts_rel_step                  (),        // output 
        .ptp_sync_ts_tod                       (),        // output [96:0]
        .ptp_sync_ts_tod_step                  (),        // output 
        .ptp_sync_pps                          (),        // output 
        .ptp_sync_pps_str                      (),        // output 
        .ptp_perout_locked                     (),        // output [PTP_PEROUT_COUNT-1:0]
        .ptp_perout_error                      (),        // output [PTP_PEROUT_COUNT-1:0]
        .ptp_perout_pulse                      (),        // output [PTP_PEROUT_COUNT-1:0]
        .tx_clk                                ('0),      // input  [PORT_COUNT-1:0]
        .tx_rst                                ('0),      // input  [PORT_COUNT-1:0]
        .tx_ptp_clk                            ('0),      // input  [PORT_COUNT-1:0]
        .tx_ptp_rst                            ('0),      // input  [PORT_COUNT-1:0]
        .tx_ptp_ts_tod                         (),        // output [PORT_COUNT*PTP_TS_WIDTH-1:0]
        .tx_ptp_ts_tod_step                    (),        // output [PORT_COUNT-1:0]
        .m_axis_tx_tdata                       (),        // output [PORT_COUNT*AXIS_DATA_WIDTH-1:0]
        .m_axis_tx_tkeep                       (),        // output [PORT_COUNT*AXIS_KEEP_WIDTH-1:0]
        .m_axis_tx_tvalid                      (),        // output [PORT_COUNT-1:0]
        .m_axis_tx_tready                      (1'b1),      // input  [PORT_COUNT-1:0]   // peer always ready - see tie_off()
        .m_axis_tx_tlast                       (),        // output [PORT_COUNT-1:0]
        .m_axis_tx_tuser                       (),        // output [PORT_COUNT*AXIS_TX_USER_WIDTH-1:0]
        .s_axis_tx_cpl_ts                      ('0),      // input  [PORT_COUNT*PTP_TS_WIDTH-1:0]
        .s_axis_tx_cpl_tag                     ('0),      // input  [PORT_COUNT*TX_TAG_WIDTH-1:0]
        .s_axis_tx_cpl_valid                   ('0),      // input  [PORT_COUNT-1:0]
        .s_axis_tx_cpl_ready                   (),        // output [PORT_COUNT-1:0]
        .tx_enable                             (),        // output [PORT_COUNT-1:0]
        .tx_status                             ('0),      // input  [PORT_COUNT-1:0]
        .tx_lfc_en                             (),        // output [PORT_COUNT-1:0]
        .tx_lfc_req                            (),        // output [PORT_COUNT-1:0]
        .tx_pfc_en                             (),        // output [PORT_COUNT*8-1:0]
        .tx_pfc_req                            (),        // output [PORT_COUNT*8-1:0]
        .tx_fc_quanta_clk_en                   ('0),      // input  [PORT_COUNT-1:0]
        .rx_clk                                ('0),      // input  [PORT_COUNT-1:0]
        .rx_rst                                ('0),      // input  [PORT_COUNT-1:0]
        .rx_ptp_clk                            ('0),      // input  [PORT_COUNT-1:0]
        .rx_ptp_rst                            ('0),      // input  [PORT_COUNT-1:0]
        .rx_ptp_ts_tod                         (),        // output [PORT_COUNT*PTP_TS_WIDTH-1:0]
        .rx_ptp_ts_tod_step                    (),        // output [PORT_COUNT-1:0]
        .s_axis_rx_tdata                       ('0),      // input  [PORT_COUNT*AXIS_DATA_WIDTH-1:0]
        .s_axis_rx_tkeep                       ('0),      // input  [PORT_COUNT*AXIS_KEEP_WIDTH-1:0]
        .s_axis_rx_tvalid                      ('0),      // input  [PORT_COUNT-1:0]
        .s_axis_rx_tready                      (),        // output [PORT_COUNT-1:0]
        .s_axis_rx_tlast                       ('0),      // input  [PORT_COUNT-1:0]
        .s_axis_rx_tuser                       ('0),      // input  [PORT_COUNT*AXIS_RX_USER_WIDTH-1:0]
        .rx_enable                             (),        // output [PORT_COUNT-1:0]
        .rx_status                             ('0),      // input  [PORT_COUNT-1:0]
        .rx_lfc_en                             (),        // output [PORT_COUNT-1:0]
        .rx_lfc_req                            ('0),      // input  [PORT_COUNT-1:0]
        .rx_lfc_ack                            (),        // output [PORT_COUNT-1:0]
        .rx_pfc_en                             (),        // output [PORT_COUNT*8-1:0]
        .rx_pfc_req                            ('0),      // input  [PORT_COUNT*8-1:0]
        .rx_pfc_ack                            (),        // output [PORT_COUNT*8-1:0]
        .rx_fc_quanta_clk_en                   ('0),      // input  [PORT_COUNT-1:0]
        .ddr_clk                               ('0),      // input  [DDR_CH-1:0]
        .ddr_rst                               ('0),      // input  [DDR_CH-1:0]
        .m_axi_ddr_awid                        (),        // output [DDR_CH*AXI_DDR_ID_WIDTH-1:0]
        .m_axi_ddr_awaddr                      (),        // output [DDR_CH*AXI_DDR_ADDR_WIDTH-1:0]
        .m_axi_ddr_awlen                       (),        // output [DDR_CH*8-1:0]
        .m_axi_ddr_awsize                      (),        // output [DDR_CH*3-1:0]
        .m_axi_ddr_awburst                     (),        // output [DDR_CH*2-1:0]
        .m_axi_ddr_awlock                      (),        // output [DDR_CH-1:0]
        .m_axi_ddr_awcache                     (),        // output [DDR_CH*4-1:0]
        .m_axi_ddr_awprot                      (),        // output [DDR_CH*3-1:0]
        .m_axi_ddr_awqos                       (),        // output [DDR_CH*4-1:0]
        .m_axi_ddr_awuser                      (),        // output [DDR_CH*AXI_DDR_AWUSER_WIDTH-1:0]
        .m_axi_ddr_awvalid                     (),        // output [DDR_CH-1:0]
        .m_axi_ddr_awready                     (1'b1),      // input  [DDR_CH-1:0]   // peer always ready - see tie_off()
        .m_axi_ddr_wdata                       (),        // output [DDR_CH*AXI_DDR_DATA_WIDTH-1:0]
        .m_axi_ddr_wstrb                       (),        // output [DDR_CH*AXI_DDR_STRB_WIDTH-1:0]
        .m_axi_ddr_wlast                       (),        // output [DDR_CH-1:0]
        .m_axi_ddr_wuser                       (),        // output [DDR_CH*AXI_DDR_WUSER_WIDTH-1:0]
        .m_axi_ddr_wvalid                      (),        // output [DDR_CH-1:0]
        .m_axi_ddr_wready                      (1'b1),      // input  [DDR_CH-1:0]   // peer always ready - see tie_off()
        .m_axi_ddr_bid                         ('0),      // input  [DDR_CH*AXI_DDR_ID_WIDTH-1:0]
        .m_axi_ddr_bresp                       ('0),      // input  [DDR_CH*2-1:0]
        .m_axi_ddr_buser                       ('0),      // input  [DDR_CH*AXI_DDR_BUSER_WIDTH-1:0]
        .m_axi_ddr_bvalid                      ('0),      // input  [DDR_CH-1:0]
        .m_axi_ddr_bready                      (),        // output [DDR_CH-1:0]
        .m_axi_ddr_arid                        (),        // output [DDR_CH*AXI_DDR_ID_WIDTH-1:0]
        .m_axi_ddr_araddr                      (),        // output [DDR_CH*AXI_DDR_ADDR_WIDTH-1:0]
        .m_axi_ddr_arlen                       (),        // output [DDR_CH*8-1:0]
        .m_axi_ddr_arsize                      (),        // output [DDR_CH*3-1:0]
        .m_axi_ddr_arburst                     (),        // output [DDR_CH*2-1:0]
        .m_axi_ddr_arlock                      (),        // output [DDR_CH-1:0]
        .m_axi_ddr_arcache                     (),        // output [DDR_CH*4-1:0]
        .m_axi_ddr_arprot                      (),        // output [DDR_CH*3-1:0]
        .m_axi_ddr_arqos                       (),        // output [DDR_CH*4-1:0]
        .m_axi_ddr_aruser                      (),        // output [DDR_CH*AXI_DDR_ARUSER_WIDTH-1:0]
        .m_axi_ddr_arvalid                     (),        // output [DDR_CH-1:0]
        .m_axi_ddr_arready                     (1'b1),      // input  [DDR_CH-1:0]   // peer always ready - see tie_off()
        .m_axi_ddr_rid                         ('0),      // input  [DDR_CH*AXI_DDR_ID_WIDTH-1:0]
        .m_axi_ddr_rdata                       ('0),      // input  [DDR_CH*AXI_DDR_DATA_WIDTH-1:0]
        .m_axi_ddr_rresp                       ('0),      // input  [DDR_CH*2-1:0]
        .m_axi_ddr_rlast                       ('0),      // input  [DDR_CH-1:0]
        .m_axi_ddr_ruser                       ('0),      // input  [DDR_CH*AXI_DDR_RUSER_WIDTH-1:0]
        .m_axi_ddr_rvalid                      ('0),      // input  [DDR_CH-1:0]
        .m_axi_ddr_rready                      (),        // output [DDR_CH-1:0]
        .ddr_status                            ('0),      // input  [DDR_CH-1:0]
        .hbm_clk                               ('0),      // input  [HBM_CH-1:0]
        .hbm_rst                               ('0),      // input  [HBM_CH-1:0]
        .m_axi_hbm_awid                        (),        // output [HBM_CH*AXI_HBM_ID_WIDTH-1:0]
        .m_axi_hbm_awaddr                      (),        // output [HBM_CH*AXI_HBM_ADDR_WIDTH-1:0]
        .m_axi_hbm_awlen                       (),        // output [HBM_CH*8-1:0]
        .m_axi_hbm_awsize                      (),        // output [HBM_CH*3-1:0]
        .m_axi_hbm_awburst                     (),        // output [HBM_CH*2-1:0]
        .m_axi_hbm_awlock                      (),        // output [HBM_CH-1:0]
        .m_axi_hbm_awcache                     (),        // output [HBM_CH*4-1:0]
        .m_axi_hbm_awprot                      (),        // output [HBM_CH*3-1:0]
        .m_axi_hbm_awqos                       (),        // output [HBM_CH*4-1:0]
        .m_axi_hbm_awuser                      (),        // output [HBM_CH*AXI_HBM_AWUSER_WIDTH-1:0]
        .m_axi_hbm_awvalid                     (),        // output [HBM_CH-1:0]
        .m_axi_hbm_awready                     (1'b1),      // input  [HBM_CH-1:0]   // peer always ready - see tie_off()
        .m_axi_hbm_wdata                       (),        // output [HBM_CH*AXI_HBM_DATA_WIDTH-1:0]
        .m_axi_hbm_wstrb                       (),        // output [HBM_CH*AXI_HBM_STRB_WIDTH-1:0]
        .m_axi_hbm_wlast                       (),        // output [HBM_CH-1:0]
        .m_axi_hbm_wuser                       (),        // output [HBM_CH*AXI_HBM_WUSER_WIDTH-1:0]
        .m_axi_hbm_wvalid                      (),        // output [HBM_CH-1:0]
        .m_axi_hbm_wready                      (1'b1),      // input  [HBM_CH-1:0]   // peer always ready - see tie_off()
        .m_axi_hbm_bid                         ('0),      // input  [HBM_CH*AXI_HBM_ID_WIDTH-1:0]
        .m_axi_hbm_bresp                       ('0),      // input  [HBM_CH*2-1:0]
        .m_axi_hbm_buser                       ('0),      // input  [HBM_CH*AXI_HBM_BUSER_WIDTH-1:0]
        .m_axi_hbm_bvalid                      ('0),      // input  [HBM_CH-1:0]
        .m_axi_hbm_bready                      (),        // output [HBM_CH-1:0]
        .m_axi_hbm_arid                        (),        // output [HBM_CH*AXI_HBM_ID_WIDTH-1:0]
        .m_axi_hbm_araddr                      (),        // output [HBM_CH*AXI_HBM_ADDR_WIDTH-1:0]
        .m_axi_hbm_arlen                       (),        // output [HBM_CH*8-1:0]
        .m_axi_hbm_arsize                      (),        // output [HBM_CH*3-1:0]
        .m_axi_hbm_arburst                     (),        // output [HBM_CH*2-1:0]
        .m_axi_hbm_arlock                      (),        // output [HBM_CH-1:0]
        .m_axi_hbm_arcache                     (),        // output [HBM_CH*4-1:0]
        .m_axi_hbm_arprot                      (),        // output [HBM_CH*3-1:0]
        .m_axi_hbm_arqos                       (),        // output [HBM_CH*4-1:0]
        .m_axi_hbm_aruser                      (),        // output [HBM_CH*AXI_HBM_ARUSER_WIDTH-1:0]
        .m_axi_hbm_arvalid                     (),        // output [HBM_CH-1:0]
        .m_axi_hbm_arready                     (1'b1),      // input  [HBM_CH-1:0]   // peer always ready - see tie_off()
        .m_axi_hbm_rid                         ('0),      // input  [HBM_CH*AXI_HBM_ID_WIDTH-1:0]
        .m_axi_hbm_rdata                       ('0),      // input  [HBM_CH*AXI_HBM_DATA_WIDTH-1:0]
        .m_axi_hbm_rresp                       ('0),      // input  [HBM_CH*2-1:0]
        .m_axi_hbm_rlast                       ('0),      // input  [HBM_CH-1:0]
        .m_axi_hbm_ruser                       ('0),      // input  [HBM_CH*AXI_HBM_RUSER_WIDTH-1:0]
        .m_axi_hbm_rvalid                      ('0),      // input  [HBM_CH-1:0]
        .m_axi_hbm_rready                      (),        // output [HBM_CH-1:0]
        .hbm_status                            ('0),      // input  [HBM_CH-1:0]
        .s_axis_stat_tdata                     ('0),      // input  [STAT_INC_WIDTH-1:0]
        .s_axis_stat_tid                       ('0),      // input  [STAT_ID_WIDTH-1:0]
        .s_axis_stat_tvalid                    ('0),      // input  
        .s_axis_stat_tready                    (),        // output 
        .app_gpio_in                           ('0),      // input  [APP_GPIO_IN_WIDTH-1:0]
        .app_gpio_out                          (),        // output [APP_GPIO_OUT_WIDTH-1:0]
        .app_jtag_tdi                          ('0),      // input  
        .app_jtag_tdo                          (),        // output 
        .app_jtag_tms                          ('0),      // input  
        .app_jtag_tck                          ('0)      // input  
    );

    // ---- DUT outputs -> interfaces --------------------------------------------
    assign req_vif.tlp_ready = d_req_ready;

    assign cpl_vif.tlp_data =
        {{(TLP_MAX_DATA_WIDTH-TLP_DATA_WIDTH){1'b0}}, d_cpl_data};
    assign cpl_vif.tlp_strb =
        {{(TLP_MAX_STRB_WIDTH-TLP_STRB_WIDTH){1'b0}}, d_cpl_strb};
    assign cpl_vif.tlp_hdr =
        {{(TLP_MAX_SEG_COUNT*TLP_HDR_WIDTH - TLP_SEG_COUNT*TLP_HDR_WIDTH){1'b0}},
         d_cpl_hdr};
    assign cpl_vif.tlp_valid =
        {{(TLP_MAX_SEG_COUNT-TLP_SEG_COUNT){1'b0}}, d_cpl_valid};
    assign cpl_vif.tlp_sop =
        {{(TLP_MAX_SEG_COUNT-TLP_SEG_COUNT){1'b0}}, d_cpl_sop};
    assign cpl_vif.tlp_eop =
        {{(TLP_MAX_SEG_COUNT-TLP_SEG_COUNT){1'b0}}, d_cpl_eop};
    assign cpl_vif.tlp_seq      = '0;
    assign cpl_vif.tlp_bar_id   = '0;
    assign cpl_vif.tlp_func_num = '0;
    assign cpl_vif.tlp_error    = '0;

    // ---- idle the TB-driven halves -------------------------------------------
    initial begin
        // The TB drives the request side through pcie_tlp_driver, which clears
        // sop/eop with valid. The completion side comes out of the core's own
        // TLP mux - stated explicitly per slang_check rule 4, and to be
        // revisited the first time a_sop_implies_valid fires here.
        req_vif.sop_eop_gated = 1'b1;
        cpl_vif.sop_eop_gated = 1'b1;

        cpl_vif.tlp_ready = 1'b0;
    end

    // ---- UVM ------------------------------------------------------------------
    initial begin
        uvm_config_db #(virtual mqnic_reset_if)::set(null, "uvm_test_top", "rst_vif", rst_if);
        uvm_config_db #(virtual pcie_tlp_if)::set(null, "uvm_test_top.m_env.m_req*", "vif", req_vif);
        uvm_config_db #(virtual pcie_tlp_if)::set(null, "uvm_test_top.m_env.m_cpl*", "vif", cpl_vif);
        run_test();
    end

    initial begin
        if ($test$plusargs("WAVES")) begin
            $dumpfile("dump.vcd");
            $dumpvars(0, tb_top_tier5);
        end
    end

endmodule : tb_top_tier5

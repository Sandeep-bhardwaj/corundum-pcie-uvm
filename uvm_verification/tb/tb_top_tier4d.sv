// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tb_top_tier4d - Tier 4d testbench top (pcie_us_if)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §18, §5 (this is the PLAN's Tier 4b)
//
// THE SHIM INTEGRATION. Tiers 4a/4b/4c verify pcie_us_if_{rc,cq}, _cc and _rq
// in isolation, where a mismatch has exactly one plausible cause. This top
// wires all four together as the design does, and adds the two things no
// single-shim testbench can see:
//
//   * pcie_us_cfg, which exists ONLY in this wrapper. It POLLS PCIe config
//     space over cfg_mgmt_* and extracts (pcie_us_cfg.v:121-123)
//
//         ext_tag_enable        <- cfg_mgmt_read_data[8]
//         max_read_request_size <- cfg_mgmt_read_data[14:12]
//         max_payload_size      <- cfg_mgmt_read_data[7:5]
//
//     MPS and MRRS are the inputs to the DMA split rules verified at Tier 3
//     against ~390k cases. Tier 3 is HANDED those limits, so it cannot see them
//     being read out of the wrong bits. This is the seam between two halves
//     that are each already correct.
//
//   * all four channels running concurrently, with no cross-channel
//     interference.
//
// NAMING: the strategy calls this Tier 4b. This environment had already used
// "4b" for pcie_us_if_cc, so it is 4d here rather than renumbering three tiers.
// sim/scripts/check_strategy_duts.py compares the strategy's DUT list against
// the filelists so the mismatch cannot hide again.
//
// GOLDEN GEOMETRY: AXIS_PCIE_DATA_WIDTH = 256 (mqnic_core_pcie_us.v:157). The
// straddle settings are the RTL's own expressions of the width, written as
// expressions rather than constants so they cannot drift from the DUT.
//
// Every DUT output reaches its interface through a continuous assign over the
// full width. The ICPSD rule, applied from the start.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_top_tier4d;

    import uvm_pkg::*;
`include "uvm_macros.svh"
    import mqnic_vrf_pkg::*;
    import mqnic_test_pkg::*;

    localparam int AXIS_PCIE_DATA_WIDTH    = 256;
    localparam int AXIS_PCIE_KEEP_WIDTH    = AXIS_PCIE_DATA_WIDTH / 32;
    localparam int AXIS_PCIE_RC_USER_WIDTH = AXIS_PCIE_DATA_WIDTH < 512 ? 75 : 161;
    localparam int AXIS_PCIE_RQ_USER_WIDTH = AXIS_PCIE_DATA_WIDTH < 512 ? 60 : 137;
    localparam int AXIS_PCIE_CQ_USER_WIDTH = AXIS_PCIE_DATA_WIDTH < 512 ? 85 : 183;
    localparam int AXIS_PCIE_CC_USER_WIDTH = AXIS_PCIE_DATA_WIDTH < 512 ? 33 : 81;
    localparam int RC_STRADDLE             = AXIS_PCIE_DATA_WIDTH >= 256;
    localparam int RQ_STRADDLE             = AXIS_PCIE_DATA_WIDTH >= 512;
    localparam int CQ_STRADDLE             = AXIS_PCIE_DATA_WIDTH >= 512;
    localparam int CC_STRADDLE             = AXIS_PCIE_DATA_WIDTH >= 512;
    localparam int RQ_SEQ_NUM_WIDTH        = AXIS_PCIE_RQ_USER_WIDTH == 60 ? 4 : 6;

    localparam int TLP_DATA_WIDTH   = AXIS_PCIE_DATA_WIDTH;
    localparam int TLP_STRB_WIDTH   = TLP_DATA_WIDTH / 32;
    localparam int TLP_HDR_WIDTH    = 128;
    localparam int TLP_SEG_COUNT    = 1;
    localparam int TX_SEQ_NUM_COUNT = AXIS_PCIE_DATA_WIDTH < 512 ? 1 : 2;
    localparam int TX_SEQ_NUM_WIDTH = RQ_SEQ_NUM_WIDTH - 1;
    localparam int PF_COUNT         = 1;
    localparam int VF_COUNT         = 0;
    localparam int F_COUNT          = PF_COUNT + VF_COUNT;
    localparam int READ_EXT_TAG_ENABLE     = 1;
    localparam int READ_MAX_READ_REQ_SIZE  = 1;
    localparam int READ_MAX_PAYLOAD_SIZE   = 1;
    localparam int MSIX_ENABLE  = 1;
    localparam int MSI_ENABLE   = 0;
    localparam int MSI_COUNT    = 32;

    // pcie_tlp_if declares these as its own localparams, which are not visible
    // here. tb_top_tier4a.sv:47 does the same - the interface is at MAXIMUM
    // width per §4.3 rule 1, and the tb pads up to it.
    localparam int TLP_MAX_DATA_WIDTH = 512;
    localparam int TLP_MAX_STRB_WIDTH = TLP_MAX_DATA_WIDTH / 32;
    localparam int TLP_MAX_SEG_COUNT  = 4;
    localparam int TLP_MAX_HDR_WIDTH  = 128;

    localparam time CLK_HALF_PERIOD = 2ns;

    logic clk;
    initial clk = 1'b0;
    always #CLK_HALF_PERIOD clk = ~clk;

    mqnic_reset_if rst_if (.clk(clk));
    wire rst = rst_if.rst;

    // ---- Xilinx side ------------------------------------------------------
    pcie_us_axis_if rc_axis_vif (.clk(clk), .rst(rst));
    pcie_us_axis_if cq_axis_vif (.clk(clk), .rst(rst));
    pcie_us_axis_if rq_axis_vif (.clk(clk), .rst(rst));
    pcie_us_axis_if cc_axis_vif (.clk(clk), .rst(rst));

    // ---- generic TLP side -------------------------------------------------
    pcie_tlp_if req_vif   (.clk(clk), .rst(rst));   // rx_req  - DUT drives
    pcie_tlp_if cpl_vif   (.clk(clk), .rst(rst));   // rx_cpl  - DUT drives
    pcie_tlp_if txcpl_vif (.clk(clk), .rst(rst));   // tx_cpl  - TB drives

    wire txcpl_tlp_ready;

    // ---- DUT outputs, captured at full width then assigned across ---------
    wire [AXIS_PCIE_DATA_WIDTH-1:0]        rq_tdata, cc_tdata;
    wire [AXIS_PCIE_KEEP_WIDTH-1:0]        rq_tkeep, cc_tkeep;
    wire                                   rq_tvalid, cc_tvalid;
    wire                                   rq_tlast, cc_tlast;
    wire [AXIS_PCIE_RQ_USER_WIDTH-1:0]     rq_tuser;
    wire [AXIS_PCIE_CC_USER_WIDTH-1:0]     cc_tuser;

    wire [TLP_DATA_WIDTH-1:0]              req_data, cpl_data;
    wire [TLP_STRB_WIDTH-1:0]              req_strb, cpl_strb;
    wire [TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0] req_hdr, cpl_hdr;
    wire [TLP_SEG_COUNT*3-1:0]             req_bar_id;
    wire [TLP_SEG_COUNT*8-1:0]             req_func_num;
    wire [TLP_SEG_COUNT*4-1:0]             cpl_error;
    wire [TLP_SEG_COUNT-1:0]               req_valid, req_sop, req_eop;
    wire [TLP_SEG_COUNT-1:0]               cpl_valid, cpl_sop, cpl_eop;

    // ---- configuration management ----------------------------------------
    // The TB plays PCIe config space. pcie_us_cfg polls it forever; without a
    // responder max_payload_size stays 0, which looks exactly like a DUT that
    // cannot read its own configuration.
    wire [9:0]   cfg_mgmt_addr;
    wire         cfg_mgmt_read, cfg_mgmt_write;
    logic [31:0] cfg_mgmt_read_data;
    logic        cfg_mgmt_read_write_done;

    wire [F_COUNT-1:0]   ext_tag_enable;
    wire [F_COUNT*3-1:0] max_read_request_size;
    wire [F_COUNT*3-1:0] max_payload_size;

    // The status pins and the config-space value the TB returns live on an
    // interface, not in this module: a test lives in a package and cannot make
    // a hierarchical reference into a testbench (IEEE 1800). See
    // uvc/common/pcie_us_cfg_status_if.sv.
    pcie_us_cfg_status_if cfg_status_vif (.clk(clk), .rst(rst));

    initial cfg_status_vif.set_dev_ctrl(3'd2, 3'd5, 1'b1);   // MPS 2, MRRS 5

    assign cfg_status_vif.max_payload_size      = max_payload_size;
    assign cfg_status_vif.max_read_request_size = max_read_request_size;
    assign cfg_status_vif.ext_tag_enable        = ext_tag_enable;

    always_ff @(posedge clk) begin
        if (rst) begin
            cfg_mgmt_read_write_done <= 1'b0;
            cfg_mgmt_read_data       <= 32'd0;
        end
        else if ((cfg_mgmt_read || cfg_mgmt_write) && !cfg_mgmt_read_write_done) begin
            cfg_mgmt_read_data       <= cfg_status_vif.dev_ctrl_value;
            cfg_mgmt_read_write_done <= 1'b1;
        end
        else begin
            cfg_mgmt_read_write_done <= 1'b0;
        end
    end

    // ---- ICPSD: every output reaches its interface, full width ------------
    assign rq_axis_vif.tdata  = {{(US_MAX_DATA_WIDTH-AXIS_PCIE_DATA_WIDTH){1'b0}}, rq_tdata};
    assign rq_axis_vif.tkeep  = {{(US_MAX_KEEP_WIDTH-AXIS_PCIE_KEEP_WIDTH){1'b0}}, rq_tkeep};
    assign rq_axis_vif.tvalid = rq_tvalid;
    assign rq_axis_vif.tlast  = rq_tlast;
    assign rq_axis_vif.tuser  = {{(US_MAX_USER_WIDTH-AXIS_PCIE_RQ_USER_WIDTH){1'b0}}, rq_tuser};

    assign cc_axis_vif.tdata  = {{(US_MAX_DATA_WIDTH-AXIS_PCIE_DATA_WIDTH){1'b0}}, cc_tdata};
    assign cc_axis_vif.tkeep  = {{(US_MAX_KEEP_WIDTH-AXIS_PCIE_KEEP_WIDTH){1'b0}}, cc_tkeep};
    assign cc_axis_vif.tvalid = cc_tvalid;
    assign cc_axis_vif.tlast  = cc_tlast;
    assign cc_axis_vif.tuser  = {{(US_MAX_USER_WIDTH-AXIS_PCIE_CC_USER_WIDTH){1'b0}}, cc_tuser};

    assign req_vif.tlp_data     = {{(TLP_MAX_DATA_WIDTH-TLP_DATA_WIDTH){1'b0}}, req_data};
    assign req_vif.tlp_strb     = {{(TLP_MAX_STRB_WIDTH-TLP_STRB_WIDTH){1'b0}}, req_strb};
    assign req_vif.tlp_hdr      = {{(TLP_MAX_SEG_COUNT*TLP_MAX_HDR_WIDTH-TLP_SEG_COUNT*TLP_HDR_WIDTH){1'b0}}, req_hdr};
    assign req_vif.tlp_bar_id   = {{(TLP_MAX_SEG_COUNT*3-TLP_SEG_COUNT*3){1'b0}}, req_bar_id};
    assign req_vif.tlp_func_num = {{(TLP_MAX_SEG_COUNT*8-TLP_SEG_COUNT*8){1'b0}}, req_func_num};
    assign req_vif.tlp_seq      = '0;
    assign req_vif.tlp_error    = '0;
    assign req_vif.tlp_valid    = {{(TLP_MAX_SEG_COUNT-TLP_SEG_COUNT){1'b0}}, req_valid};
    assign req_vif.tlp_sop      = {{(TLP_MAX_SEG_COUNT-TLP_SEG_COUNT){1'b0}}, req_sop};
    assign req_vif.tlp_eop      = {{(TLP_MAX_SEG_COUNT-TLP_SEG_COUNT){1'b0}}, req_eop};

    assign cpl_vif.tlp_data     = {{(TLP_MAX_DATA_WIDTH-TLP_DATA_WIDTH){1'b0}}, cpl_data};
    assign cpl_vif.tlp_strb     = {{(TLP_MAX_STRB_WIDTH-TLP_STRB_WIDTH){1'b0}}, cpl_strb};
    assign cpl_vif.tlp_hdr      = {{(TLP_MAX_SEG_COUNT*TLP_MAX_HDR_WIDTH-TLP_SEG_COUNT*TLP_HDR_WIDTH){1'b0}}, cpl_hdr};
    assign cpl_vif.tlp_error    = {{(TLP_MAX_SEG_COUNT*4-TLP_SEG_COUNT*4){1'b0}}, cpl_error};
    assign cpl_vif.tlp_bar_id   = '0;
    assign cpl_vif.tlp_func_num = '0;
    assign cpl_vif.tlp_seq      = '0;
    assign cpl_vif.tlp_valid    = {{(TLP_MAX_SEG_COUNT-TLP_SEG_COUNT){1'b0}}, cpl_valid};
    assign cpl_vif.tlp_sop      = {{(TLP_MAX_SEG_COUNT-TLP_SEG_COUNT){1'b0}}, cpl_sop};
    assign cpl_vif.tlp_eop      = {{(TLP_MAX_SEG_COUNT-TLP_SEG_COUNT){1'b0}}, cpl_eop};

    assign txcpl_vif.tlp_ready  = txcpl_tlp_ready;

    pcie_us_if #(
        .AXIS_PCIE_DATA_WIDTH(AXIS_PCIE_DATA_WIDTH),
        .AXIS_PCIE_KEEP_WIDTH(AXIS_PCIE_KEEP_WIDTH),
        .AXIS_PCIE_RC_USER_WIDTH(AXIS_PCIE_RC_USER_WIDTH),
        .AXIS_PCIE_RQ_USER_WIDTH(AXIS_PCIE_RQ_USER_WIDTH),
        .AXIS_PCIE_CQ_USER_WIDTH(AXIS_PCIE_CQ_USER_WIDTH),
        .AXIS_PCIE_CC_USER_WIDTH(AXIS_PCIE_CC_USER_WIDTH),
        .RC_STRADDLE(RC_STRADDLE),
        .RQ_STRADDLE(RQ_STRADDLE),
        .CQ_STRADDLE(CQ_STRADDLE),
        .CC_STRADDLE(CC_STRADDLE),
        .RQ_SEQ_NUM_WIDTH(RQ_SEQ_NUM_WIDTH),
        .TLP_DATA_WIDTH(TLP_DATA_WIDTH),
        .TLP_STRB_WIDTH(TLP_STRB_WIDTH),
        .TLP_HDR_WIDTH(TLP_HDR_WIDTH),
        .TLP_SEG_COUNT(TLP_SEG_COUNT),
        .TX_SEQ_NUM_COUNT(TX_SEQ_NUM_COUNT),
        .TX_SEQ_NUM_WIDTH(TX_SEQ_NUM_WIDTH),
        .PF_COUNT(PF_COUNT),
        .VF_COUNT(VF_COUNT),
        .F_COUNT(F_COUNT),
        .READ_EXT_TAG_ENABLE(READ_EXT_TAG_ENABLE),
        .READ_MAX_READ_REQ_SIZE(READ_MAX_READ_REQ_SIZE),
        .READ_MAX_PAYLOAD_SIZE(READ_MAX_PAYLOAD_SIZE),
        .MSIX_ENABLE(MSIX_ENABLE),
        .MSI_ENABLE(MSI_ENABLE),
        .MSI_COUNT(MSI_COUNT)
    ) u_pcie_us_if (
        .clk                                   (clk),   // input  
        .rst                                   (rst),   // input  
        .s_axis_rc_tdata                       (rc_axis_vif.tdata[AXIS_PCIE_DATA_WIDTH-1:0]),   // input  [AXIS_PCIE_DATA_WIDTH-1:0]
        .s_axis_rc_tkeep                       (rc_axis_vif.tkeep[AXIS_PCIE_KEEP_WIDTH-1:0]),   // input  [AXIS_PCIE_KEEP_WIDTH-1:0]
        .s_axis_rc_tvalid                      (rc_axis_vif.tvalid),   // input  
        .s_axis_rc_tready                      (rc_axis_vif.tready),   // output 
        .s_axis_rc_tlast                       (rc_axis_vif.tlast),   // input  
        .s_axis_rc_tuser                       (rc_axis_vif.tuser[AXIS_PCIE_RC_USER_WIDTH-1:0]),   // input  [AXIS_PCIE_RC_USER_WIDTH-1:0]
        .m_axis_rq_tdata                       (rq_tdata),   // output [AXIS_PCIE_DATA_WIDTH-1:0]
        .m_axis_rq_tkeep                       (rq_tkeep),   // output [AXIS_PCIE_KEEP_WIDTH-1:0]
        .m_axis_rq_tvalid                      (rq_tvalid),   // output 
        .m_axis_rq_tready                      (rq_axis_vif.tready),   // input     // peer always ready - see tie_off()
        .m_axis_rq_tlast                       (rq_tlast),   // output 
        .m_axis_rq_tuser                       (rq_tuser),   // output [AXIS_PCIE_RQ_USER_WIDTH-1:0]
        .s_axis_cq_tdata                       (cq_axis_vif.tdata[AXIS_PCIE_DATA_WIDTH-1:0]),   // input  [AXIS_PCIE_DATA_WIDTH-1:0]
        .s_axis_cq_tkeep                       (cq_axis_vif.tkeep[AXIS_PCIE_KEEP_WIDTH-1:0]),   // input  [AXIS_PCIE_KEEP_WIDTH-1:0]
        .s_axis_cq_tvalid                      (cq_axis_vif.tvalid),   // input  
        .s_axis_cq_tready                      (cq_axis_vif.tready),   // output 
        .s_axis_cq_tlast                       (cq_axis_vif.tlast),   // input  
        .s_axis_cq_tuser                       (cq_axis_vif.tuser[AXIS_PCIE_CQ_USER_WIDTH-1:0]),   // input  [AXIS_PCIE_CQ_USER_WIDTH-1:0]
        .m_axis_cc_tdata                       (cc_tdata),   // output [AXIS_PCIE_DATA_WIDTH-1:0]
        .m_axis_cc_tkeep                       (cc_tkeep),   // output [AXIS_PCIE_KEEP_WIDTH-1:0]
        .m_axis_cc_tvalid                      (cc_tvalid),   // output 
        .m_axis_cc_tready                      (cc_axis_vif.tready),   // input     // peer always ready - see tie_off()
        .m_axis_cc_tlast                       (cc_tlast),   // output 
        .m_axis_cc_tuser                       (cc_tuser),   // output [AXIS_PCIE_CC_USER_WIDTH-1:0]
        .s_axis_rq_seq_num_0                   ('0),      // input  [RQ_SEQ_NUM_WIDTH-1:0]
        .s_axis_rq_seq_num_valid_0             ('0),      // input  
        .s_axis_rq_seq_num_1                   ('0),      // input  [RQ_SEQ_NUM_WIDTH-1:0]
        .s_axis_rq_seq_num_valid_1             ('0),      // input  
        .cfg_mgmt_addr                         (cfg_mgmt_addr),   // output [9:0]
        .cfg_mgmt_function_number              (),        // output [7:0]
        .cfg_mgmt_write                        (cfg_mgmt_write),   // output 
        .cfg_mgmt_write_data                   (),        // output [31:0]
        .cfg_mgmt_byte_enable                  (),        // output [3:0]
        .cfg_mgmt_read                         (cfg_mgmt_read),   // output 
        .cfg_mgmt_read_data                    (cfg_mgmt_read_data),   // input  [31:0]
        .cfg_mgmt_read_write_done              (cfg_mgmt_read_write_done),   // input  
        .cfg_max_payload                       ('0),      // input  [2:0]
        .cfg_max_read_req                      ('0),      // input  [2:0]
        .cfg_fc_ph                             ('0),      // input  [7:0]
        .cfg_fc_pd                             ('0),      // input  [11:0]
        .cfg_fc_nph                            ('0),      // input  [7:0]
        .cfg_fc_npd                            ('0),      // input  [11:0]
        .cfg_fc_cplh                           ('0),      // input  [7:0]
        .cfg_fc_cpld                           ('0),      // input  [11:0]
        .cfg_fc_sel                            (),        // output [2:0]
        .cfg_interrupt_msi_enable              ('0),      // input  [3:0]
        .cfg_interrupt_msi_vf_enable           ('0),      // input  [7:0]
        .cfg_interrupt_msi_mmenable            ('0),      // input  [11:0]
        .cfg_interrupt_msi_mask_update         ('0),      // input  
        .cfg_interrupt_msi_data                ('0),      // input  [31:0]
        .cfg_interrupt_msi_select              (),        // output [3:0]
        .cfg_interrupt_msi_int                 (),        // output [31:0]
        .cfg_interrupt_msi_pending_status      (),        // output [31:0]
        .cfg_interrupt_msi_pending_status_data_enable(),        // output 
        .cfg_interrupt_msi_pending_status_function_num(),        // output [3:0]
        .cfg_interrupt_msi_sent                ('0),      // input  
        .cfg_interrupt_msi_fail                ('0),      // input  
        .cfg_interrupt_msix_enable             ('0),      // input  [3:0]
        .cfg_interrupt_msix_mask               ('0),      // input  [3:0]
        .cfg_interrupt_msix_vf_enable          ('0),      // input  [251:0]
        .cfg_interrupt_msix_vf_mask            ('0),      // input  [251:0]
        .cfg_interrupt_msix_address            (),        // output [63:0]
        .cfg_interrupt_msix_data               (),        // output [31:0]
        .cfg_interrupt_msix_int                (),        // output 
        .cfg_interrupt_msix_vec_pending        (),        // output [1:0]
        .cfg_interrupt_msix_vec_pending_status ('0),      // input  
        .cfg_interrupt_msix_sent               ('0),      // input  
        .cfg_interrupt_msix_fail               ('0),      // input  
        .cfg_interrupt_msi_attr                (),        // output [2:0]
        .cfg_interrupt_msi_tph_present         (),        // output 
        .cfg_interrupt_msi_tph_type            (),        // output [1:0]
        .cfg_interrupt_msi_tph_st_tag          (),        // output [8:0]
        .cfg_interrupt_msi_function_number     (),        // output [7:0]
        .rx_req_tlp_data                       (req_data),   // output [TLP_DATA_WIDTH-1:0]
        .rx_req_tlp_strb                       (req_strb),   // output [TLP_STRB_WIDTH-1:0]
        .rx_req_tlp_hdr                        (req_hdr),   // output [TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]
        .rx_req_tlp_bar_id                     (req_bar_id),   // output [TLP_SEG_COUNT*3-1:0]
        .rx_req_tlp_func_num                   (req_func_num),   // output [TLP_SEG_COUNT*8-1:0]
        .rx_req_tlp_valid                      (req_valid),   // output [TLP_SEG_COUNT-1:0]
        .rx_req_tlp_sop                        (req_sop),   // output [TLP_SEG_COUNT-1:0]
        .rx_req_tlp_eop                        (req_eop),   // output [TLP_SEG_COUNT-1:0]
        .rx_req_tlp_ready                      (req_vif.tlp_ready),   // input     // peer always ready - see tie_off()
        .rx_cpl_tlp_data                       (cpl_data),   // output [TLP_DATA_WIDTH-1:0]
        .rx_cpl_tlp_strb                       (cpl_strb),   // output [TLP_STRB_WIDTH-1:0]
        .rx_cpl_tlp_hdr                        (cpl_hdr),   // output [TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]
        .rx_cpl_tlp_error                      (cpl_error),   // output [TLP_SEG_COUNT*4-1:0]
        .rx_cpl_tlp_valid                      (cpl_valid),   // output [TLP_SEG_COUNT-1:0]
        .rx_cpl_tlp_sop                        (cpl_sop),   // output [TLP_SEG_COUNT-1:0]
        .rx_cpl_tlp_eop                        (cpl_eop),   // output [TLP_SEG_COUNT-1:0]
        .rx_cpl_tlp_ready                      (cpl_vif.tlp_ready),   // input     // peer always ready - see tie_off()
        .tx_rd_req_tlp_hdr                     ('0),      // input  [TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]
        .tx_rd_req_tlp_seq                     ('0),      // input  [TLP_SEG_COUNT*TX_SEQ_NUM_WIDTH-1:0]
        .tx_rd_req_tlp_valid                   ('0),      // input  [TLP_SEG_COUNT-1:0]
        .tx_rd_req_tlp_sop                     ('0),      // input  [TLP_SEG_COUNT-1:0]
        .tx_rd_req_tlp_eop                     ('0),      // input  [TLP_SEG_COUNT-1:0]
        .tx_rd_req_tlp_ready                   (),        // output 
        .m_axis_rd_req_tx_seq_num              (),        // output [TX_SEQ_NUM_COUNT*TX_SEQ_NUM_WIDTH-1:0]
        .m_axis_rd_req_tx_seq_num_valid        (),        // output [TX_SEQ_NUM_COUNT-1:0]
        .tx_wr_req_tlp_data                    ('0),      // input  [TLP_DATA_WIDTH-1:0]
        .tx_wr_req_tlp_strb                    ('0),      // input  [TLP_STRB_WIDTH-1:0]
        .tx_wr_req_tlp_hdr                     ('0),      // input  [TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]
        .tx_wr_req_tlp_seq                     ('0),      // input  [TLP_SEG_COUNT*TX_SEQ_NUM_WIDTH-1:0]
        .tx_wr_req_tlp_valid                   ('0),      // input  [TLP_SEG_COUNT-1:0]
        .tx_wr_req_tlp_sop                     ('0),      // input  [TLP_SEG_COUNT-1:0]
        .tx_wr_req_tlp_eop                     ('0),      // input  [TLP_SEG_COUNT-1:0]
        .tx_wr_req_tlp_ready                   (),        // output 
        .m_axis_wr_req_tx_seq_num              (),        // output [TX_SEQ_NUM_COUNT*TX_SEQ_NUM_WIDTH-1:0]
        .m_axis_wr_req_tx_seq_num_valid        (),        // output [TX_SEQ_NUM_COUNT-1:0]
        .tx_cpl_tlp_data                       (txcpl_vif.tlp_data[TLP_DATA_WIDTH-1:0]),   // input  [TLP_DATA_WIDTH-1:0]
        .tx_cpl_tlp_strb                       (txcpl_vif.tlp_strb[TLP_STRB_WIDTH-1:0]),   // input  [TLP_STRB_WIDTH-1:0]
        .tx_cpl_tlp_hdr                        (txcpl_vif.tlp_hdr[TLP_HDR_WIDTH-1:0]),   // input  [TLP_SEG_COUNT*TLP_HDR_WIDTH-1:0]
        .tx_cpl_tlp_valid                      (txcpl_vif.tlp_valid[0]),   // input  [TLP_SEG_COUNT-1:0]
        .tx_cpl_tlp_sop                        (txcpl_vif.tlp_sop[0]),   // input  [TLP_SEG_COUNT-1:0]
        .tx_cpl_tlp_eop                        (txcpl_vif.tlp_eop[0]),   // input  [TLP_SEG_COUNT-1:0]
        .tx_cpl_tlp_ready                      (txcpl_tlp_ready),   // output 
        .tx_msix_wr_req_tlp_data               ('0),      // input  [31:0]
        .tx_msix_wr_req_tlp_strb               ('0),      // input  
        .tx_msix_wr_req_tlp_hdr                ('0),      // input  [TLP_HDR_WIDTH-1:0]
        .tx_msix_wr_req_tlp_valid              ('0),      // input  
        .tx_msix_wr_req_tlp_sop                ('0),      // input  
        .tx_msix_wr_req_tlp_eop                ('0),      // input  
        .tx_msix_wr_req_tlp_ready              (),        // output 
        .tx_fc_ph_av                           (),        // output [7:0]
        .tx_fc_pd_av                           (),        // output [11:0]
        .tx_fc_nph_av                          (),        // output [7:0]
        .tx_fc_npd_av                          (),        // output [11:0]
        .tx_fc_cplh_av                         (),        // output [7:0]
        .tx_fc_cpld_av                         (),        // output [11:0]
        .ext_tag_enable                        (ext_tag_enable),   // output [F_COUNT-1:0]
        .max_read_request_size                 (max_read_request_size),   // output [F_COUNT*3-1:0]
        .max_payload_size                      (max_payload_size),   // output [F_COUNT*3-1:0]
        .msix_enable                           (),        // output [F_COUNT-1:0]
        .msix_mask                             (),        // output [F_COUNT-1:0]
        .msi_irq                               ('0)      // input  [MSI_COUNT-1:0]
    );

    // pcie_us_if latches sop/eop rather than gating them on valid, the same way
    // the routing blocks do (bug 15). The generic-side monitors must not assert
    // a_sop_implies_valid here.
    initial begin
        req_vif.sop_eop_gated   = 1'b0;
        cpl_vif.sop_eop_gated   = 1'b0;
        txcpl_vif.sop_eop_gated = 1'b0;
    end

    // Interfaces are published onto the AGENT paths, matching tb_top_tier4a.sv:
    // the agents look up an unqualified "vif" scoped to themselves, so a
    // wildcard set would hand every agent the same interface.
    initial begin
        uvm_config_db #(virtual mqnic_reset_if)::set(null, "uvm_test_top", "rst_vif", rst_if);
        uvm_config_db #(virtual pcie_us_axis_if)::set(null, "uvm_test_top.m_env.m_rc_axis*",  "vif", rc_axis_vif);
        uvm_config_db #(virtual pcie_us_axis_if)::set(null, "uvm_test_top.m_env.m_cq_axis*",  "vif", cq_axis_vif);
        uvm_config_db #(virtual pcie_us_axis_if)::set(null, "uvm_test_top.m_env.m_cc_axis*",  "vif", cc_axis_vif);
        uvm_config_db #(virtual pcie_us_axis_if)::set(null, "uvm_test_top.m_env.m_rq_axis*",  "vif", rq_axis_vif);
        uvm_config_db #(virtual pcie_tlp_if)::set    (null, "uvm_test_top.m_env.m_req_tlp*",  "vif", req_vif);
        uvm_config_db #(virtual pcie_tlp_if)::set    (null, "uvm_test_top.m_env.m_cpl_tlp*",  "vif", cpl_vif);
        uvm_config_db #(virtual pcie_tlp_if)::set    (null, "uvm_test_top.m_env.m_txcpl_tlp*", "vif", txcpl_vif);
        uvm_config_db #(virtual pcie_us_cfg_status_if)::set(null, "uvm_test_top", "cfg_status_vif", cfg_status_vif);
        run_test();
    end

endmodule : tb_top_tier4d

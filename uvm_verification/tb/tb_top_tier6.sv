// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tb_top_tier6 - Tier 6 testbench top (mqnic_core_pcie_us)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §3.1, §5 Tier 6, §18
//
// THE STRATEGY'S TOP DUT. VERIFICATION_STRATEGY.md is titled after this module
// and §3.1 marks it TIER 6 DUT. Everything below it has been verified in
// isolation; this is the first configuration in which the whole PCIe host
// interface exists at once:
//
//     mqnic_core_pcie_us
//       |- pcie_us_if        Tier 4d
//       \- mqnic_core_pcie   Tier 5
//
// WHAT IS NEW HERE IS THE SEAM.
// Both halves already pass. At Tier 5 a register read was driven straight onto
// the generic TLP interface; here the same read must arrive as a XILINX CQ
// DESCRIPTOR, cross pcie_us_if_cq, the demux, pcie_axil_master, three AXI-Lite
// crossbars, mqnic_interface and axil_reg_if, and return as a CC descriptor
// built by pcie_us_if_cc. Two independently correct halves can still disagree
// about byte enables, straddling or where a tag lives, and neither half's own
// testbench can see that.
//
// 252 PORTS, GENERATED. Every port appears exactly once, inputs tied off and
// outputs left open, so "unconnected" is a decision rather than an omission
// (sim/scripts/gen_tb_ports.py). A floating input on a DUT this size is not
// something a waveform makes obvious - see bug 30.
//
// LIVE: the BAR path and configuration (register tests), and - for objective
// G5 - the whole datapath: DMA (RQ/RC with sequence-number return and
// transmit flow-control credits), the
// Ethernet MAC port in both directions with TX completions, and the PTP and
// Ethernet clock domains. DDR, HBM, the application block, GPIO and JTAG stay
// tied off: their features are disabled by this configuration's parameters.
//
// MPS AND MRRS COME FROM PINS AT THIS LEVEL, NOT FROM THE CONFIG POLLING:
//     mqnic_core_pcie_us.v:861-862   pcie_us_if .max_payload_size()  DISCARDED
//     mqnic_core_pcie_us.v:1159-60   core takes cfg_max_payload / cfg_max_read_req
//     mqnic_core_pcie_us.v:283-284   which are INPUT PINS
// Only ext_tag_enable survives from pcie_us_cfg. Tier 4d verified an extraction
// path that this configuration does not use for two of its three outputs, so the
// pins are driven from the status interface here and checked as such.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_top_tier6;

    import uvm_pkg::*;
`include "uvm_macros.svh"
    import mqnic_vrf_pkg::*;
    import mqnic_test_pkg::*;

    // Golden PCIe geometry, matching mqnic_core_pcie_us.v:559-562.
    localparam int AXIS_PCIE_DATA_WIDTH    = 256;
    localparam int AXIS_PCIE_KEEP_WIDTH    = AXIS_PCIE_DATA_WIDTH / 32;
    localparam int AXIS_PCIE_RC_USER_WIDTH = AXIS_PCIE_DATA_WIDTH < 512 ? 75 : 161;
    // 62, NOT 60: mqnic_core_pcie_us.v:178 defaults RQ to 62 bits, which makes
    // RQ_SEQ_NUM_WIDTH 6 (:185). Declaring 60 here truncated tuser[61:60] - the
    // top two sequence-number bits, including the read/write flag the shim uses
    // to route returned numbers (pcie_us_if_rq.v:278-280). Invisible to the
    // register tests, fatal to DMA.
    localparam int AXIS_PCIE_RQ_USER_WIDTH = AXIS_PCIE_DATA_WIDTH < 512 ? 62 : 137;
    localparam int RQ_SEQ_NUM_WIDTH        = AXIS_PCIE_RQ_USER_WIDTH == 60 ? 4 : 6;

    // Ethernet port geometry, matching mqnic_core_pcie_us.v defaults.
    localparam int ETH_DATA_WIDTH    = 512;
    localparam int ETH_KEEP_WIDTH    = ETH_DATA_WIDTH / 8;
    localparam int PTP_TS_WIDTH      = 96;
    localparam int TX_TAG_WIDTH      = $clog2(32) + 1;        // TX_DESC_TABLE_SIZE = 32
    localparam int ETH_TX_USER_WIDTH = TX_TAG_WIDTH + 1;      // {tag, 1'b0}
    localparam int ETH_RX_USER_WIDTH = PTP_TS_WIDTH + 1;      // {timestamp, bad_frame}
    localparam int AXIS_PCIE_CQ_USER_WIDTH = AXIS_PCIE_DATA_WIDTH < 512 ? 85 : 183;
    localparam int AXIS_PCIE_CC_USER_WIDTH = AXIS_PCIE_DATA_WIDTH < 512 ? 33 : 81;

    localparam int TLP_MAX_SEG_COUNT  = 4;
    localparam int TLP_MAX_DATA_WIDTH = 512;
    localparam int TLP_MAX_STRB_WIDTH = 16;

    localparam time CLK_HALF_PERIOD = 2ns;

    logic clk;
    initial clk = 1'b0;
    always #CLK_HALF_PERIOD clk = ~clk;

    mqnic_reset_if rst_if (.clk(clk));
    wire rst = rst_if.rst;

    // ---- Xilinx side - the only transport the host has at this tier --------
    pcie_us_axis_if cq_axis_vif (.clk(clk), .rst(rst));   // TB drives
    pcie_us_axis_if cc_axis_vif (.clk(clk), .rst(rst));   // DUT drives
    pcie_us_axis_if rc_axis_vif (.clk(clk), .rst(rst));   // TB drives
    pcie_us_axis_if rq_axis_vif (.clk(clk), .rst(rst));   // DUT drives

    // ---- DUT-driven nets, captured at full width then assigned across ------
    wire [AXIS_PCIE_DATA_WIDTH-1:0]    cc_tdata, rq_tdata;
    wire [AXIS_PCIE_KEEP_WIDTH-1:0]    cc_tkeep, rq_tkeep;
    wire                               cc_tvalid, rq_tvalid;
    wire                               cc_tlast, rq_tlast;
    wire [AXIS_PCIE_CC_USER_WIDTH-1:0] cc_tuser;
    wire [AXIS_PCIE_RQ_USER_WIDTH-1:0] rq_tuser;

    // ---- configuration -----------------------------------------------------
    // The TB plays PCIe config space AND drives the MPS/MRRS pins, because at
    // this level those are two different sources - see the header.
    wire         cfg_mgmt_read, cfg_mgmt_write;
    logic [31:0] cfg_mgmt_read_data;
    logic        cfg_mgmt_read_write_done;

    pcie_us_cfg_status_if cfg_status_vif (.clk(clk), .rst(rst));

    initial begin
        cfg_status_vif.set_dev_ctrl(3'd2, 3'd5, 1'b1);
        cfg_status_vif.max_payload_size      = 3'd2;   // driven INTO the DUT here
        cfg_status_vif.max_read_request_size = 3'd5;
    end

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

    // ---- ICPSD: every output reaches its interface, full width -------------
    assign cc_axis_vif.tdata  = {{(US_MAX_DATA_WIDTH-AXIS_PCIE_DATA_WIDTH){1'b0}}, cc_tdata};
    assign cc_axis_vif.tkeep  = {{(US_MAX_KEEP_WIDTH-AXIS_PCIE_KEEP_WIDTH){1'b0}}, cc_tkeep};
    assign cc_axis_vif.tvalid = cc_tvalid;
    assign cc_axis_vif.tlast  = cc_tlast;
    assign cc_axis_vif.tuser  = {{(US_MAX_USER_WIDTH-AXIS_PCIE_CC_USER_WIDTH){1'b0}}, cc_tuser};

    assign rq_axis_vif.tdata  = {{(US_MAX_DATA_WIDTH-AXIS_PCIE_DATA_WIDTH){1'b0}}, rq_tdata};
    assign rq_axis_vif.tkeep  = {{(US_MAX_KEEP_WIDTH-AXIS_PCIE_KEEP_WIDTH){1'b0}}, rq_tkeep};
    assign rq_axis_vif.tvalid = rq_tvalid;
    assign rq_axis_vif.tlast  = rq_tlast;
    assign rq_axis_vif.tuser  = {{(US_MAX_USER_WIDTH-AXIS_PCIE_RQ_USER_WIDTH){1'b0}}, rq_tuser};

    // ---- Ethernet and PTP clock domains ------------------------------------
    // Different from the core clock on purpose, so the async FIFOs between the
    // port and the interface are crossed for real: 3.102 ns is the 100G MAC
    // clock upstream's own testbench uses at 512 bits; the PTP clock runs at
    // the 4 ns its period parameters describe (PTP_CLK_PERIOD_NS_NUM = 4).
    logic eth_clk, ptp_clk, ptp_sample_clk;
    initial begin eth_clk = 1'b0; ptp_clk = 1'b0; ptp_sample_clk = 1'b0; end
    always #1.551ns eth_clk        = ~eth_clk;
    always #2ns     ptp_clk        = ~ptp_clk;
    always #4ns     ptp_sample_clk = ~ptp_sample_clk;

    // Each domain's reset is the core reset, synchronised into that domain.
    logic [1:0] eth_rst_sync = 2'b11, ptp_rst_sync = 2'b11;
    always @(posedge eth_clk) eth_rst_sync <= {eth_rst_sync[0], rst};
    always @(posedge ptp_clk) ptp_rst_sync <= {ptp_rst_sync[0], rst};
    wire eth_rst = eth_rst_sync[1];
    wire ptp_rst = ptp_rst_sync[1];

    // ---- Ethernet MAC side --------------------------------------------------
    axis_if eth_tx_vif (.clk(eth_clk), .rst(eth_rst));   // DUT drives, TB sinks
    axis_if eth_rx_vif (.clk(eth_clk), .rst(eth_rst));   // TB drives

    wire [ETH_DATA_WIDTH-1:0]    eth_tx_tdata;
    wire [ETH_KEEP_WIDTH-1:0]    eth_tx_tkeep;
    wire                         eth_tx_tvalid, eth_tx_tlast;
    wire [ETH_TX_USER_WIDTH-1:0] eth_tx_tuser;
    wire                         eth_rx_tready;
    wire [PTP_TS_WIDTH-1:0]      eth_tx_ptp_ts_tod;

    assign eth_tx_vif.tdata  = eth_tx_tdata;
    assign eth_tx_vif.tkeep  = eth_tx_tkeep;
    assign eth_tx_vif.tvalid = eth_tx_tvalid;
    assign eth_tx_vif.tlast  = eth_tx_tlast;
    assign eth_tx_vif.tuser  = 128'(eth_tx_tuser);
    assign eth_tx_vif.tid    = '0;
    assign eth_tx_vif.tdest  = '0;
    assign eth_rx_vif.tready = eth_rx_tready;

    // ---- TX completions: what the MAC returns for every frame it sends -----
    // TX_CPL_ENABLE = PTP_TS_ENABLE = 1, so the DUT writes a TX completion only
    // after the MAC hands back the frame's tag (tuser[1 +: TX_TAG_WIDTH],
    // mqnic_port_tx.v:190) with a timestamp. A MAC model that skipped this
    // would leave every transmit descriptor outstanding forever.
    logic [PTP_TS_WIDTH-1:0] eth_tx_cpl_ts    = '0;
    logic [TX_TAG_WIDTH-1:0] eth_tx_cpl_tag   = '0;
    logic                    eth_tx_cpl_valid = 1'b0;
    wire                     eth_tx_cpl_ready;
    logic [PTP_TS_WIDTH+TX_TAG_WIDTH-1:0] eth_tx_cpl_q [$];
    int unsigned             eth_tx_cpl_count = 0;

    always @(posedge eth_clk) begin
        if (eth_rst) begin
            eth_tx_cpl_q.delete();
            eth_tx_cpl_valid <= 1'b0;
        end
        else begin
            if (eth_tx_tvalid && eth_tx_vif.tready && eth_tx_tlast)
                eth_tx_cpl_q.push_back({eth_tx_ptp_ts_tod, eth_tx_tuser[1 +: TX_TAG_WIDTH]});
            if (eth_tx_cpl_valid && eth_tx_cpl_ready) begin
                eth_tx_cpl_valid <= 1'b0;
                eth_tx_cpl_count <= eth_tx_cpl_count + 1;
            end
            if ((!eth_tx_cpl_valid || eth_tx_cpl_ready) && eth_tx_cpl_q.size() > 0) begin
                {eth_tx_cpl_ts, eth_tx_cpl_tag} <= eth_tx_cpl_q.pop_front();
                eth_tx_cpl_valid <= 1'b1;
            end
        end
    end

    // ---- PCIe transmit flow-control credits ---------------------------------
    // pcie_us_if passes cfg_fc_* straight to the RQ shim as AVAILABLE credits
    // (pcie_us_if.v:419-422, :506-509, with cfg_fc_sel = 3'b100), and the shim
    // sends nothing without them (pcie_us_if_rq.v:872-873). Tied to 0, as the
    // register-only version of this top had them, DMA can never start - the
    // first end-to-end run issued a descriptor read that sat in the shim's
    // FIFO forever. Driven from pcie_us_fc_if, as at Tier 4c, so a test can
    // starve them; unlimited by default.
    pcie_us_fc_if fc_vif ();
    initial fc_vif.init_unlimited();

    // ---- MSI-X: the hard IP's interrupt interface (objective G7) -----------
    // Enable/mask come from the test (config space); us_msix_hip answers each
    // request with sent or fail. Disabled by default, as before G7.
    pcie_us_msix_if msix_vif (.clk(clk), .rst(rst));

    // ---- RQ sequence numbers: what the hard IP returns per transmitted TLP --
    // TX_SEQ_NUM_ENABLE = 1 at this level (mqnic_core_pcie_us.v:1017): the DMA
    // engines stop after PCIE_DMA_{READ,WRITE}_TX_LIMIT (32 each) TLPs until
    // their sequence numbers come back. Returned at the end of each TLP, which
    // is when the real core reports it.
    logic [RQ_SEQ_NUM_WIDTH-1:0] rq_seq_num   = '0;
    logic                        rq_seq_valid = 1'b0;
    logic                        rq_in_tlp    = 1'b0;
    logic [RQ_SEQ_NUM_WIDTH-1:0] rq_seq_cur   = '0;
    int unsigned                 rq_seq_count = 0;

    always @(posedge clk) begin
        logic [RQ_SEQ_NUM_WIDTH-1:0] s;
        rq_seq_valid <= 1'b0;
        if (rst) begin
            rq_in_tlp <= 1'b0;
        end
        else if (rq_tvalid && rq_axis_vif.tready) begin
            // Read at the first beat; the shim holds it for the whole TLP.
            s = rq_in_tlp ? rq_seq_cur
                          : RQ_SEQ_NUM_WIDTH'(mqnic_vrf_pkg::us_rq_seq_num(
                                184'(rq_tuser), AXIS_PCIE_RQ_USER_WIDTH));
            rq_seq_cur <= s;
            if (rq_tlast) begin
                rq_seq_num   <= s;
                rq_seq_valid <= 1'b1;
                rq_seq_count <= rq_seq_count + 1;
                rq_in_tlp    <= 1'b0;
            end
            else begin
                rq_in_tlp <= 1'b1;
            end
        end
    end

    // NO PARAMETER OVERRIDES, exactly as tb_top_tier5.sv does. Every width
    // this testbench depends on already defaults to the golden geometry
    // (mqnic_core_pcie_us.v:157 is AXIS_PCIE_DATA_WIDTH = 256), and pinning
    // 164 parameters here would freeze a configuration the RTL may move on
    // from - the failure mode this top exists to avoid.
    mqnic_core_pcie_us u_dut (
        .clk                                   (clk),      // input  
        .rst                                   (rst),      // input  
        .s_axis_rc_tdata                       (rc_axis_vif.tdata[AXIS_PCIE_DATA_WIDTH-1:0]),      // input  [AXIS_PCIE_DATA_WIDTH-1:0]
        .s_axis_rc_tkeep                       (rc_axis_vif.tkeep[AXIS_PCIE_KEEP_WIDTH-1:0]),      // input  [AXIS_PCIE_KEEP_WIDTH-1:0]
        .s_axis_rc_tvalid                      (rc_axis_vif.tvalid),      // input  
        .s_axis_rc_tready                      (rc_axis_vif.tready),        // output 
        .s_axis_rc_tlast                       (rc_axis_vif.tlast),      // input  
        .s_axis_rc_tuser                       (rc_axis_vif.tuser[AXIS_PCIE_RC_USER_WIDTH-1:0]),      // input  [AXIS_PCIE_RC_USER_WIDTH-1:0]
        .m_axis_rq_tdata                       (rq_tdata),        // output [AXIS_PCIE_DATA_WIDTH-1:0]
        .m_axis_rq_tkeep                       (rq_tkeep),        // output [AXIS_PCIE_KEEP_WIDTH-1:0]
        .m_axis_rq_tvalid                      (rq_tvalid),        // output 
        .m_axis_rq_tready                      (rq_axis_vif.tready),      // input     // peer always ready - see tie_off()
        .m_axis_rq_tlast                       (rq_tlast),        // output 
        .m_axis_rq_tuser                       (rq_tuser),        // output [AXIS_PCIE_RQ_USER_WIDTH-1:0]
        .s_axis_cq_tdata                       (cq_axis_vif.tdata[AXIS_PCIE_DATA_WIDTH-1:0]),      // input  [AXIS_PCIE_DATA_WIDTH-1:0]
        .s_axis_cq_tkeep                       (cq_axis_vif.tkeep[AXIS_PCIE_KEEP_WIDTH-1:0]),      // input  [AXIS_PCIE_KEEP_WIDTH-1:0]
        .s_axis_cq_tvalid                      (cq_axis_vif.tvalid),      // input  
        .s_axis_cq_tready                      (cq_axis_vif.tready),        // output 
        .s_axis_cq_tlast                       (cq_axis_vif.tlast),      // input  
        .s_axis_cq_tuser                       (cq_axis_vif.tuser[AXIS_PCIE_CQ_USER_WIDTH-1:0]),      // input  [AXIS_PCIE_CQ_USER_WIDTH-1:0]
        .m_axis_cc_tdata                       (cc_tdata),        // output [AXIS_PCIE_DATA_WIDTH-1:0]
        .m_axis_cc_tkeep                       (cc_tkeep),        // output [AXIS_PCIE_KEEP_WIDTH-1:0]
        .m_axis_cc_tvalid                      (cc_tvalid),        // output 
        .m_axis_cc_tready                      (cc_axis_vif.tready),      // input     // peer always ready - see tie_off()
        .m_axis_cc_tlast                       (cc_tlast),        // output 
        .m_axis_cc_tuser                       (cc_tuser),        // output [AXIS_PCIE_CC_USER_WIDTH-1:0]
        .s_axis_rq_seq_num_0                   (rq_seq_num),      // input  [RQ_SEQ_NUM_WIDTH-1:0]
        .s_axis_rq_seq_num_valid_0             (rq_seq_valid),      // input  
        .s_axis_rq_seq_num_1                   ('0),      // input  [RQ_SEQ_NUM_WIDTH-1:0]
        .s_axis_rq_seq_num_valid_1             ('0),      // input  
        .cfg_mgmt_addr                         (),        // output [9:0]
        .cfg_mgmt_function_number              (),        // output [7:0]
        .cfg_mgmt_write                        (cfg_mgmt_write),        // output 
        .cfg_mgmt_write_data                   (),        // output [31:0]
        .cfg_mgmt_byte_enable                  (),        // output [3:0]
        .cfg_mgmt_read                         (cfg_mgmt_read),        // output 
        .cfg_mgmt_read_data                    (cfg_mgmt_read_data),      // input  [31:0]
        .cfg_mgmt_read_write_done              (cfg_mgmt_read_write_done),      // input  
        .cfg_max_read_req                      (cfg_status_vif.max_read_request_size),      // input  [2:0]
        .cfg_max_payload                       (cfg_status_vif.max_payload_size),      // input  [2:0]
        .cfg_rcb_status                        ('0),      // input  [3:0]
        .cfg_fc_ph                             (fc_vif.tx_fc_ph_av),      // input  [7:0]
        .cfg_fc_pd                             (fc_vif.tx_fc_pd_av),      // input  [11:0]
        .cfg_fc_nph                            (fc_vif.tx_fc_nph_av),      // input  [7:0]
        .cfg_fc_npd                            (fc_vif.tx_fc_npd_av),      // input  [11:0]
        .cfg_fc_cplh                           ('0),      // input  [7:0]
        .cfg_fc_cpld                           ('0),      // input  [11:0]
        .cfg_fc_sel                            (),        // output [2:0]
        .cfg_interrupt_msix_enable             (msix_vif.enable),      // input  [3:0]
        .cfg_interrupt_msix_mask               (msix_vif.mask),      // input  [3:0]
        .cfg_interrupt_msix_vf_enable          ('0),      // input  [251:0]
        .cfg_interrupt_msix_vf_mask            ('0),      // input  [251:0]
        .cfg_interrupt_msix_address            (msix_vif.address),        // output [63:0]
        .cfg_interrupt_msix_data               (msix_vif.data),        // output [31:0]
        .cfg_interrupt_msix_int                (msix_vif.int_req),        // output 
        .cfg_interrupt_msix_vec_pending        (),        // output [1:0]
        .cfg_interrupt_msix_vec_pending_status ('0),      // input  
        .cfg_interrupt_msix_sent               (msix_vif.sent),      // input  
        .cfg_interrupt_msix_fail               (msix_vif.fail),      // input  
        .cfg_interrupt_msi_function_number     (msix_vif.function_number),        // output [7:0]
        .status_error_cor                      (),        // output 
        .status_error_uncor                    (),        // output 
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
        .ctrl_reg_wr_ack                       ('0),      // input  
        .ctrl_reg_rd_addr                      (),        // output [AXIL_CSR_ADDR_WIDTH-1:0]
        .ctrl_reg_rd_en                        (),        // output 
        .ctrl_reg_rd_data                      ('0),      // input  [AXIL_CTRL_DATA_WIDTH-1:0]
        .ctrl_reg_rd_wait                      ('0),      // input  
        .ctrl_reg_rd_ack                       ('0),      // input  
        .ptp_clk                               (ptp_clk),      // input  
        .ptp_rst                               (ptp_rst),      // input  
        .ptp_sample_clk                        (ptp_sample_clk),      // input  
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
        .eth_tx_clk                            (eth_clk),      // input  [PORT_COUNT-1:0]
        .eth_tx_rst                            (eth_rst),      // input  [PORT_COUNT-1:0]
        .eth_tx_ptp_clk                        (ptp_clk),      // input  [PORT_COUNT-1:0]
        .eth_tx_ptp_rst                        (ptp_rst),      // input  [PORT_COUNT-1:0]
        .eth_tx_ptp_ts_tod                     (eth_tx_ptp_ts_tod),        // output [PORT_COUNT*PTP_TS_WIDTH-1:0]
        .eth_tx_ptp_ts_tod_step                (),        // output [PORT_COUNT-1:0]
        .m_axis_eth_tx_tdata                   (eth_tx_tdata),        // output [PORT_COUNT*AXIS_ETH_DATA_WIDTH-1:0]
        .m_axis_eth_tx_tkeep                   (eth_tx_tkeep),        // output [PORT_COUNT*AXIS_ETH_KEEP_WIDTH-1:0]
        .m_axis_eth_tx_tvalid                  (eth_tx_tvalid),        // output [PORT_COUNT-1:0]
        .m_axis_eth_tx_tready                  (eth_tx_vif.tready),      // input  [PORT_COUNT-1:0]   // MAC sink agent
        .m_axis_eth_tx_tlast                   (eth_tx_tlast),        // output [PORT_COUNT-1:0]
        .m_axis_eth_tx_tuser                   (eth_tx_tuser),        // output [PORT_COUNT*AXIS_ETH_TX_USER_WIDTH-1:0]
        .s_axis_eth_tx_cpl_ts                  (eth_tx_cpl_ts),      // input  [PORT_COUNT*PTP_TS_WIDTH-1:0]
        .s_axis_eth_tx_cpl_tag                 (eth_tx_cpl_tag),      // input  [PORT_COUNT*TX_TAG_WIDTH-1:0]
        .s_axis_eth_tx_cpl_valid               (eth_tx_cpl_valid),      // input  [PORT_COUNT-1:0]
        .s_axis_eth_tx_cpl_ready               (eth_tx_cpl_ready),        // output [PORT_COUNT-1:0]
        .eth_tx_enable                         (),        // output [PORT_COUNT-1:0]
        .eth_tx_status                         (1'b1),      // input  [PORT_COUNT-1:0]
        .eth_tx_lfc_en                         (),        // output [PORT_COUNT-1:0]
        .eth_tx_lfc_req                        (),        // output [PORT_COUNT-1:0]
        .eth_tx_pfc_en                         (),        // output [PORT_COUNT*8-1:0]
        .eth_tx_pfc_req                        (),        // output [PORT_COUNT*8-1:0]
        .eth_tx_fc_quanta_clk_en               (1'b1),      // input  [PORT_COUNT-1:0]
        .eth_rx_clk                            (eth_clk),      // input  [PORT_COUNT-1:0]
        .eth_rx_rst                            (eth_rst),      // input  [PORT_COUNT-1:0]
        .eth_rx_ptp_clk                        (ptp_clk),      // input  [PORT_COUNT-1:0]
        .eth_rx_ptp_rst                        (ptp_rst),      // input  [PORT_COUNT-1:0]
        .eth_rx_ptp_ts_tod                     (),        // output [PORT_COUNT*PTP_TS_WIDTH-1:0]
        .eth_rx_ptp_ts_tod_step                (),        // output [PORT_COUNT-1:0]
        .s_axis_eth_rx_tdata                   (eth_rx_vif.tdata[ETH_DATA_WIDTH-1:0]),      // input  [PORT_COUNT*AXIS_ETH_DATA_WIDTH-1:0]
        .s_axis_eth_rx_tkeep                   (eth_rx_vif.tkeep[ETH_KEEP_WIDTH-1:0]),      // input  [PORT_COUNT*AXIS_ETH_KEEP_WIDTH-1:0]
        .s_axis_eth_rx_tvalid                  (eth_rx_vif.tvalid),      // input  [PORT_COUNT-1:0]
        .s_axis_eth_rx_tready                  (eth_rx_tready),        // output [PORT_COUNT-1:0]
        .s_axis_eth_rx_tlast                   (eth_rx_vif.tlast),      // input  [PORT_COUNT-1:0]
        .s_axis_eth_rx_tuser                   (eth_rx_vif.tuser[ETH_RX_USER_WIDTH-1:0]),      // input  [PORT_COUNT*AXIS_ETH_RX_USER_WIDTH-1:0]
        .eth_rx_enable                         (),        // output [PORT_COUNT-1:0]
        .eth_rx_status                         (1'b1),      // input  [PORT_COUNT-1:0]
        .eth_rx_lfc_en                         (),        // output [PORT_COUNT-1:0]
        .eth_rx_lfc_req                        ('0),      // input  [PORT_COUNT-1:0]
        .eth_rx_lfc_ack                        (),        // output [PORT_COUNT-1:0]
        .eth_rx_pfc_en                         (),        // output [PORT_COUNT*8-1:0]
        .eth_rx_pfc_req                        ('0),      // input  [PORT_COUNT*8-1:0]
        .eth_rx_pfc_ack                        (),        // output [PORT_COUNT*8-1:0]
        .eth_rx_fc_quanta_clk_en               (1'b1),      // input  [PORT_COUNT-1:0]
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

    initial begin
        uvm_config_db #(virtual mqnic_reset_if)::set(null, "uvm_test_top", "rst_vif", rst_if);
        uvm_config_db #(virtual pcie_us_axis_if)::set(null, "uvm_test_top.m_env.m_cq_axis*", "vif", cq_axis_vif);
        uvm_config_db #(virtual pcie_us_axis_if)::set(null, "uvm_test_top.m_env.m_cc_axis*", "vif", cc_axis_vif);
        uvm_config_db #(virtual pcie_us_axis_if)::set(null, "uvm_test_top.m_env.m_rc_axis*", "vif", rc_axis_vif);
        uvm_config_db #(virtual pcie_us_axis_if)::set(null, "uvm_test_top.m_env.m_rq_axis*", "vif", rq_axis_vif);
        uvm_config_db #(virtual pcie_us_cfg_status_if)::set(null, "uvm_test_top", "cfg_status_vif", cfg_status_vif);
        uvm_config_db #(virtual pcie_us_fc_if)::set(null, "uvm_test_top", "fc_vif", fc_vif);
        uvm_config_db #(virtual pcie_us_msix_if)::set(null, "uvm_test_top*", "msix_vif", msix_vif);
        uvm_config_db #(virtual axis_if)::set(null, "uvm_test_top.m_env.m_eth_tx*", "vif", eth_tx_vif);
        uvm_config_db #(virtual axis_if)::set(null, "uvm_test_top.m_env.m_eth_rx*", "vif", eth_rx_vif);
        run_test();
    end

endmodule : tb_top_tier6

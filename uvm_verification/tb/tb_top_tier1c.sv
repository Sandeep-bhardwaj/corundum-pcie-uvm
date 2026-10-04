// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tb_top_tier1c - Tier 1c testbench top (offload blocks)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §18 Step 3
// Introduced : Step 3
//
// rx_checksum and rx_hash are driven from ONE stimulus stream, mirroring
// mqnic_ingress.v where both are tapped off the same ingress path (:97, :166).
// Neither has a tready, so the same tvalid/tdata/tkeep/tlast feeds both.
//
// The result outputs are mapped onto axis_if instances so the existing
// axis_monitor can collect them - see tier1c_env.sv for why.
//
// DUTs: fpga/common/rtl/rx_checksum.v, rx_hash.v (both unmodified).
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_top_tier1c;

    import uvm_pkg::*;
`include "uvm_macros.svh"
    import mqnic_vrf_pkg::*;
    import mqnic_test_pkg::*;

    localparam int DATA_WIDTH   = 256;
    localparam int KEEP_WIDTH   = DATA_WIDTH / 8;
    localparam int START_OFFSET = 14;          // rx_checksum default

    // Interface maxima. Restated rather than referenced: `interface::PARAM` is
    // illegal SystemVerilog (:: is package/class scope resolution only) and VCS
    // rejects it with SV-LCM-PND. See tb_top_tier1a.sv for the full note.
    localparam int AXIS_MAX_DATA_WIDTH = 512;
    localparam int AXIS_MAX_USER_WIDTH = 128;

    localparam time CLK_HALF_PERIOD = 2ns;     // 250 MHz

    logic clk;
    initial clk = 1'b0;
    always #CLK_HALF_PERIOD clk = ~clk;

    mqnic_reset_if rst_if (.clk(clk));
    wire rst = rst_if.rst;

    // ---- interfaces ---------------------------------------------------------
    axis_if stim_vif (.clk(clk), .rst(rst));   // shared ingress stream
    axis_if csum_vif (.clk(clk), .rst(rst));   // rx_checksum result
    axis_if hash_vif (.clk(clk), .rst(rst));   // rx_hash result
    axis_if tx_in_vif  (.clk(clk), .rst(rst)); // tx_checksum input
    axis_if tx_out_vif (.clk(clk), .rst(rst)); // tx_checksum output
    csum_cmd_if tx_cmd_vif (.clk(clk), .rst(rst));

    // ---- RSS key ------------------------------------------------------------
    // Driven from a plain register so a test can rewrite it; the reference model
    // is given the same bytes through the environment.
    logic [40*8-1:0] hash_key;

    initial hash_key = mqnic_vrf_pkg::MQNIC_RSS_KEY_DEFAULT;

    // ---- DUT 1: rx_checksum -------------------------------------------------
    wire [15:0] csum_value;
    wire        csum_valid;

    rx_checksum #(
        .DATA_WIDTH   (DATA_WIDTH),
        .KEEP_WIDTH   (KEEP_WIDTH),
        .START_OFFSET (START_OFFSET)
    ) u_rx_checksum (
        .clk               (clk),
        .rst               (rst),
        .s_axis_tdata      (stim_vif.tdata[DATA_WIDTH-1:0]),
        .s_axis_tkeep      (stim_vif.tkeep[KEEP_WIDTH-1:0]),
        .s_axis_tvalid     (stim_vif.tvalid),
        .s_axis_tlast      (stim_vif.tlast),
        .m_axis_csum       (csum_value),
        .m_axis_csum_valid (csum_valid)
    );

    // ---- DUT 2: rx_hash -----------------------------------------------------
    wire [31:0] hash_value;
    wire [3:0]  hash_type;
    wire        hash_valid;

    rx_hash #(
        .DATA_WIDTH (DATA_WIDTH),
        .KEEP_WIDTH (KEEP_WIDTH)
    ) u_rx_hash (
        .clk               (clk),
        .rst               (rst),
        .s_axis_tdata      (stim_vif.tdata[DATA_WIDTH-1:0]),
        .s_axis_tkeep      (stim_vif.tkeep[KEEP_WIDTH-1:0]),
        .s_axis_tvalid     (stim_vif.tvalid),
        .s_axis_tlast      (stim_vif.tlast),
        .hash_key          (hash_key),
        .m_axis_hash       (hash_value),
        .m_axis_hash_type  (hash_type),
        .m_axis_hash_valid (hash_valid)
    );

    // ---- DUT 3: tx_checksum -------------------------------------------------
    // Unlike the two receive-side blocks this one MODIFIES the datapath: it sums
    // over [csum_start, end), complements, and writes the result at csum_offset.
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
        .clk (clk),
        .rst (rst),

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

    // ---- map the result outputs onto the result interfaces -----------------
    assign csum_vif.tdata[15:0] = csum_value;
    assign csum_vif.tvalid      = csum_valid;

    assign hash_vif.tdata[31:0] = hash_value;
    assign hash_vif.tuser[3:0]  = hash_type;   // was {28'd0, hash_type}[3:0]: xsim rejects a select on a concatenation
    assign hash_vif.tvalid      = hash_valid;

    // Undriven bits: hold defined so the monitors and $isunknown checks have
    // something real to look at. The result interfaces have no tready/tlast.
    initial begin
        csum_vif.tdata[AXIS_MAX_DATA_WIDTH-1:16] = '0;
        csum_vif.tkeep  = '1;
        csum_vif.tlast  = 1'b0;
        csum_vif.tready = 1'b1;
        csum_vif.tuser  = '0;
        csum_vif.tid    = '0;
        csum_vif.tdest  = '0;

        hash_vif.tdata[AXIS_MAX_DATA_WIDTH-1:32] = '0;
        hash_vif.tuser[AXIS_MAX_USER_WIDTH-1:4]  = '0;
        hash_vif.tkeep  = '1;
        hash_vif.tlast  = 1'b0;
        hash_vif.tready = 1'b1;
        hash_vif.tid    = '0;
        hash_vif.tdest  = '0;

        // Neither receive-side DUT drives the stimulus tready; hold it high so
        // the interface assertions and the monitor see a defined value.
        stim_vif.tready = 1'b1;

        tx_out_vif.tdata[AXIS_MAX_DATA_WIDTH-1:DATA_WIDTH] = '0;
        tx_out_vif.tkeep[63:KEEP_WIDTH]                    = '0;
        tx_out_vif.tuser[AXIS_MAX_USER_WIDTH-1:1]          = '0;

        // Drift guard, same pattern as tb_top_tier1a.
        if (AXIS_MAX_DATA_WIDTH !== stim_vif.MAX_DATA_WIDTH ||
            AXIS_MAX_USER_WIDTH !== stim_vif.MAX_USER_WIDTH)
            $fatal(1, "tb_top_tier1c: maxima out of step with axis_if.sv");
    end

    // ---- UVM ----------------------------------------------------------------
    initial begin
        uvm_config_db #(virtual mqnic_reset_if)::set(null, "uvm_test_top", "rst_vif", rst_if);
        uvm_config_db #(virtual axis_if)::set(null, "uvm_test_top.m_env.m_stim*", "vif", stim_vif);
        uvm_config_db #(virtual axis_if)::set(null, "uvm_test_top.m_env.m_csum*", "vif", csum_vif);
        uvm_config_db #(virtual axis_if)::set(null, "uvm_test_top.m_env.m_hash*", "vif", hash_vif);
        uvm_config_db #(virtual axis_if)::set(null, "uvm_test_top.m_env.m_tx_in*",  "vif", tx_in_vif);
        uvm_config_db #(virtual axis_if)::set(null, "uvm_test_top.m_env.m_tx_out*", "vif", tx_out_vif);
        uvm_config_db #(virtual csum_cmd_if)::set(null, "uvm_test_top.m_env.m_tx_cmd*", "vif", tx_cmd_vif);
        run_test();
    end

    initial begin
        if ($test$plusargs("WAVES")) begin
            $dumpfile("dump.vcd");
            $dumpvars(0, tb_top_tier1c);
        end
    end

endmodule : tb_top_tier1c

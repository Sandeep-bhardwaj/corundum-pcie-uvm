// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tb_top_tier1b - Tier 1b testbench top (TLP routing and buffering)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §18 Step 2
// Introduced : Step 2
//
// DUTs, both unmodified:
//   fpga/lib/pcie/rtl/pcie_tlp_demux_bar.v   BAR_BASE=0, BAR_STRIDE=2 - the
//       configuration mqnic_core_pcie actually instantiates (:730-732)
//   fpga/lib/pcie/rtl/pcie_tlp_mux.v         PORTS=2, round-robin - likewise
//       as mqnic_core_pcie instantiates it (:778-785)
//
// FIFO_ENABLE is 0 on the demux, so a demux failure cannot be confused with a
// FIFO failure.
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

module tb_top_tier1b;

    import uvm_pkg::*;
`include "uvm_macros.svh"
    import mqnic_vrf_pkg::*;
    import mqnic_env_pkg::*;
    import mqnic_test_pkg::*;

    localparam int TLP_DATA_WIDTH = 256;
    localparam int TLP_STRB_WIDTH = TLP_DATA_WIDTH / 32;
    localparam int TLP_HDR_WIDTH  = 128;
    localparam int SEQ_NUM_WIDTH  = 6;
    localparam int SEG_COUNT      = 1;
    localparam int DEMUX_PORTS    = 2;

    localparam time CLK_HALF_PERIOD = 2ns;

    logic clk;
    initial clk = 1'b0;
    always #CLK_HALF_PERIOD clk = ~clk;

    mqnic_reset_if rst_if (.clk(clk));
    wire rst = rst_if.rst;

    // ---- interfaces ---------------------------------------------------------
    pcie_tlp_if dmx_in_vif  (.clk(clk), .rst(rst));
    pcie_tlp_if dmx_out_vif [DEMUX_PORTS] (.clk(clk), .rst(rst));

    // ---- DUT 1: pcie_tlp_demux_bar -----------------------------------------
    wire [DEMUX_PORTS*TLP_DATA_WIDTH-1:0]            dmx_out_data;
    wire [DEMUX_PORTS*TLP_STRB_WIDTH-1:0]            dmx_out_strb;
    wire [DEMUX_PORTS*SEG_COUNT*TLP_HDR_WIDTH-1:0]   dmx_out_hdr;
    wire [DEMUX_PORTS*SEG_COUNT*SEQ_NUM_WIDTH-1:0]   dmx_out_seq;
    wire [DEMUX_PORTS*SEG_COUNT*3-1:0]               dmx_out_bar_id;
    wire [DEMUX_PORTS*SEG_COUNT*8-1:0]               dmx_out_func_num;
    wire [DEMUX_PORTS*SEG_COUNT*4-1:0]               dmx_out_error;
    wire [DEMUX_PORTS*SEG_COUNT-1:0]                 dmx_out_valid;
    wire [DEMUX_PORTS*SEG_COUNT-1:0]                 dmx_out_sop;
    wire [DEMUX_PORTS*SEG_COUNT-1:0]                 dmx_out_eop;
    wire [DEMUX_PORTS-1:0]                           dmx_out_ready;

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
        .clk              (clk),
        .rst              (rst),
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

    // Fan the packed demux outputs into the per-port interfaces.
    for (genvar p = 0; p < DEMUX_PORTS; p++) begin : g_dmx_out
        assign dmx_out_vif[p].tlp_data[TLP_DATA_WIDTH-1:0] =
                   dmx_out_data[p*TLP_DATA_WIDTH +: TLP_DATA_WIDTH];
        assign dmx_out_vif[p].tlp_strb[TLP_STRB_WIDTH-1:0] =
                   dmx_out_strb[p*TLP_STRB_WIDTH +: TLP_STRB_WIDTH];
        assign dmx_out_vif[p].tlp_hdr[TLP_HDR_WIDTH-1:0] =
                   dmx_out_hdr[p*SEG_COUNT*TLP_HDR_WIDTH +: TLP_HDR_WIDTH];
        assign dmx_out_vif[p].tlp_seq[SEQ_NUM_WIDTH-1:0] =
                   dmx_out_seq[p*SEG_COUNT*SEQ_NUM_WIDTH +: SEQ_NUM_WIDTH];
        assign dmx_out_vif[p].tlp_bar_id[2:0] =
                   dmx_out_bar_id[p*SEG_COUNT*3 +: 3];
        assign dmx_out_vif[p].tlp_func_num[7:0] =
                   dmx_out_func_num[p*SEG_COUNT*8 +: 8];
        assign dmx_out_vif[p].tlp_error[3:0] =
                   dmx_out_error[p*SEG_COUNT*4 +: 4];
        assign dmx_out_vif[p].tlp_valid[SEG_COUNT-1:0] =
                   dmx_out_valid[p*SEG_COUNT +: SEG_COUNT];
        assign dmx_out_vif[p].tlp_sop[SEG_COUNT-1:0] =
                   dmx_out_sop[p*SEG_COUNT +: SEG_COUNT];
        assign dmx_out_vif[p].tlp_eop[SEG_COUNT-1:0] =
                   dmx_out_eop[p*SEG_COUNT +: SEG_COUNT];
        assign dmx_out_ready[p] = dmx_out_vif[p].tlp_ready;

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

    // ---- DUT 2: pcie_tlp_mux -------------------------------------------------
    // Parameters exactly as mqnic_core_pcie.v:778-785 instantiates it: two
    // ports, ROUND-ROBIN, LSB high priority. (mqnic ties pause to 0; here it is
    // driven so the pause path is exercised too.)
    localparam int MUX_PORTS = 2;

    pcie_tlp_if mux_in_vif [MUX_PORTS] (.clk(clk), .rst(rst));
    pcie_tlp_if mux_out_vif (.clk(clk), .rst(rst));

    wire [MUX_PORTS*TLP_DATA_WIDTH-1:0]            mux_in_data;
    wire [MUX_PORTS*TLP_STRB_WIDTH-1:0]            mux_in_strb;
    wire [MUX_PORTS*SEG_COUNT*TLP_HDR_WIDTH-1:0]   mux_in_hdr;
    wire [MUX_PORTS*SEG_COUNT*SEQ_NUM_WIDTH-1:0]   mux_in_seq;
    wire [MUX_PORTS*SEG_COUNT*3-1:0]               mux_in_bar_id;
    wire [MUX_PORTS*SEG_COUNT*8-1:0]               mux_in_func_num;
    wire [MUX_PORTS*SEG_COUNT*4-1:0]               mux_in_error;
    wire [MUX_PORTS*SEG_COUNT-1:0]                 mux_in_valid;
    wire [MUX_PORTS*SEG_COUNT-1:0]                 mux_in_sop;
    wire [MUX_PORTS*SEG_COUNT-1:0]                 mux_in_eop;
    wire [MUX_PORTS-1:0]                           mux_in_ready;
    wire [MUX_PORTS*SEG_COUNT-1:0]                 mux_sel_valid;
    logic [MUX_PORTS-1:0]                          mux_pause = '0;

    for (genvar p = 0; p < MUX_PORTS; p++) begin : g_mux_in
        assign mux_in_data[p*TLP_DATA_WIDTH +: TLP_DATA_WIDTH]      = mux_in_vif[p].tlp_data[TLP_DATA_WIDTH-1:0];
        assign mux_in_strb[p*TLP_STRB_WIDTH +: TLP_STRB_WIDTH]      = mux_in_vif[p].tlp_strb[TLP_STRB_WIDTH-1:0];
        assign mux_in_hdr[p*TLP_HDR_WIDTH +: TLP_HDR_WIDTH]         = mux_in_vif[p].tlp_hdr[TLP_HDR_WIDTH-1:0];
        assign mux_in_seq[p*SEQ_NUM_WIDTH +: SEQ_NUM_WIDTH]         = mux_in_vif[p].tlp_seq[SEQ_NUM_WIDTH-1:0];
        assign mux_in_bar_id[p*3 +: 3]                              = mux_in_vif[p].tlp_bar_id[2:0];
        assign mux_in_func_num[p*8 +: 8]                            = mux_in_vif[p].tlp_func_num[7:0];
        assign mux_in_error[p*4 +: 4]                               = mux_in_vif[p].tlp_error[3:0];
        assign mux_in_valid[p]                                      = mux_in_vif[p].tlp_valid[0];
        assign mux_in_sop[p]                                        = mux_in_vif[p].tlp_sop[0];
        assign mux_in_eop[p]                                        = mux_in_vif[p].tlp_eop[0];
        assign mux_in_vif[p].tlp_ready                              = mux_in_ready[p];
        initial mux_in_vif[p].sop_eop_gated = 1'b1;   // pcie_tlp_driver gates them
    end

    pcie_tlp_mux #(
        .PORTS                 (MUX_PORTS),
        .TLP_DATA_WIDTH        (TLP_DATA_WIDTH),
        .TLP_STRB_WIDTH        (TLP_STRB_WIDTH),
        .TLP_HDR_WIDTH         (TLP_HDR_WIDTH),
        .SEQ_NUM_WIDTH         (SEQ_NUM_WIDTH),
        .TLP_SEG_COUNT         (SEG_COUNT),
        .ARB_TYPE_ROUND_ROBIN  (1),
        .ARB_LSB_HIGH_PRIORITY (1)
    ) u_mux (
        .clk               (clk),
        .rst               (rst),
        .in_tlp_data       (mux_in_data),
        .in_tlp_strb       (mux_in_strb),
        .in_tlp_hdr        (mux_in_hdr),
        .in_tlp_seq        (mux_in_seq),
        .in_tlp_bar_id     (mux_in_bar_id),
        .in_tlp_func_num   (mux_in_func_num),
        .in_tlp_error      (mux_in_error),
        .in_tlp_valid      (mux_in_valid),
        .in_tlp_sop        (mux_in_sop),
        .in_tlp_eop        (mux_in_eop),
        .in_tlp_ready      (mux_in_ready),
        .out_tlp_data      (mux_out_vif.tlp_data[TLP_DATA_WIDTH-1:0]),
        .out_tlp_strb      (mux_out_vif.tlp_strb[TLP_STRB_WIDTH-1:0]),
        .out_tlp_hdr       (mux_out_vif.tlp_hdr[TLP_HDR_WIDTH-1:0]),
        .out_tlp_seq       (mux_out_vif.tlp_seq[SEQ_NUM_WIDTH-1:0]),
        .out_tlp_bar_id    (mux_out_vif.tlp_bar_id[2:0]),
        .out_tlp_func_num  (mux_out_vif.tlp_func_num[7:0]),
        .out_tlp_error     (mux_out_vif.tlp_error[3:0]),
        .out_tlp_valid     (mux_out_vif.tlp_valid[SEG_COUNT-1:0]),
        .out_tlp_sop       (mux_out_vif.tlp_sop[SEG_COUNT-1:0]),
        .out_tlp_eop       (mux_out_vif.tlp_eop[SEG_COUNT-1:0]),
        .out_tlp_ready     (mux_out_vif.tlp_ready),
        .pause             (mux_pause),
        .sel_tlp_seq       (),
        .sel_tlp_seq_valid (mux_sel_valid)
    );

    // Tests set the pause bits through an object (see tier1b_env); they take
    // effect on the next clock edge.
    tlp_mux_pause_ctrl mux_pause_ctrl = new("mux_pause_ctrl");
    always @(posedge clk) mux_pause <= mux_pause_ctrl.pause;

    // PAUSE RULE, checked on the DUT's own selection output: sel_tlp_seq_valid[p]
    // is the registered "port p was just chosen for a new TLP" (pcie_tlp_mux.v:282,
    // :327, :388), and the choice is made from pause[p] in the cycle before
    // (:244). A paused port must never be chosen.
    for (genvar p = 0; p < MUX_PORTS; p++) begin : g_mux_sva
        a_mux_pause_respected : assert property (@(posedge clk) disable iff (rst)
            mux_sel_valid[p] |-> !$past(mux_pause[p]))
        else $error("pcie_tlp_mux selected port %0d while it was paused", p);
        c_mux_selected : cover property (@(posedge clk) disable iff (rst) mux_sel_valid[p]);
    end
    c_mux_both_waiting : cover property (@(posedge clk) disable iff (rst)
        &mux_in_valid && !(|mux_pause));

    // ---- hold undriven upper bits defined -----------------------------------
    initial begin
        // Driven by pcie_tlp_driver, which clears sop/eop with valid.
        // The Tier 1b routing DUTs downstream gate them as well, so the
        // stronger framing check is correct on this channel.
        dmx_in_vif.sop_eop_gated = 1'b1;
        // NOT gated: the mux assigns sop/eop from the selected source whether or
        // not that segment is valid (pcie_tlp_mux.v:349-350) and registers them
        // like data (:502, :512), so sop can sit high while valid is low.
        mux_out_vif.sop_eop_gated = 1'b0;

        mux_out_vif.tlp_data[511:TLP_DATA_WIDTH] = '0;
        mux_out_vif.tlp_strb[15:TLP_STRB_WIDTH]  = '0;
        mux_out_vif.tlp_hdr[511:TLP_HDR_WIDTH]   = '0;
        mux_out_vif.tlp_seq[23:SEQ_NUM_WIDTH]    = '0;
        mux_out_vif.tlp_bar_id[11:3]             = '0;
        mux_out_vif.tlp_func_num[31:8]           = '0;
        mux_out_vif.tlp_error[15:4]              = '0;
        mux_out_vif.tlp_valid[3:SEG_COUNT]       = '0;
        mux_out_vif.tlp_sop[3:SEG_COUNT]         = '0;
        mux_out_vif.tlp_eop[3:SEG_COUNT]         = '0;
    end

    // ---- UVM ----------------------------------------------------------------
    initial begin
        uvm_config_db #(virtual mqnic_reset_if)::set(null, "uvm_test_top", "rst_vif", rst_if);
        uvm_config_db #(virtual pcie_tlp_if)::set(null, "uvm_test_top.m_env.m_dmx_in*",   "vif", dmx_in_vif);
        uvm_config_db #(virtual pcie_tlp_if)::set(null, "uvm_test_top.m_env.m_dmx_out0*", "vif", dmx_out_vif[0]);
        uvm_config_db #(virtual pcie_tlp_if)::set(null, "uvm_test_top.m_env.m_dmx_out1*", "vif", dmx_out_vif[1]);
        uvm_config_db #(virtual pcie_tlp_if)::set(null, "uvm_test_top.m_env.m_mux_in0*", "vif", mux_in_vif[0]);
        uvm_config_db #(virtual pcie_tlp_if)::set(null, "uvm_test_top.m_env.m_mux_in1*", "vif", mux_in_vif[1]);
        uvm_config_db #(virtual pcie_tlp_if)::set(null, "uvm_test_top.m_env.m_mux_out*", "vif", mux_out_vif);
        uvm_config_db #(tlp_mux_pause_ctrl)::set(null, "uvm_test_top.m_env", "mux_pause", mux_pause_ctrl);
        run_test();
    end

    initial begin
        if ($test$plusargs("WAVES")) begin
            $dumpfile("dump.vcd");
            $dumpvars(0, tb_top_tier1b);
        end
    end

endmodule : tb_top_tier1b

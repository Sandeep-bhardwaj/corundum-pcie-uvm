// SPDX-License-Identifier: BSD-2-Clause-Views
//
// axil_if - AXI4-Lite signal interface
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.1 (axil_agent), §15.1 (interface SVA)
// Introduced : Step 1 (Tier 1a)
//
// DELIBERATELY NOT PARAMETERIZED. STRATEGY §4.3 rule 1 requires that agents and
// their virtual interfaces carry no parameters: a parameterized virtual
// interface produces a distinct type per parameterization, which makes
// uvm_config_db keys type-specific and blocks reuse across tiers.
//
// Instead the interface is declared at the maximum width the environment will
// ever need, and each DUT wrapper connects only the bits its DUT has. The
// actual widths in use are published to the agent through axil_cfg.
//
// Widths in this environment:
//   queue_manager      AXIL_ADDR_WIDTH = QUEUE_INDEX_WIDTH+5 (18), DATA = 32
//   mqnic_core_pcie    AXIL_CSR_ADDR_WIDTH,                        DATA = 32
// Both fit comfortably inside the maxima below.
// -----------------------------------------------------------------------------

`ifndef AXIL_IF_SV
`define AXIL_IF_SV

`timescale 1ns / 1ps

interface axil_if (input logic clk, input logic rst);

    localparam int MAX_ADDR_WIDTH = 64;
    localparam int MAX_DATA_WIDTH = 64;
    localparam int MAX_STRB_WIDTH = MAX_DATA_WIDTH / 8;

    // ---- write address channel ---------------------------------------------
    logic [MAX_ADDR_WIDTH-1:0] awaddr;
    logic [2:0]                awprot;
    logic                      awvalid;
    logic                      awready;

    // ---- write data channel ------------------------------------------------
    logic [MAX_DATA_WIDTH-1:0] wdata;
    logic [MAX_STRB_WIDTH-1:0] wstrb;
    logic                      wvalid;
    logic                      wready;

    // ---- write response channel --------------------------------------------
    logic [1:0]                bresp;
    logic                      bvalid;
    logic                      bready;

    // ---- read address channel ----------------------------------------------
    logic [MAX_ADDR_WIDTH-1:0] araddr;
    logic [2:0]                arprot;
    logic                      arvalid;
    logic                      arready;

    // ---- read data channel -------------------------------------------------
    logic [MAX_DATA_WIDTH-1:0] rdata;
    logic [1:0]                rresp;
    logic                      rvalid;
    logic                      rready;

    // -------------------------------------------------------------------------
    // Clocking blocks. Drivers and monitors sample and drive through these so
    // there is exactly one place where timing is defined.
    // -------------------------------------------------------------------------

    clocking master_cb @(posedge clk);
        default input #1step output #1ns;
        output awaddr, awprot, awvalid;
        input  awready;
        output wdata, wstrb, wvalid;
        input  wready;
        input  bresp, bvalid;
        output bready;
        output araddr, arprot, arvalid;
        input  arready;
        input  rdata, rresp, rvalid;
        output rready;
    endclocking

    clocking slave_cb @(posedge clk);
        default input #1step output #1ns;
        input  awaddr, awprot, awvalid;
        output awready;
        input  wdata, wstrb, wvalid;
        output wready;
        output bresp, bvalid;
        input  bready;
        input  araddr, arprot, arvalid;
        output arready;
        output rdata, rresp, rvalid;
        input  rready;
    endclocking

    clocking mon_cb @(posedge clk);
        default input #1step;
        input awaddr, awprot, awvalid, awready;
        input wdata, wstrb, wvalid, wready;
        input bresp, bvalid, bready;
        input araddr, arprot, arvalid, arready;
        input rdata, rresp, rvalid, rready;
    endclocking

    modport master (clocking master_cb, input clk, input rst);
    modport slave  (clocking slave_cb,  input clk, input rst);
    modport mon    (clocking mon_cb,    input clk, input rst);

    // -------------------------------------------------------------------------
    // Protocol assertions. STRATEGY §15.1 - interface-protocol properties live
    // in the UVC interface; design-intent properties live in sva/ and are bound.
    //
    // AXI requires that once VALID is asserted it stays asserted, with payload
    // held stable, until the corresponding READY. Violating this is the single
    // most common driver bug and it is cheap to catch here.
    // -------------------------------------------------------------------------

`ifndef AXIL_IF_NO_SVA
`ifndef MQNIC_NO_SVA

    // synopsys translate_off
    default clocking mon_cb;
    // `default disable iff (rst)` is written out on each assertion below:
    // Vivado xsim cannot simulate the default form (XSIM 43-3980), and the
    // explicit form is identical in meaning (IEEE 1800-2017 16.15).

    property p_valid_stable(valid, ready);
        valid && !ready |=> valid;
    endproperty

    property p_payload_stable(valid, ready, sig);
        valid && !ready |=> $stable(sig);
    endproperty

    a_awvalid_stable : assert property (disable iff (rst) p_valid_stable(awvalid, awready))
        else $error("AXIL: awvalid deasserted before awready");
    a_awaddr_stable  : assert property (disable iff (rst) p_payload_stable(awvalid, awready, awaddr))
        else $error("AXIL: awaddr changed while awvalid && !awready");

    a_wvalid_stable  : assert property (disable iff (rst) p_valid_stable(wvalid, wready))
        else $error("AXIL: wvalid deasserted before wready");
    a_wdata_stable   : assert property (disable iff (rst) p_payload_stable(wvalid, wready, wdata))
        else $error("AXIL: wdata changed while wvalid && !wready");
    a_wstrb_stable   : assert property (disable iff (rst) p_payload_stable(wvalid, wready, wstrb))
        else $error("AXIL: wstrb changed while wvalid && !wready");

    a_arvalid_stable : assert property (disable iff (rst) p_valid_stable(arvalid, arready))
        else $error("AXIL: arvalid deasserted before arready");
    a_araddr_stable  : assert property (disable iff (rst) p_payload_stable(arvalid, arready, araddr))
        else $error("AXIL: araddr changed while arvalid && !arready");

    a_bvalid_stable  : assert property (disable iff (rst) p_valid_stable(bvalid, bready))
        else $error("AXIL: bvalid deasserted before bready");
    a_bresp_stable   : assert property (disable iff (rst) p_payload_stable(bvalid, bready, bresp))
        else $error("AXIL: bresp changed while bvalid && !bready");

    a_rvalid_stable  : assert property (disable iff (rst) p_valid_stable(rvalid, rready))
        else $error("AXIL: rvalid deasserted before rready");
    a_rdata_stable   : assert property (disable iff (rst) p_payload_stable(rvalid, rready, rdata))
        else $error("AXIL: rdata changed while rvalid && !rready");

    // No unknown bits on a qualified handshake.
    a_aw_known : assert property (disable iff (rst) awvalid && awready |-> !$isunknown(awaddr))
        else $error("AXIL: X/Z on awaddr at handshake");
    a_w_known  : assert property (disable iff (rst) wvalid && wready |-> !$isunknown({wdata, wstrb}))
        else $error("AXIL: X/Z on wdata/wstrb at handshake");
    a_ar_known : assert property (disable iff (rst) arvalid && arready |-> !$isunknown(araddr))
        else $error("AXIL: X/Z on araddr at handshake");
    // synopsys translate_on

`endif // MQNIC_NO_SVA
`endif // AXIL_IF_NO_SVA

endinterface : axil_if

`endif // AXIL_IF_SV

// SPDX-License-Identifier: BSD-2-Clause-Views
//
// dma_ram_if - segmented DMA RAM interface
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.4 (dma_ram_agent), §15.1
// Introduced : Step 4 (Tier 2); reused at Tiers 3 and 5 (§5.1)
//
// THIS INTERFACE IS NOT AXI-SHAPED, and that is the whole reason Tier 2 exists.
// Every SEGMENT is an INDEPENDENT valid/ready channel: on any given cycle an
// arbitrary subset of segments may be active, and each has its own ready.
// A UVC written around a single handshake models this incorrectly, which is why
// STRATEGY §5.1 builds it here on dma_psdpram - a DUT with no state worth
// speaking of - rather than discovering the problem inside dma_if_pcie.
//
// Signal set verified against fpga/lib/pcie/rtl/dma_psdpram.v:50-71 and the
// ram_* ports of dma_client_axis_sink.v.
//
// wr_done IS A PULSE WITH NO READY, exactly like the queue_manager doorbell
// (STRATEGY §7.8). It must be sampled on every cycle it is asserted; a monitor
// waiting for a handshake observes nothing. There is deliberately no stability
// assertion on it below.
//
// sel is present only on the muxed variants (dma_ram_demux, dma_if_mux); the
// plain dma_psdpram has none. cfg.has_sel says whether it is connected.
//
// Not parameterized (STRATEGY §4.3 rule 1). Maxima cover Tier 3's double-width
// segmented interface at 512-bit TLP data.
// -----------------------------------------------------------------------------

`ifndef DMA_RAM_IF_SV
`define DMA_RAM_IF_SV

`timescale 1ns / 1ps

interface dma_ram_if (input logic clk, input logic rst);

    // Maxima come from mqnic_vrf_pkg so the class-based UVC can read the same
    // values - a class cannot address an interface localparam. See the note in
    // the package.
    import mqnic_vrf_pkg::DMA_RAM_MAX_SEG_COUNT;
    import mqnic_vrf_pkg::DMA_RAM_MAX_SEG_DATA_WIDTH;
    import mqnic_vrf_pkg::DMA_RAM_MAX_SEG_BE_WIDTH;
    import mqnic_vrf_pkg::DMA_RAM_MAX_SEG_ADDR_WIDTH;
    import mqnic_vrf_pkg::DMA_RAM_MAX_SEL_WIDTH;

    localparam int MAX_SEG_COUNT      = DMA_RAM_MAX_SEG_COUNT;
    localparam int MAX_SEG_DATA_WIDTH = DMA_RAM_MAX_SEG_DATA_WIDTH;
    localparam int MAX_SEG_BE_WIDTH   = DMA_RAM_MAX_SEG_BE_WIDTH;
    localparam int MAX_SEG_ADDR_WIDTH = DMA_RAM_MAX_SEG_ADDR_WIDTH;
    localparam int MAX_SEL_WIDTH      = DMA_RAM_MAX_SEL_WIDTH;

    // ---- write command (initiator -> RAM) -----------------------------------
    logic [MAX_SEG_COUNT*MAX_SEL_WIDTH-1:0]      wr_cmd_sel;
    logic [MAX_SEG_COUNT*MAX_SEG_BE_WIDTH-1:0]   wr_cmd_be;
    logic [MAX_SEG_COUNT*MAX_SEG_ADDR_WIDTH-1:0] wr_cmd_addr;
    logic [MAX_SEG_COUNT*MAX_SEG_DATA_WIDTH-1:0] wr_cmd_data;
    logic [MAX_SEG_COUNT-1:0]                    wr_cmd_valid;
    logic [MAX_SEG_COUNT-1:0]                    wr_cmd_ready;
    logic [MAX_SEG_COUNT-1:0]                    wr_done;      // PULSE, no ready

    // ---- read command (initiator -> RAM) ------------------------------------
    logic [MAX_SEG_COUNT*MAX_SEL_WIDTH-1:0]      rd_cmd_sel;
    logic [MAX_SEG_COUNT*MAX_SEG_ADDR_WIDTH-1:0] rd_cmd_addr;
    logic [MAX_SEG_COUNT-1:0]                    rd_cmd_valid;
    logic [MAX_SEG_COUNT-1:0]                    rd_cmd_ready;

    // ---- read response (RAM -> initiator) -----------------------------------
    logic [MAX_SEG_COUNT*MAX_SEG_DATA_WIDTH-1:0] rd_resp_data;
    logic [MAX_SEG_COUNT-1:0]                    rd_resp_valid;
    logic [MAX_SEG_COUNT-1:0]                    rd_resp_ready;

    // -------------------------------------------------------------------------
    // init_idle - give every signal this side drives a defined value.
    //
    // Added as a task because Tier 1 lost a simulation to exactly this: on a top
    // that instantiates more DUTs than one test exercises, an interface with no
    // agent sits at X, and an unconditional assertion on X FAILS rather than
    // going vacuous. Calling init_idle() from the top at time 0 makes that
    // systematic instead of a checklist item. STRATEGY bring-up log, VCS bug 5.
    // -------------------------------------------------------------------------
    task automatic init_idle_initiator();
        wr_cmd_sel    = '0;
        wr_cmd_be     = '0;
        wr_cmd_addr   = '0;
        wr_cmd_data   = '0;
        wr_cmd_valid  = '0;
        rd_cmd_sel    = '0;
        rd_cmd_addr   = '0;
        rd_cmd_valid  = '0;
        rd_resp_ready = '0;
    endtask

    task automatic init_idle_responder();
        wr_cmd_ready  = '0;
        wr_done       = '0;
        rd_cmd_ready  = '0;
        rd_resp_data  = '0;
        rd_resp_valid = '0;
    endtask

    // -------------------------------------------------------------------------
    clocking init_cb @(posedge clk);
        default input #1step output #1ns;
        output wr_cmd_sel, wr_cmd_be, wr_cmd_addr, wr_cmd_data, wr_cmd_valid;
        input  wr_cmd_ready, wr_done;
        output rd_cmd_sel, rd_cmd_addr, rd_cmd_valid;
        input  rd_cmd_ready;
        input  rd_resp_data, rd_resp_valid;
        output rd_resp_ready;
    endclocking

    clocking resp_cb @(posedge clk);
        default input #1step output #1ns;
        input  wr_cmd_sel, wr_cmd_be, wr_cmd_addr, wr_cmd_data, wr_cmd_valid;
        output wr_cmd_ready, wr_done;
        input  rd_cmd_sel, rd_cmd_addr, rd_cmd_valid;
        output rd_cmd_ready;
        output rd_resp_data, rd_resp_valid;
        input  rd_resp_ready;
    endclocking

    clocking mon_cb @(posedge clk);
        default input #1step;
        input wr_cmd_sel, wr_cmd_be, wr_cmd_addr, wr_cmd_data, wr_cmd_valid;
        input wr_cmd_ready, wr_done;
        input rd_cmd_sel, rd_cmd_addr, rd_cmd_valid, rd_cmd_ready;
        input rd_resp_data, rd_resp_valid, rd_resp_ready;
    endclocking

    modport init (clocking init_cb, input clk, input rst);
    modport resp (clocking resp_cb, input clk, input rst);
    modport mon  (clocking mon_cb,  input clk, input rst);

    // -------------------------------------------------------------------------
    // Protocol assertions, PER SEGMENT.
    //
    // All are implications keyed on that segment's valid, so an interface with
    // no driver goes vacuous instead of failing on X - the Tier 1 lesson applied
    // at the point where it is cheapest to get right.
    // -------------------------------------------------------------------------

`ifndef DMA_RAM_IF_NO_SVA
`ifndef MQNIC_NO_SVA
    // synopsys translate_off
    default clocking mon_cb;
    // `default disable iff (rst)` is written out on each assertion below:
    // Vivado xsim cannot simulate the default form (XSIM 43-3980), and the
    // explicit form is identical in meaning (IEEE 1800-2017 16.15).

    genvar gs;
    for (gs = 0; gs < MAX_SEG_COUNT; gs++) begin : g_seg_sva

        a_wr_valid_stable : assert property (disable iff (rst)
            wr_cmd_valid[gs] && !wr_cmd_ready[gs] |=> wr_cmd_valid[gs]
        ) else $error("DMA_RAM seg %0d: wr_cmd_valid dropped before ready", gs);

        a_wr_addr_stable : assert property (disable iff (rst)
            wr_cmd_valid[gs] && !wr_cmd_ready[gs] |=>
                $stable(wr_cmd_addr[gs*MAX_SEG_ADDR_WIDTH +: MAX_SEG_ADDR_WIDTH])
        ) else $error("DMA_RAM seg %0d: wr_cmd_addr changed while stalled", gs);

        a_wr_data_stable : assert property (disable iff (rst)
            wr_cmd_valid[gs] && !wr_cmd_ready[gs] |=>
                $stable(wr_cmd_data[gs*MAX_SEG_DATA_WIDTH +: MAX_SEG_DATA_WIDTH])
        ) else $error("DMA_RAM seg %0d: wr_cmd_data changed while stalled", gs);

        a_rd_valid_stable : assert property (disable iff (rst)
            rd_cmd_valid[gs] && !rd_cmd_ready[gs] |=> rd_cmd_valid[gs]
        ) else $error("DMA_RAM seg %0d: rd_cmd_valid dropped before ready", gs);

        a_rd_addr_stable : assert property (disable iff (rst)
            rd_cmd_valid[gs] && !rd_cmd_ready[gs] |=>
                $stable(rd_cmd_addr[gs*MAX_SEG_ADDR_WIDTH +: MAX_SEG_ADDR_WIDTH])
        ) else $error("DMA_RAM seg %0d: rd_cmd_addr changed while stalled", gs);

        a_rd_resp_stable : assert property (disable iff (rst)
            rd_resp_valid[gs] && !rd_resp_ready[gs] |=> rd_resp_valid[gs]
        ) else $error("DMA_RAM seg %0d: rd_resp_valid dropped before ready", gs);

        a_rd_resp_data_stable : assert property (disable iff (rst)
            rd_resp_valid[gs] && !rd_resp_ready[gs] |=>
                $stable(rd_resp_data[gs*MAX_SEG_DATA_WIDTH +: MAX_SEG_DATA_WIDTH])
        ) else $error("DMA_RAM seg %0d: rd_resp_data changed while stalled", gs);

        a_wr_known : assert property (disable iff (rst)
            wr_cmd_valid[gs] && wr_cmd_ready[gs] |->
                !$isunknown(wr_cmd_addr[gs*MAX_SEG_ADDR_WIDTH +: MAX_SEG_ADDR_WIDTH])
        ) else $error("DMA_RAM seg %0d: X on wr_cmd_addr at handshake", gs);

        // Deliberately NO assertion on wr_done: it is a single-cycle pulse with
        // no ready, so stability and handshake properties do not apply.

    end
    // synopsys translate_on
`endif // MQNIC_NO_SVA
`endif // DMA_RAM_IF_NO_SVA

endinterface : dma_ram_if

`endif // DMA_RAM_IF_SV

// SPDX-License-Identifier: BSD-2-Clause-Views
//
// pcie_tlp_if - generic (FPGA-independent) PCIe TLP interface
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.2 (pcie_tlp_agent), §15.1
// Introduced : Step 2 (Tier 1b); reused at Tiers 3, 4, 5 (§5.1)
//
// THE HIGHEST-VALUE UVC IN THE PLAN. §5.1 reuses this at Tier 3 (dma_if_pcie),
// Tier 4 (pcie_us_if equivalence) and Tier 5 (mqnic_core_pcie). Building it here
// on stateless routing DUTs - demux, mux, fifo - is the whole point of §2.1:
// segmented TLP packing gets debugged where a failure has one plausible cause,
// not inside the DMA engine.
//
// Signal set verified against fpga/lib/pcie/rtl/pcie_tlp_demux_bar.v and
// pcie_tlp_fifo.v; the two agree exactly.
//
// Not parameterized (STRATEGY §4.3 rule 1). Declared at the maxima this
// environment needs: 512-bit data, 4 segments. mqnic_core_pcie uses
// TLP_SEG_COUNT = 1 (mqnic_core_pcie_us.v:562), so single-segment is the
// configuration every tier below Tier 4 actually runs; the multi-segment
// plumbing exists for the straddling work at Tier 4.
// -----------------------------------------------------------------------------

`ifndef PCIE_TLP_IF_SV
`define PCIE_TLP_IF_SV

`timescale 1ns / 1ps

interface pcie_tlp_if (input logic clk, input logic rst);

    localparam int MAX_DATA_WIDTH = 512;
    localparam int MAX_STRB_WIDTH = MAX_DATA_WIDTH / 32;   // strobe is per DWORD
    localparam int MAX_SEG_COUNT  = 4;
    localparam int HDR_WIDTH      = 128;
    localparam int MAX_SEQ_WIDTH  = 6;

    logic [MAX_DATA_WIDTH-1:0]              tlp_data;
    logic [MAX_STRB_WIDTH-1:0]              tlp_strb;
    logic [MAX_SEG_COUNT*HDR_WIDTH-1:0]     tlp_hdr;
    logic [MAX_SEG_COUNT*MAX_SEQ_WIDTH-1:0] tlp_seq;
    logic [MAX_SEG_COUNT*3-1:0]             tlp_bar_id;
    logic [MAX_SEG_COUNT*8-1:0]             tlp_func_num;
    logic [MAX_SEG_COUNT*4-1:0]             tlp_error;
    logic [MAX_SEG_COUNT-1:0]               tlp_valid;
    logic [MAX_SEG_COUNT-1:0]               tlp_sop;
    logic [MAX_SEG_COUNT-1:0]               tlp_eop;
    logic                                   tlp_ready;

    // -------------------------------------------------------------------------
    // Does the producer on this instance GATE sop/eop with valid?
    //
    // The protocol says sop and eop are MEANINGLESS when valid is low - it does
    // not say they must be low. Both readings are common in this codebase:
    //
    //   * pcie_tlp_demux/mux/fifo (Tier 1b) gate them. There a stray sop really
    //     is a bug, and a_sop_implies_valid below is a genuine check.
    //   * dma_if_pcie_rd ties BOTH to constant 1'b1 (dma_if_pcie_rd.v:484-485).
    //     Its request channel is single-segment and header-only, so every beat
    //     is trivially a whole packet and valid alone qualifies it.
    //   * dma_if_pcie_wr LATCHES them: valid clears on the handshake but sop
    //     and eop hold their last value (dma_if_pcie_wr.v:839-841), so sop
    //     reads high between packets. Different mechanism, same consequence.
    //
    //   * pcie_us_if_{rc,cq} (Tier 4) do not gate either - their output stage
    //     is pcie_tlp_fifo_raw, which latches sop/eop and clears only valid
    //     (pcie_tlp_fifo_raw.v:546-547, 587-588).
    //
    // All are legitimate idioms, not violations. THERE IS NO RELIABLE RULE OF
    // THUMB: an earlier version of this note claimed routing blocks gate and
    // DMA engines do not, and Tier 4 disproved it. The real predictor is
    // whether the producer's output stage is pcie_tlp_fifo_raw - which is not
    // something to infer from a block's role. slang_check rule 4 therefore
    // requires every instance to state its answer explicitly; guessing has now
    // cost three simulation rounds.
    //
    // Defaulting this to 1 keeps the stronger check wherever it is true, and the
    // top clears it per instance for producers of the second kind. Making the
    // assertion unconditional - as the first version did - reported the DUT for
    // conforming to the protocol.
    // -------------------------------------------------------------------------
    bit sop_eop_gated = 1'b1;

    clocking src_cb @(posedge clk);
        default input #1step output #1ns;
        output tlp_data, tlp_strb, tlp_hdr, tlp_seq, tlp_bar_id, tlp_func_num;
        output tlp_error, tlp_valid, tlp_sop, tlp_eop;
        input  tlp_ready;
    endclocking

    clocking sink_cb @(posedge clk);
        default input #1step output #1ns;
        input  tlp_data, tlp_strb, tlp_hdr, tlp_seq, tlp_bar_id, tlp_func_num;
        input  tlp_error, tlp_valid, tlp_sop, tlp_eop;
        output tlp_ready;
    endclocking

    clocking mon_cb @(posedge clk);
        default input #1step;
        input tlp_data, tlp_strb, tlp_hdr, tlp_seq, tlp_bar_id, tlp_func_num;
        input tlp_error, tlp_valid, tlp_sop, tlp_eop, tlp_ready;
    endclocking

    modport src  (clocking src_cb,  input clk, input rst);
    modport sink (clocking sink_cb, input clk, input rst);
    modport mon  (clocking mon_cb,  input clk, input rst);

    // -------------------------------------------------------------------------
    // Protocol assertions (STRATEGY §15.1). Framing legality is the point: a
    // dropped sop or a doubled eop corrupts every packet downstream, and on a
    // segmented bus it is invisible in a waveform until you count segments.
    // -------------------------------------------------------------------------

`ifndef PCIE_TLP_IF_NO_SVA
`ifndef MQNIC_NO_SVA
    // synopsys translate_off
    default clocking mon_cb;
    // `default disable iff (rst)` is written out on each assertion below:
    // Vivado xsim cannot simulate the default form (XSIM 43-3980), and the
    // explicit form is identical in meaning (IEEE 1800-2017 16.15).

    a_valid_stable : assert property (disable iff (rst)
        |tlp_valid && !tlp_ready |=> $stable(tlp_valid)
    ) else $error("TLP: tlp_valid changed while stalled");

    a_data_stable : assert property (disable iff (rst)
        |tlp_valid && !tlp_ready |=> $stable(tlp_data)
    ) else $error("TLP: tlp_data changed while stalled");

    a_hdr_stable : assert property (disable iff (rst)
        |tlp_valid && !tlp_ready |=> $stable(tlp_hdr)
    ) else $error("TLP: tlp_hdr changed while stalled");

    a_sop_eop_stable : assert property (disable iff (rst)
        |tlp_valid && !tlp_ready |=> $stable(tlp_sop) && $stable(tlp_eop)
    ) else $error("TLP: sop/eop changed while stalled");

    // sop and eop only mean anything on a valid segment. Checked only where the
    // producer gates them - see sop_eop_gated above.
    a_sop_implies_valid : assert property (disable iff (rst)
        sop_eop_gated |-> (tlp_sop & ~tlp_valid) == '0
    ) else $error("TLP: sop asserted on an invalid segment");

    a_eop_implies_valid : assert property (disable iff (rst)
        sop_eop_gated |-> (tlp_eop & ~tlp_valid) == '0
    ) else $error("TLP: eop asserted on an invalid segment");

    // Deliberately NO "a valid segment must carry framing" property. A
    // multi-beat TLP has interior beats with valid asserted and neither sop nor
    // eop - that is the normal shape of a packet longer than one beat, so such
    // an assertion would fail on every payload-carrying TLP at Tier 1b.

    a_known_on_fire : assert property (disable iff (rst)
        |tlp_valid && tlp_ready |-> !$isunknown({tlp_valid, tlp_sop, tlp_eop})
    ) else $error("TLP: X/Z on framing at handshake");
    // synopsys translate_on
`endif // MQNIC_NO_SVA
`endif // PCIE_TLP_IF_NO_SVA

endinterface : pcie_tlp_if

`endif // PCIE_TLP_IF_SV

// SPDX-License-Identifier: BSD-2-Clause-Views
//
// pcie_us_axis_if - Xilinx UltraScale+ PCIe AXI-Stream (RQ/RC/CQ/CC)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.6, §15.1, §22 R2
// Introduced : Step 6 (Tier 4); reused at Tier 6
//
// ONE INTERFACE FOR ALL FOUR CHANNELS. The wires are identical - tdata, tkeep,
// tvalid, tready, tlast, tuser - and only the tuser LAYOUT differs. Four
// near-identical interfaces would mean four copies of the same assertions and
// four places for them to drift apart; the layout difference belongs in the
// codec (mqnic_vrf_pkg) and the direction in cfg, not in the wire declarations.
//
// tuser IS DECLARED AT THE MAXIMUM (183 bits, CQ at 512). Per §4.3 rule 1 the
// interface is not parameterized; cfg.user_width says how much of it is live.
// Driving bits above the live width is harmless - the DUT does not see them -
// but CHECKING them is not, so the monitor consults cfg.
//
// DIRECTION IS PER CHANNEL AND IS NOT NEGOTIABLE:
//   RC, CQ  host -> DUT   the TB is the source     (s_axis_*)
//   RQ, CC  DUT -> host   the TB is the sink       (m_axis_*)
// Getting this backwards is not a subtle bug - nothing moves at all - but it is
// worth stating because the channel names do not say which way they point.
//
// STRADDLING. At the golden 256-bit width ONLY RC straddles
// (mqnic_core_pcie_us.v:163-166). Two TLPs may share a beat, and a TLP may
// begin only on a 128-bit boundary - lane 0 or 4 at 256-bit, 0/4/8/12 at
// 512-bit. That quantisation is a constraint on the DRIVER, not a decode
// detail; see the codec header in mqnic_vrf_pkg.
// -----------------------------------------------------------------------------

`ifndef PCIE_US_AXIS_IF_SV
`define PCIE_US_AXIS_IF_SV

`timescale 1ns / 1ps

interface pcie_us_axis_if (input logic clk, input logic rst);

    import mqnic_vrf_pkg::US_MAX_DATA_WIDTH;
    import mqnic_vrf_pkg::US_MAX_KEEP_WIDTH;
    import mqnic_vrf_pkg::US_MAX_USER_WIDTH;

    logic [US_MAX_DATA_WIDTH-1:0] tdata;
    logic [US_MAX_KEEP_WIDTH-1:0] tkeep;
    logic                         tvalid;
    logic                         tready;
    logic                         tlast;
    logic [US_MAX_USER_WIDTH-1:0] tuser;

    // -------------------------------------------------------------------------
    // Does this channel straddle? Set by the top from
    // mqnic_vrf_pkg::us_straddles(), which reads the RTL's own rule.
    //
    // Explicit per instance for the same reason pcie_tlp_if.sop_eop_gated is:
    // a default that is right three times in four presents its fourth case as a
    // DUT bug. slang_check rule 5 requires it to be stated.
    // -------------------------------------------------------------------------
    bit straddling = 1'b0;

    task automatic init_idle_source();
        tdata  = '0;
        tkeep  = '0;
        tvalid = 1'b0;
        tlast  = 1'b0;
        tuser  = '0;
    endtask

    task automatic init_idle_sink();
        tready = 1'b0;
    endtask

    clocking src_cb @(posedge clk);
        default input #1step output #1ns;
        output tdata, tkeep, tvalid, tlast, tuser;
        input  tready;
    endclocking

    clocking sink_cb @(posedge clk);
        default input #1step output #1ns;
        input  tdata, tkeep, tvalid, tlast, tuser;
        output tready;
    endclocking

    clocking mon_cb @(posedge clk);
        default input #1step;
        input tdata, tkeep, tvalid, tready, tlast, tuser;
    endclocking

    modport src  (clocking src_cb,  input clk, input rst);
    modport sink (clocking sink_cb, input clk, input rst);
    modport mon  (clocking mon_cb,  input clk, input rst);

    // -------------------------------------------------------------------------
    // AXI-Stream protocol assertions (§15.1).
    //
    // These are the ORDINARY AXI-S rules and they hold on all four channels
    // regardless of tuser layout or straddling - which is the argument for one
    // interface rather than four.
    // -------------------------------------------------------------------------

`ifndef PCIE_US_AXIS_IF_NO_SVA
`ifndef MQNIC_NO_SVA
    // synopsys translate_off
    default clocking mon_cb;
    // `default disable iff (rst)` is written out on each assertion below:
    // Vivado xsim cannot simulate the default form (XSIM 43-3980), and the
    // explicit form is identical in meaning (IEEE 1800-2017 16.15).

    a_valid_stable : assert property (disable iff (rst)
        tvalid && !tready |=> tvalid
    ) else $error("US_AXIS: tvalid dropped before tready");

    a_data_stable : assert property (disable iff (rst)
        tvalid && !tready |=> $stable(tdata)
    ) else $error("US_AXIS: tdata changed while stalled");

    a_keep_stable : assert property (disable iff (rst)
        tvalid && !tready |=> $stable(tkeep)
    ) else $error("US_AXIS: tkeep changed while stalled");

    a_last_stable : assert property (disable iff (rst)
        tvalid && !tready |=> $stable(tlast)
    ) else $error("US_AXIS: tlast changed while stalled");

    a_user_stable : assert property (disable iff (rst)
        tvalid && !tready |=> $stable(tuser)
    ) else $error("US_AXIS: tuser changed while stalled");

    a_known_on_fire : assert property (disable iff (rst)
        tvalid && tready |-> !$isunknown({tvalid, tlast, tkeep})
    ) else $error("US_AXIS: X/Z on framing at handshake");

    // tkeep must not be empty on an accepted beat: a beat carrying no lanes is
    // a beat that moves nothing, and downstream will still count it as data.
    a_keep_nonzero : assert property (disable iff (rst)
        tvalid && tready |-> tkeep != '0
    ) else $error("US_AXIS: accepted beat with tkeep == 0");

    // Deliberately NO assertion that tkeep is contiguous. On a STRADDLING
    // channel two TLPs share a beat and the lanes between them belong to
    // different packets, so a gap is legal there. Asserting contiguity would
    // fail on exactly the traffic Tier 4 exists to test.
    // synopsys translate_on
`endif // MQNIC_NO_SVA
`endif // PCIE_US_AXIS_IF_NO_SVA

endinterface : pcie_us_axis_if

`endif // PCIE_US_AXIS_IF_SV

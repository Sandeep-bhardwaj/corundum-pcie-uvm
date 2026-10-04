// SPDX-License-Identifier: BSD-2-Clause-Views
//
// axis_if - AXI4-Stream signal interface
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.3 (axis_agent), §15.1
// Introduced : Step 3 (Tier 1c); reused at Tiers 2, 5, 6 (§5.1)
//
// Not parameterized, for the reason given in axil_if.sv (STRATEGY §4.3 rule 1).
// Declared at 512 bits, the widest this environment needs (AXIS_PCIE_DATA_WIDTH
// at Tier 6); each DUT wrapper connects only the bits its DUT has.
//
// OPTIONAL SIDEBAND. The Tier 1c DUTs are not uniform, verified against the RTL:
//
//   rx_checksum.v  s_axis_{tdata,tkeep,tvalid,tlast}   - NO tready
//   rx_hash.v      s_axis_{tdata,tkeep,tvalid,tlast}   - NO tready
//   tx_checksum.v  full AXI-S with tready both sides
//
// A sink with no tready must accept a beat on EVERY cycle tvalid is high. The
// same hazard as the queue_manager doorbell: a monitor written around a
// valid/ready handshake silently drops every beat. axis_cfg.has_tready selects
// the behaviour, and the assertions below are guarded on it.
// -----------------------------------------------------------------------------

`ifndef AXIS_IF_SV
`define AXIS_IF_SV

`timescale 1ns / 1ps

interface axis_if (input logic clk, input logic rst);

    localparam int MAX_DATA_WIDTH = 512;
    localparam int MAX_KEEP_WIDTH = MAX_DATA_WIDTH / 8;
    localparam int MAX_USER_WIDTH = 128;
    localparam int MAX_ID_WIDTH   = 8;
    localparam int MAX_DEST_WIDTH = 8;

    logic [MAX_DATA_WIDTH-1:0] tdata;
    logic [MAX_KEEP_WIDTH-1:0] tkeep;
    logic                      tvalid;
    logic                      tready;
    logic                      tlast;
    logic [MAX_USER_WIDTH-1:0] tuser;
    logic [MAX_ID_WIDTH-1:0]   tid;
    logic [MAX_DEST_WIDTH-1:0] tdest;

    clocking src_cb @(posedge clk);
        default input #1step output #1ns;
        output tdata, tkeep, tvalid, tlast, tuser, tid, tdest;
        input  tready;
    endclocking

    clocking sink_cb @(posedge clk);
        default input #1step output #1ns;
        input  tdata, tkeep, tvalid, tlast, tuser, tid, tdest;
        output tready;
    endclocking

    clocking mon_cb @(posedge clk);
        default input #1step;
        input tdata, tkeep, tvalid, tready, tlast, tuser, tid, tdest;
    endclocking

    modport src  (clocking src_cb,  input clk, input rst);
    modport sink (clocking sink_cb, input clk, input rst);
    modport mon  (clocking mon_cb,  input clk, input rst);

    // -------------------------------------------------------------------------
    // Protocol assertions (STRATEGY §15.1).
    //
    // AXIS_IF_NO_TREADY must be defined when binding this interface to a DUT
    // that has no tready - the stability properties below are meaningless
    // without one, and tready would be floating.
    // -------------------------------------------------------------------------

`ifndef AXIS_IF_NO_SVA
`ifndef MQNIC_NO_SVA
    // synopsys translate_off
    default clocking mon_cb;
    // `default disable iff (rst)` is written out on each assertion below:
    // Vivado xsim cannot simulate the default form (XSIM 43-3980), and the
    // explicit form is identical in meaning (IEEE 1800-2017 16.15).

`ifndef AXIS_IF_NO_TREADY
    a_tvalid_stable : assert property (disable iff (rst) tvalid && !tready |=> tvalid)
        else $error("AXIS: tvalid deasserted before tready");
    a_tdata_stable  : assert property (disable iff (rst) tvalid && !tready |=> $stable(tdata))
        else $error("AXIS: tdata changed while tvalid && !tready");
    a_tkeep_stable  : assert property (disable iff (rst) tvalid && !tready |=> $stable(tkeep))
        else $error("AXIS: tkeep changed while tvalid && !tready");
    a_tlast_stable  : assert property (disable iff (rst) tvalid && !tready |=> $stable(tlast))
        else $error("AXIS: tlast changed while tvalid && !tready");
`endif

    // tkeep must be contiguous from the LSB. A hole in the middle of a beat is
    // not legal AXI-Stream for a packet-oriented interface and would silently
    // corrupt every byte-stream reconstruction downstream.
    a_tkeep_contiguous : assert property (disable iff (rst)
        tvalid |-> $countones(tkeep) == 0 || ((tkeep + 1) & tkeep) == 0
    ) else $error("AXIS: tkeep 0x%0h is not contiguous from bit 0", tkeep);

    // Only the final beat of a packet may be partially filled.
    a_tkeep_full_unless_last : assert property (disable iff (rst)
        tvalid && !tlast |-> tkeep[0] == 1'b1
    ) else $error("AXIS: non-final beat with tkeep[0] low");

    a_data_known : assert property (disable iff (rst)
        tvalid |-> !$isunknown({tkeep, tlast})
    ) else $error("AXIS: X/Z on tkeep/tlast while tvalid");
    // synopsys translate_on
`endif // MQNIC_NO_SVA
`endif // AXIS_IF_NO_SVA

endinterface : axis_if

`endif // AXIS_IF_SV

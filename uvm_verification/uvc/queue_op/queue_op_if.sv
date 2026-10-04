// SPDX-License-Identifier: BSD-2-Clause-Views
//
// queue_op_if - queue manager operation interface
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.8 (queue_op_agent, doorbell_monitor)
// Introduced : Step 1 (Tier 1a)
//
// ONE interface serves BOTH Tier 1a DUTs. queue_manager (dequeue side) and
// cpl_queue_manager (enqueue side) are structurally parallel but differ in
// three places, verified against the RTL:
//
//   queue_manager.v                      cpl_queue_manager.v
//   ------------------------------------ ------------------------------------
//   m_axis_dequeue_resp_block_size       m_axis_enqueue_resp_event
//   m_axis_dequeue_resp_cpl              (none)
//   m_axis_dequeue_resp_empty            m_axis_enqueue_resp_full
//   m_axis_doorbell_{queue,valid}        m_axis_event{,_source,_valid,_ready}
//     - PULSE, no ready                    - full valid/ready handshake
//
// The signals here are named neutrally and each DUT wrapper maps its own names
// onto them. queue_op_cfg.flavor tells the agent which DUT it is attached to.
//
// THE NOTIFY CHANNEL IS THE TRAP. On queue_manager the doorbell is a bare pulse
// with no ready, so the monitor must sample it EVERY cycle; a monitor written
// around a valid/ready handshake will silently drop doorbells. STRATEGY §7.8
// calls this out explicitly. cfg.notify_has_ready selects the behaviour.
//
// Not parameterized, for the reason given in axil_if.sv (STRATEGY §4.3 rule 1).
// -----------------------------------------------------------------------------

`ifndef QUEUE_OP_IF_SV
`define QUEUE_OP_IF_SV

`timescale 1ns / 1ps

interface queue_op_if (input logic clk, input logic rst);

    localparam int MAX_QUEUE_WIDTH  = 32;
    localparam int MAX_TAG_WIDTH    = 16;
    localparam int MAX_OP_TAG_WIDTH = 16;
    localparam int MAX_PTR_WIDTH    = 32;
    localparam int MAX_ADDR_WIDTH   = 64;
    localparam int MAX_AUX_WIDTH    = 64;   // block_size (deq) | event (enq)
    localparam int MAX_CPL_WIDTH    = 32;   // dequeue only

    // ---- request (TB -> DUT) -----------------------------------------------
    logic [MAX_QUEUE_WIDTH-1:0]  req_queue;
    logic [MAX_TAG_WIDTH-1:0]    req_tag;
    logic                        req_valid;
    logic                        req_ready;

    // ---- response (DUT -> TB) ----------------------------------------------
    logic [MAX_QUEUE_WIDTH-1:0]  resp_queue;
    logic [MAX_PTR_WIDTH-1:0]    resp_ptr;
    logic                        resp_phase;
    logic [MAX_ADDR_WIDTH-1:0]   resp_addr;
    logic [MAX_AUX_WIDTH-1:0]    resp_aux;      // block_size | event
    logic [MAX_CPL_WIDTH-1:0]    resp_cpl;      // dequeue flavour only
    logic [MAX_TAG_WIDTH-1:0]    resp_tag;
    logic [MAX_OP_TAG_WIDTH-1:0] resp_op_tag;
    logic                        resp_blocked;  // empty (deq) | full (enq)
    logic                        resp_error;
    logic                        resp_valid;
    logic                        resp_ready;

    // ---- commit (TB -> DUT) -------------------------------------------------
    logic [MAX_OP_TAG_WIDTH-1:0] commit_op_tag;
    logic                        commit_valid;
    logic                        commit_ready;

    // ---- notify (DUT -> TB): doorbell or event -----------------------------
    logic [MAX_AUX_WIDTH-1:0]    notify_data;   // event payload; unused for doorbell
    logic [MAX_QUEUE_WIDTH-1:0]  notify_source; // doorbell queue | event source
    logic                        notify_valid;
    logic                        notify_ready;  // enqueue flavour only

    // -------------------------------------------------------------------------
    clocking drv_cb @(posedge clk);
        default input #1step output #1ns;
        output req_queue, req_tag, req_valid;
        input  req_ready;
        input  resp_queue, resp_ptr, resp_phase, resp_addr, resp_aux, resp_cpl;
        input  resp_tag, resp_op_tag, resp_blocked, resp_error, resp_valid;
        output resp_ready;
        output commit_op_tag, commit_valid;
        input  commit_ready;
        input  notify_data, notify_source, notify_valid;
        output notify_ready;
    endclocking

    clocking mon_cb @(posedge clk);
        default input #1step;
        input req_queue, req_tag, req_valid, req_ready;
        input resp_queue, resp_ptr, resp_phase, resp_addr, resp_aux, resp_cpl;
        input resp_tag, resp_op_tag, resp_blocked, resp_error, resp_valid, resp_ready;
        input commit_op_tag, commit_valid, commit_ready;
        input notify_data, notify_source, notify_valid, notify_ready;
    endclocking

    modport drv (clocking drv_cb, input clk, input rst);
    modport mon (clocking mon_cb, input clk, input rst);

    // -------------------------------------------------------------------------
    // Interface-protocol assertions (STRATEGY §15.1). Design-intent properties
    // for the queue manager itself live in sva/sva_queue_manager.sv.
    //
    // Note there is deliberately NO stability assertion on the notify channel:
    // in the dequeue flavour it is a single-cycle pulse with no ready, so
    // "valid held until ready" does not apply.
    // -------------------------------------------------------------------------

`ifndef QUEUE_OP_IF_NO_SVA
`ifndef MQNIC_NO_SVA
    // synopsys translate_off
    default clocking mon_cb;
    // `default disable iff (rst)` is written out on each assertion below:
    // Vivado xsim cannot simulate the default form (XSIM 43-3980), and the
    // explicit form is identical in meaning (IEEE 1800-2017 16.15).

    a_req_valid_stable : assert property (disable iff (rst) req_valid && !req_ready |=> req_valid)
        else $error("QOP: req_valid deasserted before req_ready");
    a_req_queue_stable : assert property (disable iff (rst) req_valid && !req_ready |=> $stable(req_queue))
        else $error("QOP: req_queue changed while req_valid && !req_ready");
    a_req_tag_stable   : assert property (disable iff (rst) req_valid && !req_ready |=> $stable(req_tag))
        else $error("QOP: req_tag changed while req_valid && !req_ready");

    a_resp_valid_stable : assert property (disable iff (rst) resp_valid && !resp_ready |=> resp_valid)
        else $error("QOP: resp_valid deasserted before resp_ready");
    a_resp_optag_stable : assert property (disable iff (rst) resp_valid && !resp_ready |=> $stable(resp_op_tag))
        else $error("QOP: resp_op_tag changed while resp_valid && !resp_ready");

    a_commit_valid_stable : assert property (disable iff (rst) commit_valid && !commit_ready |=> commit_valid)
        else $error("QOP: commit_valid deasserted before commit_ready");
    a_commit_optag_stable : assert property (disable iff (rst) commit_valid && !commit_ready |=> $stable(commit_op_tag))
        else $error("QOP: commit_op_tag changed while commit_valid && !commit_ready");

    a_req_known  : assert property (disable iff (rst) req_valid && req_ready |-> !$isunknown({req_queue, req_tag}))
        else $error("QOP: X/Z on request at handshake");
    a_resp_known : assert property (disable iff (rst) resp_valid && resp_ready |->
                                    !$isunknown({resp_queue, resp_op_tag, resp_blocked, resp_error}))
        else $error("QOP: X/Z on response at handshake");
    // synopsys translate_on
`endif // MQNIC_NO_SVA
`endif // QUEUE_OP_IF_NO_SVA

endinterface : queue_op_if

`endif // QUEUE_OP_IF_SV

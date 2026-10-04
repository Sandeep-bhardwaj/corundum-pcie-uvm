// SPDX-License-Identifier: BSD-2-Clause-Views
//
// dma_desc_if - DMA descriptor request / status interface
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.5 (dma_desc_agent)
// Introduced : Step 4 (Tier 2) - EARLIER than §5.1 schedules it
//
// WHY IT ARRIVES A TIER EARLY. §5.1 builds dma_desc_agent at Tier 3a on
// dma_if_pcie. But dma_client_axis_source/sink take a descriptor of the same
// shape minus the PCIe fields, so building it here means it gets debugged on a
// DUT that only moves bytes between a RAM and a stream, with no TLPs, no tags in
// flight and no completion reordering. That is the same argument §2.1 makes for
// the whole bottom-up plan, so following it here rather than at Tier 3 is
// consistent with the strategy even though it deviates from the manifest order.
//
// SUPERSET OF BOTH USERS, verified against the RTL:
//
//   dma_client_axis_sink.v    s_axis_write_desc_{ram_addr,len,tag}
//   dma_client_axis_source.v  s_axis_read_desc_{ram_addr,len,tag,id,dest,user}
//   dma_if_pcie.v (Tier 3)    s_axis_{read,write}_desc_{pcie_addr,ram_sel,
//                                                        ram_addr,len,tag,imm,imm_en}
//
// Fields a given DUT does not have are simply left unconnected; dma_desc_cfg
// records which are live so the monitor does not report noise on them.
//
// The status channel has NO ready on either client (m_axis_*_desc_status_valid
// only). That is the same pulse shape as the queue_manager doorbell and
// dma_psdpram's wr_done - the monitor must sample it on level alone.
// -----------------------------------------------------------------------------

`ifndef DMA_DESC_IF_SV
`define DMA_DESC_IF_SV

`timescale 1ns / 1ps

interface dma_desc_if (input logic clk, input logic rst);

    import mqnic_vrf_pkg::DMA_DESC_MAX_LEN_WIDTH;
    import mqnic_vrf_pkg::DMA_DESC_MAX_TAG_WIDTH;

    // ---- descriptor request (TB -> DUT) -------------------------------------
    logic [63:0]                        req_pcie_addr;   // Tier 3 only
    logic [7:0]                         req_ram_sel;     // Tier 3 only
    logic [31:0]                        req_ram_addr;
    logic [DMA_DESC_MAX_LEN_WIDTH-1:0]  req_len;
    logic [DMA_DESC_MAX_TAG_WIDTH-1:0]  req_tag;
    logic [7:0]                         req_id;          // source client only
    logic [7:0]                         req_dest;        // source client only
    logic [7:0]                         req_user;        // source client only
    logic [31:0]                        req_imm;         // Tier 3 write only
    logic                               req_imm_en;      // Tier 3 write only
    logic                               req_valid;
    logic                               req_ready;

    // ---- status (DUT -> TB). PULSE: no ready. -------------------------------
    logic [DMA_DESC_MAX_LEN_WIDTH-1:0]  sts_len;         // sink client reports it
    logic [DMA_DESC_MAX_TAG_WIDTH-1:0]  sts_tag;
    logic [7:0]                         sts_id;
    logic [7:0]                         sts_dest;
    logic [7:0]                         sts_user;
    logic [3:0]                         sts_error;
    logic                               sts_valid;

    task automatic init_idle_requester();
        req_pcie_addr = '0;
        req_ram_sel   = '0;
        req_ram_addr  = '0;
        req_len       = '0;
        req_tag       = '0;
        req_id        = '0;
        req_dest      = '0;
        req_user      = '0;
        req_imm       = '0;
        req_imm_en    = 1'b0;
        req_valid     = 1'b0;
    endtask

    task automatic init_idle_responder();
        req_ready = 1'b0;
        sts_len   = '0;
        sts_tag   = '0;
        sts_id    = '0;
        sts_dest  = '0;
        sts_user  = '0;
        sts_error = '0;
        sts_valid = 1'b0;
    endtask

    clocking req_cb @(posedge clk);
        default input #1step output #1ns;
        output req_pcie_addr, req_ram_sel, req_ram_addr, req_len, req_tag;
        output req_id, req_dest, req_user, req_imm, req_imm_en, req_valid;
        input  req_ready;
        input  sts_len, sts_tag, sts_id, sts_dest, sts_user, sts_error, sts_valid;
    endclocking

    clocking mon_cb @(posedge clk);
        default input #1step;
        input req_pcie_addr, req_ram_sel, req_ram_addr, req_len, req_tag;
        input req_id, req_dest, req_user, req_imm, req_imm_en, req_valid, req_ready;
        input sts_len, sts_tag, sts_id, sts_dest, sts_user, sts_error, sts_valid;
    endclocking

    modport req (clocking req_cb, input clk, input rst);
    modport mon (clocking mon_cb, input clk, input rst);

`ifndef DMA_DESC_IF_NO_SVA
`ifndef MQNIC_NO_SVA
    // synopsys translate_off
    default clocking mon_cb;
    // `default disable iff (rst)` is written out on each assertion below:
    // Vivado xsim cannot simulate the default form (XSIM 43-3980), and the
    // explicit form is identical in meaning (IEEE 1800-2017 16.15).

    a_req_valid_stable : assert property (disable iff (rst) req_valid && !req_ready |=> req_valid)
        else $error("DMA_DESC: req_valid dropped before req_ready");
    a_req_addr_stable  : assert property (disable iff (rst)
        req_valid && !req_ready |=> $stable(req_ram_addr)
    ) else $error("DMA_DESC: req_ram_addr changed while stalled");
    a_req_len_stable   : assert property (disable iff (rst)
        req_valid && !req_ready |=> $stable(req_len)
    ) else $error("DMA_DESC: req_len changed while stalled");
    a_req_tag_stable   : assert property (disable iff (rst)
        req_valid && !req_ready |=> $stable(req_tag)
    ) else $error("DMA_DESC: req_tag changed while stalled");

    a_req_known : assert property (disable iff (rst)
        req_valid && req_ready |-> !$isunknown({req_ram_addr, req_len, req_tag})
    ) else $error("DMA_DESC: X on descriptor at handshake");

    // Deliberately NO stability assertion on the status channel: it is a pulse
    // with no ready, so "held until ready" does not apply.
    // synopsys translate_on
`endif // MQNIC_NO_SVA
`endif // DMA_DESC_IF_NO_SVA

endinterface : dma_desc_if

`endif // DMA_DESC_IF_SV

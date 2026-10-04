// SPDX-License-Identifier: BSD-2-Clause-Views
//
// mqnic_rc_model - PCIe root complex behaviour
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §9 (root complex model), §13 Tier 3
// Introduced : Step 5 (Tier 3); reused at Tiers 5 and 6
//
// Turns an observed read request into the completions that come back. This is
// the piece that makes most of Tier 3's test list reachable at all: reordering,
// maximum splitting, timeouts and every error status are BEHAVIOURS OF THE
// COMPLETER, not stimulus a sequence can drive.
//
// It is a pure transaction-level model - given a request it produces a list of
// completions with delays attached. Driving them onto the bus is the agent's
// job, and holding the memory is mqnic_host_mem_model's. Keeping those three
// separate is what lets a completion-ordering bug and a data bug be told apart.
//
// LEGALITY RULES IT OBEYS (and therefore does not hide from the DUT):
//   * every completion except the last ends on an RCB boundary
//   * no completion exceeds max_payload_size
//   * byte_count counts from THIS completion to the end of the original
//     request, not the length of this completion
//   * lower_address is the low 7 bits of this completion's start address
//
// The last two are the ones a hand-written stimulus usually gets wrong, and
// getting them wrong makes the DUT's reassembly look broken.
// -----------------------------------------------------------------------------

`ifndef MQNIC_RC_MODEL_SV
`define MQNIC_RC_MODEL_SV

// One completion the root complex will return.
class rc_completion;
    bit [63:0]         addr;          // byte-exact start address of this chunk
    int unsigned       len;           // MEANINGFUL data bytes in this completion

    // Bytes of the first payload DWORD that precede `addr`. A completion is
    // transmitted in whole DWORDs, so when addr is not DWORD-aligned the wire
    // carries this many leading bytes that are not part of the transfer.
    // lower_address[1:0] is what tells the requester to skip them.
    int unsigned       pad_front;
    int unsigned       byte_count;    // remaining bytes of the ORIGINAL request
    bit [6:0]          lower_address;
    bit [7:0]          tag;
    bit [15:0]         requester_id;
    mqnic_cpl_status_e status;
    bit                poisoned;
    // Delivered as PCIE_ERROR_TIMEOUT on the completion's error sideband, not as
    // a completion status. See the timeout note in the class header.
    bit                is_timeout;
    bit                is_last;
    int unsigned       delay;         // cycles before this one is presented
    byte unsigned      payload [];

    function string convert2string();
        return $sformatf({"CPL tag=0x%0h addr=0x%0h len=%0d bc=%0d la=0x%0h ",
                          "st=%s%s%s"},
                         tag, addr, len, byte_count, lower_address, status.name(),
                         poisoned ? " POISONED" : "", is_last ? " LAST" : "");
    endfunction
endclass


class mqnic_rc_model extends uvm_object;

    `uvm_object_utils(mqnic_rc_model)

    mqnic_host_mem_model mem;

    // Completer configuration.
    bit [2:0]    max_payload_size = 3'd1;    // 128 << value  -> 256 bytes
    bit          rcb_128b         = 1'b0;
    bit [15:0]   completer_id     = 16'h0100;

    // ---- shaping -------------------------------------------------------------
    // Split every completion to the smallest legal size. t3_cpl_split_max sets
    // this: maximum splitting is the worst case for reassembly.
    bit          split_maximally  = 1'b0;

    // How far a completion may be moved from its in-order position. Zero means
    // strictly in order. Reordering is legal across DIFFERENT tags only, which
    // the caller enforces by shuffling the emission queue, not this model.
    int unsigned reorder_depth    = 0;

    int unsigned min_latency      = 4;
    int unsigned max_latency      = 40;

    // -------------------------------------------------------------------------
    // COMPLETION TIMEOUT IS AN INBOUND EVENT, NOT AN ABSENCE.
    //
    // dma_if_pcie_rd HAS NO INTERNAL TIMEOUT COUNTER. Reading the RTL settles
    // it: the only path to DMA_ERROR_TIMEOUT is an incoming completion TLP whose
    // error sideband reads PCIE_ERROR_TIMEOUT (dma_if_pcie_rd.v:1117-1122) -
    // that is how the hard IP reports a timeout it detected itself.
    //
    // So simply withholding a completion does NOT exercise the timeout path; it
    // leaves the tag outstanding forever and the descriptor never retires. The
    // first version of t3_cpl_timeout did exactly that and would have hung until
    // the global watchdog, reporting nothing useful.
    //
    // timeout_pct injects the real event. drop_pct remains for the DIFFERENT
    // question of what the DUT does when a completion never arrives at all - a
    // hang test, not an error test - and defaults off.
    // -------------------------------------------------------------------------
    int unsigned timeout_pct      = 0;
    int unsigned drop_pct         = 0;

    protected int unsigned m_n_requests;
    protected int unsigned m_n_completions;
    protected int unsigned m_n_dropped;
    protected int unsigned m_n_timeout;

    function new(string name = "mqnic_rc_model");
        super.new(name);
    endfunction

    function int unsigned mps_bytes();
        return 128 << max_payload_size;
    endfunction

    function int unsigned rcb();
        return rcb_128b ? 128 : 64;
    endfunction

    // -------------------------------------------------------------------------
    // Produce the completions for one read request.
    //
    // Returns an empty list when the request is dropped (timeout path).
    // -------------------------------------------------------------------------
    virtual function void complete_read(input bit [63:0]   addr,
                                        input int unsigned len,
                                        input bit [7:0]    tag,
                                        input bit [15:0]   requester_id,
                                        ref   rc_completion out[$]);
        bit [63:0]        cur;
        int unsigned      rem;
        int unsigned      chunk;
        int unsigned      to_rcb;
        int unsigned      limit;
        host_mem_status_e st;
        rc_completion     c;

        out.delete();
        m_n_requests++;

        if (drop_pct > 0 && $urandom_range(1, 100) <= drop_pct) begin
            m_n_dropped++;
            return;                     // nothing comes back at all
        end

        // Timeout: a single no-data completion whose ERROR SIDEBAND says so.
        // Status stays SC - the RTL keys on the sideband, and a non-SC status
        // with a data-carrying format would be rejected as malformed instead
        // (dma_if_pcie_rd.v:1085).
        if (timeout_pct > 0 && $urandom_range(1, 100) <= timeout_pct) begin
            c               = new();
            c.addr          = addr;
            c.len           = 0;
            c.byte_count    = len;
            c.lower_address = addr[6:0];
            c.tag           = tag;
            c.requester_id  = requester_id;
            c.status        = CPL_STATUS_SC;
            c.is_timeout    = 1'b1;
            c.is_last       = 1'b1;
            c.delay         = $urandom_range(min_latency, max_latency);
            c.payload       = new[0];
            out.push_back(c);
            m_n_completions++;
            m_n_timeout++;
            return;
        end

        // A bad region answers with a single status completion and no data.
        st = (mem == null) ? HOST_MEM_OK : mem.status_for(addr, len);
        if (st == HOST_MEM_UR || st == HOST_MEM_CA) begin
            c               = new();
            c.addr          = addr;
            c.len           = 0;
            c.byte_count    = len;
            c.lower_address = addr[6:0];
            c.tag           = tag;
            c.requester_id  = requester_id;
            c.status        = (st == HOST_MEM_UR) ? CPL_STATUS_UR : CPL_STATUS_CA;
            c.poisoned      = 1'b0;
            c.is_last       = 1'b1;
            c.delay         = $urandom_range(min_latency, max_latency);
            c.payload       = new[0];
            out.push_back(c);
            m_n_completions++;
            return;
        end

        // Normal path: split into legal chunks.
        limit = split_maximally ? rcb() : mps_bytes();
        cur   = addr;
        rem   = len;

        while (rem > 0) begin
            chunk = rem;
            if (chunk > limit) chunk = limit;

            // Every completion except the last must end on an RCB boundary.
            to_rcb = rcb() - (int'(cur) % rcb());
            if (chunk > to_rcb) chunk = to_rcb;

            c               = new();
            c.addr          = cur;
            c.len           = chunk;
            // byte_count counts to the end of the ORIGINAL request, not this
            // chunk - the single most common thing to get wrong here.
            c.byte_count    = rem;
            // lower_address is the BYTE-EXACT chunk address. Its low two bits
            // are load-bearing: dma_if_pcie_rd computes the RAM destination as
            // ram_end - (byte_count + lower_addr[1:0]) (:1008), so reporting a
            // DWORD-aligned address here shifts the whole transfer.
            c.lower_address = cur[6:0];
            c.tag           = tag;
            c.requester_id  = requester_id;
            c.status        = CPL_STATUS_SC;
            c.poisoned      = (st == HOST_MEM_POISON);
            c.delay         = $urandom_range(min_latency, max_latency);

            // The wire carries whole DWORDs. When `cur` is not DWORD-aligned
            // the completion begins with pad_front bytes that belong to the
            // same DWORD but precede the requested data.
            c.pad_front = int'(cur[1:0]);
            begin
                int unsigned wire_bytes = ((c.pad_front + chunk + 3) / 4) * 4;
                bit [63:0]   dw_base    = cur - 64'(c.pad_front);
                c.payload = new[wire_bytes];
                for (int i = 0; i < int'(wire_bytes); i++)
                    c.payload[i] = (mem == null) ? 8'h00 : mem.read_byte(dw_base + i);
            end

            out.push_back(c);
            m_n_completions++;

            cur += chunk;
            rem -= chunk;
        end

        if (out.size() > 0) out[out.size()-1].is_last = 1'b1;
    endfunction

    // -------------------------------------------------------------------------
    // Shuffle a pending emission queue within reorder_depth.
    //
    // PCIe allows completions for DIFFERENT tags to return in any order, but
    // completions for the SAME tag must stay in order.
    //
    // "q[i].tag != q[j].tag" IS NOT SUFFICIENT to preserve that, and the first
    // version of this function got it wrong. Swapping the ends of
    //
    //     [ tagA_0 , tagA_1 , tagB ]        i=0, j=2, tags differ
    //  -> [ tagB   , tagA_1 , tagA_0 ]
    //
    // leaves tagA's two completions in the wrong relative order. The queue would
    // then be ILLEGAL traffic, and the DUT would be blamed for mishandling it.
    //
    // The swap is legal only when nothing STRICTLY BETWEEN i and j shares a tag
    // with either endpoint - that is what makes the exchange invisible to every
    // same-tag subsequence.
    // -------------------------------------------------------------------------
    virtual function void reorder(ref rc_completion q[$]);
        int j;
        rc_completion tmp;

        if (reorder_depth == 0 || q.size() < 2) return;

        for (int i = 0; i < q.size() - 1; i++) begin
            j = i + $urandom_range(1, reorder_depth);
            if (j >= q.size()) j = q.size() - 1;
            if (swap_legal(q, i, j)) begin
                tmp  = q[i];
                q[i] = q[j];
                q[j] = tmp;
            end
        end
    endfunction

    protected virtual function bit swap_legal(ref rc_completion q[$],
                                              input int i, input int j);
        if (i >= j) return 1'b0;
        if (q[i].tag == q[j].tag) return 1'b0;
        for (int k = i + 1; k < j; k++)
            if (q[k].tag == q[i].tag || q[k].tag == q[j].tag) return 1'b0;
        return 1'b1;
    endfunction

    // -------------------------------------------------------------------------
    virtual function string convert2string();
        return $sformatf({"rc_model: %0d request(s), %0d completion(s), %0d dropped, ",
                          "%0d timeout-marked"},
                         m_n_requests, m_n_completions, m_n_dropped, m_n_timeout);
    endfunction

    virtual function int unsigned timeout_count();
        return m_n_timeout;
    endfunction

    virtual function void reset_stats();
        m_n_requests    = 0;
        m_n_completions = 0;
        m_n_dropped     = 0;
        m_n_timeout     = 0;
    endfunction

endclass : mqnic_rc_model

`endif // MQNIC_RC_MODEL_SV

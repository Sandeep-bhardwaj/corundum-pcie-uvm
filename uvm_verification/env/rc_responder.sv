// SPDX-License-Identifier: BSD-2-Clause-Views
//
// rc_responder - drives completions in reply to observed read requests
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §9, §13 Tier 3
// Introduced : Step 5 (Tier 3); reused at Tiers 5 and 6
//
// The active half of the root complex. mqnic_rc_model decides WHAT comes back;
// this component decides WHEN, and puts it on the bus.
//
// Splitting it this way matters: the model is a pure function that a test can
// call directly to predict, while this component is the only thing with timing.
// A single class doing both would make "the model is wrong" and "the driver is
// late" indistinguishable.
//
// EMISSION IS A SINGLE ORDERED QUEUE, shuffled by mqnic_rc_model.reorder(). PCIe
// permits completions for DIFFERENT tags to return in any order but requires
// same-tag completions to stay ordered, and the model's shuffle honours that -
// so reordering here cannot generate illegal traffic and then blame the DUT for
// mishandling it.
// -----------------------------------------------------------------------------

`ifndef RC_RESPONDER_SV
`define RC_RESPONDER_SV

`uvm_analysis_imp_decl(_rc_req)

class rc_responder extends uvm_component;

    `uvm_component_utils(rc_responder)

    uvm_analysis_imp_rc_req #(pcie_tlp_item, rc_responder) req_imp;

    mqnic_rc_model       rc;
    mqnic_host_mem_model mem;

    // Sequencer for the completion channel.
    pcie_tlp_sequencer   cpl_seqr;

    // Completions waiting to be emitted.
    protected rc_completion m_pending [$];

    // Signalled when write_rc_req() queues work.
    //
    // NOT `wait (m_pending.size() > 0)`. That form depends on the simulator
    // re-evaluating the condition when a queue is pushed from an analysis
    // write - which is a function call in another process, not an assignment
    // the scheduler is obliged to notice. An explicit event has defined
    // semantics; the wait form has a plausible one.
    protected event m_work;

    // How many requests have been seen but not yet fully answered. A test drains
    // on this - the Tier 2 lesson: a finished sequence is not finished traffic.
    protected int unsigned m_outstanding;

    protected int unsigned m_n_emitted;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        req_imp = new("req_imp", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (rc == null) rc = mqnic_rc_model::type_id::create("rc");
    endfunction

    // -------------------------------------------------------------------------
    // A read request arrives: ask the model what comes back, and queue it.
    // -------------------------------------------------------------------------
    virtual function void write_rc_req(pcie_tlp_item t);
        rc_completion cpls [$];
        bit [63:0]    addr;
        int unsigned  len;
        bit [7:0]     tag;
        bit [15:0]    rid;

        // BYTE-EXACT, from the byte enables - not the header's DWORD-aligned
        // address and DWORD count. The DUT reconstructs the RAM destination
        // from byte_count and lower_addr[1:0] (dma_if_pcie_rd.v:1008), so a
        // completion built from the rounded extent lands 0-3 bytes off.
        addr = mqnic_vrf_pkg::tlp_hdr_req_byte_addr(t.hdr);
        len  = mqnic_vrf_pkg::tlp_hdr_req_byte_len(t.hdr);
        tag  = t.hdr_req_tag();
        rid  = mqnic_vrf_pkg::tlp_hdr_req_requester_id(t.hdr);

        // A zero-length read is a legal flush; it still needs one completion.
        if (len == 0) len = 1;

        rc.complete_read(addr, len, tag, rid, cpls);

        if (cpls.size() == 0) begin
            // Deliberately dropped: the DUT must reach its completion timeout.
            `uvm_info(get_type_name(),
                $sformatf("request tag 0x%0h addr 0x%0h DROPPED (timeout path)",
                          tag, addr), UVM_MEDIUM)
            return;
        end

        m_outstanding++;
        foreach (cpls[i]) m_pending.push_back(cpls[i]);
        rc.reorder(m_pending);
        ->m_work;

        `uvm_info(get_type_name(),
            $sformatf("request tag 0x%0h addr 0x%0h len %0d -> %0d completion(s)",
                      tag, addr, len, cpls.size()), UVM_HIGH)
    endfunction

    // -------------------------------------------------------------------------
    virtual task run_phase(uvm_phase phase);
        rc_completion c;
        pcie_tlp_item it;

        forever begin
            while (m_pending.size() == 0) @m_work;
            c = m_pending.pop_front();

            it            = pcie_tlp_item::type_id::create("cpl");
            it.hdr        = mqnic_vrf_pkg::tlp_hdr_completion(
                                rc.completer_id,
                                c.status,
                                c.byte_count,
                                c.requester_id,
                                c.tag,
                                c.lower_address,
                                // Length field counts the DWORDs actually on
                                // the wire, which includes the leading pad.
                                c.payload.size() / 4,
                                c.poisoned);
            it.payload    = new[c.payload.size()];
            foreach (c.payload[i]) it.payload[i] = c.payload[i];
            // The completion channel carries an error code rather than a BAR.
            // A timeout reaches the DUT ONLY through this sideband - it has no
            // internal timer. See the note in mqnic_rc_model.
            if      (c.is_timeout) it.error = 4'(PCIE_ERROR_TIMEOUT);
            else if (c.poisoned)   it.error = 4'(PCIE_ERROR_POISONED);
            else                   it.error = 4'd0;
            it.bar_id     = '0;
            it.func_num   = '0;
            it.delay      = c.delay;

            emit(it);

            if (c.is_last && m_outstanding > 0) m_outstanding--;
            m_n_emitted++;
        end
    endtask

    // Sends the item VERBATIM. pcie_tlp_single_seq would randomize the payload,
    // which is correct for stimulus and wrong here - a completion must carry the
    // bytes the host memory model actually holds, or every data check fails for
    // a reason that has nothing to do with the DUT.
    protected virtual task emit(pcie_tlp_item it);
        pcie_tlp_verbatim_seq s;
        if (cpl_seqr == null)
            `uvm_fatal(get_type_name(), "cpl_seqr not connected")
        s     = pcie_tlp_verbatim_seq::type_id::create("cpl_seq");
        s.src = it;
        s.start(cpl_seqr);
    endtask

    // -------------------------------------------------------------------------
    // Requests seen but not yet fully answered, plus completions still queued.
    // A test waits on this rather than on a fixed delay.
    // -------------------------------------------------------------------------
    virtual function bit is_idle();
        return (m_pending.size() == 0) && (m_outstanding == 0);
    endfunction

    virtual function int unsigned pending_completions();
        return m_pending.size();
    endfunction

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf("emitted %0d completion(s); %s",
                      m_n_emitted, rc.convert2string()), UVM_LOW)
    endfunction

endclass : rc_responder

`endif // RC_RESPONDER_SV

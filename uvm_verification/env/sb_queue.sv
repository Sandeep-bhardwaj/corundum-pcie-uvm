// SPDX-License-Identifier: BSD-2-Clause-Views
//
// sb_queue - Tier 1a scoreboard
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §11 (sb_queue), §10 (ref_queue)
// Introduced : Step 1 (Tier 1a)
//
// Subscribes to five analysis ports and decides pass/fail:
//
//   axil wr_ap    -> ref_queue.write_reg()      (register programming)
//   qop  req_ap   -> ref_queue.predict_request() -> push expected response
//   qop  resp_ap  -> compare against the expected response
//   qop  commit_ap-> ref_queue.apply_commit()
//   qop  notify_ap-> compare against expected doorbells
//
// ORDERING ASSUMPTION, stated explicitly because it bounds what this scoreboard
// can check: register programming and dequeue traffic are assumed not to
// overlap. The Tier 1a tests configure queues first, then drive requests. The
// DUT pipelines AXI-Lite and request operations against a shared queue RAM, so
// interleaving them makes the predicted response depend on pipeline timing that
// a transaction-level model cannot resolve. t1a_random_stress therefore keeps
// the two phases separate. Lifting this needs a cycle-accurate model, which is
// not justified at this tier.
// -----------------------------------------------------------------------------

`ifndef SB_QUEUE_SV
`define SB_QUEUE_SV

`uvm_analysis_imp_decl(_axil_wr)
`uvm_analysis_imp_decl(_qop_req)
`uvm_analysis_imp_decl(_qop_resp)
`uvm_analysis_imp_decl(_qop_commit)
`uvm_analysis_imp_decl(_qop_notify)

class sb_queue extends mqnic_scoreboard_base;

    `uvm_component_utils(sb_queue)

    uvm_analysis_imp_axil_wr    #(axil_item,     sb_queue) axil_wr_imp;
    uvm_analysis_imp_qop_req    #(queue_op_item, sb_queue) qop_req_imp;
    uvm_analysis_imp_qop_resp   #(queue_op_item, sb_queue) qop_resp_imp;
    uvm_analysis_imp_qop_commit #(queue_op_item, sb_queue) qop_commit_imp;
    uvm_analysis_imp_qop_notify #(queue_op_item, sb_queue) qop_notify_imp;

    ref_queue m_ref;

    // Expected responses, in issue order. The DUT answers requests in order, so
    // a queue is the correct structure - a mismatch in ORDER is itself a bug.
    protected ref_queue_resp m_exp_resp [$];
    // Expected doorbell / event source queues.
    protected bit [31:0]     m_exp_doorbell [$];
    // Doorbells that arrived BEFORE the register write that predicts them.
    // See reconcile_doorbell() for why that ordering is legal.
    protected bit [31:0]     m_act_doorbell [$];

    // Every op_tag the DUT has handed out and not yet had committed. Used for
    // the uniqueness check that STRATEGY §15.2 requires.
    protected bit            m_op_tag_outstanding [bit [15:0]];

    protected int unsigned   m_n_doorbell_match;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        axil_wr_imp    = new("axil_wr_imp", this);
        qop_req_imp    = new("qop_req_imp", this);
        qop_resp_imp   = new("qop_resp_imp", this);
        qop_commit_imp = new("qop_commit_imp", this);
        qop_notify_imp = new("qop_notify_imp", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (m_ref == null)
            m_ref = ref_queue::type_id::create("m_ref");
    endfunction

    virtual function int unsigned pending_count();
        return m_exp_resp.size() + m_exp_doorbell.size() + m_act_doorbell.size();
    endfunction


    // -------------------------------------------------------------------------
    // DOORBELL / EVENT RECONCILIATION
    //
    // The register-write stream and the doorbell stream are INDEPENDENT analysis
    // channels with no guaranteed relative order. queue_manager raises the
    // doorbell inside the register-write pipeline (:509-519), so the monitor can
    // observe it BEFORE axil_monitor publishes the write - the write is only
    // published once its B handshake completes, which happens later.
    //
    // Matching them as a strict FIFO therefore produced a one-behind lag:
    // "unexpected doorbell for queue 37", then "expected 37, actual 74", and one
    // expectation left over at the end. The DUT was right; the scoreboard was
    // imposing an order that does not exist.
    //
    // The fix keeps two lists and reconciles in BOTH directions. Matching is by
    // source queue rather than strictly positional, which is the correct
    // relaxation here: what must hold is that every predicted doorbell occurs
    // exactly once, not that it occurs in a particular position relative to an
    // unrelated channel. Count per queue is still enforced, so a missing,
    // extra or wrong-source doorbell still fails.
    // -------------------------------------------------------------------------
    protected virtual function void expect_doorbell(bit [31:0] q);
        int idx [$];

        // Did this one already arrive early?
        idx = m_act_doorbell.find_first_index(x) with (x == q);
        if (idx.size() > 0) begin
            m_act_doorbell.delete(idx[0]);
            note_match($sformatf("doorbell for queue %0d (arrived before its register write)", q));
            return;
        end

        m_exp_doorbell.push_back(q);
        note_expected();
        `uvm_info(get_type_name(),
            $sformatf("expect doorbell for queue %0d", q), UVM_HIGH)
    endfunction

    protected virtual function void observe_doorbell(bit [31:0] q);
        int idx [$];

        note_actual();

        idx = m_exp_doorbell.find_first_index(x) with (x == q);
        if (idx.size() > 0) begin
            m_exp_doorbell.delete(idx[0]);
            m_n_doorbell_match++;
            note_match($sformatf("doorbell for queue %0d", q));
            return;
        end

        // Not predicted yet. Hold it: the register write that predicts it may
        // still be in flight. Anything left here at end of test is a genuine
        // unexpected doorbell and fails the drain check.
        m_act_doorbell.push_back(q);
        `uvm_info(get_type_name(),
            $sformatf("doorbell for queue %0d arrived before its register write", q),
            UVM_HIGH)
    endfunction

    // -------------------------------------------------------------------------
    // Register writes drive the model's queue configuration, and may predict a
    // doorbell (producer-pointer write while enabled - queue_manager.v:509).
    // -------------------------------------------------------------------------
    virtual function void write_axil_wr(axil_item t);
        bit [31:0] db_queue;
        bit        db;

        if (t.resp != AXIL_OKAY) begin
            `uvm_info(get_type_name(),
                $sformatf("ignoring errored register write: %s", t.convert2string()),
                UVM_MEDIUM)
            return;
        end

        db = m_ref.write_reg(t.addr, 32'(t.data), db_queue);
        if (db) expect_doorbell(db_queue);
        drain_notifies();
    endfunction

    // -------------------------------------------------------------------------
    // The enqueue flavour raises EVENTS from three places - a register write, an
    // arm command, and commit-time retirement - so the model queues them rather
    // than returning one. Draining after every model interaction keeps the
    // expected order identical to the order the DUT emits them.
    // -------------------------------------------------------------------------
    protected virtual function void drain_notifies();
        ref_queue_notify n;
        forever begin
            n = m_ref.pop_notify();
            if (n == null) break;
            expect_doorbell(n.source);
        end
    endfunction

    // -------------------------------------------------------------------------
    virtual function void write_qop_req(queue_op_item t);
        ref_queue_resp r = m_ref.predict_request(t.queue);
        m_exp_resp.push_back(r);
        note_expected();
        `uvm_info(get_type_name(),
            $sformatf("expect resp: %s", r.convert2string()), UVM_HIGH)
    endfunction

    // -------------------------------------------------------------------------
    virtual function void write_qop_resp(queue_op_item t);
        ref_queue_resp r;
        string         ctx;

        note_actual();

        if (m_exp_resp.size() == 0) begin
            note_mismatch("unexpected response - no request outstanding",
                          "no response", t.convert2string());
            return;
        end

        r   = m_exp_resp.pop_front();
        ctx = $sformatf("dequeue response for queue %0d", r.queue);

        if (r.queue   !== t.queue   ||
            r.ptr     !== t.ptr     ||
            r.phase   !== t.phase   ||
            r.addr    !== t.addr    ||
            r.aux     !== t.aux     ||
            r.cpl     !== t.cpl     ||
            r.op_tag  !== t.op_tag  ||
            r.blocked !== t.blocked ||
            r.error   !== t.error) begin
            note_mismatch(ctx, r.convert2string(), t.convert2string());
            return;
        end

        // An op_tag is only allocated when the operation actually starts -
        // i.e. not on an error or empty response (queue_manager.v:451).
        if (!t.error && !t.blocked) begin
            if (m_op_tag_outstanding.exists(t.op_tag)) begin
                note_mismatch($sformatf("op_tag 0x%0h reissued while still outstanding",
                                        t.op_tag),
                              "unique op_tag", $sformatf("duplicate op_tag 0x%0h", t.op_tag));
                return;
            end
            m_op_tag_outstanding[t.op_tag] = 1'b1;
        end

        note_match(ctx);
    endfunction

    // -------------------------------------------------------------------------
    virtual function void write_qop_commit(queue_op_item t);
        if (!m_op_tag_outstanding.exists(t.commit_op_tag)) begin
            `uvm_warning(get_type_name(),
                $sformatf("commit of op_tag 0x%0h that was never issued", t.commit_op_tag))
        end
        else begin
            m_op_tag_outstanding.delete(t.commit_op_tag);
        end
        m_ref.apply_commit(t.commit_op_tag);
        drain_notifies();
    endfunction

    // -------------------------------------------------------------------------
    virtual function void write_qop_notify(queue_op_item t);
        observe_doorbell(t.notify_source);
    endfunction

    // -------------------------------------------------------------------------
    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf({"doorbells matched=%0d, unmatched expected=%0d, ",
                       "unmatched actual=%0d, op_tags outstanding=%0d"},
                      m_n_doorbell_match, m_exp_doorbell.size(),
                      m_act_doorbell.size(), m_op_tag_outstanding.size()), UVM_LOW)
    endfunction

endclass : sb_queue

`endif // SB_QUEUE_SV

// SPDX-License-Identifier: BSD-2-Clause-Views
//
// ref_queue - reference model for queue_manager / cpl_queue_manager
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §10 (reference models), §11 (sb_queue)
// Introduced : Step 1 (Tier 1a)
//
// Derived by reading fpga/common/rtl/queue_manager.v, not by assumption. Line
// references below are to that file.
//
// QUEUE RAM LAYOUT (:206-213)
//   [15:0]    prod_ptr
//   [31:16]   cons_ptr
//   [47:32]   cpl_queue
//   [51:48]   log_queue_size
//   [53:52]   log_block_size
//   [55]      enable
//   [63:56]   op_index          - index of the most recent op on this queue
//   [127:76]  base_addr >> 12   - queue base is 4 KB aligned
//
// KEY SEMANTICS
//   queue_active     (:268) op_table_active[op_index] && op_table_queue[op_index] == q
//   queue_empty      (:271) active ? prod_ptr == op_table_queue_ptr[op_index]
//                                  : prod_ptr == cons_ptr
//   active_cons_ptr  (:272) active ? op_table_queue_ptr[op_index] : cons_ptr
//   resp.ptr         (:420) active_cons_ptr
//   resp.phase       (:421) !active_cons_ptr[log_queue_size]
//   resp.addr        (:422) base_addr + ((active_cons_ptr & size_mask)
//                                        << (CL_DESC_SIZE + log_block_size))
//   resp.op_tag      (:426) op_table_start_ptr
//   resp.error       (:437) queue not enabled
//   resp.empty       (:443) enabled but empty
//   op start         (:451) only when enabled AND not empty
//   next queue ptr   (:351) active_cons_ptr + 1
//
// The "active" pointer is the crux: a queue with an outstanding uncommitted
// operation reports the SPECULATIVELY ADVANCED pointer, not the committed one.
// A model that returns cons_ptr unconditionally passes the single-op tests and
// fails everything with two operations in flight.
//
// RETIREMENT IS IN ORDER (:394). An op is retired only when the op at
// finish_ptr is both active and committed. Committing op 5 before op 4 does not
// advance anything until 4 also commits - that is what t1a_commit_ordering
// checks.
//
// DOORBELL (:509-519) fires on a PRODUCER POINTER WRITE (command 0x8080_zzzz)
// while the queue is enabled. It is NOT tied to the enable bit changing - see
// the strategy-document correction noted in docs/bringup_log.md.
// -----------------------------------------------------------------------------

`ifndef REF_QUEUE_SV
`define REF_QUEUE_SV

// Predicted dequeue/enqueue response.
class ref_queue_resp;
    bit [31:0] queue;
    bit [31:0] ptr;
    bit        phase;
    bit [63:0] addr;
    bit [63:0] aux;      // log_block_size (dequeue flavour)
    bit [31:0] cpl;
    bit [15:0] op_tag;
    bit        blocked;  // empty (dequeue) / full (enqueue)
    bit        error;

    function string convert2string();
        return $sformatf({"queue=%0d ptr=%0d phase=%0b addr=0x%0h aux=0x%0h ",
                          "cpl=%0d op_tag=0x%0h blocked=%0b error=%0b"},
                         queue, ptr, phase, addr, aux, cpl, op_tag, blocked, error);
    endfunction
endclass


class ref_queue_entry;
    bit [15:0] prod_ptr;
    bit [15:0] cons_ptr;
    bit [15:0] cpl_queue;
    bit [3:0]  log_queue_size;
    bit [1:0]  log_block_size;
    bit        enable;
    bit        armed;        // cpl_queue_manager RAM [54]
    bit        continuous;   // cpl_queue_manager RAM [53]
    bit [7:0]  op_index;
    bit [63:0] base_addr;
endclass


// A doorbell (dequeue) or an event (enqueue) predicted by the model.
class ref_queue_notify;
    bit [31:0] source;   // queue index
    bit [63:0] data;     // event payload; unused for a doorbell
endclass


// Which DUT this instance models. cpl_queue_manager is structurally identical
// to queue_manager with exactly four differences, all verified against
// cpl_queue_manager.v:
//
//   1. FULL replaces EMPTY (:269-271)
//        full = ((prod - cons) & (~0 << log_size)) != 0
//        i.e. occupancy has reached the ring size, rather than prod == cons.
//   2. The speculative pointer is the PRODUCER side (:272, :420)
//        active_prod_ptr, and retirement advances prod_ptr, not cons_ptr.
//   3. Address is base + (ptr & size_mask) * CPL_SIZE (:423) - a MULTIPLY by the
//      fixed 32-byte completion size, not a shift by log_block_size.
//   4. The RAM field at [47:32] is `event`, and there is no log_block_size
//      field at [53:52] (:212-213).
typedef enum {
    REF_Q_DEQUEUE,   // queue_manager
    REF_Q_ENQUEUE    // cpl_queue_manager
} ref_queue_flavor_e;


class ref_queue extends uvm_object;

    `uvm_object_utils(ref_queue)

    ref_queue_flavor_e flavor = REF_Q_DEQUEUE;

    // ---- geometry -----------------------------------------------------------
    int unsigned queue_index_width = 13;
    int unsigned op_table_size     = 32;
    int unsigned desc_size         = 16;
    int unsigned ptr_width         = 16;
    // cpl_queue_manager's CPL_SIZE parameter (default 16 in the RTL). Must match
    // whatever the top elaborates the DUT with, or every enqueue address is off.
    int unsigned cpl_size          = 16;

    // Doorbells / events the DUT is expected to emit, in order. The scoreboard
    // drains this after every register write and every commit.
    ref_queue_notify m_pending_notify [$];

    // ---- queue state, sparse: only touched queues are modelled -------------
    protected ref_queue_entry m_q [bit [31:0]];

    // ---- op table -----------------------------------------------------------
    protected bit        m_op_active [];
    protected bit        m_op_commit [];
    protected bit [31:0] m_op_queue  [];
    protected bit [15:0] m_op_ptr    [];
    protected int        m_op_start;    // next tag to allocate
    protected int        m_op_finish;   // in-order retire pointer

    function new(string name = "ref_queue");
        super.new(name);
    endfunction

    // -------------------------------------------------------------------------
    virtual function void configure(int unsigned qiw, int unsigned ots,
                                    int unsigned dsz = 16, int unsigned pw = 16);
        queue_index_width = qiw;
        op_table_size     = ots;
        desc_size         = dsz;
        ptr_width         = pw;
        reset();
    endfunction

    virtual function void reset();
        m_q.delete();
        m_op_active = new[op_table_size];
        m_op_commit = new[op_table_size];
        m_op_queue  = new[op_table_size];
        m_op_ptr    = new[op_table_size];
        foreach (m_op_active[i]) begin
            m_op_active[i] = 1'b0;
            m_op_commit[i] = 1'b0;
            m_op_queue[i]  = '0;
            m_op_ptr[i]    = '0;
        end
        m_op_start  = 0;
        m_op_finish = 0;
        m_pending_notify.delete();
    endfunction

    // Drain one predicted notification, or null when none is pending.
    virtual function ref_queue_notify pop_notify();
        if (m_pending_notify.size() == 0) return null;
        return m_pending_notify.pop_front();
    endfunction

    virtual function int unsigned notify_pending();
        return m_pending_notify.size();
    endfunction

    protected virtual function void push_notify(bit [31:0] src, bit [63:0] data);
        ref_queue_notify n = new();
        n.source = src;
        n.data   = data;
        m_pending_notify.push_back(n);
    endfunction

    protected virtual function ref_queue_entry get_q(bit [31:0] idx);
        if (!m_q.exists(idx)) begin
            ref_queue_entry e = new();
            m_q[idx] = e;
        end
        return m_q[idx];
    endfunction

    // -------------------------------------------------------------------------
    // Register writes. Address layout is queue in the upper bits, register in
    // [4:2] - AXIL_ADDR_WIDTH = QUEUE_INDEX_WIDTH+5 gives 8 dword registers per
    // queue. Commands are the MQNIC_QUEUE_CMD_* opcodes from mqnic_hw.h.
    //
    // Returns 1 if this write generates a doorbell.
    // -------------------------------------------------------------------------
    virtual function bit write_reg(bit [63:0] addr,
                                   bit [31:0] data,
                                   output bit [31:0] doorbell_queue);
        bit [31:0]      qidx;
        bit [2:0]       reg_sel;
        ref_queue_entry e;

        doorbell_queue = '0;

        // ADDRESS LAYOUT DIFFERS BETWEEN THE TWO DUTS.
        //   queue_manager      uses a 3-bit register select: 8 dwords per queue,
        //                      AXIL_ADDR_WIDTH = QUEUE_INDEX_WIDTH + 5
        //   cpl_queue_manager  uses a 2-bit register select (:'case
        //                      (axil_reg_pipeline_reg)' has only 2'd0..2'd3):
        //                      4 dwords per queue, +4
        // Using the wrong one silently addresses the wrong queue.
        if (flavor == REF_Q_DEQUEUE) begin
            qidx    = 32'(addr >> 5);
            reg_sel = addr[4:2];
        end
        else begin
            qidx    = 32'(addr >> 4);
            reg_sel = {1'b0, addr[3:2]};
        end
        e = get_q(qidx);

        // The command port: register 2 on the dequeue side, registers 2 and 3
        // on the enqueue side (cpl_queue_manager.v treats 2'd2 and 2'd3 alike).
        if (reg_sel == 3'd2 || (flavor == REF_Q_ENQUEUE && reg_sel == 3'd3)) begin
            // The enqueue side splits the 0x4000 group into SET_ENABLE
            // (0x400001zz) and SET_ARM (0x400002zz); the dequeue side has only
            // SET_ENABLE (0x40000100).
            if (flavor == REF_Q_ENQUEUE && data[31:8] == 24'h400002) begin
                e.armed = data[0];
                if (e.enable && data[0] && (e.prod_ptr != e.cons_ptr)) begin
                    push_notify(qidx, 64'(e.cpl_queue));
                    e.armed = 1'b0;
                end
                return 1'b0;
            end

            casez (data[31:16])
                16'h8001: ; // SET_VF_ID - not modelled
                16'h8002: begin // SET_SIZE
                    // The enqueue side has no log_block_size field: SET_SIZE
                    // writes only [51:48] (cpl_queue_manager.v, 'set size').
                    e.log_queue_size = data[3:0];
                    if (flavor == REF_Q_DEQUEUE) e.log_block_size = data[9:8];
                end
                16'hC0zz, 16'hC000: begin // SET_CQN (dequeue) / SET_EQN (enqueue)
                    e.cpl_queue = data[15:0];
                end
                16'h8080: begin // SET_PROD_PTR
                    // Software may only write the producer pointer while the
                    // queue is DISABLED on the enqueue side - the DUT owns it
                    // once enabled (cpl_queue_manager.v, 'set producer pointer').
                    if (flavor == REF_Q_DEQUEUE || e.enable == 1'b0)
                        e.prod_ptr = data[15:0];
                    // Doorbell on producer pointer update, gated by enable.
                    // queue_manager.v:509-519
                    if (e.enable) begin
                        doorbell_queue = qidx;
                        return 1'b1;
                    end
                end
                16'h8091: begin // SET_CONS_PTR_ARM (enqueue side only)
                    if (flavor == REF_Q_ENQUEUE) begin
                        // Arm, then fire immediately if the queue is enabled and
                        // the producer pointer has moved past the new consumer
                        // pointer - i.e. there is already something to report.
                        e.armed = 1'b1;
                        if (e.enable && e.prod_ptr != data[15:0]) begin
                            push_notify(qidx, 64'(e.cpl_queue));
                            e.armed = 1'b0;
                        end
                        e.cons_ptr = data[15:0];
                    end
                    else if (e.enable == 1'b0) begin
                        e.cons_ptr = data[15:0];
                    end
                end
                16'h4000: begin // SET_ENABLE (dequeue) - handled below
                    e.enable = data[0];
                end
                16'h8090: begin // SET_CONS_PTR
                    // The completion-queue side lets software advance the
                    // consumer pointer while enabled - that is how a driver
                    // reclaims completion entries (cpl_queue_manager.v:526-531).
                    if (flavor == REF_Q_ENQUEUE || e.enable == 1'b0)
                        e.cons_ptr = data[15:0];
                end
                default: ;
            endcase
        end
        else if (reg_sel == 3'd0) begin
            // BASE_ADDR low dword. Base address is 4 KB aligned; the RTL stores
            // bits [127:76] and appends 12 zero bits.
            e.base_addr[31:0] = {data[31:12], 12'h000};
        end
        else if (reg_sel == 3'd1) begin
            e.base_addr[63:32] = data;
        end
        return 1'b0;
    endfunction

    // -------------------------------------------------------------------------
    // Predict the response to a dequeue/enqueue request, and apply the state
    // change the DUT would make. Call exactly once per observed request.
    // -------------------------------------------------------------------------
    virtual function ref_queue_resp predict_request(bit [31:0] qidx);
        ref_queue_entry e;
        ref_queue_resp  r;
        bit             q_active;
        bit             q_empty;
        bit [15:0]      active_cons;
        bit [15:0]      size_mask;

        e = get_q(qidx);
        r = new();

        q_active = m_op_active[e.op_index] && (m_op_queue[e.op_index] == qidx);
        size_mask = 16'((32'd1 << e.log_queue_size) - 32'd1);

        if (flavor == REF_Q_DEQUEUE) begin
            active_cons = q_active ? m_op_ptr[e.op_index] : e.cons_ptr;
            q_empty     = q_active ? (e.prod_ptr == m_op_ptr[e.op_index])
                                   : (e.prod_ptr == e.cons_ptr);
        end
        else begin
            // Enqueue: speculate on the PRODUCER pointer and block on FULL.
            active_cons = q_active ? m_op_ptr[e.op_index] : e.prod_ptr;
            q_empty     = ((active_cons - e.cons_ptr) &
                           ~(16'((32'd1 << e.log_queue_size) - 32'd1))) != 16'd0;
        end

        r.queue   = qidx;
        r.ptr     = 32'(active_cons);
        r.phase   = ~active_cons[e.log_queue_size];
        r.addr    = (flavor == REF_Q_DEQUEUE)
                    ? e.base_addr + (64'(active_cons & size_mask)
                                     << (clog2_int(desc_size) + e.log_block_size))
                    : e.base_addr + 64'(active_cons & size_mask) * 64'(cpl_size);
        r.aux     = (flavor == REF_Q_DEQUEUE) ? 64'(e.log_block_size)
                                              : 64'(e.cpl_queue);           // event field
        // cpl_queue_manager has no resp_cpl port - its RAM [47:32] is the event,
        // already predicted in aux - and queue_op_monitor records 0 for that
        // flavour, so predicting cpl_queue here mismatched every enqueue.
        r.cpl     = (flavor == REF_Q_DEQUEUE) ? 32'(e.cpl_queue) : 32'd0;
        r.op_tag  = 16'(m_op_start);
        r.blocked = 1'b0;
        r.error   = 1'b0;

        if (!e.enable) begin
            r.error = 1'b1;                       // queue_manager.v:437
        end
        else if (q_empty) begin
            r.blocked = 1'b1;                     // queue_manager.v:443
        end
        else begin
            // Start the operation. queue_manager.v:451
            m_op_active[m_op_start] = 1'b1;
            m_op_commit[m_op_start] = 1'b0;
            m_op_queue[m_op_start]  = qidx;
            m_op_ptr[m_op_start]    = active_cons + 16'd1;   // :351
            e.op_index              = 8'(m_op_start);
            m_op_start              = (m_op_start + 1) % int'(op_table_size);
        end

        return r;
    endfunction

    // -------------------------------------------------------------------------
    virtual function void apply_commit(bit [15:0] op_tag);
        int t = int'(op_tag) % int'(op_table_size);
        if (!m_op_active[t]) begin
            `uvm_warning("ref_queue",
                $sformatf("commit of op_tag %0d that is not active", t))
        end
        m_op_commit[t] = 1'b1;
        retire();
    endfunction

    // -------------------------------------------------------------------------
    // In-order retirement. queue_manager.v:394 - the op at finish_ptr retires
    // only when it is both active and committed, so an out-of-order commit
    // parks until its predecessors catch up.
    // -------------------------------------------------------------------------
    protected virtual function void retire();
        ref_queue_entry e;
        while (m_op_active[m_op_finish] && m_op_commit[m_op_finish]) begin
            e = get_q(m_op_queue[m_op_finish]);
            // Dequeue retires the consumer pointer; enqueue the producer.
            if (flavor == REF_Q_DEQUEUE) begin
                e.cons_ptr = m_op_ptr[m_op_finish];
            end
            else begin
                e.prod_ptr = m_op_ptr[m_op_finish];
                // EVENT ON COMMIT when armed. The armed bit self-clears unless
                // the queue is continuous (cpl_queue_manager.v, 'generate event
                // on producer pointer update').
                if (e.armed) begin
                    push_notify(m_op_queue[m_op_finish], 64'(e.cpl_queue));
                    if (!e.continuous) e.armed = 1'b0;
                end
            end
            m_op_active[m_op_finish] = 1'b0;
            m_op_commit[m_op_finish] = 1'b0;
            m_op_finish              = (m_op_finish + 1) % int'(op_table_size);
        end
    endfunction

    // -------------------------------------------------------------------------
    // Observability for tests and coverage.
    // -------------------------------------------------------------------------
    virtual function int unsigned op_table_occupancy();
        int unsigned n = 0;
        foreach (m_op_active[i]) if (m_op_active[i]) n++;
        return n;
    endfunction

    virtual function bit op_table_full();
        return (op_table_occupancy() >= op_table_size);
    endfunction

    virtual function bit [15:0] cons_ptr(bit [31:0] qidx);
        return get_q(qidx).cons_ptr;
    endfunction

    virtual function bit [15:0] prod_ptr(bit [31:0] qidx);
        return get_q(qidx).prod_ptr;
    endfunction

    virtual function bit enabled(bit [31:0] qidx);
        return get_q(qidx).enable;
    endfunction

    // $clog2 rather than a `while ((1 << r) < int'(v))` loop: Vivado xsim 2026.1
    // mis-evaluates a cast inside a while condition and returned 0 for v=16,
    // so every predicted dequeue address lost its descriptor-size shift.
    protected function int clog2_int(int unsigned v);
        return $clog2(v);
    endfunction

endclass : ref_queue

`endif // REF_QUEUE_SV

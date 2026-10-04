// SPDX-License-Identifier: BSD-2-Clause-Views
//
// Tier 1a test suite - remaining seven tests
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §13 Tier 1a
// Introduced : Step 1, after t1a_reset / t1a_reg_access / t1a_dequeue_basic
//              passed on VCS
//
// OP_TAG PREDICTION. Several tests below commit by op_tag without observing the
// responses. That is safe because the DUT allocates op tags strictly
// sequentially from op_table_start_ptr, wrapping at OP_TABLE_SIZE
// (queue_manager.v:451, :628), and a tag is allocated ONLY when an operation
// actually starts - never on an error or empty response. Every request in these
// tests is arranged to succeed, so the k-th successful request carries
// op_tag == k % OP_TABLE_SIZE. The scoreboard independently checks the op_tag
// the DUT actually returned, so a wrong assumption here surfaces as a mismatch
// rather than as a silent pass.
// -----------------------------------------------------------------------------

`ifndef TIER1A_TESTS2_SV
`define TIER1A_TESTS2_SV

// -----------------------------------------------------------------------------
// t1a_enable_disable
//
// A request to a DISABLED queue must return error=1 / empty=0, allocate no
// op_tag, and advance nothing (queue_manager.v:437). A producer-pointer write
// while disabled must NOT raise a doorbell (:517 gates on enable).
// -----------------------------------------------------------------------------
class t1a_enable_disable extends tier1a_base_test;

    `uvm_component_utils(t1a_enable_disable)

    function new(string name = "t1a_enable_disable", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t1a_enable_disable");
        apply_power_on_reset();
        idle(10);

        // Configure but leave DISABLED.
        configure_queue_only(.q(32'd5),
                             .base_addr(64'h0000_0000_0020_0000),
                             .log_queue_size(4'd4),
                             .log_block_size(2'd0),
                             .cqn(16'd9));
        idle(10);

        // No doorbell expected - queue is disabled.
        set_prod_ptr(32'd5, 16'd4);
        idle(20);

        // Request must be rejected with error, not empty.
        dequeue_req(32'd5, 16'hB0);
        idle(20);

        // Enable, then the same queue must work. The producer pointer written
        // while disabled is still in the RAM, so the queue is non-empty.
        set_enable(32'd5, 1'b1);
        idle(10);

        // Now a producer-pointer write DOES raise a doorbell.
        set_prod_ptr(32'd5, 16'd4);
        idle(20);

        dequeue_req(32'd5, 16'hB1);
        idle(20);
        commit(16'd0);
        idle(20);

        // Disable again: subsequent requests return to error.
        set_enable(32'd5, 1'b0);
        idle(10);
        dequeue_req(32'd5, 16'hB2);
        idle(20);

        phase.drop_objection(this, "t1a_enable_disable");
    endtask

endclass : t1a_enable_disable


// -----------------------------------------------------------------------------
// t1a_dequeue_empty
//
// prod_ptr == cons_ptr means empty: empty=1, error=0, no op_tag allocated, no
// pointer movement (queue_manager.v:443). Repeating the request must give the
// same answer - an empty dequeue must not consume anything.
// -----------------------------------------------------------------------------
class t1a_dequeue_empty extends tier1a_base_test;

    `uvm_component_utils(t1a_dequeue_empty)

    function new(string name = "t1a_dequeue_empty", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t1a_dequeue_empty");
        apply_power_on_reset();
        idle(10);

        configure_queue(.q(32'd2),
                        .base_addr(64'h0000_0000_0030_0000),
                        .log_queue_size(4'd4),
                        .log_block_size(2'd0),
                        .cqn(16'd4));
        idle(10);

        // prod_ptr stays at its reset value of 0, equal to cons_ptr.
        // The write itself still raises a doorbell (enable is set).
        set_prod_ptr(32'd2, 16'd0);
        idle(20);

        // Three requests, all of which must report empty and change nothing.
        dequeue_req(32'd2, 16'hC0);
        idle(20);
        dequeue_req(32'd2, 16'hC1);
        idle(20);
        dequeue_req(32'd2, 16'hC2);
        idle(20);

        // Make one descriptor available; the next request must now succeed with
        // ptr == 0, proving the empty requests did not advance anything.
        set_prod_ptr(32'd2, 16'd1);
        idle(20);
        dequeue_req(32'd2, 16'hC3);
        idle(20);
        commit(16'd0);
        idle(20);

        // Back to empty.
        dequeue_req(32'd2, 16'hC4);
        idle(20);

        phase.drop_objection(this, "t1a_dequeue_empty");
    endtask

endclass : t1a_dequeue_empty


// -----------------------------------------------------------------------------
// t1a_commit_ordering
//
// Retirement is IN ORDER (queue_manager.v:394): the op at finish_ptr retires
// only when it is both active and committed. Committing 2 then 1 must advance
// NOTHING until 0 commits, at which point all three retire together.
//
// Observable through the response pointer: while ops are outstanding the DUT
// reports the speculative pointer, so the check that really bites is the
// request issued after the out-of-order commits.
// -----------------------------------------------------------------------------
class t1a_commit_ordering extends tier1a_base_test;

    `uvm_component_utils(t1a_commit_ordering)

    function new(string name = "t1a_commit_ordering", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t1a_commit_ordering");
        apply_power_on_reset();
        idle(10);

        configure_queue(.q(32'd7),
                        .base_addr(64'h0000_0000_0040_0000),
                        .log_queue_size(4'd5),
                        .log_block_size(2'd0),
                        .cqn(16'd11));
        idle(10);
        set_prod_ptr(32'd7, 16'd16);
        idle(20);

        // Three outstanding operations: op_tags 0, 1, 2 with ptr 0, 1, 2.
        dequeue_req(32'd7, 16'hD0);
        idle(20);
        dequeue_req(32'd7, 16'hD1);
        idle(20);
        dequeue_req(32'd7, 16'hD2);
        idle(20);

        // Commit OUT OF ORDER. Neither of these may retire anything.
        commit(16'd2);
        idle(20);
        commit(16'd1);
        idle(20);

        // Fourth request: speculative pointer must be 3 regardless of the
        // out-of-order commits above.
        dequeue_req(32'd7, 16'hD3);
        idle(20);

        // Committing 0 retires 0,1,2 together; committing 3 then retires 3.
        commit(16'd0);
        idle(20);
        commit(16'd3);
        idle(20);

        // Fifth request with nothing outstanding: the DUT must now report the
        // COMMITTED pointer, which is 4.
        dequeue_req(32'd7, 16'hD4);
        idle(20);
        commit(16'd4);
        idle(20);

        phase.drop_objection(this, "t1a_commit_ordering");
    endtask

endclass : t1a_commit_ordering


// -----------------------------------------------------------------------------
// t1a_op_table_full
//
// OP_TABLE_SIZE outstanding operations exhaust the table; the DUT must then
// back-pressure req_ready until a commit frees an entry.
//
// The second phase deliberately DEADLOCKS unless the DUT recovers: eight more
// requests are issued from one process while another process commits the first
// eight after a delay. If back-pressure or retirement is broken the test hangs
// and the UVM timeout fails it - which is the correct outcome, not a false pass.
// -----------------------------------------------------------------------------
class t1a_op_table_full extends tier1a_base_test;

    `uvm_component_utils(t1a_op_table_full)

    localparam int OP_TABLE_SIZE = 32;

    function new(string name = "t1a_op_table_full", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t1a_op_table_full");
        apply_power_on_reset();
        idle(10);

        // 256-entry ring with plenty of descriptors so nothing reports empty.
        configure_queue(.q(32'd4),
                        .base_addr(64'h0000_0000_0050_0000),
                        .log_queue_size(4'd8),
                        .log_block_size(2'd0),
                        .cqn(16'd6));
        idle(10);
        set_prod_ptr(32'd4, 16'd200);
        idle(20);

        // Phase 1: fill the op table exactly. All must complete.
        for (int i = 0; i < OP_TABLE_SIZE; i++)
            dequeue_req(32'd4, 16'(i));
        idle(50);
        `uvm_info(get_type_name(),
            $sformatf("op table filled with %0d outstanding operations", OP_TABLE_SIZE),
            UVM_LOW)

        // Phase 2: eight more requests against a full table, unblocked only by
        // commits arriving from a parallel process.
        fork
            begin : more_requests
                for (int i = 0; i < 8; i++)
                    dequeue_req(32'd4, 16'(100 + i));
            end
            begin : drain
                idle(40);
                for (int i = 0; i < 8; i++) begin
                    commit(16'(i));
                    idle(5);
                end
            end
        join
        idle(50);

        // Retire everything still outstanding: tags 8..31 then 0..7 reissued.
        for (int i = 8; i < OP_TABLE_SIZE; i++) begin
            commit(16'(i));
            idle(3);
        end
        for (int i = 0; i < 8; i++) begin
            commit(16'(i));
            idle(3);
        end
        idle(50);

        phase.drop_objection(this, "t1a_op_table_full");
    endtask

endclass : t1a_op_table_full


// -----------------------------------------------------------------------------
// t1a_ptr_wrap
//
// phase = !ptr[log_queue_size] (queue_manager.v:421). With log_queue_size = 2
// the ring holds 4 entries, so the phase bit flips when the pointer crosses 4
// and again at 8. Pointers themselves are free-running 16-bit counters; only
// the low log_queue_size bits index the ring, which is why the address must
// repeat every 4 entries while the phase alternates.
// -----------------------------------------------------------------------------
class t1a_ptr_wrap extends tier1a_base_test;

    `uvm_component_utils(t1a_ptr_wrap)

    function new(string name = "t1a_ptr_wrap", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t1a_ptr_wrap");
        apply_power_on_reset();
        idle(10);

        configure_queue(.q(32'd6),
                        .base_addr(64'h0000_0000_0060_0000),
                        .log_queue_size(4'd2),      // 4-entry ring
                        .log_block_size(2'd0),
                        .cqn(16'd3));
        idle(10);

        // Twelve descriptors: three full laps of the ring.
        set_prod_ptr(32'd6, 16'd12);
        idle(20);

        for (int i = 0; i < 12; i++) begin
            dequeue_req(32'd6, 16'(i));
            idle(15);
            commit(16'(i % 32));
            idle(10);
        end

        phase.drop_objection(this, "t1a_ptr_wrap");
    endtask

endclass : t1a_ptr_wrap


// -----------------------------------------------------------------------------
// t1a_doorbell
//
// CORRECTED SPEC. The original test plan said "doorbell fires once per enable
// transition". Reading queue_manager.v:509-519 showed that is wrong: the
// doorbell fires on a PRODUCER-POINTER WRITE, gated by the enable bit. See
// docs/bringup_log.md.
//
// Checks: one doorbell per producer-pointer write while enabled, none while
// disabled, and the source queue index is correct across several queues.
// -----------------------------------------------------------------------------
class t1a_doorbell extends tier1a_base_test;

    `uvm_component_utils(t1a_doorbell)

    function new(string name = "t1a_doorbell", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t1a_doorbell");
        apply_power_on_reset();
        idle(10);

        // Three queues, deliberately far apart so a truncated source index
        // would show up as a mismatch.
        configure_queue(.q(32'd0),    .base_addr(64'h0000_0000_0070_0000),
                        .log_queue_size(4'd4), .log_block_size(2'd0), .cqn(16'd0));
        configure_queue(.q(32'd100),  .base_addr(64'h0000_0000_0080_0000),
                        .log_queue_size(4'd4), .log_block_size(2'd0), .cqn(16'd1));
        configure_queue_only(.q(32'd4095), .base_addr(64'h0000_0000_0090_0000),
                             .log_queue_size(4'd4), .log_block_size(2'd0), .cqn(16'd2));
        idle(20);

        // Queue 4095 is still DISABLED - no doorbell may result.
        set_prod_ptr(32'd4095, 16'd4);
        idle(20);

        // Enabled queues: one doorbell per write, carrying the right source.
        set_prod_ptr(32'd0,   16'd1);
        idle(15);
        set_prod_ptr(32'd100, 16'd2);
        idle(15);
        set_prod_ptr(32'd0,   16'd3);
        idle(15);
        set_prod_ptr(32'd100, 16'd4);
        idle(15);

        // Repeated writes of the SAME value still raise a doorbell - the DUT
        // gates on the write, not on the value changing.
        set_prod_ptr(32'd0, 16'd3);
        idle(15);
        set_prod_ptr(32'd0, 16'd3);
        idle(20);

        // Enable 4095, then it too must produce doorbells.
        set_enable(32'd4095, 1'b1);
        idle(10);
        set_prod_ptr(32'd4095, 16'd5);
        idle(20);

        phase.drop_objection(this, "t1a_doorbell");
    endtask

endclass : t1a_doorbell


// -----------------------------------------------------------------------------
// t1a_random_stress
//
// Randomized traffic across several queues. Requests are issued in rounds and
// each round is fully committed before the next, which keeps op-tag prediction
// exact (see the file header) while still mixing queues, pointers and
// back-pressure.
//
// Register programming and dequeue traffic are kept in separate phases - the
// ordering assumption documented in env/sb_queue.sv.
// -----------------------------------------------------------------------------
class t1a_random_stress extends tier1a_base_test;

    `uvm_component_utils(t1a_random_stress)

    localparam int N_QUEUES       = 4;
    localparam int ROUNDS         = 20;
    localparam int REQS_PER_ROUND = 8;

    rand int unsigned seed_unused;   // keeps the class randomizable if extended

    function new(string name = "t1a_random_stress", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [31:0] qsel;
        int        tag_base;

        phase.raise_objection(this, "t1a_random_stress");
        apply_power_on_reset();
        idle(10);

        // Configuration phase.
        for (int q = 0; q < N_QUEUES; q++) begin
            configure_queue(.q(32'(q * 37)),                 // scatter the indices
                            .base_addr(64'h0000_0000_0100_0000 + (64'(q) << 16)),
                            .log_queue_size(4'd8),           // 256 entries
                            .log_block_size(2'(q % 4)),
                            .cqn(16'(q)));
            idle(5);
        end
        idle(20);

        for (int q = 0; q < N_QUEUES; q++) begin
            set_prod_ptr(32'(q * 37), 16'd250);
            idle(10);
        end
        idle(20);

        // Traffic phase.
        tag_base = 0;
        for (int r = 0; r < ROUNDS; r++) begin
            for (int i = 0; i < REQS_PER_ROUND; i++) begin
                qsel = 32'(($urandom_range(0, N_QUEUES - 1)) * 37);
                dequeue_req(qsel, 16'($urandom_range(0, 255)));
                idle($urandom_range(1, 6));
            end
            idle(30);

            for (int i = 0; i < REQS_PER_ROUND; i++) begin
                commit(16'((tag_base + i) % 32));
                idle($urandom_range(1, 4));
            end
            idle(20);

            tag_base = (tag_base + REQS_PER_ROUND) % 32;
        end
        idle(50);

        `uvm_info(get_type_name(),
            $sformatf("completed %0d rounds x %0d requests = %0d operations",
                      ROUNDS, REQS_PER_ROUND, ROUNDS * REQS_PER_ROUND), UVM_LOW)

        phase.drop_objection(this, "t1a_random_stress");
    endtask

endclass : t1a_random_stress


// -----------------------------------------------------------------------------
// t1a_cpl_enqueue_basic - cpl_queue_manager response path.
//
// Enqueue is the mirror of dequeue: the speculative pointer is the PRODUCER
// side, and the blocking condition is FULL, not empty
// (cpl_queue_manager.v:269-272). Two back-to-back requests with nothing
// committed prove the speculation, exactly as t1a_dequeue_basic does.
// -----------------------------------------------------------------------------
class t1a_cpl_enqueue_basic extends tier1a_base_test;

    `uvm_component_utils(t1a_cpl_enqueue_basic)

    function new(string name = "t1a_cpl_enqueue_basic", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_cq_sb.m_enable_end_check = 1'b1;   // this test DOES drive it
        m_env.m_sb.m_enable_end_check    = 1'b0;   // ...and not the dequeue side
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t1a_cpl_enqueue_basic");
        apply_power_on_reset();
        idle(10);

        cq_configure(.q(32'd3), .base_addr(64'h0000_0000_0200_0000),
                     .log_size(4'd4), .eqn(16'd5));
        idle(20);

        // Ring is empty, so enqueue must succeed. Two outstanding operations
        // exercise the speculative producer pointer.
        cq_enqueue_req(32'd3, 16'hE0);
        idle(20);
        cq_enqueue_req(32'd3, 16'hE1);
        idle(20);

        cq_commit(16'd0);
        idle(20);
        cq_commit(16'd1);
        idle(20);

        cq_enqueue_req(32'd3, 16'hE2);
        idle(20);
        cq_commit(16'd2);
        idle(30);

        phase.drop_objection(this, "t1a_cpl_enqueue_basic");
    endtask

endclass : t1a_cpl_enqueue_basic


// -----------------------------------------------------------------------------
// t1a_cpl_event - the arm/event state machine.
//
// Events fire from three places (cpl_queue_manager.v):
//   * commit-time retirement while armed, with `armed` self-clearing unless
//     the queue is continuous
//   * SET_ARM while enabled and prod != cons
//   * SET_CONS_PTR_ARM while enabled and prod != the new consumer pointer
//
// This is a genuine state machine, not a naming difference from the dequeue
// side's doorbell - which is why wiring this DUT needed the model extended
// first rather than reusing ref_queue as-is.
// -----------------------------------------------------------------------------
class t1a_cpl_event extends tier1a_base_test;

    `uvm_component_utils(t1a_cpl_event)

    function new(string name = "t1a_cpl_event", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_cq_sb.m_enable_end_check = 1'b1;
        m_env.m_sb.m_enable_end_check    = 1'b0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t1a_cpl_event");
        apply_power_on_reset();
        idle(10);

        cq_configure(.q(32'd7), .base_addr(64'h0000_0000_0300_0000),
                     .log_size(4'd4), .eqn(16'd9));
        idle(20);

        // Arm on an empty queue: prod == cons, so NO event yet.
        cq_set_arm(32'd7, 1'b1);
        idle(20);

        // Enqueue and commit: retirement advances prod_ptr while armed, so one
        // event fires and the armed bit self-clears.
        cq_enqueue_req(32'd7, 16'hF0);
        idle(20);
        cq_commit(16'd0);
        idle(30);

        // Now disarmed: a second enqueue+commit must NOT raise an event.
        cq_enqueue_req(32'd7, 16'hF1);
        idle(20);
        cq_commit(16'd1);
        idle(30);

        // Arm while prod != cons: fires immediately.
        cq_set_arm(32'd7, 1'b1);
        idle(30);

        // SET_CONS_PTR_ARM with the consumer pointer still behind the producer:
        // arms and fires in the same write.
        cq_set_cons_ptr(32'd7, 16'd1, 1'b1);
        idle(30);

        phase.drop_objection(this, "t1a_cpl_event");
    endtask

endclass : t1a_cpl_event


// -----------------------------------------------------------------------------
// t1a_cov_closure - the cg_queue bins the directed tests never reach.
//
//   * commit order: out-of-order commits at op tags in every bin, including
//     tag 0 committed ahead of tags 30/31 across the table wrap;
//   * outcome x queue: ok / empty / error at queue 0, a mid, a high and the
//     last queue (8191) - the existing tests only ever saw errors and empties
//     at low indices;
//   * outcome x occupancy: empty and error probes while 1, 8, 20 and 31
//     operations are outstanding;
//   * pointer wrap: the consumer pointer is set to 65533 while disabled, so the
//     dequeues walk 65533 -> 65534 -> 65535 -> 0, with every block size.
//
// Op tags are predicted exactly as the file header describes; m_tag counts the
// successful requests.
// -----------------------------------------------------------------------------
class t1a_cov_closure extends tier1a_base_test;

    `uvm_component_utils(t1a_cov_closure)

    localparam bit [31:0] Q_WORK     = 32'd9;      // the queue that carries ops
    localparam bit [31:0] Q_EMPTY    = 32'd1;      // enabled, never filled
    localparam bit [31:0] Q_DISABLED = 32'd2;      // configured, never enabled

    protected int unsigned m_tag;

    function new(string name = "t1a_cov_closure", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // n successful dequeues on Q_WORK, left outstanding.
    protected task issue(int n);
        repeat (n) begin
            dequeue_req(Q_WORK, 16'(m_tag));
            m_tag++;
            idle(4);
        end
        idle(10);
    endtask

    // One empty and one error response at the current occupancy. Neither
    // allocates an op tag.
    protected task probe();
        dequeue_req(Q_EMPTY, 16'hEE);
        idle(10);
        dequeue_req(Q_DISABLED, 16'hDD);
        idle(10);
    endtask

    protected task commit_tag(int unsigned tag);
        commit(16'(tag % 32));
        idle(6);
    endtask

    // Request and immediately commit - occupancy returns to zero.
    protected task ok_req(bit [31:0] q);
        dequeue_req(q, 16'(m_tag));
        idle(15);
        commit_tag(m_tag);
        m_tag++;
        idle(10);
    endtask

    protected task set_cons_ptr(bit [31:0] q, bit [15:0] ptr);
        axil_write(q_reg_addr(q, 2), 32'h8090_0000 | 32'(ptr));
    endtask

    virtual task run_phase(uvm_phase phase);
        bit [31:0] outcome_q [] = '{32'd0, 32'd1000, 32'd5000, 32'd8191};

        phase.raise_objection(this, "t1a_cov_closure");
        apply_power_on_reset();
        idle(10);
        m_tag = 0;

        configure_queue(Q_WORK, 64'h0000_0000_0A00_0000, 4'd8, 2'd0, 16'd1);
        configure_queue(Q_EMPTY, 64'h0000_0000_0A10_0000, 4'd4, 2'd0, 16'd2);
        configure_queue_only(Q_DISABLED, 64'h0000_0000_0A20_0000, 4'd4, 2'd0, 16'd3);
        idle(10);
        set_prod_ptr(Q_WORK, 16'd200);
        idle(20);

        // ---- occupancy 0, then commit order across the table ----------------
        probe();

        // Round A: tags 0..7. Probe at one and at eight outstanding, then
        // commit 7..1 (out of order, low tags) and 0.
        issue(1);
        probe();
        issue(7);
        probe();
        for (int t = 7; t >= 0; t--) commit_tag(t);
        idle(20);

        // Round B: tags 8..27, committed in reverse (mid and high tags).
        issue(20);
        probe();
        for (int t = 27; t >= 8; t--) commit_tag(t);
        idle(20);

        // Round C wraps the table: tags 28, 29, 30, 31, 0, 1. Committing 0,
        // 1, 31 and 29 ahead of 28 gives out-of-order first/low/last/high.
        issue(6);
        commit_tag(0);
        commit_tag(1);
        commit_tag(31);
        commit_tag(29);
        commit_tag(30);
        commit_tag(28);
        idle(20);

        // ---- near-full: 31 outstanding ---------------------------------------
        // Not probed at 32: a full table back-pressures every request
        // (t1a_op_table_full), so an empty/error response cannot be produced.
        issue(31);
        probe();
        issue(1);
        for (int i = 32; i > 0; i--) commit_tag(m_tag - i);
        idle(30);

        // ---- outcome x queue index ------------------------------------------
        foreach (outcome_q[i]) begin
            bit [31:0] q = outcome_q[i];
            configure_queue_only(q, 64'h0000_0000_0B00_0000 + (64'(i) << 16),
                                 4'd4, 2'd0, 16'(4 + i));
            idle(10);
            dequeue_req(q, 16'hE0);            // disabled -> error
            idle(15);
            set_enable(q, 1'b1);
            idle(10);
            set_prod_ptr(q, 16'd0);            // enabled, prod == cons -> empty
            idle(15);
            dequeue_req(q, 16'hE1);
            idle(15);
            set_prod_ptr(q, 16'd3);
            idle(15);
            ok_req(q);
        end

        // ---- pointer wrap at 65535, every block size -------------------------
        // The consumer pointer is only writable while disabled
        // (queue_manager.v:520). prod = 1 is four entries ahead of 65533.
        for (int bs = 0; bs < 4; bs++) begin
            bit [31:0] q = 32'd6000 + 32'(bs);
            configure_queue_only(q, 64'h0000_0000_0C00_0000 + (64'(bs) << 16),
                                 4'd2, 2'(bs), 16'(8 + bs));
            set_cons_ptr(q, 16'd65533);
            set_prod_ptr(q, 16'd1);
            set_enable(q, 1'b1);
            idle(15);
            repeat (4) ok_req(q);
        end
        idle(50);

        phase.drop_objection(this, "t1a_cov_closure");
    endtask

endclass : t1a_cov_closure

`endif // TIER1A_TESTS2_SV

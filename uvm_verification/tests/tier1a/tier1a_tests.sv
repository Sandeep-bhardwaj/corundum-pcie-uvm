// SPDX-License-Identifier: BSD-2-Clause-Views
//
// Tier 1a test suite (first three tests)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §13 Tier 1a
// Introduced : Step 1
//
// Register programming uses the MQNIC_QUEUE_CMD_* opcodes from
// modules/mqnic/mqnic_hw.h:333-349. The address layout is
// {queue[QUEUE_INDEX_WIDTH-1:0], reg[2:0], 2'b00}, giving eight dword registers
// per queue - which is why AXIL_ADDR_WIDTH == QUEUE_INDEX_WIDTH+5.
// -----------------------------------------------------------------------------

`ifndef TIER1A_TESTS_SV
`define TIER1A_TESTS_SV

class tier1a_base_test extends mqnic_base_test;

    `uvm_component_utils(tier1a_base_test)

    tier1a_env m_env;

    function new(string name = "tier1a_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        m_env = tier1a_env::type_id::create("m_env", this);
    endfunction

    // The two DUTs are independent, so a test that drives only one must not be
    // failed by the other scoreboard's "you checked nothing" drain rule.
    // Dequeue tests are the default; the cpl_* tests flip this.
    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_cq_sb.m_enable_end_check = 1'b0;
    endfunction

    // ---- cpl_queue_manager helpers -----------------------------------------
    // 4 dwords per queue here, not 8: AXIL_ADDR_WIDTH = QUEUE_INDEX_WIDTH+4.
    protected function bit [63:0] cq_reg_addr(bit [31:0] q, int unsigned r);
        return (64'(q) << 4) | (64'(r) << 2);
    endfunction

    protected task cq_axil_write(bit [63:0] addr, bit [31:0] data);
        axil_write_seq s = axil_write_seq::type_id::create("s");
        s.addr = addr;
        s.data = 64'(data);
        s.strb = 8'hF;
        s.start(m_env.m_cq_axil.sequencer);
    endtask

    protected task cq_configure(bit [31:0] q, bit [63:0] base_addr,
                                bit [3:0] log_size, bit [15:0] eqn);
        cq_axil_write(cq_reg_addr(q, 0), base_addr[31:0]);
        cq_axil_write(cq_reg_addr(q, 1), base_addr[63:32]);
        cq_axil_write(cq_reg_addr(q, 2), 32'h8002_0000 | 32'(log_size));
        cq_axil_write(cq_reg_addr(q, 2), 32'hC000_0000 | 32'(eqn));
        cq_axil_write(cq_reg_addr(q, 2), 32'h4000_0100 | 32'd1);   // SET_ENABLE
    endtask

    protected task cq_set_arm(bit [31:0] q, bit armed);
        cq_axil_write(cq_reg_addr(q, 2), 32'h4000_0200 | 32'(armed));
    endtask

    protected task cq_set_cons_ptr(bit [31:0] q, bit [15:0] ptr, bit arm = 1'b0);
        cq_axil_write(cq_reg_addr(q, 2),
                      (arm ? 32'h8091_0000 : 32'h8090_0000) | 32'(ptr));
    endtask

    protected task cq_enqueue_req(bit [31:0] q, bit [15:0] tag = 16'h0);
        queue_op_req_seq s = queue_op_req_seq::type_id::create("s");
        s.queue = q;
        s.tag   = tag;
        s.start(m_env.m_cq_qop.sequencer);
    endtask

    protected task cq_commit(bit [15:0] op_tag);
        queue_op_commit_seq s = queue_op_commit_seq::type_id::create("s");
        s.op_tag = op_tag;
        s.start(m_env.m_cq_qop.sequencer);
    endtask

    // ---- register helpers ---------------------------------------------------
    protected function bit [63:0] q_reg_addr(bit [31:0] q, int unsigned r);
        return (64'(q) << 5) | (64'(r) << 2);
    endfunction

    protected task axil_write(bit [63:0] addr, bit [31:0] data);
        axil_write_seq s = axil_write_seq::type_id::create("s");
        s.addr = addr;
        s.data = 64'(data);
        s.strb = 8'hF;
        s.start(m_env.m_axil.sequencer);
    endtask

    protected task axil_read(bit [63:0] addr, output bit [31:0] data);
        axil_read_seq s = axil_read_seq::type_id::create("s");
        s.addr = addr;
        s.start(m_env.m_axil.sequencer);
        data = 32'(s.data);
    endtask

    // Program one queue WITHOUT enabling it. Order matters - the DUT ignores a
    // consumer-pointer write while enabled, so all configuration must precede
    // the enable.
    protected task configure_queue_only(bit [31:0] q,
                                        bit [63:0] base_addr,
                                        bit [3:0]  log_queue_size,
                                        bit [1:0]  log_block_size,
                                        bit [15:0] cqn);
        axil_write(q_reg_addr(q, 0), base_addr[31:0]);
        axil_write(q_reg_addr(q, 1), base_addr[63:32]);
        axil_write(q_reg_addr(q, 2), 32'h8002_0000 | 32'(log_queue_size)
                                                   | (32'(log_block_size) << 8));
        axil_write(q_reg_addr(q, 2), 32'hC000_0000 | 32'(cqn));
    endtask

    // MQNIC_QUEUE_CMD_SET_ENABLE, with the value in data[0].
    protected task set_enable(bit [31:0] q, bit en);
        axil_write(q_reg_addr(q, 2), 32'h4000_0100 | 32'(en));
    endtask

    // Configure and enable, the common case.
    protected task configure_queue(bit [31:0] q,
                                   bit [63:0] base_addr,
                                   bit [3:0]  log_queue_size,
                                   bit [1:0]  log_block_size,
                                   bit [15:0] cqn);
        configure_queue_only(q, base_addr, log_queue_size, log_block_size, cqn);
        set_enable(q, 1'b1);
    endtask

    protected task set_prod_ptr(bit [31:0] q, bit [15:0] ptr);
        axil_write(q_reg_addr(q, 2), 32'h8080_0000 | 32'(ptr));
    endtask

    protected task dequeue_req(bit [31:0] q, bit [15:0] tag = 16'h00);
        queue_op_req_seq s = queue_op_req_seq::type_id::create("s");
        s.queue = q;
        s.tag   = tag;
        s.start(m_env.m_qop.sequencer);
    endtask

    protected task commit(bit [15:0] op_tag);
        queue_op_commit_seq s = queue_op_commit_seq::type_id::create("s");
        s.op_tag = op_tag;
        s.start(m_env.m_qop.sequencer);
    endtask

    protected task idle(int n);
        repeat (n) @(posedge m_rst_vif.clk);
    endtask

endclass : tier1a_base_test


// -----------------------------------------------------------------------------
// t1a_reset - reset behaviour only.
//
// The scoreboard's end-of-test drain check is DISABLED here: this test performs
// no transactions by design, and the default "at least one comparison" rule
// (mqnic_scoreboard_base §11) would otherwise fail it. That rule exists to catch
// tests that silently check nothing; this is the documented exception.
// -----------------------------------------------------------------------------
class t1a_reset extends tier1a_base_test;

    `uvm_component_utils(t1a_reset)

    function new(string name = "t1a_reset", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_sb.m_enable_end_check = 1'b0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t1a_reset");
        apply_power_on_reset();
        idle(50);
        // A second reset mid-run must also leave the DUT quiescent.
        m_rst_vif.inject_reset(5);
        idle(50);
        phase.drop_objection(this, "t1a_reset");
    endtask

endclass : t1a_reset


// -----------------------------------------------------------------------------
// t1a_reg_access - program a queue and prove the register path works.
//
// The producer-pointer write at the end is what makes this test CHECK something:
// it must generate exactly one doorbell (queue_manager.v:509), which the
// scoreboard compares against the reference model.
// -----------------------------------------------------------------------------
class t1a_reg_access extends tier1a_base_test;

    `uvm_component_utils(t1a_reg_access)

    function new(string name = "t1a_reg_access", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [31:0] rdata;

        phase.raise_objection(this, "t1a_reg_access");
        apply_power_on_reset();
        idle(10);

        configure_queue(.q(32'd3),
                        .base_addr(64'h0000_0000_1234_5000),
                        .log_queue_size(4'd4),      // 16 entries
                        .log_block_size(2'd0),
                        .cqn(16'd7));
        idle(10);

        // Readback of CTRL_STATUS. Not scoreboarded - the RAL at Tier 5 owns
        // register mirroring; here we only log it for triage.
        axil_read(q_reg_addr(32'd3, 2), rdata);
        `uvm_info(get_type_name(),
            $sformatf("queue 3 CTRL_STATUS readback = 0x%08h", rdata), UVM_LOW)

        // Must produce exactly one doorbell for queue 3.
        set_prod_ptr(32'd3, 16'd8);
        idle(20);

        phase.drop_objection(this, "t1a_reg_access");
    endtask

endclass : t1a_reg_access


// -----------------------------------------------------------------------------
// t1a_dequeue_basic - one full dequeue, then commit.
//
// Expected, from ref_queue:
//   request 1 : ptr=0, phase=!0[4]=1, addr=base, empty=0, error=0, op_tag=0
//   request 2 : ptr=1 via the SPECULATIVE active_cons_ptr, since op 0 is still
//               outstanding (queue_manager.v:272). A model that returned
//               cons_ptr would predict 0 again and this test would fail.
// -----------------------------------------------------------------------------
class t1a_dequeue_basic extends tier1a_base_test;

    `uvm_component_utils(t1a_dequeue_basic)

    function new(string name = "t1a_dequeue_basic", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t1a_dequeue_basic");
        apply_power_on_reset();
        idle(10);

        configure_queue(.q(32'd1),
                        .base_addr(64'h0000_0000_0010_0000),
                        .log_queue_size(4'd4),
                        .log_block_size(2'd0),
                        .cqn(16'd2));
        idle(10);

        // Four descriptors available.
        set_prod_ptr(32'd1, 16'd4);
        idle(20);

        // Two back-to-back dequeues with nothing committed in between - this is
        // what exercises the speculative pointer.
        dequeue_req(32'd1, 16'hA0);
        idle(20);
        dequeue_req(32'd1, 16'hA1);
        idle(20);

        // Retire in order.
        commit(16'd0);
        idle(10);
        commit(16'd1);
        idle(20);

        // Queue should now report two entries consumed; a third dequeue must
        // still succeed (prod=4, cons=2).
        dequeue_req(32'd1, 16'hA2);
        idle(20);
        commit(16'd2);
        idle(20);

        phase.drop_objection(this, "t1a_dequeue_basic");
    endtask

endclass : t1a_dequeue_basic

`endif // TIER1A_TESTS_SV

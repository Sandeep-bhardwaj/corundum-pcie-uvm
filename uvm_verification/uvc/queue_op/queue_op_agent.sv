// SPDX-License-Identifier: BSD-2-Clause-Views
//
// queue_op_sequencer / queue_op_agent / queue_op_seq_lib
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.8, §12.1 Level 0
// Introduced : Step 1 (Tier 1a)
// -----------------------------------------------------------------------------

`ifndef QUEUE_OP_AGENT_SV
`define QUEUE_OP_AGENT_SV

typedef uvm_sequencer #(queue_op_item) queue_op_sequencer;

class queue_op_agent extends uvm_agent;

    `uvm_component_utils(queue_op_agent)

    queue_op_cfg       cfg;

    queue_op_sequencer sequencer;
    queue_op_driver    driver;
    queue_op_monitor   monitor;

    uvm_analysis_port #(queue_op_item) req_ap;
    uvm_analysis_port #(queue_op_item) resp_ap;
    uvm_analysis_port #(queue_op_item) commit_ap;
    uvm_analysis_port #(queue_op_item) notify_ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db #(queue_op_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "no queue_op_cfg in config_db under key 'cfg'")
        uvm_config_db #(queue_op_cfg)::set(this, "*", "cfg", cfg);

        monitor = queue_op_monitor::type_id::create("monitor", this);

        if (cfg.is_active()) begin
            sequencer = queue_op_sequencer::type_id::create("sequencer", this);
            driver    = queue_op_driver::type_id::create("driver", this);
        end
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        req_ap    = monitor.req_ap;
        resp_ap   = monitor.resp_ap;
        commit_ap = monitor.commit_ap;
        notify_ap = monitor.notify_ap;
        if (cfg.is_active())
            driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction

endclass : queue_op_agent


// =============================================================================
// Sequence library (Level 0)
// =============================================================================

// Single request.
class queue_op_req_seq extends mqnic_base_seq #(queue_op_item);

    `uvm_object_utils(queue_op_req_seq)

    rand bit [31:0] queue;
    rand bit [15:0] tag;

    function new(string name = "queue_op_req_seq");
        super.new(name);
    endfunction

    virtual task body();
        queue_op_item it;
        it = queue_op_item::type_id::create("it");
        start_item(it);
        if (!it.randomize() with { kind  == QOP_REQ;
                                   queue == local::queue;
                                   tag   == local::tag; })
            `uvm_fatal(get_type_name(), "randomize failed")
        finish_item(it);
        it.wait_driven();
    endtask

endclass : queue_op_req_seq


// Single commit.
class queue_op_commit_seq extends mqnic_base_seq #(queue_op_item);

    `uvm_object_utils(queue_op_commit_seq)

    rand bit [15:0] op_tag;

    function new(string name = "queue_op_commit_seq");
        super.new(name);
    endfunction

    virtual task body();
        queue_op_item it;
        it = queue_op_item::type_id::create("it");
        start_item(it);
        if (!it.randomize() with { kind == QOP_COMMIT;
                                   commit_op_tag == local::op_tag; })
            `uvm_fatal(get_type_name(), "randomize failed")
        finish_item(it);
        it.wait_driven();
    endtask

endclass : queue_op_commit_seq


// -----------------------------------------------------------------------------
// Burst of requests without committing any of them. This is how the op table is
// driven to full: the DUT allocates an op_tag per outstanding request and can
// only reclaim it on commit. Used by t1a_op_table_full.
//
// n_reqs defaults ABOVE OP_TABLE_SIZE so the fill actually happens; a value at
// or below the table size would never exercise the back-pressure path.
// -----------------------------------------------------------------------------
class queue_op_fill_table_seq extends mqnic_base_seq #(queue_op_item);

    `uvm_object_utils(queue_op_fill_table_seq)

    rand int unsigned n_reqs;
    rand bit [31:0]   queue_lo;
    rand bit [31:0]   queue_hi;

    constraint c_defaults {
        soft n_reqs   == 40;      // > default OP_TABLE_SIZE of 32
        soft queue_lo == 0;
        soft queue_hi == 7;
        queue_hi >= queue_lo;
    }

    function new(string name = "queue_op_fill_table_seq");
        super.new(name);
    endfunction

    virtual task body();
        queue_op_item it;
        for (int i = 0; i < int'(n_reqs); i++) begin
            if (stop_requested()) break;
            it = queue_op_item::type_id::create($sformatf("req%0d", i));
            start_item(it);
            if (!it.randomize() with {
                    kind  == QOP_REQ;
                    queue inside {[local::queue_lo : local::queue_hi]};
                    delay == 0;                 // fill as fast as the DUT allows
                })
                `uvm_fatal(get_type_name(), "randomize failed")
            finish_item(it);
            it.wait_driven();
        end
    endtask

endclass : queue_op_fill_table_seq


// -----------------------------------------------------------------------------
// Randomized request stream over a queue window.
// -----------------------------------------------------------------------------
class queue_op_random_seq extends mqnic_base_seq #(queue_op_item);

    `uvm_object_utils(queue_op_random_seq)

    rand int unsigned n_reqs;
    rand bit [31:0]   queue_lo;
    rand bit [31:0]   queue_hi;

    constraint c_defaults {
        soft n_reqs   inside {[32:128]};
        soft queue_lo == 0;
        soft queue_hi == 15;
        queue_hi >= queue_lo;
    }

    function new(string name = "queue_op_random_seq");
        super.new(name);
    endfunction

    virtual task body();
        queue_op_item it;
        for (int i = 0; i < int'(n_reqs); i++) begin
            if (stop_requested()) break;
            it = queue_op_item::type_id::create($sformatf("req%0d", i));
            start_item(it);
            if (!it.randomize() with {
                    kind  == QOP_REQ;
                    queue inside {[local::queue_lo : local::queue_hi]};
                })
                `uvm_fatal(get_type_name(), "randomize failed")
            finish_item(it);
            it.wait_driven();
        end
    endtask

endclass : queue_op_random_seq

`endif // QUEUE_OP_AGENT_SV

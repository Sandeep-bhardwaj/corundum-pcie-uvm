// SPDX-License-Identifier: BSD-2-Clause-Views
//
// cov_queue - Tier 1a functional coverage
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §14.2 (Tier 1a coverage model),
//                                        §14.1 (principles)
// Introduced : Step 1 (Tier 1a)
//
// STRATEGY §14.1, and the reason this is a separate component rather than
// covergroups bolted onto the scoreboard:
//
//   "Every covergroup is sampled from a MONITOR analysis port, never from
//    driver stimulus - stimulus coverage measures the testbench, not the DUT."
//
// So everything here samples observed traffic. If a sequence asks for something
// the DUT refuses, that bin stays empty, which is the honest answer.
//
// op_table occupancy is read from the shared ref_queue rather than recomputed,
// so coverage and checking can never disagree about how full the table is.
// -----------------------------------------------------------------------------

`ifndef CG_QUEUE_SV
`define CG_QUEUE_SV

`uvm_analysis_imp_decl(_cov_resp)
`uvm_analysis_imp_decl(_cov_commit)
`uvm_analysis_imp_decl(_cov_notify)

class cov_queue extends uvm_component;

    `uvm_component_utils(cov_queue)

    uvm_analysis_imp_cov_resp   #(queue_op_item, cov_queue) resp_imp;
    uvm_analysis_imp_cov_commit #(queue_op_item, cov_queue) commit_imp;
    uvm_analysis_imp_cov_notify #(queue_op_item, cov_queue) notify_imp;

    // Shared with sb_queue - see file header.
    ref_queue    m_ref;
    queue_op_cfg m_cfg;

    // ---- sample variables ---------------------------------------------------
    protected bit [31:0] s_queue;
    protected bit [15:0] s_ptr;
    protected bit        s_phase;
    protected bit [1:0]  s_block_size;
    protected bit        s_blocked;
    protected bit        s_error;
    protected int        s_occupancy;
    protected bit [15:0] s_op_tag;
    protected bit        s_in_order_commit;
    protected bit [31:0] s_doorbell_q;

    // Next op_tag expected to retire, used to classify commit ordering, and
    // the tags committed ahead of it. Retirement is in order
    // (queue_manager.v:394): committing the oldest tag retires it AND every
    // already-committed tag behind it. Advancing by one per in-order commit,
    // as the first version did, fell behind after any out-of-order run and then
    // called every later in-order commit "out of order".
    protected int        m_expect_finish;
    protected bit        m_committed [32];

    // -------------------------------------------------------------------------
    // Response coverage. The cross at the bottom is the point of the whole
    // group: an outcome observed at only one queue index or only one occupancy
    // level is not really verified.
    // -------------------------------------------------------------------------
    covergroup cg_response;
        option.per_instance = 1;
        option.name         = "cg_response";

        cp_queue : coverpoint s_queue {
            bins zero    = {0};
            bins low     = {[1:15]};
            bins mid     = {[16:2047]};
            bins high    = {[2048:8190]};
            bins maximum = {8191};              // 2**13 - 1
        }

        // The three mutually exclusive outcomes of a request
        // (queue_manager.v:437 / :443 / :451).
        cp_outcome : coverpoint {s_error, s_blocked} {
            bins ok    = {2'b00};
            bins empty = {2'b01};
            bins error = {2'b10};
            illegal_bins both = {2'b11};        // error and empty are exclusive
        }

        cp_phase : coverpoint s_phase {
            bins zero = {0};
            bins one  = {1};
        }

        // log_block_size reaches the address formula, so all four values matter.
        cp_block_size : coverpoint s_block_size {
            bins b[] = {[0:3]};
        }

        cp_occupancy : coverpoint s_occupancy {
            bins empty_tbl = {0};
            bins one       = {1};
            bins few       = {[2:15]};
            bins many      = {[16:30]};
            bins near_full = {31};
            bins full      = {32};
        }

        cp_ptr_wrap : coverpoint s_ptr {
            bins zero     = {0};
            bins low      = {[1:3]};
            bins mid      = {[4:255]};
            bins high     = {[256:65534]};
            bins maximum  = {65535};
        }

        x_outcome_queue     : cross cp_outcome, cp_queue;
        x_outcome_occupancy : cross cp_outcome, cp_occupancy {
            // Occupancy is read from ref_queue after sb_queue has allocated
            // this request's own op, so a successful response is never at 0.
            ignore_bins ok_counts_itself = binsof(cp_outcome.ok) && binsof(cp_occupancy.empty_tbl);
            // No request is accepted while the next op slot is active
            // (queue_manager.v:404), so a full table answers nothing.
            ignore_bins full_accepts_none = !binsof(cp_outcome.ok) && binsof(cp_occupancy.full);
        }
        x_phase_block       : cross cp_phase, cp_block_size;
    endgroup

    // -------------------------------------------------------------------------
    // Commit coverage. In-order versus out-of-order is the behaviour
    // t1a_commit_ordering targets, so it needs its own evidence.
    // -------------------------------------------------------------------------
    covergroup cg_commit;
        option.per_instance = 1;
        option.name         = "cg_commit";

        cp_order : coverpoint s_in_order_commit {
            bins in_order     = {1};
            bins out_of_order = {0};
        }

        cp_op_tag : coverpoint s_op_tag {
            bins first = {0};
            bins low   = {[1:7]};
            bins mid   = {[8:23]};
            bins high  = {[24:30]};
            bins last  = {31};
        }

        x_order_tag : cross cp_order, cp_op_tag;
    endgroup

    // -------------------------------------------------------------------------
    covergroup cg_doorbell;
        option.per_instance = 1;
        option.name         = "cg_doorbell";

        cp_source : coverpoint s_doorbell_q {
            bins zero    = {0};
            bins low     = {[1:15]};
            bins mid     = {[16:2047]};
            bins high    = {[2048:8190]};
            bins maximum = {8191};
        }
    endgroup

    // -------------------------------------------------------------------------
    function new(string name, uvm_component parent);
        super.new(name, parent);
        resp_imp   = new("resp_imp", this);
        commit_imp = new("commit_imp", this);
        notify_imp = new("notify_imp", this);
        cg_response = new();
        cg_response.set_inst_name({get_full_name(), ".cg_response"});
        cg_commit   = new();
        cg_commit.set_inst_name({get_full_name(), ".cg_commit"});
        cg_doorbell = new();
        cg_doorbell.set_inst_name({get_full_name(), ".cg_doorbell"});
        m_expect_finish = 0;
    endfunction

    virtual function void write_cov_resp(queue_op_item t);
        s_queue      = t.queue;
        s_ptr        = 16'(t.ptr);
        s_phase      = t.phase;
        s_block_size = 2'(t.aux);
        s_blocked    = t.blocked;
        s_error      = t.error;
        s_occupancy  = (m_ref != null) ? int'(m_ref.op_table_occupancy()) : 0;
        cg_response.sample();
    endfunction

    virtual function void write_cov_commit(queue_op_item t);
        s_op_tag          = t.commit_op_tag;
        s_in_order_commit = (int'(t.commit_op_tag) == m_expect_finish);
        m_committed[t.commit_op_tag % 32] = 1'b1;
        while (m_committed[m_expect_finish]) begin
            m_committed[m_expect_finish] = 1'b0;
            m_expect_finish = (m_expect_finish + 1) % 32;
        end
        cg_commit.sample();
    endfunction

    virtual function void write_cov_notify(queue_op_item t);
        s_doorbell_q = t.notify_source;
        cg_doorbell.sample();
    endfunction

    // -------------------------------------------------------------------------
    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf("coverage: response=%.1f%% commit=%.1f%% doorbell=%.1f%%",
                      cg_response.get_inst_coverage(),
                      cg_commit.get_inst_coverage(),
                      cg_doorbell.get_inst_coverage()), UVM_LOW)
    endfunction

endclass : cov_queue

`endif // CG_QUEUE_SV

// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tier1a_env - Tier 1a environment
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §5 Tier 1a, §11
// Introduced : Step 1 (Tier 1a)
//
//   axil_agent    (MODE_ACTIVE_MASTER) -> queue_manager s_axil_*
//   queue_op_agent(MODE_ACTIVE_MASTER) -> dequeue req/resp/commit + doorbell
//   sb_queue                            -> ref_queue-based checking
// -----------------------------------------------------------------------------

`ifndef TIER1A_ENV_SV
`define TIER1A_ENV_SV

class tier1a_vseqr extends uvm_sequencer;
    `uvm_component_utils(tier1a_vseqr)

    axil_sequencer     axil_seqr;
    queue_op_sequencer qop_seqr;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
endclass : tier1a_vseqr


class tier1a_env extends uvm_env;

    `uvm_component_utils(tier1a_env)

    axil_cfg        m_axil_cfg;
    queue_op_cfg    m_qop_cfg;

    axil_agent      m_axil;
    queue_op_agent  m_qop;
    sb_queue        m_sb;
    cov_queue       m_cov;
    tier1a_vseqr    m_vseqr;

    // ---- second DUT: cpl_queue_manager (enqueue side) -----------------------
    axil_cfg        m_cq_axil_cfg;
    queue_op_cfg    m_cq_qop_cfg;
    axil_agent      m_cq_axil;
    queue_op_agent  m_cq_qop;
    sb_queue        m_cq_sb;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // Config objects may be supplied by the test; otherwise defaults that
        // match the Tier 1a golden configuration (STRATEGY §2.3) are used.
        if (!uvm_config_db #(axil_cfg)::get(this, "", "axil_cfg", m_axil_cfg)) begin
            m_axil_cfg            = axil_cfg::type_id::create("m_axil_cfg");
            m_axil_cfg.mode       = MODE_ACTIVE_MASTER;
            m_axil_cfg.addr_width = 18;   // QUEUE_INDEX_WIDTH(13) + 5
            m_axil_cfg.data_width = 32;
        end
        if (!uvm_config_db #(queue_op_cfg)::get(this, "", "qop_cfg", m_qop_cfg)) begin
            m_qop_cfg = queue_op_cfg::type_id::create("m_qop_cfg");
            m_qop_cfg.mode = MODE_ACTIVE_MASTER;
            m_qop_cfg.apply_flavor(QOP_DEQUEUE);
            m_qop_cfg.queue_width   = 13;
            m_qop_cfg.tag_width     = 8;
            m_qop_cfg.op_tag_width  = 8;
            m_qop_cfg.ptr_width     = 16;
            m_qop_cfg.addr_width    = 64;
            m_qop_cfg.cpl_width     = 8;
            m_qop_cfg.op_table_size = 32;
        end

        uvm_config_db #(axil_cfg)::set(this, "m_axil", "cfg", m_axil_cfg);
        uvm_config_db #(queue_op_cfg)::set(this, "m_qop", "cfg", m_qop_cfg);

        m_axil  = axil_agent::type_id::create("m_axil", this);
        m_qop   = queue_op_agent::type_id::create("m_qop", this);
        m_sb    = sb_queue::type_id::create("m_sb", this);
        m_cov   = cov_queue::type_id::create("m_cov", this);
        m_vseqr = tier1a_vseqr::type_id::create("m_vseqr", this);

        // ---- cpl_queue_manager --------------------------------------------
        // AXIL_ADDR_WIDTH is QUEUE_INDEX_WIDTH+4 here, not +5: the enqueue side
        // has a 4-dword register map. ref_queue applies the matching shift.
        m_cq_axil_cfg            = axil_cfg::type_id::create("m_cq_axil_cfg");
        m_cq_axil_cfg.mode       = MODE_ACTIVE_MASTER;
        m_cq_axil_cfg.addr_width = 12;      // 8 + 4
        m_cq_axil_cfg.data_width = 32;

        m_cq_qop_cfg = queue_op_cfg::type_id::create("m_cq_qop_cfg");
        m_cq_qop_cfg.mode = MODE_ACTIVE_MASTER;
        m_cq_qop_cfg.apply_flavor(QOP_ENQUEUE);   // sets notify_has_ready = 1
        m_cq_qop_cfg.queue_width   = 8;
        m_cq_qop_cfg.tag_width     = 8;
        m_cq_qop_cfg.op_tag_width  = 8;
        m_cq_qop_cfg.ptr_width     = 16;
        m_cq_qop_cfg.addr_width    = 64;
        m_cq_qop_cfg.aux_width     = 8;           // EVENT_WIDTH
        m_cq_qop_cfg.op_table_size = 32;

        uvm_config_db #(axil_cfg)::set(this, "m_cq_axil", "cfg", m_cq_axil_cfg);
        uvm_config_db #(queue_op_cfg)::set(this, "m_cq_qop", "cfg", m_cq_qop_cfg);

        m_cq_axil = axil_agent::type_id::create("m_cq_axil", this);
        m_cq_qop  = queue_op_agent::type_id::create("m_cq_qop", this);
        m_cq_sb   = sb_queue::type_id::create("m_cq_sb", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        m_sb.m_ref.configure(m_qop_cfg.queue_width,
                             m_qop_cfg.op_table_size,
                             16,                       // DESC_SIZE
                             m_qop_cfg.ptr_width);

        m_axil.wr_ap.connect(m_sb.axil_wr_imp);
        m_qop.req_ap.connect(m_sb.qop_req_imp);
        m_qop.resp_ap.connect(m_sb.qop_resp_imp);
        m_qop.commit_ap.connect(m_sb.qop_commit_imp);
        m_qop.notify_ap.connect(m_sb.qop_notify_imp);

        // Coverage shares the scoreboard's reference model so the two can never
        // disagree about op-table occupancy (cov/cg_queue.sv header).
        m_cov.m_ref = m_sb.m_ref;
        m_cov.m_cfg = m_qop_cfg;
        m_qop.resp_ap.connect(m_cov.resp_imp);
        m_qop.commit_ap.connect(m_cov.commit_imp);
        m_qop.notify_ap.connect(m_cov.notify_imp);

        m_vseqr.axil_seqr = m_axil.sequencer;
        m_vseqr.qop_seqr  = m_qop.sequencer;

        // ---- cpl_queue_manager checking ------------------------------------
        m_cq_sb.m_ref.flavor = REF_Q_ENQUEUE;
        m_cq_sb.m_ref.configure(m_cq_qop_cfg.queue_width,
                                m_cq_qop_cfg.op_table_size,
                                16,
                                m_cq_qop_cfg.ptr_width);
        m_cq_sb.m_ref.flavor   = REF_Q_ENQUEUE;   // configure() calls reset()
        m_cq_sb.m_ref.cpl_size = 32;              // must match CQ_CPL_SIZE in the top

        m_cq_axil.wr_ap.connect(m_cq_sb.axil_wr_imp);
        m_cq_qop.req_ap.connect(m_cq_sb.qop_req_imp);
        m_cq_qop.resp_ap.connect(m_cq_sb.qop_resp_imp);
        m_cq_qop.commit_ap.connect(m_cq_sb.qop_commit_imp);
        m_cq_qop.notify_ap.connect(m_cq_sb.qop_notify_imp);
    endfunction

endclass : tier1a_env

`endif // TIER1A_ENV_SV

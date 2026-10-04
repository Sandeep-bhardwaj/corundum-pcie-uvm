// SPDX-License-Identifier: BSD-2-Clause-Views
//
// sb_rq - Tier 4c scoreboard (pcie_us_if_rq)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §11, §10 (ref_tlp_shim, ref_rq_arb)
// Introduced : Step 6 (Tier 4c)
//
// TWO INPUT STREAMS, ONE OUTPUT - which changes the checking in two ways.
//
// 1. MATCHING CANNOT BE POSITIONAL. Read and write requests merge onto one RQ
//    channel, so an observed TLP has to be matched against the head of EITHER
//    expected queue by content. That is the same set-versus-sequence argument
//    as sb_dma, arrived at for a different reason: there it was concurrency,
//    here it is a merge.
//
// 2. PRIORITY IS NOT BLACK-BOX CHECKABLE HERE, and the first version of this
//    scoreboard got that wrong. It asserted "a read was pending, so a read must
//    come out" using its OWN queue depth as the definition of pending.
//
//    The DUT's arbiter does not look at what the scoreboard has seen. It looks
//    at PER-PORT FIFO OCCUPANCY - pcie_us_if_rq instantiates a pcie_tlp_fifo_raw
//    per port (:314, :384) and arbitrates on fifo_tlp_valid[port] (:513). A TLP
//    accepted at the input is not yet at the arbiter, so "pending in the
//    scoreboard" and "available to the arbiter" are separated by a FIFO of
//    unknown occupancy.
//
//    That check reported 17 failures on a run where all 60 TLPs converted
//    correctly and none were lost. It was measuring the model's ignorance of
//    the pipeline, not the DUT.
//
//    WHAT IS CHECKED INSTEAD is the credit rule, which IS observable: a TLP
//    from a port whose credit is below threshold must never appear. That is the
//    property flow control actually guarantees, and it is timing-independent.
//
// SILENCE IS ALSO CHECKED. When neither port has credit the DUT must transmit
// NOTHING, and a scoreboard that only inspects what did appear passes that
// trivially. expect_silence() makes the absence a positive check.
// -----------------------------------------------------------------------------

`ifndef SB_RQ_SV
`define SB_RQ_SV

`uvm_analysis_imp_decl(_rq_rd)
`uvm_analysis_imp_decl(_rq_wr)
`uvm_analysis_imp_decl(_rq_out)

class sb_rq extends mqnic_scoreboard_base;

    `uvm_component_utils(sb_rq)

    uvm_analysis_imp_rq_rd  #(pcie_tlp_item,                       sb_rq) rd_imp;
    uvm_analysis_imp_rq_wr  #(pcie_tlp_item,                       sb_rq) wr_imp;
    uvm_analysis_imp_rq_out #(pcie_us_axis_pkg::pcie_us_axis_item, sb_rq) out_imp;

    ref_tlp_shim m_shim;
    ref_rq_arb   m_arb;

    // Predicted Xilinx DWORD streams, one queue per source port.
    protected bit [31:0] m_exp_rd [$][];
    protected bit [31:0] m_exp_wr [$][];

    // When set, no RQ TLP may appear at all.
    bit expect_silence = 1'b0;

    protected int unsigned m_n_rd;
    protected int unsigned m_n_wr;
    protected int unsigned m_n_out;
    protected int unsigned m_n_credit_bad;

    cg_rq cov;               // optional functional coverage
    protected int unsigned m_n_from_rd;
    protected int unsigned m_n_from_wr;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        rd_imp  = new("rd_imp", this);
        wr_imp  = new("wr_imp", this);
        out_imp = new("out_imp", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (m_shim == null) m_shim = ref_tlp_shim::type_id::create("m_shim");
        if (m_arb  == null) m_arb  = ref_rq_arb::type_id::create("m_arb");
    endfunction

    virtual function int unsigned from_read();  return m_n_from_rd; endfunction
    virtual function int unsigned from_write(); return m_n_from_wr; endfunction

    virtual function int unsigned pending_count();
        return m_exp_rd.size() + m_exp_wr.size();
    endfunction

    // -------------------------------------------------------------------------
    protected virtual function void predict(pcie_tlp_item t, ref bit [31:0] dw[]);
        bit [127:0]  desc = m_shim.rq_encode(t.hdr);
        int unsigned n_pl = t.payload.size() / 4;

        dw = new[4 + n_pl];
        for (int i = 0; i < 4; i++) dw[i] = desc[i*32 +: 32];
        for (int i = 0; i < int'(n_pl); i++)
            for (int b = 0; b < 4; b++)
                dw[4 + i][b*8 +: 8] = t.payload[i*4 + b];
    endfunction

    virtual function void write_rq_rd(pcie_tlp_item t);
        bit [31:0] dw [];
        m_n_rd++;
        predict(t, dw);
        m_exp_rd.push_back(dw);
        note_expected();
    endfunction

    virtual function void write_rq_wr(pcie_tlp_item t);
        bit [31:0] dw [];
        m_n_wr++;
        predict(t, dw);
        m_exp_wr.push_back(dw);
        note_expected();
    endfunction

    // -------------------------------------------------------------------------
    virtual function void write_rq_out(pcie_us_axis_pkg::pcie_us_axis_item t);
        bit        matches_rd;
        bit        matches_wr;

        note_actual();
        m_n_out++;

        if (expect_silence) begin
            note_mismatch({"RQ TLP transmitted while both credit pools are ",
                           "below threshold"},
                          "no transmission", t.convert2string());
            return;
        end

        matches_rd = (m_exp_rd.size() > 0) && same(m_exp_rd[0], t.dwords);
        matches_wr = (m_exp_wr.size() > 0) && same(m_exp_wr[0], t.dwords);

        if (!matches_rd && !matches_wr) begin
            note_mismatch("RQ TLP matches neither pending read nor pending write",
                          $sformatf("rd queue %0d, wr queue %0d",
                                    m_exp_rd.size(), m_exp_wr.size()),
                          t.convert2string());
            // Drop the oldest so one bad TLP does not desynchronise everything
            // after it - otherwise a single fault reports as hundreds.
            if (m_exp_rd.size() > 0)      void'(m_exp_rd.pop_front());
            else if (m_exp_wr.size() > 0) void'(m_exp_wr.pop_front());
            return;
        end

        // ---- credit rule: sound, and timing-independent ---------------------
        //
        // A port below its credit threshold must emit NOTHING. Unlike priority,
        // this does not depend on when a TLP reached the arbiter - if the
        // credit is unavailable it is unavailable for the whole window.
        if (matches_rd && !m_arb.have_np_credit()) begin
            m_n_credit_bad++;
            note_mismatch("read request transmitted without non-posted credit",
                          "no read request", $sformatf("%0d DWORD(s)", t.dwords.size()));
        end
        else if (matches_wr && !m_arb.have_p_credit()) begin
            m_n_credit_bad++;
            note_mismatch("write request transmitted without posted credit",
                          "no write request", $sformatf("%0d DWORD(s)", t.dwords.size()));
        end

        // Which port each TLP came from, so a test can assert a distribution
        // even though a per-TLP order cannot be predicted.
        if (matches_rd) m_n_from_rd++;
        else            m_n_from_wr++;

        if (matches_rd) void'(m_exp_rd.pop_front());
        else            void'(m_exp_wr.pop_front());

        if (cov != null)
            cov.sample(!matches_rd,
                       matches_rd ? m_arb.have_p_credit()  : m_arb.have_np_credit(),
                       matches_rd ? (m_exp_wr.size() > 0)  : (m_exp_rd.size() > 0),
                       t.dwords.size());

        note_match($sformatf("RQ TLP, %0d DWORD(s), from the %s port",
                             t.dwords.size(), matches_rd ? "read" : "write"));
    endfunction

    protected virtual function bit same(const ref bit [31:0] a[],
                                        const ref bit [31:0] b[]);
        if (a.size() != b.size()) return 1'b0;
        foreach (a[i]) if (a[i] !== b[i]) return 1'b0;
        return 1'b1;
    endfunction

    // -------------------------------------------------------------------------
    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf({"read in=%0d write in=%0d RQ out=%0d (from rd=%0d, from ",
                       "wr=%0d) credit violations=%0d (rd pending %0d, wr pending %0d)"},
                      m_n_rd, m_n_wr, m_n_out, m_n_from_rd, m_n_from_wr,
                      m_n_credit_bad, m_exp_rd.size(), m_exp_wr.size()), UVM_LOW)
        `uvm_info(get_type_name(), m_arb.convert2string(), UVM_LOW)
    endfunction

endclass : sb_rq

`endif // SB_RQ_SV

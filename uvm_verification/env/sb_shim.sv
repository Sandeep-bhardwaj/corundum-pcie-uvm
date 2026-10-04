// SPDX-License-Identifier: BSD-2-Clause-Views
//
// sb_shim - Tier 4 scoreboard (Xilinx AXI-S <-> generic TLP)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §11, §10 (ref_tlp_shim), §19 Tier 4
// Introduced : Step 6 (Tier 4a)
//
// A PURE CONVERSION CHECK, and that makes it different in kind from every
// scoreboard below it. There is no state, no reordering, no memory: one TLP
// goes in on the Xilinx side and one comes out on the generic side, and the
// question is only whether the fields survived. §19's Tier 4 criterion is
// "bidirectional equivalence", and equivalence is what this measures.
//
// TWO CHECKS:
//
//   1. HEADER EQUIVALENCE - the generic header the DUT produced equals what
//      ref_tlp_shim predicts from the descriptor the testbench sent.
//   2. PAYLOAD EQUIVALENCE - the bytes after the descriptor arrive unchanged
//      and in order.
//
// They are separate because a straddle bug corrupts the payload while leaving
// the header intact, and a descriptor-decode bug does the reverse. Reporting
// one number for both would make them indistinguishable.
//
// MATCHING IS IN ORDER. Unlike sb_dma, these DUTs are stateless routers with a
// single stream in and a single stream out - they cannot reorder, so a
// positional match is correct here and a set match would be weaker.
//
// FIELDS THE RTL DELIBERATELY DROPS ARE NOT COMPARED. AT does not survive an RC
// conversion and EP does not survive CQ; see the ref_tlp_shim header. Comparing
// them would report the DUT for behaving as written.
// -----------------------------------------------------------------------------

`ifndef SB_SHIM_SV
`define SB_SHIM_SV

`uvm_analysis_imp_decl(_shim_axis)
`uvm_analysis_imp_decl(_shim_tlp)

class sb_shim extends mqnic_scoreboard_base;

    `uvm_component_utils(sb_shim)

    uvm_analysis_imp_shim_axis #(pcie_us_axis_pkg::pcie_us_axis_item, sb_shim) axis_imp;
    uvm_analysis_imp_shim_tlp  #(pcie_tlp_item,                       sb_shim) tlp_imp;

    ref_tlp_shim       m_shim;
    mqnic_us_channel_e channel = PCIE_CH_RC;

    // What the testbench sent on the Xilinx side, converted to the generic
    // form it should come out as.
    protected pcie_tlp_item m_expected [$];
    protected pcie_us_axis_pkg::pcie_us_axis_item m_expected_axis [$];

    protected int unsigned m_n_axis;
    protected int unsigned m_n_tlp;
    protected int unsigned m_n_straddled;
    protected int unsigned m_n_hdr_bad;
    protected int unsigned m_n_payload_bad;

    // Optional: sampled per converted TLP.
    cg_straddle cov;

    // Fail the run if RC never straddled.
    //
    // §14.4 makes straddle coverage mandatory FOR THE TIER, not for every test
    // in it. t4a_backpressure is about backpressure and legitimately produced no
    // straddled TLP; failing it taught nothing, and a check that fires on
    // correct runs trains people to ignore it. The tests that exist to straddle
    // set this.
    bit require_straddle = 1'b0;

    // -------------------------------------------------------------------------
    // WHICH SIDE IS THE STIMULUS.
    //
    // Tier 4a (RC, CQ) flows Xilinx -> generic: the AXI-S item is what was
    // sent and the generic TLP is what must come out.
    // Tier 4b (RQ, CC) flows the other way, so the roles SWAP - the generic
    // TLP is the stimulus and the AXI-S item is the result.
    //
    // One scoreboard serves both because the check is the same equivalence in
    // both directions, and ref_tlp_shim already models both. A second
    // scoreboard would be a second place for the field list to drift.
    // -------------------------------------------------------------------------
    bit tx_direction = 1'b0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        axis_imp = new("axis_imp", this);
        tlp_imp  = new("tlp_imp", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (m_shim == null) m_shim = ref_tlp_shim::type_id::create("m_shim");
    endfunction

    virtual function int unsigned pending_count();
        return m_expected.size() + m_expected_axis.size();
    endfunction

    // -------------------------------------------------------------------------
    // The Xilinx side: convert what was sent into what should emerge.
    // -------------------------------------------------------------------------
    virtual function void write_shim_axis(pcie_us_axis_pkg::pcie_us_axis_item t);
        if (tx_direction) begin
            actual_axis(t);
            return;
        end
        expect_from_axis(t);
    endfunction

    protected virtual function void expect_from_axis(pcie_us_axis_pkg::pcie_us_axis_item t);
        pcie_tlp_item  e;
        bit [127:0]    desc;
        int unsigned   desc_dw;
        int unsigned   n_payload;

        m_n_axis++;
        if (t.straddled) m_n_straddled++;

        desc_dw = (channel == PCIE_CH_RC) ? 3 : 4;
        if (t.dwords.size() < desc_dw) begin
            note_mismatch("Xilinx TLP shorter than its descriptor",
                          $sformatf(">= %0d DWORD(s)", desc_dw),
                          $sformatf("%0d DWORD(s)", t.dwords.size()));
            return;
        end

        desc = m_shim.unpack_desc(t.dwords, desc_dw);

        e = pcie_tlp_item::type_id::create("exp");
        case (channel)
            PCIE_CH_RC: begin
                e.hdr   = m_shim.rc_parse(desc[95:0]);
                e.error = m_shim.rc_error(desc[95:0]);
            end
            PCIE_CH_CQ: begin
                e.hdr    = m_shim.cq_parse(desc, t.first_be, t.last_be);
                e.bar_id = m_shim.cq_bar_id(desc);
            end
            default:
                `uvm_fatal(get_type_name(),
                    $sformatf("sb_shim does not model channel %s", channel.name()))
        endcase

        // Payload is everything after the descriptor, DWORD order preserved.
        n_payload  = t.dwords.size() - desc_dw;
        e.payload  = new[n_payload * 4];
        for (int i = 0; i < int'(n_payload); i++)
            for (int b = 0; b < 4; b++)
                e.payload[i*4 + b] = t.dwords[desc_dw + i][b*8 +: 8];

        m_expected.push_back(e);
        note_expected();

        if (cov != null)
            cov.sample_tlp(channel, t.straddled, t.start_lane,
                           (t.start_lane + t.dwords.size() - 1) % 8, t.dwords.size());
    endfunction

    // -------------------------------------------------------------------------
    // The generic side: compare against the head of the expected queue.
    // -------------------------------------------------------------------------
    virtual function void write_shim_tlp(pcie_tlp_item t);
        if (tx_direction) begin
            expect_from_tlp(t);
            return;
        end
        actual_tlp(t);
    endfunction

    // -------------------------------------------------------------------------
    // Tier 4b: the generic TLP is the stimulus. Predict the Xilinx DWORD stream
    // the shim must produce - descriptor first, then payload.
    // -------------------------------------------------------------------------
    protected virtual function void expect_from_tlp(pcie_tlp_item t);
        pcie_us_axis_pkg::pcie_us_axis_item e;
        bit [127:0]  desc;
        int unsigned desc_dw;
        int unsigned n_payload_dw;

        m_n_tlp++;
        desc_dw = (channel == PCIE_CH_CC) ? 3 : 4;

        case (channel)
            PCIE_CH_CC: desc = 128'(m_shim.cc_encode(t.hdr));
            PCIE_CH_RQ: desc = m_shim.rq_encode(t.hdr);
            default:
                `uvm_fatal(get_type_name(),
                    $sformatf("sb_shim tx direction does not model %s", channel.name()))
        endcase

        n_payload_dw = t.payload.size() / 4;

        e = pcie_us_axis_pkg::pcie_us_axis_item::type_id::create("exp");
        e.dwords = new[desc_dw + n_payload_dw];
        for (int i = 0; i < int'(desc_dw); i++)
            e.dwords[i] = desc[i*32 +: 32];
        for (int i = 0; i < int'(n_payload_dw); i++)
            for (int b = 0; b < 4; b++)
                e.dwords[desc_dw + i][b*8 +: 8] = t.payload[i*4 + b];

        if (channel == PCIE_CH_RQ) begin
            e.first_be = m_shim.rq_first_be(t.hdr);
            e.last_be  = m_shim.rq_last_be(t.hdr);
        end

        m_expected_axis.push_back(e);
        note_expected();
    endfunction

    // The Xilinx side is now the RESULT.
    protected virtual function void actual_axis(pcie_us_axis_pkg::pcie_us_axis_item t);
        pcie_us_axis_pkg::pcie_us_axis_item e;

        note_actual();
        m_n_axis++;
        if (t.straddled) m_n_straddled++;

        if (m_expected_axis.size() == 0) begin
            note_mismatch("Xilinx TLP with nothing outstanding on the generic side",
                          "no TLP", t.convert2string());
            return;
        end

        e = m_expected_axis.pop_front();

        if (e.dwords.size() != t.dwords.size()) begin
            m_n_payload_bad++;
            note_mismatch($sformatf("%s TLP length", channel.name()),
                          $sformatf("%0d DWORD(s)", e.dwords.size()),
                          $sformatf("%0d DWORD(s)", t.dwords.size()));
            return;
        end

        foreach (e.dwords[i]) begin
            if (e.dwords[i] !== t.dwords[i]) begin
                // The descriptor and the payload are reported separately: a
                // descriptor-build bug and a data-path bug look nothing alike
                // and should not share a counter.
                if (i < ((channel == PCIE_CH_CC) ? 3 : 4)) m_n_hdr_bad++;
                else                                        m_n_payload_bad++;
                note_mismatch($sformatf("%s DWORD %0d of %0d (%s)",
                                        channel.name(), i, e.dwords.size(),
                                        (i < ((channel == PCIE_CH_CC) ? 3 : 4))
                                            ? "descriptor" : "payload"),
                              $sformatf("0x%08h", e.dwords[i]),
                              $sformatf("0x%08h", t.dwords[i]));
                return;
            end
        end

        // RQ byte enables travel in tuser, not in the descriptor. They were
        // predicted above but never compared, so a monitor that read them on
        // the wrong beat (last instead of first) passed every Tier 4c test and
        // was found only end-to-end, when a multi-beat DMA write landed in
        // host memory as a single DWORD.
        if (channel == PCIE_CH_RQ && (e.first_be !== t.first_be || e.last_be !== t.last_be)) begin
            m_n_hdr_bad++;
            note_mismatch("RQ byte enables (tuser)",
                          $sformatf("first 0x%0h last 0x%0h", e.first_be, e.last_be),
                          $sformatf("first 0x%0h last 0x%0h", t.first_be, t.last_be));
            return;
        end

        note_match($sformatf("%s TLP converted, %0d DWORD(s)",
                             channel.name(), e.dwords.size()));

        if (cov != null)
            cov.sample_tlp(channel, t.straddled, t.start_lane,
                           (t.start_lane + t.dwords.size() - 1) % 8, t.dwords.size());
    endfunction

    protected virtual function void actual_tlp(pcie_tlp_item t);
        pcie_tlp_item e;

        note_actual();
        m_n_tlp++;

        if (m_expected.size() == 0) begin
            note_mismatch("generic TLP with nothing outstanding on the Xilinx side",
                          "no TLP", t.convert2string());
            return;
        end

        e = m_expected.pop_front();

        // ---- check 1: header equivalence ------------------------------------
        if (!hdr_equal(e.hdr, t.hdr)) begin
            m_n_hdr_bad++;
            note_mismatch($sformatf("%s header conversion", channel.name()),
                          $sformatf("0x%032h", e.hdr),
                          $sformatf("0x%032h", t.hdr));
            // Fall through: the payload check below still applies and is
            // independent, so run it rather than hiding it behind this failure.
        end

        // ---- check 2: payload equivalence -----------------------------------
        if (e.payload.size() != t.payload.size()) begin
            m_n_payload_bad++;
            note_mismatch($sformatf("%s payload length", channel.name()),
                          $sformatf("%0d byte(s)", e.payload.size()),
                          $sformatf("%0d byte(s)", t.payload.size()));
            return;
        end

        foreach (e.payload[i]) begin
            if (e.payload[i] !== t.payload[i]) begin
                m_n_payload_bad++;
                note_mismatch($sformatf("%s payload byte %0d of %0d",
                                        channel.name(), i, e.payload.size()),
                              $sformatf("0x%02h", e.payload[i]),
                              $sformatf("0x%02h", t.payload[i]));
                return;
            end
        end

        note_match($sformatf("%s TLP converted, %0d payload byte(s)",
                             channel.name(), e.payload.size()));
    endfunction

    // -------------------------------------------------------------------------
    // Compare only the fields the conversion is required to preserve.
    //
    // AT ([107:106]) is hardwired to 0 by RC and EP ([110]) is dropped by CQ -
    // both RTL behaviour, both documented in ref_tlp_shim. Masking them here is
    // what stops the scoreboard reporting the DUT for doing what it is written
    // to do, which is the trap a_sop_implies_valid fell into twice.
    // -------------------------------------------------------------------------
    protected virtual function bit hdr_equal(bit [127:0] exp, bit [127:0] act);
        bit [127:0] mask = '1;
        mask[107:106] = 2'b00;              // AT
        if (channel == PCIE_CH_CQ) mask[110] = 1'b0;   // EP
        return ((exp & mask) === (act & mask));
    endfunction

    // -------------------------------------------------------------------------
    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf({"channel %s: %0d Xilinx TLP(s) in (%0d straddled), %0d ",
                       "generic out, %0d header / %0d payload mismatch(es)"},
                      channel.name(), m_n_axis, m_n_straddled, m_n_tlp,
                      m_n_hdr_bad, m_n_payload_bad), UVM_LOW)
    endfunction

    virtual function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        if (!m_enable_end_check) return;

        // A straddling channel that never straddled has not been tested for the
        // thing it exists to be tested for. §14.4 makes this mandatory.
        if (require_straddle && channel == PCIE_CH_RC && m_n_axis > 0 && m_n_straddled == 0)
            `uvm_error(get_type_name(),
                {"RC straddles at this width but no straddled TLP was driven - ",
                 "§14.4 straddle coverage is unreachable from this run"})
    endfunction

endclass : sb_shim

`endif // SB_SHIM_SV

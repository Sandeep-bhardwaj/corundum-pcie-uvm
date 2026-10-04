// SPDX-License-Identifier: BSD-2-Clause-Views
//
// cg_straddle - Tier 4 straddle coverage (MANDATORY, §14.4)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §14.4, §22 R2
// Introduced : Step 6 (Tier 4a); restructured per channel in coverage closure
//
// §14.4 marks this coverage mandatory, and §22 R2 says why: a tuser straddle
// error corrupts data silently three tiers up. Coverage is the evidence that
// the straddle cases were actually produced, not merely permitted.
//
// ONE COVERGROUP INSTANCE PER CHANNEL, created when that channel is first
// sampled. The first version crossed all four channels in one instance, but
// Tier 4a carries only RC/CQ and 4b only CC - so most of every tier's bins were
// unreachable by construction and the score (52-72%) measured the tier's
// channel list, not its stimulus. A tier is now scored only on the channels it
// actually carries.
//
// Only RC straddles at the golden 256-bit width (mqnic_core_pcie_us.v:163-166),
// so RC gets the full mode x sop x eop cross (§14.4); the other channels get
// end position x length.
//
// SOP POSITION IS QUANTISED. A TLP may begin only on a 128-bit boundary - lane
// 0 or 4 at 256-bit data - so the sop axis has two reachable values, not eight.
// -----------------------------------------------------------------------------

`ifndef CG_STRADDLE_SV
`define CG_STRADDLE_SV

// One channel's coverage. Embedded covergroups give one instance per object,
// so per-channel instances need one of these per channel.
class cg_straddle_ch;

    protected bit          m_straddled;
    protected int unsigned m_sop_lane;
    protected int unsigned m_eop_lane;
    protected int unsigned m_dwords;
    protected bit          m_is_rc;

    // RC: the straddling channel.
    covergroup cg_rc;
        option.per_instance = 1;
        cp_mode : coverpoint m_straddled { bins b_none = {0}; bins b_2tlp = {1}; }
        cp_sop  : coverpoint m_sop_lane {
            bins b_slot0 = {0}; bins b_slot1 = {4};
            illegal_bins b_unaligned = default;
        }
        cp_eop  : coverpoint m_eop_lane { bins b_lane[] = {[0:7]}; }
        cp_len  : coverpoint m_dwords {
            bins b_desc_only = {[3:4]}; bins b_short = {[5:7]}; bins b_one_beat = {8};
            bins b_multi = {[9:16]};    bins b_long  = {[17:$]};
        }
        // The monitor defines "straddled" as "began part-way through a beat"
        // (pcie_us_axis_monitor: lane != 0), so mode and sop slot are the same
        // fact: slot 1 is always the second of a pair, slot 0 never is.
        x_straddle : cross cp_mode, cp_sop, cp_eop {
            ignore_bins none_at_slot1     = binsof(cp_mode) intersect {0} && binsof(cp_sop) intersect {4};
            ignore_bins straddled_at_slot0 = binsof(cp_mode) intersect {1} && binsof(cp_sop) intersect {0};
        }
        x_len : cross cp_mode, cp_len;
    endgroup

    // CQ / RQ / CC: no straddling at 256 bits.
    covergroup cg_plain;
        option.per_instance = 1;
        cp_mode : coverpoint m_straddled { bins b_none = {0}; illegal_bins b_straddled = {1}; }
        cp_sop  : coverpoint m_sop_lane {
            bins b_slot0 = {0};
            illegal_bins b_other = default;
        }
        cp_eop  : coverpoint m_eop_lane { bins b_lane[] = {[0:7]}; }
        cp_len  : coverpoint m_dwords {
            bins b_desc_only = {[3:4]}; bins b_short = {[5:7]}; bins b_one_beat = {8};
            bins b_multi = {[9:16]};    bins b_long  = {[17:$]};
        }
    endgroup

    function new(string inst_name, bit is_rc);
        m_is_rc = is_rc;
        if (is_rc) begin cg_rc = new();    cg_rc.set_inst_name(inst_name);    end
        else       begin cg_plain = new(); cg_plain.set_inst_name(inst_name); end
    endfunction

    function void sample(bit straddled, int unsigned sop_lane,
                         int unsigned eop_lane, int unsigned dwords);
        m_straddled = straddled;
        m_sop_lane  = sop_lane;
        m_eop_lane  = eop_lane;
        m_dwords    = dwords;
        if (m_is_rc) cg_rc.sample();
        else         cg_plain.sample();
    endfunction

    function real coverage();
        return m_is_rc ? cg_rc.get_inst_coverage() : cg_plain.get_inst_coverage();
    endfunction

endclass : cg_straddle_ch


class cg_straddle extends uvm_component;

    `uvm_component_utils(cg_straddle)

    protected cg_straddle_ch m_ch [mqnic_us_channel_e];

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void sample_tlp(mqnic_us_channel_e ch,
                                     bit                straddled,
                                     int unsigned       sop_lane,
                                     int unsigned       eop_lane,
                                     int unsigned       dwords);
        if (!m_ch.exists(ch))
            m_ch[ch] = new({get_full_name(), ".", ch.name()}, ch == PCIE_CH_RC);
        m_ch[ch].sample(straddled, sop_lane, eop_lane, dwords);
    endfunction

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        foreach (m_ch[c])
            `uvm_info(get_type_name(),
                $sformatf("%s straddle coverage %.2f%%", c.name(), m_ch[c].coverage()), UVM_LOW)
    endfunction

endclass : cg_straddle

`endif // CG_STRADDLE_SV

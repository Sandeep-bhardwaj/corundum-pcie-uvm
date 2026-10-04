// SPDX-License-Identifier: BSD-2-Clause-Views
//
// cg_tlp - Tier 1b functional coverage (TLP routing: demux and mux)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §14 (Tier 1b)
// Introduced : coverage closure, after the 20-seed regression
//
// Sampled by sb_tlp at its decision points, from monitor-observed TLPs only
// (§14.1) - so a bin fills only for traffic the DUT actually handled.
//
// DEMUX (pcie_tlp_demux_bar, BAR_BASE=0, BAR_STRIDE=2, 2 ports): every BAR id
// crossed with its fate. BAR 0 -> port 0 and BAR 2 -> port 1 are the only legal
// routes; everything else must be DROPPED. The wrong combinations are
// illegal_bins, so a mis-route fails here as well as in the scoreboard.
//
// MUX (pcie_tlp_mux, 2 ports, round-robin): source port crossed with whether
// the OTHER port was waiting (the arbitration actually decided something) and
// with length class - a long TLP holding the output while the other waits is
// the case a fairness bug shows up in.
//
// Length classes are relative to the 256-bit (32-byte) beat: header only,
// partial beat, exact beat, one-to-two beats, multi-beat.
// -----------------------------------------------------------------------------

`ifndef CG_TLP_SV
`define CG_TLP_SV

class cg_tlp extends uvm_component;

    `uvm_component_utils(cg_tlp)

    // fate: 0 = port 0, 1 = port 1, 2 = dropped
    protected int unsigned m_bar;
    protected int unsigned m_fate;
    protected int unsigned m_len;
    protected int unsigned m_src;
    protected bit          m_contended;
    protected int unsigned m_run;

    // -------------------------------------------------------------------------
    covergroup cg_route;
        option.per_instance = 1;
        option.name         = "cg_tlp_route";

        cp_bar  : coverpoint m_bar  { bins b[] = {[0:5]}; }
        cp_fate : coverpoint m_fate { bins port0 = {0}; bins port1 = {1}; bins dropped = {2}; }
        cp_len  : coverpoint m_len {
            bins hdr_only   = {0};
            bins part_beat  = {[4:28]};
            bins one_beat   = {32};
            bins beat_1_2   = {[36:60]};
            bins two_beats  = {64};
            bins multi_beat = {[68:$]};
        }

        // Each BAR's fate. Anything other than the configured route is illegal.
        // Legal bins left: (0,port0) (2,port1) and (1|3|4|5, dropped).
        x_bar_fate : cross cp_bar, cp_fate {
            illegal_bins bar0_misrouted = binsof(cp_bar) intersect {0} && binsof(cp_fate) intersect {1, 2};
            illegal_bins bar2_misrouted = binsof(cp_bar) intersect {2} && binsof(cp_fate) intersect {0, 2};
            illegal_bins unmatched_leak = binsof(cp_bar) intersect {1, 3, 4, 5}
                                       && binsof(cp_fate) intersect {0, 1};
        }

        // Every length class reaches every fate (a drop of a multi-beat TLP
        // must swallow all of its beats).
        x_fate_len : cross cp_fate, cp_len;
    endgroup

    // -------------------------------------------------------------------------
    covergroup cg_merge;
        option.per_instance = 1;
        option.name         = "cg_tlp_merge";

        cp_src       : coverpoint m_src { bins port0 = {0}; bins port1 = {1}; }
        cp_contended : coverpoint m_contended { bins alone = {0}; bins other_waiting = {1}; }
        cp_len : coverpoint m_len {
            bins hdr_only   = {0};
            bins part_beat  = {[4:28]};
            bins one_beat   = {32};
            bins multi_beat = {[36:$]};
        }
        // Consecutive wins by one port. Under contention round-robin allows
        // only 1; runs >1 are legal only while the other port is idle.
        cp_run : coverpoint m_run { bins one = {1}; bins two = {2}; bins long = {[3:$]}; }

        x_arb     : cross cp_src, cp_contended, cp_len;
        x_run_ctx : cross cp_run, cp_contended {
            ignore_bins unreachable_rr = binsof(cp_contended) intersect {1}
                                      && binsof(cp_run) intersect {[3:$]};
        }
    endgroup

    // -------------------------------------------------------------------------
    function new(string name, uvm_component parent);
        super.new(name, parent);
        cg_route = new();
        cg_route.set_inst_name({get_full_name(), ".cg_route"});
        cg_merge = new();
        cg_merge.set_inst_name({get_full_name(), ".cg_merge"});
    endfunction

    virtual function void sample_route(int unsigned bar, int unsigned fate,
                                       int unsigned len);
        m_bar = bar; m_fate = fate; m_len = len;
        cg_route.sample();
    endfunction

    virtual function void sample_merge(int unsigned src, bit contended,
                                       int unsigned len, int unsigned run);
        m_src = src; m_contended = contended; m_len = len; m_run = run;
        cg_merge.sample();
    endfunction

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf("route coverage %.2f%%, merge coverage %.2f%%",
                      cg_route.get_coverage(), cg_merge.get_coverage()), UVM_LOW)
    endfunction

endclass : cg_tlp

`endif // CG_TLP_SV

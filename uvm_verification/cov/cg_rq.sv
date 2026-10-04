// SPDX-License-Identifier: BSD-2-Clause-Views
//
// cg_rq - Tier 4c functional coverage (pcie_us_if_rq: two streams onto RQ)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §14 (Tier 4c)
// Introduced : coverage closure, after the 20-seed regression
//
// Sampled by sb_rq for every RQ TLP it matched. A TLP can only legally leave on
// its own port's credit (sb_rq checks that), so the interesting state is the
// OTHER port: did it have credit, and did it have something waiting? Those
// together are the arbitration situations - one port starved while the other
// flows, both contending, one alone - and each should be seen from both sides.
// -----------------------------------------------------------------------------

`ifndef CG_RQ_SV
`define CG_RQ_SV

class cg_rq extends uvm_component;

    `uvm_component_utils(cg_rq)

    protected bit          m_is_write;
    protected bit          m_other_credit;
    protected bit          m_other_pending;
    protected int unsigned m_dw;              // TLP DWORDs incl. 4-DW descriptor

    covergroup cg_out;
        option.per_instance = 1;
        option.name         = "cg_rq_out";

        cp_port    : coverpoint m_is_write     { bins read = {0}; bins write = {1}; }
        cp_ocredit : coverpoint m_other_credit { bins starved = {0}; bins has_credit = {1}; }
        cp_opend   : coverpoint m_other_pending{ bins idle = {0}; bins waiting = {1}; }
        cp_len : coverpoint m_dw {
            bins desc_only  = {4};            // read request
            bins one_dw     = {5};
            bins short_     = {[6:11]};
            bins beat_plus  = {[12:$]};
        }

        x_arb : cross cp_port, cp_ocredit, cp_opend;
        x_len : cross cp_port, cp_len {
            // A read request carries no payload; a write always carries some.
            ignore_bins rd_payload = binsof(cp_port.read)  && !binsof(cp_len.desc_only);
            ignore_bins wr_no_pl   = binsof(cp_port.write) &&  binsof(cp_len.desc_only);
        }
    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        cg_out = new();
        cg_out.set_inst_name({get_full_name(), ".cg_out"});
    endfunction

    virtual function void sample(bit is_write, bit other_credit, bit other_pending,
                                 int unsigned dwords);
        m_is_write = is_write; m_other_credit = other_credit;
        m_other_pending = other_pending; m_dw = dwords;
        cg_out.sample();
    endfunction

endclass : cg_rq

`endif // CG_RQ_SV

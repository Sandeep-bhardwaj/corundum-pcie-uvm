// SPDX-License-Identifier: BSD-2-Clause-Views
//
// ref_rq_arb - flow control and arbitration for pcie_us_if_rq
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §10, §7.6
// Introduced : Step 6 (Tier 4c)
//
// THE FIRST TIER 4 MODEL THAT IS NOT A PURE FUNCTION OF ITS INPUT. Every other
// piece of this tier converts one TLP into one TLP. pcie_us_if_rq decides WHICH
// of two input streams goes next, and whether either may go at all.
//
// TWO PORTS, DIFFERENT CREDIT POOLS (pcie_us_if_rq.v:381, 448):
//
//   port 0  read requests   NON-POSTED   gated by have_np_credit
//   port 1  write requests  POSTED       gated by have_p_credit
//
// FIXED PRIORITY, PORT 0 FIRST (:523-536). The loop starts at port 0 and takes
// the first eligible port, so a read request beats a write request whenever
// both are ready. That has a consequence for testing rather than for the model:
// with both credit pools full the write path is barely exercised, so a test
// that wants to see it has to starve the posted pool. pcie_us_fc_if.starve_p()
// exists for exactly that.
//
// THE THRESHOLDS ARE STRICT INEQUALITIES (:872), which is where an off-by-one
// hides - a credit count of exactly 8 BLOCKS. Cross-checked against an
// independent transcription including both boundaries.
// -----------------------------------------------------------------------------

`ifndef REF_RQ_ARB_SV
`define REF_RQ_ARB_SV

typedef enum {
    RQ_GRANT_NONE,
    RQ_GRANT_READ,      // port 0, non-posted
    RQ_GRANT_WRITE      // port 1, posted
} rq_grant_e;


class ref_rq_arb extends uvm_object;

    `uvm_object_utils(ref_rq_arb)

    // Mirrors of the DUT's credit inputs.
    bit [7:0]  tx_fc_ph_av  = 8'hFF;
    bit [11:0] tx_fc_pd_av  = 12'hFFF;
    bit [7:0]  tx_fc_nph_av = 8'hFF;
    bit [11:0] tx_fc_npd_av = 12'hFFF;

    bit [2:0]  max_payload_size = 3'd1;

    function new(string name = "ref_rq_arb");
        super.new(name);
    endfunction

    // pcie_us_if_rq.v:871 - note the clamp at 5, and that this is in CREDIT
    // units (8 << n), not bytes.
    virtual function int unsigned mps_fc_units();
        bit [2:0] m = (max_payload_size > 3'd5) ? 3'd5 : max_payload_size;
        return 8 << m;
    endfunction

    // Non-posted: header credits only. Read requests carry no data.
    virtual function bit have_np_credit();
        return (int'(tx_fc_nph_av) > 8);
    endfunction

    // Posted: header AND data, because a write request carries its payload.
    virtual function bit have_p_credit();
        return (int'(tx_fc_ph_av) > 8) &&
               (int'(tx_fc_pd_av) > (mps_fc_units() << 1));
    endfunction

    // -------------------------------------------------------------------------
    // Which port the DUT must select, given what is waiting.
    // -------------------------------------------------------------------------
    virtual function rq_grant_e grant(bit rd_pending, bit wr_pending);
        if (rd_pending && have_np_credit()) return RQ_GRANT_READ;
        if (wr_pending && have_p_credit())  return RQ_GRANT_WRITE;
        return RQ_GRANT_NONE;
    endfunction

    // True when the DUT must be transmitting nothing at all - used by the
    // starvation tests, where the property under test is SILENCE and a
    // scoreboard that only checks what did appear would pass trivially.
    virtual function bit blocked(bit rd_pending, bit wr_pending);
        return (grant(rd_pending, wr_pending) == RQ_GRANT_NONE);
    endfunction

    virtual function string convert2string();
        return $sformatf({"rq_arb: ph=%0d pd=%0d nph=%0d npd=%0d mps=%0d ",
                          "-> np_credit=%0b p_credit=%0b"},
                         tx_fc_ph_av, tx_fc_pd_av, tx_fc_nph_av, tx_fc_npd_av,
                         128 << max_payload_size,
                         have_np_credit(), have_p_credit());
    endfunction

endclass : ref_rq_arb

`endif // REF_RQ_ARB_SV

// SPDX-License-Identifier: BSD-2-Clause-Views
//
// pcie_us_fc_if - PCIe transmit flow-control credits
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.6, §13 Tier 4
// Introduced : Step 6 (Tier 4c, pcie_us_if_rq)
//
// WHY THIS IS AN INTERFACE AND NOT A TIE-OFF.
//
// pcie_us_if_rq will not transmit until credits are available:
//
//     have_np_credit = tx_fc_nph_av > 8;                          // :872
//     have_p_credit  = (tx_fc_ph_av > 8) &&
//                      (tx_fc_pd_av > (max_payload_size_fc << 1));
//
// Tying these high is the obvious shortcut and it verifies the shim only in the
// case where flow control NEVER BINDS - which is the case that never fails. It
// is the same trap as a completion-timeout test that cannot reach the timeout,
// and this project has already paid for that one once (bug 4).
//
// Driving them properly also lets a test STARVE ONE PORT AND NOT THE OTHER,
// which is the only way to observe the arbitration: read requests are
// non-posted and write requests are posted, so they draw on different credit
// pools. With both pools full, the fixed priority means reads always win and
// the write path is barely exercised.
//
// Quasi-static, like dma_if_cfg_if: a test sets a credit level and leaves it.
// There is no clocking block for the same reason, and the setters are
// FUNCTIONS not tasks - they consume no time, and a test needs to call them
// from start_of_simulation_phase before any traffic exists.
// -----------------------------------------------------------------------------

`ifndef PCIE_US_FC_IF_SV
`define PCIE_US_FC_IF_SV

`timescale 1ns / 1ps

interface pcie_us_fc_if;

    logic [7:0]  tx_fc_ph_av;      // posted header credits
    logic [11:0] tx_fc_pd_av;      // posted data credits
    logic [7:0]  tx_fc_nph_av;     // non-posted header credits
    logic [11:0] tx_fc_npd_av;     // non-posted data credits

    // Plenty of everything: flow control never binds. The starting point, and
    // deliberately NOT the only configuration any test runs.
    function automatic void init_unlimited();
        tx_fc_ph_av  = 8'hFF;
        tx_fc_pd_av  = 12'hFFF;
        tx_fc_nph_av = 8'hFF;
        tx_fc_npd_av = 12'hFFF;
    endfunction

    // Below the DUT's thresholds, so nothing may be transmitted at all.
    function automatic void starve_all();
        tx_fc_ph_av  = 8'd8;       // must EXCEED 8, so 8 blocks
        tx_fc_pd_av  = 12'd0;
        tx_fc_nph_av = 8'd8;
        tx_fc_npd_av = 12'd0;
    endfunction

    // Read requests (non-posted) blocked, writes (posted) free.
    function automatic void starve_np();
        tx_fc_ph_av  = 8'hFF;
        tx_fc_pd_av  = 12'hFFF;
        tx_fc_nph_av = 8'd8;
        tx_fc_npd_av = 12'hFFF;
    endfunction

    // Writes (posted) blocked, read requests free. This is the configuration
    // that makes the write path observable at all - with both pools full the
    // fixed priority starves it.
    function automatic void starve_p();
        tx_fc_ph_av  = 8'd8;
        tx_fc_pd_av  = 12'd0;
        tx_fc_nph_av = 8'hFF;
        tx_fc_npd_av = 12'hFFF;
    endfunction

endinterface : pcie_us_fc_if

`endif // PCIE_US_FC_IF_SV

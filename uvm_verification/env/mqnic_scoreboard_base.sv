// SPDX-License-Identifier: BSD-2-Clause-Views
//
// mqnic_scoreboard_base
// -----------------------------------------------------------------------------
// Abstract base for every scoreboard in the environment.
//
// Implements : VERIFICATION_STRATEGY.md  §11 (scoreboards),
//                                        §17.4 (mismatch message format)
// Introduced : Step 0 (infrastructure)
//
// Provides the behaviour every scoreboard must have and which is otherwise
// re-invented (differently) in each one:
//
//   * match / mismatch / expected / actual counters
//   * a FIXED 3-line mismatch report format so log scraping is reliable
//   * an end-of-test drain check - a scoreboard that never compared anything,
//     or that still holds unmatched expected items, FAILS the test. This is the
//     single most common way a testbench silently passes while checking nothing.
//
// Derived classes must implement pending_count().
// -----------------------------------------------------------------------------

`ifndef MQNIC_SCOREBOARD_BASE_SV
`define MQNIC_SCOREBOARD_BASE_SV

virtual class mqnic_scoreboard_base extends uvm_scoreboard;

    // ---- statistics ---------------------------------------------------------
    protected int unsigned m_match_count;
    protected int unsigned m_mismatch_count;
    protected int unsigned m_expected_count;
    protected int unsigned m_actual_count;

    // ---- configuration ------------------------------------------------------

    // Run the end-of-test drain check. Only disable for tests that
    // deliberately terminate with traffic in flight (e.g. reset-in-flight),
    // and say so in the test's class header.
    bit m_enable_end_check = 1'b1;

    // A scoreboard that performed fewer than this many comparisons fails the
    // drain check. Guards against "passing" tests that never checked anything.
    int unsigned m_min_comparisons = 1;

    // Upper bound on outstanding expected items; exceeding it is reported as a
    // runtime error rather than being left to exhaust memory.
    int unsigned m_max_pending = 4096;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        m_match_count    = 0;
        m_mismatch_count = 0;
        m_expected_count = 0;
        m_actual_count   = 0;
    endfunction

    // -------------------------------------------------------------------------
    // Derived classes report how many expected items are still unmatched.
    // -------------------------------------------------------------------------
    pure virtual function int unsigned pending_count();

    // -------------------------------------------------------------------------
    // Bookkeeping helpers
    // -------------------------------------------------------------------------

    protected function void note_expected(int unsigned n = 1);
        m_expected_count += n;
        if (pending_count() > m_max_pending) begin
            `uvm_error(get_type_name(),
                $sformatf({"pending expected items (%0d) exceeded m_max_pending (%0d) - ",
                           "the actual-side monitor is probably not connected"},
                          pending_count(), m_max_pending))
        end
    endfunction

    protected function void note_actual(int unsigned n = 1);
        m_actual_count += n;
    endfunction

    protected function void note_match(string ctx = "");
        m_match_count++;
        if (ctx != "")
            `uvm_info(get_type_name(), $sformatf("MATCH: %s", ctx), UVM_HIGH)
    endfunction

    // -------------------------------------------------------------------------
    // The one and only mismatch reporting path. Fixed format, three lines:
    //   expected / actual / context.  STRATEGY §17.4.
    // -------------------------------------------------------------------------
    protected function void note_mismatch(string ctx,
                                          string expected,
                                          string actual);
        m_mismatch_count++;
        `uvm_error(get_type_name(),
            $sformatf("MISMATCH\n  expected: %s\n  actual  : %s\n  context : %s",
                      expected, actual, ctx))
    endfunction

    // -------------------------------------------------------------------------
    // Convenience comparator for byte streams, the dominant comparison in this
    // environment (packets, DMA payloads, descriptor images).
    // -------------------------------------------------------------------------
    protected function void compare_bytes(string ctx,
                                          const ref byte unsigned expected[],
                                          const ref byte unsigned actual[]);
        int  first_diff;
        bit  ok;

        ok = mqnic_vrf_pkg::bytes_equal(expected, actual, first_diff);
        if (ok) begin
            note_match(ctx);
        end
        else if (expected.size() != actual.size()) begin
            note_mismatch(ctx,
                $sformatf("%0d bytes\n            %s",
                          expected.size(), mqnic_vrf_pkg::bytes2str(expected)),
                $sformatf("%0d bytes\n            %s",
                          actual.size(), mqnic_vrf_pkg::bytes2str(actual)));
        end
        else begin
            note_mismatch($sformatf("%s (first differing byte at offset %0d)",
                                    ctx, first_diff),
                $sformatf("[%0d]=0x%02x\n            %s",
                          first_diff, expected[first_diff],
                          mqnic_vrf_pkg::bytes2str(expected)),
                $sformatf("[%0d]=0x%02x\n            %s",
                          first_diff, actual[first_diff],
                          mqnic_vrf_pkg::bytes2str(actual)));
        end
    endfunction

    // -------------------------------------------------------------------------
    // End-of-test drain check
    // -------------------------------------------------------------------------
    virtual function void check_phase(uvm_phase phase);
        super.check_phase(phase);

        if (!m_enable_end_check) begin
            `uvm_info(get_type_name(),
                "end-of-test check DISABLED for this scoreboard", UVM_LOW)
            return;
        end

        if (pending_count() != 0) begin
            `uvm_error(get_type_name(),
                $sformatf("%0d expected item(s) never matched at end of test",
                          pending_count()))
        end

        if (m_match_count < m_min_comparisons) begin
            `uvm_error(get_type_name(),
                $sformatf({"only %0d comparison(s) performed, minimum is %0d - ",
                           "the scoreboard was connected but never exercised"},
                          m_match_count, m_min_comparisons))
        end
    endfunction

    // -------------------------------------------------------------------------
    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf("summary: expected=%0d actual=%0d match=%0d mismatch=%0d pending=%0d",
                      m_expected_count, m_actual_count,
                      m_match_count, m_mismatch_count, pending_count()),
            UVM_LOW)
    endfunction

endclass : mqnic_scoreboard_base

`endif // MQNIC_SCOREBOARD_BASE_SV

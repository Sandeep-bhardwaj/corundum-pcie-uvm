// SPDX-License-Identifier: BSD-2-Clause-Views
//
// Tier 4a test suite - pcie_us_if_rc, pcie_us_if_cq
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §13 Tier 4, §14.4, §22 R2
// Introduced : Step 6 (Tier 4a)
//
// These DUTs are STATELESS CONVERTERS. There is no memory, no reordering and no
// outstanding-transaction table, so the test list looks nothing like Tier 3's:
// no tag exhaustion, no timeouts, no error injection from a peer. What matters
// is field coverage of the descriptor and, above all, STRADDLING.
//
// §14.4 makes straddle coverage mandatory and §22 R2 explains why: a tuser
// straddle error corrupts data silently three tiers up. At the golden 256-bit
// width only RC straddles, so that is where the weight of this suite sits.
//
// Descriptors are built through ref_tlp_shim rather than by hand. Hand-built
// descriptors would be a second, unvalidated transcription of the same layout -
// which is exactly the duplication §22 R2 warns against.
// -----------------------------------------------------------------------------

`ifndef TIER4A_TESTS_SV
`define TIER4A_TESTS_SV

class tier4a_base_test extends mqnic_base_test;

    `uvm_component_utils(tier4a_base_test)

    tier4a_env m_env;

    function new(string name = "tier4a_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        m_env = tier4a_env::type_id::create("m_env", this);
    endfunction

    protected task idle(int n);
        repeat (n) @(posedge m_rst_vif.clk);
    endtask

    // -------------------------------------------------------------------------
    // Build a completion TLP for the RC channel, descriptor first.
    //
    // The generic header is built with the same helper the rest of the
    // environment uses, then converted by ref_tlp_shim. One transcription,
    // used in both directions.
    // -------------------------------------------------------------------------
    protected function void make_rc(output bit [31:0] dw [],
                                    input  int unsigned payload_dw,
                                    input  bit [7:0]    tag       = 8'h10,
                                    input  bit [6:0]    lower_addr = 7'h00,
                                    input  bit [2:0]    status    = 3'b000);
        bit [127:0] hdr;
        bit [95:0]  desc;

        hdr = mqnic_vrf_pkg::tlp_hdr_completion(
                  .completer_id(16'h0100), .status(status),
                  .byte_count(payload_dw * 4), .requester_id(16'h0200),
                  .tag(tag), .lower_addr(lower_addr),
                  .dw_len(payload_dw), .poisoned(1'b0));

        desc = m_env.m_shim.cc_encode(hdr);

        dw = new[3 + payload_dw];
        for (int i = 0; i < 3; i++) dw[i] = desc[i*32 +: 32];
        for (int i = 0; i < int'(payload_dw); i++)
            dw[3 + i] = {8'hC0 + 8'(i), 8'(tag), 16'(i)};
    endfunction

    // Build a memory-write request for the CQ channel.
    protected function void make_cq(output bit [31:0] dw [],
                                    input  int unsigned payload_dw,
                                    input  bit [63:0]   addr = 64'h0000_1000,
                                    input  bit [7:0]    tag  = 8'h20);
        bit [127:0] hdr;
        bit [127:0] desc;

        hdr = '0;
        hdr[127:125] = (payload_dw != 0) ? mqnic_vrf_pkg::TLP_FMT_4DW_DATA
                                         : mqnic_vrf_pkg::TLP_FMT_4DW;
        hdr[124:120] = 5'b00000;                  // memory
        hdr[105:96]  = 10'(payload_dw);
        hdr[95:80]   = 16'h0200;                  // requester ID
        hdr[79:72]   = tag;
        hdr[71:68]   = 4'hF;                      // last BE
        hdr[67:64]   = 4'hF;                      // first BE
        hdr[63:2]    = addr[63:2];

        desc = m_env.m_shim.cq_encode(hdr);

        dw = new[4 + payload_dw];
        for (int i = 0; i < 4; i++) dw[i] = desc[i*32 +: 32];
        for (int i = 0; i < int'(payload_dw); i++)
            dw[4 + i] = {8'hA0 + 8'(i), 8'(tag), 16'(i)};
    endfunction

    protected task send_rc(const ref bit [31:0] dw []);
        pcie_us_axis_pkg::pcie_us_axis_single_seq s;
        s = pcie_us_axis_pkg::pcie_us_axis_single_seq::type_id::create("rc");
        s.dwords = new[dw.size()];
        foreach (dw[i]) s.dwords[i] = dw[i];
        if (!s.randomize() with { delay inside {[0:2]}; })
            `uvm_fatal(get_type_name(), "randomize failed")
        s.start(m_env.m_rc_axis.sequencer);
    endtask

    protected task send_cq(const ref bit [31:0] dw []);
        pcie_us_axis_pkg::pcie_us_axis_single_seq s;
        s = pcie_us_axis_pkg::pcie_us_axis_single_seq::type_id::create("cq");
        s.dwords = new[dw.size()];
        foreach (dw[i]) s.dwords[i] = dw[i];
        if (!s.randomize() with { delay inside {[0:2]}; })
            `uvm_fatal(get_type_name(), "randomize failed")
        s.start(m_env.m_cq_axis.sequencer);
    endtask

    protected task wait_drained(int max_cycles = 100000);
        int n = 0;
        while (!m_env.is_idle() && n < max_cycles) begin
            @(posedge m_rst_vif.clk);
            n++;
        end
        if (!m_env.is_idle())
            `uvm_error(get_type_name(),
                $sformatf({"did not drain in %0d cycles: rc %0d unconverted, ",
                           "cq %0d unconverted"},
                          max_cycles, m_env.m_rc_sb.pending_count(),
                          m_env.m_cq_sb.pending_count()))
        else
            idle(100);
    endtask

endclass : tier4a_base_test


// -----------------------------------------------------------------------------
// t4a_reset - quiescent through reset. No stimulus, so no TLP may emerge.
// -----------------------------------------------------------------------------
class t4a_reset extends tier4a_base_test;

    `uvm_component_utils(t4a_reset)

    function new(string name = "t4a_reset", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_rc_sb.m_enable_end_check = 1'b0;
        m_env.m_cq_sb.m_enable_end_check = 1'b0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t4a_reset");
        apply_power_on_reset();
        idle(100);
        m_rst_vif.inject_reset(8);
        idle(100);
        phase.drop_objection(this, "t4a_reset");
    endtask

endclass : t4a_reset


// -----------------------------------------------------------------------------
// t4a_rc_basic - one completion at a time, long enough that it cannot straddle.
//
// The first thing to look at if anything else in this tier fails: it isolates
// the descriptor conversion from the framing.
// -----------------------------------------------------------------------------
class t4a_rc_basic extends tier4a_base_test;

    `uvm_component_utils(t4a_rc_basic)

    function new(string name = "t4a_rc_basic", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_cq_sb.m_enable_end_check = 1'b0;   // RC only
        // The RC end check stays ON: this test drives RC. The straddle
        // requirement it once dodged is off by default (sb_shim.sv:71), and
        // disabling the end check also removed the drain and "never exercised"
        // guards (audit item C in docs/bringup_log.md).
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [31:0] dw [];

        phase.raise_objection(this, "t4a_rc_basic");
        apply_power_on_reset();
        idle(20);

        // 5+ payload DWORDs puts the TLP at 8 or more, filling the beat.
        for (int n = 5; n <= 12; n++) begin
            make_rc(dw, n, 8'(n), 7'(n * 4));
            send_rc(dw);
            wait_drained();
        end

        phase.drop_objection(this, "t4a_rc_basic");
    endtask

endclass : t4a_rc_basic


// -----------------------------------------------------------------------------
// t4a_rc_straddle - the test this tier exists for.
//
// Short completions leave room in the beat, so the driver pairs them and two
// TLPs share a cycle. The second begins at lane 4, which is the only other
// legal start position at 256-bit data.
//
// A lane-wise reassembler is the only structure that gets this right; a monitor
// waiting for tlast would concatenate the pair into one corrupt TLP. That is
// the failure mode §22 R2 is about, and it is silent - the data is wrong but
// nothing complains until three tiers up.
// -----------------------------------------------------------------------------
class t4a_rc_straddle extends tier4a_base_test;

    `uvm_component_utils(t4a_rc_straddle)

    function new(string name = "t4a_rc_straddle", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_cq_sb.m_enable_end_check = 1'b0;
        // This test exists to straddle. If it did not, it proved nothing.
        m_env.m_rc_sb.require_straddle = 1'b1;
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [31:0] dw [];

        phase.raise_objection(this, "t4a_rc_straddle");
        apply_power_on_reset();
        idle(20);

        // Descriptor-only completions are 3 DWORDs and leave 5 lanes free, so
        // every consecutive pair straddles.
        for (int i = 0; i < 16; i++) begin
            make_rc(dw, 0, 8'(i), 7'(i * 4));
            send_rc(dw);
        end
        wait_drained();

        // 1 payload DWORD -> 4 total, ending exactly on the slot boundary.
        for (int i = 0; i < 16; i++) begin
            make_rc(dw, 1, 8'(16 + i), 7'(i * 4));
            send_rc(dw);
        end
        wait_drained();

        phase.drop_objection(this, "t4a_rc_straddle");
    endtask

endclass : t4a_rc_straddle


// -----------------------------------------------------------------------------
// t4a_rc_len_sweep - lengths across the beat boundary.
//
// At 256 bits a beat is 8 DWORDs. 3..7 leaves room for a partner, 8 exactly
// fills, 9+ spills into a second beat. Sweeping across that boundary is what
// makes the driver's straddle decision vary, which is §14.4's sop axis.
// -----------------------------------------------------------------------------
class t4a_rc_len_sweep extends tier4a_base_test;

    `uvm_component_utils(t4a_rc_len_sweep)

    function new(string name = "t4a_rc_len_sweep", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_cq_sb.m_enable_end_check = 1'b0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [31:0] dw [];

        phase.raise_objection(this, "t4a_rc_len_sweep");
        apply_power_on_reset();
        idle(20);

        for (int n = 0; n <= 24; n++) begin
            make_rc(dw, n, 8'(n), 7'((n * 4) % 128));
            send_rc(dw);
        end
        wait_drained();

        phase.drop_objection(this, "t4a_rc_len_sweep");
    endtask

endclass : t4a_rc_len_sweep


// -----------------------------------------------------------------------------
// t4a_rc_status - every completion status code survives the conversion.
//
// The status field is three bits in the descriptor and three in the generic
// header, at different offsets. A transposition here is invisible on a
// successful completion and changes the meaning of every failing one.
// -----------------------------------------------------------------------------
class t4a_rc_status extends tier4a_base_test;

    `uvm_component_utils(t4a_rc_status)

    function new(string name = "t4a_rc_status", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_cq_sb.m_enable_end_check = 1'b0;   // RC only; RC's check stays on
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [31:0] dw [];
        bit [2:0]  codes [] = '{3'b000, 3'b001, 3'b010, 3'b100};

        phase.raise_objection(this, "t4a_rc_status");
        apply_power_on_reset();
        idle(20);

        foreach (codes[i]) begin
            make_rc(dw, 4, 8'(i), 7'h0, codes[i]);
            send_rc(dw);
            wait_drained();
        end

        phase.drop_objection(this, "t4a_rc_status");
    endtask

endclass : t4a_rc_status


// -----------------------------------------------------------------------------
// t4a_cq_basic - memory writes through the completer-request shim.
//
// CQ does not straddle at 256 bits, so this is a pure descriptor-conversion
// check: a 4-DWORD request descriptor becoming a 4DW generic header, with the
// byte enables arriving from tuser rather than from the descriptor.
// -----------------------------------------------------------------------------
class t4a_cq_basic extends tier4a_base_test;

    `uvm_component_utils(t4a_cq_basic)

    function new(string name = "t4a_cq_basic", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_rc_sb.m_enable_end_check = 1'b0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [31:0] dw [];

        phase.raise_objection(this, "t4a_cq_basic");
        apply_power_on_reset();
        idle(20);

        for (int n = 1; n <= 16; n++) begin
            make_cq(dw, n, 64'h0000_1000 + 64'(n * 64), 8'(n));
            send_cq(dw);
            wait_drained();
        end

        phase.drop_objection(this, "t4a_cq_basic");
    endtask

endclass : t4a_cq_basic


// -----------------------------------------------------------------------------
// t4a_cq_addr_sweep - the 62-bit address field, across its width.
//
// The address is the widest field in the request descriptor and it moves as a
// single slice. An off-by-one in that slice shifts every address by 4 bytes,
// which looks exactly like a DMA alignment bug two tiers up.
// -----------------------------------------------------------------------------
class t4a_cq_addr_sweep extends tier4a_base_test;

    `uvm_component_utils(t4a_cq_addr_sweep)

    function new(string name = "t4a_cq_addr_sweep", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_rc_sb.m_enable_end_check = 1'b0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [31:0] dw [];

        phase.raise_objection(this, "t4a_cq_addr_sweep");
        apply_power_on_reset();
        idle(20);

        // One address per bit position, so a misplaced slice shows up as a
        // specific bit rather than as general corruption.
        for (int b = 2; b < 62; b++) begin
            make_cq(dw, 2, 64'd1 << b, 8'(b));
            send_cq(dw);
        end
        wait_drained();

        phase.drop_objection(this, "t4a_cq_addr_sweep");
    endtask

endclass : t4a_cq_addr_sweep


// -----------------------------------------------------------------------------
// t4a_backpressure - the generic side stalls, independently per channel.
//
// The shims have no buffering worth the name, so backpressure on the output
// propagates straight to tready on the input. What this catches is a shim that
// drops or duplicates a beat while stalled - which a straddling channel makes
// much easier to get wrong, because a stall can land between two TLPs that
// share a beat.
// -----------------------------------------------------------------------------
class t4a_backpressure extends tier4a_base_test;

    `uvm_component_utils(t4a_backpressure)

    function new(string name = "t4a_backpressure", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        mqnic_bp_profile_e profs [] = '{BP_NONE, BP_RANDOM, BP_AGGRESSIVE, BP_BURSTY};
        bit [31:0] dw [];

        phase.raise_objection(this, "t4a_backpressure");
        apply_power_on_reset();
        idle(20);

        foreach (profs[p]) begin
            // Deliberately mismatched so the two channels never stall in step.
            m_env.m_rc_tlp_cfg.bp_profile = profs[p];
            m_env.m_cq_tlp_cfg.bp_profile = profs[(p + 2) % 4];

            `uvm_info(get_type_name(),
                $sformatf("RC sink %s / CQ sink %s",
                          profs[p].name(), profs[(p + 2) % 4].name()), UVM_LOW)

            for (int i = 0; i < 12; i++) begin
                make_rc(dw, i % 6, 8'(i), 7'(i * 4));
                send_rc(dw);
                make_cq(dw, (i % 5) + 1, 64'h2000 + 64'(i * 64), 8'(i));
                send_cq(dw);
            end
            wait_drained();
        end

        phase.drop_objection(this, "t4a_backpressure");
    endtask

endclass : t4a_backpressure


// -----------------------------------------------------------------------------
// t4a_both_channels - RC and CQ converting at the same time.
//
// The two shims are independent modules with no shared state, so this is not
// looking for interference - it is looking for a TESTBENCH fault: a shared
// covergroup, a shared model handle or a crossed virtual interface would show
// up here and nowhere else.
// -----------------------------------------------------------------------------
class t4a_both_channels extends tier4a_base_test;

    `uvm_component_utils(t4a_both_channels)

    function new(string name = "t4a_both_channels", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [31:0] dw [];

        phase.raise_objection(this, "t4a_both_channels");
        apply_power_on_reset();
        idle(20);

        for (int round = 0; round < 8; round++) begin
            for (int i = 0; i < 8; i++) begin
                make_rc(dw, i % 7, 8'(round * 8 + i), 7'(i * 4));
                send_rc(dw);
                make_cq(dw, (i % 6) + 1,
                        64'h4000 + 64'(round * 512 + i * 64), 8'(i));
                send_cq(dw);
            end
            wait_drained();
        end

        phase.drop_objection(this, "t4a_both_channels");
    endtask

endclass : t4a_both_channels


// -----------------------------------------------------------------------------
// t4a_random_stress - randomized traffic on both channels.
//
// Lengths are biased short by pcie_us_axis_random_seq, because short TLPs are
// the ones that leave room for a partner. A stress test made of long TLPs never
// straddles and so never exercises the thing this tier is for.
// -----------------------------------------------------------------------------
class t4a_random_stress extends tier4a_base_test;

    `uvm_component_utils(t4a_random_stress)

    function new(string name = "t4a_random_stress", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        // Short lengths are biased in, so a run with NO straddle at all means
        // the driver stopped pairing - which is exactly how bug 18 hid.
        m_env.m_rc_sb.require_straddle = 1'b1;
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [31:0] dw [];

        phase.raise_objection(this, "t4a_random_stress");
        apply_power_on_reset();
        idle(20);

        for (int round = 0; round < 10; round++) begin
            for (int i = 0; i < 12; i++) begin
                make_rc(dw, $urandom_range(0, 10), 8'($urandom), 7'($urandom));
                send_rc(dw);
            end
            for (int i = 0; i < 12; i++) begin
                make_cq(dw, $urandom_range(1, 10),
                        64'($urandom) << 2, 8'($urandom));
                send_cq(dw);
            end
            wait_drained();
        end

        phase.drop_objection(this, "t4a_random_stress");
    endtask

endclass : t4a_random_stress


// -----------------------------------------------------------------------------
// t4a_cov_closure - the straddle shapes the other tests never produce.
//
// Until the monitor recorded start_lane, every TLP was sampled as starting in
// slot 0, so the slot-1 bins were unreachable and nobody noticed that no test
// steered WHERE the second TLP of a pair ends. Here the first TLP of each pair
// is a 3-DWORD descriptor-only completion (always leaves slot 1 free), and the
// second sweeps 3..24 DWORDs: its end lane (4 + n - 1) % 8 visits all eight
// lanes and its length every class, including multi-beat.
//
// CQ: a memory READ is a 4-DWORD descriptor with no payload - the one CQ
// length class the write-only tests above cannot reach.
// -----------------------------------------------------------------------------
class t4a_cov_closure extends tier4a_base_test;

    `uvm_component_utils(t4a_cov_closure)

    function new(string name = "t4a_cov_closure", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_rc_sb.require_straddle = 1'b1;
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [31:0] dw [];

        phase.raise_objection(this, "t4a_cov_closure");
        apply_power_on_reset();
        idle(20);

        for (int n = 3; n <= 24; n++) begin
            make_rc(dw, 0, 8'(2 * n), 7'h0);
            send_rc(dw);
            make_rc(dw, n - 3, 8'(2 * n + 1), 7'((n * 4) % 128));
            send_rc(dw);
        end
        wait_drained();

        for (int i = 0; i < 8; i++) begin
            make_cq(dw, 0, 64'h0000_8000 + 64'(i * 64), 8'(i));
            send_cq(dw);
        end
        wait_drained();

        phase.drop_objection(this, "t4a_cov_closure");
    endtask

endclass : t4a_cov_closure

`endif // TIER4A_TESTS_SV

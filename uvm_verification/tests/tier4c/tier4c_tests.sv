// SPDX-License-Identifier: BSD-2-Clause-Views
//
// Tier 4c test suite - pcie_us_if_rq
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §13 Tier 4
// Introduced : Step 6 (Tier 4c)
//
// The two properties only this DUT has: ARBITRATION between two input streams,
// and FLOW CONTROL gating both.
//
// FIXED PRIORITY MAKES THE WRITE PORT NEARLY INVISIBLE BY DEFAULT. Read
// requests win whenever they have credit, so a test that leaves both pools full
// barely exercises the posted path. Several tests below therefore starve one
// pool deliberately - that is not a corner case here, it is the only way to see
// the behaviour at all.
// -----------------------------------------------------------------------------

`ifndef TIER4C_TESTS_SV
`define TIER4C_TESTS_SV

class tier4c_base_test extends mqnic_base_test;

    `uvm_component_utils(tier4c_base_test)

    tier4c_env m_env;
    virtual pcie_us_fc_if m_fc_vif;

    function new(string name = "tier4c_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        m_env = tier4c_env::type_id::create("m_env", this);
        if (!uvm_config_db #(virtual pcie_us_fc_if)::get(this, "", "fc_vif", m_fc_vif))
            `uvm_fatal(get_type_name(), "no pcie_us_fc_if in config_db under key fc_vif")
    endfunction

    // -------------------------------------------------------------------------
    // The ONLY place credits are written. The interface feeds the DUT and the
    // model feeds the arbitration check; if they disagree the scoreboard is
    // checking the DUT against a fiction - the same discipline as
    // tier3_base_test.set_config().
    // -------------------------------------------------------------------------
    typedef enum { FC_UNLIMITED, FC_STARVE_ALL, FC_STARVE_NP, FC_STARVE_P } fc_mode_e;

    protected virtual function void set_credits(fc_mode_e m);
        case (m)
            FC_UNLIMITED:  m_fc_vif.init_unlimited();
            FC_STARVE_ALL: m_fc_vif.starve_all();
            FC_STARVE_NP:  m_fc_vif.starve_np();
            FC_STARVE_P:   m_fc_vif.starve_p();
        endcase

        m_env.m_arb.tx_fc_ph_av      = m_fc_vif.tx_fc_ph_av;
        m_env.m_arb.tx_fc_pd_av      = m_fc_vif.tx_fc_pd_av;
        m_env.m_arb.tx_fc_nph_av     = m_fc_vif.tx_fc_nph_av;
        m_env.m_arb.tx_fc_npd_av     = m_fc_vif.tx_fc_npd_av;
        m_env.m_arb.max_payload_size = 3'd1;   // matches the DUT pin

        `uvm_info(get_type_name(),
            $sformatf("credits: %s -> %s", m.name(), m_env.m_arb.convert2string()),
            UVM_LOW)
    endfunction

    virtual function void start_of_simulation_phase(uvm_phase phase);
        super.start_of_simulation_phase(phase);
        set_credits(FC_UNLIMITED);
    endfunction

    protected task idle(int n);
        repeat (n) @(posedge m_rst_vif.clk);
    endtask

    // A memory read request: header only, no payload.
    protected task send_rd(bit [63:0] addr, int unsigned dw_len, bit [7:0] tag);
        pcie_tlp_single_seq s;
        bit [127:0] hdr = mqnic_vrf_pkg::tlp_hdr_read_req(addr, dw_len, tag, 16'h0200);
        s = pcie_tlp_single_seq::type_id::create("rd");
        if (!s.randomize() with { hdr == local::hdr; payload_bytes == 0;
                                  delay inside {[0:2]}; })
            `uvm_fatal(get_type_name(), "randomize failed")
        s.start(m_env.m_rd_tlp.sequencer);
    endtask

    // A memory write request: header plus payload.
    protected task send_wr(bit [63:0] addr, int unsigned dw_len, bit [7:0] tag);
        pcie_tlp_single_seq s;
        bit [127:0] hdr = '0;
        hdr[127:125] = mqnic_vrf_pkg::TLP_FMT_4DW_DATA;
        hdr[124:120] = 5'b00000;
        hdr[105:96]  = 10'(dw_len);
        hdr[95:80]   = 16'h0200;
        hdr[79:72]   = tag;
        hdr[71:64]   = 8'hFF;
        hdr[63:2]    = addr[63:2];

        s = pcie_tlp_single_seq::type_id::create("wr");
        if (!s.randomize() with { hdr == local::hdr;
                                  payload_bytes == local::dw_len * 4;
                                  delay inside {[0:2]}; })
            `uvm_fatal(get_type_name(), "randomize failed")
        s.start(m_env.m_wr_tlp.sequencer);
    endtask

    protected task wait_drained(int max_cycles = 100000);
        int n = 0;
        while (!m_env.is_idle() && n < max_cycles) begin
            @(posedge m_rst_vif.clk);
            n++;
        end
        if (!m_env.is_idle())
            `uvm_error(get_type_name(),
                $sformatf("did not drain in %0d cycles: %0d unconverted",
                          max_cycles, m_env.m_sb.pending_count()))
        else
            idle(100);
    endtask

endclass : tier4c_base_test


// -----------------------------------------------------------------------------
// t4c_reset - quiescent through reset.
// -----------------------------------------------------------------------------
class t4c_reset extends tier4c_base_test;
    `uvm_component_utils(t4c_reset)
    function new(string name = "t4c_reset", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_sb.m_enable_end_check = 1'b0;
    endfunction
    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t4c_reset");
        apply_power_on_reset();
        idle(100);
        m_rst_vif.inject_reset(8);
        idle(100);
        phase.drop_objection(this, "t4c_reset");
    endtask
endclass


// -----------------------------------------------------------------------------
// t4c_read_only - read requests alone, credits unlimited.
//
// Isolates the non-posted descriptor build from the arbitration.
// -----------------------------------------------------------------------------
class t4c_read_only extends tier4c_base_test;
    `uvm_component_utils(t4c_read_only)
    function new(string name = "t4c_read_only", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t4c_read_only");
        apply_power_on_reset();
        idle(20);
        for (int i = 1; i <= 16; i++)
            send_rd(64'h1000 + 64'(i * 64), i, 8'(i));
        wait_drained();
        phase.drop_objection(this, "t4c_read_only");
    endtask
endclass


// -----------------------------------------------------------------------------
// t4c_write_only - write requests alone.
//
// Reachable ONLY because no read request is pending. With both streams active
// and both pools full the fixed priority would starve this path entirely.
// -----------------------------------------------------------------------------
class t4c_write_only extends tier4c_base_test;
    `uvm_component_utils(t4c_write_only)
    function new(string name = "t4c_write_only", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t4c_write_only");
        apply_power_on_reset();
        idle(20);
        for (int i = 1; i <= 16; i++)
            send_wr(64'h2000 + 64'(i * 64), i, 8'(i));
        wait_drained();
        phase.drop_objection(this, "t4c_write_only");
    endtask
endclass


// -----------------------------------------------------------------------------
// t4c_both_streams - both ports active at once.
//
// Originally written as a priority check, and that was wrong: the arbiter works
// on per-port FIFO occupancy, which is not observable from the interface, so
// "a read was pending so a read must emerge" compares the scoreboard's queue
// against something else entirely. See the note in sb_rq.
//
// What this test DOES check, and it is not nothing: every TLP from both streams
// converts correctly and none is lost when the two are merged. A merge that
// dropped, duplicated or corrupted a TLP under contention fails here.
//
// The counts per source port are reported rather than asserted - a distribution
// is a fact about this DUT's arbitration, not a requirement the interface can
// express.
// -----------------------------------------------------------------------------
class t4c_both_streams extends tier4c_base_test;
    `uvm_component_utils(t4c_both_streams)
    function new(string name = "t4c_both_streams", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t4c_both_streams");
        apply_power_on_reset();
        idle(20);

        // Interleaved so both queues are non-empty when the DUT chooses.
        for (int i = 1; i <= 12; i++) begin
            send_rd(64'h1000 + 64'(i * 64), (i % 8) + 1, 8'(i));
            send_wr(64'h2000 + 64'(i * 64), (i % 6) + 1, 8'h40 + 8'(i));
        end
        wait_drained();

        `uvm_info(get_type_name(),
            $sformatf("merged %0d from the read port and %0d from the write port",
                      m_env.m_sb.from_read(), m_env.m_sb.from_write()), UVM_LOW)

        phase.drop_objection(this, "t4c_both_streams");
    endtask
endclass


// -----------------------------------------------------------------------------
// t4c_starve_np - the read port loses its credit, so the write port proceeds.
//
// The complement of t4c_priority: with non-posted credit below threshold the
// fixed priority no longer applies, and the posted stream must flow. A DUT that
// stalled everything when the higher-priority port was blocked would pass every
// other test here.
// -----------------------------------------------------------------------------
class t4c_starve_np extends tier4c_base_test;
    `uvm_component_utils(t4c_starve_np)
    function new(string name = "t4c_starve_np", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t4c_starve_np");
        apply_power_on_reset();
        idle(20);

        set_credits(FC_STARVE_NP);
        idle(20);

        for (int i = 1; i <= 12; i++)
            send_wr(64'h3000 + 64'(i * 64), (i % 6) + 1, 8'(i));
        wait_drained();

        phase.drop_objection(this, "t4c_starve_np");
    endtask
endclass


// -----------------------------------------------------------------------------
// t4c_starve_all - no credit anywhere, so nothing may be transmitted.
//
// THE PROPERTY IS SILENCE, and a scoreboard that only inspects what did appear
// passes that trivially. sb_rq.expect_silence makes the absence a positive
// check: any RQ TLP at all is a failure.
// -----------------------------------------------------------------------------
class t4c_starve_all extends tier4c_base_test;
    `uvm_component_utils(t4c_starve_all)
    function new(string name = "t4c_starve_all", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_sb.expect_silence = 1'b1;
        // Nothing is expected to convert, so the "did you check anything" rule
        // does not apply - what is being checked is that nothing happened.
        m_env.m_sb.m_enable_end_check = 1'b0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t4c_starve_all");
        apply_power_on_reset();
        idle(20);

        set_credits(FC_STARVE_ALL);
        idle(20);

        for (int i = 1; i <= 8; i++) begin
            send_rd(64'h4000 + 64'(i * 64), 4, 8'(i));
            send_wr(64'h5000 + 64'(i * 64), 4, 8'h40 + 8'(i));
        end
        idle(5000);          // long enough for anything to have escaped

        phase.drop_objection(this, "t4c_starve_all");
    endtask
endclass


// -----------------------------------------------------------------------------
// t4c_credit_release - starved, then released; the backlog must drain.
//
// The interesting half of flow control is not the stall, it is the RESTART.
// -----------------------------------------------------------------------------
class t4c_credit_release extends tier4c_base_test;
    `uvm_component_utils(t4c_credit_release)
    function new(string name = "t4c_credit_release", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t4c_credit_release");
        apply_power_on_reset();
        idle(20);

        // Queue work while nothing may move.
        m_env.m_sb.expect_silence = 1'b1;
        set_credits(FC_STARVE_ALL);
        idle(20);
        for (int i = 1; i <= 8; i++)
            send_rd(64'h6000 + 64'(i * 64), 4, 8'(i));
        idle(2000);

        // Release, and the backlog must come out.
        m_env.m_sb.expect_silence = 1'b0;
        set_credits(FC_UNLIMITED);
        idle(20);
        wait_drained();

        phase.drop_objection(this, "t4c_credit_release");
    endtask
endclass


// -----------------------------------------------------------------------------
// t4c_random_stress - both streams, credits changing between rounds.
// -----------------------------------------------------------------------------
class t4c_random_stress extends tier4c_base_test;
    `uvm_component_utils(t4c_random_stress)
    function new(string name = "t4c_random_stress", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        fc_mode_e modes [] = '{FC_UNLIMITED, FC_STARVE_NP, FC_UNLIMITED, FC_STARVE_P};

        phase.raise_objection(this, "t4c_random_stress");
        apply_power_on_reset();
        idle(20);

        foreach (modes[m]) begin
            set_credits(modes[m]);
            idle(20);
            for (int i = 0; i < 10; i++) begin
                // Under FC_STARVE_P the write port cannot move, so only queue
                // what the configuration allows to drain - otherwise the test
                // would fail its own drain wait rather than the DUT.
                if (modes[m] != FC_STARVE_NP)
                    send_rd(64'h7000 + 64'(i * 64), $urandom_range(1, 8), 8'($urandom));
                if (modes[m] != FC_STARVE_P)
                    send_wr(64'h8000 + 64'(i * 64), $urandom_range(1, 6), 8'($urandom));
            end
            wait_drained();
        end

        phase.drop_objection(this, "t4c_random_stress");
    endtask
endclass


// -----------------------------------------------------------------------------
// t4c_starve_with_backlog - the flow-control case the other tests never make:
// one port transmits while the OTHER is out of credit WITH requests queued.
// (t4c_starve_np drives only writes; nothing had reads waiting behind the NP
// starvation, and nothing had writes waiting behind P starvation - cg_rq's two
// missing x_arb bins.) The queued port must stay silent (sb_rq's credit rule),
// then everything must drain once credit is restored.
// -----------------------------------------------------------------------------
class t4c_starve_with_backlog extends tier4c_base_test;
    `uvm_component_utils(t4c_starve_with_backlog)
    function new(string name = "t4c_starve_with_backlog", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t4c_starve_with_backlog");
        apply_power_on_reset();
        idle(20);

        // Reads queued behind NP starvation while writes flow.
        set_credits(FC_STARVE_NP);
        idle(20);
        for (int i = 0; i < 6; i++) send_rd(64'h5000 + 64'(i * 64), 1 + i, 8'(8'h40 + i));
        for (int i = 0; i < 10; i++) send_wr(64'h6000 + 64'(i * 64), (i % 4) + 1, 8'(8'h50 + i));
        idle(200);
        set_credits(FC_UNLIMITED);
        wait_drained();

        // Writes queued behind P starvation while reads flow.
        set_credits(FC_STARVE_P);
        idle(20);
        for (int i = 0; i < 6; i++) send_wr(64'h7000 + 64'(i * 64), (i % 4) + 1, 8'(8'h60 + i));
        for (int i = 0; i < 10; i++) send_rd(64'h8000 + 64'(i * 64), 1 + (i % 4), 8'(8'h70 + i));
        idle(200);
        set_credits(FC_UNLIMITED);
        wait_drained();

        phase.drop_objection(this, "t4c_starve_with_backlog");
    endtask
endclass

`endif // TIER4C_TESTS_SV

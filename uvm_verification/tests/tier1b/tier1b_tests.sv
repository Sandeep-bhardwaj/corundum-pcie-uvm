// SPDX-License-Identifier: BSD-2-Clause-Views
//
// Tier 1b test suite - TLP routing and buffering
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §13 Tier 1b
// Introduced : Step 2
//
// The demux is configured as mqnic_core_pcie configures it: BAR_BASE=0,
// BAR_STRIDE=2 over 2 ports. So BAR 0 -> port 0, BAR 2 -> port 1, and BAR 1,
// 3, 4, 5 match nothing and must be dropped.
// -----------------------------------------------------------------------------

`ifndef TIER1B_TESTS_SV
`define TIER1B_TESTS_SV

class tier1b_base_test extends mqnic_base_test;

    `uvm_component_utils(tier1b_base_test)

    tier1b_env m_env;

    function new(string name = "tier1b_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        m_env = tier1b_env::type_id::create("m_env", this);
    endfunction

    // The demux tests never drive the mux, so its scoreboard would otherwise
    // fail them as "never exercised". tier1b_mux_base_test switches it back on.
    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        if (m_env.has_mux) m_env.m_sb_mux.m_enable_end_check = 1'b0;
    endfunction

    // Synthetic but well-formed header. The Tier 1b DUTs do not interpret it;
    // what matters is that the same 128 bits come back out.
    protected function bit [127:0] make_hdr(int unsigned len_dw, bit has_payload,
                                            bit [7:0] tag = 8'h00);
        bit [127:0] h = '0;
        h[9:0]    = len_dw[9:0];
        h[126]    = has_payload;       // fmt bit 1: payload present
        h[103:96] = tag;
        h[63:32]  = 32'hA5A5_0000 | {24'd0, tag};
        return h;
    endfunction

    protected task send_dmx(bit [2:0] bar_id, int unsigned payload_bytes,
                            bit [7:0] tag = 8'h00, int delay = 2);
        pcie_tlp_single_seq s = pcie_tlp_single_seq::type_id::create("s");
        s.hdr           = make_hdr(payload_bytes / 4, payload_bytes != 0, tag);
        s.bar_id        = bar_id;
        s.func_num      = 8'h00;
        s.payload_bytes = payload_bytes;
        s.delay         = delay;
        s.start(m_env.m_dmx_in.sequencer);
    endtask

    protected task idle(int n);
        repeat (n) @(posedge m_rst_vif.clk);
    endtask

endclass : tier1b_base_test


// -----------------------------------------------------------------------------
// t1b_reset - both DUTs quiescent through reset. No traffic, so the drain check
// is disabled (the documented exception in mqnic_scoreboard_base).
// -----------------------------------------------------------------------------
class t1b_reset extends tier1b_base_test;

    `uvm_component_utils(t1b_reset)

    function new(string name = "t1b_reset", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_sb_dmx.m_enable_end_check = 1'b0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t1b_reset");
        apply_power_on_reset();
        idle(50);
        m_rst_vif.inject_reset(5);
        idle(50);
        phase.drop_objection(this, "t1b_reset");
    endtask

endclass : t1b_reset


// -----------------------------------------------------------------------------
// t1b_bar_route - the core property: every BAR reaches exactly the port that
// owns it, and unmatched BARs reach nobody.
// -----------------------------------------------------------------------------
class t1b_bar_route extends tier1b_base_test;

    `uvm_component_utils(t1b_bar_route)

    function new(string name = "t1b_bar_route", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t1b_bar_route");
        apply_power_on_reset();
        idle(10);

        // Matching BARs.
        send_dmx(3'd0, 32, 8'h10);   idle(20);   // -> port 0
        send_dmx(3'd2, 32, 8'h11);   idle(20);   // -> port 1
        send_dmx(3'd0,  0, 8'h12);   idle(20);   // header-only, port 0
        send_dmx(3'd2,  0, 8'h13);   idle(20);   // header-only, port 1

        // Non-matching BARs with BAR_STRIDE=2: must be dropped, not leaked to
        // port 0. A demux that defaulted unmatched traffic anywhere fails here.
        send_dmx(3'd1, 16, 8'h20);   idle(20);
        send_dmx(3'd3, 16, 8'h21);   idle(20);
        send_dmx(3'd4, 16, 8'h22);   idle(20);
        send_dmx(3'd5, 16, 8'h23);   idle(20);

        // Interleave matching and non-matching.
        for (int i = 0; i < 8; i++) begin
            send_dmx(3'(i % 6), 32, 8'(8'h30 + i));
            idle(15);
        end
        idle(60);

        phase.drop_objection(this, "t1b_bar_route");
    endtask

endclass : t1b_bar_route


// -----------------------------------------------------------------------------
// t1b_len_sweep - payload length across beat boundaries. At 256 bits a beat is
// 32 bytes, so 0..96 covers header-only, part-beat, exact-beat and multi-beat.
// -----------------------------------------------------------------------------
class t1b_len_sweep extends tier1b_base_test;

    `uvm_component_utils(t1b_len_sweep)

    function new(string name = "t1b_len_sweep", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t1b_len_sweep");
        apply_power_on_reset();
        idle(10);

        for (int len = 0; len <= 96; len += 4) begin
            send_dmx(3'd0, len, 8'(len));
            idle(12);
            send_dmx(3'd2, len, 8'(len));
            idle(12);
        end
        idle(80);

        phase.drop_objection(this, "t1b_len_sweep");
    endtask

endclass : t1b_len_sweep


// -----------------------------------------------------------------------------
// t1b_backpressure - aggressive consumer backpressure on every output. The FIFO
// must fill and drain without losing or reordering, and the demux must stall
// its input rather than drop.
// -----------------------------------------------------------------------------
class t1b_backpressure extends tier1b_base_test;

    `uvm_component_utils(t1b_backpressure)

    function new(string name = "t1b_backpressure", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // Backpressure profiles are read by the sink drivers in run_phase, so
    // setting them at end_of_elaboration is early enough.
    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        foreach (m_env.m_dmx_out_cfg[p])
            m_env.m_dmx_out_cfg[p].bp_profile = BP_AGGRESSIVE;
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t1b_backpressure");
        apply_power_on_reset();
        idle(10);

        for (int i = 0; i < 24; i++) begin
            send_dmx((i % 2) ? 3'd2 : 3'd0, 32, 8'(i), 0);
            idle(4);
        end
        idle(400);

        phase.drop_objection(this, "t1b_backpressure");
    endtask

endclass : t1b_backpressure


// -----------------------------------------------------------------------------
// t1b_random_stress - randomized traffic into both DUTs concurrently.
// -----------------------------------------------------------------------------
class t1b_random_stress extends tier1b_base_test;

    `uvm_component_utils(t1b_random_stress)

    function new(string name = "t1b_random_stress", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        pcie_tlp_random_seq sd;

        phase.raise_objection(this, "t1b_random_stress");
        apply_power_on_reset();
        idle(10);

        sd = pcie_tlp_random_seq::type_id::create("sd");
        if (!sd.randomize() with { n_tlps == 48; bar_lo == 0; bar_hi == 5;
                                   max_payload == 96; })
            `uvm_fatal(get_type_name(), "randomize failed")

        sd.start(m_env.m_dmx_in.sequencer);
        idle(400);

        phase.drop_objection(this, "t1b_random_stress");
    endtask

endclass : t1b_random_stress


// =============================================================================
// pcie_tlp_mux - two inputs merged onto one output, round-robin, as
// mqnic_core_pcie.v:778-785 uses it (control-path and application completions).
//
// sb_tlp in merge mode checks every output TLP is the NEXT TLP of exactly one
// input (bit-identical header, payload, bar/func/error/seq), so loss,
// duplication, corruption, per-port reordering and interleaving all fail.
// tb_top_tier1b asserts a paused port is never selected.
// =============================================================================
class tier1b_mux_base_test extends tier1b_base_test;

    `uvm_component_utils(tier1b_mux_base_test)

    function new(string name = "tier1b_mux_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        if (!m_env.has_mux)
            `uvm_fatal(get_type_name(), "this top has no pcie_tlp_mux - run it on tb_top_tier1b")
        m_env.m_sb_mux.m_enable_end_check = 1'b1;
        m_env.m_sb_dmx.m_enable_end_check = 1'b0;   // demux is not driven here
    endfunction

    // n TLPs into one mux input. delay_max = 0 keeps the port saturated.
    protected task send_mux(int port, int n, int unsigned max_payload = 96,
                            int unsigned delay_max = 4);
        pcie_tlp_single_seq s;
        int unsigned        len;
        for (int i = 0; i < n; i++) begin
            s = pcie_tlp_single_seq::type_id::create($sformatf("mux%0d_%0d", port, i));
            // Chosen HERE, not as `payload_bytes <= max`: the sequence's
            // `soft payload_bytes == 0` satisfies that bound, so every mux TLP
            // was header-only until cg_tlp's length bins showed it.
            len = 4 * $urandom_range(0, max_payload / 4);
            if (!s.randomize() with { payload_bytes == local::len;
                                      delay <= local::delay_max;
                                      bar_id inside {[0:5]}; })
                `uvm_fatal(get_type_name(), "randomize failed")
            s.start(m_env.m_mux_in[port].sequencer);
        end
    endtask

    protected task set_pause(bit [1:0] p);
        m_env.m_mux_pause.pause = p;
        idle(2);
    endtask

    // Wait for every sent TLP to come out, rather than guessing a delay.
    protected task wait_mux_drained(int max_cycles = 20000);
        int n = 0;
        while (m_env.m_sb_mux.pending_count() != 0 && n < max_cycles) begin
            @(posedge m_rst_vif.clk);
            n++;
        end
        idle(20);
        if (m_env.m_sb_mux.pending_count() != 0)
            `uvm_error(get_type_name(),
                $sformatf("%0d TLP(s) never left the mux after %0d cycles",
                          m_env.m_sb_mux.pending_count(), max_cycles))
    endtask

endclass : tier1b_mux_base_test


// t1b_mux_basic - each port alone, then both, over a length sweep.
class t1b_mux_basic extends tier1b_mux_base_test;

    `uvm_component_utils(t1b_mux_basic)

    function new(string name = "t1b_mux_basic", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t1b_mux_basic");
        apply_power_on_reset();
        idle(10);

        send_mux(0, 12);
        wait_mux_drained();
        send_mux(1, 12);
        wait_mux_drained();
        fork
            send_mux(0, 16);
            send_mux(1, 16);
        join
        wait_mux_drained();

        phase.drop_objection(this, "t1b_mux_basic");
    endtask

endclass : t1b_mux_basic


// t1b_mux_arbitration - STRATEGY §13: "fairness, no starvation". Both inputs
// saturated; round-robin must alternate, so no port may win more than twice in
// a row while the other waits (1 is the ideal; 2 allows the input register).
class t1b_mux_arbitration extends tier1b_mux_base_test;

    `uvm_component_utils(t1b_mux_arbitration)

    function new(string name = "t1b_mux_arbitration", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_sb_mux.max_run_while_waiting = 2;
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t1b_mux_arbitration");
        apply_power_on_reset();
        idle(10);

        // Saturated, output never stalls.
        m_env.m_mux_out_cfg.bp_profile = BP_NONE;
        fork
            send_mux(0, 40, 64, 0);
            send_mux(1, 40, 64, 0);
        join
        wait_mux_drained();

        // Saturated, output stalling at random: fairness must survive it.
        m_env.m_mux_out_cfg.bp_profile = BP_RANDOM;
        fork
            send_mux(0, 40, 64, 0);
            send_mux(1, 40, 64, 0);
        join
        wait_mux_drained();

        // Unequal lengths: a port sending long TLPs must not starve the other.
        fork
            send_mux(0, 30, 256, 0);
            send_mux(1, 30, 0, 0);
        join
        wait_mux_drained();

        if (m_env.m_sb_mux.m_per_port_out[0] == 0 || m_env.m_sb_mux.m_per_port_out[1] == 0)
            `uvm_error(get_type_name(), "a port produced no output at all")
        `uvm_info(get_type_name(),
            $sformatf("longest same-port run while the other waited: %0d",
                      m_env.m_sb_mux.m_worst_run), UVM_LOW)

        phase.drop_objection(this, "t1b_mux_arbitration");
    endtask

endclass : t1b_mux_arbitration


// t1b_mux_pause - a paused port is never selected (SVA in the top), the other
// port keeps flowing, and nothing is lost when the pause is released.
class t1b_mux_pause extends tier1b_mux_base_test;

    `uvm_component_utils(t1b_mux_pause)

    function new(string name = "t1b_mux_pause", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        int p1_before;

        phase.raise_objection(this, "t1b_mux_pause");
        apply_power_on_reset();
        idle(10);

        for (int which = 0; which < 2; which++) begin
            int other = 1 - which;
            set_pause(2'(1 << which));
            p1_before = m_env.m_sb_mux.m_per_port_out[other];
            // The paused port's sender blocks until the pause lifts, so it must
            // not be joined before the pause is released.
            fork
                send_mux(which, 10, 64, 0);
            join_none
            send_mux(other, 10, 64, 0);
            idle(300);
            if (m_env.m_sb_mux.m_per_port_out[other] - p1_before != 10)
                `uvm_error(get_type_name(),
                    $sformatf("port %0d delivered %0d of 10 TLPs while port %0d was paused",
                              other, m_env.m_sb_mux.m_per_port_out[other] - p1_before, which))
            set_pause(2'b00);
            wait fork;
            wait_mux_drained();
        end

        phase.drop_objection(this, "t1b_mux_pause");
    endtask

endclass : t1b_mux_pause


// t1b_mux_random_stress - random lengths, gaps, backpressure and pause toggling.
class t1b_mux_random_stress extends tier1b_mux_base_test;

    `uvm_component_utils(t1b_mux_random_stress)

    function new(string name = "t1b_mux_random_stress", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t1b_mux_random_stress");
        apply_power_on_reset();
        idle(10);
        m_env.m_mux_out_cfg.bp_profile = BP_BURSTY;

        fork
            send_mux(0, 60, 256, 8);
            send_mux(1, 60, 256, 8);
            begin : pause_toggler
                repeat (30) begin
                    set_pause(2'($urandom_range(0, 3)));
                    idle($urandom_range(5, 60));
                end
                set_pause(2'b00);
            end
        join
        wait_mux_drained();

        phase.drop_objection(this, "t1b_mux_random_stress");
    endtask

endclass : t1b_mux_random_stress

`endif // TIER1B_TESTS_SV

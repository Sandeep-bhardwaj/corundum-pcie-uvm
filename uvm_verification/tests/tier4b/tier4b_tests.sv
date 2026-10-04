// SPDX-License-Identifier: BSD-2-Clause-Views
//
// Tier 4b test suite - pcie_us_if_cc
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §13 Tier 4, §19 Tier 4
// Introduced : Step 6 (Tier 4b)
//
// The transmit direction: a generic completion goes in, a Xilinx CC descriptor
// plus payload comes out. §19's Tier 4 criterion is bidirectional equivalence,
// and this suite is the second half of it.
//
// CC DOES NOT STRADDLE at the golden 256-bit width
// (mqnic_core_pcie_us.v:166 - CC_STRADDLE is DATA_WIDTH >= 512), so there is no
// straddle test here and none is missing. The straddle weight of Tier 4 sits on
// RC, which is where the suite puts it.
//
// Completions are built with the same helper the rest of the environment uses;
// sb_shim converts them through ref_tlp_shim. Nothing in this file knows a
// descriptor bit position.
// -----------------------------------------------------------------------------

`ifndef TIER4B_TESTS_SV
`define TIER4B_TESTS_SV

class tier4b_base_test extends mqnic_base_test;

    `uvm_component_utils(tier4b_base_test)

    tier4b_env m_env;

    function new(string name = "tier4b_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        m_env = tier4b_env::type_id::create("m_env", this);
    endfunction

    protected task idle(int n);
        repeat (n) @(posedge m_rst_vif.clk);
    endtask

    // Drive one completion on the generic side.
    protected task send_cpl(int unsigned payload_dw,
                            bit [7:0]    tag        = 8'h30,
                            bit [6:0]    lower_addr = 7'h00,
                            bit [2:0]    status     = 3'b000,
                            bit          poisoned   = 1'b0);
        pcie_tlp_single_seq s;
        bit [127:0]         hdr;

        hdr = mqnic_vrf_pkg::tlp_hdr_completion(
                  .completer_id(16'h0100), .status(status),
                  .byte_count(payload_dw * 4), .requester_id(16'h0200),
                  .tag(tag), .lower_addr(lower_addr),
                  .dw_len(payload_dw), .poisoned(poisoned));

        s = pcie_tlp_single_seq::type_id::create("cpl");
        if (!s.randomize() with { hdr           == local::hdr;
                                  payload_bytes == local::payload_dw * 4;
                                  delay inside {[0:3]}; })
            `uvm_fatal(get_type_name(), "randomize failed")
        s.start(m_env.m_cc_tlp.sequencer);
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
                          max_cycles, m_env.m_cc_sb.pending_count()))
        else
            idle(100);
    endtask

endclass : tier4b_base_test


// -----------------------------------------------------------------------------
// t4b_reset - quiescent through reset.
// -----------------------------------------------------------------------------
class t4b_reset extends tier4b_base_test;

    `uvm_component_utils(t4b_reset)

    function new(string name = "t4b_reset", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_cc_sb.m_enable_end_check = 1'b0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t4b_reset");
        apply_power_on_reset();
        idle(100);
        m_rst_vif.inject_reset(8);
        idle(100);
        phase.drop_objection(this, "t4b_reset");
    endtask

endclass : t4b_reset


// -----------------------------------------------------------------------------
// t4b_cpl_basic - one completion at a time.
//
// The first thing to look at if anything else here fails: it isolates the
// descriptor build from the framing and the backpressure.
// -----------------------------------------------------------------------------
class t4b_cpl_basic extends tier4b_base_test;

    `uvm_component_utils(t4b_cpl_basic)

    function new(string name = "t4b_cpl_basic", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t4b_cpl_basic");
        apply_power_on_reset();
        idle(20);

        for (int n = 1; n <= 8; n++) begin
            send_cpl(n, 8'(n), 7'(n * 4));
            wait_drained();
        end

        phase.drop_objection(this, "t4b_cpl_basic");
    endtask

endclass : t4b_cpl_basic


// -----------------------------------------------------------------------------
// t4b_len_sweep - payload lengths across the beat boundary.
//
// At 256 bits a beat is 8 DWORDs and the CC descriptor eats 3 of them, so a
// completion of 5 payload DWORDs is the first that spills into a second beat.
// Sweeping across that is what exercises the multi-beat packing.
// -----------------------------------------------------------------------------
class t4b_len_sweep extends tier4b_base_test;

    `uvm_component_utils(t4b_len_sweep)

    function new(string name = "t4b_len_sweep", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t4b_len_sweep");
        apply_power_on_reset();
        idle(20);

        for (int n = 0; n <= 32; n++) begin
            send_cpl(n, 8'(n), 7'((n * 4) % 128));
        end
        wait_drained();

        phase.drop_objection(this, "t4b_len_sweep");
    endtask

endclass : t4b_len_sweep


// -----------------------------------------------------------------------------
// t4b_status - every completion status survives the build.
//
// The status is three bits at [79:77] of the generic header and [45:43] of the
// descriptor. A transposition is invisible on a successful completion and
// changes the meaning of every failing one - the mirror of t4_rc_status.
// -----------------------------------------------------------------------------
class t4b_status extends tier4b_base_test;

    `uvm_component_utils(t4b_status)

    function new(string name = "t4b_status", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [2:0] codes [] = '{3'b000, 3'b001, 3'b010, 3'b100};

        phase.raise_objection(this, "t4b_status");
        apply_power_on_reset();
        idle(20);

        foreach (codes[i]) begin
            send_cpl(4, 8'(i), 7'h0, codes[i]);
            wait_drained();
        end

        // Poisoned completions take a different descriptor bit ([46]) from the
        // status field, so they are swept separately rather than crossed.
        for (int i = 0; i < 4; i++) begin
            send_cpl(4, 8'h40 + 8'(i), 7'h0, 3'b000, 1'b1);
            wait_drained();
        end

        phase.drop_objection(this, "t4b_status");
    endtask

endclass : t4b_status


// -----------------------------------------------------------------------------
// t4b_lower_addr - the 7-bit lower-address field, across its width.
//
// It is the field the requester uses to place returned data, so an error here
// misplaces every completion by up to 127 bytes - and looks like a DMA bug two
// tiers up rather than a shim bug here.
// -----------------------------------------------------------------------------
class t4b_lower_addr extends tier4b_base_test;

    `uvm_component_utils(t4b_lower_addr)

    function new(string name = "t4b_lower_addr", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t4b_lower_addr");
        apply_power_on_reset();
        idle(20);

        // One per bit position, so a misplaced slice shows as a specific bit.
        for (int b = 0; b < 7; b++) begin
            send_cpl(2, 8'(b), 7'(1 << b));
        end
        // ...and a few arbitrary values, to catch a mask rather than a shift.
        for (int i = 0; i < 8; i++) begin
            send_cpl(2, 8'h50 + 8'(i), 7'($urandom));
        end
        wait_drained();

        phase.drop_objection(this, "t4b_lower_addr");
    endtask

endclass : t4b_lower_addr


// -----------------------------------------------------------------------------
// t4b_backpressure - the Xilinx sink stalls.
//
// The shim has a FIFO on its output, so backpressure here is not simply passed
// through - it fills the FIFO and eventually stalls tx_cpl_tlp_ready. What this
// catches is a shim that drops or duplicates a beat while stalled.
// -----------------------------------------------------------------------------
class t4b_backpressure extends tier4b_base_test;

    `uvm_component_utils(t4b_backpressure)

    function new(string name = "t4b_backpressure", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        mqnic_bp_profile_e profs [] = '{BP_NONE, BP_RANDOM, BP_AGGRESSIVE, BP_BURSTY};

        phase.raise_objection(this, "t4b_backpressure");
        apply_power_on_reset();
        idle(20);

        foreach (profs[p]) begin
            m_env.m_cc_axis_cfg.bp_profile = profs[p];
            `uvm_info(get_type_name(),
                $sformatf("CC sink %s", profs[p].name()), UVM_LOW)

            for (int i = 0; i < 16; i++)
                send_cpl((i % 9) + 1, 8'(i), 7'(i * 4));
            wait_drained();
        end

        phase.drop_objection(this, "t4b_backpressure");
    endtask

endclass : t4b_backpressure


// -----------------------------------------------------------------------------
// t4b_random_stress - randomized completions, back to back.
// -----------------------------------------------------------------------------
class t4b_random_stress extends tier4b_base_test;

    `uvm_component_utils(t4b_random_stress)

    function new(string name = "t4b_random_stress", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t4b_random_stress");
        apply_power_on_reset();
        idle(20);

        for (int round = 0; round < 10; round++) begin
            for (int i = 0; i < 16; i++)
                send_cpl($urandom_range(0, 24), 8'($urandom), 7'($urandom),
                         3'($urandom_range(0, 4)) & 3'b101);
            wait_drained();
        end

        phase.drop_objection(this, "t4b_random_stress");
    endtask

endclass : t4b_random_stress

`endif // TIER4B_TESTS_SV

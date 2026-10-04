// SPDX-License-Identifier: BSD-2-Clause-Views
//
// Tier 5 test suite - mqnic_core_pcie
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §13 Tier 5, §8.2
// Introduced : Step 7 (Tier 5)
//
// §8.2 names test_rb_walk as the FIRST Tier 5 test, and the ordering is not
// arbitrary: every other register test needs a base address, and a hardcoded one
// is a guess about how the DUT was parameterised. Discovery has to come first or
// everything after it is built on an assumption.
// -----------------------------------------------------------------------------

`ifndef TIER5_TESTS_SV
`define TIER5_TESTS_SV

class tier5_base_test extends mqnic_base_test;

    `uvm_component_utils(tier5_base_test)

    tier5_env m_env;

    // The control BAR. Register block 0 sits at offset 0 of it.
    protected bit [63:0] m_bar_base = 64'h0000_0000;

    function new(string name = "tier5_base_test", uvm_component parent = null);
        super.new(name, parent);
        m_x_safe_reset = 1'b1;   // AXI-Lite tree - see mqnic_reset_if.pulse_reset_x_safe()
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        m_env = tier5_env::type_id::create("m_env", this);
    endfunction

    protected task idle(int n);
        repeat (n) @(posedge m_rst_vif.clk);
    endtask

    protected task csr_read(bit [63:0] addr, output bit [31:0] data,
                            output bit ok);
        mqnic_csr_read_seq s = mqnic_csr_read_seq::type_id::create("rd");
        s.ctx  = m_env.m_ctx;
        s.addr = addr;
        s.start(m_env.m_req.sequencer);
        data = s.data;
        ok   = !s.timed_out;
    endtask

    protected task csr_write(bit [63:0] addr, bit [31:0] data);
        mqnic_csr_write_seq s = mqnic_csr_write_seq::type_id::create("wr");
        s.ctx  = m_env.m_ctx;
        s.addr = addr;
        s.data = data;
        s.start(m_env.m_req.sequencer);
    endtask

endclass : tier5_base_test


// -----------------------------------------------------------------------------
// t5_reset - the core comes out of reset without emitting anything.
//
// Worth running first on a DUT this size: 2,141 lines of RTL with no stimulus
// must produce no completions, and a core that chatters on reset would make
// every later test's completion matching unreliable.
// -----------------------------------------------------------------------------
class t5_reset extends tier5_base_test;

    `uvm_component_utils(t5_reset)

    function new(string name = "t5_reset", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t5_reset");
        apply_power_on_reset();
        idle(200);
        m_rst_vif.inject_reset(8);
        idle(200);
        phase.drop_objection(this, "t5_reset");
    endtask

endclass : t5_reset


// -----------------------------------------------------------------------------
// t5_rb_walk - discover the register block list (§8.2).
//
// THE FIRST REAL TIER 5 TEST. It walks the linked list the way the Linux driver
// does, and the walk is the check:
//
//   * every block type must be one mqnic_hw.h knows about
//   * every version must match what the header declares
//   * the list must terminate, and must not loop
//   * the FW ID block must be present - it is the anchor the driver keys on
//
// A failure here is one of two things and the message distinguishes them: the
// RAL is stale relative to the RTL, or the DUT is not presenting the map the
// driver expects. Both matter; they are fixed in different places.
// -----------------------------------------------------------------------------
class t5_rb_walk extends tier5_base_test;

    `uvm_component_utils(t5_rb_walk)

    function new(string name = "t5_rb_walk", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        mqnic_rb_walker w;
        bit [31:0] data;
        bit        ok;

        phase.raise_objection(this, "t5_rb_walk");
        apply_power_on_reset();
        idle(50);

        // Prove the register path works at all before trusting a walk over it.
        // A walk that reads garbage would otherwise report a dozen confusing
        // block-type errors instead of one clear "no completion came back".
        csr_read(m_bar_base + 64'(mqnic_ral_pkg::RB_REG_TYPE), data, ok);
        if (!ok) begin
            `uvm_error(get_type_name(),
                {"the first register read got no completion - the BAR path is not ",
                 "working, so the walk below would report nonsense"})
            phase.drop_objection(this, "t5_rb_walk");
            return;
        end
        `uvm_info(get_type_name(),
            $sformatf("first block type reads 0x%08h (%s)",
                      data, mqnic_ral_pkg::rb_type_name(data)), UVM_LOW)

        w     = mqnic_rb_walker::type_id::create("walker");
        w.ctx = m_env.m_ctx;
        w.walk(m_env.m_req.sequencer, m_bar_base);

        `uvm_info(get_type_name(),
            $sformatf("discovered %0d register block(s)", w.blocks.size()), UVM_LOW)

        if (w.blocks.size() == 0)
            `uvm_error(get_type_name(), "no register blocks discovered")

        w.check_types_known();
        w.check_versions();

        // The FW ID block is the anchor: the driver finds everything else from
        // it, so a map without one is unusable regardless of what else is there.
        if (!w.has_type(32'hFFFFFFFF))
            `uvm_error(get_type_name(),
                "no FW ID block in the discovered list - the driver anchors on it")

        idle(50);
        phase.drop_objection(this, "t5_rb_walk");
    endtask

endclass : t5_rb_walk

`endif // TIER5_TESTS_SV

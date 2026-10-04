// SPDX-License-Identifier: BSD-2-Clause-Views
//
// Tier 6 MSI-X tests - objective G7
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §1 G7 ("MSI-X TLP address/data match
//              table contents")
// Introduced : G7 MSI-X
//
// The interrupt path end to end: event queue -> pcie_msix (table, pending-bit
// array) -> pcie_us_if -> the hard IP's cfg_interrupt_msix interface. sb_msix
// checks every delivered message against the table the driver programmed.
//
// ORDER MATTERS, as it does for an OS: pcie_msix resets its table to all-zero
// and UNMASKED (pcie_msix.v:233-238), so the table is programmed before the
// function's MSI-X Enable is set - otherwise an early interrupt would be sent
// to address 0.
// -----------------------------------------------------------------------------

`ifndef TIER6_MSIX_TESTS_SV
`define TIER6_MSIX_TESTS_SV

class tier6_msix_base extends tier6_e2e_base;

    `uvm_component_utils(tier6_msix_base)

    int unsigned n_vectors = 32;      // IRQ_INDEX_WIDTH = EQN_WIDTH = 5

    function new(string name = "tier6_msix_base", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        m_env.msix = 1'b1;
    endfunction

    virtual function void start_of_simulation_phase(uvm_phase phase);
        super.start_of_simulation_phase(phase);
        m_env.m_drv.use_irq = 1'b1;
    endfunction

    // Bring-up with interrupts: table first, then MSI-X Enable.
    protected task msix_bring_up();
        m_env.m_msix_hip.set_function(1'b0, 1'b0);
        bring_up();
        m_env.m_drv.msix_setup(n_vectors);
        m_env.m_msix_hip.set_function(1'b1, 1'b0);
    endtask

    protected task expect_pba(bit [31:0] mask_bits, bit [31:0] expected, string when);
        bit [31:0] pba;
        m_env.m_drv.msix_read_pba(pba);
        if ((pba & mask_bits) != (expected & mask_bits))
            `uvm_error(get_type_name(),
                $sformatf("PBA %s: 0x%08h, expected bits 0x%08h of 0x%08h", when, pba, expected, mask_bits))
    endtask

    // A mixed batch both ways; returns when all of it has come through.
    protected task traffic(int unsigned n, int unsigned seed);
        byte unsigned f [];
        fork
            for (int i = 0; i < int'(n); i++) begin
                make_frame(64 + ((i + seed) * 131) % 1400, seed + i, f);
                m_env.m_drv.xmit(f, i % n_txq);
            end
            begin
                byte unsigned g [];
                for (int i = 0; i < int'(n); i++) begin
                    if (n_rxq > 1) make_udp(100 + i * 7, 16'(i), 16'(seed + i), seed + i, g);
                    else           make_frame(64 + ((i + seed) * 97) % 1400, 1000 + seed + i, g);
                    send_rx(g);
                end
            end
        join
    endtask

endclass : tier6_msix_base


// -----------------------------------------------------------------------------
// t6_msix_table - the table and pending-bit array through the BAR.
//
// Every vector's four words read back as written; the mask bit is the only
// writable bit of vector control; the PBA reads all clear with nothing pending.
// -----------------------------------------------------------------------------
class t6_msix_table extends tier6_msix_base;

    `uvm_component_utils(t6_msix_table)

    function new(string name = "t6_msix_table", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_sb.m_enable_end_check      = 1'b0;   // no traffic by design
        m_env.m_msix_sb.m_enable_end_check = 1'b0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [31:0] v [4];
        bit [63:0] a;
        phase.raise_objection(this, "t6_msix_table");
        msix_bring_up();
        for (int unsigned k = 0; k < n_vectors; k++) begin
            m_env.m_drv.msix_mask(k, k % 3 == 1);
        end
        for (int unsigned k = 0; k < n_vectors; k++) begin
            for (int w = 0; w < 4; w++)
                m_env.m_host.read32(m_env.m_drv.MSIX_TABLE + 64'(k) * 16 + 64'(w) * 4, v[w]);
            a = m_env.m_drv.msix_addr(k);
            if (v[0] !== a[31:0] || v[1] !== a[63:32] || v[2] !== m_env.m_drv.msix_data(k))
                `uvm_error(get_type_name(),
                    $sformatf("vector %0d reads 0x%08h_%08h / 0x%08h, wrote 0x%016h / 0x%08h",
                              k, v[1], v[0], v[2], a, m_env.m_drv.msix_data(k)))
            if (v[3] !== 32'(k % 3 == 1))
                `uvm_error(get_type_name(),
                    $sformatf("vector %0d control reads 0x%08h, mask written %0d", k, v[3], k % 3 == 1))
        end
        expect_pba(32'hFFFF_FFFF, 32'h0, "with nothing pending");
        phase.drop_objection(this, "t6_msix_table");
    endtask

endclass : t6_msix_table


// -----------------------------------------------------------------------------
// t6_msix_irq - the datapath driven by interrupts alone.
//
// Polling is off: every completion is found because an event queue raised an
// MSI-X message. Each message must match vector 0's table entry (sb_msix), and
// every frame must arrive (sb_e2e).
// -----------------------------------------------------------------------------
class t6_msix_irq extends tier6_msix_base;

    `uvm_component_utils(t6_msix_irq)

    function new(string name = "t6_msix_irq", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t6_msix_irq");
        msix_bring_up();
        traffic(40, 0);
        wait_quiet();
        expect_counts(40, 40);
        if (m_env.m_msix_sb.count(0) == 0)
            `uvm_error(get_type_name(), "no MSI-X message was delivered - the datapath cannot have been interrupt-driven")
        if (m_env.m_drv.n_irqs != m_env.m_msix_sb.count(0))
            `uvm_error(get_type_name(),
                $sformatf("driver handled %0d interrupt(s), %0d delivered", m_env.m_drv.n_irqs, m_env.m_msix_sb.count(0)))
        phase.drop_objection(this, "t6_msix_irq");
    endtask

endclass : t6_msix_irq


// -----------------------------------------------------------------------------
// t6_msix_multi_vector - eight event queues on eight vectors.
//
// Four RX and four TX completion queues are spread over EQs 0-7 (RX queue k on
// EQ k, TX queue k on EQ 4+k); EQ k raises vector k. Every vector must fire,
// and every message must carry its own vector's address and data.
// -----------------------------------------------------------------------------
class t6_msix_multi_vector extends tier6_msix_base;

    `uvm_component_utils(t6_msix_multi_vector)

    function new(string name = "t6_msix_multi_vector", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void start_of_simulation_phase(uvm_phase phase);
        super.start_of_simulation_phase(phase);
        m_env.m_drv.n_eq = 8;
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t6_msix_multi_vector");
        n_txq = 4;
        n_rxq = 4;
        msix_bring_up();
        m_env.m_drv.set_rss_mask(32'h3);
        for (int k = 0; k < 4; k++) m_env.m_drv.set_indir(k, k);
        m_env.m_drv.flush_writes();
        traffic(64, 7);
        wait_quiet();
        expect_counts(64, 64);
        for (int unsigned v = 0; v < 8; v++)
            if (m_env.m_msix_sb.count(v) == 0)
                `uvm_error(get_type_name(), $sformatf("vector %0d never fired", v))
        phase.drop_objection(this, "t6_msix_multi_vector");
    endtask

endclass : t6_msix_multi_vector


// -----------------------------------------------------------------------------
// t6_msix_vector_mask - a masked vector is held pending, then delivered.
//
// With vector 0 masked, traffic produces no message: the interrupt sets its
// PBA bit and the frames wait in host memory unprocessed. Unmasking must
// deliver the held message (pcie_msix scans the PBA, pcie_msix.v:316-343),
// clear the bit, and let the traffic complete.
// -----------------------------------------------------------------------------
class t6_msix_vector_mask extends tier6_msix_base;

    `uvm_component_utils(t6_msix_vector_mask)

    function new(string name = "t6_msix_vector_mask", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        byte unsigned f [];
        phase.raise_objection(this, "t6_msix_vector_mask");
        msix_bring_up();
        m_env.m_drv.msix_mask(0, 1'b1);
        for (int i = 0; i < 4; i++) begin make_frame(200 + i, i, f); send_rx(f); end
        idle(20000);
        if (m_env.m_msix_sb.count(0) != 0)
            `uvm_error(get_type_name(), "an interrupt was delivered on a masked vector")
        if (m_env.m_drv.n_rx_received != 0)
            `uvm_error(get_type_name(), "frames were processed although no interrupt was delivered")
        expect_pba(32'h1, 32'h1, "with vector 0 masked and an interrupt raised");

        m_env.m_drv.msix_mask(0, 1'b0);
        wait_quiet();
        expect_counts(0, 4);
        if (m_env.m_msix_sb.count(0) == 0)
            `uvm_error(get_type_name(), "unmasking did not deliver the pending interrupt")
        expect_pba(32'h1, 32'h0, "after unmask and delivery");
        phase.drop_objection(this, "t6_msix_vector_mask");
    endtask

endclass : t6_msix_vector_mask


// -----------------------------------------------------------------------------
// t6_msix_function_mask - Function Mask and MSI-X Enable in config space.
//
// The same hold-then-deliver, controlled at function level: first with the
// Function Mask set, then with MSI-X Enable cleared. sb_msix fails any message
// delivered while either is in force.
// -----------------------------------------------------------------------------
class t6_msix_function_mask extends tier6_msix_base;

    `uvm_component_utils(t6_msix_function_mask)

    function new(string name = "t6_msix_function_mask", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    protected task hold_then_release(bit use_enable, int unsigned seed);
        byte unsigned f [];
        int unsigned  irq_before;
        int unsigned  rx0;
        string        how;
        irq_before = m_env.m_msix_sb.count(0);
        rx0        = m_env.m_drv.n_rx_received;
        // Through a string variable: a ?: between string LITERALS of different
        // lengths crashed the xsim 2026.1 kernel here (FATAL_ERROR, no message).
        if (use_enable) how = "disabled";
        else            how = "masked";
        if (use_enable) m_env.m_msix_hip.set_function(1'b0, 1'b0);
        else            m_env.m_msix_hip.set_function(1'b1, 1'b1);
        for (int i = 0; i < 3; i++) begin make_frame(300 + i, seed + i, f); send_rx(f); end
        idle(20000);
        if (m_env.m_msix_sb.count(0) != irq_before)
            `uvm_error(get_type_name(),
                $sformatf("interrupt delivered while the function was %s", how))
        if (m_env.m_drv.n_rx_received != rx0)
            `uvm_error(get_type_name(), "frames processed with interrupts held off")
        expect_pba(32'h1, 32'h1, {"with the function ", how});
        m_env.m_msix_hip.set_function(1'b1, 1'b0);
        wait_quiet();
        if (m_env.m_msix_sb.count(0) == irq_before)
            `uvm_error(get_type_name(), "releasing the function did not deliver the pending interrupt")
        expect_pba(32'h1, 32'h0, "after release");
    endtask

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t6_msix_function_mask");
        msix_bring_up();
        hold_then_release(1'b0, 0);
        hold_then_release(1'b1, 10);
        expect_counts(0, 6);
        phase.drop_objection(this, "t6_msix_function_mask");
    endtask

endclass : t6_msix_function_mask


// -----------------------------------------------------------------------------
// t6_msix_fail - the hard IP refuses a message.
//
// cfg_interrupt_msix_fail must release the DUT's request just as _sent does
// (pcie_us_if.v:598-602); the interrupt itself is lost, as on hardware. A
// driver recovers with a watchdog pass (rearm_all); after that, interrupts must
// flow normally again.
// -----------------------------------------------------------------------------
class t6_msix_fail extends tier6_msix_base;

    `uvm_component_utils(t6_msix_fail)

    function new(string name = "t6_msix_fail", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        byte unsigned f [];
        phase.raise_objection(this, "t6_msix_fail");
        msix_bring_up();
        m_env.m_msix_hip.fail_next = 1;
        make_frame(400, 1, f);
        send_rx(f);
        idle(20000);
        if (m_env.m_msix_hip.n_failed != 1)
            `uvm_error(get_type_name(), $sformatf("%0d failed message(s), expected 1", m_env.m_msix_hip.n_failed))
        if (m_env.m_drv.n_rx_received != 0)
            `uvm_error(get_type_name(), "a frame was processed although its interrupt failed")

        m_env.m_drv.rearm_all();         // the watchdog
        traffic(20, 50);
        wait_quiet();
        expect_counts(20, 21);
        if (m_env.m_msix_sb.count(0) == 0)
            `uvm_error(get_type_name(), "no interrupt delivered after recovery")
        phase.drop_objection(this, "t6_msix_fail");
    endtask

endclass : t6_msix_fail

`endif // TIER6_MSIX_TESTS_SV

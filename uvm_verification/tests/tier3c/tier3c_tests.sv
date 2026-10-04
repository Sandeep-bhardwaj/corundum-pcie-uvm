// SPDX-License-Identifier: BSD-2-Clause-Views
//
// Tier 3c test suite - full dma_if_pcie
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §13 Tier 3
// Introduced : Step 5 (Tier 3c)
//
// 3c IS NOT 3a AND 3b RUN AGAIN. Repeating the alignment and length sweeps here
// would burn regression time re-proving what the sub-DUT tiers already proved
// on smaller DUTs where a failure has one plausible cause - which is the whole
// argument of §2.1, and it applies to Tier 3c as much as to Tier 1.
//
// What only 3c can ask:
//
//   * do the two engines interfere when they share one RAM?
//   * does a byte survive the full round trip - host memory, into RAM by the
//     read engine, back out by the write engine, into host memory again?
//
// The loopback is the strongest check in the whole tier because it has NO
// reference model in the middle. Both directions are compared against the same
// host memory, so a model that is wrong in a self-consistent way - which is
// exactly what bug 9 was - cannot hide here.
// -----------------------------------------------------------------------------

`ifndef TIER3C_TESTS_SV
`define TIER3C_TESTS_SV

class tier3c_base_test extends mqnic_base_test;

    `uvm_component_utils(tier3c_base_test)

    tier3c_env m_env;

    virtual dma_if_cfg_if m_cfg_vif;

    protected bit [7:0] m_rd_tag;
    protected bit [7:0] m_wr_tag;

    function new(string name = "tier3c_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        m_env = tier3c_env::type_id::create("m_env", this);
        if (!uvm_config_db #(virtual dma_if_cfg_if)::get(this, "", "cfg_vif", m_cfg_vif))
            `uvm_fatal(get_type_name(), "no dma_if_cfg_if in config_db under key cfg_vif")
    endfunction

    // Pins and BOTH models together - see tier3_base_test.set_config.
    protected virtual function void set_config(bit [2:0] mrrs, bit rcb_128b,
                                               bit ext_tag, bit [2:0] mps);
        m_cfg_vif.max_read_request_size = mrrs;
        m_cfg_vif.rcb_128b              = rcb_128b;
        m_cfg_vif.ext_tag_enable        = ext_tag;
        m_cfg_vif.max_payload_size      = mps;

        m_env.m_ref.max_read_request_size = mrrs;
        m_env.m_ref.max_payload_size      = mps;
        m_env.m_ref.rcb_128b              = rcb_128b;
        m_env.m_ref.ext_tag_enable        = ext_tag;

        m_env.m_rc.rc.rcb_128b         = rcb_128b;
        m_env.m_rc.rc.max_payload_size = mps;

        `uvm_info(get_type_name(),
            $sformatf("config: MRRS=%0d RCB=%0d ext_tag=%0b MPS=%0d",
                      128 << mrrs, rcb_128b ? 128 : 64, ext_tag, 128 << mps), UVM_LOW)
    endfunction

    virtual function void start_of_simulation_phase(uvm_phase phase);
        super.start_of_simulation_phase(phase);
        set_config(3'd2, 1'b0, 1'b1, 3'd1);
    endfunction

    protected task idle(int n);
        repeat (n) @(posedge m_rst_vif.clk);
    endtask

    // Host memory -> RAM.
    protected task read_at(bit [63:0] pcie_addr, int unsigned ram_addr,
                           int unsigned len, int unsigned delay = 0);
        dma_desc_pkg::dma_desc_pcie_seq s;
        bit [7:0] tag = m_rd_tag;
        m_rd_tag = m_rd_tag + 1;

        m_env.m_mem.fill_pattern(pcie_addr, len);

        s = dma_desc_pkg::dma_desc_pcie_seq::type_id::create("rd_desc");
        if (!s.randomize() with { pcie_addr == local::pcie_addr;
                                  ram_addr  == local::ram_addr;
                                  len       == local::len;
                                  tag       == local::tag;
                                  ram_sel   == 0;
                                  imm_en    == 1'b0;
                                  delay     == local::delay; })
            `uvm_fatal(get_type_name(), "randomize failed")
        s.start(m_env.m_rd_desc.sequencer);
    endtask

    // RAM -> host memory.
    protected task write_at(bit [63:0] pcie_addr, int unsigned ram_addr,
                            int unsigned len, int unsigned delay = 0);
        dma_desc_pkg::dma_desc_pcie_seq s;
        bit [7:0] tag = m_wr_tag;
        m_wr_tag = m_wr_tag + 1;

        s = dma_desc_pkg::dma_desc_pcie_seq::type_id::create("wr_desc");
        if (!s.randomize() with { pcie_addr == local::pcie_addr;
                                  ram_addr  == local::ram_addr;
                                  len       == local::len;
                                  tag       == local::tag;
                                  ram_sel   == 0;
                                  imm_en    == 1'b0;
                                  delay     == local::delay; })
            `uvm_fatal(get_type_name(), "randomize failed")
        s.start(m_env.m_wr_desc.sequencer);
    endtask

    protected task wait_drained(int max_cycles = 300000);
        int n = 0;
        while (!m_env.is_idle() && n < max_cycles) begin
            @(posedge m_rst_vif.clk);
            n++;
        end
        if (!m_env.is_idle())
            `uvm_error(get_type_name(),
                $sformatf({"did not drain in %0d cycles: rd desc %0d, rd req %0d, ",
                           "wr desc %0d, wr req %0d outstanding"},
                          max_cycles,
                          m_env.m_sb.outstanding_desc(),   m_env.m_sb.pending_count(),
                          m_env.m_sb_wr.outstanding_desc(), m_env.m_sb_wr.pending_count()))
        else
            idle(200);
    endtask

    protected function bit [63:0] host_base(int unsigned i = 0);
        return 64'h0000_0004_0000_0000 + (64'(i) << 16);
    endfunction

    // -------------------------------------------------------------------------
    // The end-to-end check: two host regions must be byte-identical.
    // -------------------------------------------------------------------------
    protected function void compare_host(bit [63:0] src, bit [63:0] dst,
                                         int unsigned len, string ctx);
        byte unsigned a;
        byte unsigned b;
        int unsigned  n_bad = 0;

        for (int i = 0; i < int'(len); i++) begin
            a = m_env.m_mem.read_byte(src + i);
            b = m_env.m_mem.read_byte(dst + i);
            if (a !== b) begin
                n_bad++;
                if (n_bad <= 4)
                    `uvm_error(get_type_name(),
                        $sformatf({"LOOPBACK MISMATCH\n  expected: 0x%02h\n  ",
                                   "actual  : 0x%02h\n  context : %s byte %0d ",
                                   "(src 0x%0h dst 0x%0h)"},
                                  a, b, ctx, i, src + i, dst + i))
            end
        end

        if (n_bad == 0)
            `uvm_info(get_type_name(),
                $sformatf("loopback OK: %0d byte(s), %s", len, ctx), UVM_LOW)
        else
            `uvm_error(get_type_name(),
                $sformatf("%s: %0d of %0d byte(s) differ", ctx, n_bad, len))
    endfunction

endclass : tier3c_base_test


// -----------------------------------------------------------------------------
// t3c_reset - quiescent through reset, both engines.
// -----------------------------------------------------------------------------
class t3c_reset extends tier3c_base_test;

    `uvm_component_utils(t3c_reset)

    function new(string name = "t3c_reset", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_sb.m_enable_end_check    = 1'b0;
        m_env.m_sb_wr.m_enable_end_check = 1'b0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t3c_reset");
        apply_power_on_reset();
        idle(100);
        m_rst_vif.inject_reset(8);
        idle(100);
        phase.drop_objection(this, "t3c_reset");
    endtask

endclass : t3c_reset


// -----------------------------------------------------------------------------
// t3c_loopback - the round trip, and the strongest check in the tier.
//
// host[src] --read engine--> RAM --write engine--> host[dst], then compare the
// two host regions directly. No reference model sits between them, so a model
// that is wrong in a SELF-CONSISTENT way cannot hide - which is precisely the
// failure mode of bug 9, where the RC model and the scoreboard agreed with each
// other and both disagreed with the DUT.
//
// The write must not start until the read has landed, so each pair drains in
// between. t3c_concurrent is where they deliberately overlap.
// -----------------------------------------------------------------------------
class t3c_loopback extends tier3c_base_test;

    `uvm_component_utils(t3c_loopback)

    function new(string name = "t3c_loopback", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        // The RAM contents come from the read engine, not from a test preload,
        // so the write scoreboard has no shadow to compare against. Its request
        // set and legality checks still run; the payload check is the loopback
        // comparison itself.
        m_env.m_sb_wr.check_payload = 1'b0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        int lens []  = '{1, 4, 7, 32, 63, 64, 65, 128, 255, 256, 512, 1024, 2048};
        bit [63:0] src_base = host_base(1);
        bit [63:0] dst_base = host_base(8);
        int unsigned ram = 0;

        phase.raise_objection(this, "t3c_loopback");
        apply_power_on_reset();
        idle(20);

        foreach (lens[i]) begin
            bit [63:0] src = src_base + 64'(ram);
            bit [63:0] dst = dst_base + 64'(ram);

            read_at(src, 32'(ram), lens[i]);
            wait_drained();

            write_at(dst, 32'(ram), lens[i]);
            wait_drained();

            compare_host(src, dst, lens[i],
                         $sformatf("len %0d at ram 0x%0h", lens[i], ram));
            ram += 4096;
        end

        phase.drop_objection(this, "t3c_loopback");
    endtask

endclass : t3c_loopback


// -----------------------------------------------------------------------------
// t3c_loopback_unaligned - the round trip with every offset combination.
//
// Source offset, RAM offset and destination offset are all varied
// independently. A realignment bug that cancels itself out in one direction
// will not cancel in both, which is what makes this stronger than either
// tier's alignment sweep on its own.
// -----------------------------------------------------------------------------
class t3c_loopback_unaligned extends tier3c_base_test;

    `uvm_component_utils(t3c_loopback_unaligned)

    function new(string name = "t3c_loopback_unaligned", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_sb_wr.check_payload = 1'b0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [63:0] src_base = host_base(2);
        bit [63:0] dst_base = host_base(9);
        int unsigned ram = 0;

        phase.raise_objection(this, "t3c_loopback_unaligned");
        apply_power_on_reset();
        idle(20);

        for (int so = 0; so < 4; so++) begin
            for (int ro = 0; ro < 4; ro++) begin
                for (int doff = 0; doff < 4; doff++) begin
                    bit [63:0] src = src_base + 64'(ram) + 64'(so);
                    bit [63:0] dst = dst_base + 64'(ram) + 64'(doff);
                    int unsigned ra = ram + ro;

                    read_at(src, 32'(ra), 96);
                    wait_drained();
                    write_at(dst, 32'(ra), 96);
                    wait_drained();

                    compare_host(src, dst, 96,
                                 $sformatf("src+%0d ram+%0d dst+%0d", so, ro, doff));
                    ram += 512;
                end
            end
        end

        phase.drop_objection(this, "t3c_loopback_unaligned");
    endtask

endclass : t3c_loopback_unaligned


// -----------------------------------------------------------------------------
// t3c_concurrent - both engines busy at once on DISJOINT RAM regions.
//
// The integration question 3a and 3b cannot ask. The two engines contend for
// one segmented RAM - the read engine writing it, the write engine reading it -
// and for the shared configuration. Regions are kept disjoint so that any
// mismatch is interference, not a race the test created itself.
// -----------------------------------------------------------------------------
class t3c_concurrent extends tier3c_base_test;

    `uvm_component_utils(t3c_concurrent)

    function new(string name = "t3c_concurrent", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        // Read engine works the low half of RAM, write engine the high half.
        localparam int unsigned RD_BASE = 32'h0000;
        localparam int unsigned WR_BASE = 32'h8000;

        phase.raise_objection(this, "t3c_concurrent");
        apply_power_on_reset();
        idle(20);

        // Give the write engine something known to send.
        for (int i = 0; i < 8192; i++)
            m_env.preload(WR_BASE + i, 8'((WR_BASE + i) ^ ((WR_BASE + i) >> 8)));
        idle(20);

        for (int round = 0; round < 8; round++) begin
            for (int i = 0; i < 4; i++) begin
                read_at (host_base(3) + 64'(round * 8192 + i * 1024),
                         RD_BASE + 32'(i * 1024), 512);
                write_at(host_base(10) + 64'(round * 8192 + i * 1024),
                         WR_BASE + 32'(i * 1024), 512);
            end
            wait_drained();
        end

        phase.drop_objection(this, "t3c_concurrent");
    endtask

endclass : t3c_concurrent


// -----------------------------------------------------------------------------
// t3c_concurrent_stress - both engines, randomized, with reordering on.
//
// Everything at once: split reads, split writes, out-of-order completions and
// independent backpressure on three channels. Directed tests prove each
// mechanism; this is what finds interactions between them.
// -----------------------------------------------------------------------------
class t3c_concurrent_stress extends tier3c_base_test;

    `uvm_component_utils(t3c_concurrent_stress)

    function new(string name = "t3c_concurrent_stress", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_rc.rc.reorder_depth = 3;
        m_env.m_rc.rc.min_latency   = 4;
        m_env.m_rc.rc.max_latency   = 90;
    endfunction

    virtual task run_phase(uvm_phase phase);
        localparam int unsigned RD_BASE = 32'h0000;
        localparam int unsigned WR_BASE = 32'h8000;
        int unsigned len;

        phase.raise_objection(this, "t3c_concurrent_stress");
        apply_power_on_reset();
        idle(20);

        for (int i = 0; i < 16384; i++)
            m_env.preload(WR_BASE + i, 8'((WR_BASE + i) ^ ((WR_BASE + i) >> 8)));
        idle(20);

        for (int round = 0; round < 8; round++) begin
            for (int i = 0; i < 4; i++) begin
                len = $urandom_range(1, 2048);
                read_at (host_base(4) + 64'(round * 32768 + i * 8192 + $urandom_range(0, 63)),
                         RD_BASE + 32'(i * 4096), len, $urandom_range(0, 6));
                len = $urandom_range(1, 2048);
                write_at(host_base(11) + 64'(round * 32768 + i * 8192 + $urandom_range(0, 63)),
                         WR_BASE + 32'(i * 4096), len, $urandom_range(0, 6));
            end
            wait_drained();
        end

        phase.drop_objection(this, "t3c_concurrent_stress");
    endtask

endclass : t3c_concurrent_stress


// -----------------------------------------------------------------------------
// t3c_config_matrix - MRRS and MPS swept together on the integrated DUT.
//
// The two engines take DIFFERENT limits from the same configuration block -
// MRRS bounds reads, MPS bounds writes. Sweeping them together on the wrapper
// is what proves the wrapper routes each pin to the right engine, which is a
// wiring property neither sub-tier can check.
// -----------------------------------------------------------------------------
class t3c_config_matrix extends tier3c_base_test;

    `uvm_component_utils(t3c_config_matrix)

    function new(string name = "t3c_config_matrix", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_sb_wr.check_payload = 1'b0;   // loopback provides the data check
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [2:0] mrrs [] = '{3'd0, 3'd2, 3'd3};   // 128, 512, 1024
        bit [2:0] mps  [] = '{3'd0, 3'd1, 3'd2};   // 128, 256, 512
        int unsigned ram = 0;

        phase.raise_objection(this, "t3c_config_matrix");
        apply_power_on_reset();
        idle(20);

        foreach (mrrs[r]) begin
            foreach (mps[m]) begin
                bit [63:0] src = host_base(5) + 64'(ram);
                bit [63:0] dst = host_base(12) + 64'(ram);

                set_config(mrrs[r], 1'b0, 1'b1, mps[m]);
                idle(20);

                read_at(src, 32'(ram % 32768), 1536);
                wait_drained();
                write_at(dst, 32'(ram % 32768), 1536);
                wait_drained();

                compare_host(src, dst, 1536,
                             $sformatf("MRRS=%0d MPS=%0d",
                                       128 << mrrs[r], 128 << mps[m]));
                ram += 4096;
            end
        end

        phase.drop_objection(this, "t3c_config_matrix");
    endtask

endclass : t3c_config_matrix

`endif // TIER3C_TESTS_SV

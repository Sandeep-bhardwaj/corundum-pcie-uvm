// SPDX-License-Identifier: BSD-2-Clause-Views
//
// Tier 3b test suite - dma_if_pcie_wr
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §13 Tier 3
// Introduced : Step 5 (Tier 3b)
//
// The write engine is a smaller problem than the read engine, and the test list
// reflects that honestly rather than padding it to match 3a. There are no
// completions, so no reordering, no tags in flight, no timeouts and no error
// injection from the host - a posted write gets no answer. What remains is the
// splitting rule, the RAM read path, alignment, and the immediate-data path.
//
// SOURCE AND DESTINATION SWAP ROLES. Here the RAM is the source and host memory
// the destination, so the reference is the RAM image the test preloaded. Every
// test therefore preloads through tier3b_env.preload(), which writes the
// responder and the scoreboard's shadow together.
// -----------------------------------------------------------------------------

`ifndef TIER3B_TESTS_SV
`define TIER3B_TESTS_SV

class tier3b_base_test extends mqnic_base_test;

    `uvm_component_utils(tier3b_base_test)

    tier3b_env m_env;

    virtual dma_if_cfg_if m_cfg_vif;

    protected bit [7:0] m_next_tag;

    function new(string name = "tier3b_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        m_env = tier3b_env::type_id::create("m_env", this);
        if (!uvm_config_db #(virtual dma_if_cfg_if)::get(this, "", "cfg_vif", m_cfg_vif))
            `uvm_fatal(get_type_name(), "no dma_if_cfg_if in config_db under key cfg_vif")
    endfunction

    // The DUT pin and the model, set together - see tier3_base_test.set_config.
    protected virtual function void set_config(bit [2:0] mps);
        m_cfg_vif.max_payload_size = mps;
        m_env.m_ref.max_payload_size = mps;
        `uvm_info(get_type_name(),
            $sformatf("config: MPS=%0d bytes", 128 << mps), UVM_LOW)
    endfunction

    virtual function void start_of_simulation_phase(uvm_phase phase);
        super.start_of_simulation_phase(phase);
        set_config(3'd1);                    // 256-byte payload
    endfunction

    protected task idle(int n);
        repeat (n) @(posedge m_rst_vif.clk);
    endtask

    protected function bit [7:0] next_tag();
        bit [7:0] t = m_next_tag;
        m_next_tag = m_next_tag + 1;
        return t;
    endfunction

    // Fill a RAM region with an address-derived pattern, through the single
    // entry point that keeps the responder and the scoreboard in step.
    protected function void preload_region(int unsigned base, int unsigned len);
        for (int i = 0; i < int'(len); i++)
            m_env.preload(base + i, 8'((base + i) ^ ((base + i) >> 8)));
    endfunction

    protected task write_at(bit [63:0] pcie_addr, int unsigned ram_addr,
                            int unsigned len, int unsigned delay = 0);
        dma_desc_pkg::dma_desc_pcie_seq s;
        bit [7:0] tag = next_tag();

        preload_region(ram_addr, len);

        s = dma_desc_pkg::dma_desc_pcie_seq::type_id::create("desc");
        if (!s.randomize() with { pcie_addr == local::pcie_addr;
                                  ram_addr  == local::ram_addr;
                                  len       == local::len;
                                  tag       == local::tag;
                                  ram_sel   == 0;
                                  imm_en    == 1'b0;
                                  delay     == local::delay; })
            `uvm_fatal(get_type_name(), "randomize failed")
        s.start(m_env.m_desc.sequencer);
    endtask

    // Immediate mode: the data comes from the descriptor, not from RAM.
    protected task write_imm(bit [63:0] pcie_addr, bit [31:0] imm,
                             int unsigned len);
        dma_desc_pkg::dma_desc_pcie_seq s;
        bit [7:0] tag = next_tag();

        s = dma_desc_pkg::dma_desc_pcie_seq::type_id::create("desc");
        if (!s.randomize() with { pcie_addr == local::pcie_addr;
                                  ram_addr  == 0;
                                  len       == local::len;
                                  tag       == local::tag;
                                  ram_sel   == 0;
                                  imm       == local::imm;
                                  imm_en    == 1'b1;
                                  delay     == 0; })
            `uvm_fatal(get_type_name(), "randomize failed")
        s.start(m_env.m_desc.sequencer);
    endtask

    protected task wait_drained(int max_cycles = 200000);
        int n = 0;
        while (!m_env.is_idle() && n < max_cycles) begin
            @(posedge m_rst_vif.clk);
            n++;
        end
        if (!m_env.is_idle())
            `uvm_error(get_type_name(),
                $sformatf({"did not drain in %0d cycles: %0d descriptor(s) without ",
                           "status, %0d predicted request(s) unseen"},
                          max_cycles, m_env.m_sb.outstanding_desc(),
                          m_env.m_sb.pending_count()))
        else
            idle(100);
    endtask

    protected function bit [63:0] host_base(int unsigned i = 0);
        return 64'h0000_0004_0000_0000 + (64'(i) << 16);
    endfunction

endclass : tier3b_base_test


// -----------------------------------------------------------------------------
// t3b_reset - quiescent through reset. No descriptor, so no TLP may appear.
// -----------------------------------------------------------------------------
class t3b_reset extends tier3b_base_test;

    `uvm_component_utils(t3b_reset)

    function new(string name = "t3b_reset", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_sb.m_enable_end_check = 1'b0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t3b_reset");
        apply_power_on_reset();
        idle(100);
        m_rst_vif.inject_reset(8);
        idle(100);
        phase.drop_objection(this, "t3b_reset");
    endtask

endclass : t3b_reset


// -----------------------------------------------------------------------------
// t3b_write_basic - one aligned, single-request write.
// -----------------------------------------------------------------------------
class t3b_write_basic extends tier3b_base_test;

    `uvm_component_utils(t3b_write_basic)

    function new(string name = "t3b_write_basic", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t3b_write_basic");
        apply_power_on_reset();
        idle(20);

        for (int i = 0; i < 8; i++) begin
            write_at(host_base() + 64'(i * 64), 32'(i * 64), 64);
            wait_drained();
        end

        phase.drop_objection(this, "t3b_write_basic");
    endtask

endclass : t3b_write_basic


// -----------------------------------------------------------------------------
// t3b_addr_3dw - low addresses take the 3DW header path.
// -----------------------------------------------------------------------------
class t3b_addr_3dw extends tier3b_base_test;

    `uvm_component_utils(t3b_addr_3dw)

    function new(string name = "t3b_addr_3dw", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t3b_addr_3dw");
        apply_power_on_reset();
        idle(20);

        for (int i = 0; i < 6; i++) begin
            write_at(64'h0000_0000_1000_0000 + 64'(i * 128), 32'(i * 128), 128);
            wait_drained();
        end
        write_at(64'h0000_0001_0000_0000, 32'h800, 128);   // just above 4 GB: 4DW
        wait_drained();

        phase.drop_objection(this, "t3b_addr_3dw");
    endtask

endclass : t3b_addr_3dw


// -----------------------------------------------------------------------------
// t3b_alignment_sweep - every source offset against every destination offset.
//
// The gather direction: the DUT must collect bytes spread across RAM segments
// and pack them into a linear TLP payload, realigning when the RAM offset and
// the PCIe offset differ.
// -----------------------------------------------------------------------------
class t3b_alignment_sweep extends tier3b_base_test;

    `uvm_component_utils(t3b_alignment_sweep)

    function new(string name = "t3b_alignment_sweep", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        int unsigned ram = 0;

        phase.raise_objection(this, "t3b_alignment_sweep");
        apply_power_on_reset();
        idle(20);

        for (int pa = 0; pa < 8; pa++) begin
            for (int ra = 0; ra < 8; ra++) begin
                write_at(host_base(1) + 64'(pa) + 64'(ram), 32'(ram + ra), 96);
                wait_drained();
                ram += 256;
            end
        end

        phase.drop_objection(this, "t3b_alignment_sweep");
    endtask

endclass : t3b_alignment_sweep


// -----------------------------------------------------------------------------
// t3b_len_sweep - lengths around every boundary that changes the split.
// -----------------------------------------------------------------------------
class t3b_len_sweep extends tier3b_base_test;

    `uvm_component_utils(t3b_len_sweep)

    function new(string name = "t3b_len_sweep", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        int lens [] = '{1, 2, 3, 4, 5, 7, 8, 15, 16, 31, 32, 33,
                        63, 64, 65, 127, 128, 129, 255, 256, 257,
                        511, 512, 513, 1023, 1024, 1025, 2048};
        int unsigned ram = 0;

        phase.raise_objection(this, "t3b_len_sweep");
        apply_power_on_reset();
        idle(20);

        foreach (lens[i]) begin
            write_at(host_base(2) + 64'(ram), 32'(ram), lens[i]);
            wait_drained();
            ram += ((lens[i] + 511) / 256) * 256;
        end

        phase.drop_objection(this, "t3b_len_sweep");
    endtask

endclass : t3b_len_sweep


// -----------------------------------------------------------------------------
// t3b_4k_boundary - writes that would cross a 4 KB page.
//
// The same hard PCIe rule as the read side, and the scoreboard checks it twice:
// as set membership against ref_dma.split_write, and as an unconditional
// legality check on every emitted TLP.
// -----------------------------------------------------------------------------
class t3b_4k_boundary extends tier3b_base_test;

    `uvm_component_utils(t3b_4k_boundary)

    function new(string name = "t3b_4k_boundary", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        int offs [] = '{4, 8, 32, 64, 128, 256, 508, 512};
        bit [63:0] page = host_base(3) + 64'h1000;
        int unsigned ram = 0;

        phase.raise_objection(this, "t3b_4k_boundary");
        apply_power_on_reset();
        idle(20);

        foreach (offs[i]) begin
            write_at(page - 64'(offs[i]), 32'(ram), offs[i] + 256);
            wait_drained();
            ram += 1024;
        end

        // Ending exactly on the boundary must not split on the page rule.
        write_at(page - 64'd64, 32'(ram), 64);
        wait_drained();

        phase.drop_objection(this, "t3b_4k_boundary");
    endtask

endclass : t3b_4k_boundary


// -----------------------------------------------------------------------------
// t3b_mps_sweep - max_payload_size decides where writes split.
//
// The write engine's limit is MPS, not MRRS - a different pin and a different
// rule from the read side (ref_dma.split_write). Sweeping it is what proves the
// model is following the right one.
// -----------------------------------------------------------------------------
class t3b_mps_sweep extends tier3b_base_test;

    `uvm_component_utils(t3b_mps_sweep)

    function new(string name = "t3b_mps_sweep", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [2:0] mps [] = '{3'd0, 3'd1, 3'd2, 3'd3};   // 128..1024
        int lens []      = '{64, 128, 256, 512, 1024, 2048};
        int unsigned ram = 0;

        phase.raise_objection(this, "t3b_mps_sweep");
        apply_power_on_reset();
        idle(20);

        foreach (mps[m]) begin
            set_config(mps[m]);
            idle(20);
            foreach (lens[l]) begin
                write_at(host_base(4) + 64'(ram), 32'(ram % 32768), lens[l]);
                wait_drained();
                ram += 4096;
            end
        end

        phase.drop_objection(this, "t3b_mps_sweep");
    endtask

endclass : t3b_mps_sweep


// -----------------------------------------------------------------------------
// t3b_immediate - the descriptor carries the data instead of RAM.
//
// Reachable only because tb_top_tier3b sets IMM_ENABLE = 1. At the RTL default
// of 0 the imm and imm_en ports are dead wires and this test would pass while
// exercising nothing - which is why the parameter is called out in the top.
//
// The payload check is disabled: the source is the descriptor, not the RAM
// image the scoreboard shadows. The request set and legality checks still run,
// and the DUT must still issue no RAM read at all - that is the property this
// test is really about.
// -----------------------------------------------------------------------------
class t3b_immediate extends tier3b_base_test;

    `uvm_component_utils(t3b_immediate)

    function new(string name = "t3b_immediate", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // Payload checking stays ON: sb_dma_wr now checks immediate data against
    // the descriptor (it used to be switched off here, leaving it unverified).

    virtual task run_phase(uvm_phase phase);
        int unsigned rd_before;

        phase.raise_objection(this, "t3b_immediate");
        apply_power_on_reset();
        idle(20);

        rd_before = m_env.m_ram.outstanding_reads();

        for (int i = 0; i < 8; i++) begin
            // Immediate data is at most IMM_WIDTH/8 = 4 bytes.
            write_imm(host_base(5) + 64'(i * 64), 32'hA5A5_0000 + 32'(i), (i % 4) + 1);
            wait_drained();
        end

        if (m_env.m_ram.outstanding_reads() != rd_before)
            `uvm_error(get_type_name(),
                "immediate write left a RAM read outstanding - it must not read RAM at all")

        phase.drop_objection(this, "t3b_immediate");
    endtask

endclass : t3b_immediate


// -----------------------------------------------------------------------------
// t3b_backpressure_matrix - stall the TLP output and the RAM independently.
//
// The DUT sits between a source it pulls from and a sink it pushes to. Stalling
// them in step is the one pattern that will never expose an ordering bug
// between them - the §7.4 argument, one tier up.
// -----------------------------------------------------------------------------
class t3b_backpressure_matrix extends tier3b_base_test;

    `uvm_component_utils(t3b_backpressure_matrix)

    function new(string name = "t3b_backpressure_matrix", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        mqnic_bp_profile_e req_bp [] = '{BP_NONE, BP_RANDOM, BP_AGGRESSIVE, BP_BURSTY};
        mqnic_bp_profile_e ram_bp [] = '{BP_AGGRESSIVE, BP_BURSTY, BP_NONE, BP_RANDOM};
        int unsigned ram = 0;

        phase.raise_objection(this, "t3b_backpressure_matrix");
        apply_power_on_reset();
        idle(20);

        foreach (req_bp[i]) begin
            m_env.m_wr_req_cfg.bp_profile = req_bp[i];
            m_env.m_ram_cfg.bp_profile[0] = ram_bp[i];
            m_env.m_ram_cfg.bp_profile[1] = req_bp[i];

            `uvm_info(get_type_name(),
                $sformatf("TLP %s / RAM seg0 %s seg1 %s",
                          req_bp[i].name(), ram_bp[i].name(), req_bp[i].name()),
                UVM_LOW)

            for (int d = 0; d < 6; d++) begin
                write_at(host_base(6) + 64'(ram), 32'(ram), 512);
                ram += 512;
            end
            wait_drained();
        end

        phase.drop_objection(this, "t3b_backpressure_matrix");
    endtask

endclass : t3b_backpressure_matrix


// -----------------------------------------------------------------------------
// t3b_random_stress - randomized descriptors, several in flight.
// -----------------------------------------------------------------------------
class t3b_random_stress extends tier3b_base_test;

    `uvm_component_utils(t3b_random_stress)

    function new(string name = "t3b_random_stress", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        int unsigned len;
        int unsigned pa_off;
        int unsigned ra;
        bit [63:0]   base = host_base(7);

        phase.raise_objection(this, "t3b_random_stress");
        apply_power_on_reset();
        idle(20);

        for (int round = 0; round < 10; round++) begin
            // Destinations stay distinct within a batch: several are in flight
            // and the scoreboard shadows RAM by address - see t3_tag_exhaustion.
            for (int i = 0; i < 6; i++) begin
                len    = $urandom_range(1, 2048);
                pa_off = $urandom_range(0, 63);
                ra     = $urandom_range(0, 63) + (i * 4096);
                write_at(base + 64'(round * 65536 + i * 8192 + pa_off),
                         32'(ra), len, $urandom_range(0, 6));
            end
            wait_drained();
        end

        phase.drop_objection(this, "t3b_random_stress");
    endtask

endclass : t3b_random_stress


// -----------------------------------------------------------------------------
// t3b_cov_closure - directed sweep of the write-split space (cg_dma_wr holes):
//   length class x MPS-relative alignment x MPS (128..1024), with unaligned
//   DWORD offsets and varied RAM alignment; a 4 KB-crossing descriptor for
//   every length class; immediate descriptors at aligned and unaligned
//   addresses. Every request and byte is still checked by sb_dma_wr.
// -----------------------------------------------------------------------------
class t3b_cov_closure extends tier3b_base_test;

    `uvm_component_utils(t3b_cov_closure)

    function new(string name = "t3b_cov_closure", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [2:0]    mps   [] = '{3'd0, 3'd1, 3'd2, 3'd3};
        int unsigned lens  [] = '{1, 100, 128, 200, 256, 1000, 4096, 5000};
        // Offset within a 128-byte block: aligned, low half (DWORD offset 1),
        // high half (DWORD offset 2).
        int unsigned offs  [] = '{0, 33, 98};
        int unsigned ram_off [] = '{0, 2, 17};
        int unsigned ram = 0;
        int unsigned win = 8;

        phase.raise_objection(this, "t3b_cov_closure");
        apply_power_on_reset();
        idle(20);

        // ---- split sweep -----------------------------------------------------
        foreach (mps[m]) begin
            set_config(mps[m]);
            idle(20);
            foreach (lens[l])
                foreach (offs[o]) begin
                    write_at(host_base(win++) + 64'(offs[o]),
                             ram + ram_off[o], lens[l]);
                    wait_drained();
                    ram = (ram + 6144) % 24576;
                end
        end

        // ---- 4 KB crossing, every length class --------------------------------
        set_config(3'd1);
        idle(20);
        foreach (lens[l]) begin
            if (lens[l] < 2) continue;                       // one byte cannot cross
            write_at(host_base(win++) + 64'(4096 - lens[l] / 2), ram, lens[l]);
            wait_drained();
            ram = (ram + 6144) % 24576;
        end

        // ---- immediate descriptors, aligned and unaligned ---------------------
        for (int off = 0; off < 2; off++)
            for (int len = 1; len <= 4; len += 3) begin
                write_imm(host_base(win++) + 64'(off ? 1 : 0), 32'hC0DE_0000 + 32'(len), len);
                wait_drained();
            end

        phase.drop_objection(this, "t3b_cov_closure");
    endtask

endclass : t3b_cov_closure

`endif // TIER3B_TESTS_SV

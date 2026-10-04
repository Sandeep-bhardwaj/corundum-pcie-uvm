// SPDX-License-Identifier: BSD-2-Clause-Views
//
// Tier 3a test suite - dma_if_pcie_rd
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §13 Tier 3, §14.3
// Introduced : Step 5
//
// EVERY TEST DRAINS ON A CONDITION, NEVER ON A DELAY. The condition is
// tier3_env.is_idle(): every descriptor answered, every request completed,
// nothing predicted but unseen. Tier 2 established why - a fixed idle() long
// enough for one backpressure profile is too short for another, and a test that
// finishes early reports a green-looking match count for traffic that never
// happened.
//
// ADDRESS DISCIPLINE. Host buffers are allocated above 4 GB so the DUT emits
// 4DW headers; t3_addr_3dw deliberately uses a low address to reach the 3DW
// path, which is a different header layout and a different decode.
//
// The RAM is only 64 KB (RAM_ADDR_WIDTH=16), so descriptors longer than that
// cannot be checked end to end. Lengths above 4 KB appear only where the point
// is the request SPLIT, not the data landing.
// -----------------------------------------------------------------------------

`ifndef TIER3_TESTS_SV
`define TIER3_TESTS_SV

class tier3_base_test extends mqnic_base_test;

    `uvm_component_utils(tier3_base_test)

    tier3_env m_env;

    virtual dma_if_cfg_if m_cfg_vif;

    // Rotates so two live descriptors never share a tag - the driver rejects
    // that as illegal stimulus, and it would be.
    protected bit [7:0] m_next_tag;

    function new(string name = "tier3_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        m_env = tier3_env::type_id::create("m_env", this);
        if (!uvm_config_db #(virtual dma_if_cfg_if)::get(this, "", "cfg_vif", m_cfg_vif))
            `uvm_fatal(get_type_name(), "no dma_if_cfg_if in config_db under key cfg_vif")
    endfunction

    // -------------------------------------------------------------------------
    // THE ONLY PLACE CONFIGURATION IS SET.
    //
    // The DUT's pins, ref_dma and mqnic_rc_model must all say the same thing. A
    // test that changed the model alone would be checking the DUT against a
    // configuration it was never in, and every request would mismatch for a
    // reason that has nothing to do with the DUT. Routing all three through one
    // function is what makes that impossible - the same argument as Tier 2's
    // cli_preload().
    // -------------------------------------------------------------------------
    protected virtual function void set_config(bit [2:0] mrrs,
                                               bit       rcb_128b,
                                               bit       ext_tag,
                                               bit [2:0] mps);
        m_cfg_vif.max_read_request_size = mrrs;
        m_cfg_vif.rcb_128b              = rcb_128b;
        m_cfg_vif.ext_tag_enable        = ext_tag;
        m_cfg_vif.max_payload_size      = mps;

        m_env.m_ref.max_read_request_size = mrrs;
        m_env.m_ref.rcb_128b              = rcb_128b;
        m_env.m_ref.ext_tag_enable        = ext_tag;

        m_env.m_rc.rc.rcb_128b         = rcb_128b;
        m_env.m_rc.rc.max_payload_size = mps;
        m_env.m_rc.rc.completer_id     = 16'h0100;

        `uvm_info(get_type_name(),
            $sformatf("config: MRRS=%0d RCB=%0d ext_tag=%0b MPS=%0d",
                      128 << mrrs, rcb_128b ? 128 : 64, ext_tag, 128 << mps),
            UVM_LOW)
    endfunction

    // Golden configuration (§2.3). Applied in start_of_simulation so it is in
    // force before any test's run_phase, and overridable from there.
    virtual function void start_of_simulation_phase(uvm_phase phase);
        super.start_of_simulation_phase(phase);
        set_config(3'd2, 1'b0, 1'b1, 3'd1);   // 512B MRRS, 64B RCB, ext tags, 256B MPS
    endfunction

    protected task idle(int n);
        repeat (n) @(posedge m_rst_vif.clk);
    endtask

    protected function bit [7:0] next_tag();
        bit [7:0] t = m_next_tag;
        m_next_tag = m_next_tag + 1;
        return t;
    endfunction

    // -------------------------------------------------------------------------
    // Fill host memory with an address-derived pattern and hand the DUT a
    // descriptor for it.
    //
    // The pattern MUST be laid down before the descriptor is issued: sb_dma
    // snapshots host memory when the descriptor arrives, so filling afterwards
    // would have it predict the pre-fill contents.
    // -------------------------------------------------------------------------
    protected task read_at(bit [63:0] pcie_addr, int unsigned ram_addr,
                           int unsigned len, int unsigned delay = 0);
        dma_desc_pkg::dma_desc_pcie_seq s;
        bit [7:0] tag = next_tag();

        m_env.m_mem.fill_pattern(pcie_addr, len);

        s = dma_desc_pkg::dma_desc_pcie_seq::type_id::create("desc");
        if (!s.randomize() with { pcie_addr == local::pcie_addr;
                                  ram_addr  == local::ram_addr;
                                  len       == local::len;
                                  tag       == local::tag;
                                  ram_sel   == 0;
                                  delay     == local::delay; })
            `uvm_fatal(get_type_name(), "randomize failed")
        s.start(m_env.m_desc.sequencer);
    endtask

    // -------------------------------------------------------------------------
    // Wait until the DUT has genuinely finished. See the file header.
    // -------------------------------------------------------------------------
    protected task wait_drained(int max_cycles = 200000);
        int n = 0;
        while (!m_env.is_idle() && n < max_cycles) begin
            @(posedge m_rst_vif.clk);
            n++;
        end
        if (!m_env.is_idle())
            `uvm_error(get_type_name(),
                $sformatf({"did not drain in %0d cycles: %0d descriptor(s) without ",
                           "status, %0d predicted request(s) unseen, rc %s"},
                          max_cycles, m_env.m_sb.outstanding_desc(),
                          m_env.m_sb.pending_count(),
                          m_env.m_rc.is_idle() ? "idle" : "busy"))
        else
            idle(200);   // let the last RAM writes reach the scoreboard
    endtask

    // Base of the host buffer this test uses. Above 4 GB, so headers are 4DW.
    protected function bit [63:0] host_base(int unsigned i = 0);
        return 64'h0000_0004_0000_0000 + (64'(i) << 16);
    endfunction

endclass : tier3_base_test


// -----------------------------------------------------------------------------
// t3_reset - quiescent through reset. No descriptor, so no request may appear.
// -----------------------------------------------------------------------------
class t3_reset extends tier3_base_test;

    `uvm_component_utils(t3_reset)

    function new(string name = "t3_reset", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_sb.m_enable_end_check = 1'b0;   // no traffic by design
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t3_reset");
        apply_power_on_reset();
        idle(100);
        m_rst_vif.inject_reset(8);
        idle(100);
        phase.drop_objection(this, "t3_reset");
    endtask

endclass : t3_reset


// -----------------------------------------------------------------------------
// t3_read_basic - one aligned, single-request read. The first thing to look at
// if anything else in this tier fails.
//
// 64 bytes at an RCB-aligned address: rule 3 does nothing, rule 2 does nothing,
// rule 1 does nothing. Exactly one request, exactly one completion.
// -----------------------------------------------------------------------------
class t3_read_basic extends tier3_base_test;

    `uvm_component_utils(t3_read_basic)

    function new(string name = "t3_read_basic", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t3_read_basic");
        apply_power_on_reset();
        idle(20);

        for (int i = 0; i < 8; i++) begin
            read_at(host_base() + 64'(i * 64), 32'(i * 64), 64);
            wait_drained();
        end

        phase.drop_objection(this, "t3_read_basic");
    endtask

endclass : t3_read_basic


// -----------------------------------------------------------------------------
// t3_addr_3dw - addresses below 4 GB produce a 3DW header.
//
// The address sits in a DIFFERENT header field for 3DW ([63:34]) than for 4DW
// ([63:2]). A testbench that only ever uses high addresses never decodes the
// 3DW form, and a decoder that got it wrong would pass every other test here.
// -----------------------------------------------------------------------------
class t3_addr_3dw extends tier3_base_test;

    `uvm_component_utils(t3_addr_3dw)

    function new(string name = "t3_addr_3dw", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t3_addr_3dw");
        apply_power_on_reset();
        idle(20);

        // Low addresses: the DUT builds 3DW headers (TLP_FORCE_64_BIT_ADDR=0).
        for (int i = 0; i < 6; i++) begin
            read_at(64'h0000_0000_1000_0000 + 64'(i * 128), 32'(i * 128), 128);
            wait_drained();
        end

        // ...and one just above the boundary, which must switch to 4DW.
        read_at(64'h0000_0001_0000_0000, 32'h800, 128);
        wait_drained();

        phase.drop_objection(this, "t3_addr_3dw");
    endtask

endclass : t3_addr_3dw


// -----------------------------------------------------------------------------
// t3_alignment_sweep - every source offset against every destination offset.
//
// This is the realignment path: when the PCIe address and the RAM address have
// different offsets within a word, the DMA must shift the data as it lands. A
// DUT that only handled the equal-offset case would pass t3_read_basic and
// corrupt everything here.
// -----------------------------------------------------------------------------
class t3_alignment_sweep extends tier3_base_test;

    `uvm_component_utils(t3_alignment_sweep)

    function new(string name = "t3_alignment_sweep", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        int unsigned ram = 0;

        phase.raise_objection(this, "t3_alignment_sweep");
        apply_power_on_reset();
        idle(20);

        // 0..7 on the source, 0..63 on the destination. cocotb sweeps the RAM
        // offset across a whole byte-lane group (0..64) and we covered only 8;
        // the realignment path depends on the DIFFERENCE, so a short
        // destination sweep leaves most of the shift network untested.
        for (int pa = 0; pa < 8; pa++) begin
            for (int ra = 0; ra < 64; ra += 8) begin
                read_at(host_base(1) + 64'(pa) + 64'(ram), 32'(ram + ra), 96);
                wait_drained();
                ram += 256;
            end
        end

        phase.drop_objection(this, "t3_alignment_sweep");
    endtask

endclass : t3_alignment_sweep


// -----------------------------------------------------------------------------
// t3_len_sweep - lengths around every boundary that changes the split.
//
// 1 and 4 exercise the byte-enable corners; 63/64/65 straddle the RCB; 511/512/
// 513 straddle MRRS. The values either side of each boundary are the point -
// the boundary itself usually works.
// -----------------------------------------------------------------------------
class t3_len_sweep extends tier3_base_test;

    `uvm_component_utils(t3_len_sweep)

    function new(string name = "t3_len_sweep", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        // Starts at 0: the RTL special-cases a zero-length descriptor and
        // our model did not. Found by the cocotb cross-check (§19 E6).
        int lens [] = '{0, 1, 2, 3, 4, 5, 7, 8, 15, 16, 31, 32, 33,
                        63, 64, 65, 127, 128, 129, 255, 256, 257,
                        511, 512, 513, 1023, 1024, 1025, 2048, 4096};
        int unsigned ram = 0;

        phase.raise_objection(this, "t3_len_sweep");
        apply_power_on_reset();
        idle(20);

        foreach (lens[i]) begin
            read_at(host_base(2) + 64'(ram), 32'(ram), lens[i]);
            wait_drained();
            // Keep destinations apart so an overrun shows as a mismatch on the
            // NEXT descriptor rather than being overwritten and lost.
            ram += ((lens[i] + 511) / 256) * 256;
        end

        phase.drop_objection(this, "t3_len_sweep");
    endtask

endclass : t3_len_sweep


// -----------------------------------------------------------------------------
// t3_4k_boundary - reads that would cross a 4 KB page.
//
// A hard PCIe rule, and one that hangs real silicon when broken. Each descriptor
// starts a little below a 4 KB line and runs past it, so the DUT MUST split
// there whether or not MRRS would have forced a split anyway.
//
// The scoreboard checks this twice over: once as set membership against
// ref_dma, and once as an unconditional legality check on every emitted TLP.
// -----------------------------------------------------------------------------
class t3_4k_boundary extends tier3_base_test;

    `uvm_component_utils(t3_4k_boundary)

    function new(string name = "t3_4k_boundary", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        // Bytes remaining before the page ends, when the read starts.
        int offs [] = '{4, 8, 32, 64, 128, 256, 508, 512};
        bit [63:0] page = host_base(3) + 64'h1000;
        int unsigned ram = 0;

        phase.raise_objection(this, "t3_4k_boundary");
        apply_power_on_reset();
        idle(20);

        foreach (offs[i]) begin
            // Start `offs[i]` bytes before the boundary and read well past it.
            read_at(page - 64'(offs[i]), 32'(ram), offs[i] + 256);
            wait_drained();
            ram += 1024;
        end

        // Exactly reaching the boundary must NOT split on rule 1.
        read_at(page - 64'd64, 32'(ram), 64);
        wait_drained();

        phase.drop_objection(this, "t3_4k_boundary");
    endtask

endclass : t3_4k_boundary


// -----------------------------------------------------------------------------
// t3_mps_mrrs_matrix - request size limit crossed with completion payload size.
//
// MRRS decides how the DUT SPLITS a descriptor; MPS decides how the completer
// splits its answer. They are independent knobs on the two halves of the same
// transfer, and §14.3 crosses them because the interesting failures live in the
// combination - a reassembly buffer sized for one MRRS behaves differently when
// the completions arrive in smaller pieces than expected.
//
// Configuration is changed only between drains, never mid-operation.
// -----------------------------------------------------------------------------
class t3_mps_mrrs_matrix extends tier3_base_test;

    `uvm_component_utils(t3_mps_mrrs_matrix)

    function new(string name = "t3_mps_mrrs_matrix", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [2:0] mrrs [] = '{3'd0, 3'd1, 3'd2, 3'd3};   // 128, 256, 512, 1024
        bit [2:0] mps  [] = '{3'd0, 3'd1, 3'd2};         // 128, 256, 512
        int lens []       = '{64, 128, 256, 512, 1024, 2048};
        int unsigned ram  = 0;

        phase.raise_objection(this, "t3_mps_mrrs_matrix");
        apply_power_on_reset();
        idle(20);

        foreach (mrrs[r]) begin
            foreach (mps[m]) begin
                set_config(mrrs[r], 1'b0, 1'b1, mps[m]);
                idle(20);

                foreach (lens[l]) begin
                    read_at(host_base(4) + 64'(ram), 32'(ram % 32768), lens[l]);
                    wait_drained();
                    ram += 4096;
                end
            end
        end

        phase.drop_objection(this, "t3_mps_mrrs_matrix");
    endtask

endclass : t3_mps_mrrs_matrix


// -----------------------------------------------------------------------------
// t3_rcb_64_128 - read completion boundary of 64 vs 128 bytes.
//
// RCB changes where the FIRST request ends (ref_dma rule 3) and where each
// completion may end. set_config drives the DUT pin and both models together,
// so the two halves cannot disagree about which boundary is in force.
//
// The source offsets sweep 0..112 in steps of 16, which lands inside a 64-byte
// RCB block for some and inside a 128-byte one for others - the offsets where
// the two settings predict DIFFERENT first-request lengths are exactly the ones
// that catch a model or a DUT that ignores rcb_128b.
// -----------------------------------------------------------------------------
class t3_rcb_64_128 extends tier3_base_test;

    `uvm_component_utils(t3_rcb_64_128)

    function new(string name = "t3_rcb_64_128", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit rcb [] = '{1'b0, 1'b1};
        int unsigned ram;

        phase.raise_objection(this, "t3_rcb_64_128");
        apply_power_on_reset();
        idle(20);

        foreach (rcb[r]) begin
            set_config(3'd2, rcb[r], 1'b1, 3'd1);
            idle(20);

            ram = 0;
            for (int off = 0; off < 128; off += 16) begin
                read_at(host_base(5 + r) + 64'(off) + 64'(ram), 32'(ram), 320);
                wait_drained();
                ram += 512;
            end
        end

        phase.drop_objection(this, "t3_rcb_64_128");
    endtask

endclass : t3_rcb_64_128


// -----------------------------------------------------------------------------
// t3_cpl_reorder - completions for different tags come back out of order.
//
// PCIe permits this and the DUT must reassemble correctly regardless. The model
// only ever swaps entries when doing so leaves every same-tag subsequence
// intact, so any failure here is the DUT's, not illegal stimulus.
//
// Multiple descriptors are in flight at once - with one at a time there is only
// ever one tag outstanding and nothing to reorder against.
// -----------------------------------------------------------------------------
class t3_cpl_reorder extends tier3_base_test;

    `uvm_component_utils(t3_cpl_reorder)

    function new(string name = "t3_cpl_reorder", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_rc.rc.reorder_depth = 4;
        m_env.m_rc.rc.min_latency   = 8;
        m_env.m_rc.rc.max_latency   = 120;   // wide spread, so orders really vary
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t3_cpl_reorder");
        apply_power_on_reset();
        idle(20);

        for (int round = 0; round < 4; round++) begin
            // Issue a batch back to back: several tags outstanding together.
            for (int i = 0; i < 8; i++)
                read_at(host_base(6) + 64'(round * 8192 + i * 512),
                        32'(i * 512), 512);
            wait_drained();
        end

        phase.drop_objection(this, "t3_cpl_reorder");
    endtask

endclass : t3_cpl_reorder


// -----------------------------------------------------------------------------
// t3_cpl_split_max - every completion split to the smallest legal size.
//
// One RCB per completion is the worst case for reassembly: the most fragments,
// the most partial-word writes, the most opportunities to lose a byte at a
// seam. Combined with reordering it is the hardest thing this DUT has to do.
// -----------------------------------------------------------------------------
class t3_cpl_split_max extends tier3_base_test;

    `uvm_component_utils(t3_cpl_split_max)

    function new(string name = "t3_cpl_split_max", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_rc.rc.split_maximally = 1'b1;
        m_env.m_rc.rc.reorder_depth   = 3;
    endfunction

    virtual task run_phase(uvm_phase phase);
        int lens [] = '{64, 128, 192, 256, 512, 1024};
        int unsigned ram = 0;

        phase.raise_objection(this, "t3_cpl_split_max");
        apply_power_on_reset();
        idle(20);

        foreach (lens[i]) begin
            // Unaligned start, so the first fragment is a partial RCB.
            read_at(host_base(7) + 64'(ram) + 64'd8, 32'(ram + 8), lens[i]);
            wait_drained();
            ram += 2048;
        end

        phase.drop_objection(this, "t3_cpl_split_max");
    endtask

endclass : t3_cpl_split_max


// -----------------------------------------------------------------------------
// t3_tag_exhaustion - more descriptors in flight than the DUT has PCIe tags.
//
// PCIE_TAG_COUNT is 256 and each descriptor may consume several tags, so a
// sustained burst forces the DUT to wait for a tag to come free before issuing
// the next request. The failure this catches is a DUT that reuses a tag while
// its completion is still outstanding - which the scoreboard reports directly,
// because it tracks tag liveness from the completion side rather than guessing.
// -----------------------------------------------------------------------------
class t3_tag_exhaustion extends tier3_base_test;

    `uvm_component_utils(t3_tag_exhaustion)

    function new(string name = "t3_tag_exhaustion", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        // Slow completions keep tags outstanding for longer, which is what
        // actually creates the shortage.
        m_env.m_rc.rc.min_latency = 60;
        m_env.m_rc.rc.max_latency = 300;
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t3_tag_exhaustion");
        apply_power_on_reset();
        idle(20);

        // 200 descriptors, no gap: far more requests than there are tags.
        //
        // Destinations must NOT wrap. These are all in flight together, and
        // sb_dma keys its expected-RAM image by address - two live descriptors
        // sharing a destination would have the second overwrite the first's
        // expectation while the first's data was still landing, producing a
        // mismatch that is the test's fault. 200 x 256 = 51200 fits in the
        // 64 KB RAM, so no modulo is needed.
        for (int i = 0; i < 200; i++)
            read_at(host_base(8) + 64'(i * 256), 32'(i * 256), 256);

        wait_drained(400000);

        phase.drop_objection(this, "t3_tag_exhaustion");
    endtask

endclass : t3_tag_exhaustion


// -----------------------------------------------------------------------------
// t3_ext_tag_off - only 32 tags available.
//
// With extended tags disabled the legal tag range is 5 bits. The scoreboard
// fails any request outside it, so this test's whole job is to issue MORE
// concurrent work than 32 tags can carry and confirm the DUT throttles instead
// of reaching for a tag it is not allowed to use.
//
// Slow completions are what create the shortage; with fast ones the DUT would
// never have more than a handful outstanding and the limit would never bind.
// -----------------------------------------------------------------------------
class t3_ext_tag_off extends tier3_base_test;

    `uvm_component_utils(t3_ext_tag_off)

    function new(string name = "t3_ext_tag_off", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_rc.rc.min_latency = 40;
        m_env.m_rc.rc.max_latency = 200;
    endfunction

    virtual function void start_of_simulation_phase(uvm_phase phase);
        super.start_of_simulation_phase(phase);
        set_config(3'd2, 1'b0, 1'b0, 3'd1);   // ext_tag_enable = 0
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t3_ext_tag_off");
        apply_power_on_reset();
        idle(20);

        // 64 descriptors back to back against a 32-tag budget. Destinations do
        // not wrap - see the note in t3_tag_exhaustion.
        for (int i = 0; i < 64; i++)
            read_at(host_base(9) + 64'(i * 512), 32'(i * 512), 512);
        wait_drained(400000);

        phase.drop_objection(this, "t3_ext_tag_off");
    endtask

endclass : t3_ext_tag_off


// -----------------------------------------------------------------------------
// Error injection base. The three error tests differ only in the status the
// host memory region returns.
//
// The RAM never receives the data for a failed read, so the data check has
// nothing to compare and the descriptor status is the whole point: the DUT must
// report the RIGHT error, not merely some error.
// -----------------------------------------------------------------------------
virtual class tier3_err_base extends tier3_base_test;

    function new(string name = "tier3_err_base", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    pure virtual function host_mem_status_e injected_status();
    pure virtual function bit [3:0]         expected_error();

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        // No data lands for the failing reads, so the RAM-side comparison count
        // is not a meaningful floor here.
        m_env.m_sb.m_min_comparisons = 1;
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [63:0] base = host_base(10);

        phase.raise_objection(this, get_type_name());
        apply_power_on_reset();
        idle(20);

        // A clean read first: proves the environment works before anything is
        // deliberately broken. Without it, a failure below is ambiguous.
        read_at(base, 32'h0, 256);
        wait_drained();

        // Now poison a window and read into it.
        m_env.m_mem.set_region_status(base + 64'h1000, base + 64'h1FFF,
                                      injected_status());
        for (int i = 0; i < 4; i++) begin
            read_at(base + 64'h1000 + 64'(i * 256), 32'h2000 + 32'(i * 256), 256);
            wait_drained();
        end

        if (m_env.m_sb.error_count(expected_error()) == 0)
            `uvm_error(get_type_name(),
                $sformatf({"injected %s but the DUT never reported error code %0d ",
                           "on the descriptor status"},
                          injected_status().name(), expected_error()))

        // And a clean read afterwards: the DUT must recover, not wedge.
        m_env.m_mem.clear_regions();
        read_at(base + 64'h4000, 32'h4000, 256);
        wait_drained();

        phase.drop_objection(this, get_type_name());
    endtask

endclass : tier3_err_base


class t3_err_ur extends tier3_err_base;
    `uvm_component_utils(t3_err_ur)
    function new(string name = "t3_err_ur", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function host_mem_status_e injected_status(); return HOST_MEM_UR; endfunction
    virtual function bit [3:0] expected_error(); return 4'(DMA_ERROR_PCIE_CPL_STATUS_UR); endfunction
endclass


class t3_err_ca extends tier3_err_base;
    `uvm_component_utils(t3_err_ca)
    function new(string name = "t3_err_ca", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function host_mem_status_e injected_status(); return HOST_MEM_CA; endfunction
    virtual function bit [3:0] expected_error(); return 4'(DMA_ERROR_PCIE_CPL_STATUS_CA); endfunction
endclass


class t3_err_poison extends tier3_err_base;
    `uvm_component_utils(t3_err_poison)
    function new(string name = "t3_err_poison", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    // A poisoned completion carries data the DUT may legitimately discard, so
    // the "these bytes must land" check does not apply. The request-set and
    // legality checks still do, and stay on.
    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_sb.check_ram_data = 1'b0;
    endfunction
    virtual function host_mem_status_e injected_status(); return HOST_MEM_POISON; endfunction
    virtual function bit [3:0] expected_error(); return 4'(DMA_ERROR_PCIE_CPL_POISONED); endfunction
endclass


// -----------------------------------------------------------------------------
// t3_cpl_timeout - the host interface reports a completion timeout.
//
// dma_if_pcie_rd HAS NO INTERNAL TIMEOUT COUNTER. Reading the RTL settles what
// this test has to do: DMA_ERROR_TIMEOUT is reachable only via an inbound
// completion whose error sideband is PCIE_ERROR_TIMEOUT (:1117-1122), which is
// how the hard IP forwards a timeout it detected. Withholding a completion
// instead just leaves the tag outstanding forever - the DUT is not the component
// that times out.
//
// The RAM data check stays ON. A timed-out request delivers no data, so the only
// way it could fail is if the DUT wrote something anyway, which is precisely
// what should be caught.
// -----------------------------------------------------------------------------
class t3_cpl_timeout extends tier3_base_test;

    `uvm_component_utils(t3_cpl_timeout)

    function new(string name = "t3_cpl_timeout", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_rc.rc.timeout_pct = 30;
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t3_cpl_timeout");
        apply_power_on_reset();
        idle(20);

        for (int i = 0; i < 32; i++) begin
            read_at(host_base(11) + 64'(i * 256), 32'(i * 256), 256);
            wait_drained();
        end

        // With 30% injection over 32 descriptors, seeing none would mean the
        // sideband never reached the DUT - a broken testbench, not a pass.
        if (m_env.m_rc.rc.timeout_count() == 0)
            `uvm_error(get_type_name(),
                "no timeout was injected - the test proved nothing")
        else if (m_env.m_sb.error_count(4'(DMA_ERROR_TIMEOUT)) == 0)
            `uvm_error(get_type_name(),
                $sformatf({"injected %0d timeout completion(s) but the DUT never ",
                           "reported DMA_ERROR_TIMEOUT on a descriptor status"},
                          m_env.m_rc.rc.timeout_count()))

        phase.drop_objection(this, "t3_cpl_timeout");
    endtask

endclass : t3_cpl_timeout


// -----------------------------------------------------------------------------
// t3_cpl_dropped - a completion that never arrives.
//
// The companion to t3_cpl_timeout and a genuinely different question: with no
// internal timer, the DUT CANNOT retire a request whose completion is simply
// withheld. This test asserts that reality rather than pretending otherwise -
// the descriptor must stay outstanding and the DUT must not invent a status, a
// RAM write, or a duplicate use of the stranded tag.
//
// Every end-of-test rule that assumes traffic completes is therefore off; what
// remains is the check that the DUT does nothing it should not.
//
// RUN THIS TEST WITH +MQNIC_NO_LIVENESS. The bound assertions in
// sva/sva_dma_if_pcie.sv say every descriptor is eventually answered, which is
// the very thing this test arranges not to happen.
// -----------------------------------------------------------------------------
class t3_cpl_dropped extends tier3_base_test;

    `uvm_component_utils(t3_cpl_dropped)

    function new(string name = "t3_cpl_dropped", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_rc.rc.drop_pct        = 100;   // nothing comes back
        m_env.m_sb.m_enable_end_check = 1'b0;  // by design, nothing completes
        m_env.m_sb.check_tag_reuse    = 1'b0;  // tags are stranded, not reused
    endfunction

    virtual task run_phase(uvm_phase phase);
        int unsigned sts_before;

        phase.raise_objection(this, "t3_cpl_dropped");
        apply_power_on_reset();
        idle(20);

        sts_before = m_env.m_sb.status_count();

        for (int i = 0; i < 8; i++)
            read_at(host_base(14) + 64'(i * 256), 32'(i * 256), 256);

        idle(50000);

        if (m_env.m_sb.status_count() != sts_before)
            `uvm_error(get_type_name(),
                $sformatf({"DUT reported %0d descriptor status(es) although no ",
                           "completion was ever returned"},
                          m_env.m_sb.status_count() - sts_before))

        phase.drop_objection(this, "t3_cpl_dropped");
    endtask

endclass : t3_cpl_dropped


// -----------------------------------------------------------------------------
// t3_backpressure_matrix - stall the request channel and the RAM independently.
//
// The DUT sits between two ports that can each stall. Stalling them together is
// the one pattern that will never expose an ordering bug between them, which is
// the same argument §7.4 makes for per-segment profiles at Tier 2.
// -----------------------------------------------------------------------------
class t3_backpressure_matrix extends tier3_base_test;

    `uvm_component_utils(t3_backpressure_matrix)

    function new(string name = "t3_backpressure_matrix", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        mqnic_bp_profile_e req_bp [] = '{BP_NONE, BP_RANDOM, BP_AGGRESSIVE, BP_BURSTY};
        mqnic_bp_profile_e ram_bp [] = '{BP_AGGRESSIVE, BP_BURSTY, BP_NONE, BP_RANDOM};
        int unsigned ram = 0;

        phase.raise_objection(this, "t3_backpressure_matrix");
        apply_power_on_reset();
        idle(20);

        foreach (req_bp[i]) begin
            m_env.m_rd_req_cfg.bp_profile    = req_bp[i];
            // Deliberately mismatched with the request profile: the two ports
            // must never stall in step.
            m_env.m_ram_cfg.bp_profile[0]    = ram_bp[i];
            m_env.m_ram_cfg.bp_profile[1]    = req_bp[i];

            `uvm_info(get_type_name(),
                $sformatf("request %s / RAM seg0 %s seg1 %s",
                          req_bp[i].name(), ram_bp[i].name(), req_bp[i].name()),
                UVM_LOW)

            // Six in flight together, so destinations must stay distinct
            // within the batch - see the note in t3_tag_exhaustion.
            for (int d = 0; d < 6; d++) begin
                read_at(host_base(12) + 64'(ram), 32'(ram), 512);
                ram += 512;
            end
            wait_drained();
        end

        phase.drop_objection(this, "t3_backpressure_matrix");
    endtask

endclass : t3_backpressure_matrix


// -----------------------------------------------------------------------------
// t3_random_stress - randomized descriptors, everything on at once.
//
// Reordering, splitting and backpressure together. Directed tests prove each
// mechanism in isolation; this is what finds the interactions between them, and
// it is the test whose seed is worth varying in regression.
// -----------------------------------------------------------------------------
class t3_random_stress extends tier3_base_test;

    `uvm_component_utils(t3_random_stress)

    function new(string name = "t3_random_stress", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_rc.rc.reorder_depth = 3;
        m_env.m_rc.rc.min_latency   = 4;
        m_env.m_rc.rc.max_latency   = 90;
    endfunction

    virtual task run_phase(uvm_phase phase);
        int unsigned len;
        int unsigned pa_off;
        int unsigned ra;
        bit [63:0]   base = host_base(13);

        phase.raise_objection(this, "t3_random_stress");
        apply_power_on_reset();
        idle(20);

        for (int round = 0; round < 10; round++) begin
            // A handful in flight together, then drain and check.
            for (int i = 0; i < 6; i++) begin
                len    = $urandom_range(1, 2048);
                pa_off = $urandom_range(0, 63);
                ra     = $urandom_range(0, 63) + (i * 4096);
                read_at(base + 64'(round * 65536 + i * 8192 + pa_off),
                        32'(ra), len, $urandom_range(0, 6));
            end
            wait_drained();
        end

        phase.drop_objection(this, "t3_random_stress");
    endtask

endclass : t3_random_stress


// -----------------------------------------------------------------------------
// t3_cov_closure - the §14.3 split cross, every cell.
//
// cg_dma's x_split is length x PCIe alignment x MRRS x RCB. The directed tests
// above each sweep ONE axis at the golden configuration, so after 20 seeds half
// the cross was empty - and MRRS 2048/4096 had never been configured at all.
// This walks the cross explicitly: for each MRRS (all six) and RCB, every
// alignment class against one length from every length class, the destination
// offset rotating through every class so x_realign fills as a side effect.
//
// A last pass starts each length 8 bytes below a 4 KB line, giving the
// "crossed" half of x_4k for every length class that can cross.
//
// Drained after each alignment pass: one pass is ~14 KB of the 64 KB RAM, and
// destinations of live descriptors must not overlap.
//
// SKIPPED: exactly 4096 bytes, 4 KB-aligned, at MRRS 4096. That is the RTL
// finding t3_mrrs4096_exact demonstrates (a spurious extra 4 KB read); running
// it here would fail this test for a reason it does not exist to test. The
// x_split cells it would fill stay as holes until the RTL is fixed.
// -----------------------------------------------------------------------------
class t3_cov_closure extends tier3_base_test;

    `uvm_component_utils(t3_cov_closure)

    function new(string name = "t3_cov_closure", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        // One representative per cg_dma bin, in bin order.
        int unsigned lens   [] = '{1, 30, 64, 63, 200, 512, 511, 1000, 4096, 5000};
        int unsigned aligns [] = '{0, 4, 2, 17, 32, 45};
        int unsigned ram, ram_off, n;
        bit [63:0]   host;

        phase.raise_objection(this, "t3_cov_closure");
        apply_power_on_reset();
        idle(20);

        for (int mrrs = 0; mrrs <= 5; mrrs++) begin
            for (int rcb = 0; rcb <= 1; rcb++) begin
                set_config(3'(mrrs), 1'(rcb), 1'b1, 3'd1);
                idle(20);
                foreach (aligns[a]) begin
                    ram = 0;
                    foreach (lens[l]) begin
                        if (mrrs == 5 && lens[l] == 4096 && aligns[a] == 0)
                            continue;                 // RTL finding - see header
                        ram_off = aligns[(a + l) % aligns.size()];
                        host    = host_base(5) + 64'(l * 8192) + 64'(aligns[a]);
                        read_at(host, ram + ram_off, lens[l]);
                        ram += ((lens[l] + ram_off + 255) / 256 + 1) * 256;
                    end
                    wait_drained();
                end
            end
        end

        // 4 KB crossings at the golden configuration.
        set_config(3'd2, 1'b0, 1'b1, 3'd1);
        idle(20);
        ram = 0;
        n   = 0;
        foreach (lens[l]) begin
            if (lens[l] <= 8) continue;               // cannot reach the line
            host = host_base(6) + 64'(l * 16384) + 64'h1000 - 64'd8;
            read_at(host, ram, lens[l]);
            ram += ((lens[l] + 255) / 256 + 1) * 256;
            if (++n % 4 == 0) begin
                wait_drained();
                ram = 0;
            end
        end
        wait_drained();

        phase.drop_objection(this, "t3_cov_closure");
    endtask

endclass : t3_cov_closure


// -----------------------------------------------------------------------------
// t3_mrrs4096_exact - RTL FINDING: an extra 4 KB read at MRRS 4096.
//
// EXPECTED TO FAIL until dma_if_pcie_rd.v is fixed. Kept in the regression,
// like t3_cpl_timeout, so the failure stays visible.
//
// With MRRS = 4096, a remaining count of exactly 4096 at a 4 KB-aligned
// address takes the "fits in MRRS, crosses 4k" branch (dma_if_pcie_rd.v:665)
// because req_op_count_reg >> 12 != 0. That branch issues the correct 4096-byte
// request but computes req_last_tlp (:675) with "&& req_op_count_reg >> 12 == 0",
// which is false for exactly 4096 - so the request is not marked last. The
// engine iterates with 0 bytes left; the non-crossing branch then gives
// req_dword_count = 0, and a TLP length of 0 means 1024 DWORDs. Result: a
// spurious 4096-byte read of the NEXT page, never asked for by any descriptor.
//
// Unreachable at MRRS <= 2048 (4096 > MRRS takes the other branch, which never
// marks last). Reached by a 4096-byte aligned descriptor, or by any longer one
// whose remainder is 4096 at a page boundary (e.g. 8192 bytes aligned).
// -----------------------------------------------------------------------------
class t3_mrrs4096_exact extends tier3_base_test;

    `uvm_component_utils(t3_mrrs4096_exact)

    function new(string name = "t3_mrrs4096_exact", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t3_mrrs4096_exact");
        apply_power_on_reset();
        idle(20);
        set_config(3'd5, 1'b0, 1'b1, 3'd1);       // MRRS 4096
        idle(20);

        read_at(host_base(7), 0, 4096);             // exactly one page, aligned
        wait_drained();
        read_at(host_base(7) + 64'h4000, 0, 8192);  // remainder hits 4096 aligned
        wait_drained();

        phase.drop_objection(this, "t3_mrrs4096_exact");
    endtask

endclass : t3_mrrs4096_exact

`endif // TIER3_TESTS_SV

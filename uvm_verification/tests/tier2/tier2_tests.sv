// SPDX-License-Identifier: BSD-2-Clause-Views
//
// Tier 2 test suite - segmented memory
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §13 Tier 2
// Introduced : Step 4
//
// dma_psdpram is a SIMPLE DUAL PORT RAM, so a read of an address whose write
// has not completed is a race in the DUT, not defined behaviour. Every test
// below waits after a write before reading the same address - see the ordering
// note in env/sb_dma_ram.sv.
// -----------------------------------------------------------------------------

`ifndef TIER2_TESTS_SV
`define TIER2_TESTS_SV

class tier2_base_test extends mqnic_base_test;

    `uvm_component_utils(tier2_base_test)

    tier2_env m_env;

    function new(string name = "tier2_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // Reset drivers for the async DUT's two clock domains.
    virtual mqnic_reset_if m_rst_wr_vif;
    virtual mqnic_reset_if m_rst_rd_vif;

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        m_env = tier2_env::type_id::create("m_env", this);
        void'(uvm_config_db #(virtual mqnic_reset_if)::get(this, "", "rst_wr_vif", m_rst_wr_vif));
        void'(uvm_config_db #(virtual mqnic_reset_if)::get(this, "", "rst_rd_vif", m_rst_rd_vif));
    endfunction

    // The two DUTs are independent, so a test that drives only one must not be
    // failed by the other scoreboard's "you checked nothing" drain rule. The
    // synchronous RAM is the default; t2_cdc_* flips this.
    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_asb.m_enable_end_check     = 1'b0;
        m_env.m_cli_sb.m_enable_end_check  = 1'b0;
    endfunction

    // Both async domains must come out of reset before any traffic.
    protected task reset_async_domains();
        fork
            if (m_rst_wr_vif != null) m_rst_wr_vif.pulse_reset(20);
            if (m_rst_rd_vif != null) m_rst_rd_vif.pulse_reset(20);
        join
    endtask

    protected task aram_write(int seg, bit [15:0] addr, bit [255:0] data,
                              bit [31:0] be = 32'hFFFF_FFFF);
        dma_ram_write_seq s = dma_ram_write_seq::type_id::create("s");
        s.seg = seg; s.addr = addr; s.data = data; s.be = be;
        s.start(m_env.m_aram_wr.sequencer);
    endtask

    protected task aram_read(int seg, bit [15:0] addr);
        dma_ram_read_seq s = dma_ram_read_seq::type_id::create("s");
        s.seg = seg; s.addr = addr;
        s.start(m_env.m_aram_rd.sequencer);
    endtask

    // Wait in the READ clock domain. The read side is the slower clock, so
    // counting its edges is what actually guarantees the crossing has settled.
    protected task idle_rd(int n);
        if (m_rst_rd_vif != null) repeat (n) @(posedge m_rst_rd_vif.clk);
        else                      idle(n);
    endtask

    protected task ram_write(int seg, bit [15:0] addr, bit [255:0] data,
                             bit [31:0] be = 32'hFFFF_FFFF);
        dma_ram_write_seq s = dma_ram_write_seq::type_id::create("s");
        s.seg = seg; s.addr = addr; s.data = data; s.be = be;
        s.start(m_env.m_ram.sequencer);
    endtask

    protected task ram_read(int seg, bit [15:0] addr);
        dma_ram_read_seq s = dma_ram_read_seq::type_id::create("s");
        s.seg = seg; s.addr = addr;
        s.start(m_env.m_ram.sequencer);
    endtask


    // ---- DMA client helpers --------------------------------------------------
    // The scoreboard's default is the synchronous RAM; client tests flip these.
    protected task cli_send_desc(bit is_write, bit [31:0] ram_addr,
                                 bit [15:0] len, bit [7:0] tag);
        dma_desc_pkg::dma_desc_seq d = dma_desc_pkg::dma_desc_seq::type_id::create("d");
        d.ram_addr = ram_addr; d.len = len; d.tag = tag;
        d.id = 0; d.dest = 0; d.user = 0;
        if (is_write) d.start(m_env.m_cli_wr_desc.sequencer);
        else          d.start(m_env.m_cli_rd_desc.sequencer);
    endtask

    protected task cli_send_packet(const ref byte unsigned bytes[]);
        axis_packet_seq p = axis_packet_seq::type_id::create("p");
        p.payload = new[bytes.size()];
        foreach (bytes[i]) p.payload[i] = bytes[i];
        p.delay_start = 0;
        p.start(m_env.m_cli_wr_pkt.sequencer);
    endtask

    // Preload the source client's RAM. The responder stores 256-bit words per
    // {segment, seg_addr}; the scoreboard works in linear bytes. Writing both
    // through one helper is what keeps them from drifting - and the address
    // split here is the same one documented in sb_dma_client.sv.
    protected function void cli_preload(int unsigned lin_addr, byte unsigned data);
        int unsigned seg_be   = 8;
        int unsigned n_seg    = 2;
        int unsigned byte_in  = lin_addr % seg_be;
        int unsigned seg      = (lin_addr / seg_be) % n_seg;
        int unsigned seg_addr = lin_addr / (seg_be * n_seg);
        bit [255:0]  w        = m_env.m_cli_rd_ram.peek(seg, 16'(seg_addr));
        w[byte_in*8 +: 8] = data;
        m_env.m_cli_rd_ram.poke(seg, 16'(seg_addr), w);
        m_env.m_cli_sb.preload(lin_addr, data);
    endfunction

    protected task idle(int n);
        repeat (n) @(posedge m_rst_vif.clk);
    endtask

    // -------------------------------------------------------------------------
    // Wait until every read command this agent issued has been answered.
    //
    // Replaces a fixed idle() at the end of a read burst. VCS found the reason:
    // t2_seg_independent_backpressure runs segment 1 at BP_AGGRESSIVE, and its
    // last two responses had not drained when the test finished - the monitor's
    // own check_phase caught it as "2 read command(s) never answered". A delay
    // long enough for one backpressure profile is too short for another, so
    // waiting on the actual condition is the only stable answer.
    //
    // The timeout is a real failure, not a convenience: if the DUT genuinely
    // stops answering, this reports it clearly instead of hanging until the
    // global watchdog fires with no explanation.
    // -------------------------------------------------------------------------
    protected task wait_ram_drained(dma_ram_agent a, int max_cycles = 20000);
        int n = 0;

        // is_idle() covers BOTH conditions: nothing left in the driver's
        // per-segment queues AND no read awaiting data. Waiting on bus activity
        // alone exits immediately, because seq.start() returns as soon as the
        // items are queued - which is exactly how this test previously issued 5
        // of its 64 reads and still reported matches.
        while (!a.is_idle() && n < max_cycles) begin
            @(posedge m_rst_vif.clk);
            n++;
        end

        if (!a.is_idle())
            `uvm_error(get_type_name(),
                $sformatf({"%s did not drain in %0d cycles: %0d item(s) still queued, ",
                           "%0d read(s) unanswered"},
                          a.get_name(), max_cycles,
                          a.pending_items(), a.outstanding_reads()))
        else
            idle(20);   // let the last response propagate to the scoreboard
    endtask

    // A distinctive pattern per {segment, address} so a crossed wire between
    // segments shows up as a data mismatch rather than passing by accident.
    protected function bit [255:0] pattern(int seg, bit [15:0] addr);
        bit [255:0] d;
        for (int w = 0; w < 8; w++)
            d[w*32 +: 32] = {8'(seg), 8'(w), addr};
        return d;
    endfunction

endclass : tier2_base_test


// -----------------------------------------------------------------------------
// t2_reset - quiescent through reset, no spurious completions.
// -----------------------------------------------------------------------------
class t2_reset extends tier2_base_test;

    `uvm_component_utils(t2_reset)

    function new(string name = "t2_reset", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_sb.m_enable_end_check = 1'b0;   // no traffic by design
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t2_reset");
        apply_power_on_reset();
        idle(50);
        m_rst_vif.inject_reset(5);
        idle(50);
        phase.drop_objection(this, "t2_reset");
    endtask

endclass : t2_reset


// -----------------------------------------------------------------------------
// t2_wr_rd_single_seg - one segment at a time. The simplest possible check, and
// the one to look at first if anything else fails.
// -----------------------------------------------------------------------------
class t2_wr_rd_single_seg extends tier2_base_test;

    `uvm_component_utils(t2_wr_rd_single_seg)

    function new(string name = "t2_wr_rd_single_seg", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t2_wr_rd_single_seg");
        apply_power_on_reset();
        idle(10);

        for (int s = 0; s < 2; s++) begin
            for (int a = 0; a < 8; a++) begin
                ram_write(s, 16'(a), pattern(s, 16'(a)));
                idle(20);
            end
            for (int a = 0; a < 8; a++) begin
                ram_read(s, 16'(a));
                idle(20);
            end
        end
        wait_ram_drained(m_env.m_ram);

        phase.drop_objection(this, "t2_wr_rd_single_seg");
    endtask

endclass : t2_wr_rd_single_seg


// -----------------------------------------------------------------------------
// t2_wr_rd_all_segs - every segment active at the same address on the same
// cycles. This is the pattern a real DMA client produces and the one a serial
// driver would never generate; it is what the per-segment driver servers exist
// for.
// -----------------------------------------------------------------------------
class t2_wr_rd_all_segs extends tier2_base_test;

    `uvm_component_utils(t2_wr_rd_all_segs)

    function new(string name = "t2_wr_rd_all_segs", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        dma_ram_all_seg_seq s;

        phase.raise_objection(this, "t2_wr_rd_all_segs");
        apply_power_on_reset();
        idle(10);

        for (int a = 0; a < 16; a++) begin
            s = dma_ram_all_seg_seq::type_id::create("wr");
            if (!s.randomize() with { n_segs == 2; addr == 16'(a); do_write == 1'b1; })
                `uvm_fatal(get_type_name(), "randomize failed")
            s.start(m_env.m_ram.sequencer);
            idle(25);
        end

        for (int a = 0; a < 16; a++) begin
            s = dma_ram_all_seg_seq::type_id::create("rd");
            if (!s.randomize() with { n_segs == 2; addr == 16'(a); do_write == 1'b0; })
                `uvm_fatal(get_type_name(), "randomize failed")
            s.start(m_env.m_ram.sequencer);
            idle(25);
        end
        wait_ram_drained(m_env.m_ram);

        phase.drop_objection(this, "t2_wr_rd_all_segs");
    endtask

endclass : t2_wr_rd_all_segs


// -----------------------------------------------------------------------------
// t2_byte_enables - partial writes must leave the untouched bytes alone.
//
// A DUT that ignored the byte enables and wrote the whole word would pass every
// other test in this tier, because every other test writes full-width.
// -----------------------------------------------------------------------------
class t2_byte_enables extends tier2_base_test;

    `uvm_component_utils(t2_byte_enables)

    function new(string name = "t2_byte_enables", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t2_byte_enables");
        apply_power_on_reset();
        idle(10);

        // Fill with a known background, then overwrite fragments of it.
        for (int s = 0; s < 2; s++) begin
            ram_write(s, 16'd0, {8{32'hA5A5_A5A5}});
            idle(20);
        end

        for (int s = 0; s < 2; s++) begin
            ram_write(s, 16'd0, {8{32'h5A5A_5A5A}}, 32'h0000_0001);  // byte 0 only
            idle(20);
            ram_read(s, 16'd0);
            idle(20);

            ram_write(s, 16'd0, {8{32'h1234_5678}}, 32'h0000_00F0);  // bytes 4-7
            idle(20);
            ram_read(s, 16'd0);
            idle(20);

            ram_write(s, 16'd0, {8{32'hFFFF_FFFF}}, 32'h0000_0000);  // no bytes
            idle(20);
            ram_read(s, 16'd0);
            idle(20);
        end
        wait_ram_drained(m_env.m_ram);

        phase.drop_objection(this, "t2_byte_enables");
    endtask

endclass : t2_byte_enables


// -----------------------------------------------------------------------------
// t2_seg_independent_backpressure - each segment gets a DIFFERENT read-response
// backpressure profile, so they cannot stall in lockstep.
//
// Lockstep is the one pattern guaranteed never to expose a per-segment bug, and
// it is what a single shared profile produces. STRATEGY §7.4.
// -----------------------------------------------------------------------------
class t2_seg_independent_backpressure extends tier2_base_test;

    `uvm_component_utils(t2_seg_independent_backpressure)

    function new(string name = "t2_seg_independent_backpressure",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_ram_cfg.bp_profile[0] = BP_NONE;        // never stalls
        m_env.m_ram_cfg.bp_profile[1] = BP_AGGRESSIVE;  // stalls most cycles
    endfunction

    virtual task run_phase(uvm_phase phase);
        dma_ram_random_seq s;

        phase.raise_objection(this, "t2_seg_independent_backpressure");
        apply_power_on_reset();
        idle(10);

        // Writes first so every address has known content, then mixed traffic.
        for (int a = 0; a < 16; a++) begin
            ram_write(0, 16'(a), pattern(0, 16'(a)));
            ram_write(1, 16'(a), pattern(1, 16'(a)));
            idle(15);
        end
        idle(60);

        s = dma_ram_random_seq::type_id::create("s");
        if (!s.randomize() with { n_ops == 64; n_segs == 2; addr_hi == 16'd15;
                                  write_pct == 0; })     // reads only: content known
            `uvm_fatal(get_type_name(), "randomize failed")
        s.start(m_env.m_ram.sequencer);
        wait_ram_drained(m_env.m_ram);

        phase.drop_objection(this, "t2_seg_independent_backpressure");
    endtask

endclass : t2_seg_independent_backpressure


// -----------------------------------------------------------------------------
// t2_random_stress - randomized traffic over both segments.
//
// Writes and reads are kept in separate phases: with a simple dual port RAM,
// interleaving them on the same address is a race, not a check.
// -----------------------------------------------------------------------------
class t2_random_stress extends tier2_base_test;

    `uvm_component_utils(t2_random_stress)

    function new(string name = "t2_random_stress", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        dma_ram_random_seq s;

        phase.raise_objection(this, "t2_random_stress");
        apply_power_on_reset();
        idle(10);

        for (int round = 0; round < 6; round++) begin
            s = dma_ram_random_seq::type_id::create($sformatf("wr%0d", round));
            if (!s.randomize() with { n_ops == 32; n_segs == 2; addr_hi == 16'd31;
                                      write_pct == 100; })
                `uvm_fatal(get_type_name(), "randomize failed")
            s.start(m_env.m_ram.sequencer);
            // Drain, not a fixed idle: the driver releases items before driving
            // them, and under random backpressure idle(120) let reads overtake
            // still-queued writes - the undefined race sb_dma_ram excludes.
            wait_ram_drained(m_env.m_ram);
            idle(10);

            s = dma_ram_random_seq::type_id::create($sformatf("rd%0d", round));
            if (!s.randomize() with { n_ops == 32; n_segs == 2; addr_hi == 16'd31;
                                      write_pct == 0; })
                `uvm_fatal(get_type_name(), "randomize failed")
            s.start(m_env.m_ram.sequencer);
            wait_ram_drained(m_env.m_ram);
        end
        idle(50);

        phase.drop_objection(this, "t2_random_stress");
    endtask

endclass : t2_random_stress


// -----------------------------------------------------------------------------
// t2_cdc_async - data written in the write clock domain must be readable in the
// read clock domain.
//
// The two clocks are at 4ns and 6ns, a ratio that never repeats a phase
// relationship. That is deliberate: at 1:1 or 2:1 the edges line up in a fixed
// pattern and a broken crossing can still pass.
//
// Every read is separated from its write by a generous settle time in the READ
// domain. dma_psdpram_async gives no completion signal on the read side, so
// "long enough" is the only available discipline - and this test is checking
// that the data crossed, not measuring how fast it crossed.
// -----------------------------------------------------------------------------
class t2_cdc_async extends tier2_base_test;

    `uvm_component_utils(t2_cdc_async)

    function new(string name = "t2_cdc_async", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_asb.m_enable_end_check = 1'b1;   // this test DOES drive it
        m_env.m_sb.m_enable_end_check  = 1'b0;   // ...and not the sync RAM
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t2_cdc_async");
        apply_power_on_reset();
        reset_async_domains();
        idle_rd(20);

        // Fill both segments across the write clock domain.
        for (int a = 0; a < 16; a++) begin
            aram_write(0, 16'(a), pattern(0, 16'(a)));
            aram_write(1, 16'(a), pattern(1, 16'(a)));
            idle(10);
        end

        // Let the crossing settle, measured in the SLOWER read domain.
        idle_rd(100);

        // Read it all back from the read clock domain.
        for (int a = 0; a < 16; a++) begin
            aram_read(0, 16'(a));
            aram_read(1, 16'(a));
            idle_rd(15);
        end
        wait_ram_drained(m_env.m_aram_rd);
        idle_rd(40);

        phase.drop_objection(this, "t2_cdc_async");
    endtask

endclass : t2_cdc_async


// -----------------------------------------------------------------------------
// t2_cdc_reset - each clock domain is reset INDEPENDENTLY, which is the case a
// shared-reset testbench never produces.
//
// A CDC whose synchroniser assumes both sides reset together will pass
// t2_cdc_async and fail here. The scoreboard's drain check is disabled because
// traffic is deliberately abandoned mid-flight across the resets.
// -----------------------------------------------------------------------------
class t2_cdc_reset extends tier2_base_test;

    `uvm_component_utils(t2_cdc_reset)

    function new(string name = "t2_cdc_reset", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        // In-flight traffic is discarded by the mid-test resets by design, so
        // neither scoreboard can be held to its drain rule here.
        m_env.m_asb.m_enable_end_check = 1'b0;
        m_env.m_sb.m_enable_end_check  = 1'b0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t2_cdc_reset");
        apply_power_on_reset();
        reset_async_domains();
        idle_rd(20);

        for (int a = 0; a < 8; a++) begin
            aram_write(0, 16'(a), pattern(0, 16'(a)));
            idle(8);
        end
        idle_rd(60);

        // Reset ONLY the read domain; the write domain keeps running.
        if (m_rst_rd_vif != null) m_rst_rd_vif.inject_reset(8);
        idle_rd(60);

        // Reset ONLY the write domain.
        if (m_rst_wr_vif != null) m_rst_wr_vif.inject_reset(8);
        idle_rd(60);

        // Both together, then confirm the RAM still functions.
        reset_async_domains();
        idle_rd(40);
        for (int a = 0; a < 4; a++) begin
            aram_write(0, 16'(a), pattern(0, 16'(a)));
            idle(8);
        end
        idle_rd(100);
        for (int a = 0; a < 4; a++) begin
            aram_read(0, 16'(a));
            idle_rd(15);
        end
        wait_ram_drained(m_env.m_aram_rd);
        idle_rd(40);

        phase.drop_objection(this, "t2_cdc_reset");
    endtask

endclass : t2_cdc_reset


// -----------------------------------------------------------------------------
// t2_client_sink - AXI-Stream in, RAM writes out.
//
// Checks that the DUT scatters a linear packet across the segments correctly:
// with SEG_COUNT=2 and SEG_BE_WIDTH=8, consecutive bytes alternate segments
// every 8 bytes. A client that assumed one segment holds the low half of memory
// would pass a single-segment test and corrupt everything here.
// -----------------------------------------------------------------------------
class t2_client_sink extends tier2_base_test;

    `uvm_component_utils(t2_client_sink)

    function new(string name = "t2_client_sink", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_cli_sb.m_enable_end_check = 1'b1;
        m_env.m_cli_sb.check_source       = 1'b0;   // sink only
        m_env.m_sb.m_enable_end_check     = 1'b0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        byte unsigned pkt [];

        phase.raise_objection(this, "t2_client_sink");
        apply_power_on_reset();
        idle(20);

        // Lengths chosen to straddle the 8-byte segment stride and the 16-byte
        // full-rotation: 8, 16 and 64 land on boundaries, the rest do not.
        foreach_len: begin
            int lens [] = '{1, 7, 8, 9, 15, 16, 17, 31, 32, 64};
            foreach (lens[i]) begin
                pkt = new[lens[i]];
                foreach (pkt[b]) pkt[b] = 8'(lens[i] * 16 + b);
                cli_send_desc(1'b1, 32'(i * 128), 16'(lens[i]), 8'(i));
                cli_send_packet(pkt);
                idle(80);
            end
        end
        idle(200);

        phase.drop_objection(this, "t2_client_sink");
    endtask

endclass : t2_client_sink


// -----------------------------------------------------------------------------
// t2_client_source - RAM in, AXI-Stream out.
//
// The mirror of the sink: the DUT must GATHER bytes that are spread across the
// segments back into a linear packet.
// -----------------------------------------------------------------------------
class t2_client_source extends tier2_base_test;

    `uvm_component_utils(t2_client_source)

    function new(string name = "t2_client_source", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_cli_sb.m_enable_end_check = 1'b1;
        m_env.m_cli_sb.check_sink         = 1'b0;   // source only
        m_env.m_sb.m_enable_end_check     = 1'b0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t2_client_source");
        apply_power_on_reset();
        idle(20);

        // Fill the region the descriptors will read, both in the responder RAM
        // and in the scoreboard's reference, through the single helper.
        for (int a = 0; a < 1024; a++)
            cli_preload(a, 8'(a * 3 + 1));
        idle(20);

        begin
            int lens [] = '{1, 7, 8, 9, 15, 16, 17, 31, 32, 64};
            foreach (lens[i]) begin
                cli_send_desc(1'b0, 32'(i * 64), 16'(lens[i]), 8'(i));
                idle(100);
            end
        end
        idle(250);

        phase.drop_objection(this, "t2_client_source");
    endtask

endclass : t2_client_source


// -----------------------------------------------------------------------------
// t2_cov_closure - directed stimulus for the cg_ram / cg_client holes:
//   * RAM (sync AND async/CDC): every byte-enable shape (single byte, low half,
//     high half, sparse, full) on both segments, and a read of a never-written
//     word, which must return the initial 0 (dma_psdpram.v:100-108).
//   * Clients: descriptors starting at every alignment within the 16-byte RAM
//     word, every length class, and sink packets SHORTER and LONGER than their
//     descriptor - the sink writes min(descriptor, packet) bytes.
// All three scoreboards check everything.
// -----------------------------------------------------------------------------
class t2_cov_closure extends tier2_base_test;

    `uvm_component_utils(t2_cov_closure)

    function new(string name = "t2_cov_closure", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_sb.m_enable_end_check     = 1'b1;
        m_env.m_asb.m_enable_end_check    = 1'b1;
        m_env.m_cli_sb.m_enable_end_check = 1'b1;
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [31:0]    bes [] = '{32'h0000_0001, 32'h0000_0080, 32'h0000_00FF,
                                 32'h0000_FF00, 32'h0000_A5C3, 32'h0000_FFFF};
        // Word start and segment-1 start only: the clients mask ram_addr to the
        // 8-byte stream word (ADDR_MASK), so unaligned starts are illegal.
        int           aligns [] = '{0, 8};
        int           lens   [] = '{1, 5, 8, 12, 16, 40};
        byte unsigned pkt [];
        int           tag = 0;

        phase.raise_objection(this, "t2_cov_closure");
        apply_power_on_reset();
        reset_async_domains();
        idle(20);

        // ---- RAM: byte-enable shapes, then read back ------------------------
        foreach (bes[i])
            for (int seg = 0; seg < 2; seg++) begin
                ram_write(seg, 16'(40 + i), pattern(seg, 16'(40 + i)), bes[i]);
                aram_write(seg, 16'(40 + i), pattern(seg, 16'(40 + i)), bes[i]);
            end
        wait_ram_drained(m_env.m_ram);
        wait_ram_drained(m_env.m_aram_wr);
        idle_rd(40);
        foreach (bes[i])
            for (int seg = 0; seg < 2; seg++) begin
                ram_read(seg, 16'(40 + i));
                aram_read(seg, 16'(40 + i));
            end
        for (int seg = 0; seg < 2; seg++) begin     // never written: must read 0
            ram_read(seg, 16'd100);
            aram_read(seg, 16'd100);
        end
        wait_ram_drained(m_env.m_ram);
        wait_ram_drained(m_env.m_aram_rd);
        idle_rd(40);

        // ---- clients: alignment x length, and sink packet vs descriptor -----
        // Covers every source range below (up to 128*11 + 8 + 40 bytes).
        for (int a = 0; a < 2048; a++) cli_preload(a, 8'(a * 5 + 7));
        foreach (aligns[i])
            foreach (lens[j]) begin
                int base = 128 * (i * lens.size() + j) + aligns[i];
                // source: RAM -> stream
                cli_send_desc(1'b0, 32'(base), 16'(lens[j]), 8'(tag++));
                idle(60);
                // sink: packet shorter / equal / longer than the descriptor
                for (int rel = -1; rel <= 1; rel++) begin
                    int plen = lens[j] + rel * 3;
                    if (plen < 1) continue;
                    pkt = new[plen];
                    foreach (pkt[b]) pkt[b] = 8'(base + b + rel * 16);
                    // 256-byte stride per case, 64 per variant: transfers of up
                    // to 43 bytes never overlap (they did at 32, which made the
                    // model and the RAM disagree about who wrote a byte last).
                    cli_send_desc(1'b1, 32'(4096 + 256 * (i * lens.size() + j)
                                            + aligns[i] + (rel + 1) * 64),
                                  16'(lens[j]), 8'(tag++));
                    cli_send_packet(pkt);
                    idle(60);
                end
            end

        // Packets SHORTER than the descriptor that write exactly 1, 8 and 16
        // bytes - the loop above only produces shorter writes of other sizes.
        begin
            int shorter [3][2] = '{'{4, 1}, '{11, 8}, '{19, 16}};   // {desc, packet}
            foreach (shorter[k]) begin
                pkt = new[shorter[k][1]];
                foreach (pkt[b]) pkt[b] = 8'(k * 32 + b);
                cli_send_desc(1'b1, 32'(12288 + 64 * k), 16'(shorter[k][0]), 8'(tag++));
                cli_send_packet(pkt);
                idle(60);
            end
        end
        idle(300);

        phase.drop_objection(this, "t2_cov_closure");
    endtask

endclass : t2_cov_closure

`endif // TIER2_TESTS_SV

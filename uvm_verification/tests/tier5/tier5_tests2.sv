// SPDX-License-Identifier: BSD-2-Clause-Views
//
// Tier 5 test suite, part 2 - register access under load
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §13 Tier 5, §8.2
// Introduced : Step 7 (Tier 5)
//
// t5_rb_walk proves the map has the right SHAPE. These prove the register path
// returns the right DATA, stays stable, and pairs completions correctly when
// several are in flight.
// -----------------------------------------------------------------------------

`ifndef TIER5_TESTS2_SV
`define TIER5_TESTS2_SV

// -----------------------------------------------------------------------------
// t5_fw_id - the firmware identification block reads back sane values.
//
// The first block the Linux driver reads, and the anchor for everything else.
// Its registers are read-only constants baked in at synthesis, which makes this
// the cleanest check that the path delivers the RIGHT data rather than merely
// SOME data: a path returning zero for everything passes t5_rb_walk's
// structural checks and fails here.
// -----------------------------------------------------------------------------
class t5_fw_id extends tier5_base_test;

    `uvm_component_utils(t5_fw_id)

    function new(string name = "t5_fw_id", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        mqnic_rb_walker w;
        bit [63:0] base;
        bit [31:0] fpga_id, fw_id, fw_ver, board_id;
        bit        ok;

        phase.raise_objection(this, "t5_fw_id");
        apply_power_on_reset();
        idle(50);

        w     = mqnic_rb_walker::type_id::create("walker");
        w.ctx = m_env.m_ctx;
        w.walk(m_env.m_req.sequencer, m_bar_base);

        if (!w.has_type(32'hFFFFFFFF)) begin
            `uvm_error(get_type_name(), "no FW ID block to read")
            phase.drop_objection(this, "t5_fw_id");
            return;
        end
        base = w.base_of(32'hFFFFFFFF);

        csr_read(base + 64'(mqnic_ral_pkg::RB_FW_ID_FPGA_ID),  fpga_id,  ok);
        csr_read(base + 64'(mqnic_ral_pkg::RB_FW_ID_FW_ID),    fw_id,    ok);
        csr_read(base + 64'(mqnic_ral_pkg::RB_FW_ID_FW_VER),   fw_ver,   ok);
        csr_read(base + 64'(mqnic_ral_pkg::RB_FW_ID_BOARD_ID), board_id, ok);

        `uvm_info(get_type_name(),
            $sformatf("fpga_id=0x%08h fw_id=0x%08h fw_ver=0x%08h board_id=0x%08h",
                      fpga_id, fw_id, fw_ver, board_id), UVM_LOW)

        // All four zero means the path is returning nothing rather than reading
        // anything - the failure a purely structural walk cannot see.
        if (fpga_id == 0 && fw_id == 0 && fw_ver == 0 && board_id == 0)
            `uvm_error(get_type_name(),
                {"every FW ID register read as zero - the register path is ",
                 "returning data that was never in the DUT"})

        idle(50);
        phase.drop_objection(this, "t5_fw_id");
    endtask

endclass : t5_fw_id


// -----------------------------------------------------------------------------
// t5_rb_walk_repeat - discovery is idempotent.
//
// The driver walks the list on every probe, so a map that changes between walks
// makes the device unusable. Blocks are compared FIELD BY FIELD rather than by
// count: a register path returning stale completion data would produce two
// walks that agree for the wrong reason.
// -----------------------------------------------------------------------------
class t5_rb_walk_repeat extends tier5_base_test;

    `uvm_component_utils(t5_rb_walk_repeat)

    function new(string name = "t5_rb_walk_repeat", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        mqnic_rb_walker a, b;

        phase.raise_objection(this, "t5_rb_walk_repeat");
        apply_power_on_reset();
        idle(50);

        a = mqnic_rb_walker::type_id::create("walk_a");
        a.ctx = m_env.m_ctx;
        a.walk(m_env.m_req.sequencer, m_bar_base);

        idle(200);

        b = mqnic_rb_walker::type_id::create("walk_b");
        b.ctx = m_env.m_ctx;
        b.walk(m_env.m_req.sequencer, m_bar_base);

        if (a.blocks.size() != b.blocks.size()) begin
            `uvm_error(get_type_name(),
                $sformatf("walk 1 found %0d block(s), walk 2 found %0d",
                          a.blocks.size(), b.blocks.size()))
        end
        else begin
            foreach (a.blocks[i]) begin
                if (a.blocks[i].base    !== b.blocks[i].base    ||
                    a.blocks[i].rb_type !== b.blocks[i].rb_type ||
                    a.blocks[i].version !== b.blocks[i].version) begin
                    `uvm_error(get_type_name(),
                        $sformatf({"block %0d differs between walks: ",
                                   "0x%0h/0x%08h/0x%08h vs 0x%0h/0x%08h/0x%08h"},
                                  i, a.blocks[i].base, a.blocks[i].rb_type,
                                  a.blocks[i].version,
                                  b.blocks[i].base, b.blocks[i].rb_type,
                                  b.blocks[i].version))
                end
            end
        end

        idle(50);
        phase.drop_objection(this, "t5_rb_walk_repeat");
    endtask

endclass : t5_rb_walk_repeat


// -----------------------------------------------------------------------------
// t5_csr_outstanding - several register reads in flight at once.
//
// Register access is a SPLIT TRANSACTION, so completions may return out of
// order. mqnic_csr_ctx keys them by tag, and this is the test that fails if it
// ever pairs them positionally: each value read under load is compared against
// what the SAME address returned when read alone.
// -----------------------------------------------------------------------------
class t5_csr_outstanding extends tier5_base_test;

    `uvm_component_utils(t5_csr_outstanding)

    function new(string name = "t5_csr_outstanding", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        mqnic_rb_walker w;
        bit [31:0] solo [8];
        bit [31:0] d;
        bit        ok;
        int        n;

        phase.raise_objection(this, "t5_csr_outstanding");
        apply_power_on_reset();
        idle(50);

        w     = mqnic_rb_walker::type_id::create("walker");
        w.ctx = m_env.m_ctx;
        w.walk(m_env.m_req.sequencer, m_bar_base);

        n = (w.blocks.size() < 8) ? w.blocks.size() : 8;
        if (n == 0) begin
            `uvm_error(get_type_name(), "no blocks to read")
            phase.drop_objection(this, "t5_csr_outstanding");
            return;
        end

        // Baseline: each block's type register, read one at a time.
        for (int i = 0; i < n; i++)
            csr_read(w.blocks[i].base + 64'(mqnic_ral_pkg::RB_REG_TYPE), solo[i], ok);

        // The same reads back to back, so several are outstanding together.
        // CONCURRENT: all n reads of a round are in flight together. The first
        // version issued them one after another - each csr_read waits for its
        // own completion - so there was never a second read outstanding and the
        // pairing this test is named for was never exercised (cg_csr cp_depth
        // stayed at "alone" on every seed).
        for (int rep = 0; rep < 4; rep++) begin
            for (int i = 0; i < n; i++) begin
                automatic int k = i;
                automatic int r = rep;
                fork begin
                    bit [31:0] dk;
                    bit        okk;
                    csr_read(w.blocks[k].base + 64'(mqnic_ral_pkg::RB_REG_TYPE), dk, okk);
                    if (!okk)
                        `uvm_error(get_type_name(),
                            $sformatf("read of block %0d timed out on repeat %0d", k, r))
                    else if (dk !== solo[k])
                        `uvm_error(get_type_name(),
                            $sformatf({"block %0d type read 0x%08h under load but ",
                                       "0x%08h alone - completions are being paired ",
                                       "with the wrong request"}, k, dk, solo[k]))
                end join_none
            end
            wait fork;
        end

        idle(50);
        phase.drop_objection(this, "t5_csr_outstanding");
    endtask

endclass : t5_csr_outstanding


// -----------------------------------------------------------------------------
// t5_csr_bad_addr - a read outside any register block still completes.
//
// The DUT must answer every request it accepts. An address with no block behind
// it may return anything, but it must NOT be dropped - a swallowed request
// stalls the driver forever, and it is the kind of hole that only shows up on
// hardware.
// -----------------------------------------------------------------------------
class t5_csr_bad_addr extends tier5_base_test;

    `uvm_component_utils(t5_csr_bad_addr)

    function new(string name = "t5_csr_bad_addr", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [31:0] d;
        bit        ok;

        phase.raise_objection(this, "t5_csr_bad_addr");
        apply_power_on_reset();
        idle(50);

        // Well past anything the block list covers, still inside the BAR.
        for (int i = 0; i < 4; i++) begin
            csr_read(m_bar_base + 64'h0000_7F00 + 64'(i * 4), d, ok);
            if (!ok)
                `uvm_error(get_type_name(),
                    $sformatf({"read of unmapped address 0x%0h was never completed - ",
                               "a dropped request stalls the driver indefinitely"},
                              m_bar_base + 64'h0000_7F00 + 64'(i * 4)))
            else
                `uvm_info(get_type_name(),
                    $sformatf("unmapped read returned 0x%08h", d), UVM_MEDIUM)
        end

        idle(50);
        phase.drop_objection(this, "t5_csr_bad_addr");
    endtask

endclass : t5_csr_bad_addr


// -----------------------------------------------------------------------------
// t5_cov_closure - the register-access cases no Tier 5 test made (cg_csr):
//   * WRITES: every block's list header (TYPE / VER / NEXT) is read-only, so a
//     write must be ignored - checked by reading each one back unchanged.
//   * Reads of each block's body and of an address past the block list.
//   * The UR path: a non-memory request (an I/O read) must be answered with an
//     Unsupported Request completion carrying no data (pcie_axil_master.v:560-569),
//     which the collector delivers as the status-only marker 0xBAD0_C0DE.
// -----------------------------------------------------------------------------
class t5_cov_closure extends tier5_base_test;

    `uvm_component_utils(t5_cov_closure)

    function new(string name = "t5_cov_closure", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // A single-DWORD I/O read (fmt 3DW no data, type 00010), tag from the shared
    // context so the collector can hand the completion back.
    protected task io_read(bit [31:0] addr, output bit [31:0] data, output bit ok);
        pcie_tlp_single_seq s = pcie_tlp_single_seq::type_id::create("io_rd");
        bit [7:0]    tag = m_env.m_ctx.alloc_tag();
        bit [127:0]  h   = '0;
        int unsigned waited = 0;

        h[127:125] = mqnic_vrf_pkg::TLP_FMT_3DW;
        h[124:120] = 5'b00010;                      // I/O request
        h[105:96]  = 10'd1;
        h[95:80]   = m_env.m_ctx.requester_id;
        h[79:72]   = tag;
        h[67:64]   = 4'b1111;
        h[63:34]   = addr[31:2];
        s.hdr = h; s.bar_id = m_env.m_ctx.bar_id; s.func_num = 0;
        s.payload_bytes = 0; s.delay = 0;
        s.start(m_env.m_req.sequencer);

        while (!m_env.m_ctx.have(tag) && waited < 20000) begin
            idle(1);
            waited++;
        end
        ok   = m_env.m_ctx.have(tag);
        data = ok ? m_env.m_ctx.take(tag) : 32'hDEAD_BEEF;
    endtask

    virtual task run_phase(uvm_phase phase);
        bit [31:0] bases [7] = '{32'h000, 32'h040, 32'h050, 32'h070,
                                 32'h080, 32'h100, 32'h200};
        bit [31:0] hdr_before [7][3];
        bit [31:0] d;
        bit        ok;

        phase.raise_objection(this, "t5_cov_closure");
        apply_power_on_reset();
        idle(50);

        // ---- header registers: read, write junk, read back unchanged --------
        foreach (bases[b])
            for (int r = 0; r < 3; r++) begin
                csr_read(m_bar_base + 64'(bases[b] + 4 * r), hdr_before[b][r], ok);
                if (!ok) `uvm_error(get_type_name(), $sformatf("read 0x%0h timed out", bases[b] + 4 * r))
            end
        foreach (bases[b])
            for (int r = 0; r < 3; r++)
                csr_write(m_bar_base + 64'(bases[b] + 4 * r), 32'hA5A5_5A5A ^ bases[b]);
        idle(50);
        foreach (bases[b])
            for (int r = 0; r < 3; r++) begin
                csr_read(m_bar_base + 64'(bases[b] + 4 * r), d, ok);
                if (ok && d !== hdr_before[b][r])
                    `uvm_error(get_type_name(),
                        $sformatf({"read-only list header 0x%0h changed after a write: ",
                                   "0x%08h -> 0x%08h"}, bases[b] + 4 * r, hdr_before[b][r], d))
            end

        // ---- body registers, and past the end of the block list -------------
        foreach (bases[b]) csr_read(m_bar_base + 64'(bases[b] + 32'hC), d, ok);
        csr_read(m_bar_base + 64'h300, d, ok);

        // ---- a deep burst: all 21 header reads in flight together ----------
        // Reads complete faster than the driver issues them, so with a
        // never-stalling completion sink the depth stays at 1-3. Stalling the
        // completion path makes completions queue in pcie_axil_master's
        // 32-entry response FIFO (RESP_FIFO_ADDR_WIDTH=5) - which is also the
        // only test of that FIFO under backpressure.
        m_env.m_cpl_cfg.bp_profile = BP_AGGRESSIVE;
        fork begin
            foreach (bases[b])
                for (int r = 0; r < 3; r++) begin
                    automatic int bb = b;
                    automatic int rr = r;
                    fork begin
                        bit [31:0] dk;
                        bit        okk;
                        csr_read(m_bar_base + 64'(bases[bb] + 4 * rr), dk, okk);
                        if (okk && dk !== hdr_before[bb][rr])
                            `uvm_error(get_type_name(),
                                $sformatf("header 0x%0h read 0x%08h in a burst, 0x%08h alone",
                                          bases[bb] + 4 * rr, dk, hdr_before[bb][rr]))
                    end join_none
                end
            wait fork;
        end join
        m_env.m_cpl_cfg.bp_profile = BP_NONE;

        // ---- UR: a request the AXI-Lite bridge does not support ------------
        io_read(32'h0000_0000, d, ok);
        if (!ok)
            `uvm_error(get_type_name(), "I/O read got no completion - UR must still be returned")
        else if (d !== 32'hBAD0_C0DE)
            `uvm_error(get_type_name(),
                $sformatf("I/O read returned data 0x%08h; a UR completion carries none", d))

        idle(50);
        phase.drop_objection(this, "t5_cov_closure");
    endtask

endclass : t5_cov_closure

`endif // TIER5_TESTS2_SV

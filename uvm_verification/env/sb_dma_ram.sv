// SPDX-License-Identifier: BSD-2-Clause-Views
//
// sb_dma_ram - Tier 2 scoreboard (segmented RAM)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §11, §5 Tier 2
// Introduced : Step 4 (Tier 2)
//
// Models the RAM the DUT is supposed to be, and checks three things:
//   1. read data == what was written to that {segment, address}
//   2. every accepted write produces exactly one wr_done on its own segment
//   3. byte enables are honoured - a partial write must not disturb the
//      untouched bytes
//
// ORDERING ASSUMPTION, stated because it bounds what can be checked here.
// dma_psdpram is a SIMPLE DUAL PORT RAM: the write and read ports are
// independent, so a read issued to an address whose write has not yet completed
// is a genuine race in the DUT, not a defined behaviour. The Tier 2 tests
// therefore wait for wr_done before reading an address they just wrote, and
// this scoreboard assumes that discipline. A test that violates it would report
// a mismatch that says nothing about the DUT.
//
// wr_done carries NO address (dma_psdpram.v:61), so it can only be counted, not
// paired. Per-segment counting is still a real check: a DUT that dropped or
// duplicated a completion fails it.
// -----------------------------------------------------------------------------

`ifndef SB_DMA_RAM_SV
`define SB_DMA_RAM_SV

`uvm_analysis_imp_decl(_ram_wr)
`uvm_analysis_imp_decl(_ram_done)
`uvm_analysis_imp_decl(_ram_data)

class sb_dma_ram extends mqnic_scoreboard_base;

    `uvm_component_utils(sb_dma_ram)

    uvm_analysis_imp_ram_wr   #(dma_ram_item, sb_dma_ram) wr_imp;
    uvm_analysis_imp_ram_done #(dma_ram_item, sb_dma_ram) done_imp;
    uvm_analysis_imp_ram_data #(dma_ram_item, sb_dma_ram) data_imp;

    dma_ram_cfg cfg;
    cg_ram      cov;         // optional functional coverage

    // Reference memory, keyed by {segment, address}.
    protected bit [255:0]  m_mem [longint unsigned];

    // Writes accepted but not yet completed, per segment.
    protected int unsigned m_done_expected [DMA_RAM_MAX_SEG_COUNT];
    protected int unsigned m_done_seen     [DMA_RAM_MAX_SEG_COUNT];

    function new(string name, uvm_component parent);
        super.new(name, parent);
        wr_imp   = new("wr_imp", this);
        done_imp = new("done_imp", this);
        data_imp = new("data_imp", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(dma_ram_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "no dma_ram_cfg in config_db under key cfg")
        foreach (m_done_expected[s]) begin
            m_done_expected[s] = 0;
            m_done_seen[s]     = 0;
        end
    endfunction

    virtual function int unsigned pending_count();
        int unsigned n = 0;
        for (int s = 0; s < int'(cfg.seg_count); s++)
            n += (m_done_expected[s] - m_done_seen[s]);
        return n;
    endfunction

    protected function longint unsigned key(int seg, bit [15:0] addr);
        return (longint'(seg) << 32) | longint'(addr);
    endfunction

    // -------------------------------------------------------------------------
    // A write updates the reference memory under its byte enables, and owes one
    // completion on the same segment.
    // -------------------------------------------------------------------------
    virtual function void write_ram_wr(dma_ram_item t);
        longint unsigned k   = key(t.seg, t.addr);
        bit [255:0]      old = m_mem.exists(k) ? m_mem[k] : '0;

        for (int b = 0; b < int'(cfg.seg_be_width()); b++)
            if (t.be[b]) old[b*8 +: 8] = t.data[b*8 +: 8];
        m_mem[k] = old;

        m_done_expected[t.seg]++;
        note_expected();
        if (cov != null) cov.sample_write(t.seg, t.be);
        `uvm_info(get_type_name(),
            $sformatf("seg %0d addr 0x%0h <- 0x%0h (be 0x%0h)",
                      t.seg, t.addr, old, t.be), UVM_HIGH)
    endfunction

    // -------------------------------------------------------------------------
    virtual function void write_ram_done(dma_ram_item t);
        note_actual();
        m_done_seen[t.seg]++;

        if (m_done_seen[t.seg] > m_done_expected[t.seg]) begin
            note_mismatch($sformatf("seg %0d write completions", t.seg),
                          $sformatf("%0d", m_done_expected[t.seg]),
                          $sformatf("%0d (one too many)", m_done_seen[t.seg]));
            return;
        end
        note_match($sformatf("seg %0d write completion %0d", t.seg, m_done_seen[t.seg]));
    endfunction

    // -------------------------------------------------------------------------
    // Read data is compared against the reference memory at the address the
    // monitor resolved by pairing with the outstanding read command.
    // -------------------------------------------------------------------------
    virtual function void write_ram_data(dma_ram_item t);
        longint unsigned k;
        bit [255:0]      exp;
        bit [255:0]      act;
        int              dw = int'(cfg.seg_data_width);

        note_actual();

        k   = key(t.seg, t.addr);
        exp = m_mem.exists(k) ? m_mem[k] : '0;

        // Compare only the bits this configuration actually uses.
        exp = exp & ((256'd1 << dw) - 256'd1);
        act = t.data & ((256'd1 << dw) - 256'd1);

        if (exp !== act) begin
            note_mismatch($sformatf("read data seg %0d addr 0x%0h", t.seg, t.addr),
                          $sformatf("0x%0h", exp),
                          $sformatf("0x%0h", act));
            return;
        end
        note_match($sformatf("read seg %0d addr 0x%0h", t.seg, t.addr));
        if (cov != null) cov.sample_read(t.seg, m_mem.exists(k));
    endfunction

    // -------------------------------------------------------------------------
    virtual function void report_phase(uvm_phase phase);
        string s = "";
        super.report_phase(phase);
        for (int i = 0; i < int'(cfg.seg_count); i++)
            s = {s, $sformatf(" seg%0d:%0d/%0d", i, m_done_seen[i], m_done_expected[i])};
        `uvm_info(get_type_name(),
            $sformatf("write completions seen/expected per segment:%s", s), UVM_LOW)
    endfunction

endclass : sb_dma_ram

`endif // SB_DMA_RAM_SV

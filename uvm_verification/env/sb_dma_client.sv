// SPDX-License-Identifier: BSD-2-Clause-Views
//
// sb_dma_client - Tier 2 scoreboard for the DMA stream clients
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §11, §5 Tier 2
// Introduced : Step 4 (Tier 2)
//
// Checks the translation between a SEGMENTED RAM and an AXI-STREAM, in both
// directions:
//
//   dma_client_axis_sink   descriptor + stream in  -> RAM writes
//   dma_client_axis_source descriptor + RAM        -> stream out
//
// ADDRESS MAPPING IS THE HEART OF IT. A linear RAM byte address is split across
// the segments, not laid out per segment. With SEG_COUNT=2 and SEG_BE_WIDTH=8:
//
//   byte_in_seg = addr[2:0]        (log2 SEG_BE_WIDTH)
//   segment     = addr[3]          (log2 SEG_COUNT)
//   seg_addr    = addr[15:4]
//
// so consecutive bytes alternate between segments every SEG_BE_WIDTH bytes.
// A model that assumed "segment 0 holds the low half of memory" would pass a
// single-segment test and corrupt everything at SEG_COUNT=2 - which is exactly
// the class of bug this tier exists to catch before Tier 3 inherits it.
// -----------------------------------------------------------------------------

`ifndef SB_DMA_CLIENT_SV
`define SB_DMA_CLIENT_SV

`uvm_analysis_imp_decl(_cli_wr_desc)
`uvm_analysis_imp_decl(_cli_wr_pkt)
`uvm_analysis_imp_decl(_cli_wr_ram)
`uvm_analysis_imp_decl(_cli_wr_sts)
`uvm_analysis_imp_decl(_cli_rd_desc)
`uvm_analysis_imp_decl(_cli_rd_pkt)

class sb_dma_client extends mqnic_scoreboard_base;

    `uvm_component_utils(sb_dma_client)

    // ---- sink (stream -> RAM) ----------------------------------------------
    uvm_analysis_imp_cli_wr_desc #(dma_desc_pkg::dma_desc_item, sb_dma_client) wr_desc_imp;
    uvm_analysis_imp_cli_wr_pkt  #(axis_item,                   sb_dma_client) wr_pkt_imp;
    uvm_analysis_imp_cli_wr_ram  #(dma_ram_item,                sb_dma_client) wr_ram_imp;
    uvm_analysis_imp_cli_wr_sts  #(dma_desc_pkg::dma_desc_item, sb_dma_client) wr_sts_imp;

    // ---- source (RAM -> stream) --------------------------------------------
    uvm_analysis_imp_cli_rd_desc #(dma_desc_pkg::dma_desc_item, sb_dma_client) rd_desc_imp;
    uvm_analysis_imp_cli_rd_pkt  #(axis_item,                   sb_dma_client) rd_pkt_imp;

    // Geometry, so the address split can be computed.
    int unsigned seg_count      = 2;
    int unsigned seg_be_width   = 8;

    cg_client cov;           // optional functional coverage

    bit check_sink   = 1'b1;
    bit check_source = 1'b1;

    // Reference memory, BYTE addressed in the linear RAM address space.
    protected byte unsigned m_mem [int unsigned];

    // sink: descriptors and packets pair in arrival order
    protected dma_desc_pkg::dma_desc_item m_wr_desc [$];
    protected axis_item                   m_wr_pkt  [$];
    protected int unsigned                m_wr_expected_sts;
    protected int unsigned                m_wr_seen_sts;
    // RAM writes seen before their bytes were predicted. The sink writes each
    // beat as it arrives, but the packet is only published at tlast, so every
    // multi-beat packet's first writes beat the prediction. Held here and
    // checked once the descriptor/packet pair lands; counted as pending, so a
    // write the model never predicts still fails the drain check.
    protected dma_ram_item                m_wr_ram_held [$];

    // source: expected outgoing packets, in descriptor order
    protected byte unsigned m_exp_rd_pkt [$][];

    function new(string name, uvm_component parent);
        super.new(name, parent);
        wr_desc_imp = new("wr_desc_imp", this);
        wr_pkt_imp  = new("wr_pkt_imp", this);
        wr_ram_imp  = new("wr_ram_imp", this);
        wr_sts_imp  = new("wr_sts_imp", this);
        rd_desc_imp = new("rd_desc_imp", this);
        rd_pkt_imp  = new("rd_pkt_imp", this);
    endfunction

    virtual function int unsigned pending_count();
        return m_exp_rd_pkt.size() + (m_wr_expected_sts - m_wr_seen_sts)
               + m_wr_ram_held.size();
    endfunction

    // -------------------------------------------------------------------------
    // Linear byte address -> {segment, segment address, byte within segment}.
    // See the file header for why this split matters.
    // -------------------------------------------------------------------------
    protected function void split_addr(input int unsigned lin,
                                       output int unsigned seg,
                                       output int unsigned seg_addr,
                                       output int unsigned byte_in_seg);
        byte_in_seg = lin % seg_be_width;
        seg         = (lin / seg_be_width) % seg_count;
        seg_addr    = lin / (seg_be_width * seg_count);
    endfunction

    // Test-side preload, used before a source-client descriptor.
    virtual function void preload(int unsigned lin_addr, byte unsigned data);
        m_mem[lin_addr] = data;
    endfunction

    virtual function byte unsigned peek(int unsigned lin_addr);
        return m_mem.exists(lin_addr) ? m_mem[lin_addr] : 8'h00;
    endfunction

    // =========================================================================
    // SINK: descriptor + stream packet -> RAM writes
    // =========================================================================
    virtual function void write_cli_wr_desc(dma_desc_pkg::dma_desc_item t);
        if (!check_sink) return;
        m_wr_desc.push_back(t);
        m_wr_expected_sts++;
        note_expected();
        try_pair_sink();
    endfunction

    virtual function void write_cli_wr_pkt(axis_item t);
        if (!check_sink) return;
        m_wr_pkt.push_back(t);
        try_pair_sink();
    endfunction

    // A descriptor and its packet arrive on independent channels, so pair them
    // in arrival order rather than assuming one precedes the other.
    protected virtual function void try_pair_sink();
        dma_desc_pkg::dma_desc_item d;
        axis_item                   p;
        int unsigned                n;

        while (m_wr_desc.size() > 0 && m_wr_pkt.size() > 0) begin
            d = m_wr_desc.pop_front();
            p = m_wr_pkt.pop_front();

            // The DUT writes min(descriptor length, packet length) bytes.
            n = (p.data.size() < int'(d.len)) ? p.data.size() : int'(d.len);
            for (int i = 0; i < int'(n); i++)
                m_mem[int'(d.ram_addr) + i] = p.data[i];
            if (cov != null) cov.sample_sink(d.len, p.data.size(), d.ram_addr);

            `uvm_info(get_type_name(),
                $sformatf("sink: %0d bytes of packet -> RAM 0x%0h (desc len %0d, tag 0x%0h)",
                          n, d.ram_addr, d.len, d.tag), UVM_HIGH)
        end
        check_held_writes();
    endfunction

    protected function int unsigned lin_base_of(dma_ram_item t);
        // Linear address of byte 0 of this segment word.
        return (int'(t.addr) * seg_count + int'(t.seg)) * seg_be_width;
    endfunction

    // True once every enabled byte of the write has a predicted value.
    protected function bit predicted(dma_ram_item t);
        int unsigned lin_base = lin_base_of(t);
        for (int b = 0; b < int'(seg_be_width); b++)
            if (t.be[b] && !m_mem.exists(lin_base + b)) return 1'b0;
        return 1'b1;
    endfunction

    protected function void check_held_writes();
        dma_ram_item still [$];
        foreach (m_wr_ram_held[i]) begin
            if (predicted(m_wr_ram_held[i])) compare_ram_write(m_wr_ram_held[i]);
            else                            still.push_back(m_wr_ram_held[i]);
        end
        m_wr_ram_held = still;
    endfunction

    // Every RAM write the DUT makes must match what the reference memory says
    // should be at that {segment, address}.
    virtual function void write_cli_wr_ram(dma_ram_item t);
        if (!check_sink) return;
        note_actual();
        if (predicted(t)) compare_ram_write(t);
        else              m_wr_ram_held.push_back(t);
    endfunction

    protected function void compare_ram_write(dma_ram_item t);
        int unsigned  lin_base = lin_base_of(t);
        byte unsigned exp;
        byte unsigned act;

        for (int b = 0; b < int'(seg_be_width); b++) begin
            if (!t.be[b]) continue;
            exp = peek(lin_base + b);
            act = t.data[b*8 +: 8];
            if (exp !== act) begin
                note_mismatch($sformatf({"sink RAM write seg %0d seg_addr 0x%0h byte %0d ",
                                         "(linear 0x%0h)"}, t.seg, t.addr, b, lin_base + b),
                              $sformatf("0x%02h", exp), $sformatf("0x%02h", act));
                return;
            end
        end
        note_match($sformatf("sink RAM write seg %0d addr 0x%0h", t.seg, t.addr));
    endfunction

    virtual function void write_cli_wr_sts(dma_desc_pkg::dma_desc_item t);
        if (!check_sink) return;
        m_wr_seen_sts++;
        if (t.error != 0)
            note_mismatch($sformatf("sink status tag 0x%0h", t.tag),
                          "error 0", $sformatf("error %0d", t.error));
        else
            note_match($sformatf("sink status tag 0x%0h len %0d", t.tag, t.sts_len));
    endfunction

    // =========================================================================
    // SOURCE: descriptor + RAM -> stream packet
    // =========================================================================
    virtual function void write_cli_rd_desc(dma_desc_pkg::dma_desc_item t);
        byte unsigned exp [];

        if (!check_source) return;

        exp = new[t.len];
        for (int i = 0; i < int'(t.len); i++)
            exp[i] = peek(int'(t.ram_addr) + i);

        m_exp_rd_pkt.push_back(exp);
        note_expected();
        if (cov != null) cov.sample_source(t.len, t.ram_addr);
        `uvm_info(get_type_name(),
            $sformatf("source: expect %0d-byte packet from RAM 0x%0h (tag 0x%0h)",
                      t.len, t.ram_addr, t.tag), UVM_HIGH)
    endfunction

    virtual function void write_cli_rd_pkt(axis_item t);
        byte unsigned exp [];

        if (!check_source) return;
        note_actual();

        if (m_exp_rd_pkt.size() == 0) begin
            note_mismatch("source emitted a packet with no descriptor outstanding",
                          "no packet", $sformatf("%0d bytes", t.data.size()));
            return;
        end
        exp = m_exp_rd_pkt.pop_front();
        compare_bytes("source packet", exp, t.data);
    endfunction

    // -------------------------------------------------------------------------
    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf("sink status seen/expected = %0d/%0d, source packets pending = %0d",
                      m_wr_seen_sts, m_wr_expected_sts, m_exp_rd_pkt.size()), UVM_LOW)
    endfunction

endclass : sb_dma_client

`endif // SB_DMA_CLIENT_SV

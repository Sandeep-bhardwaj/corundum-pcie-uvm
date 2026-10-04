// SPDX-License-Identifier: BSD-2-Clause-Views
//
// sb_offload - Tier 1c scoreboard (rx_checksum + rx_hash)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §11, §10
// Introduced : Step 3 (Tier 1c)
//
// rx_checksum and rx_hash are tapped off the SAME ingress stream in
// mqnic_ingress.v (:97 and :166), so the Tier 1c top drives one stimulus stream
// into both. One packet in therefore produces one checksum result and one hash
// result, and this scoreboard predicts both from the same observed packet.
//
// Both DUTs are pure functions of the frame with no back-pressure, so there is
// no ordering ambiguity: results come out in packet order.
// -----------------------------------------------------------------------------

`ifndef SB_OFFLOAD_SV
`define SB_OFFLOAD_SV

`uvm_analysis_imp_decl(_stim)
`uvm_analysis_imp_decl(_csum)
`uvm_analysis_imp_decl(_hash)
`uvm_analysis_imp_decl(_tx_in)
`uvm_analysis_imp_decl(_tx_cmd)
`uvm_analysis_imp_decl(_tx_out)

class sb_offload extends mqnic_scoreboard_base;

    `uvm_component_utils(sb_offload)

    uvm_analysis_imp_stim #(axis_item, sb_offload) stim_imp;
    uvm_analysis_imp_csum #(axis_item, sb_offload) csum_imp;
    uvm_analysis_imp_hash   #(axis_item,     sb_offload) hash_imp;
    uvm_analysis_imp_tx_in  #(axis_item,     sb_offload) tx_in_imp;
    uvm_analysis_imp_tx_cmd #(csum_cmd_item, sb_offload) tx_cmd_imp;
    uvm_analysis_imp_tx_out #(axis_item,     sb_offload) tx_out_imp;

    ref_checksum m_ref_csum;
    ref_hash     m_ref_hash;
    cg_offload   cov;        // optional functional coverage

    // Enable per DUT: a top that instantiates only one of them must not fail
    // the drain check on the other.
    bit check_csum = 1'b1;
    bit check_hash = 1'b1;
    bit check_tx   = 1'b1;

    protected bit [15:0] m_exp_csum [$];
    protected bit [31:0] m_exp_hash [$];
    protected bit [3:0]  m_exp_htyp [$];

    // Results that arrived BEFORE their stimulus packet was published. The stim
    // monitor publishes at tlast, but rx_hash needs only the headers and emits
    // its result mid-packet on anything longer than them - so "result first" is
    // normal, not an error. Both streams are in order, so pairing stays
    // positional; anything still held at the end counts as pending.
    protected bit [15:0] m_early_csum [$];
    protected bit [31:0] m_early_hash [$];
    protected bit [3:0]  m_early_htyp [$];

    // tx_checksum: a packet and its command arrive on separate channels and are
    // paired in arrival order - one command per packet (tx_checksum.v).
    protected axis_item     m_tx_pkt [$];
    protected csum_cmd_item m_tx_cmd [$];
    protected byte unsigned m_exp_tx [$][];

    function new(string name, uvm_component parent);
        super.new(name, parent);
        stim_imp   = new("stim_imp", this);
        csum_imp   = new("csum_imp", this);
        hash_imp   = new("hash_imp", this);
        tx_in_imp  = new("tx_in_imp", this);
        tx_cmd_imp = new("tx_cmd_imp", this);
        tx_out_imp = new("tx_out_imp", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (m_ref_csum == null) m_ref_csum = ref_checksum::type_id::create("m_ref_csum");
        if (m_ref_hash == null) m_ref_hash = ref_hash::type_id::create("m_ref_hash");
    endfunction

    virtual function int unsigned pending_count();
        return m_exp_csum.size() + m_exp_hash.size() + m_exp_tx.size()
               + m_early_csum.size() + m_early_hash.size();
    endfunction

    // -------------------------------------------------------------------------
    // tx_checksum. The packet and its command are independent streams; pair them
    // in arrival order and predict the modified frame once both are present.
    // -------------------------------------------------------------------------
    virtual function void write_tx_in(axis_item t);
        if (!check_tx) return;
        m_tx_pkt.push_back(t);
        try_predict_tx();
    endfunction

    virtual function void write_tx_cmd(csum_cmd_item t);
        if (!check_tx) return;
        m_tx_cmd.push_back(t);
        try_predict_tx();
    endfunction

    protected virtual function void try_predict_tx();
        axis_item     pkt;
        csum_cmd_item cmd;
        byte unsigned out [];

        while (m_tx_pkt.size() > 0 && m_tx_cmd.size() > 0) begin
            pkt = m_tx_pkt.pop_front();
            cmd = m_tx_cmd.pop_front();
            m_ref_csum.tx_expected(pkt.data, cmd.csum_enable, int'(cmd.csum_start),
                                   int'(cmd.csum_offset), cmd.csum_init, out);
            m_exp_tx.push_back(out);
            note_expected();
            if (cov != null)
                cov.sample_tx(pkt.data.size(), cmd.csum_enable, int'(cmd.csum_start),
                              int'(cmd.csum_offset), cmd.csum_init);
            `uvm_info(get_type_name(),
                $sformatf("expect tx frame of %0d bytes (%s)",
                          out.size(), cmd.convert2string()), UVM_HIGH)
        end
    endfunction

    virtual function void write_tx_out(axis_item t);
        byte unsigned exp [];

        if (!check_tx) return;
        note_actual();

        if (m_exp_tx.size() == 0) begin
            note_mismatch("unexpected tx_checksum output", "none",
                          $sformatf("%0d bytes", t.data.size()));
            return;
        end
        exp = m_exp_tx.pop_front();
        compare_bytes("tx_checksum frame", exp, t.data);
    endfunction

    // -------------------------------------------------------------------------
    virtual function void write_stim(axis_item t);
        bit [31:0] h;
        bit [3:0]  ht;

        if (check_csum) begin
            m_exp_csum.push_back(m_ref_csum.rx_expected(t.data));
            note_expected();
        end
        if (check_hash || cov != null)
            m_ref_hash.predict(t.data, h, ht);
        if (check_hash) begin
            m_exp_hash.push_back(h);
            m_exp_htyp.push_back(ht);
            note_expected();
        end
        if (cov != null) cov.sample_rx(t.data, ht);

        `uvm_info(get_type_name(),
            $sformatf("stimulus %0d bytes -> expect csum=0x%04h hash=0x%08h type=0x%01h",
                      t.data.size(),
                      check_csum ? m_exp_csum[$] : 16'h0, h, ht), UVM_HIGH)

        // Pair any results that were already waiting for this packet.
        while (m_early_csum.size() > 0 && m_exp_csum.size() > 0)
            compare_csum(m_exp_csum.pop_front(), m_early_csum.pop_front());
        while (m_early_hash.size() > 0 && m_exp_hash.size() > 0)
            compare_hash(m_exp_hash.pop_front(), m_exp_htyp.pop_front(),
                         m_early_hash.pop_front(), m_early_htyp.pop_front());
    endfunction

    protected function void compare_csum(bit [15:0] exp, bit [15:0] act);
        if (exp !== act)
            note_mismatch("rx_checksum", $sformatf("0x%04h", exp), $sformatf("0x%04h", act));
        else
            note_match($sformatf("rx_checksum 0x%04h", act));
    endfunction

    protected function void compare_hash(bit [31:0] exp_h, bit [3:0] exp_t,
                                         bit [31:0] act_h, bit [3:0] act_t);
        if (exp_h !== act_h || exp_t !== act_t)
            note_mismatch("rx_hash",
                          $sformatf("hash=0x%08h type=0x%01h", exp_h, exp_t),
                          $sformatf("hash=0x%08h type=0x%01h", act_h, act_t));
        else
            note_match($sformatf("rx_hash 0x%08h type 0x%01h", act_h, act_t));
    endfunction

    // -------------------------------------------------------------------------
    // The result monitors publish the raw output bytes; the checksum arrives as
    // two bytes, high byte first.
    // -------------------------------------------------------------------------
    virtual function void write_csum(axis_item t);
        bit [15:0] act;
        bit [15:0] exp;

        note_actual();
        if (t.data.size() < 2) begin
            note_mismatch("checksum result too short", "2 bytes",
                          $sformatf("%0d bytes", t.data.size()));
            return;
        end
        act = {t.data[1], t.data[0]};       // tdata[15:0], little-endian on the bus

        if (m_exp_csum.size() == 0) begin
            m_early_csum.push_back(act);        // its packet has not been published yet
            return;
        end
        exp = m_exp_csum.pop_front();
        compare_csum(exp, act);
    endfunction

    // -------------------------------------------------------------------------
    virtual function void write_hash(axis_item t);
        bit [31:0] act_h;
        bit [3:0]  act_t;
        bit [31:0] exp_h;
        bit [3:0]  exp_t;

        note_actual();
        if (t.data.size() < 4) begin
            note_mismatch("hash result too short", "4 bytes",
                          $sformatf("%0d bytes", t.data.size()));
            return;
        end
        act_h = {t.data[3], t.data[2], t.data[1], t.data[0]};
        act_t = t.user[3:0];

        if (m_exp_hash.size() == 0) begin
            m_early_hash.push_back(act_h);      // its packet has not been published yet
            m_early_htyp.push_back(act_t);
            return;
        end
        exp_h = m_exp_hash.pop_front();
        exp_t = m_exp_htyp.pop_front();
        compare_hash(exp_h, exp_t, act_h, act_t);
    endfunction

endclass : sb_offload

`endif // SB_OFFLOAD_SV

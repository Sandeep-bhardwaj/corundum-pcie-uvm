// SPDX-License-Identifier: BSD-2-Clause-Views
//
// mqnic_base_seq / mqnic_base_vseq
// -----------------------------------------------------------------------------
// Sequence base classes.
//
// Implements : VERIFICATION_STRATEGY.md  §12.1 (sequence layering)
// Introduced : Step 0 (infrastructure)
//
// Layering (STRATEGY §12.1):
//   Level 3  virtual sequences   -> extend mqnic_base_vseq
//   Level 2  driver model seqs   -> extend mqnic_base_vseq
//   Level 1  RAL access seqs     -> extend mqnic_base_vseq
//   Level 0  UVC item sequences  -> extend mqnic_base_seq #(item_type)
//
// Both bases handle phase objections through get_starting_phase(), which is
// available in UVM 1.2 and IEEE 1800.2 alike. Sequences started as the phase's
// default sequence therefore keep the test alive automatically; sequences
// started manually from a task do nothing extra.
// -----------------------------------------------------------------------------

`ifndef MQNIC_BASE_SEQ_SV
`define MQNIC_BASE_SEQ_SV

// -----------------------------------------------------------------------------
// Level 0 - item-generating sequences, parameterized on the UVC item type.
// -----------------------------------------------------------------------------
virtual class mqnic_base_seq #(type REQ = uvm_sequence_item,
                               type RSP = REQ)
    extends uvm_sequence #(REQ, RSP);

    // Set by a test to make a long-running sequence stop cleanly at the next
    // convenient point rather than being killed mid-transaction.
    protected bit m_stop_requested;

    function new(string name = "mqnic_base_seq");
        super.new(name);
        m_stop_requested = 1'b0;
    endfunction

    virtual function void request_stop();
        m_stop_requested = 1'b1;
    endfunction

    virtual function bit stop_requested();
        return m_stop_requested;
    endfunction

    virtual task pre_body();
        uvm_phase p = get_starting_phase();
        if (p != null)
            p.raise_objection(this, $sformatf("%s started", get_type_name()));
    endtask

    virtual task post_body();
        uvm_phase p = get_starting_phase();
        if (p != null)
            p.drop_objection(this, $sformatf("%s finished", get_type_name()));
    endtask

endclass : mqnic_base_seq


// -----------------------------------------------------------------------------
// Levels 1-3 - virtual sequences. These do not generate items themselves; they
// start other sequences on the sequencers reachable through the virtual
// sequencer handle held by the environment.
// -----------------------------------------------------------------------------
virtual class mqnic_base_vseq extends uvm_sequence #(uvm_sequence_item);

    protected bit m_stop_requested;

    function new(string name = "mqnic_base_vseq");
        super.new(name);
        m_stop_requested = 1'b0;
    endfunction

    virtual function void request_stop();
        m_stop_requested = 1'b1;
    endfunction

    virtual function bit stop_requested();
        return m_stop_requested;
    endfunction

    virtual task pre_body();
        uvm_phase p = get_starting_phase();
        if (p != null)
            p.raise_objection(this, $sformatf("%s started", get_type_name()));
    endtask

    virtual task post_body();
        uvm_phase p = get_starting_phase();
        if (p != null)
            p.drop_objection(this, $sformatf("%s finished", get_type_name()));
    endtask

endclass : mqnic_base_vseq

`endif // MQNIC_BASE_SEQ_SV

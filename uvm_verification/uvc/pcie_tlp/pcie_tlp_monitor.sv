// SPDX-License-Identifier: BSD-2-Clause-Views
//
// pcie_tlp_monitor - generic TLP monitor
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.2, §4.3 rule 2
// Introduced : Step 2 (Tier 1b); reused at Tiers 3, 4, 5
//
// Reassembles beats into whole TLPs and publishes one item per TLP.
//
// The header and sidebands are captured from the SOP beat and must NOT be
// re-read on later beats: the RTL only presents them on sop, and later beats
// carry stale or zeroed values. Capturing them on eop instead is the classic
// way to get a monitor that works for single-beat TLPs and silently corrupts
// every multi-beat one.
// -----------------------------------------------------------------------------

`ifndef PCIE_TLP_MONITOR_SV
`define PCIE_TLP_MONITOR_SV

class pcie_tlp_monitor extends uvm_monitor;

    `uvm_component_utils(pcie_tlp_monitor)

    virtual pcie_tlp_if vif;
    pcie_tlp_cfg        cfg;

    uvm_analysis_port #(pcie_tlp_item) ap;

    // Identifies which port this monitor watches, for multi-port DUTs.
    int port_id = 0;

    protected byte unsigned m_bytes [$];
    protected bit [127:0]   m_hdr;
    protected bit [2:0]     m_bar_id;
    protected bit [7:0]     m_func_num;
    protected bit [3:0]     m_error;
    protected bit [5:0]     m_seq;
    protected bit           m_in_pkt;
    protected time          m_start;
    protected int unsigned  m_n_tlp;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual pcie_tlp_if)::get(this, "", "vif", vif))
            `uvm_fatal(get_type_name(), "no pcie_tlp_if in config_db under key 'vif'")
        if (!uvm_config_db #(pcie_tlp_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "no pcie_tlp_cfg in config_db under key 'cfg'")
        void'(uvm_config_db #(int)::get(this, "", "port_id", port_id));
    endfunction

    virtual task run_phase(uvm_phase phase);
        forever begin
            fork
                collect();
                @(posedge vif.rst);
            join_any
            disable fork;

            if (m_in_pkt) begin
                `uvm_info(get_type_name(),
                    $sformatf("reset discarded a partial TLP (%0d bytes)",
                              m_bytes.size()), UVM_MEDIUM)
                m_bytes.delete();
                m_in_pkt = 1'b0;
            end
            while (vif.rst === 1'b1) @(vif.mon_cb);
        end
    endtask

    // -------------------------------------------------------------------------
    // PER SEGMENT, NOT PER BEAT.
    //
    // The first version keyed on tlp_sop[0] and tlp_eop[0] alone. That is
    // correct for TLP_SEG_COUNT = 1 and it SILENTLY DROPS every TLP presented on
    // a higher segment when the count is greater - the monitor would see half
    // the traffic and report the other half as matching, which is the Tier 2
    // failure mode one tier up.
    //
    // Every tier currently runs at 1 segment, including Tier 4a since the
    // rtl_patched/ fix for bug 13. This was written when Tier 4a was forced to
    // 2 and is kept because the capability is real, is needed by any future
    // multi-segment configuration, and costs nothing at a count of 1.
    //
    // Each segment owns a contiguous slice of the strobe lanes,
    // seg_strb_width() wide, and carries its own header, sidebands and framing
    // bits. Segment index from lane is lane / seg_strb_width - the same mapping
    // the RTL uses (pcie_us_if_rc.v:308-320).
    //
    // Only ONE TLP is ever open at a time: the segments form a single ordered
    // stream, not independent channels. That is what distinguishes this from
    // dma_ram_if, where the segments really are independent and the UVC has to
    // model them as such.
    // -------------------------------------------------------------------------
    protected virtual task collect();
        int unsigned n_seg;
        int unsigned seg_lanes;

        n_seg     = cfg.seg_count;
        seg_lanes = cfg.seg_strb_width();

        forever begin
            @(vif.mon_cb);
            if (!(|vif.mon_cb.tlp_valid) || vif.mon_cb.tlp_ready !== 1'b1) continue;

            for (int s = 0; s < int'(n_seg); s++) begin
                if (vif.mon_cb.tlp_valid[s] !== 1'b1) continue;

                if (vif.mon_cb.tlp_sop[s] === 1'b1) begin
                    if (m_in_pkt)
                        `uvm_error(get_type_name(),
                            $sformatf({"sop on segment %0d while a TLP is already ",
                                       "open - framing violation"}, s))
                    m_bytes.delete();
                    m_in_pkt = 1'b1;
                    m_start  = $time;
                    // Captured ONCE, on sop, from THIS segment's slice.
                    m_hdr      = vif.mon_cb.tlp_hdr[s*128 +: 128];
                    m_bar_id   = cfg.has_bar_id   ? vif.mon_cb.tlp_bar_id[s*3 +: 3]   : '0;
                    m_func_num = cfg.has_func_num ? vif.mon_cb.tlp_func_num[s*8 +: 8] : '0;
                    m_error    = cfg.has_error    ? vif.mon_cb.tlp_error[s*4 +: 4]    : '0;
                    m_seq      = cfg.has_seq      ? vif.mon_cb.tlp_seq[s*6 +: 6]      : '0;
                end
                else if (!m_in_pkt) begin
                    `uvm_error(get_type_name(),
                        $sformatf({"valid segment %0d with no preceding sop - ",
                                   "framing violation"}, s))
                    continue;
                end

                // One strobe bit per DWORD, over this segment's lanes only.
                for (int w = 0; w < int'(seg_lanes); w++) begin
                    int unsigned lane = s * seg_lanes + w;
                    if (vif.mon_cb.tlp_strb[lane] === 1'b1)
                        for (int b = 0; b < 4; b++)
                            m_bytes.push_back(vif.mon_cb.tlp_data[(lane*4 + b)*8 +: 8]);
                end

                if (vif.mon_cb.tlp_eop[s] === 1'b1) publish();
            end
        end
    endtask

    protected virtual function void publish();
        pcie_tlp_item it = pcie_tlp_item::type_id::create("tlp");
        it.hdr      = m_hdr;
        it.payload  = new[m_bytes.size()];
        foreach (m_bytes[i]) it.payload[i] = m_bytes[i];
        it.bar_id   = m_bar_id;
        it.func_num = m_func_num;
        it.error    = m_error;
        it.seq      = m_seq;
        it.src_port = port_id;
        it.start_time = m_start;
        it.end_time   = $time;

        m_bytes.delete();
        m_in_pkt = 1'b0;
        m_n_tlp++;

        `uvm_info(get_type_name(),
            $sformatf("port %0d observed %s", port_id, it.convert2string()), UVM_HIGH)
        ap.write(it);
    endfunction

    virtual function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        if (m_in_pkt)
            `uvm_error(get_type_name(),
                "a TLP was still open at end of test (sop with no eop)")
    endfunction

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf("port %0d observed %0d TLP(s)", port_id, m_n_tlp), UVM_LOW)
    endfunction

endclass : pcie_tlp_monitor

`endif // PCIE_TLP_MONITOR_SV

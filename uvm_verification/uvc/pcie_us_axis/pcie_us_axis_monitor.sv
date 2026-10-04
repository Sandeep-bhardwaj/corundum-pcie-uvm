// SPDX-License-Identifier: BSD-2-Clause-Views
//
// pcie_us_axis_monitor - reassembles TLPs from a possibly-straddling stream
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.6, §4.3 rule 2, §22 R2
// Introduced : Step 6 (Tier 4)
//
// THE HARDEST MONITOR IN THE ENVIRONMENT, and the reason is straddling: a beat
// can end one TLP and begin another, so "wait for tlast" reassembles garbage on
// an RC channel. The framing has to be read out of tuser, per lane, every beat.
//
// It works in LANES, not beats. Each accepted beat is walked lane by lane; a
// lane that carries a start opens a TLP, a lane that carries an end closes one.
// That is the same shape as the generic pcie_tlp_monitor but driven from tuser
// rather than from sop/eop wires, and it is the only structure that handles two
// TLPs in one beat without special cases.
//
// ALL BIT POSITIONS COME FROM THE CODEC. Nothing in this file knows where
// is_eop_ptr lives - that is in mqnic_vrf_pkg, cross-checked against the RTL
// over 308 framing cases. §22 R2 is about exactly this, and the mitigation is
// to have one definition rather than one per consumer.
// -----------------------------------------------------------------------------

`ifndef PCIE_US_AXIS_MONITOR_SV
`define PCIE_US_AXIS_MONITOR_SV

class pcie_us_axis_monitor extends uvm_monitor;

    `uvm_component_utils(pcie_us_axis_monitor)

    virtual pcie_us_axis_if vif;
    pcie_us_axis_cfg        cfg;

    uvm_analysis_port #(pcie_us_axis_item) ap;

    // The TLP currently open, if any.
    protected bit [31:0]   m_dw [$];
    protected bit          m_open;
    protected time         m_start;
    protected bit          m_straddled_this;
    protected int unsigned m_start_lane;
    // tuser as it was on the beat the TLP STARTED. Byte enables and the RQ
    // sequence number are first-beat fields (PG156); pcie_us_if_rq recomputes
    // tuser every beat and drives them as 0 after the first
    // (pcie_us_if_rq.v:742, :853). Reading them at end-of-packet, as this
    // monitor did, turned every multi-beat DMA write into a 1-DWORD write -
    // found by the first end-to-end RX packet, which reached host memory as
    // four correct bytes and 96 zeros.
    protected bit [183:0]  m_sop_user;

    protected int unsigned m_n_tlp;
    protected int unsigned m_n_straddled;
    protected int unsigned m_n_beats;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual pcie_us_axis_if)::get(this, "", "vif", vif))
            `uvm_fatal(get_type_name(), "no pcie_us_axis_if in config_db under key vif")
        if (!uvm_config_db #(pcie_us_axis_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "no pcie_us_axis_cfg in config_db under key cfg")
    endfunction

    virtual task run_phase(uvm_phase phase);
        forever begin
            fork
                collect();
                @(posedge vif.rst);
            join_any
            disable fork;
            if (m_open)
                `uvm_info(get_type_name(),
                    "reset discarded a partially received TLP", UVM_MEDIUM)
            m_dw.delete();
            m_open = 1'b0;
            while (vif.rst === 1'b1) @(vif.mon_cb);
        end
    endtask

    // -------------------------------------------------------------------------
    protected virtual task collect();
        int unsigned lanes = cfg.keep_width();
        bit [15:0]   sop_lanes;
        bit [15:0]   eop_lanes;

        forever begin
            @(vif.mon_cb);
            if (vif.mon_cb.tvalid !== 1'b1 || vif.mon_cb.tready !== 1'b1) continue;
            m_n_beats++;

            decode_framing(sop_lanes, eop_lanes);

            for (int lane = 0; lane < int'(lanes); lane++) begin
                if (sop_lanes[lane]) begin
                    if (m_open) begin
                        // Legal on a straddling channel only if the previous
                        // TLP ended in this same beat - which the eop pass
                        // below would have closed. Reaching here means it did
                        // not, so the stream is malformed.
                        `uvm_error(get_type_name(),
                            $sformatf({"start of a TLP at lane %0d while another ",
                                       "is still open - framing violation"}, lane))
                        m_dw.delete();
                    end
                    m_open           = 1'b1;
                    m_start          = $time;
                    m_straddled_this = (lane != 0);
                    m_start_lane     = lane;
                    m_sop_user       = 184'(vif.mon_cb.tuser);
                    m_dw.delete();
                end

                if (m_open && vif.mon_cb.tkeep[lane] === 1'b1)
                    m_dw.push_back(vif.mon_cb.tdata[lane*32 +: 32]);

                if (eop_lanes[lane] && m_open) publish();
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Framing, entirely from the codec. On a non-straddling channel there is no
    // tuser framing at all - the ordinary AXI-S rules apply and tlast is what
    // ends a packet.
    // -------------------------------------------------------------------------
    protected virtual function void decode_framing(output bit [15:0] sop_lanes,
                                                   output bit [15:0] eop_lanes);
        int unsigned lanes = cfg.keep_width();
        bit [183:0]  u     = 184'(vif.mon_cb.tuser);

        sop_lanes = '0;
        eop_lanes = '0;

        if (!cfg.straddles()) begin
            if (!m_open) sop_lanes[0] = 1'b1;
            if (vif.mon_cb.tlast === 1'b1) begin
                // The last asserted keep lane carries the end.
                for (int l = int'(lanes) - 1; l >= 0; l--)
                    if (vif.mon_cb.tkeep[l] === 1'b1) begin
                        eop_lanes[l] = 1'b1;
                        break;
                    end
            end
            return;
        end

        // CC AND RQ STRADDLE WITH A DIFFERENT tuser LAYOUT.
        //
        // The decode below implements the RC/CQ shape (is_sop at [64+seg] or
        // [80+seg], with a separate pointer field). CC packs it as
        // [1:0] is_sop / [3:2] is_sop0_ptr / [7:6] is_eop / [11:8] is_eop0_ptr
        // (pcie_us_if_cc.v:484-520), and RQ differently again.
        //
        // Applying the wrong layout would not fail - it would silently
        // reassemble the wrong bytes, which is precisely the §22 R2 failure
        // mode. Refusing is the only honest option until the layout is
        // transcribed and cross-checked like the others.
        //
        // NOT CURRENTLY REACHABLE. At the golden 256-bit width CC_STRADDLE and
        // RQ_STRADDLE are both false (mqnic_core_pcie_us.v:164-166), and the
        // rtl_patched/ fix is what lets Tier 4b run at 256 rather than being
        // forced to 512. The guard stays because a future 512-bit tier would
        // reach it, and because it records why the transcription is missing
        // rather than leaving a silent gap.
        if (cfg.straddles() &&
            (cfg.channel == PCIE_CH_CC || cfg.channel == PCIE_CH_RQ))
            `uvm_fatal(get_type_name(),
                $sformatf({"straddle decode for %s is not implemented - the ",
                           "RC/CQ tuser layout does not apply. See the note here."},
                          cfg.channel.name()))

        // Straddling: RC is the only channel that does this at 256 bits.
        if (cfg.data_width == 256) begin
            // Addressed BY LANE: bit 32 is lane 0, bit 33 is lane 4. When a
            // frame is already open, bit 32 means the NEXT slot instead - the
            // RTL's own rule (pcie_us_if_rc.v:278-286).
            if (u[32]) sop_lanes[m_open ? 4 : 0] = 1'b1;
            if (u[33]) sop_lanes[4]              = 1'b1;
            for (int seg = 0; seg < 2; seg++)
                if (u[34 + seg*4])
                    eop_lanes[u[35 + seg*4 +: 3]] = 1'b1;
        end
        else begin
            for (int seg = 0; seg < 4; seg++) begin
                if (u[64 + seg])
                    sop_lanes[u[68 + seg*2 +: 2] * mqnic_vrf_pkg::US_STRADDLE_LANE_STEP] = 1'b1;
                if (u[76 + seg])
                    eop_lanes[u[80 + seg*4 +: 4]] = 1'b1;
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    protected virtual function void publish();
        pcie_us_axis_item it = pcie_us_axis_item::type_id::create("tlp");
        bit [183:0] u   = 184'(vif.mon_cb.tuser);   // last beat: discontinue
        bit [183:0] u0  = m_sop_user;                // first beat: BEs, seq_num

        it.dwords = new[m_dw.size()];
        foreach (m_dw[i]) it.dwords[i] = m_dw[i];

        it.straddled  = m_straddled_this;
        // Coverage needs WHERE it started; without this every TLP read as
        // lane 0 and the slot-1 straddle bins could never be hit.
        it.start_lane = m_start_lane;
        it.start_time = m_start;
        it.end_time   = $time;

        // Fields the DUT drives, read through the codec.
        case (cfg.channel)
            PCIE_CH_RQ: begin
                it.first_be    = mqnic_vrf_pkg::us_rq_first_be(u0, cfg.user_width());
                it.last_be     = mqnic_vrf_pkg::us_rq_last_be(u0, cfg.user_width());
                it.seq_num     = 6'(mqnic_vrf_pkg::us_rq_seq_num(u0, cfg.user_width()));
                it.discontinue = mqnic_vrf_pkg::us_rq_discontinue(u, cfg.user_width());
            end
            PCIE_CH_CC: begin
                it.discontinue = mqnic_vrf_pkg::us_cc_discontinue(u, cfg.user_width());
            end
            PCIE_CH_CQ: begin
                // The byte enables travel in tuser, not in the descriptor, so
                // they have to be recovered here even though the TB drove them
                // - the scoreboard is fed by the monitor, not by the sequence.
                it.first_be = mqnic_vrf_pkg::us_cq_first_be(u0, cfg.data_width,
                                                            cfg.straddles());
                it.last_be  = mqnic_vrf_pkg::us_cq_last_be(u0, cfg.data_width,
                                                           cfg.straddles());
            end
            default: ;
        endcase

        m_dw.delete();
        m_open = 1'b0;
        m_n_tlp++;
        if (it.straddled) m_n_straddled++;

        `uvm_info(get_type_name(), it.convert2string(), UVM_HIGH)
        ap.write(it);
    endfunction

    // -------------------------------------------------------------------------
    virtual function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        if (m_open)
            `uvm_error(get_type_name(),
                $sformatf({"a TLP was still open at end of test: %0d DWORD(s) ",
                           "received with no end-of-packet"}, m_dw.size()))
    endfunction

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf("channel %s: %0d beat(s), %0d TLP(s), %0d straddled",
                      cfg.channel.name(), m_n_beats, m_n_tlp, m_n_straddled),
            UVM_LOW)
        if (cfg.straddles() && m_n_tlp > 0 && m_n_straddled == 0)
            `uvm_info(get_type_name(),
                {"channel supports straddling but none was observed - ",
                 "§14.4 coverage will be short"}, UVM_LOW)
    endfunction

endclass : pcie_us_axis_monitor

`endif // PCIE_US_AXIS_MONITOR_SV

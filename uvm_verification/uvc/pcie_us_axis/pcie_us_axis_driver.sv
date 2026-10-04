// SPDX-License-Identifier: BSD-2-Clause-Views
//
// pcie_us_axis_driver / pcie_us_axis_sink_driver
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.6, §22 R2
// Introduced : Step 6 (Tier 4)
//
// The source driver is where straddling actually gets generated, and it is the
// only place in the environment that has to BUILD a tuser field rather than
// read one. Everything it needs comes from the validated codec in
// mqnic_vrf_pkg - no bit positions appear in this file.
//
// STRADDLING IS OPT-IN PER BEAT, not per test. A driver that straddles whenever
// it can produces one pattern; a driver that never does produces another; and
// §14.4 asks for the CROSS of straddle mode against sop and eop position. So
// the decision is made per TLP pair, and pcie_us_axis_cfg carries no straddle
// probability - the sequence decides, because the sequence is what a test can
// aim.
//
// SEQUENCE COMPLETION IS NOT TRAFFIC COMPLETION - the Tier 2 lesson. This
// driver buffers a TLP when it is holding one back to straddle it with the
// next, so pending_items() reports that and the agent's is_idle() consults it.
// -----------------------------------------------------------------------------

`ifndef PCIE_US_AXIS_DRIVER_SV
`define PCIE_US_AXIS_DRIVER_SV

class pcie_us_axis_driver extends uvm_driver #(pcie_us_axis_item);

    `uvm_component_utils(pcie_us_axis_driver)

    virtual pcie_us_axis_if vif;
    pcie_us_axis_cfg        cfg;

    // A TLP held back so it can share a beat with the next one.
    protected pcie_us_axis_item m_held;

    protected int unsigned m_n_tlp;
    protected int unsigned m_n_straddled;
    protected int unsigned m_idle_cycles;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual pcie_us_axis_if)::get(this, "", "vif", vif))
            `uvm_fatal(get_type_name(), "no pcie_us_axis_if in config_db under key vif")
        if (!uvm_config_db #(pcie_us_axis_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "no pcie_us_axis_cfg in config_db under key cfg")
        if (!cfg.tb_is_source())
            `uvm_fatal(get_type_name(),
                $sformatf({"channel %s flows DUT -> host; the testbench must SINK it. ",
                           "Use MODE_ACTIVE_SLAVE."}, cfg.channel.name()))
    endfunction

    virtual function int unsigned pending_items();
        return (m_held == null) ? 0 : 1;
    endfunction

    virtual task run_phase(uvm_phase phase);
        vif.init_idle_source();
        forever begin
            @(vif.src_cb);
            if (vif.rst === 1'b1) begin
                vif.init_idle_source();
                m_held        = null;
                m_idle_cycles = 0;
                while (vif.rst === 1'b1) @(vif.src_cb);
                continue;
            end
            // try_next_item, NOT get_next_item.
            //
            // This driver holds a TLP back so it can straddle it with the next
            // one. get_next_item BLOCKS, so at the end of a burst the held TLP
            // waits for a partner that never comes: it is never driven, and
            // pending_items() never returns to zero, so the test never drains.
            // That is exactly what happened - four rounds of
            // t4a_random_stress timed out with both scoreboards empty, and two
            // TLPs went missing between the driver and the monitor.
            //
            // try_next_item lets the driver notice that the sequencer has gone
            // quiet and FLUSH the held TLP on its own.
            seq_item_port.try_next_item(req);
            if (req == null) begin
                // Give the partner a chance to arrive before giving up. An
                // immediate flush here is correct for drain and WRONG for
                // straddling - see cfg.straddle_hold_cycles.
                if (m_held != null) begin
                    m_idle_cycles++;
                    if (m_idle_cycles > cfg.straddle_hold_cycles) flush_held();
                end
                continue;
            end
            m_idle_cycles = 0;
            handle(req);
            seq_item_port.item_done();
        end
    endtask

    // Send a held TLP alone. Called when no partner is forthcoming, and at
    // end-of-test so nothing is left un-driven.
    protected virtual task flush_held();
        pcie_us_axis_item h;
        if (m_held == null) return;
        h      = m_held;
        m_held = null;          // cleared FIRST: send_one blocks, and
        send_one(h);            // pending_items() must not double-count.
    endtask

    // -------------------------------------------------------------------------
    // A TLP that ends part-way through a beat CAN be straddled with the next
    // one, if the channel allows it and the next TLP would start on a legal
    // 128-bit boundary. Holding it back is how that pairing is created.
    // -------------------------------------------------------------------------
    protected virtual task handle(pcie_us_axis_item it);
        if (m_held != null) begin
            send_pair(m_held, it);
            m_held = null;
        end
        else if (cfg.straddles() && it.start_lane == 0 && can_straddle(it)) begin
            m_held = it;      // wait for a partner
        end
        else begin
            send_one(it);
        end
    endtask

    // Room for another TLP to start in the same beat: this one must end before
    // the last straddle slot.
    protected virtual function bit can_straddle(pcie_us_axis_item it);
        int unsigned lanes = cfg.keep_width();
        int unsigned end_lane = (it.dwords.size() - 1) % lanes;
        return (end_lane + mqnic_vrf_pkg::US_STRADDLE_LANE_STEP) < lanes;
    endfunction

    // -------------------------------------------------------------------------
    protected virtual task send_one(pcie_us_axis_item it);
        int unsigned lanes = cfg.keep_width();
        int unsigned n     = it.dwords.size();
        int unsigned sent  = 0;
        bit [15:0]   sop_lanes;
        bit [15:0]   eop_lanes;

        repeat (it.delay) @(vif.src_cb);
        it.start_time = $time;

        while (sent < n) begin
            int unsigned this_beat = (n - sent > lanes) ? lanes : (n - sent);

            vif.src_cb.tdata <= '0;
            vif.src_cb.tkeep <= '0;
            for (int l = 0; l < int'(this_beat); l++) begin
                vif.src_cb.tdata[l*32 +: 32] <= it.dwords[sent + l];
                vif.src_cb.tkeep[l]          <= 1'b1;
            end

            sop_lanes = (sent == 0) ? 16'd1 : 16'd0;
            eop_lanes = (sent + this_beat >= n) ? (16'd1 << (this_beat - 1)) : 16'd0;

            vif.src_cb.tuser  <= build_tuser(it, null, sop_lanes, eop_lanes);
            vif.src_cb.tlast  <= (sent + this_beat >= n);
            vif.src_cb.tvalid <= 1'b1;

            do @(vif.src_cb); while (vif.src_cb.tready !== 1'b1);
            sent += this_beat;
        end

        vif.src_cb.tvalid <= 1'b0;
        vif.src_cb.tlast  <= 1'b0;
        it.end_time = $time;
        m_n_tlp++;
        `uvm_info(get_type_name(), it.convert2string(), UVM_HIGH)
    endtask

    // -------------------------------------------------------------------------
    // Two TLPs sharing one beat. Only reachable on a straddling channel, and
    // the second must begin on a 128-bit boundary.
    // -------------------------------------------------------------------------
    protected virtual task send_pair(pcie_us_axis_item a, pcie_us_axis_item b);
        int unsigned lanes = cfg.keep_width();
        int unsigned step  = mqnic_vrf_pkg::US_STRADDLE_LANE_STEP;
        int unsigned a_end = a.dwords.size() - 1;
        int unsigned b_off = ((a_end / step) + 1) * step;     // next legal slot
        bit [15:0]   sop_lanes;
        bit [15:0]   eop_lanes;
        int unsigned b_sent;

        if (b_off >= lanes) begin      // no room after all
            send_one(a);
            send_one(b);
            return;
        end

        repeat (a.delay) @(vif.src_cb);
        a.start_time = $time;
        b.start_time = $time;

        // ---- the shared beat -------------------------------------------------
        vif.src_cb.tdata <= '0;
        vif.src_cb.tkeep <= '0;
        for (int l = 0; l <= int'(a_end); l++) begin
            vif.src_cb.tdata[l*32 +: 32] <= a.dwords[l];
            vif.src_cb.tkeep[l]          <= 1'b1;
        end

        b_sent = 0;
        while (b_off + b_sent < lanes && b_sent < b.dwords.size()) begin
            vif.src_cb.tdata[(b_off + b_sent)*32 +: 32] <= b.dwords[b_sent];
            vif.src_cb.tkeep[b_off + b_sent]            <= 1'b1;
            b_sent++;
        end

        sop_lanes = 16'd1 | (16'd1 << b_off);
        eop_lanes = 16'd1 << a_end;
        if (b_sent >= b.dwords.size())
            eop_lanes |= 16'd1 << (b_off + b_sent - 1);

        vif.src_cb.tuser  <= build_tuser(a, b, sop_lanes, eop_lanes);
        vif.src_cb.tlast  <= (b_sent >= b.dwords.size());
        vif.src_cb.tvalid <= 1'b1;

        do @(vif.src_cb); while (vif.src_cb.tready !== 1'b1);

        // Only b BEGINS mid-beat, and that is what the monitor can observe -
        // so that is what both sides count. Marking the pair (2 per straddle)
        // made the driver report 34 where the monitor reported 17, which looked
        // like lost traffic and was only a definitional mismatch.
        a.straddled = 1'b0;
        b.straddled = 1'b1;
        a.end_time  = $time;
        m_n_straddled++;

        // ---- b's remaining beats --------------------------------------------
        while (b_sent < b.dwords.size()) begin
            int unsigned rem = b.dwords.size() - b_sent;
            int unsigned this_beat = (rem > lanes) ? lanes : rem;

            vif.src_cb.tdata <= '0;
            vif.src_cb.tkeep <= '0;
            for (int l = 0; l < int'(this_beat); l++) begin
                vif.src_cb.tdata[l*32 +: 32] <= b.dwords[b_sent + l];
                vif.src_cb.tkeep[l]          <= 1'b1;
            end
            vif.src_cb.tuser  <= build_tuser(b, null, 16'd0,
                                             (rem <= lanes) ? (16'd1 << (this_beat-1)) : 16'd0);
            vif.src_cb.tlast  <= (rem <= lanes);
            vif.src_cb.tvalid <= 1'b1;
            do @(vif.src_cb); while (vif.src_cb.tready !== 1'b1);
            b_sent += this_beat;
        end

        vif.src_cb.tvalid <= 1'b0;
        vif.src_cb.tlast  <= 1'b0;
        b.end_time = $time;
        m_n_tlp += 2;
    endtask

    // -------------------------------------------------------------------------
    // ALL bit positions live in the codec, which is cross-checked against the
    // RTL. Nothing here knows where is_sop is.
    // -------------------------------------------------------------------------
    protected virtual function bit [mqnic_vrf_pkg::US_MAX_USER_WIDTH-1:0]
            build_tuser(pcie_us_axis_item a, pcie_us_axis_item b,
                        bit [15:0] sop_lanes, bit [15:0] eop_lanes);
        bit [183:0] u;

        case (cfg.channel)
            PCIE_CH_RC:
                u = mqnic_vrf_pkg::us_rc_tuser_encode(cfg.data_width,
                                                      sop_lanes, eop_lanes);
            PCIE_CH_CQ:
                u = mqnic_vrf_pkg::us_cq_tuser_encode(
                        cfg.data_width, cfg.straddles(),
                        a.first_be, a.last_be,
                        (b == null) ? 4'h0 : b.first_be,
                        (b == null) ? 4'h0 : b.last_be,
                        sop_lanes, eop_lanes);
            default:
                u = '0;
        endcase
        return u[mqnic_vrf_pkg::US_MAX_USER_WIDTH-1:0];
    endfunction

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf({"drove %0d TLP(s), %0d of which began mid-beat ",
                       "(i.e. %0d straddled pair(s))"},
                      m_n_tlp, m_n_straddled, m_n_straddled), UVM_LOW)
    endfunction

endclass : pcie_us_axis_driver


// -----------------------------------------------------------------------------
// pcie_us_axis_sink_driver - tready shaping for the DUT-driven channels.
// -----------------------------------------------------------------------------
class pcie_us_axis_sink_driver extends uvm_driver #(pcie_us_axis_item);

    `uvm_component_utils(pcie_us_axis_sink_driver)

    virtual pcie_us_axis_if vif;
    pcie_us_axis_cfg        cfg;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual pcie_us_axis_if)::get(this, "", "vif", vif))
            `uvm_fatal(get_type_name(), "no pcie_us_axis_if in config_db under key vif")
        if (!uvm_config_db #(pcie_us_axis_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "no pcie_us_axis_cfg in config_db under key cfg")
        if (cfg.tb_is_source())
            `uvm_fatal(get_type_name(),
                $sformatf({"channel %s flows host -> DUT; the testbench must DRIVE it. ",
                           "Use MODE_ACTIVE_MASTER."}, cfg.channel.name()))
    endfunction

    virtual task run_phase(uvm_phase phase);
        vif.init_idle_sink();
        forever begin
            @(vif.sink_cb);
            if (vif.rst === 1'b1) begin
                vif.sink_cb.tready <= 1'b0;
                continue;
            end
            case (cfg.bp_profile)
                BP_NONE: begin
                    vif.sink_cb.tready <= 1'b1;
                end
                BP_AGGRESSIVE: begin
                    vif.sink_cb.tready <= 1'b0;
                    repeat ($urandom_range(4, 12)) @(vif.sink_cb);
                    vif.sink_cb.tready <= 1'b1;
                    @(vif.sink_cb);
                end
                BP_BURSTY: begin
                    vif.sink_cb.tready <= 1'b1;
                    if ($urandom_range(0, 9) < 3) begin
                        vif.sink_cb.tready <= 1'b0;
                        repeat ($urandom_range(8, 20)) @(vif.sink_cb);
                    end
                end
                default: begin
                    vif.sink_cb.tready <= ($urandom_range(0, 3) != 0);
                end
            endcase
        end
    endtask

endclass : pcie_us_axis_sink_driver

`endif // PCIE_US_AXIS_DRIVER_SV

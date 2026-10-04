// SPDX-License-Identifier: BSD-2-Clause-Views
//
// axis_driver / axis_sink_driver - AXI4-Stream drivers
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.3
// Introduced : Step 3 (Tier 1c)
//
// axis_driver      MODE_ACTIVE_MASTER - sources packets onto the bus
// axis_sink_driver MODE_ACTIVE_SLAVE  - supplies tready backpressure only
//
// When cfg.has_tready is clear the source presents exactly one beat per clock
// and never waits, because the DUT has no way to say "not now"
// (rx_checksum.v / rx_hash.v). The sink driver is then unnecessary and does
// nothing.
// -----------------------------------------------------------------------------

`ifndef AXIS_DRIVER_SV
`define AXIS_DRIVER_SV

class axis_driver extends uvm_driver #(axis_item);

    `uvm_component_utils(axis_driver)

    protected realtime m_line_free = 0;   // when the line is next idle
    virtual axis_if vif;
    axis_cfg        cfg;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual axis_if)::get(this, "", "vif", vif))
            `uvm_fatal(get_type_name(), "no axis_if in config_db under key 'vif'")
        if (!uvm_config_db #(axis_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "no axis_cfg in config_db under key 'cfg'")
    endfunction

    virtual task run_phase(uvm_phase phase);
        drive_idle();
        forever begin
            @(vif.src_cb);
            if (vif.rst === 1'b1) begin
                drive_idle();
                while (vif.rst === 1'b1) @(vif.src_cb);
                continue;
            end
            seq_item_port.try_next_item(req);
            if (req == null) continue;
            drive_packet(req);
            seq_item_port.item_done();
        end
    endtask

    protected virtual task drive_idle();
        vif.src_cb.tdata  <= '0;
        vif.src_cb.tkeep  <= '0;
        vif.src_cb.tvalid <= 1'b0;
        vif.src_cb.tlast  <= 1'b0;
        vif.src_cb.tuser  <= '0;
        vif.src_cb.tid    <= '0;
        vif.src_cb.tdest  <= '0;
    endtask

    // -------------------------------------------------------------------------
    protected virtual task drive_packet(axis_item it);
        int unsigned bw;          // bytes per beat
        int unsigned n;           // total bytes
        int unsigned idx;
        int unsigned this_beat;
        bit [511:0]  d;
        bit [63:0]   k;
        bit          last;

        bw = cfg.keep_width();
        n  = it.data.size();
        it.start_time = $time;

        repeat (it.delay_start) @(vif.src_cb);

        if (n == 0) begin
            `uvm_warning(get_type_name(), "zero-length packet ignored")
            return;
        end

        idx = 0;
        while (idx < n) begin
            this_beat = (n - idx > bw) ? bw : (n - idx);
            last      = (idx + this_beat >= n);

            // Line-rate pacing: wait (valid low) until the line has carried
            // everything before this beat.
            if (cfg.line_rate_gbps > 0.0) begin
                if (m_line_free < $realtime) m_line_free = $realtime;
                while ($realtime + 0.001ns < m_line_free) begin
                    vif.src_cb.tvalid <= 1'b0;
                    @(vif.src_cb);
                end
                m_line_free += (this_beat * 8.0 / cfg.line_rate_gbps) * 1ns;
            end

            d = '0;
            k = '0;
            for (int b = 0; b < int'(this_beat); b++) begin
                d[b*8 +: 8] = it.data[idx + b];
                k[b]        = 1'b1;
            end

            vif.src_cb.tdata  <= d;
            vif.src_cb.tkeep  <= cfg.has_tkeep ? k : '1;
            vif.src_cb.tvalid <= 1'b1;
            vif.src_cb.tlast  <= cfg.has_tlast ? last : 1'b0;
            vif.src_cb.tuser  <= last ? it.user : '0;
            vif.src_cb.tid    <= it.id;
            vif.src_cb.tdest  <= it.dest;

            if (cfg.has_tready) begin
                do @(vif.src_cb); while (vif.src_cb.tready !== 1'b1);
            end
            else begin
                // No handshake: the DUT must consume one beat per clock.
                @(vif.src_cb);
            end

            idx += this_beat;

            // Optional bubble between beats.
            if (!last && it.gap_pct > 0 && $urandom_range(1, 100) <= int'(it.gap_pct)) begin
                vif.src_cb.tvalid <= 1'b0;
                repeat ($urandom_range(1, 3)) @(vif.src_cb);
            end
        end

        vif.src_cb.tvalid <= 1'b0;
        vif.src_cb.tlast  <= 1'b0;
        it.end_time = $time;
        if (cfg.line_rate_gbps > 0.0)
            m_line_free += (cfg.ifg_bytes * 8.0 / cfg.line_rate_gbps) * 1ns;

        `uvm_info(get_type_name(),
            $sformatf("drove %0d-byte packet", n), UVM_HIGH)
    endtask

endclass : axis_driver


// -----------------------------------------------------------------------------
class axis_sink_driver extends uvm_driver #(axis_item);

    `uvm_component_utils(axis_sink_driver)

    virtual axis_if vif;
    axis_cfg        cfg;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual axis_if)::get(this, "", "vif", vif))
            `uvm_fatal(get_type_name(), "no axis_if in config_db under key 'vif'")
        if (!uvm_config_db #(axis_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "no axis_cfg in config_db under key 'cfg'")
    endfunction

    virtual task run_phase(uvm_phase phase);
        if (!cfg.has_tready) begin
            `uvm_info(get_type_name(),
                "interface has no tready; sink driver idle by design", UVM_MEDIUM)
            return;
        end
        vif.sink_cb.tready <= 1'b0;
        forever begin
            case (cfg.bp_profile)
                BP_NONE: begin
                    vif.sink_cb.tready <= 1'b1;
                    @(vif.sink_cb);
                end
                BP_AGGRESSIVE: begin
                    vif.sink_cb.tready <= 1'b0;
                    repeat ($urandom_range(4, 12)) @(vif.sink_cb);
                    vif.sink_cb.tready <= 1'b1;
                    @(vif.sink_cb);
                end
                BP_BURSTY: begin
                    vif.sink_cb.tready <= 1'b1;
                    repeat ($urandom_range(8, 20)) @(vif.sink_cb);
                    vif.sink_cb.tready <= 1'b0;
                    repeat ($urandom_range(8, 20)) @(vif.sink_cb);
                end
                default: begin
                    vif.sink_cb.tready <= 1'b0;
                    repeat ($urandom_range(0, 3)) @(vif.sink_cb);
                    vif.sink_cb.tready <= 1'b1;
                    @(vif.sink_cb);
                end
            endcase
        end
    endtask

endclass : axis_sink_driver

`endif // AXIS_DRIVER_SV

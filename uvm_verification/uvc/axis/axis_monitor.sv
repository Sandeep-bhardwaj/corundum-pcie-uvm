// SPDX-License-Identifier: BSD-2-Clause-Views
//
// axis_monitor - AXI4-Stream monitor
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.3, §4.3 rule 2
// Introduced : Step 3 (Tier 1c)
//
// Reassembles beats into packets and publishes one item per packet.
//
// The qualifying condition is tvalid && (!has_tready || tready). With
// cfg.has_tready clear - rx_checksum, rx_hash - the DUT has no tready at all and
// every tvalid cycle carries a beat. A monitor hard-coded to wait for a
// handshake would observe nothing and the tests would pass while checking
// nothing, which is the failure mode STRATEGY §7.8 warns about for the
// queue_manager doorbell.
//
// When has_tlast is clear the stream has no packet boundary, so beats are
// published individually; that is how the offload result channels are handled.
// -----------------------------------------------------------------------------

`ifndef AXIS_MONITOR_SV
`define AXIS_MONITOR_SV

class axis_monitor extends uvm_monitor;

    `uvm_component_utils(axis_monitor)

    virtual axis_if vif;
    axis_cfg        cfg;

    uvm_analysis_port #(axis_item) ap;

    protected byte unsigned m_bytes [$];
    protected bit [127:0]   m_user;
    protected bit [7:0]     m_id;
    protected bit [7:0]     m_dest;
    protected time          m_start;
    protected int unsigned  m_n_pkt;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual axis_if)::get(this, "", "vif", vif))
            `uvm_fatal(get_type_name(), "no axis_if in config_db under key 'vif'")
        if (!uvm_config_db #(axis_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "no axis_cfg in config_db under key 'cfg'")
    endfunction

    virtual task run_phase(uvm_phase phase);
        forever begin
            fork
                collect();
                @(posedge vif.rst);
            join_any
            disable fork;

            if (m_bytes.size() != 0) begin
                `uvm_info(get_type_name(),
                    $sformatf("reset discarded %0d byte(s) of a partial packet",
                              m_bytes.size()), UVM_MEDIUM)
                m_bytes.delete();
            end
            while (vif.rst === 1'b1) @(vif.mon_cb);
        end
    endtask

    protected virtual task collect();
        bit          fire;
        int unsigned bw;

        bw = cfg.keep_width();

        forever begin
            @(vif.mon_cb);
            fire = (vif.mon_cb.tvalid === 1'b1) &&
                   (!cfg.has_tready || (vif.mon_cb.tready === 1'b1));
            if (!fire) continue;

            if (m_bytes.size() == 0) m_start = $time;

            for (int b = 0; b < int'(bw); b++) begin
                if (!cfg.has_tkeep || vif.mon_cb.tkeep[b] === 1'b1)
                    m_bytes.push_back(vif.mon_cb.tdata[b*8 +: 8]);
            end

            m_user = vif.mon_cb.tuser;
            m_id   = vif.mon_cb.tid;
            m_dest = vif.mon_cb.tdest;

            // No tlast means no packet boundary: publish per beat.
            if (!cfg.has_tlast || vif.mon_cb.tlast === 1'b1)
                publish();
        end
    endtask

    protected virtual function void publish();
        axis_item it = axis_item::type_id::create("pkt");
        it.data = new[m_bytes.size()];
        foreach (m_bytes[i]) it.data[i] = m_bytes[i];
        it.user       = m_user;
        it.id         = m_id;
        it.dest       = m_dest;
        it.start_time = m_start;
        it.end_time   = $time;
        m_bytes.delete();
        m_n_pkt++;

        `uvm_info(get_type_name(), it.convert2string(), UVM_HIGH)
        ap.write(it);
    endfunction

    virtual function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        if (m_bytes.size() != 0)
            `uvm_error(get_type_name(),
                $sformatf("%0d byte(s) left in an unterminated packet at end of test",
                          m_bytes.size()))
    endfunction

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf("observed %0d packet(s)", m_n_pkt), UVM_LOW)
    endfunction

endclass : axis_monitor

`endif // AXIS_MONITOR_SV

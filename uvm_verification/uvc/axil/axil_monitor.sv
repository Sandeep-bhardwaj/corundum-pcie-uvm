// SPDX-License-Identifier: BSD-2-Clause-Views
//
// axil_monitor - AXI4-Lite passive monitor
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.1 (monitor behaviour), §4.3 rule 2
// Introduced : Step 1 (Tier 1a)
//
// STRATEGY §7.1: "reconstructs complete transactions; publishes on write-response
// and read-data completion. Must handle out-of-order AW/W arrival."
//
// The five channels are sampled by five independent processes. A write is only
// published once its AW, its W and its B have all been seen - publishing on AW
// alone would report writes the DUT never accepted, and publishing on B alone
// loses the address.
//
// STRATEGY §4.3 rule 2: monitors are the ONLY components with analysis ports.
// Drivers never publish, so a scoreboard can never be fooled by stimulus that
// the DUT did not actually accept.
// -----------------------------------------------------------------------------

`ifndef AXIL_MONITOR_SV
`define AXIL_MONITOR_SV

class axil_monitor extends uvm_monitor;

    `uvm_component_utils(axil_monitor)

    virtual axil_if vif;
    axil_cfg        cfg;

    // Completed transactions, both directions.
    uvm_analysis_port #(axil_item) ap;
    // Split ports for scoreboards that care about one direction only.
    uvm_analysis_port #(axil_item) wr_ap;
    uvm_analysis_port #(axil_item) rd_ap;

    // Channel staging
    protected bit [63:0] m_aw_addr_q [$];
    protected bit [2:0]  m_aw_prot_q [$];
    protected time       m_aw_time_q [$];
    protected bit [63:0] m_w_data_q  [$];
    protected bit [7:0]  m_w_strb_q  [$];
    protected bit [63:0] m_ar_addr_q [$];
    protected bit [2:0]  m_ar_prot_q [$];
    protected time       m_ar_time_q [$];

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap    = new("ap", this);
        wr_ap = new("wr_ap", this);
        rd_ap = new("rd_ap", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual axil_if)::get(this, "", "vif", vif))
            `uvm_fatal(get_type_name(), "no axil_if in config_db under key 'vif'")
        if (!uvm_config_db #(axil_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "no axil_cfg in config_db under key 'cfg'")
    endfunction

    virtual task run_phase(uvm_phase phase);
        forever begin
            fork
                begin : collectors
                    fork
                        collect_aw();
                        collect_w();
                        collect_b();
                        collect_ar();
                        collect_r();
                    join
                end
                begin : reset_watch
                    @(posedge vif.rst);
                end
            join_any
            disable fork;

            flush_on_reset();
            while (vif.rst === 1'b1) @(vif.mon_cb);
        end
    endtask

    // -------------------------------------------------------------------------
    // A reset discards in-flight transactions. Reporting them afterwards would
    // manufacture phantom activity for the scoreboard.
    // -------------------------------------------------------------------------
    protected virtual function void flush_on_reset();
        int n = m_aw_addr_q.size() + m_w_data_q.size() + m_ar_addr_q.size();
        if (n != 0)
            `uvm_info(get_type_name(),
                $sformatf("reset discarded %0d in-flight channel beat(s)", n), UVM_MEDIUM)
        m_aw_addr_q.delete(); m_aw_prot_q.delete(); m_aw_time_q.delete();
        m_w_data_q.delete();  m_w_strb_q.delete();
        m_ar_addr_q.delete(); m_ar_prot_q.delete(); m_ar_time_q.delete();
    endfunction

    // -------------------------------------------------------------------------
    protected virtual task collect_aw();
        forever begin
            @(vif.mon_cb);
            if (vif.mon_cb.awvalid === 1'b1 && vif.mon_cb.awready === 1'b1) begin
                m_aw_addr_q.push_back(vif.mon_cb.awaddr & cfg.addr_mask());
                m_aw_prot_q.push_back(vif.mon_cb.awprot);
                m_aw_time_q.push_back($time);
            end
        end
    endtask

    protected virtual task collect_w();
        forever begin
            @(vif.mon_cb);
            if (vif.mon_cb.wvalid === 1'b1 && vif.mon_cb.wready === 1'b1) begin
                m_w_data_q.push_back(vif.mon_cb.wdata & cfg.data_mask());
                m_w_strb_q.push_back(vif.mon_cb.wstrb & cfg.strb_mask());
            end
        end
    endtask

    // Publish a write when B completes it. AW and W may have arrived in either
    // order; both queues are drained in issue order, which is the AXI-Lite
    // association rule in the absence of IDs.
    protected virtual task collect_b();
        axil_item it;
        forever begin
            @(vif.mon_cb);
            if (vif.mon_cb.bvalid === 1'b1 && vif.mon_cb.bready === 1'b1) begin
                if (m_aw_addr_q.size() == 0 || m_w_data_q.size() == 0) begin
                    `uvm_error(get_type_name(),
                        $sformatf({"write response with no matching address/data ",
                                   "(aw pending=%0d, w pending=%0d) - protocol violation"},
                                  m_aw_addr_q.size(), m_w_data_q.size()))
                    continue;
                end
                it            = axil_item::type_id::create("wr");
                it.kind       = AXIL_WRITE;
                it.addr       = m_aw_addr_q.pop_front();
                it.prot       = m_aw_prot_q.pop_front();
                it.start_time = m_aw_time_q.pop_front();
                it.data       = m_w_data_q.pop_front();
                it.strb       = m_w_strb_q.pop_front();
                it.resp       = axil_resp_e'(vif.mon_cb.bresp);
                it.end_time   = $time;

                `uvm_info(get_type_name(),
                    $sformatf("observed %s", it.convert2string()), UVM_HIGH)
                ap.write(it);
                wr_ap.write(it);
            end
        end
    endtask

    protected virtual task collect_ar();
        forever begin
            @(vif.mon_cb);
            if (vif.mon_cb.arvalid === 1'b1 && vif.mon_cb.arready === 1'b1) begin
                m_ar_addr_q.push_back(vif.mon_cb.araddr & cfg.addr_mask());
                m_ar_prot_q.push_back(vif.mon_cb.arprot);
                m_ar_time_q.push_back($time);
            end
        end
    endtask

    protected virtual task collect_r();
        axil_item it;
        forever begin
            @(vif.mon_cb);
            if (vif.mon_cb.rvalid === 1'b1 && vif.mon_cb.rready === 1'b1) begin
                if (m_ar_addr_q.size() == 0) begin
                    `uvm_error(get_type_name(),
                        "read data with no outstanding read address - protocol violation")
                    continue;
                end
                it            = axil_item::type_id::create("rd");
                it.kind       = AXIL_READ;
                it.addr       = m_ar_addr_q.pop_front();
                it.prot       = m_ar_prot_q.pop_front();
                it.start_time = m_ar_time_q.pop_front();
                it.data       = vif.mon_cb.rdata & cfg.data_mask();
                it.resp       = axil_resp_e'(vif.mon_cb.rresp);
                it.end_time   = $time;

                `uvm_info(get_type_name(),
                    $sformatf("observed %s", it.convert2string()), UVM_HIGH)
                ap.write(it);
                rd_ap.write(it);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    virtual function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        if (m_aw_addr_q.size() != 0)
            `uvm_error(get_type_name(),
                $sformatf("%0d write address(es) never completed", m_aw_addr_q.size()))
        if (m_w_data_q.size() != 0)
            `uvm_error(get_type_name(),
                $sformatf("%0d write data beat(s) never completed", m_w_data_q.size()))
        if (m_ar_addr_q.size() != 0)
            `uvm_error(get_type_name(),
                $sformatf("%0d read address(es) never returned data", m_ar_addr_q.size()))
    endfunction

endclass : axil_monitor

`endif // AXIL_MONITOR_SV

// SPDX-License-Identifier: BSD-2-Clause-Views
//
// queue_op_monitor - queue manager operation monitor
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.8, §4.3 rule 2
// Introduced : Step 1 (Tier 1a)
//
// Four independent collectors, one per channel, each with its own analysis port
// so the scoreboard can subscribe to exactly what it needs.
//
// THE DOORBELL COLLECTOR IS THE ONE TO GET RIGHT. On the dequeue flavour
// (queue_manager) the doorbell is `m_axis_doorbell_{queue,valid}` - a bare pulse
// with NO ready signal. It must be sampled on EVERY clock where valid is high.
// A collector written as `wait valid; wait ready;` would drop every doorbell in
// the run and t1a_doorbell would pass by observing nothing. STRATEGY §7.8.
// -----------------------------------------------------------------------------

`ifndef QUEUE_OP_MONITOR_SV
`define QUEUE_OP_MONITOR_SV

class queue_op_monitor extends uvm_monitor;

    `uvm_component_utils(queue_op_monitor)

    virtual queue_op_if vif;
    queue_op_cfg        cfg;

    uvm_analysis_port #(queue_op_item) req_ap;
    uvm_analysis_port #(queue_op_item) resp_ap;
    uvm_analysis_port #(queue_op_item) commit_ap;
    uvm_analysis_port #(queue_op_item) notify_ap;

    // Counters, surfaced for the end-of-test sanity check.
    protected int unsigned m_n_req;
    protected int unsigned m_n_resp;
    protected int unsigned m_n_commit;
    protected int unsigned m_n_notify;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        req_ap    = new("req_ap", this);
        resp_ap   = new("resp_ap", this);
        commit_ap = new("commit_ap", this);
        notify_ap = new("notify_ap", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual queue_op_if)::get(this, "", "vif", vif))
            `uvm_fatal(get_type_name(), "no queue_op_if in config_db under key 'vif'")
        if (!uvm_config_db #(queue_op_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "no queue_op_cfg in config_db under key 'cfg'")
    endfunction

    virtual task run_phase(uvm_phase phase);
        forever begin
            fork
                begin : collectors
                    fork
                        collect_req();
                        collect_resp();
                        collect_commit();
                        collect_notify();
                    join
                end
                begin : reset_watch
                    @(posedge vif.rst);
                end
            join_any
            disable fork;
            while (vif.rst === 1'b1) @(vif.mon_cb);
        end
    endtask

    // -------------------------------------------------------------------------
    protected virtual task collect_req();
        queue_op_item it;
        forever begin
            @(vif.mon_cb);
            if (vif.mon_cb.req_valid === 1'b1 && vif.mon_cb.req_ready === 1'b1) begin
                it       = queue_op_item::type_id::create("req");
                it.kind  = QOP_REQ;
                it.queue = vif.mon_cb.req_queue & cfg.queue_mask();
                it.tag   = vif.mon_cb.req_tag;
                it.stamp = $time;
                m_n_req++;
                `uvm_info(get_type_name(), it.convert2string(), UVM_HIGH)
                req_ap.write(it);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    protected virtual task collect_resp();
        queue_op_item it;
        forever begin
            @(vif.mon_cb);
            if (vif.mon_cb.resp_valid === 1'b1 && vif.mon_cb.resp_ready === 1'b1) begin
                it         = queue_op_item::type_id::create("resp");
                it.kind    = QOP_RESP;
                it.queue   = vif.mon_cb.resp_queue & cfg.queue_mask();
                it.ptr     = vif.mon_cb.resp_ptr;
                it.phase   = vif.mon_cb.resp_phase;
                it.addr    = vif.mon_cb.resp_addr;
                it.aux     = vif.mon_cb.resp_aux;
                it.cpl     = (cfg.flavor == QOP_DEQUEUE) ? vif.mon_cb.resp_cpl : '0;
                it.tag     = vif.mon_cb.resp_tag;
                it.op_tag  = vif.mon_cb.resp_op_tag & cfg.op_tag_mask();
                it.blocked = vif.mon_cb.resp_blocked;
                it.error   = vif.mon_cb.resp_error;
                it.stamp   = $time;
                m_n_resp++;
                `uvm_info(get_type_name(), it.convert2string(), UVM_HIGH)
                resp_ap.write(it);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    protected virtual task collect_commit();
        queue_op_item it;
        forever begin
            @(vif.mon_cb);
            if (vif.mon_cb.commit_valid === 1'b1 && vif.mon_cb.commit_ready === 1'b1) begin
                it               = queue_op_item::type_id::create("commit");
                it.kind          = QOP_COMMIT;
                it.commit_op_tag = vif.mon_cb.commit_op_tag & cfg.op_tag_mask();
                it.stamp         = $time;
                m_n_commit++;
                `uvm_info(get_type_name(), it.convert2string(), UVM_HIGH)
                commit_ap.write(it);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Doorbell / event. See the file header: on the dequeue flavour there is no
    // ready, so the qualifying condition is valid ALONE, evaluated every cycle.
    // -------------------------------------------------------------------------
    protected virtual task collect_notify();
        queue_op_item it;
        bit           fire;
        forever begin
            @(vif.mon_cb);
            fire = (vif.mon_cb.notify_valid === 1'b1) &&
                   (!cfg.notify_has_ready || (vif.mon_cb.notify_ready === 1'b1));
            if (fire) begin
                it               = queue_op_item::type_id::create("notify");
                it.kind          = QOP_NOTIFY;
                it.notify_source = vif.mon_cb.notify_source & cfg.queue_mask();
                it.notify_data   = cfg.notify_has_ready ? vif.mon_cb.notify_data : '0;
                it.stamp         = $time;
                m_n_notify++;
                `uvm_info(get_type_name(), it.convert2string(), UVM_HIGH)
                notify_ap.write(it);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf("observed req=%0d resp=%0d commit=%0d notify=%0d",
                      m_n_req, m_n_resp, m_n_commit, m_n_notify), UVM_LOW)
    endfunction

endclass : queue_op_monitor

`endif // QUEUE_OP_MONITOR_SV

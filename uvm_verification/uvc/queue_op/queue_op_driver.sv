// SPDX-License-Identifier: BSD-2-Clause-Views
//
// queue_op_driver - queue manager operation driver
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.8
// Introduced : Step 1 (Tier 1a)
//
// Drives the two DUT-input channels (request, commit) and supplies consumer-side
// backpressure on the two DUT-output channels (response, notify).
//
// The response and notify ready signals are driven by free-running processes
// rather than per-item, because they are not associated with any one
// transaction: the DUT produces responses at its own rate and the testbench must
// always be a well-behaved consumer. Randomizing these is how t1a_op_table_full
// gets the op table to fill up.
//
// The request and commit channels are INDEPENDENT, each with its own server
// process. A single serial loop deadlocks as soon as the op table is full:
// drive_req() waits for req_ready, which only returns after a commit, and that
// commit is queued behind the blocked request. t1a_op_table_full hung on
// exactly that until the channels were split. Items are marked `driven` when
// their handshake completes; sequences wait on it (queue_op_item.wait_driven).
// -----------------------------------------------------------------------------

`ifndef QUEUE_OP_DRIVER_SV
`define QUEUE_OP_DRIVER_SV

class queue_op_driver extends uvm_driver #(queue_op_item);

    `uvm_component_utils(queue_op_driver)

    virtual queue_op_if vif;
    queue_op_cfg        cfg;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual queue_op_if)::get(this, "", "vif", vif))
            `uvm_fatal(get_type_name(), "no queue_op_if in config_db under key 'vif'")
        if (!uvm_config_db #(queue_op_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "no queue_op_cfg in config_db under key 'cfg'")
    endfunction

    protected mailbox #(queue_op_item) m_req_mb    = new();
    protected mailbox #(queue_op_item) m_commit_mb = new();

    virtual task run_phase(uvm_phase phase);
        drive_idle();
        fork
            resp_ready_driver();
            notify_ready_driver();
            channel_server(m_req_mb);
            channel_server(m_commit_mb);
        join_none

        forever begin
            @(vif.drv_cb);
            if (vif.rst === 1'b1) begin
                drive_idle();
                while (vif.rst === 1'b1) @(vif.drv_cb);
                continue;
            end
            seq_item_port.try_next_item(req);
            if (req == null) continue;
            if (req.kind == QOP_COMMIT) m_commit_mb.put(req);
            else                        m_req_mb.put(req);   // drive_item() rejects observed kinds
            seq_item_port.item_done();
        end
    endtask

    // One per DUT-input channel; each drives its items strictly in order.
    protected virtual task channel_server(mailbox #(queue_op_item) mb);
        queue_op_item it;
        forever begin
            mb.get(it);             // same timestep the dispatcher fetched it - no added cycle
            drive_item(it);
            it.driven = 1'b1;
        end
    endtask

    // -------------------------------------------------------------------------
    protected virtual task drive_idle();
        vif.drv_cb.req_queue     <= '0;
        vif.drv_cb.req_tag       <= '0;
        vif.drv_cb.req_valid     <= 1'b0;
        vif.drv_cb.commit_op_tag <= '0;
        vif.drv_cb.commit_valid  <= 1'b0;
    endtask

    protected virtual function int unsigned ready_gap();
        case (cfg.bp_profile)
            BP_NONE:       return 0;
            BP_AGGRESSIVE: return $urandom_range(4, 12);
            BP_BURSTY:     return ($urandom_range(0, 9) < 3) ? $urandom_range(8, 20) : 0;
            default:       return $urandom_range(0, 3);
        endcase
    endfunction

    // Free-running consumer for the response channel.
    protected virtual task resp_ready_driver();
        forever begin
            vif.drv_cb.resp_ready <= 1'b0;
            repeat (ready_gap()) @(vif.drv_cb);
            vif.drv_cb.resp_ready <= 1'b1;
            @(vif.drv_cb);
        end
    endtask

    // The dequeue flavour's doorbell has NO ready. Driving one would connect to
    // nothing in the wrapper, but holding it high is also the correct default
    // for the enqueue flavour's event channel, so this is safe either way.
    protected virtual task notify_ready_driver();
        if (!cfg.notify_has_ready) begin
            vif.drv_cb.notify_ready <= 1'b1;
            return;
        end
        forever begin
            vif.drv_cb.notify_ready <= 1'b0;
            repeat (ready_gap()) @(vif.drv_cb);
            vif.drv_cb.notify_ready <= 1'b1;
            @(vif.drv_cb);
        end
    endtask

    // -------------------------------------------------------------------------
    protected virtual task drive_item(queue_op_item it);
        it.stamp = $time;
        case (it.kind)
            QOP_REQ:    drive_req(it);
            QOP_COMMIT: drive_commit(it);
            default:
                `uvm_error(get_type_name(),
                    $sformatf({"item kind %s is an OBSERVED channel and cannot be ",
                               "driven; sequences may only send QOP_REQ or QOP_COMMIT"},
                              it.kind.name()))
        endcase
        `uvm_info(get_type_name(), $sformatf("drove %s", it.convert2string()), UVM_HIGH)
    endtask

    protected virtual task drive_req(queue_op_item it);
        repeat (it.delay) @(vif.drv_cb);
        vif.drv_cb.req_queue <= it.queue & cfg.queue_mask();
        vif.drv_cb.req_tag   <= it.tag;
        vif.drv_cb.req_valid <= 1'b1;
        do @(vif.drv_cb); while (vif.drv_cb.req_ready !== 1'b1);
        vif.drv_cb.req_valid <= 1'b0;
    endtask

    protected virtual task drive_commit(queue_op_item it);
        repeat (it.delay) @(vif.drv_cb);
        vif.drv_cb.commit_op_tag <= it.commit_op_tag & cfg.op_tag_mask();
        vif.drv_cb.commit_valid  <= 1'b1;
        do @(vif.drv_cb); while (vif.drv_cb.commit_ready !== 1'b1);
        vif.drv_cb.commit_valid  <= 1'b0;
    endtask

endclass : queue_op_driver

`endif // QUEUE_OP_DRIVER_SV

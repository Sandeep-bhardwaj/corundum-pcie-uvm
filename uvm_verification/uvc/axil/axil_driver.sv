// SPDX-License-Identifier: BSD-2-Clause-Views
//
// axil_driver - AXI4-Lite master driver
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.1 (driver behaviour)
// Introduced : Step 1 (Tier 1a)
//
// STRATEGY §7.1 requires independent AW and W channel timing, and that the
// driver randomize AW-before-W, W-before-AW and simultaneous. AXI imposes no
// ordering between those channels and DUTs routinely assume one; a driver that
// always issues AW first will never find that bug.
//
// Single outstanding transaction. AXI-Lite permits pipelining but neither DUT
// in this environment requires it, and a single-outstanding driver keeps the
// response association unambiguous. If a later tier needs pipelining, extend
// here rather than in the monitor - the monitor already tracks channels
// independently.
// -----------------------------------------------------------------------------

`ifndef AXIL_DRIVER_SV
`define AXIL_DRIVER_SV

class axil_driver extends uvm_driver #(axil_item);

    `uvm_component_utils(axil_driver)

    virtual axil_if vif;
    axil_cfg        cfg;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual axil_if)::get(this, "", "vif", vif))
            `uvm_fatal(get_type_name(), "no axil_if in config_db under key 'vif'")
        if (!uvm_config_db #(axil_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "no axil_cfg in config_db under key 'cfg'")
    endfunction

    virtual task run_phase(uvm_phase phase);
        drive_idle();
        forever begin
            // Stay idle through reset, then serve the sequencer.
            @(vif.master_cb);
            if (vif.rst === 1'b1) begin
                drive_idle();
                wait_out_of_reset();
                continue;
            end
            seq_item_port.try_next_item(req);
            if (req == null) continue;
            drive_item(req);
            seq_item_port.item_done();
        end
    endtask

    // -------------------------------------------------------------------------
    protected virtual task wait_out_of_reset();
        while (vif.rst === 1'b1) @(vif.master_cb);
    endtask

    protected virtual task drive_idle();
        vif.master_cb.awaddr  <= '0;
        vif.master_cb.awprot  <= '0;
        vif.master_cb.awvalid <= 1'b0;
        vif.master_cb.wdata   <= '0;
        vif.master_cb.wstrb   <= '0;
        vif.master_cb.wvalid  <= 1'b0;
        vif.master_cb.bready  <= 1'b0;
        vif.master_cb.araddr  <= '0;
        vif.master_cb.arprot  <= '0;
        vif.master_cb.arvalid <= 1'b0;
        vif.master_cb.rready  <= 1'b0;
    endtask

    // -------------------------------------------------------------------------
    protected virtual task drive_item(axil_item it);
        it.start_time = $time;
        if (it.kind == AXIL_WRITE) drive_write(it);
        else                       drive_read(it);
        it.end_time = $time;
        `uvm_info(get_type_name(), $sformatf("drove %s", it.convert2string()), UVM_HIGH)
    endtask

    // -------------------------------------------------------------------------
    // Write: AW and W are driven by independent processes whose relative start
    // is set by it.wr_order. B is collected after both have completed.
    // -------------------------------------------------------------------------
    protected virtual task drive_write(axil_item it);
        int unsigned aw_delay;
        int unsigned w_delay;

        case (it.wr_order)
            AXIL_AW_FIRST:      begin aw_delay = it.delay_aw; w_delay = it.delay_aw + it.delay_w + 1; end
            AXIL_W_FIRST:       begin w_delay  = it.delay_w;  aw_delay = it.delay_w + it.delay_aw + 1; end
            default:            begin aw_delay = it.delay_aw; w_delay = it.delay_aw; end
        endcase

        fork
            begin : aw_channel
                repeat (aw_delay) @(vif.master_cb);
                vif.master_cb.awaddr  <= it.addr & cfg.addr_mask();
                vif.master_cb.awprot  <= it.prot;
                vif.master_cb.awvalid <= 1'b1;
                do @(vif.master_cb); while (vif.master_cb.awready !== 1'b1);
                vif.master_cb.awvalid <= 1'b0;
            end
            begin : w_channel
                repeat (w_delay) @(vif.master_cb);
                vif.master_cb.wdata  <= it.data & cfg.data_mask();
                vif.master_cb.wstrb  <= it.strb & cfg.strb_mask();
                vif.master_cb.wvalid <= 1'b1;
                do @(vif.master_cb); while (vif.master_cb.wready !== 1'b1);
                vif.master_cb.wvalid <= 1'b0;
            end
        join

        // Write response
        repeat (it.delay_b) @(vif.master_cb);
        vif.master_cb.bready <= 1'b1;
        do @(vif.master_cb); while (vif.master_cb.bvalid !== 1'b1);
        it.resp = axil_resp_e'(vif.master_cb.bresp);
        vif.master_cb.bready <= 1'b0;
    endtask

    // -------------------------------------------------------------------------
    protected virtual task drive_read(axil_item it);
        repeat (it.delay_ar) @(vif.master_cb);
        vif.master_cb.araddr  <= it.addr & cfg.addr_mask();
        vif.master_cb.arprot  <= it.prot;
        vif.master_cb.arvalid <= 1'b1;
        do @(vif.master_cb); while (vif.master_cb.arready !== 1'b1);
        vif.master_cb.arvalid <= 1'b0;

        repeat (it.delay_r) @(vif.master_cb);
        vif.master_cb.rready <= 1'b1;
        do @(vif.master_cb); while (vif.master_cb.rvalid !== 1'b1);
        it.data = vif.master_cb.rdata & cfg.data_mask();
        it.resp = axil_resp_e'(vif.master_cb.rresp);
        vif.master_cb.rready <= 1'b0;
    endtask

endclass : axil_driver

`endif // AXIL_DRIVER_SV

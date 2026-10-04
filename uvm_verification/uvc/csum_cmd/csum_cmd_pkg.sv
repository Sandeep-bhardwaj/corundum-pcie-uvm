// SPDX-License-Identifier: BSD-2-Clause-Views
//
// csum_cmd_pkg - tx_checksum command UVC
//
// Implements : VERIFICATION_STRATEGY.md  §7.3
// Introduced : Step 3 (Tier 1c)
//
// Deliberately minimal: item, cfg, driver, monitor, agent and one sequence, all
// in the package file. There is exactly one command per packet and nothing to
// reassemble, so the full nine-file UVC pattern would be ceremony.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

package csum_cmd_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    import mqnic_vrf_pkg::*;
    import mqnic_seq_pkg::*;

    class csum_cmd_item extends uvm_sequence_item;
        rand bit          csum_enable;
        rand bit [7:0]    csum_start;
        rand bit [7:0]    csum_offset;
        rand bit [15:0]   csum_init;
        rand int unsigned delay;

        `uvm_object_utils_begin(csum_cmd_item)
            `uvm_field_int(csum_enable, UVM_ALL_ON | UVM_BIN)
            `uvm_field_int(csum_start,  UVM_ALL_ON | UVM_DEC)
            `uvm_field_int(csum_offset, UVM_ALL_ON | UVM_DEC)
            `uvm_field_int(csum_init,   UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(delay,       UVM_ALL_ON | UVM_DEC | UVM_NOCOMPARE)
        `uvm_object_utils_end

        // Defaults describe an IPv4/UDP frame: sum from the start of the IP
        // header, write the result into the UDP checksum field.
        constraint c_defaults {
            soft csum_enable == 1'b1;
            soft csum_start  == 14;
            soft csum_offset == 24;
            soft csum_init   == 16'h0000;
            delay dist { 0 := 80, [1:4] := 20 };
        }

        function new(string name = "csum_cmd_item");
            super.new(name);
        endfunction

        virtual function string convert2string();
            return $sformatf("CSUM_CMD en=%0b start=%0d offset=%0d init=0x%04h",
                             csum_enable, csum_start, csum_offset, csum_init);
        endfunction
    endclass


    class csum_cmd_cfg extends uvm_object;
        mqnic_agent_mode_e mode = MODE_ACTIVE_MASTER;
        `uvm_object_utils(csum_cmd_cfg)
        function new(string name = "csum_cmd_cfg");
            super.new(name);
        endfunction
    endclass


    class csum_cmd_driver extends uvm_driver #(csum_cmd_item);
        `uvm_component_utils(csum_cmd_driver)
        virtual csum_cmd_if vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual csum_cmd_if)::get(this, "", "vif", vif))
                `uvm_fatal(get_type_name(), "no csum_cmd_if in config_db under key vif")
        endfunction

        virtual task run_phase(uvm_phase phase);
            drive_idle();
            forever begin
                @(vif.drv_cb);
                if (vif.rst === 1'b1) begin
                    drive_idle();
                    while (vif.rst === 1'b1) @(vif.drv_cb);
                    continue;
                end
                seq_item_port.try_next_item(req);
                if (req == null) continue;
                repeat (req.delay) @(vif.drv_cb);
                vif.drv_cb.csum_enable <= req.csum_enable;
                vif.drv_cb.csum_start  <= req.csum_start;
                vif.drv_cb.csum_offset <= req.csum_offset;
                vif.drv_cb.csum_init   <= req.csum_init;
                vif.drv_cb.valid       <= 1'b1;
                do @(vif.drv_cb); while (vif.drv_cb.ready !== 1'b1);
                vif.drv_cb.valid       <= 1'b0;
                `uvm_info(get_type_name(), req.convert2string(), UVM_HIGH)
                seq_item_port.item_done();
            end
        endtask

        protected virtual task drive_idle();
            vif.drv_cb.csum_enable <= 1'b0;
            vif.drv_cb.csum_start  <= '0;
            vif.drv_cb.csum_offset <= '0;
            vif.drv_cb.csum_init   <= '0;
            vif.drv_cb.valid       <= 1'b0;
        endtask
    endclass


    class csum_cmd_monitor extends uvm_monitor;
        `uvm_component_utils(csum_cmd_monitor)
        virtual csum_cmd_if vif;
        uvm_analysis_port #(csum_cmd_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual csum_cmd_if)::get(this, "", "vif", vif))
                `uvm_fatal(get_type_name(), "no csum_cmd_if in config_db under key vif")
        endfunction

        virtual task run_phase(uvm_phase phase);
            csum_cmd_item it;
            forever begin
                @(vif.mon_cb);
                if (vif.mon_cb.valid === 1'b1 && vif.mon_cb.ready === 1'b1) begin
                    it = csum_cmd_item::type_id::create("cmd");
                    it.csum_enable = vif.mon_cb.csum_enable;
                    it.csum_start  = vif.mon_cb.csum_start;
                    it.csum_offset = vif.mon_cb.csum_offset;
                    it.csum_init   = vif.mon_cb.csum_init;
                    ap.write(it);
                end
            end
        endtask
    endclass


    typedef uvm_sequencer #(csum_cmd_item) csum_cmd_sequencer;


    class csum_cmd_agent extends uvm_agent;
        `uvm_component_utils(csum_cmd_agent)

        csum_cmd_cfg       cfg;
        csum_cmd_sequencer sequencer;
        csum_cmd_driver    driver;
        csum_cmd_monitor   monitor;
        uvm_analysis_port #(csum_cmd_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(csum_cmd_cfg)::get(this, "", "cfg", cfg))
                cfg = csum_cmd_cfg::type_id::create("cfg");
            monitor = csum_cmd_monitor::type_id::create("monitor", this);
            if (cfg.mode != MODE_PASSIVE) begin
                sequencer = csum_cmd_sequencer::type_id::create("sequencer", this);
                driver    = csum_cmd_driver::type_id::create("driver", this);
            end
        endfunction

        virtual function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            ap = monitor.ap;
            if (cfg.mode != MODE_PASSIVE)
                driver.seq_item_port.connect(sequencer.seq_item_export);
        endfunction
    endclass


    class csum_cmd_seq extends mqnic_base_seq #(csum_cmd_item);
        `uvm_object_utils(csum_cmd_seq)

        rand bit        csum_enable;
        rand bit [7:0]  csum_start;
        rand bit [7:0]  csum_offset;
        rand bit [15:0] csum_init;

        function new(string name = "csum_cmd_seq");
            super.new(name);
        endfunction

        virtual task body();
            csum_cmd_item it;
            it = csum_cmd_item::type_id::create("it");
            start_item(it);
            if (!it.randomize() with {
                    csum_enable == local::csum_enable;
                    csum_start  == local::csum_start;
                    csum_offset == local::csum_offset;
                    csum_init   == local::csum_init;
                })
                `uvm_fatal(get_type_name(), "randomize failed")
            finish_item(it);
        endtask
    endclass

endpackage : csum_cmd_pkg

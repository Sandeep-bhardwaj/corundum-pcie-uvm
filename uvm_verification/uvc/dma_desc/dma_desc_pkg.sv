// SPDX-License-Identifier: BSD-2-Clause-Views
//
// dma_desc_pkg - DMA descriptor UVC
//
// Implements : VERIFICATION_STRATEGY.md  §7.5
// Introduced : Step 4 (Tier 2); reused at Tier 3 (dma_if_pcie) and Tier 5
//
// Item, cfg, driver, monitor, agent and sequences in one package file. The
// channel is a single request handshake plus a status pulse - there is nothing
// to reassemble, so the nine-file pattern would be ceremony.
//
// THE FREE-TAG POOL IS THE INTERESTING PART. STRATEGY §7.5: "The driver must
// maintain a free-tag pool - issuing a duplicate in-flight tag is illegal
// stimulus, not a DUT bug." That matters from Tier 3 on, where a duplicate tag
// makes completion reassembly ambiguous and the resulting mismatch looks like a
// DMA engine fault. Building the pool here means Tier 3 inherits it working.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

package dma_desc_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    import mqnic_vrf_pkg::*;
    import mqnic_seq_pkg::*;

    // Which DUT this agent is attached to; selects which fields are live.
    typedef enum {
        DMA_DESC_CLIENT_RD,   // dma_client_axis_source: ram_addr,len,tag,id,dest,user
        DMA_DESC_CLIENT_WR,   // dma_client_axis_sink  : ram_addr,len,tag
        DMA_DESC_PCIE_RD,     // Tier 3 dma_if_pcie read
        DMA_DESC_PCIE_WR      // Tier 3 dma_if_pcie write (adds imm)
    } dma_desc_flavor_e;


    class dma_desc_item extends uvm_sequence_item;

        rand bit [63:0] pcie_addr;
        rand bit [7:0]  ram_sel;
        rand bit [31:0] ram_addr;
        rand bit [15:0] len;
        rand bit [7:0]  tag;
        rand bit [7:0]  id;
        rand bit [7:0]  dest;
        rand bit [7:0]  user;
        rand bit [31:0] imm;
        rand bit        imm_en;
        rand int unsigned delay;

        // Filled by the monitor from the status channel.
        bit [15:0] sts_len;
        bit [3:0]  error;
        time       stamp;

        `uvm_object_utils_begin(dma_desc_item)
            `uvm_field_int(pcie_addr, UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(ram_sel,   UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(ram_addr,  UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(len,       UVM_ALL_ON | UVM_DEC)
            `uvm_field_int(tag,       UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(id,        UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(dest,      UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(user,      UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(imm,       UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(imm_en,    UVM_ALL_ON | UVM_BIN)
            `uvm_field_int(error,     UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(delay,     UVM_ALL_ON | UVM_DEC | UVM_NOCOMPARE)
        `uvm_object_utils_end

        constraint c_defaults {
            soft len inside {[1:256]};
            soft imm_en == 1'b0;
            soft ram_sel == 0;
            delay dist { 0 := 70, [1:4] := 20, [5:15] := 10 };
        }

        function new(string name = "dma_desc_item");
            super.new(name);
        endfunction

        virtual function string convert2string();
            return $sformatf("DESC ram_addr=0x%0h len=%0d tag=0x%0h err=%0d",
                             ram_addr, len, tag, error);
        endfunction
    endclass


    class dma_desc_cfg extends uvm_object;
        mqnic_agent_mode_e mode   = MODE_ACTIVE_MASTER;
        dma_desc_flavor_e  flavor = DMA_DESC_CLIENT_WR;

        int unsigned len_width = 16;
        int unsigned tag_width = 8;

        // Tags currently in flight must be unique - see the package header.
        int unsigned tag_count = 256;

        `uvm_object_utils_begin(dma_desc_cfg)
            `uvm_field_enum(mqnic_agent_mode_e, mode,   UVM_ALL_ON)
            `uvm_field_enum(dma_desc_flavor_e,  flavor, UVM_ALL_ON)
            `uvm_field_int (len_width, UVM_ALL_ON | UVM_DEC)
            `uvm_field_int (tag_width, UVM_ALL_ON | UVM_DEC)
            `uvm_field_int (tag_count, UVM_ALL_ON | UVM_DEC)
        `uvm_object_utils_end

        function new(string name = "dma_desc_cfg");
            super.new(name);
        endfunction

        function bit has_id_dest_user();
            return (flavor == DMA_DESC_CLIENT_RD);
        endfunction

        function bit has_pcie();
            return (flavor == DMA_DESC_PCIE_RD || flavor == DMA_DESC_PCIE_WR);
        endfunction

        function bit has_imm();
            return (flavor == DMA_DESC_PCIE_WR);
        endfunction

        function bit has_sts_len();
            return (flavor == DMA_DESC_CLIENT_WR);
        endfunction
    endclass


    class dma_desc_driver extends uvm_driver #(dma_desc_item);
        `uvm_component_utils(dma_desc_driver)

        virtual dma_desc_if vif;
        dma_desc_cfg        cfg;

        // Tags handed out and not yet returned by the status channel.
        protected bit m_tag_busy [bit [7:0]];

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual dma_desc_if)::get(this, "", "vif", vif))
                `uvm_fatal(get_type_name(), "no dma_desc_if in config_db under key vif")
            if (!uvm_config_db #(dma_desc_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal(get_type_name(), "no dma_desc_cfg in config_db under key cfg")
        endfunction

        // Called by the agent when the status channel retires a tag.
        virtual function void release_tag(bit [7:0] t);
            if (m_tag_busy.exists(t)) m_tag_busy.delete(t);
        endfunction

        virtual task run_phase(uvm_phase phase);
            vif.init_idle_requester();
            forever begin
                @(vif.req_cb);
                if (vif.rst === 1'b1) begin
                    vif.init_idle_requester();
                    m_tag_busy.delete();
                    while (vif.rst === 1'b1) @(vif.req_cb);
                    continue;
                end
                seq_item_port.try_next_item(req);
                if (req == null) continue;
                drive(req);
                seq_item_port.item_done();
            end
        endtask

        protected virtual task drive(dma_desc_item it);
            // Reusing an in-flight tag is illegal STIMULUS - flag it here rather
            // than letting it surface later as an unexplainable DUT mismatch.
            if (m_tag_busy.exists(it.tag))
                `uvm_error(get_type_name(),
                    $sformatf({"descriptor tag 0x%0h is already in flight; ",
                               "reusing it makes the status response ambiguous"}, it.tag))
            m_tag_busy[it.tag] = 1'b1;

            repeat (it.delay) @(vif.req_cb);

            vif.req_cb.req_ram_addr <= it.ram_addr;
            vif.req_cb.req_len      <= it.len;
            vif.req_cb.req_tag      <= it.tag;
            if (cfg.has_id_dest_user()) begin
                vif.req_cb.req_id   <= it.id;
                vif.req_cb.req_dest <= it.dest;
                vif.req_cb.req_user <= it.user;
            end
            if (cfg.has_pcie()) begin
                vif.req_cb.req_pcie_addr <= it.pcie_addr;
                vif.req_cb.req_ram_sel   <= it.ram_sel;
            end
            if (cfg.has_imm()) begin
                vif.req_cb.req_imm    <= it.imm;
                vif.req_cb.req_imm_en <= it.imm_en;
            end
            vif.req_cb.req_valid <= 1'b1;

            do @(vif.req_cb); while (vif.req_cb.req_ready !== 1'b1);
            vif.req_cb.req_valid <= 1'b0;
            it.stamp = $time;
            `uvm_info(get_type_name(), it.convert2string(), UVM_HIGH)
        endtask
    endclass


    class dma_desc_monitor extends uvm_monitor;
        `uvm_component_utils(dma_desc_monitor)

        virtual dma_desc_if vif;
        dma_desc_cfg        cfg;

        uvm_analysis_port #(dma_desc_item) req_ap;
        uvm_analysis_port #(dma_desc_item) sts_ap;

        protected int unsigned m_n_req;
        protected int unsigned m_n_sts;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            req_ap = new("req_ap", this);
            sts_ap = new("sts_ap", this);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual dma_desc_if)::get(this, "", "vif", vif))
                `uvm_fatal(get_type_name(), "no dma_desc_if in config_db under key vif")
            if (!uvm_config_db #(dma_desc_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal(get_type_name(), "no dma_desc_cfg in config_db under key cfg")
        endfunction

        virtual task run_phase(uvm_phase phase);
            dma_desc_item it;
            forever begin
                @(vif.mon_cb);

                if (vif.mon_cb.req_valid === 1'b1 && vif.mon_cb.req_ready === 1'b1) begin
                    it = dma_desc_item::type_id::create("req");
                    it.ram_addr  = vif.mon_cb.req_ram_addr;
                    it.len       = 16'(vif.mon_cb.req_len);
                    it.tag       = 8'(vif.mon_cb.req_tag);
                    it.id        = cfg.has_id_dest_user() ? vif.mon_cb.req_id   : 8'h0;
                    it.dest      = cfg.has_id_dest_user() ? vif.mon_cb.req_dest : 8'h0;
                    it.user      = cfg.has_id_dest_user() ? vif.mon_cb.req_user : 8'h0;
                    it.pcie_addr = cfg.has_pcie() ? vif.mon_cb.req_pcie_addr : 64'h0;
                    it.ram_sel   = cfg.has_pcie() ? vif.mon_cb.req_ram_sel   : 8'h0;
                    it.imm       = cfg.has_imm()  ? vif.mon_cb.req_imm       : 32'h0;
                    it.imm_en    = cfg.has_imm()  ? vif.mon_cb.req_imm_en    : 1'b0;
                    it.stamp     = $time;
                    m_n_req++;
                    `uvm_info(get_type_name(), it.convert2string(), UVM_HIGH)
                    req_ap.write(it);
                end

                // Status is a PULSE with no ready - level-qualified only.
                if (vif.mon_cb.sts_valid === 1'b1) begin
                    it = dma_desc_item::type_id::create("sts");
                    it.tag     = 8'(vif.mon_cb.sts_tag);
                    it.error   = vif.mon_cb.sts_error;
                    it.sts_len = cfg.has_sts_len() ? 16'(vif.mon_cb.sts_len) : 16'h0;
                    it.id      = vif.mon_cb.sts_id;
                    it.dest    = vif.mon_cb.sts_dest;
                    it.user    = vif.mon_cb.sts_user;
                    it.stamp   = $time;
                    m_n_sts++;
                    `uvm_info(get_type_name(),
                        $sformatf("STATUS tag=0x%0h len=%0d err=%0d",
                                  it.tag, it.sts_len, it.error), UVM_HIGH)
                    sts_ap.write(it);
                end
            end
        endtask

        virtual function void report_phase(uvm_phase phase);
            super.report_phase(phase);
            `uvm_info(get_type_name(),
                $sformatf("observed req=%0d status=%0d", m_n_req, m_n_sts), UVM_LOW)
        endfunction
    endclass


    typedef uvm_sequencer #(dma_desc_item) dma_desc_sequencer;


    // -------------------------------------------------------------------------
    // Returns a tag to the driver's free pool when the DUT reports the
    // descriptor complete.
    //
    // Without this the pool only ever shrinks. Tier 2's tests each used fewer
    // descriptors than there are tags, so it never showed; Tier 3's random
    // stress issues hundreds and would report every reuse as illegal stimulus -
    // a testbench fault dressed up as a DUT bug.
    // -------------------------------------------------------------------------
    class dma_desc_tag_release extends uvm_subscriber #(dma_desc_item);
        `uvm_component_utils(dma_desc_tag_release)

        dma_desc_driver driver;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        virtual function void write(dma_desc_item t);
            if (driver != null) driver.release_tag(t.tag);
        endfunction
    endclass


    class dma_desc_agent extends uvm_agent;
        `uvm_component_utils(dma_desc_agent)

        dma_desc_cfg         cfg;
        dma_desc_sequencer   sequencer;
        dma_desc_driver      driver;
        dma_desc_monitor     monitor;
        dma_desc_tag_release tag_release;

        uvm_analysis_port #(dma_desc_item) req_ap;
        uvm_analysis_port #(dma_desc_item) sts_ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(dma_desc_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal(get_type_name(), "no dma_desc_cfg in config_db under key cfg")
            uvm_config_db #(dma_desc_cfg)::set(this, "*", "cfg", cfg);

            monitor = dma_desc_monitor::type_id::create("monitor", this);
            if (cfg.mode != MODE_PASSIVE) begin
                sequencer   = dma_desc_sequencer::type_id::create("sequencer", this);
                driver      = dma_desc_driver::type_id::create("driver", this);
                tag_release = dma_desc_tag_release::type_id::create("tag_release", this);
            end
        endfunction

        virtual function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            req_ap = monitor.req_ap;
            sts_ap = monitor.sts_ap;
            if (cfg.mode != MODE_PASSIVE) begin
                driver.seq_item_port.connect(sequencer.seq_item_export);
                tag_release.driver = driver;
                monitor.sts_ap.connect(tag_release.analysis_export);
            end
        endfunction
    endclass


    class dma_desc_seq extends mqnic_base_seq #(dma_desc_item);
        `uvm_object_utils(dma_desc_seq)

        rand bit [31:0] ram_addr;
        rand bit [15:0] len;
        rand bit [7:0]  tag;
        rand bit [7:0]  id;
        rand bit [7:0]  dest;
        rand bit [7:0]  user;

        function new(string name = "dma_desc_seq");
            super.new(name);
        endfunction

        virtual task body();
            dma_desc_item it;
            it = dma_desc_item::type_id::create("it");
            start_item(it);
            if (!it.randomize() with { ram_addr == local::ram_addr;
                                       len      == local::len;
                                       tag      == local::tag;
                                       id       == local::id;
                                       dest     == local::dest;
                                       user     == local::user; })
                `uvm_fatal(get_type_name(), "randomize failed")
            finish_item(it);
        endtask
    endclass


    // -------------------------------------------------------------------------
    // Tier 3 descriptor: adds the PCIe source address and the RAM select that
    // the client flavours do not carry.
    //
    // The tag is NOT randomized here. Tier 3 runs hundreds of descriptors and
    // the driver rejects an in-flight duplicate, so tags are allocated by the
    // caller in a rotation the free pool can keep up with.
    // -------------------------------------------------------------------------
    class dma_desc_pcie_seq extends mqnic_base_seq #(dma_desc_item);
        `uvm_object_utils(dma_desc_pcie_seq)

        rand bit [63:0] pcie_addr;
        rand bit [31:0] ram_addr;
        rand bit [15:0] len;
        rand bit [7:0]  tag;
        rand bit [7:0]  ram_sel;
        rand bit [31:0] imm;
        rand bit        imm_en;
        rand int unsigned delay;

        constraint c_defaults {
            soft ram_sel == 0;
            soft imm_en  == 1'b0;
            soft delay   inside {[0:4]};
        }

        function new(string name = "dma_desc_pcie_seq");
            super.new(name);
        endfunction

        virtual task body();
            dma_desc_item it;
            it = dma_desc_item::type_id::create("it");
            start_item(it);
            if (!it.randomize() with { pcie_addr == local::pcie_addr;
                                       ram_addr  == local::ram_addr;
                                       len       == local::len;
                                       tag       == local::tag;
                                       ram_sel   == local::ram_sel;
                                       imm       == local::imm;
                                       imm_en    == local::imm_en;
                                       delay     == local::delay; })
                `uvm_fatal(get_type_name(), "randomize failed")
            finish_item(it);
        endtask
    endclass

endpackage : dma_desc_pkg

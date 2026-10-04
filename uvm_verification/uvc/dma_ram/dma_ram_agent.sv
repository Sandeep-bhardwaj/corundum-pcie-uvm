// SPDX-License-Identifier: BSD-2-Clause-Views
//
// dma_ram_sequencer / dma_ram_agent / dma_ram_seq_lib
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.4, §12.1 Level 0
// Introduced : Step 4 (Tier 2); reused at Tiers 3 and 5 (§5.1)
// -----------------------------------------------------------------------------

`ifndef DMA_RAM_AGENT_SV
`define DMA_RAM_AGENT_SV

typedef uvm_sequencer #(dma_ram_item) dma_ram_sequencer;

class dma_ram_agent extends uvm_agent;

    `uvm_component_utils(dma_ram_agent)

    dma_ram_cfg       cfg;

    dma_ram_sequencer sequencer;
    dma_ram_driver    driver;       // MODE_ACTIVE_MASTER - drives commands
    dma_ram_responder responder;    // MODE_ACTIVE_SLAVE  - models the RAM
    dma_ram_monitor   monitor;

    uvm_analysis_port #(dma_ram_item) wr_ap;
    uvm_analysis_port #(dma_ram_item) done_ap;
    uvm_analysis_port #(dma_ram_item) rd_ap;
    uvm_analysis_port #(dma_ram_item) data_ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db #(dma_ram_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "no dma_ram_cfg in config_db under key cfg")
        uvm_config_db #(dma_ram_cfg)::set(this, "*", "cfg", cfg);

        monitor = dma_ram_monitor::type_id::create("monitor", this);

        case (cfg.mode)
            MODE_ACTIVE_MASTER: begin
                sequencer = dma_ram_sequencer::type_id::create("sequencer", this);
                driver    = dma_ram_driver::type_id::create("driver", this);
            end
            MODE_ACTIVE_SLAVE:
                responder = dma_ram_responder::type_id::create("responder", this);
            MODE_PASSIVE: ;
            default:
                `uvm_fatal(get_type_name(), $sformatf("bad mode %s", cfg.mode.name()))
        endcase
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        wr_ap   = monitor.wr_ap;
        done_ap = monitor.done_ap;
        rd_ap   = monitor.rd_ap;
        data_ap = monitor.data_ap;
        if (cfg.mode == MODE_ACTIVE_MASTER)
            driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction

    // Read commands still awaiting data. A test drains on this rather than on
    // a fixed delay - see dma_ram_monitor.outstanding_reads().
    virtual function int unsigned outstanding_reads();
        return monitor.outstanding_reads();
    endfunction

    // Items accepted from the sequencer but not yet driven onto the bus.
    // seq.start() returning does NOT mean the DUT has seen the traffic - the
    // driver queues per segment. See dma_ram_driver's file header.
    virtual function int unsigned pending_items();
        return (driver == null) ? 0 : driver.pending_items();
    endfunction

    // True when nothing is queued, nothing is mid-handshake and every read has
    // been answered.
    virtual function bit is_idle();
        return (pending_items() == 0) && (outstanding_reads() == 0);
    endfunction

    // Backdoor into the responder's memory, for Tier 3 preloading.
    virtual function void poke(int seg, bit [15:0] addr, bit [255:0] data);
        if (responder == null)
            `uvm_fatal(get_type_name(), "poke() requires MODE_ACTIVE_SLAVE")
        responder.poke(seg, addr, data);
    endfunction

    virtual function bit [255:0] peek(int seg, bit [15:0] addr);
        if (responder == null)
            `uvm_fatal(get_type_name(), "peek() requires MODE_ACTIVE_SLAVE")
        return responder.peek(seg, addr);
    endfunction

endclass : dma_ram_agent


// =============================================================================
// Sequence library (Level 0)
// =============================================================================

// One write to one segment.
class dma_ram_write_seq extends mqnic_base_seq #(dma_ram_item);

    `uvm_object_utils(dma_ram_write_seq)

    rand int unsigned seg;
    rand bit [15:0]   addr;
    rand bit [255:0]  data;
    rand bit [31:0]   be;

    constraint c_defaults { soft be == 32'hFFFF_FFFF; }

    function new(string name = "dma_ram_write_seq");
        super.new(name);
    endfunction

    virtual task body();
        dma_ram_item it;
        it = dma_ram_item::type_id::create("it");
        start_item(it);
        if (!it.randomize() with { kind == DMA_RAM_WRITE; seg  == local::seg;
                                   addr == local::addr;   data == local::data;
                                   be   == local::be; })
            `uvm_fatal(get_type_name(), "randomize failed")
        finish_item(it);
    endtask

endclass : dma_ram_write_seq


// One read from one segment.
class dma_ram_read_seq extends mqnic_base_seq #(dma_ram_item);

    `uvm_object_utils(dma_ram_read_seq)

    rand int unsigned seg;
    rand bit [15:0]   addr;

    function new(string name = "dma_ram_read_seq");
        super.new(name);
    endfunction

    virtual task body();
        dma_ram_item it;
        it = dma_ram_item::type_id::create("it");
        start_item(it);
        if (!it.randomize() with { kind == DMA_RAM_READ; seg == local::seg;
                                   addr == local::addr; })
            `uvm_fatal(get_type_name(), "randomize failed")
        finish_item(it);
    endtask

endclass : dma_ram_read_seq


// -----------------------------------------------------------------------------
// Write every segment at one address, then read them all back.
//
// The sequencer hands items to the driver serially, but the driver routes them
// into per-segment queues and its per-segment servers run concurrently - so
// issuing one item per segment back-to-back is what actually produces
// simultaneous multi-segment activity. That is the pattern a real DMA client
// generates and the one a naive serial driver never would.
// -----------------------------------------------------------------------------
class dma_ram_all_seg_seq extends mqnic_base_seq #(dma_ram_item);

    `uvm_object_utils(dma_ram_all_seg_seq)

    rand int unsigned n_segs;
    rand bit [15:0]   addr;
    rand bit          do_write;

    constraint c_defaults {
        soft n_segs   == 2;
        soft do_write == 1'b1;
        n_segs inside {[1:8]};
    }

    function new(string name = "dma_ram_all_seg_seq");
        super.new(name);
    endfunction

    virtual task body();
        dma_ram_item it;
        for (int s = 0; s < int'(n_segs); s++) begin
            if (stop_requested()) break;
            it = dma_ram_item::type_id::create($sformatf("seg%0d", s));
            start_item(it);
            if (!it.randomize() with {
                    kind  == (local::do_write ? DMA_RAM_WRITE : DMA_RAM_READ);
                    seg   == s;
                    addr  == local::addr;
                    delay == 0;             // no stagger: hit all segments together
                })
                `uvm_fatal(get_type_name(), "randomize failed")
            finish_item(it);
        end
    endtask

endclass : dma_ram_all_seg_seq


// -----------------------------------------------------------------------------
// Randomized traffic across a segment and address window.
// -----------------------------------------------------------------------------
class dma_ram_random_seq extends mqnic_base_seq #(dma_ram_item);

    `uvm_object_utils(dma_ram_random_seq)

    rand int unsigned n_ops;
    rand int unsigned n_segs;
    rand bit [15:0]   addr_hi;
    rand int unsigned write_pct;

    constraint c_defaults {
        soft n_ops     inside {[32:128]};
        soft n_segs    == 2;
        soft addr_hi   == 16'h003F;
        soft write_pct == 50;
        n_segs inside {[1:8]};
        write_pct <= 100;
    }

    function new(string name = "dma_ram_random_seq");
        super.new(name);
    endfunction

    virtual task body();
        dma_ram_item it;
        for (int i = 0; i < int'(n_ops); i++) begin
            if (stop_requested()) break;
            it = dma_ram_item::type_id::create($sformatf("op%0d", i));
            start_item(it);
            if (!it.randomize() with {
                    kind dist { DMA_RAM_WRITE := local::write_pct,
                                DMA_RAM_READ  := 100 - local::write_pct };
                    seg  < local::n_segs;
                    addr <= local::addr_hi;
                })
                `uvm_fatal(get_type_name(), "randomize failed")
            finish_item(it);
        end
    endtask

endclass : dma_ram_random_seq

`endif // DMA_RAM_AGENT_SV

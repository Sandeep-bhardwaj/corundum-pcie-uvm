// SPDX-License-Identifier: BSD-2-Clause-Views
//
// pcie_tlp_sequencer / pcie_tlp_agent / pcie_tlp_seq_lib
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.2, §12.1 Level 0
// Introduced : Step 2 (Tier 1b); reused at Tiers 3, 4, 5 (§5.1)
// -----------------------------------------------------------------------------

`ifndef PCIE_TLP_AGENT_SV
`define PCIE_TLP_AGENT_SV

typedef uvm_sequencer #(pcie_tlp_item) pcie_tlp_sequencer;

class pcie_tlp_agent extends uvm_agent;

    `uvm_component_utils(pcie_tlp_agent)

    pcie_tlp_cfg         cfg;
    int                  port_id = 0;

    pcie_tlp_sequencer   sequencer;
    pcie_tlp_driver      driver;
    pcie_tlp_sink_driver sink_driver;
    pcie_tlp_monitor     monitor;

    uvm_analysis_port #(pcie_tlp_item) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(pcie_tlp_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "no pcie_tlp_cfg in config_db under key 'cfg'")
        void'(uvm_config_db #(int)::get(this, "", "port_id", port_id));

        uvm_config_db #(pcie_tlp_cfg)::set(this, "*", "cfg", cfg);
        uvm_config_db #(int)::set(this, "*", "port_id", port_id);

        monitor = pcie_tlp_monitor::type_id::create("monitor", this);

        case (cfg.mode)
            MODE_ACTIVE_MASTER: begin
                sequencer = pcie_tlp_sequencer::type_id::create("sequencer", this);
                driver    = pcie_tlp_driver::type_id::create("driver", this);
            end
            MODE_ACTIVE_SLAVE:
                sink_driver = pcie_tlp_sink_driver::type_id::create("sink_driver", this);
            MODE_PASSIVE: ;
            default:
                `uvm_fatal(get_type_name(), $sformatf("bad mode %s", cfg.mode.name()))
        endcase
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        ap = monitor.ap;
        if (cfg.mode == MODE_ACTIVE_MASTER)
            driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction

endclass : pcie_tlp_agent


// =============================================================================
// Sequence library (Level 0)
// =============================================================================

// One TLP with caller-supplied fields.
class pcie_tlp_single_seq extends mqnic_base_seq #(pcie_tlp_item);

    `uvm_object_utils(pcie_tlp_single_seq)

    rand bit [127:0]  hdr;
    rand bit [2:0]    bar_id;
    rand bit [7:0]    func_num;
    rand int unsigned payload_bytes;
    rand int unsigned delay;

    constraint c_defaults {
        soft payload_bytes == 0;
        soft func_num      == 0;
        soft delay         inside {[0:4]};
        payload_bytes % 4 == 0;
        payload_bytes <= 256;
    }

    function new(string name = "pcie_tlp_single_seq");
        super.new(name);
    endfunction

    virtual task body();
        pcie_tlp_item it;
        it = pcie_tlp_item::type_id::create("it");
        start_item(it);
        if (!it.randomize() with {
                hdr           == local::hdr;
                bar_id        == local::bar_id;
                func_num      == local::func_num;
                payload.size() == local::payload_bytes;
                delay         == local::delay;
            })
            `uvm_fatal(get_type_name(), "randomize failed")
        finish_item(it);
    endtask

endclass : pcie_tlp_single_seq


// Send an already-built item verbatim.
//
// pcie_tlp_single_seq RANDOMIZES the payload, which is right for stimulus and
// wrong for a completion: the bytes must be the ones the host memory model
// holds. This sequence carries a fully-formed item through untouched.
class pcie_tlp_verbatim_seq extends mqnic_base_seq #(pcie_tlp_item);

    `uvm_object_utils(pcie_tlp_verbatim_seq)

    pcie_tlp_item src;

    function new(string name = "pcie_tlp_verbatim_seq");
        super.new(name);
    endfunction

    virtual task body();
        pcie_tlp_item it;
        if (src == null)
            `uvm_fatal(get_type_name(), "src item not set")
        it = pcie_tlp_item::type_id::create("it");
        it.hdr      = src.hdr;
        it.bar_id   = src.bar_id;
        it.func_num = src.func_num;
        it.error    = src.error;
        it.seq      = src.seq;
        it.delay    = src.delay;
        it.payload  = new[src.payload.size()];
        foreach (src.payload[i]) it.payload[i] = src.payload[i];
        start_item(it);
        finish_item(it);
    endtask

endclass : pcie_tlp_verbatim_seq


// Randomized TLP stream over a chosen BAR set. Used by the demux tests to prove
// every BAR reaches exactly the port that owns it.
class pcie_tlp_random_seq extends mqnic_base_seq #(pcie_tlp_item);

    `uvm_object_utils(pcie_tlp_random_seq)

    rand int unsigned n_tlps;
    rand bit [2:0]    bar_lo;
    rand bit [2:0]    bar_hi;
    rand int unsigned max_payload;

    constraint c_defaults {
        soft n_tlps      inside {[16:64]};
        soft bar_lo      == 0;
        soft bar_hi      == 3;
        soft max_payload == 64;
        bar_hi >= bar_lo;
        max_payload % 4 == 0;
        max_payload <= 256;
    }

    function new(string name = "pcie_tlp_random_seq");
        super.new(name);
    endfunction

    virtual task body();
        pcie_tlp_item it;
        for (int i = 0; i < int'(n_tlps); i++) begin
            if (stop_requested()) break;
            it = pcie_tlp_item::type_id::create($sformatf("tlp%0d", i));
            start_item(it);
            if (!it.randomize() with {
                    bar_id inside {[local::bar_lo : local::bar_hi]};
                    payload.size() <= local::max_payload;
                })
                `uvm_fatal(get_type_name(), "randomize failed")
            finish_item(it);
        end
    endtask

endclass : pcie_tlp_random_seq


// Sweeps payload length across beat boundaries. At 256 bits a beat is 32 bytes,
// so 0..96 covers header-only, part-beat, exact-beat and multi-beat TLPs.
class pcie_tlp_len_sweep_seq extends mqnic_base_seq #(pcie_tlp_item);

    `uvm_object_utils(pcie_tlp_len_sweep_seq)

    rand bit [2:0]    bar_id;
    rand int unsigned max_bytes;

    constraint c_defaults {
        soft bar_id    == 0;
        soft max_bytes == 96;
        max_bytes % 4 == 0;
    }

    function new(string name = "pcie_tlp_len_sweep_seq");
        super.new(name);
    endfunction

    virtual task body();
        pcie_tlp_item it;
        for (int len = 0; len <= int'(max_bytes); len += 4) begin
            if (stop_requested()) break;
            it = pcie_tlp_item::type_id::create($sformatf("len%0d", len));
            start_item(it);
            if (!it.randomize() with {
                    bar_id == local::bar_id;
                    payload.size() == len;
                })
                `uvm_fatal(get_type_name(), "randomize failed")
            finish_item(it);
        end
    endtask

endclass : pcie_tlp_len_sweep_seq

`endif // PCIE_TLP_AGENT_SV

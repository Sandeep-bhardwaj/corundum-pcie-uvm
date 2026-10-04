// SPDX-License-Identifier: BSD-2-Clause-Views
//
// axis_sequencer / axis_agent / axis_seq_lib
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.3, §12.1 Level 0
// Introduced : Step 3 (Tier 1c); reused at Tiers 2, 5, 6 (§5.1)
// -----------------------------------------------------------------------------

`ifndef AXIS_AGENT_SV
`define AXIS_AGENT_SV

typedef uvm_sequencer #(axis_item) axis_sequencer;

class axis_agent extends uvm_agent;

    `uvm_component_utils(axis_agent)

    axis_cfg         cfg;

    axis_sequencer   sequencer;
    axis_driver      driver;
    axis_sink_driver sink_driver;
    axis_monitor     monitor;

    uvm_analysis_port #(axis_item) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db #(axis_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "no axis_cfg in config_db under key 'cfg'")
        uvm_config_db #(axis_cfg)::set(this, "*", "cfg", cfg);

        monitor = axis_monitor::type_id::create("monitor", this);

        case (cfg.mode)
            MODE_ACTIVE_MASTER: begin
                sequencer = axis_sequencer::type_id::create("sequencer", this);
                driver    = axis_driver::type_id::create("driver", this);
            end
            MODE_ACTIVE_SLAVE:
                sink_driver = axis_sink_driver::type_id::create("sink_driver", this);
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

endclass : axis_agent


// =============================================================================
// Sequence library (Level 0)
// =============================================================================

// Send one packet with caller-supplied bytes.
class axis_packet_seq extends mqnic_base_seq #(axis_item);

    `uvm_object_utils(axis_packet_seq)

    byte unsigned payload [];
    rand bit [127:0] user;
    rand int unsigned delay_start;

    constraint c_defaults {
        soft user        == '0;
        soft delay_start inside {[0:5]};
    }

    function new(string name = "axis_packet_seq");
        super.new(name);
    endfunction

    virtual task body();
        axis_item it;
        it = axis_item::type_id::create("it");
        start_item(it);
        it.data        = new[payload.size()];
        foreach (payload[i]) it.data[i] = payload[i];
        it.user        = user;
        it.delay_start = delay_start;
        it.gap_pct     = 0;
        finish_item(it);
    endtask

endclass : axis_packet_seq


// Randomized packet stream over a length window.
class axis_random_seq extends mqnic_base_seq #(axis_item);

    `uvm_object_utils(axis_random_seq)

    rand int unsigned n_pkts;
    rand int unsigned len_lo;
    rand int unsigned len_hi;

    constraint c_defaults {
        soft n_pkts inside {[8:32]};
        soft len_lo == 60;
        soft len_hi == 512;
        len_hi >= len_lo;
        len_lo > 0;
    }

    function new(string name = "axis_random_seq");
        super.new(name);
    endfunction

    virtual task body();
        axis_item it;
        for (int i = 0; i < int'(n_pkts); i++) begin
            if (stop_requested()) break;
            it = axis_item::type_id::create($sformatf("pkt%0d", i));
            start_item(it);
            // Two comparisons rather than `inside {[len_lo:len_hi]}`: Vivado xsim
            // cannot simulate `inside` on size() with variable bounds (XSIM 43-3980).
            if (!it.randomize() with {
                    data.size() >= local::len_lo;
                    data.size() <= local::len_hi;
                })
                `uvm_fatal(get_type_name(), "randomize failed")
            finish_item(it);
        end
    endtask

endclass : axis_random_seq


// -----------------------------------------------------------------------------
// Length sweep. Walks every length in a window so off-by-one handling at beat
// boundaries is exercised deterministically rather than left to chance - the
// odd-length case in particular decides whether the checksum pads correctly.
// -----------------------------------------------------------------------------
class axis_len_sweep_seq extends mqnic_base_seq #(axis_item);

    `uvm_object_utils(axis_len_sweep_seq)

    rand int unsigned len_lo;
    rand int unsigned len_hi;

    constraint c_defaults {
        soft len_lo == 15;
        soft len_hi == 80;
        len_hi >= len_lo;
        len_lo > 0;
    }

    function new(string name = "axis_len_sweep_seq");
        super.new(name);
    endfunction

    virtual task body();
        axis_item it;
        for (int len = int'(len_lo); len <= int'(len_hi); len++) begin
            if (stop_requested()) break;
            it = axis_item::type_id::create($sformatf("len%0d", len));
            start_item(it);
            if (!it.randomize() with { data.size() == len; })
                `uvm_fatal(get_type_name(), "randomize failed")
            finish_item(it);
        end
    endtask

endclass : axis_len_sweep_seq

`endif // AXIS_AGENT_SV

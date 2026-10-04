// SPDX-License-Identifier: BSD-2-Clause-Views
//
// pcie_us_axis_sequencer / pcie_us_axis_agent / sequence library
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.6, §12.1 Level 0, §14.4
// Introduced : Step 6 (Tier 4)
// -----------------------------------------------------------------------------

`ifndef PCIE_US_AXIS_AGENT_SV
`define PCIE_US_AXIS_AGENT_SV

typedef uvm_sequencer #(pcie_us_axis_item) pcie_us_axis_sequencer;

class pcie_us_axis_agent extends uvm_agent;

    `uvm_component_utils(pcie_us_axis_agent)

    pcie_us_axis_cfg          cfg;

    pcie_us_axis_sequencer    sequencer;
    pcie_us_axis_driver       driver;        // MODE_ACTIVE_MASTER - RC, CQ
    pcie_us_axis_sink_driver  sink_driver;   // MODE_ACTIVE_SLAVE  - RQ, CC
    pcie_us_axis_monitor      monitor;

    uvm_analysis_port #(pcie_us_axis_item) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(pcie_us_axis_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "no pcie_us_axis_cfg in config_db under key cfg")
        uvm_config_db #(pcie_us_axis_cfg)::set(this, "*", "cfg", cfg);

        monitor = pcie_us_axis_monitor::type_id::create("monitor", this);

        case (cfg.mode)
            MODE_ACTIVE_MASTER: begin
                sequencer = pcie_us_axis_sequencer::type_id::create("sequencer", this);
                driver    = pcie_us_axis_driver::type_id::create("driver", this);
            end
            MODE_ACTIVE_SLAVE:
                sink_driver = pcie_us_axis_sink_driver::type_id::create("sink_driver", this);
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

    // A TLP held back to be straddled with the next one still counts as work.
    // Sequence completion is not traffic completion - the Tier 2 lesson.
    virtual function int unsigned pending_items();
        return (driver == null) ? 0 : driver.pending_items();
    endfunction

    virtual function bit is_idle();
        return (pending_items() == 0);
    endfunction

endclass : pcie_us_axis_agent


// =============================================================================
// Sequence library (Level 0)
// =============================================================================

// One TLP, caller-supplied DWORDs.
class pcie_us_axis_single_seq extends mqnic_base_seq #(pcie_us_axis_item);

    `uvm_object_utils(pcie_us_axis_single_seq)

    bit [31:0]        dwords [];
    rand bit [3:0]    first_be;
    rand bit [3:0]    last_be;
    rand bit [5:0]    seq_num;
    rand int unsigned delay;

    constraint c_defaults {
        soft first_be == 4'hF;
        soft last_be  == 4'hF;
        soft delay    inside {[0:4]};
    }

    function new(string name = "pcie_us_axis_single_seq");
        super.new(name);
    endfunction

    virtual task body();
        pcie_us_axis_item it;
        it = pcie_us_axis_item::type_id::create("it");
        start_item(it);
        it.dwords = new[dwords.size()];
        foreach (dwords[i]) it.dwords[i] = dwords[i];
        it.first_be   = first_be;
        it.last_be    = last_be;
        it.seq_num    = seq_num;
        it.start_lane = 0;
        it.delay      = delay;
        finish_item(it);
    endtask

endclass : pcie_us_axis_single_seq


// -----------------------------------------------------------------------------
// Lengths that land on and either side of a beat boundary.
//
// At 256 bits a beat is 8 DWORDs. A TLP of exactly 8 fills a beat and cannot
// straddle; 5..7 leaves a gap a second TLP can start in. Sweeping across that
// boundary is what makes the driver's straddle decision vary, which is the
// §14.4 sop_position axis.
// -----------------------------------------------------------------------------
class pcie_us_axis_len_sweep_seq extends mqnic_base_seq #(pcie_us_axis_item);

    `uvm_object_utils(pcie_us_axis_len_sweep_seq)

    rand int unsigned min_dw;
    rand int unsigned max_dw;

    constraint c_defaults {
        soft min_dw == 3;
        soft max_dw == 20;
        max_dw >= min_dw;
    }

    function new(string name = "pcie_us_axis_len_sweep_seq");
        super.new(name);
    endfunction

    virtual task body();
        pcie_us_axis_item it;
        for (int n = int'(min_dw); n <= int'(max_dw); n++) begin
            if (stop_requested()) break;
            it = pcie_us_axis_item::type_id::create($sformatf("dw%0d", n));
            start_item(it);
            it.dwords = new[n];
            foreach (it.dwords[i]) it.dwords[i] = {16'(n), 16'(i)};
            it.first_be   = 4'hF;
            it.last_be    = 4'hF;
            it.start_lane = 0;
            it.delay      = 0;
            finish_item(it);
        end
    endtask

endclass : pcie_us_axis_len_sweep_seq


// -----------------------------------------------------------------------------
// Randomized stream. Lengths are biased SHORT on purpose: short TLPs are the
// ones that leave room for a partner in the beat, and a stream of long TLPs
// never straddles - so it never exercises what Tier 4 exists to test.
// -----------------------------------------------------------------------------
class pcie_us_axis_random_seq extends mqnic_base_seq #(pcie_us_axis_item);

    `uvm_object_utils(pcie_us_axis_random_seq)

    rand int unsigned n_tlps;
    rand int unsigned max_dw;

    constraint c_defaults {
        soft n_tlps inside {[16:64]};
        soft max_dw == 24;
        max_dw >= 4;
    }

    function new(string name = "pcie_us_axis_random_seq");
        super.new(name);
    endfunction

    virtual task body();
        pcie_us_axis_item it;
        int unsigned n;
        for (int i = 0; i < int'(n_tlps); i++) begin
            if (stop_requested()) break;
            n = ($urandom_range(0, 9) < 6) ? $urandom_range(3, 8)
                                           : $urandom_range(9, max_dw);
            it = pcie_us_axis_item::type_id::create($sformatf("tlp%0d", i));
            start_item(it);
            it.dwords = new[n];
            foreach (it.dwords[j]) it.dwords[j] = {16'(i), 16'(j)};
            it.first_be   = 4'hF;
            it.last_be    = 4'hF;
            it.start_lane = 0;
            it.delay      = $urandom_range(0, 3);
            finish_item(it);
        end
    endtask

endclass : pcie_us_axis_random_seq

`endif // PCIE_US_AXIS_AGENT_SV

// SPDX-License-Identifier: BSD-2-Clause-Views
//
// axil_sequencer / axil_agent - AXI4-Lite agent
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.1 (three modes), §5.1 (reuse)
// Introduced : Step 1 (Tier 1a); reused at Tiers 3, 5, 6
// -----------------------------------------------------------------------------

`ifndef AXIL_AGENT_SV
`define AXIL_AGENT_SV

typedef uvm_sequencer #(axil_item) axil_sequencer;

class axil_agent extends uvm_agent;

    `uvm_component_utils(axil_agent)

    axil_cfg          cfg;

    axil_sequencer    sequencer;
    axil_driver       driver;        // MODE_ACTIVE_MASTER
    axil_slave_driver slave_driver;  // MODE_ACTIVE_SLAVE
    axil_monitor      monitor;       // always present

    // Convenience re-export so an environment can connect without reaching
    // into the monitor.
    uvm_analysis_port #(axil_item) ap;
    uvm_analysis_port #(axil_item) wr_ap;
    uvm_analysis_port #(axil_item) rd_ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db #(axil_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "no axil_cfg in config_db under key 'cfg'")

        // Push cfg down so driver and monitor need no separate registration.
        uvm_config_db #(axil_cfg)::set(this, "*", "cfg", cfg);

        monitor = axil_monitor::type_id::create("monitor", this);

        case (cfg.mode)
            MODE_ACTIVE_MASTER: begin
                sequencer = axil_sequencer::type_id::create("sequencer", this);
                driver    = axil_driver::type_id::create("driver", this);
            end
            MODE_ACTIVE_SLAVE: begin
                slave_driver = axil_slave_driver::type_id::create("slave_driver", this);
            end
            MODE_PASSIVE: begin
                // monitor only
            end
            default:
                `uvm_fatal(get_type_name(), $sformatf("bad mode %s", cfg.mode.name()))
        endcase
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        ap    = monitor.ap;
        wr_ap = monitor.wr_ap;
        rd_ap = monitor.rd_ap;

        if (cfg.mode == MODE_ACTIVE_MASTER)
            driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction

    // Backdoor helpers, valid in slave mode only. Used by Tier 5/6 tests to
    // pre-load CSR space before the DUT reads it.
    virtual function void poke(bit [63:0] addr, bit [63:0] data);
        if (slave_driver == null)
            `uvm_fatal(get_type_name(), "poke() requires MODE_ACTIVE_SLAVE")
        slave_driver.poke(addr, data);
    endfunction

    virtual function bit [63:0] peek(bit [63:0] addr);
        if (slave_driver == null)
            `uvm_fatal(get_type_name(), "peek() requires MODE_ACTIVE_SLAVE")
        return slave_driver.peek(addr);
    endfunction

endclass : axil_agent

`endif // AXIL_AGENT_SV

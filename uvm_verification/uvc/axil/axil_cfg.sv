// SPDX-License-Identifier: BSD-2-Clause-Views
//
// axil_cfg - AXI4-Lite agent configuration
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.1 (config fields), §4.3 rule 1
// Introduced : Step 1 (Tier 1a)
//
// Carries the real bus widths into the width-agnostic agent, plus the operating
// mode. STRATEGY §7.1 requires three modes; MODE_ACTIVE_SLAVE exists because
// several DUT interfaces have the DUT as master (m_axil_csr_* on
// mqnic_core_pcie) and the agent must respond rather than initiate.
// -----------------------------------------------------------------------------

`ifndef AXIL_CFG_SV
`define AXIL_CFG_SV

class axil_cfg extends uvm_object;

    // ---- topology -----------------------------------------------------------
    mqnic_agent_mode_e mode = MODE_ACTIVE_MASTER;

    // ---- bus geometry -------------------------------------------------------
    // Defaults match the Tier 1a DUT: queue_manager with QUEUE_INDEX_WIDTH=13
    // gives AXIL_ADDR_WIDTH = 13+5 = 18, AXIL_DATA_WIDTH = 32.
    int unsigned addr_width = 18;
    int unsigned data_width = 32;

    // ---- driver shaping -----------------------------------------------------
    mqnic_bp_profile_e bp_profile = BP_RANDOM;

    // Slave mode: probability (percent) of answering with an error response.
    // Zero by default; error-injection tests raise it.
    int unsigned slverr_rate_pct = 0;
    int unsigned decerr_rate_pct = 0;

    // Slave mode: fixed extra latency, in clocks, before responding.
    int unsigned slave_min_latency = 0;
    int unsigned slave_max_latency = 3;

    // ---- checking -----------------------------------------------------------
    bit enable_coverage = 1'b1;

    // Reads to an address never written return this. Made explicit so a
    // scoreboard mismatch on unwritten memory is unambiguous rather than X.
    bit [63:0] slave_default_data = 64'hDEAD_BEEF_DEAD_BEEF;

    `uvm_object_utils_begin(axil_cfg)
        `uvm_field_enum(mqnic_agent_mode_e, mode,       UVM_ALL_ON)
        `uvm_field_int (addr_width,                     UVM_ALL_ON | UVM_DEC)
        `uvm_field_int (data_width,                     UVM_ALL_ON | UVM_DEC)
        `uvm_field_enum(mqnic_bp_profile_e, bp_profile, UVM_ALL_ON)
        `uvm_field_int (slverr_rate_pct,                UVM_ALL_ON | UVM_DEC)
        `uvm_field_int (decerr_rate_pct,                UVM_ALL_ON | UVM_DEC)
        `uvm_field_int (slave_min_latency,              UVM_ALL_ON | UVM_DEC)
        `uvm_field_int (slave_max_latency,              UVM_ALL_ON | UVM_DEC)
        `uvm_field_int (enable_coverage,                UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "axil_cfg");
        super.new(name);
    endfunction

    function int unsigned strb_width();
        return data_width / 8;
    endfunction

    function bit [63:0] addr_mask();
        return (addr_width >= 64) ? 64'hFFFF_FFFF_FFFF_FFFF
                                  : ((64'd1 << addr_width) - 64'd1);
    endfunction

    function bit [63:0] data_mask();
        return (data_width >= 64) ? 64'hFFFF_FFFF_FFFF_FFFF
                                  : ((64'd1 << data_width) - 64'd1);
    endfunction

    function bit [7:0] strb_mask();
        return 8'((16'd1 << strb_width()) - 16'd1);
    endfunction

    function bit is_active();
        return (mode != MODE_PASSIVE);
    endfunction

endclass : axil_cfg

`endif // AXIL_CFG_SV

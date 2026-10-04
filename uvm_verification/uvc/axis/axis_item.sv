// SPDX-License-Identifier: BSD-2-Clause-Views
//
// axis_item / axis_cfg - AXI4-Stream transaction and configuration
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.3
// Introduced : Step 3 (Tier 1c)
//
// The item is a PACKET, not a beat. Beat-level detail (how many bytes land in
// each cycle, where the gaps are) is a driver concern shaped by the delay
// fields; the scoreboard compares payloads. This is what lets the same item
// serve a 32-bit Tier 1c DUT and a 512-bit Tier 6 Ethernet port.
// -----------------------------------------------------------------------------

`ifndef AXIS_ITEM_SV
`define AXIS_ITEM_SV

class axis_item extends uvm_sequence_item;

    // ---- payload ------------------------------------------------------------
    rand byte unsigned data [];

    // ---- sideband, sampled on the last beat ---------------------------------
    rand bit [127:0] user;
    rand bit [7:0]   id;
    rand bit [7:0]   dest;

    // ---- timing shaping -----------------------------------------------------
    // Idle cycles before the packet starts, and the probability of inserting a
    // bubble between beats. Both matter: a DUT that only works back-to-back is
    // a real bug, and one that only works with gaps is a different real bug.
    rand int unsigned delay_start;
    rand int unsigned gap_pct;

    // ---- observation --------------------------------------------------------
    time             start_time;
    time             end_time;

    `uvm_object_utils_begin(axis_item)
        `uvm_field_array_int(data,     UVM_ALL_ON | UVM_HEX)
        `uvm_field_int      (user,     UVM_ALL_ON | UVM_HEX)
        `uvm_field_int      (id,       UVM_ALL_ON | UVM_HEX)
        `uvm_field_int      (dest,     UVM_ALL_ON | UVM_HEX)
        `uvm_field_int      (delay_start, UVM_ALL_ON | UVM_DEC | UVM_NOCOMPARE)
        `uvm_field_int      (gap_pct,     UVM_ALL_ON | UVM_DEC | UVM_NOCOMPARE)
    `uvm_object_utils_end

    constraint c_size {
        soft data.size() inside {[60:1514]};    // ordinary Ethernet range
    }

    constraint c_timing {
        delay_start dist { 0 := 60, [1:5] := 30, [6:30] := 10 };
        gap_pct     dist { 0 := 50, [1:25] := 35, [26:75] := 15 };
        gap_pct <= 100;
    }

    constraint c_sideband {
        soft user == '0;
        soft id   == '0;
        soft dest == '0;
    }

    function new(string name = "axis_item");
        super.new(name);
    endfunction

    virtual function string convert2string();
        return $sformatf("AXIS len=%0d user=0x%0h data=%s",
                         data.size(), user,
                         mqnic_vrf_pkg::bytes2str(data, 32));
    endfunction

endclass : axis_item


class axis_cfg extends uvm_object;

    mqnic_agent_mode_e mode = MODE_ACTIVE_MASTER;   // MASTER drives, SLAVE sinks

    // Bus geometry. Defaults match the Tier 1c DUTs.
    int unsigned data_width = 256;

    // -------------------------------------------------------------------------
    // has_tready = 0 for rx_checksum / rx_hash, whose AXI-S inputs have NO
    // tready (verified against the RTL). With it clear:
    //   * the driver never waits for a handshake - it presents one beat per
    //     clock and moves on
    //   * the monitor qualifies on tvalid ALONE, sampling every cycle
    // Getting this wrong drops every beat, exactly like the queue_manager
    // doorbell case (STRATEGY §7.8).
    // -------------------------------------------------------------------------
    bit has_tready = 1'b1;
    bit has_tlast  = 1'b1;
    bit has_tkeep  = 1'b1;

    mqnic_bp_profile_e bp_profile      = BP_RANDOM;
    bit                enable_coverage = 1'b1;

    // Source line rate in Gb/s; 0 = one beat per clock. A MAC never presents
    // data faster than its line rate, even inside a frame: a 512-bit bus at
    // 3.1 ns carries 165 Gb/s, so a 100G MAC leaves ~40% of beats idle. With
    // the rate set, the driver holds each beat until the line has carried the
    // previous ones, and charges ifg_bytes (preamble + SFD + minimum gap) per
    // frame - the pacing upstream's EthMac applies (speed, ifg=12).
    real               line_rate_gbps  = 0.0;
    int unsigned       ifg_bytes       = 20;

    `uvm_object_utils_begin(axis_cfg)
        `uvm_field_enum(mqnic_agent_mode_e, mode,       UVM_ALL_ON)
        `uvm_field_int (data_width,                     UVM_ALL_ON | UVM_DEC)
        `uvm_field_int (has_tready,                     UVM_ALL_ON | UVM_BIN)
        `uvm_field_int (has_tlast,                      UVM_ALL_ON | UVM_BIN)
        `uvm_field_int (has_tkeep,                      UVM_ALL_ON | UVM_BIN)
        `uvm_field_enum(mqnic_bp_profile_e, bp_profile, UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "axis_cfg");
        super.new(name);
    endfunction

    function int unsigned keep_width();
        return data_width / 8;
    endfunction

    function bit is_active();
        return (mode != MODE_PASSIVE);
    endfunction

endclass : axis_cfg

`endif // AXIS_ITEM_SV

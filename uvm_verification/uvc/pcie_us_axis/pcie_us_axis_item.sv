// SPDX-License-Identifier: BSD-2-Clause-Views
//
// pcie_us_axis_item / pcie_us_axis_cfg
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.6
// Introduced : Step 6 (Tier 4)
//
// THE ITEM IS ONE TLP, NOT ONE BEAT. On a straddling channel a beat may carry
// the tail of one TLP and the head of the next, so a beat is not a transaction
// boundary - the same argument that made dma_ram_item per-segment at Tier 2.
//
// The Xilinx side carries the TLP as a DESCRIPTOR IN THE FIRST DWORDS OF THE
// PAYLOAD, not as a separate header bus. That is the whole point of Tier 4: the
// shim converts between that layout and the generic 128-bit tlp_hdr the rest of
// the environment already understands. The item therefore holds the raw DWORD
// stream; ref_tlp_shim is what interprets it.
// -----------------------------------------------------------------------------

`ifndef PCIE_US_AXIS_ITEM_SV
`define PCIE_US_AXIS_ITEM_SV

class pcie_us_axis_item extends uvm_sequence_item;

    // The complete TLP as it appears on the wire, DWORD by DWORD: Xilinx
    // descriptor first, then payload.
    rand bit [31:0] dwords [];

    // Byte enables, only meaningful on RQ and CQ.
    rand bit [3:0]  first_be;
    rand bit [3:0]  last_be;

    // Sequence number (RQ) - 6 bits at the mqnic width, and SPLIT across two
    // tuser fields. See us_rq_seq_num().
    rand bit [5:0]  seq_num;

    // Where this TLP started within its first beat, in 32-bit lanes. Only
    // non-zero on a straddling channel, and constrained to a 128-bit boundary.
    rand int unsigned start_lane;

    rand int unsigned delay;

    // ---- observation --------------------------------------------------------
    time         start_time;
    time         end_time;
    bit          straddled;    // shared a beat with another TLP
    bit          discontinue;

    `uvm_object_utils_begin(pcie_us_axis_item)
        `uvm_field_array_int(dwords,     UVM_ALL_ON | UVM_HEX)
        `uvm_field_int      (first_be,   UVM_ALL_ON | UVM_HEX)
        `uvm_field_int      (last_be,    UVM_ALL_ON | UVM_HEX)
        `uvm_field_int      (seq_num,    UVM_ALL_ON | UVM_HEX)
        `uvm_field_int      (start_lane, UVM_ALL_ON | UVM_DEC | UVM_NOCOMPARE)
        `uvm_field_int      (delay,      UVM_ALL_ON | UVM_DEC | UVM_NOCOMPARE)
        `uvm_field_int      (straddled,  UVM_ALL_ON | UVM_BIN | UVM_NOCOMPARE)
        `uvm_field_int      (discontinue,UVM_ALL_ON | UVM_BIN)
    `uvm_object_utils_end

    // A TLP is at least its descriptor: 3 DWORDs for RC, 4 for RQ/CQ/CC.
    constraint c_size {
        soft dwords.size() inside {[3:64]};
        dwords.size() >= 3;
    }

    // STRADDLE SLOTS ARE QUANTISED TO 128 BITS. A TLP may begin only on a
    // multiple of 4 lanes; is_sop_ptr is 2 bits and is multiplied by 4
    // (pcie_us_if_rc.v:301). Stimulus starting at lane 1 is not representable,
    // so generating it would be illegal traffic rather than a harder test.
    constraint c_start_lane {
        start_lane % mqnic_vrf_pkg::US_STRADDLE_LANE_STEP == 0;
        start_lane < mqnic_vrf_pkg::US_MAX_KEEP_WIDTH;
        soft start_lane == 0;
    }

    constraint c_be {
        soft first_be == 4'hF;
        soft last_be  == 4'hF;
    }

    constraint c_delay {
        delay dist { 0 := 70, [1:3] := 20, [4:15] := 10 };
    }

    function new(string name = "pcie_us_axis_item");
        super.new(name);
    endfunction

    // Payload bytes, i.e. everything after the descriptor.
    virtual function int unsigned payload_dwords(int unsigned desc_dw);
        return (dwords.size() > desc_dw) ? (dwords.size() - desc_dw) : 0;
    endfunction

    virtual function string convert2string();
        return $sformatf("US_AXIS %0d DW start_lane=%0d be=%01h/%01h seq=%0d%s",
                         dwords.size(), start_lane, first_be, last_be, seq_num,
                         straddled ? " STRADDLED" : "");
    endfunction

endclass : pcie_us_axis_item


class pcie_us_axis_cfg extends uvm_object;

    mqnic_agent_mode_e  mode    = MODE_ACTIVE_MASTER;
    mqnic_us_channel_e  channel = PCIE_CH_RC;

    // Golden configuration: mqnic_core_pcie_us.v:157 builds at 256.
    int unsigned data_width = 256;

    mqnic_bp_profile_e bp_profile      = BP_RANDOM;
    bit                enable_coverage = 1'b1;

    // How long the driver may hold a TLP waiting for a straddle partner.
    //
    // Zero would flush on the first idle cycle, and that destroys straddling
    // entirely: a test that interleaves two channels leaves the sequencer
    // momentarily empty between every pair of items, so the partner never
    // arrives in time. Bug 18 - the fix for the end-of-burst deadlock
    // overshot into exactly that.
    //
    // Too long and drain gets slow. 16 cycles is comfortably longer than the
    // gap a back-to-back sequence leaves and far shorter than any drain-wait.
    int unsigned straddle_hold_cycles = 16;

    `uvm_object_utils_begin(pcie_us_axis_cfg)
        `uvm_field_enum(mqnic_agent_mode_e,  mode,    UVM_ALL_ON)
        `uvm_field_enum(mqnic_us_channel_e,  channel, UVM_ALL_ON)
        `uvm_field_int (data_width,                   UVM_ALL_ON | UVM_DEC)
        `uvm_field_enum(mqnic_bp_profile_e,  bp_profile, UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "pcie_us_axis_cfg");
        super.new(name);
    endfunction

    // Derived from the RTL's own rules rather than set by hand, so a testbench
    // cannot pick a mismatched width/straddle pair.
    function int unsigned user_width();
        return mqnic_vrf_pkg::us_user_width(channel, data_width);
    endfunction

    function bit straddles();
        return mqnic_vrf_pkg::us_straddles(channel, data_width);
    endfunction

    function int unsigned keep_width();
        return data_width / 32;
    endfunction

    // Descriptor length in DWORDs. RC's completion descriptor is 3 DWORDs; the
    // request and completer channels use 4.
    function int unsigned desc_dwords();
        return (channel == PCIE_CH_RC) ? 3 : 4;
    endfunction

    // Which side the TESTBENCH drives. RC and CQ flow host -> DUT, so the TB is
    // the source; RQ and CC flow DUT -> host, so the TB sinks.
    function bit tb_is_source();
        return (channel == PCIE_CH_RC || channel == PCIE_CH_CQ);
    endfunction

    function bit is_active();
        return (mode != MODE_PASSIVE);
    endfunction

endclass : pcie_us_axis_cfg

`endif // PCIE_US_AXIS_ITEM_SV

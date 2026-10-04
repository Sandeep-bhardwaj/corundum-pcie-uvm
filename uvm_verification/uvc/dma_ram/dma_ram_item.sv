// SPDX-License-Identifier: BSD-2-Clause-Views
//
// dma_ram_item / dma_ram_cfg
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.4
// Introduced : Step 4 (Tier 2)
//
// THE ITEM IS ONE SEGMENT OPERATION, not one bus cycle. That is the crux of
// this UVC: the segments are independent channels, so a "cycle" is not a
// meaningful transaction boundary - on any given clock an arbitrary subset of
// segments may be active, each with its own ready. Making the item per-segment
// lets the driver run genuinely concurrent per-segment servers and lets the
// monitor report exactly what each channel did.
// -----------------------------------------------------------------------------

`ifndef DMA_RAM_ITEM_SV
`define DMA_RAM_ITEM_SV

// Which half of the interface this agent owns.
//
// dma_psdpram_async has SEPARATE write and read clock domains (clk_wr / clk_rd),
// so a single agent cannot cover both: a virtual interface carries one clock.
// The async DUT therefore gets two agents, one per domain, each restricted to
// its own channels. The synchronous dma_psdpram uses DMA_RAM_CH_BOTH.
typedef enum {
    DMA_RAM_CH_BOTH,
    DMA_RAM_CH_WR_ONLY,
    DMA_RAM_CH_RD_ONLY
} dma_ram_channels_e;


typedef enum {
    DMA_RAM_WRITE,      // driven  : wr_cmd on one segment
    DMA_RAM_READ,       // driven  : rd_cmd on one segment
    DMA_RAM_WR_DONE,    // observed: wr_done pulse on one segment
    DMA_RAM_RD_DATA     // observed: rd_resp on one segment
} dma_ram_kind_e;


class dma_ram_item extends uvm_sequence_item;

    rand dma_ram_kind_e kind;
    rand int unsigned   seg;          // which segment this operation uses
    rand bit [15:0]     addr;
    rand bit [255:0]    data;
    rand bit [31:0]     be;
    rand bit [7:0]      sel;

    // Idle cycles before this segment presents the command.
    rand int unsigned   delay;

    time                stamp;

    `uvm_object_utils_begin(dma_ram_item)
        `uvm_field_enum(dma_ram_kind_e, kind, UVM_ALL_ON)
        `uvm_field_int (seg,   UVM_ALL_ON | UVM_DEC)
        `uvm_field_int (addr,  UVM_ALL_ON | UVM_HEX)
        `uvm_field_int (data,  UVM_ALL_ON | UVM_HEX)
        `uvm_field_int (be,    UVM_ALL_ON | UVM_HEX)
        `uvm_field_int (sel,   UVM_ALL_ON | UVM_HEX)
        `uvm_field_int (delay, UVM_ALL_ON | UVM_DEC | UVM_NOCOMPARE)
    `uvm_object_utils_end

    constraint c_defaults {
        soft be  == 32'hFFFF_FFFF;    // full-width write unless a test narrows it
        soft sel == 8'h00;
        delay dist { 0 := 70, [1:3] := 20, [4:12] := 10 };
    }

    function new(string name = "dma_ram_item");
        super.new(name);
    endfunction

    virtual function string convert2string();
        case (kind)
            DMA_RAM_WRITE:   return $sformatf("WR   seg=%0d addr=0x%0h be=0x%0h data=0x%0h",
                                              seg, addr, be, data);
            DMA_RAM_READ:    return $sformatf("RD   seg=%0d addr=0x%0h", seg, addr);
            DMA_RAM_WR_DONE: return $sformatf("DONE seg=%0d", seg);
            DMA_RAM_RD_DATA: return $sformatf("DATA seg=%0d data=0x%0h", seg, data);
            default:         return "?";
        endcase
    endfunction

endclass : dma_ram_item


class dma_ram_cfg extends uvm_object;

    // INITIATOR drives commands (Tier 2, testing the RAM).
    // RESPONDER models the RAM (Tier 3, where the DUT is the initiator).
    mqnic_agent_mode_e mode = MODE_ACTIVE_MASTER;

    // Which channels this agent drives and monitors. See dma_ram_channels_e.
    dma_ram_channels_e channels = DMA_RAM_CH_BOTH;

    // Geometry. Defaults match dma_psdpram's own defaults.
    int unsigned seg_count      = 2;
    int unsigned seg_data_width = 128;
    int unsigned seg_addr_width = 7;     // $clog2(4096/(2*16))
    int unsigned sel_width      = 0;
    bit          has_sel        = 1'b0;  // absent on plain dma_psdpram

    // Latency the RESPONDER adds before wr_done and rd_resp.
    int unsigned resp_min_latency = 1;
    int unsigned resp_max_latency = 3;

    // -------------------------------------------------------------------------
    // Backpressure is chosen PER SEGMENT, independently. STRATEGY §7.4 makes
    // this a hard requirement: a shared profile lets every segment stall in
    // lockstep, which is the one pattern that will never expose a per-segment
    // bug in the DUT.
    // -------------------------------------------------------------------------
    mqnic_bp_profile_e bp_profile [8];

    bit enable_coverage = 1'b1;

    `uvm_object_utils_begin(dma_ram_cfg)
        `uvm_field_enum(mqnic_agent_mode_e, mode,     UVM_ALL_ON)
        `uvm_field_enum(dma_ram_channels_e, channels, UVM_ALL_ON)
        `uvm_field_int (seg_count,        UVM_ALL_ON | UVM_DEC)
        `uvm_field_int (seg_data_width,   UVM_ALL_ON | UVM_DEC)
        `uvm_field_int (seg_addr_width,   UVM_ALL_ON | UVM_DEC)
        `uvm_field_int (sel_width,        UVM_ALL_ON | UVM_DEC)
        `uvm_field_int (has_sel,          UVM_ALL_ON | UVM_BIN)
        `uvm_field_int (resp_min_latency, UVM_ALL_ON | UVM_DEC)
        `uvm_field_int (resp_max_latency, UVM_ALL_ON | UVM_DEC)
    `uvm_object_utils_end

    function new(string name = "dma_ram_cfg");
        super.new(name);
        foreach (bp_profile[i]) bp_profile[i] = BP_RANDOM;
    endfunction

    // Give each segment a different profile, so they cannot stall in lockstep.
    virtual function void stagger_backpressure();
        mqnic_bp_profile_e p [4];
        p[0] = BP_NONE; p[1] = BP_RANDOM; p[2] = BP_AGGRESSIVE; p[3] = BP_BURSTY;
        foreach (bp_profile[i]) bp_profile[i] = p[i % 4];
    endfunction

    function int unsigned seg_be_width();
        return seg_data_width / 8;
    endfunction

    // Total RAM bytes addressable across all segments.
    function longint unsigned ram_bytes();
        return longint'(seg_count) * longint'(seg_be_width()) *
               (longint'(1) << seg_addr_width);
    endfunction

    function bit is_active();
        return (mode != MODE_PASSIVE);
    endfunction

    function bit has_wr();
        return (channels != DMA_RAM_CH_RD_ONLY);
    endfunction

    function bit has_rd();
        return (channels != DMA_RAM_CH_WR_ONLY);
    endfunction

endclass : dma_ram_cfg

`endif // DMA_RAM_ITEM_SV

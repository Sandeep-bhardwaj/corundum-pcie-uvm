// SPDX-License-Identifier: BSD-2-Clause-Views
//
// axil_item - AXI4-Lite transaction item
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.1 (item fields)
// Introduced : Step 1 (Tier 1a)
//
// Maximally-sized fields (STRATEGY §4.3 rule 1): the item is width-agnostic and
// the driver masks to the widths published in axil_cfg. This is what lets the
// same item type serve an 18-bit queue_manager address map and a wider CSR map
// without reparameterizing anything.
// -----------------------------------------------------------------------------

`ifndef AXIL_ITEM_SV
`define AXIL_ITEM_SV

typedef enum bit {
    AXIL_READ  = 1'b0,
    AXIL_WRITE = 1'b1
} axil_kind_e;

// AXI response encoding. AXI-Lite uses OKAY / SLVERR / DECERR; EXOKAY is not
// legal on AXI-Lite and is included only so a DUT emitting it can be flagged.
typedef enum bit [1:0] {
    AXIL_OKAY   = 2'b00,
    AXIL_EXOKAY = 2'b01,
    AXIL_SLVERR = 2'b10,
    AXIL_DECERR = 2'b11
} axil_resp_e;

// Relative ordering of the AW and W channels for a write. AXI places no
// ordering requirement between them, and DUTs regularly assume one. Randomizing
// this is a first-class coverage goal (STRATEGY §7.1).
typedef enum {
    AXIL_AW_FIRST,   // address, then data
    AXIL_W_FIRST,    // data, then address
    AXIL_AW_W_TOGETHER
} axil_wr_order_e;

class axil_item extends uvm_sequence_item;

    // ---- request ------------------------------------------------------------
    rand axil_kind_e                kind;
    rand bit [63:0]                 addr;
    rand bit [63:0]                 data;
    rand bit [7:0]                  strb;
    rand bit [2:0]                  prot;

    // ---- response (filled by driver/monitor) --------------------------------
    axil_resp_e                     resp;

    // ---- timing controls ----------------------------------------------------
    rand int unsigned               delay_aw;   // idle cycles before AW
    rand int unsigned               delay_w;    // idle cycles before W
    rand int unsigned               delay_ar;   // idle cycles before AR
    rand int unsigned               delay_b;    // bready backpressure
    rand int unsigned               delay_r;    // rready backpressure
    rand axil_wr_order_e            wr_order;

    // ---- observation metadata (monitor only) --------------------------------
    time                            start_time;
    time                            end_time;

    `uvm_object_utils_begin(axil_item)
        `uvm_field_enum(axil_kind_e, kind,     UVM_ALL_ON)
        `uvm_field_int (addr,                  UVM_ALL_ON | UVM_HEX)
        `uvm_field_int (data,                  UVM_ALL_ON | UVM_HEX)
        `uvm_field_int (strb,                  UVM_ALL_ON | UVM_HEX)
        `uvm_field_int (prot,                  UVM_ALL_ON | UVM_HEX)
        `uvm_field_enum(axil_resp_e, resp,     UVM_ALL_ON)
        `uvm_field_int (delay_aw,              UVM_ALL_ON | UVM_DEC | UVM_NOCOMPARE)
        `uvm_field_int (delay_w,               UVM_ALL_ON | UVM_DEC | UVM_NOCOMPARE)
        `uvm_field_int (delay_ar,              UVM_ALL_ON | UVM_DEC | UVM_NOCOMPARE)
        `uvm_field_int (delay_b,               UVM_ALL_ON | UVM_DEC | UVM_NOCOMPARE)
        `uvm_field_int (delay_r,               UVM_ALL_ON | UVM_DEC | UVM_NOCOMPARE)
        `uvm_field_enum(axil_wr_order_e, wr_order, UVM_ALL_ON | UVM_NOCOMPARE)
    `uvm_object_utils_end

    // Default delay shaping. Sequences tighten or widen these; the bias toward
    // zero keeps random tests fast while still hitting the stalled cases.
    constraint c_delays {
        delay_aw dist { 0 := 60, [1:3] := 30, [4:15] := 10 };
        delay_w  dist { 0 := 60, [1:3] := 30, [4:15] := 10 };
        delay_ar dist { 0 := 60, [1:3] := 30, [4:15] := 10 };
        delay_b  dist { 0 := 70, [1:3] := 20, [4:15] := 10 };
        delay_r  dist { 0 := 70, [1:3] := 20, [4:15] := 10 };
    }

    constraint c_prot {
        soft prot == 3'b000;
    }

    // AXI-Lite has no bursts, so an all-ones strobe over the active data width
    // is the common case; sub-word strobes are exercised deliberately.
    constraint c_strb {
        soft strb == 8'hFF;
    }

    constraint c_wr_order {
        wr_order dist { AXIL_AW_FIRST := 40,
                        AXIL_W_FIRST  := 30,
                        AXIL_AW_W_TOGETHER := 30 };
    }

    function new(string name = "axil_item");
        super.new(name);
        resp       = AXIL_OKAY;
        start_time = 0;
        end_time   = 0;
    endfunction

    virtual function string convert2string();
        if (kind == AXIL_WRITE)
            return $sformatf("WR addr=0x%0h data=0x%0h strb=0x%0h resp=%s",
                             addr, data, strb, resp.name());
        else
            return $sformatf("RD addr=0x%0h data=0x%0h resp=%s",
                             addr, data, resp.name());
    endfunction

    virtual function bit is_error();
        return (resp != AXIL_OKAY);
    endfunction

endclass : axil_item

`endif // AXIL_ITEM_SV

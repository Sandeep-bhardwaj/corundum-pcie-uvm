// SPDX-License-Identifier: BSD-2-Clause-Views
//
// axil_seq_lib - AXI4-Lite sequence library
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §12.1 Level 0 (UVC item sequences)
// Introduced : Step 1 (Tier 1a)
//
// Level 0 sequences only: single accesses and simple randomized streams. Higher
// layers (RAL access, driver model, virtual sequences) build on these and live
// in seq/ rather than here.
// -----------------------------------------------------------------------------

`ifndef AXIL_SEQ_LIB_SV
`define AXIL_SEQ_LIB_SV

// -----------------------------------------------------------------------------
// Single write. Returns the response in `rsp_code` so a caller can check it
// without reaching into the item.
// -----------------------------------------------------------------------------
class axil_write_seq extends mqnic_base_seq #(axil_item);

    `uvm_object_utils(axil_write_seq)

    rand bit [63:0] addr;
    rand bit [63:0] data;
    rand bit [7:0]  strb;
    axil_resp_e     rsp_code;

    constraint c_strb { soft strb == 8'hFF; }

    function new(string name = "axil_write_seq");
        super.new(name);
    endfunction

    virtual task body();
        axil_item it;
        it = axil_item::type_id::create("it");
        start_item(it);
        if (!it.randomize() with {
                kind == AXIL_WRITE;
                addr == local::addr;
                data == local::data;
                strb == local::strb;
            })
            `uvm_fatal(get_type_name(), "randomize failed")
        finish_item(it);
        rsp_code = it.resp;
    endtask

endclass : axil_write_seq


// -----------------------------------------------------------------------------
// Single read. Result lands in `data` / `rsp_code`.
// -----------------------------------------------------------------------------
class axil_read_seq extends mqnic_base_seq #(axil_item);

    `uvm_object_utils(axil_read_seq)

    rand bit [63:0] addr;
    bit [63:0]      data;
    axil_resp_e     rsp_code;

    function new(string name = "axil_read_seq");
        super.new(name);
    endfunction

    virtual task body();
        axil_item it;
        it = axil_item::type_id::create("it");
        start_item(it);
        if (!it.randomize() with {
                kind == AXIL_READ;
                addr == local::addr;
            })
            `uvm_fatal(get_type_name(), "randomize failed")
        finish_item(it);
        data     = it.data;
        rsp_code = it.resp;
    endtask

endclass : axil_read_seq


// -----------------------------------------------------------------------------
// Write followed by a read of the same address. The most useful primitive for
// register bring-up: one call proves the path in both directions.
//
// It does NOT check the readback - that is the scoreboard's job (STRATEGY §4.3
// rule 3). The sequence only reports what came back.
// -----------------------------------------------------------------------------
class axil_write_read_seq extends mqnic_base_seq #(axil_item);

    `uvm_object_utils(axil_write_read_seq)

    rand bit [63:0] addr;
    rand bit [63:0] wdata;
    bit [63:0]      rdata;

    function new(string name = "axil_write_read_seq");
        super.new(name);
    endfunction

    virtual task body();
        axil_write_seq wr;
        axil_read_seq  rd;

        wr = axil_write_seq::type_id::create("wr");
        wr.addr = addr;
        wr.data = wdata;
        wr.strb = 8'hFF;
        wr.start(m_sequencer, this);

        rd = axil_read_seq::type_id::create("rd");
        rd.addr = addr;
        rd.start(m_sequencer, this);

        rdata = rd.data;
    endtask

endclass : axil_write_read_seq


// -----------------------------------------------------------------------------
// Randomized traffic stream. Addresses are constrained to a window so a test
// can aim it at a real register region instead of scattering across the map.
// -----------------------------------------------------------------------------
class axil_random_seq extends mqnic_base_seq #(axil_item);

    `uvm_object_utils(axil_random_seq)

    rand int unsigned n_items;
    rand bit [63:0]   addr_lo;
    rand bit [63:0]   addr_hi;
    rand int unsigned write_pct;
    rand bit          align_dword;

    constraint c_defaults {
        soft n_items   inside {[16:64]};
        soft write_pct == 50;
        soft addr_lo   == 64'h0;
        soft addr_hi   == 64'hFF;
        soft align_dword == 1'b1;
        addr_hi >= addr_lo;
        write_pct <= 100;
    }

    function new(string name = "axil_random_seq");
        super.new(name);
    endfunction

    virtual task body();
        axil_item it;
        for (int i = 0; i < int'(n_items); i++) begin
            if (stop_requested()) break;
            it = axil_item::type_id::create($sformatf("it%0d", i));
            start_item(it);
            if (!it.randomize() with {
                    kind dist { AXIL_WRITE := local::write_pct,
                                AXIL_READ  := 100 - local::write_pct };
                    addr inside {[local::addr_lo : local::addr_hi]};
                    local::align_dword -> (addr[1:0] == 2'b00);
                })
                `uvm_fatal(get_type_name(), "randomize failed")
            finish_item(it);
        end
    endtask

endclass : axil_random_seq

`endif // AXIL_SEQ_LIB_SV

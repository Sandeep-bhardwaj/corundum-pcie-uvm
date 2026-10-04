// SPDX-License-Identifier: BSD-2-Clause-Views
//
// pcie_tlp_item / pcie_tlp_cfg
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.2
// Introduced : Step 2 (Tier 1b)
//
// The item is one complete TLP: a 128-bit header, a payload as a byte array,
// and the per-TLP sidebands the generic interface carries.
//
// HEADER IS CARRIED RAW at this tier. Tier 1b's DUTs - demux, mux, fifo - route
// and buffer TLPs without interpreting them, so the property under test is that
// the header arrives bit-identical. Field-level decode (fmt/type/length/tag/
// address) is added at Step 5 when dma_if_pcie needs it, because that is the
// first tier where a wrong field means a wrong request rather than a wrong
// route. Convenience accessors for the fields Tier 1b does need - length, and
// whether a payload is expected - are provided below.
// -----------------------------------------------------------------------------

`ifndef PCIE_TLP_ITEM_SV
`define PCIE_TLP_ITEM_SV

class pcie_tlp_item extends uvm_sequence_item;

    // ---- header and payload -------------------------------------------------
    rand bit [127:0]      hdr;
    rand byte unsigned    payload [];

    // ---- per-TLP sidebands --------------------------------------------------
    rand bit [2:0]        bar_id;
    rand bit [7:0]        func_num;
    rand bit [3:0]        error;
    rand bit [5:0]        seq;

    // ---- timing -------------------------------------------------------------
    rand int unsigned     delay;

    // ---- observation --------------------------------------------------------
    time                  start_time;
    time                  end_time;
    int                   src_port;    // which mux input / demux output carried it

    `uvm_object_utils_begin(pcie_tlp_item)
        `uvm_field_int      (hdr,      UVM_ALL_ON | UVM_HEX)
        `uvm_field_array_int(payload,  UVM_ALL_ON | UVM_HEX)
        `uvm_field_int      (bar_id,   UVM_ALL_ON | UVM_HEX)
        `uvm_field_int      (func_num, UVM_ALL_ON | UVM_HEX)
        `uvm_field_int      (error,    UVM_ALL_ON | UVM_HEX)
        `uvm_field_int      (seq,      UVM_ALL_ON | UVM_HEX)
        `uvm_field_int      (delay,    UVM_ALL_ON | UVM_DEC | UVM_NOCOMPARE)
        `uvm_field_int      (src_port, UVM_ALL_ON | UVM_DEC | UVM_NOCOMPARE)
    `uvm_object_utils_end

    // Payload is a whole number of DWORDs: the strobe is per DWORD, so a
    // non-multiple-of-4 payload cannot be represented on this interface.
    constraint c_payload {
        soft payload.size() inside {[0:256]};
        payload.size() % 4 == 0;
    }

    constraint c_sideband {
        soft bar_id   inside {[0:5]};   // pcie_tlp_demux_bar.v:130 rejects > 5
        soft func_num == 8'h00;
        soft error    == 4'h0;
    }

    constraint c_delay {
        delay dist { 0 := 70, [1:3] := 20, [4:15] := 10 };
    }

    function new(string name = "pcie_tlp_item");
        super.new(name);
    endfunction

    // ---- accessors the routing tiers need -----------------------------------

    // TLP header length field, in DWORDs (0 encodes 1024).
    //
    // Length lives at [105:96], NOT [9:0]. Verified against
    // dma_if_pcie_rd.v:764 (build) and :983 (decode).
    virtual function int unsigned hdr_length_dw();
        return mqnic_vrf_pkg::tlp_hdr_len_dw(hdr);
    endfunction

    virtual function bit [63:0] hdr_req_addr();
        return mqnic_vrf_pkg::tlp_hdr_req_addr(hdr);
    endfunction

    virtual function bit [7:0] hdr_req_tag();
        return mqnic_vrf_pkg::tlp_hdr_req_tag(hdr);
    endfunction

    // fmt[2:0] bit 1 set means a payload is present.
    virtual function bit hdr_has_payload();
        return hdr[126];
    endfunction

    virtual function string convert2string();
        return $sformatf("TLP hdr=0x%032h bar=%0d func=%0d err=%0d seq=%0d payload=%0dB",
                         hdr, bar_id, func_num, error, seq, payload.size());
    endfunction

endclass : pcie_tlp_item


class pcie_tlp_cfg extends uvm_object;

    mqnic_agent_mode_e  mode    = MODE_ACTIVE_MASTER;
    mqnic_tlp_channel_e channel = TLP_CH_RX_REQ;

    // Bus geometry. Defaults match mqnic_core_pcie at 256 bits with one
    // segment (mqnic_core_pcie_us.v:559-562).
    int unsigned data_width = 256;
    int unsigned seg_count  = 1;
    int unsigned seq_width  = 6;

    // Not every channel carries every sideband: the completion channel has
    // error but no bar_id, the request channel the reverse. Driving an absent
    // field is harmless; checking one is not, so the scoreboard consults these.
    bit has_bar_id   = 1'b1;
    bit has_func_num = 1'b1;
    bit has_error    = 1'b1;
    bit has_seq      = 1'b1;

    mqnic_bp_profile_e bp_profile      = BP_RANDOM;
    bit                enable_coverage = 1'b1;

    `uvm_object_utils_begin(pcie_tlp_cfg)
        `uvm_field_enum(mqnic_agent_mode_e,  mode,    UVM_ALL_ON)
        `uvm_field_enum(mqnic_tlp_channel_e, channel, UVM_ALL_ON)
        `uvm_field_int (data_width,                   UVM_ALL_ON | UVM_DEC)
        `uvm_field_int (seg_count,                    UVM_ALL_ON | UVM_DEC)
        `uvm_field_int (seq_width,                    UVM_ALL_ON | UVM_DEC)
        `uvm_field_int (has_bar_id,                   UVM_ALL_ON | UVM_BIN)
        `uvm_field_int (has_func_num,                 UVM_ALL_ON | UVM_BIN)
        `uvm_field_int (has_error,                    UVM_ALL_ON | UVM_BIN)
        `uvm_field_int (has_seq,                      UVM_ALL_ON | UVM_BIN)
        `uvm_field_enum(mqnic_bp_profile_e, bp_profile, UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "pcie_tlp_cfg");
        super.new(name);
    endfunction

    function int unsigned strb_width();
        return data_width / 32;
    endfunction

    // Bytes carried per segment per cycle.
    function int unsigned seg_bytes();
        return (data_width / 8) / seg_count;
    endfunction

    // Strobe lanes (DWORDs) owned by one segment. Segment index from lane is
    // lane / seg_strb_width(), matching the RTL's own mapping
    // (pcie_us_if_rc.v:308-320).
    function int unsigned seg_strb_width();
        return strb_width() / seg_count;
    endfunction

    function bit is_active();
        return (mode != MODE_PASSIVE);
    endfunction

endclass : pcie_tlp_cfg

`endif // PCIE_TLP_ITEM_SV

// SPDX-License-Identifier: BSD-2-Clause-Views
//
// pcie_tlp_driver / pcie_tlp_sink_driver
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.2
// Introduced : Step 2 (Tier 1b)
//
// Packs a pcie_tlp_item onto the segmented bus and drives it, or supplies
// consumer backpressure.
//
// PACKING RULES, from the generic TLP interface as used by the Corundum RTL:
//   * the header travels on the SOP segment, in that segment's tlp_hdr slice
//   * payload occupies tlp_data, one DWORD per tlp_strb bit
//   * a header-only TLP still occupies one beat with sop and eop both set and
//     tlp_strb all zero - it is not a zero-beat transfer
//   * ready is a single signal for the whole bus, not per segment
// -----------------------------------------------------------------------------

`ifndef PCIE_TLP_DRIVER_SV
`define PCIE_TLP_DRIVER_SV

class pcie_tlp_driver extends uvm_driver #(pcie_tlp_item);

    `uvm_component_utils(pcie_tlp_driver)

    virtual pcie_tlp_if vif;
    pcie_tlp_cfg        cfg;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual pcie_tlp_if)::get(this, "", "vif", vif))
            `uvm_fatal(get_type_name(), "no pcie_tlp_if in config_db under key 'vif'")
        if (!uvm_config_db #(pcie_tlp_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "no pcie_tlp_cfg in config_db under key 'cfg'")

        if (cfg.seg_count != 1)
            `uvm_info(get_type_name(),
                $sformatf({"seg_count=%0d: multi-segment packing is exercised at ",
                           "Tier 4 (straddling); Tiers 1b/3/5 run at 1"},
                          cfg.seg_count), UVM_LOW)
    endfunction

    virtual task run_phase(uvm_phase phase);
        drive_idle();
        forever begin
            @(vif.src_cb);
            if (vif.rst === 1'b1) begin
                drive_idle();
                while (vif.rst === 1'b1) @(vif.src_cb);
                continue;
            end
            seq_item_port.try_next_item(req);
            if (req == null) continue;
            drive_tlp(req);
            seq_item_port.item_done();
        end
    endtask

    protected virtual task drive_idle();
        vif.src_cb.tlp_data     <= '0;
        vif.src_cb.tlp_strb     <= '0;
        vif.src_cb.tlp_hdr      <= '0;
        vif.src_cb.tlp_seq      <= '0;
        vif.src_cb.tlp_bar_id   <= '0;
        vif.src_cb.tlp_func_num <= '0;
        vif.src_cb.tlp_error    <= '0;
        vif.src_cb.tlp_valid    <= '0;
        vif.src_cb.tlp_sop      <= '0;
        vif.src_cb.tlp_eop      <= '0;
    endtask

    // -------------------------------------------------------------------------
    protected virtual task drive_tlp(pcie_tlp_item it);
        int unsigned bytes_per_beat;
        int unsigned dw_per_beat;
        int unsigned n;
        int unsigned idx;
        int unsigned this_beat;
        bit [511:0]  d;
        bit [15:0]   s;
        bit          first;
        bit          last;

        bytes_per_beat = cfg.data_width / 8;
        dw_per_beat    = cfg.strb_width();
        n              = it.payload.size();
        it.start_time  = $time;

        repeat (it.delay) @(vif.src_cb);

        idx   = 0;
        first = 1'b1;

        // Header-only TLPs still take one beat.
        do begin
            this_beat = (n - idx > bytes_per_beat) ? bytes_per_beat : (n - idx);
            last      = (idx + this_beat >= n);

            d = '0;
            s = '0;
            for (int b = 0; b < int'(this_beat); b++)
                d[b*8 +: 8] = it.payload[idx + b];
            for (int w = 0; w < int'((this_beat + 3) / 4); w++)
                s[w] = 1'b1;

            vif.src_cb.tlp_data <= d;
            vif.src_cb.tlp_strb <= s;

            // Header and sidebands ride the SOP segment, which this driver
            // always places at segment 0: a TLP starts a beat, it never
            // begins mid-beat. Straddled STIMULUS is a Xilinx-side shape and
            // is driven by pcie_us_axis_driver, not here.
            vif.src_cb.tlp_hdr      <= first ? {384'd0, it.hdr} : '0;
            vif.src_cb.tlp_seq      <= cfg.has_seq      ? {58'd0, it.seq}      : '0;
            vif.src_cb.tlp_bar_id   <= cfg.has_bar_id   ? {9'd0,  it.bar_id}   : '0;
            vif.src_cb.tlp_func_num <= cfg.has_func_num ? {24'd0, it.func_num} : '0;
            vif.src_cb.tlp_error    <= cfg.has_error    ? {12'd0, it.error}    : '0;

            // ---- framing, PER SEGMENT ---------------------------------
            //
            // A beat spans cfg.seg_count segments, each owning seg_strb_width()
            // lanes. A TLP occupies the segments its bytes actually reach: sop
            // marks the first, eop the last one used, and any segment between
            // them is valid with neither.
            //
            // The first version drove segment 0 alone and left the rest idle.
            // Legal stimulus, but weak - it never presents a TLP that SPANS
            // segments, which is the case a multi-segment consumer gets wrong.
            // It also could not drive Tier 4b at all, where SEG_COUNT is 2
            // because the RTL will not elaborate at 1 (bug 13).
            begin
                int unsigned seg_lanes = cfg.seg_strb_width();
                int unsigned dw_used   = (this_beat + 3) / 4;
                int unsigned last_seg;
                bit [3:0]    v         = '0;

                if (dw_used == 0) dw_used = 1;          // header-only beat
                last_seg = (dw_used - 1) / seg_lanes;
                if (last_seg >= cfg.seg_count) last_seg = cfg.seg_count - 1;

                for (int sg = 0; sg <= int'(last_seg); sg++) v[sg] = 1'b1;

                vif.src_cb.tlp_valid <= v;
                vif.src_cb.tlp_sop   <= first ? 4'b0001 : 4'b0000;
                vif.src_cb.tlp_eop   <= last  ? (4'b0001 << last_seg) : 4'b0000;
            end

            do @(vif.src_cb); while (vif.src_cb.tlp_ready !== 1'b1);

            idx  += this_beat;
            first = 1'b0;
        end while (idx < n);

        vif.src_cb.tlp_valid <= '0;
        vif.src_cb.tlp_sop   <= '0;
        vif.src_cb.tlp_eop   <= '0;
        it.end_time = $time;

        `uvm_info(get_type_name(),
            $sformatf("drove %s", it.convert2string()), UVM_HIGH)
    endtask

endclass : pcie_tlp_driver


// -----------------------------------------------------------------------------
class pcie_tlp_sink_driver extends uvm_driver #(pcie_tlp_item);

    `uvm_component_utils(pcie_tlp_sink_driver)

    virtual pcie_tlp_if vif;
    pcie_tlp_cfg        cfg;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual pcie_tlp_if)::get(this, "", "vif", vif))
            `uvm_fatal(get_type_name(), "no pcie_tlp_if in config_db under key 'vif'")
        if (!uvm_config_db #(pcie_tlp_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "no pcie_tlp_cfg in config_db under key 'cfg'")
    endfunction

    virtual task run_phase(uvm_phase phase);
        vif.sink_cb.tlp_ready <= 1'b0;
        forever begin
            case (cfg.bp_profile)
                BP_NONE: begin
                    vif.sink_cb.tlp_ready <= 1'b1;
                    @(vif.sink_cb);
                end
                BP_AGGRESSIVE: begin
                    vif.sink_cb.tlp_ready <= 1'b0;
                    repeat ($urandom_range(4, 12)) @(vif.sink_cb);
                    vif.sink_cb.tlp_ready <= 1'b1;
                    @(vif.sink_cb);
                end
                BP_BURSTY: begin
                    vif.sink_cb.tlp_ready <= 1'b1;
                    repeat ($urandom_range(8, 20)) @(vif.sink_cb);
                    vif.sink_cb.tlp_ready <= 1'b0;
                    repeat ($urandom_range(8, 20)) @(vif.sink_cb);
                end
                default: begin
                    vif.sink_cb.tlp_ready <= 1'b0;
                    repeat ($urandom_range(0, 3)) @(vif.sink_cb);
                    vif.sink_cb.tlp_ready <= 1'b1;
                    @(vif.sink_cb);
                end
            endcase
        end
    endtask

endclass : pcie_tlp_sink_driver

`endif // PCIE_TLP_DRIVER_SV

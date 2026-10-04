// SPDX-License-Identifier: BSD-2-Clause-Views
//
// ref_checksum - reference model for rx_checksum
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §10 (reference models)
// Introduced : Step 3 (Tier 1c)
//
// rx_checksum.v computes a 16-bit one's-complement SUM over the frame starting
// at START_OFFSET (default 14 - immediately after the Ethernet header) and
// presents it on m_axis_csum. Note it is the SUM, not the complemented
// checksum: the driver complements it later, which is why the cocotb reference
// test asserts
//
//     pkt.rx_checksum == ~scapy.utils.checksum(bytes(pkt.data[14:])) & 0xffff
//
// (fpga/common/tb/mqnic_core_pcie_us/test_mqnic_core_pcie_us.py:469 - scapy's
// checksum() already returns the complemented value, so the ~ recovers the raw
// sum). Getting this polarity backwards is the obvious way to write a model
// that is wrong by exactly one bitwise-not.
//
// Odd trailing byte: the final byte is padded with a zero low half, which
// mqnic_vrf_pkg::ones_complement_sum16 already does.
//
// tx_checksum is modelled by tx_expected() below: it sums over [csum_start,
// end) and writes the complemented result at csum_offset.
// -----------------------------------------------------------------------------

`ifndef REF_CHECKSUM_SV
`define REF_CHECKSUM_SV

class ref_checksum extends uvm_object;

    `uvm_object_utils(ref_checksum)

    // Must match the DUT's START_OFFSET parameter.
    int unsigned start_offset = 14;

    // Must match tx_checksum's USE_INIT_VALUE. With 0 - tb_top_tier1c and
    // mqnic_egress.v:128 both use 0 - the DUT IGNORES csum_init (tx_checksum.v:348)
    // however the command sets it. Applying it unconditionally mispredicted every
    // frame sent with a non-zero init.
    bit          use_init_value = 1'b0;

    function new(string name = "ref_checksum");
        super.new(name);
    endfunction

    // -------------------------------------------------------------------------
    // Expected m_axis_csum for a frame. Frames shorter than start_offset
    // contribute nothing and sum to zero.
    // -------------------------------------------------------------------------
    virtual function bit [15:0] rx_expected(const ref byte unsigned frame[]);
        if (frame.size() <= int'(start_offset)) return 16'h0000;
        return mqnic_vrf_pkg::ones_complement_sum16(
                   frame, int'(start_offset), frame.size() - int'(start_offset));
    endfunction

    // -------------------------------------------------------------------------
    // The value a driver would place in an IP/UDP/TCP checksum field, i.e. the
    // complement of the sum. Provided so tests can be written in the terms a
    // network engineer expects.
    // -------------------------------------------------------------------------
    virtual function bit [15:0] rx_expected_complemented(const ref byte unsigned frame[]);
        return ~rx_expected(frame) & 16'hFFFF;
    endfunction

    // -------------------------------------------------------------------------
    // tx_checksum: sums over [csum_start, end), seeded with csum_init,
    // COMPLEMENTS the result, and writes it big-endian at csum_offset
    // (tx_checksum.v:354-358 for the complement, :412-413 for the insertion:
    //  frame[offset] = csum[15:8], frame[offset+1] = csum[7:0]).
    //
    // ODD csum_start. The RTL tracks `sum_odd` (:292) and swaps the result
    // bytes (:354-355) when the start offset is odd. That swap exists to undo
    // the bus-alignment shift the hardware sees; the net effect is the ordinary
    // checksum of the byte range. This model therefore performs NO swap - it
    // computes the natural big-endian sum directly.
    //
    // Confirmed on Vivado xsim: t1c_tx_checksum sweeps csum_start 12..22, odd
    // and even, and every frame matches with no swap.
    // -------------------------------------------------------------------------
    virtual function void tx_expected(const ref byte unsigned frame[],
                                      input bit         csum_enable,
                                      input int         csum_start,
                                      input int         csum_offset,
                                      input bit [15:0]  csum_init,
                                      output byte unsigned out_frame[]);
        bit [31:0] sum;
        bit [15:0] csum;

        out_frame = new[frame.size()];
        foreach (frame[i]) out_frame[i] = frame[i];

        if (!csum_enable) return;
        if (csum_start >= frame.size()) return;
        if (csum_offset + 1 >= frame.size()) return;

        sum = 32'(mqnic_vrf_pkg::ones_complement_sum16(
                      frame, csum_start, frame.size() - csum_start))
              + (use_init_value ? 32'(csum_init) : 32'd0);
        while (sum[31:16] != 16'd0)
            sum = {16'd0, sum[15:0]} + {16'd0, sum[31:16]};

        csum = ~sum[15:0];

        out_frame[csum_offset]     = csum[15:8];
        out_frame[csum_offset + 1] = csum[7:0];
    endfunction

endclass : ref_checksum

`endif // REF_CHECKSUM_SV

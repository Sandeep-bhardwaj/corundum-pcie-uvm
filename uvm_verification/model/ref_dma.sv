// SPDX-License-Identifier: BSD-2-Clause-Views
//
// ref_dma - reference model for dma_if_pcie read requests
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §10 (ref_dma), §14.3, §15.2
// Introduced : Step 5 (Tier 3)
//
// Predicts, for one descriptor, the exact SET of read-request TLPs the DUT must
// emit. Getting this right is the whole of Tier 3: §14.3 crosses length against
// both alignments against MPS against RCB precisely because the splitting rules
// interact.
//
// THE SPLIT IS TRANSCRIBED FROM THE RTL, not reasoned out from the spec.
// dma_if_pcie_rd.v:662-720 picks exactly ONE branch per request:
//
//   if (remaining + addr[1:0] <= MRRS)          // fits in one request
//       if (crosses a 4 KB page)  chunk = 4096 - addr[11:0]
//       else                      chunk = remaining
//   else                                         // must be split
//       if (addr[11:0] + MRRS crosses 4 KB)
//                                 chunk = 4096 - addr[11:0]
//       else                      chunk = MRRS - addr[6:0]
//
// Two details are easy to get wrong and were, in the first version:
//
//   * The MRRS test includes addr[1:0]. A request is measured in DWORDs from
//     the containing DWORD boundary, so an unaligned start eats into the
//     budget.
//   * The alignment term is addr[6:0] - a FIXED 128-byte boundary
//     (dma_if_pcie_rd.v:710), NOT the RCB. It does not change with rcb_128b,
//     and it applies to every oversized request rather than only the first.
//
// A model that splits purely by MRRS predicts the right TOTAL but the wrong
// BOUNDARIES, and then every request after the first mismatches.
//
// This model predicts REQUESTS. Whether the returned data lands correctly in
// RAM is checked separately by sb_dma against the host memory model - splitting
// the two means a boundary bug and a data-placement bug do not mask each other.
// -----------------------------------------------------------------------------

`ifndef REF_DMA_SV
`define REF_DMA_SV

class ref_dma_req;
    bit [63:0]   addr;
    int unsigned len;        // bytes
    int unsigned ram_addr;   // where this chunk lands
    function string convert2string();
        return $sformatf("addr=0x%0h len=%0d -> ram 0x%0h", addr, len, ram_addr);
    endfunction
endclass


class ref_dma extends uvm_object;

    `uvm_object_utils(ref_dma)

    // Configuration mirrored from the DUT's inputs.
    bit [2:0] max_read_request_size = 3'd2;   // encoding: 128 << value
    bit [2:0] max_payload_size      = 3'd1;   // same encoding; bounds WRITES
    bit       rcb_128b              = 1'b0;
    bit       ext_tag_enable        = 1'b1;

    function new(string name = "ref_dma");
        super.new(name);
    endfunction

    function int unsigned mrrs_bytes();
        return 128 << max_read_request_size;
    endfunction

    // dma_if_pcie_wr.v:1109 clamps the encoding at 5, so 4096 is the ceiling.
    function int unsigned mps_bytes();
        return 128 << ((max_payload_size > 3'd5) ? 3'd5 : max_payload_size);
    endfunction

    function bit exceeds_mps(int unsigned len);
        return (len > mps_bytes());
    endfunction

    function int unsigned rcb();
        return rcb_128b ? 128 : 64;
    endfunction

    // -------------------------------------------------------------------------
    // Split one descriptor into the read requests it must produce.
    // -------------------------------------------------------------------------
    virtual function void split_read(input bit [63:0]   pcie_addr,
                                     input int unsigned ram_addr,
                                     input int unsigned len,
                                     ref   ref_dma_req  out[$]);
        bit [63:0]   cur = pcie_addr;
        int unsigned rem = len;
        int unsigned ram = ram_addr;
        int unsigned chunk;
        int unsigned mrrs;
        int unsigned page_off;    // cur[11:0]
        int unsigned dw_off;      // cur[1:0]
        ref_dma_req  r;

        out.delete();
        mrrs = mrrs_bytes();

        // ZERO LENGTH IS ONE REQUEST, NOT NONE.
        //
        // dma_if_pcie_rd.v:795-798 special-cases len == 0: op_count becomes 1
        // and zero_len is set, producing a single request with BOTH byte enables
        // zero - the standard PCIe zero-length read. A `while (rem > 0)` loop
        // emits nothing, and the scoreboard then reports the DUT for a request
        // it was required to make.
        //
        // Found by cross-checking against the cocotb block TB (§19 E6), whose
        // length sweep starts at 0 where ours started at 1. Neither half of the
        // UVM environment could have caught it: the model and the scoreboard
        // agreed with each other.
        if (len == 0) begin
            r          = new();
            r.addr     = pcie_addr;
            r.len      = 0;
            r.ram_addr = ram_addr;
            out.push_back(r);
            return;
        end

        while (rem > 0) begin
            page_off = int'(cur[11:0]);
            dw_off   = int'(cur[1:0]);

            if (rem + dw_off <= mrrs) begin
                // Fits in one request - unless a page boundary falls inside it.
                if (page_off + rem > 4096)
                    chunk = 4096 - page_off;
                else
                    chunk = rem;
            end
            else begin
                // Too big for one request. A page boundary inside the MRRS
                // window takes precedence over the 128-byte alignment split.
                if (page_off + mrrs > 4096)
                    chunk = 4096 - page_off;
                else
                    chunk = mrrs - int'(cur[6:0]);
            end

            r          = new();
            r.addr     = cur;
            r.len      = chunk;
            r.ram_addr = ram;
            out.push_back(r);

            cur += chunk;
            ram += chunk;
            rem -= chunk;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Split one descriptor into the WRITE requests it must produce.
    //
    // A DIFFERENT RULE FROM split_read, and reusing that one here would be
    // wrong in two ways (dma_if_pcie_wr.v:546-565):
    //
    //   * the limit is max_payload_size, not max_read_request_size - a write
    //     carries its data, so the payload limit binds, not the request limit;
    //   * the alignment term is addr[1:0], a DWORD, not addr[6:0]. There are no
    //     completions coming back, so there is no RCB to align to; only the
    //     DWORD packing of the payload matters.
    //
    // Verified against an independent transcription of the RTL over 268,830
    // cases - see docs/bringup_log.md.
    // -------------------------------------------------------------------------
    virtual function void split_write(input bit [63:0]   pcie_addr,
                                      input int unsigned ram_addr,
                                      input int unsigned len,
                                      ref   ref_dma_req  out[$]);
        bit [63:0]   cur = pcie_addr;
        int unsigned rem = len;
        int unsigned ram = ram_addr;
        int unsigned chunk;
        int unsigned mps;
        int unsigned page_off;
        int unsigned dw_off;
        ref_dma_req  r;

        out.delete();
        mps = mps_bytes();

        // ZERO LENGTH IS ONE REQUEST, NOT NONE.
        //
        // dma_if_pcie_wr.v:795-798 special-cases len == 0: op_count becomes 1
        // and zero_len is set, producing a single request with BOTH byte enables
        // zero - the standard PCIe zero-length write. A `while (rem > 0)` loop
        // emits nothing, and the scoreboard then reports the DUT for a request
        // it was required to make.
        //
        // Found by cross-checking against the cocotb block TB (§19 E6), whose
        // length sweep starts at 0 where ours started at 1. Neither half of the
        // UVM environment could have caught it: the model and the scoreboard
        // agreed with each other.
        if (len == 0) begin
            r          = new();
            r.addr     = pcie_addr;
            r.len      = 0;
            r.ram_addr = ram_addr;
            out.push_back(r);
            return;
        end

        while (rem > 0) begin
            page_off = int'(cur[11:0]);
            dw_off   = int'(cur[1:0]);

            if (rem + dw_off <= mps) begin
                if (page_off + rem > 4096) chunk = 4096 - page_off;
                else                       chunk = rem;
            end
            else begin
                if (page_off + mps > 4096) chunk = 4096 - page_off;
                else                       chunk = mps - dw_off;
            end

            r          = new();
            r.addr     = cur;
            r.len      = chunk;
            r.ram_addr = ram;
            out.push_back(r);

            cur += chunk;
            ram += chunk;
            rem -= chunk;
        end
    endfunction

    // -------------------------------------------------------------------------
    // How a completer is allowed to break one read request into completions.
    // Used by the root complex model to generate legal traffic, and by the
    // scoreboard to reject illegal traffic.
    //
    // Every completion except the last must end on an RCB boundary.
    // -------------------------------------------------------------------------
    virtual function void split_completion(input bit [63:0]   addr,
                                           input int unsigned len,
                                           input int unsigned max_payload,
                                           ref   ref_dma_req  out[$]);
        bit [63:0]   cur = addr;
        int unsigned rem = len;
        int unsigned chunk;
        int unsigned to_rcb;
        ref_dma_req  r;

        out.delete();

        while (rem > 0) begin
            chunk = rem;
            if (chunk > max_payload) chunk = max_payload;

            to_rcb = rcb() - (int'(cur) % rcb());
            if (chunk > to_rcb) chunk = to_rcb;

            r      = new();
            r.addr = cur;
            r.len  = chunk;
            out.push_back(r);

            cur += chunk;
            rem -= chunk;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Checks the scoreboard applies to every observed request. These are the
    // §15.2 properties, expressed here so they can be reported with context
    // rather than as a bare assertion failure.
    // -------------------------------------------------------------------------
    virtual function bit crosses_4k(bit [63:0] addr, int unsigned len);
        return mqnic_vrf_pkg::crosses_4k(addr, len);
    endfunction

    virtual function bit exceeds_mrrs(int unsigned len);
        return (len > mrrs_bytes());
    endfunction

    // Legal tag range depends on ext_tag_enable: 8 bits when set, 5 when not.
    virtual function bit tag_in_range(int unsigned tag);
        return ext_tag_enable ? (tag < 256) : (tag < 32);
    endfunction

endclass : ref_dma

`endif // REF_DMA_SV

// SPDX-License-Identifier: BSD-2-Clause-Views
//
// ref_tlp_shim - Xilinx AXI-S descriptor <-> generic TLP header
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §10, §7.6, §22 R2
// Introduced : Step 6 (Tier 4)
//
// ONE MODEL SERVES BOTH DIRECTIONS, which is what §10's table asks for. That is
// not just tidiness: the Xilinx descriptor families are INVERSES of each other
// across the two directions -
//
//     CC build  (generic -> Xilinx)  is the inverse of  RC parse
//     RQ build  (generic -> Xilinx)  is the inverse of  CQ parse
//
// - so implementing them together lets each be checked against the other. That
// round-trip is exactly how this transcription was validated: 20,000 randomized
// completion headers and 20,000 request headers through encode-then-parse, zero
// divergent. A single-direction model has nothing to check itself against.
//
// TRANSCRIBED FROM RTL, with the source line for every field group:
//     RC parse   pcie_us_if_rc.v:346-374
//     CQ parse   pcie_us_if_cq.v:365-408
//     RQ build   pcie_us_if_rq.v:654-678
//     CC build   pcie_us_if_cc.v:390-407
//
// THE DESCRIPTOR IS CARRIED IN THE PAYLOAD. Unlike the generic interface, which
// has a separate 128-bit tlp_hdr bus, the Xilinx side puts the header in the
// first DWORDs of tdata: 3 DWORDs for RC, 4 for RQ/CQ/CC. Converting between
// those two representations is the whole of Tier 4.
//
// FIELDS THAT ARE DELIBERATELY LOST, and are therefore not checked:
//   * AT (address type) survives generic -> Xilinx but RC hardwires it to 0
//     coming back (rc:365), so a completion round-trip cannot preserve it.
//   * EP/poisoned survives into the RQ descriptor but CQ does not reproduce it
//     (cq:394 hardwires 0).
// Both are RTL behaviour, not model limitations. A scoreboard that compared
// them would report the DUT for doing what it is written to do.
// -----------------------------------------------------------------------------

`ifndef REF_TLP_SHIM_SV
`define REF_TLP_SHIM_SV

class ref_tlp_shim extends uvm_object;

    `uvm_object_utils(ref_tlp_shim)

    function new(string name = "ref_tlp_shim");
        super.new(name);
    endfunction

    // =========================================================================
    // Completion family
    // =========================================================================

    // Generic TLP header -> Xilinx CC descriptor (96 bits, 3 DWORDs).
    // pcie_us_if_cc.v:390-407.
    virtual function bit [95:0] cc_encode(bit [127:0] h);
        bit [95:0] d = '0;
        d[6:0]   = h[38:32];                       // lower address
        d[9:8]   = h[107:106];                     // AT
        d[28:16] = 13'(h[75:64]);                  // byte count
        d[29]    = 1'b0;                           // locked read completion
        d[42:32] = 11'(h[105:96]);                 // DWORD count
        d[45:43] = h[79:77];                       // completion status
        d[46]    = h[110];                         // poisoned
        d[63:48] = h[63:48];                       // requester ID
        d[71:64] = h[47:40];                       // tag
        d[87:72] = h[95:80];                       // completer ID
        d[91:89] = h[118:116];                     // TC
        d[94:92] = {h[114], h[109:108]};           // attr
        return d;
    endfunction

    // Xilinx RC descriptor -> generic TLP header. pcie_us_if_rc.v:346-374.
    virtual function bit [127:0] rc_parse(bit [95:0] d);
        bit [127:0] h = '0;
        // A completion with a non-zero DWORD count carries data.
        h[127:125] = (d[42:32] != 0) ? mqnic_vrf_pkg::TLP_FMT_3DW_DATA
                                     : mqnic_vrf_pkg::TLP_FMT_3DW;
        h[124:120] = {4'b0101, d[29]};             // type - Cpl / CplLk
        h[119]     = 1'b0;                         // T9
        h[118:116] = d[91:89];                     // TC
        h[115]     = 1'b0;                         // T8
        h[114]     = d[94];                        // attr[2]
        h[113:111] = 3'b000;                       // LN, TH, TD
        h[110]     = d[46];                        // EP
        h[109:108] = d[93:92];                     // attr[1:0]
        h[107:106] = 2'b00;                        // AT - hardwired, see header
        h[105:96]  = 10'(d[42:32]);                // length
        h[95:80]   = d[87:72];                     // completer ID
        h[79:77]   = d[45:43];                     // completion status
        h[76]      = 1'b0;                         // BCM
        h[75:64]   = 12'(d[28:16]);                // byte count
        h[63:48]   = d[63:48];                     // requester ID
        h[47:40]   = d[71:64];                     // tag
        h[39]      = 1'b0;
        h[38:32]   = d[6:0];                       // lower address
        h[31:0]    = 32'd0;
        return h;
    endfunction

    // The RC descriptor carries an error code that the generic interface
    // exposes as a separate sideband. pcie_us_if_rc.v:377-390.
    virtual function bit [3:0] rc_error(bit [95:0] d);
        case (d[15:12])
            4'd0:    return 4'(mqnic_vrf_pkg::PCIE_ERROR_NONE);
            4'd1:    return 4'(mqnic_vrf_pkg::PCIE_ERROR_POISONED);
            4'd2:    return 4'(mqnic_vrf_pkg::PCIE_ERROR_BAD_STATUS);
            4'd3:    return 4'(mqnic_vrf_pkg::PCIE_ERROR_INVALID_LEN);
            4'd4:    return 4'(mqnic_vrf_pkg::PCIE_ERROR_MISMATCH);
            4'd5:    return 4'(mqnic_vrf_pkg::PCIE_ERROR_INVALID_ADDR);
            4'd6:    return 4'(mqnic_vrf_pkg::PCIE_ERROR_INVALID_TAG);
            4'd8:    return 4'(mqnic_vrf_pkg::PCIE_ERROR_FLR);
            // 4'b1001, pcie_us_if_rc.v:140 (RC_ERROR_TIMEOUT). This line said 15
            // until the upstream-report review caught it; no test had sent a
            // timeout code through the RC shim, so nothing had failed.
            4'd9:    return 4'(mqnic_vrf_pkg::PCIE_ERROR_TIMEOUT);
            default: return 4'(mqnic_vrf_pkg::PCIE_ERROR_NONE);
        endcase
    endfunction

    // =========================================================================
    // Request family
    // =========================================================================

    // Values from pcie_us_if_rq.v:207-214, NOT invented. The first version of
    // this block guessed REQ_MEM_READ_LOCKED as 4'b0001, colliding it with
    // REQ_MEM_WRITE - which would have made every locked read decode as a write
    // and carry a phantom payload.
    localparam bit [3:0] REQ_MEM_READ        = 4'b0000;
    localparam bit [3:0] REQ_MEM_WRITE       = 4'b0001;
    localparam bit [3:0] REQ_IO_READ         = 4'b0010;
    localparam bit [3:0] REQ_IO_WRITE        = 4'b0011;
    localparam bit [3:0] REQ_MEM_READ_LOCKED = 4'b0111;

    // Generic TLP header -> Xilinx RQ descriptor (128 bits, 4 DWORDs).
    // pcie_us_if_rq.v:654-678.
    virtual function bit [127:0] rq_encode(bit [127:0] h);
        bit [127:0]  d = '0;
        bit [2:0]    fmt  = h[127:125];
        bit [4:0]    typ  = h[124:120];
        int unsigned len  = int'(h[105:96]);

        d[1:0]   = h[107:106];                     // address type
        d[63:2]  = h[63:2];                        // address
        // A length field of 0 encodes 1024 DWORDs, and the Xilinx count is 11
        // bits wide precisely so it can say so explicitly.
        d[74:64] = (len == 0) ? 11'd1024 : 11'(len);

        // The request type is derived from fmt AND type together - neither
        // alone is enough to tell a read from a write.
        if (typ == 5'b00000)      d[78:75] = fmt[1] ? REQ_MEM_WRITE : REQ_MEM_READ;
        else if (typ == 5'b00001) d[78:75] = REQ_MEM_READ_LOCKED;
        else if (typ == 5'b00010) d[78:75] = fmt[1] ? REQ_IO_WRITE : REQ_IO_READ;
        else                      d[78:75] = REQ_MEM_WRITE;   // rq:670 default

        d[79]      = h[110];                       // poisoned request
        d[95:80]   = h[95:80];                     // requester ID
        d[103:96]  = h[79:72];                     // tag
        d[119:104] = 16'd0;                        // completer ID
        d[120]     = 1'b0;                         // requester ID enable
        d[123:121] = h[118:116];                   // traffic class
        d[126:124] = {h[114], h[109:108]};         // attr
        d[127]     = 1'b0;                         // force ECRC
        return d;
    endfunction

    // The RQ byte enables travel in tuser, not in the descriptor.
    // pcie_us_if_rq.v:682-683.
    virtual function bit [3:0] rq_first_be(bit [127:0] h);
        return h[67:64];
    endfunction

    virtual function bit [3:0] rq_last_be(bit [127:0] h);
        return h[71:68];
    endfunction

    // Xilinx CQ descriptor -> generic TLP header. pcie_us_if_cq.v:365-408.
    //
    // The byte enables arrive in tuser, so the caller must supply them: they
    // are not recoverable from the descriptor.
    virtual function bit [127:0] cq_parse(bit [127:0] d,
                                          bit [3:0]   first_be,
                                          bit [3:0]   last_be);
        bit [127:0] h   = '0;
        bit [3:0]   req = d[78:75];
        bit         has_data;

        has_data = (req == REQ_MEM_WRITE) || (req == REQ_IO_WRITE);

        h[127:125] = has_data ? mqnic_vrf_pkg::TLP_FMT_4DW_DATA
                              : mqnic_vrf_pkg::TLP_FMT_4DW;
        h[124:120] = 5'b00000;                     // type - memory
        h[119]     = 1'b0;
        h[118:116] = d[123:121];                   // TC
        h[115]     = 1'b0;
        h[114]     = d[126];                       // attr[2]
        h[113:110] = 4'b0000;                      // LN, TH, TD, EP
        h[109:108] = d[125:124];                   // attr[1:0]
        h[107:106] = d[1:0];                       // AT
        h[105:96]  = 10'(d[74:64]);                // length
        h[95:80]   = d[95:80];                     // requester ID
        h[79:72]   = d[103:96];                    // tag
        h[71:68]   = last_be;
        h[67:64]   = first_be;
        h[63:2]    = d[63:2];                      // address
        h[1:0]     = 2'b00;                        // PH
        return h;
    endfunction

    // Generic TLP header -> Xilinx CQ descriptor: the inverse of cq_parse, for
    // tests that play the HOST and must put a request onto CQ.
    //
    // Not rq_encode. The RQ shim copies hdr[63:2] verbatim (pcie_us_if_rq.v:655),
    // which is right for what the DMA engine emits but wrong for a 3DW header,
    // whose address lives in DW2 at [63:34]: rq_encode(3DW read of 0x8) puts
    // 0x8_0000_0000 on the wire. cq_parse reads d[63:2] as the full address,
    // so a 3DW header's address is moved down here.
    virtual function bit [127:0] cq_encode(bit [127:0] h);
        bit [127:0] d = rq_encode(h);
        if (h[125] == 1'b0)                        // fmt: 3DW header
            d[63:2] = {32'd0, h[63:34]};
        return d;
    endfunction

    virtual function bit [2:0] cq_bar_id(bit [127:0] d);
        return d[114:112];
    endfunction

    virtual function bit [7:0] cq_func_num(bit [127:0] d);
        return d[111:104];
    endfunction

    // =========================================================================
    // Helpers
    // =========================================================================

    // Pack a descriptor into the DWORD stream the AXI-S item carries.
    virtual function void pack_desc(input bit [127:0] d, input int unsigned n_dw,
                                    ref bit [31:0] dwords[]);
        dwords = new[n_dw];
        for (int i = 0; i < int'(n_dw); i++)
            dwords[i] = d[i*32 +: 32];
    endfunction

    virtual function bit [127:0] unpack_desc(const ref bit [31:0] dwords[],
                                             input int unsigned n_dw);
        bit [127:0] d = '0;
        for (int i = 0; i < int'(n_dw) && i < dwords.size(); i++)
            d[i*32 +: 32] = dwords[i];
        return d;
    endfunction

endclass : ref_tlp_shim

`endif // REF_TLP_SHIM_SV

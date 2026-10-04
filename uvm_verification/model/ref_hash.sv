// SPDX-License-Identifier: BSD-2-Clause-Views
//
// ref_hash - reference model for rx_hash (Toeplitz / RSS)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §10 (reference models), §14 (RSS)
// Introduced : Step 3 (Tier 1c)
//
// Derived by reading fpga/common/rtl/rx_hash.v. Line references below are to
// that file.
//
// TOEPLITZ (:135-147)
//   function hash_toep(data, len, key):
//       for i in 0..len-1, for j in 0..7:
//           if data[i*8 + (7-j)]:  hash ^= key[320 - 32 - i*8 - j +: 32]
//
//   That is the textbook Toeplitz: walking the input MSB-first, bit k selects
//   the 32-bit key window starting at key bit k counted from the key's MSB.
//
// TWO-PART COMPUTATION (:151-152, :312-318)
//   hash_part_ipv4_ip   = hash_toep(data,       8, key)
//   hash_part_ipv4_port = hash_toep(data >> 64, 4, key << 64)
//   result = ipv4 ? (tcp|udp ? ip ^ port : ip) : 0
//
//   Shifting the key left by 64 bits and restarting the index is identical to
//   continuing the same key stream, and Toeplitz is linear, so the two-part XOR
//   equals ONE Toeplitz pass over the concatenated 12 bytes. That equivalence
//   is what this model relies on - it is exact, not an approximation.
//
// INPUT TUPLE
//   bytes 0..7   src IPv4 address, dst IPv4 address
//   bytes 8..11  src port, dst port          (only when TCP or UDP)
//
// HASH TYPE (:246, :268) is {udp, tcp, 1'b0, ipv4}:
//   4'b0001 IPv4 only        4'b0101 IPv4+TCP        4'b1001 IPv4+UDP
//   4'b0000 anything else, and the hash is forced to 0 (:317)
//
// Only IPv4 is hashed. IPv6 is detected as an ethertype (:189) but produces no
// hash, so the expected result for an IPv6 frame is hash=0, type=0.
// -----------------------------------------------------------------------------

`ifndef REF_HASH_SV
`define REF_HASH_SV

class ref_hash extends uvm_object;

    `uvm_object_utils(ref_hash)

    // 40-byte RSS key, byte 0 first on the wire. Bit 319 of the packed form is
    // the MSB of key_bytes[0].
    byte unsigned key_bytes [40];

    // Hash type bit positions (rx_hash.v:268).
    localparam bit [3:0] HASH_TYPE_IPV4 = 4'b0001;
    localparam bit [3:0] HASH_TYPE_TCP  = 4'b0100;
    localparam bit [3:0] HASH_TYPE_UDP  = 4'b1000;

    function new(string name = "ref_hash");
        super.new(name);
        foreach (key_bytes[i]) key_bytes[i] = 8'h00;
    endfunction

    // -------------------------------------------------------------------------
    virtual function void set_key(const ref byte unsigned k[]);
        foreach (key_bytes[i])
            key_bytes[i] = (i < k.size()) ? k[i] : 8'h00;
    endfunction

    // Pack into the 320-bit form the DUT's hash_key port takes: byte 0 in the
    // most significant position.
    virtual function bit [319:0] packed_key();
        bit [319:0] k = '0;
        foreach (key_bytes[i])
            k[319 - i*8 -: 8] = key_bytes[i];
        return k;
    endfunction

    // -------------------------------------------------------------------------
    // Toeplitz over an arbitrary byte stream, MSB-first.
    // -------------------------------------------------------------------------
    virtual function bit [31:0] toeplitz(const ref byte unsigned data[]);
        bit [319:0] k;
        bit [31:0]  h;
        int         bit_idx;

        k       = packed_key();
        h       = 32'd0;
        bit_idx = 0;

        foreach (data[i]) begin
            for (int j = 7; j >= 0; j--) begin
                if (data[i][j]) begin
                    // 32-bit window starting at key bit `bit_idx` from the MSB.
                    // Equivalent to rx_hash.v's key[320-32-i*8-j +: 32].
                    if (288 - bit_idx >= 0)
                        h ^= k[(288 - bit_idx) +: 32];
                end
                bit_idx++;
            end
        end
        return h;
    endfunction

    // -------------------------------------------------------------------------
    // Full prediction from a raw Ethernet frame.
    // -------------------------------------------------------------------------
    virtual function void predict(const ref byte unsigned frame[],
                                  output bit [31:0] hash,
                                  output bit [3:0]  hash_type);
        bit [15:0]      ethertype;
        int             ihl;
        int             ip_off;
        int             l4_off;
        byte unsigned   proto;
        byte unsigned   tuple [];
        bit             is_tcp;
        bit             is_udp;

        hash      = 32'd0;
        hash_type = 4'b0000;

        if (frame.size() < 34) return;                 // too short for Eth+IPv4

        ethertype = {frame[12], frame[13]};
        if (ethertype != 16'h0800) return;             // IPv4 only (rx_hash.v:186)

        ip_off = 14;
        ihl    = int'(frame[ip_off] & 8'h0F);
        if (ihl < 5) return;                           // malformed
        l4_off = ip_off + ihl * 4;

        proto  = frame[ip_off + 9];
        is_tcp = (proto == 8'd6);
        is_udp = (proto == 8'd17);

        hash_type = HASH_TYPE_IPV4;

        // Source and destination IPv4 addresses.
        tuple = new[8];
        for (int i = 0; i < 8; i++)
            tuple[i] = frame[ip_off + 12 + i];

        // Ports only for TCP/UDP, and only if the frame actually contains them.
        if ((is_tcp || is_udp) && frame.size() >= l4_off + 4) begin
            tuple = new[12] (tuple);
            for (int i = 0; i < 4; i++)
                tuple[8 + i] = frame[l4_off + i];
            hash_type |= is_tcp ? HASH_TYPE_TCP : HASH_TYPE_UDP;
        end

        hash = toeplitz(tuple);
    endfunction

endclass : ref_hash

`endif // REF_HASH_SV

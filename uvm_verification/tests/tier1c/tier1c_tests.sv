// SPDX-License-Identifier: BSD-2-Clause-Views
//
// Tier 1c test suite - offload blocks
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §13 Tier 1c
// Introduced : Step 3
//
// rx_checksum and rx_hash are driven from one shared stimulus stream, so every
// test below exercises both DUTs at once and the scoreboard checks both.
// -----------------------------------------------------------------------------

`ifndef TIER1C_TESTS_SV
`define TIER1C_TESTS_SV

class tier1c_base_test extends mqnic_base_test;

    `uvm_component_utils(tier1c_base_test)

    tier1c_env m_env;

    function new(string name = "tier1c_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        m_env = tier1c_env::type_id::create("m_env", this);
    endfunction

    // The receive-side DUTs and tx_checksum are independent. Tests that drive
    // only the receive stream must not be failed by the tx scoreboard's
    // "you checked nothing" drain rule; t1c_tx_* flips this.
    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_sb.check_tx = 1'b0;
    endfunction

    // ---- tx_checksum stimulus ----------------------------------------------
    protected task tx_send(const ref byte unsigned bytes[],
                           input bit       csum_enable,
                           input bit [7:0] csum_start,
                           input bit [7:0] csum_offset,
                           input bit [15:0] csum_init = 16'h0000);
        axis_packet_seq p = axis_packet_seq::type_id::create("p");
        csum_cmd_seq    c = csum_cmd_seq::type_id::create("c");

        c.csum_enable = csum_enable;
        c.csum_start  = csum_start;
        c.csum_offset = csum_offset;
        c.csum_init   = csum_init;

        p.payload = new[bytes.size()];
        foreach (bytes[i]) p.payload[i] = bytes[i];
        p.delay_start = 0;

        fork
            c.start(m_env.m_tx_cmd.sequencer);
            p.start(m_env.m_tx_in.sequencer);
        join
    endtask

    // ---- frame construction -------------------------------------------------

    // Ethernet header with the given ethertype.
    protected function void eth_hdr(ref byte unsigned f[$], input bit [15:0] etype);
        for (int i = 0; i < 6; i++) f.push_back(8'hAA);          // dst MAC
        for (int i = 0; i < 6; i++) f.push_back(8'hBB);          // src MAC
        f.push_back(etype[15:8]);
        f.push_back(etype[7:0]);
    endfunction

    // IPv4 header. proto 6 = TCP, 17 = UDP, anything else = no L4 hash.
    protected function void ipv4_hdr(ref byte unsigned f[$],
                                     input byte unsigned proto,
                                     input bit [31:0] src_ip,
                                     input bit [31:0] dst_ip,
                                     input int total_len);
        f.push_back(8'h45);                       // version 4, IHL 5
        f.push_back(8'h00);                       // DSCP/ECN
        f.push_back(total_len[15:8]);
        f.push_back(total_len[7:0]);
        f.push_back(8'h00); f.push_back(8'h01);   // identification
        f.push_back(8'h40); f.push_back(8'h00);   // flags/fragment
        f.push_back(8'h40);                       // TTL
        f.push_back(proto);
        f.push_back(8'h00); f.push_back(8'h00);   // header checksum (unused here)
        for (int i = 3; i >= 0; i--) f.push_back(src_ip[i*8 +: 8]);
        for (int i = 3; i >= 0; i--) f.push_back(dst_ip[i*8 +: 8]);
    endfunction

    protected function void l4_ports(ref byte unsigned f[$],
                                     input bit [15:0] sport,
                                     input bit [15:0] dport);
        f.push_back(sport[15:8]); f.push_back(sport[7:0]);
        f.push_back(dport[15:8]); f.push_back(dport[7:0]);
    endfunction

    // Complete IPv4/TCP or IPv4/UDP frame with `payload_len` bytes of payload.
    protected function void make_ipv4_frame(output byte unsigned out[],
                                            input byte unsigned proto,
                                            input bit [31:0] src_ip,
                                            input bit [31:0] dst_ip,
                                            input bit [15:0] sport,
                                            input bit [15:0] dport,
                                            input int payload_len,
                                            input byte unsigned fill = 8'h5A);
        byte unsigned f [$];
        eth_hdr(f, 16'h0800);
        ipv4_hdr(f, proto, src_ip, dst_ip, 20 + 4 + payload_len);
        l4_ports(f, sport, dport);
        for (int i = 0; i < payload_len; i++)
            f.push_back(fill + 8'(i));
        out = new[f.size()];
        foreach (f[i]) out[i] = f[i];
    endfunction

    // Non-IP frame: must produce hash = 0, type = 0.
    protected function void make_raw_frame(output byte unsigned out[],
                                           input int len,
                                           input bit [15:0] etype = 16'h88F7);
        byte unsigned f [$];
        eth_hdr(f, etype);
        for (int i = 0; i < len; i++) f.push_back(8'(i * 7 + 3));
        out = new[f.size()];
        foreach (f[i]) out[i] = f[i];
    endfunction

    // ---- stimulus -----------------------------------------------------------
    protected task send(const ref byte unsigned bytes[], input int gap = 8);
        axis_packet_seq s = axis_packet_seq::type_id::create("s");
        s.payload = new[bytes.size()];
        foreach (bytes[i]) s.payload[i] = bytes[i];
        s.delay_start = gap;
        s.start(m_env.m_stim.sequencer);
    endtask

    protected task idle(int n);
        repeat (n) @(posedge m_rst_vif.clk);
    endtask

endclass : tier1c_base_test


// -----------------------------------------------------------------------------
// t1c_checksum_known_vectors - fixed frames whose checksum is easy to reason
// about by hand. Run this first: if it fails, the polarity of ref_checksum
// (sum versus complemented sum) is the first thing to check.
// -----------------------------------------------------------------------------
class t1c_checksum_known_vectors extends tier1c_base_test;

    `uvm_component_utils(t1c_checksum_known_vectors)

    function new(string name = "t1c_checksum_known_vectors", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        byte unsigned f [];

        phase.raise_objection(this, "t1c_checksum_known_vectors");
        apply_power_on_reset();
        idle(10);

        // All-zero payload after the Ethernet header: sum must be zero.
        f = new[64];
        foreach (f[i]) f[i] = 8'h00;
        send(f);
        idle(30);

        // All-ones payload.
        f = new[64];
        foreach (f[i]) f[i] = 8'hFF;
        send(f);
        idle(30);

        // Alternating pattern.
        f = new[64];
        foreach (f[i]) f[i] = (i % 2) ? 8'hFF : 8'h00;
        send(f);
        idle(30);

        // A real IPv4/UDP frame.
        make_ipv4_frame(f, 8'd17, 32'hC0A80001, 32'hC0A80002, 16'd1234, 16'd5678, 32);
        send(f);
        idle(40);

        phase.drop_objection(this, "t1c_checksum_known_vectors");
    endtask

endclass : t1c_checksum_known_vectors


// -----------------------------------------------------------------------------
// t1c_checksum_odd_length - the trailing-odd-byte path. rx_checksum must pad
// the final byte with a zero low half; a model or DUT that drops it is wrong by
// exactly one byte and only on odd lengths.
// -----------------------------------------------------------------------------
class t1c_checksum_odd_length extends tier1c_base_test;

    `uvm_component_utils(t1c_checksum_odd_length)

    function new(string name = "t1c_checksum_odd_length", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        axis_len_sweep_seq s;

        phase.raise_objection(this, "t1c_checksum_odd_length");
        apply_power_on_reset();
        idle(10);

        // Every length across two beat boundaries at 256 bits (32 bytes/beat):
        // covers 15..80, so both odd and even, and the 32/64-byte crossings.
        s = axis_len_sweep_seq::type_id::create("s");
        if (!s.randomize() with { len_lo == 15; len_hi == 80; })
            `uvm_fatal(get_type_name(), "randomize failed")
        s.start(m_env.m_stim.sequencer);
        idle(80);

        phase.drop_objection(this, "t1c_checksum_odd_length");
    endtask

endclass : t1c_checksum_odd_length


// -----------------------------------------------------------------------------
// t1c_hash_known_vectors - IPv4/TCP, IPv4/UDP, IPv4 without L4, and non-IP.
//
// Expected hash_type (rx_hash.v:268, {udp,tcp,0,ipv4}):
//   IPv4+TCP -> 4'b0101   IPv4+UDP -> 4'b1001
//   IPv4     -> 4'b0001   non-IP   -> 4'b0000 with hash forced to 0
// -----------------------------------------------------------------------------
class t1c_hash_known_vectors extends tier1c_base_test;

    `uvm_component_utils(t1c_hash_known_vectors)

    function new(string name = "t1c_hash_known_vectors", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        byte unsigned f [];

        phase.raise_objection(this, "t1c_hash_known_vectors");
        apply_power_on_reset();
        idle(10);

        // IPv4 + TCP
        make_ipv4_frame(f, 8'd6, 32'h0A000001, 32'h0A000002, 16'd80, 16'd12345, 32);
        send(f);
        idle(40);

        // IPv4 + UDP
        make_ipv4_frame(f, 8'd17, 32'h0A000003, 32'h0A000004, 16'd53, 16'd40000, 32);
        send(f);
        idle(40);

        // IPv4, no L4 hash (ICMP) - hash over the addresses only
        make_ipv4_frame(f, 8'd1, 32'h0A000005, 32'h0A000006, 16'd0, 16'd0, 32);
        send(f);
        idle(40);

        // Non-IP ethertype - hash and type must both be zero
        make_raw_frame(f, 60);
        send(f);
        idle(40);

        phase.drop_objection(this, "t1c_hash_known_vectors");
    endtask

endclass : t1c_hash_known_vectors


// -----------------------------------------------------------------------------
// t1c_hash_flow_spread - distinct flows must produce distinct hashes. This is
// the property RSS actually depends on; a DUT that hashed only the addresses
// would pass the type checks and fail here.
// -----------------------------------------------------------------------------
class t1c_hash_flow_spread extends tier1c_base_test;

    `uvm_component_utils(t1c_hash_flow_spread)

    function new(string name = "t1c_hash_flow_spread", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        byte unsigned f [];

        phase.raise_objection(this, "t1c_hash_flow_spread");
        apply_power_on_reset();
        idle(10);

        // Same address pair, different port pairs: only the ports vary, so the
        // hash must still change.
        for (int p = 0; p < 8; p++) begin
            make_ipv4_frame(f, 8'd6, 32'hC0A80101, 32'hC0A80102,
                            16'(1000 + p), 16'(2000 + p * 7), 32);
            send(f);
            idle(35);
        end

        // Same ports, different addresses.
        for (int a = 0; a < 8; a++) begin
            make_ipv4_frame(f, 8'd17, 32'h0A000000 + 32'(a),
                            32'h0B000000 + 32'(a * 3), 16'd53, 16'd53, 32);
            send(f);
            idle(35);
        end

        phase.drop_objection(this, "t1c_hash_flow_spread");
    endtask

endclass : t1c_hash_flow_spread


// -----------------------------------------------------------------------------
// t1c_random_stress - randomized frames, mixed protocols and lengths.
// -----------------------------------------------------------------------------
class t1c_random_stress extends tier1c_base_test;

    `uvm_component_utils(t1c_random_stress)

    function new(string name = "t1c_random_stress", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        byte unsigned f [];
        int           sel;

        phase.raise_objection(this, "t1c_random_stress");
        apply_power_on_reset();
        idle(10);

        for (int i = 0; i < 60; i++) begin
            sel = $urandom_range(0, 3);
            case (sel)
                0: make_ipv4_frame(f, 8'd6,  $urandom, $urandom,
                                   16'($urandom), 16'($urandom),
                                   $urandom_range(0, 200));
                1: make_ipv4_frame(f, 8'd17, $urandom, $urandom,
                                   16'($urandom), 16'($urandom),
                                   $urandom_range(0, 200));
                2: make_ipv4_frame(f, 8'd1,  $urandom, $urandom, 16'd0, 16'd0,
                                   $urandom_range(0, 200));
                default: make_raw_frame(f, $urandom_range(46, 200));
            endcase
            send(f, $urandom_range(0, 6));
            idle($urandom_range(25, 45));
        end
        idle(60);

        phase.drop_objection(this, "t1c_random_stress");
    endtask

endclass : t1c_random_stress


// -----------------------------------------------------------------------------
// t1c_tx_checksum - the transmit-side offload, which MODIFIES the datapath.
//
// tx_checksum sums over [csum_start, end), complements, and writes the result
// big-endian at csum_offset (tx_checksum.v:354-358, :412-413). Everything
// outside those two bytes must pass through untouched.
//
// The offset sweep includes ODD csum_start values on purpose. The RTL swaps the
// result bytes when the start offset is odd; ref_checksum assumes that swap
// merely undoes the bus-alignment shift and so performs no swap of its own.
// **If this test fails only on odd starts, that assumption is the culprit** -
// see the note in model/ref_checksum.sv.
// -----------------------------------------------------------------------------
class t1c_tx_checksum extends tier1c_base_test;

    `uvm_component_utils(t1c_tx_checksum)

    function new(string name = "t1c_tx_checksum", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_sb.check_tx   = 1'b1;   // this test DOES drive tx_checksum
        m_env.m_sb.check_csum = 1'b0;   // ...and not the receive stream
        m_env.m_sb.check_hash = 1'b0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        byte unsigned f [];

        phase.raise_objection(this, "t1c_tx_checksum");
        apply_power_on_reset();
        idle(10);

        // Baseline: a real IPv4/UDP frame, checksum into the UDP field.
        make_ipv4_frame(f, 8'd17, 32'hC0A80001, 32'hC0A80002, 16'd1234, 16'd5678, 32);
        tx_send(f, 1'b1, 8'd14, 8'd24);
        idle(60);

        // Disabled: the frame must come through completely unmodified.
        tx_send(f, 1'b0, 8'd14, 8'd24);
        idle(60);

        // Non-zero initial value.
        tx_send(f, 1'b1, 8'd14, 8'd24, 16'h1234);
        idle(60);

        // Start-offset sweep, EVEN and ODD.
        for (int st = 12; st <= 22; st++) begin
            tx_send(f, 1'b1, 8'(st), 8'd24);
            idle(50);
        end

        // Insertion-offset sweep.
        for (int off = 20; off <= 30; off += 2) begin
            tx_send(f, 1'b1, 8'd14, 8'(off));
            idle(50);
        end

        // Length sweep across beat boundaries.
        for (int len = 0; len <= 96; len += 8) begin
            make_ipv4_frame(f, 8'd6, 32'h0A000001, 32'h0A000002,
                            16'd80, 16'd9000, len);
            tx_send(f, 1'b1, 8'd14, 8'd24);
            idle(50);
        end
        idle(100);

        phase.drop_objection(this, "t1c_tx_checksum");
    endtask

endclass : t1c_tx_checksum

// -----------------------------------------------------------------------------
// t1c_cov_closure - directed stimulus for the cg_offload holes the random and
// known-vector tests never reach:
//   RX: IPv6 and VLAN-tagged frames (rx_hash detects IPv6 but must not hash it,
//       rx_hash.v:189; it has no VLAN parsing, so a tagged frame is "other"),
//       and every protocol at every length class relative to the 32-byte beat.
//   TX: enable x start parity (the RTL's byte-swap path, tx_checksum.v:292)
//       x checksum inserted before/after the summed region x init x length.
// Every frame is still fully checked by sb_offload.
// -----------------------------------------------------------------------------
class t1c_cov_closure extends tier1c_base_test;

    `uvm_component_utils(t1c_cov_closure)

    function new(string name = "t1c_cov_closure", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_sb.check_tx = 1'b1;    // this test drives both streams
    endfunction

    virtual task run_phase(uvm_phase phase);
        byte unsigned f [];
        // Total frame lengths spanning every cg_rx length class.
        int totals [] = '{40, 50, 64, 80, 95, 96, 97, 150};
        byte unsigned protos [] = '{8'd6, 8'd17, 8'd1};   // TCP, UDP, ICMP (IPv4, no L4 hash)
        int tx_starts [] = '{12, 13, 14, 15, 20, 34, 35};
        int tx_payload [] = '{10, 50, 120};                // short / mid / long frames

        phase.raise_objection(this, "t1c_cov_closure");
        apply_power_on_reset();
        idle(10);

        // ---- RX: IPv4 by protocol, at each length class ----------------------
        foreach (protos[p])
            foreach (totals[i]) begin
                make_ipv4_frame(f, protos[p], 32'h0A00_0001 + p, 32'h0A00_0101 + i,
                                16'(1000 + i), 16'(2000 + p), totals[i] - 38);
                send(f);
            end
        // ---- RX: IPv6, VLAN and other ethertypes, and sub-L3 lengths --------
        foreach (totals[i]) begin
            make_raw_frame(f, totals[i] - 14, 16'h86DD);  send(f);
            make_raw_frame(f, totals[i] - 14, 16'h8100);  send(f);
            make_raw_frame(f, totals[i] - 14, 16'h88F7);  send(f);
        end
        // Sub-L3 lengths with a NON-IP ethertype. Not truncated IPv4: a runt
        // IPv4 frame (<34 bytes) makes rx_hash hash stale bus bytes from the
        // previous frame (it reported type IPv4 for 33 bytes) - unreachable in
        // hardware, where the MAC pads every frame to 60 bytes, so it is not
        // stimulus this DUT must handle.
        for (int len = 20; len <= 33; len += 13) begin
            make_raw_frame(f, len - 14, 16'h88F7);        send(f);
        end
        idle(200);

        // ---- TX: the command-space sweep --------------------------------------
        foreach (tx_payload[l])
            foreach (tx_starts[s])
                for (int en = 0; en < 2; en++)
                    for (int pre = 0; pre < 2; pre++)          // offset before start?
                        for (int nz = 0; nz < 2; nz++) begin
                            int st  = tx_starts[s];
                            int off = pre ? st - 4 : st + 4;
                            make_ipv4_frame(f, 8'd17, 32'hC0A8_0001, 32'hC0A8_0002,
                                            16'd1234, 16'd5678, tx_payload[l]);
                            tx_send(f, bit'(en), 8'(st), 8'(off), nz ? 16'hBEEF : 16'h0000);
                            idle(4);
                        end
        idle(300);

        phase.drop_objection(this, "t1c_cov_closure");
    endtask

endclass : t1c_cov_closure

`endif // TIER1C_TESTS_SV

// SPDX-License-Identifier: BSD-2-Clause-Views
//
// Tier 6 end-to-end datapath tests - objective G5
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §1 G5 ("byte-exact packet match through
//              host memory model"), §5 Tier 6
// Introduced : G5 end-to-end datapath
//
// The whole NIC, the way software uses it: the driver (mqnic_drv, a
// transcription of upstream's mqnic.py) discovers the device over the BAR,
// builds event, completion, transmit and receive rings in host memory, and
// moves frames. The DUT fetches descriptors and packet data by DMA, sends
// frames to the MAC, receives frames from it, writes them into host buffers
// and reports completions - every step through mqnic_core_pcie_us's real
// Xilinx PCIe interface.
//
// sb_e2e checks both directions byte-exactly against the OTHER end: what left
// host memory against what reached the wire, and what arrived on the wire
// against what landed in host memory.
//
// PCIe settings follow upstream's own end-to-end test
// (test_mqnic_core_pcie_us.py:47-48): MPS 256, MRRS 512. The register tests'
// MRRS of 4096 would put RTL finding 2 (t3_mrrs4096_exact) on this path; that
// finding has its own test and is not what these tests are about.
// -----------------------------------------------------------------------------

`ifndef TIER6_E2E_TESTS_SV
`define TIER6_E2E_TESTS_SV

class tier6_e2e_base extends tier6_base_test;

    `uvm_component_utils(tier6_e2e_base)

    int unsigned n_txq = 1;
    int unsigned n_rxq = 1;

    // RX MAC line rate. The AXI-S bus itself carries 512 bits per 3.102 ns
    // (165 Gb/s); a 100G MAC delivers a frame no faster than (len + 20) bytes
    // at 100 Gb/s - preamble, SFD and the minimum inter-frame gap included -
    // which is how upstream's EthMac paces it (speed=100e9, ifg=12). Blasting
    // at bus rate overran the 32 KB RX FIFO in the first t6_e2e_rx run, and
    // with AXIS_ETH_RX_USE_READY = 0 the DUT then drops whole frames - correct
    // behaviour, but not what a rate-correct MAC would ever present. 0 = bus
    // rate, for the deliberate-overload test.
    real         rx_gbps = 100.0;

    // RX bytes allowed in flight inside the DUT (on the wire but not yet in
    // host memory). The DUT spends 150-250 ns per frame on descriptor fetch,
    // data DMA, completion and event writes (measured on t6_e2e_rx), so a
    // 100G burst of small frames builds a backlog faster than it drains, and
    // the RX FIFOs then drop whole frames - correct under overload, and tested
    // as such in t6_e2e_rx_overload. The functional tests keep half the 32 KB
    // RX FIFO in flight instead: still several frames deep, never overrun.
    // 0 = unlimited.
    int unsigned rx_inflight_limit = 16384;

    function new(string name = "tier6_e2e_base", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        m_env.e2e = 1'b1;
    endfunction

    // -------------------------------------------------------------------------
    // Reset, discover, open. Configuration pins are set while reset is held.
    // -------------------------------------------------------------------------
    protected task bring_up();
        fork
            begin
                @(posedge m_rst_vif.clk);
                m_cfg_vif.set_dev_ctrl(3'd1, 3'd2, 1'b1);   // MPS 256, MRRS 512, ext tags
                m_cfg_vif.max_payload_size      = 3'd1;
                m_cfg_vif.max_read_request_size = 3'd2;
            end
        join_none
        m_env.m_rq_axis_cfg.bp_profile   = BP_NONE;   // the hard IP's RQ is not a bottleneck
        m_env.m_host.rc.max_payload_size = 3'd1;
        m_env.m_host.rc.rcb_128b         = 1'b0;     // cfg_rcb_status = 0
        apply_power_on_reset();
        idle(400);                                   // pcie_us_cfg polling
        m_env.m_drv.init();
        m_env.m_drv.open(n_txq, n_rxq);
    endtask

    // An Ethernet frame: destination, source, EtherType 0x88B5 (local
    // experimental, so no offload treats it as IP), then a pattern that makes
    // every byte position distinguishable.
    protected function void make_frame(int unsigned len, int unsigned seed,
                                       output byte unsigned f[]);
        f = new[len];
        foreach (f[i]) f[i] = 8'(i * 7 + seed * 13 + (i >> 8));
        if (len >= 14) begin
            for (int i = 0; i < 6; i++) begin
                f[i]     = 8'hDA + 8'(i);
                f[6 + i] = 8'h5A + 8'(i);
            end
            f[12] = 8'h88;
            f[13] = 8'hB5;
        end
    endfunction

    // An Ethernet/IPv4/UDP frame with valid IP header checksum and a UDP
    // checksum field holding the pseudo-header sum, as Linux leaves it for
    // CHECKSUM_PARTIAL offload.
    protected function void make_udp(int unsigned payload_len, bit [15:0] sport,
                                     bit [15:0] dport, int unsigned seed,
                                     output byte unsigned f[]);
        int unsigned len  = 14 + 20 + 8 + payload_len;
        bit [31:0]   sum;
        bit [15:0]   ip_len  = 16'(20 + 8 + payload_len);
        bit [15:0]   udp_len = 16'(8 + payload_len);
        byte unsigned ip [];
        f = new[len];
        for (int i = 0; i < 6; i++) begin
            f[i]     = 8'hDA + 8'(i);
            f[6 + i] = 8'h5A + 8'(i);
        end
        f[12] = 8'h08; f[13] = 8'h00;
        // IPv4 header
        f[14] = 8'h45; f[15] = 8'h00;
        f[16] = ip_len[15:8]; f[17] = ip_len[7:0];
        f[18] = 8'(seed >> 8); f[19] = 8'(seed);
        f[20] = 8'h40; f[21] = 8'h00;
        f[22] = 8'd64; f[23] = 8'd17;
        f[24] = 8'h00; f[25] = 8'h00;
        f[26] = 8'd192; f[27] = 8'd168; f[28] = 8'd1; f[29] = 8'd100;
        f[30] = 8'd192; f[31] = 8'd168; f[32] = 8'd1; f[33] = 8'(101 + seed % 50);
        ip = new[20];
        for (int i = 0; i < 20; i++) ip[i] = f[14 + i];
        sum = 32'(~mqnic_vrf_pkg::ones_complement_sum16(ip, 0, 20) & 16'hFFFF);
        f[24] = sum[15:8]; f[25] = sum[7:0];
        // UDP header
        f[34] = sport[15:8]; f[35] = sport[7:0];
        f[36] = dport[15:8]; f[37] = dport[7:0];
        f[38] = udp_len[15:8]; f[39] = udp_len[7:0];
        f[40] = 8'h00; f[41] = 8'h00;
        for (int i = 0; i < int'(payload_len); i++) f[42 + i] = 8'(i + seed);
        // Pseudo-header sum into the checksum field (not complemented).
        sum = {f[26], f[27]} + {f[28], f[29]} + {f[30], f[31]} + {f[32], f[33]}
              + 32'd17 + 32'(udp_len);
        while (sum[31:16] != 0) sum = sum[15:0] + sum[31:16];
        f[40] = sum[15:8]; f[41] = sum[7:0];
    endfunction

    // Change an IPv4 frame's protocol and recompute its header checksum.
    protected function void set_ip_proto(ref byte unsigned f[], input byte unsigned proto);
        byte unsigned ip [];
        bit [15:0]    c;
        f[23] = proto;
        f[24] = 8'h00; f[25] = 8'h00;
        ip = new[20];
        for (int i = 0; i < 20; i++) ip[i] = f[14 + i];
        c = ~mqnic_vrf_pkg::ones_complement_sum16(ip, 0, 20);
        f[24] = c[15:8]; f[25] = c[7:0];
    endfunction

    // One frame into the DUT from the MAC. Line-rate pacing is the RX agent's
    // (axis_cfg.line_rate_gbps), applied beat by beat.
    protected task send_rx(byte unsigned f[], bit bad = 1'b0);
        axis_pkg::axis_packet_seq s = axis_pkg::axis_packet_seq::type_id::create("rx");
        int unsigned waited = 0;
        m_env.m_eth_rx_cfg.line_rate_gbps = rx_gbps;
        // Bounded: a frame the DUT dropped never leaves the pending set, and
        // an unbounded wait turned that into a 10 ms watchdog hang.
        if (rx_inflight_limit > 0)
            while (m_env.m_sb.rx_pending_bytes() + f.size() > rx_inflight_limit &&
                   waited < 200000) begin
                @(posedge m_rst_vif.clk);
                waited++;
            end
        if (waited >= 200000)
            `uvm_error(get_type_name(),
                $sformatf("%0d RX byte(s) still undelivered after %0d cycles - a frame was lost",
                          m_env.m_sb.rx_pending_bytes(), waited))
        s.payload = f;
        if (!s.randomize() with { user == 128'(bad); delay_start == 0; })
            `uvm_fatal(get_type_name(), "randomize failed")
        s.start(m_env.m_eth_rx.sequencer);
    endtask

    // Everything handed over has come out of the other end, and the DUT has
    // nothing in flight on PCIe.
    protected task wait_quiet(int unsigned max_cycles = 400000);
        int unsigned n = 0;
        while (n < max_cycles &&
               !(m_env.m_sb.pending_count() == 0 && m_env.m_drv.tx_idle() &&
                 m_env.m_host.is_idle())) begin
            @(posedge m_rst_vif.clk);
            n++;
        end
        if (n >= max_cycles)
            `uvm_error(get_type_name(),
                $sformatf({"datapath not quiet after %0d cycles: %0d TX frame(s) not seen on ",
                           "the MAC, %0d RX frame(s) not delivered, TX completions %0d/%0d, ",
                           "host idle %0b"},
                          max_cycles, m_env.m_sb.tx_pending(), m_env.m_sb.rx_pending(),
                          m_env.m_drv.n_tx_completed, m_env.m_drv.n_tx_sent,
                          m_env.m_host.is_idle()))
        else
            idle(200);
    endtask

    protected function void expect_counts(int unsigned tx, int unsigned rx);
        if (m_env.m_sb.n_tx_ok != tx)
            `uvm_error(get_type_name(),
                $sformatf("%0d TX frame(s) matched, expected %0d", m_env.m_sb.n_tx_ok, tx))
        if (m_env.m_sb.n_rx_ok != rx)
            `uvm_error(get_type_name(),
                $sformatf("%0d RX frame(s) matched, expected %0d", m_env.m_sb.n_rx_ok, rx))
    endfunction

endclass : tier6_e2e_base


// -----------------------------------------------------------------------------
// t6_e2e_init - the driver brings the interface up, and the device agrees.
//
// Discovery values are checked against the configuration this top is built
// with, and every queue the driver opened must read back enabled with the
// pointers the driver wrote.
// -----------------------------------------------------------------------------
class t6_e2e_init extends tier6_e2e_base;

    `uvm_component_utils(t6_e2e_init)

    function new(string name = "t6_e2e_init", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_sb.m_enable_end_check = 1'b0;     // no traffic by design
    endfunction

    virtual task run_phase(uvm_phase phase);
        mqnic_drv  d;
        bit [31:0] v;
        phase.raise_objection(this, "t6_e2e_init");
        n_txq = 2;
        n_rxq = 2;
        bring_up();
        d = m_env.m_drv;

        if (d.if_count != 1)    `uvm_error(get_type_name(), $sformatf("IF count %0d, built with 1", d.if_count))
        if (d.port_count != 1)  `uvm_error(get_type_name(), $sformatf("port count %0d, built with 1", d.port_count))
        if (d.sched_count != 1) `uvm_error(get_type_name(), $sformatf("scheduler count %0d, built with 1", d.sched_count))
        // TX_QUEUE_INDEX_WIDTH 13, RX 8, CQN 14, EQN 5 (mqnic_core_pcie_us.v).
        if (d.txq_count != 8192) `uvm_error(get_type_name(), $sformatf("TXQ count %0d, expected 8192", d.txq_count))
        if (d.rxq_count != 256)  `uvm_error(get_type_name(), $sformatf("RXQ count %0d, expected 256", d.rxq_count))
        if (d.eq_count != 32)    `uvm_error(get_type_name(), $sformatf("EQ count %0d, expected 32", d.eq_count))
        // RSS, PTP TS, TX csum, RX csum, RX hash, LFC, PFC all enabled here.
        if ((d.if_features & 32'h1F11) != 32'h1F11)
            `uvm_error(get_type_name(), $sformatf("IF features 0x%08h lack an enabled offload", d.if_features))
        if (d.max_tx_mtu != 9214 || d.max_rx_mtu != 9214)
            `uvm_error(get_type_name(), $sformatf("max MTU %0d/%0d, built with 9214", d.max_tx_mtu, d.max_rx_mtu))

        foreach (d.txqs[i]) begin
            m_env.m_host.read32(d.txqs[i].hw + 'h08, v);
            if (v[0] !== 1'b1) `uvm_error(get_type_name(), $sformatf("TXQ %0d reads back disabled (0x%08h)", i, v))
        end
        foreach (d.rxqs[i]) begin
            m_env.m_host.read32(d.rxqs[i].hw + 'h08, v);
            if (v[0] !== 1'b1) `uvm_error(get_type_name(), $sformatf("RXQ %0d reads back disabled (0x%08h)", i, v))
            m_env.m_host.read32(d.rxqs[i].hw + 'h10, v);
            if (v[15:0] != 16'(d.rxqs[i].prod))
                `uvm_error(get_type_name(),
                    $sformatf("RXQ %0d producer pointer reads 0x%04h, driver posted 0x%04h",
                              i, v[15:0], 16'(d.rxqs[i].prod)))
        end
        foreach (d.cqs[i]) begin
            m_env.m_host.read32(d.cqs[i].hw + 'h08, v);
            if (v[16] !== 1'b1) `uvm_error(get_type_name(), $sformatf("CQ %0d reads back disabled (0x%08h)", i, v))
        end
        m_env.m_host.read32(d.eqs[0].hw + 'h08, v);
        if (v[16] !== 1'b1) `uvm_error(get_type_name(), $sformatf("EQ 0 reads back disabled (0x%08h)", v))

        idle(200);
        phase.drop_objection(this, "t6_e2e_init");
    endtask

endclass : t6_e2e_init


// -----------------------------------------------------------------------------
// t6_e2e_tx - host memory to wire.
//
// Lengths straddle every boundary the transmit path cares about: the 42-byte
// first descriptor segment (mqnic.py:1516), the 64-byte MAC beat, DMA request
// and completion sizes (256 / 512), and the 4096-byte segment limit.
// -----------------------------------------------------------------------------
class t6_e2e_tx extends tier6_e2e_base;

    `uvm_component_utils(t6_e2e_tx)

    function new(string name = "t6_e2e_tx", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        int unsigned lens [] = '{60, 14, 41, 42, 43, 63, 64, 65, 127, 128, 129, 255, 256, 257,
                                 511, 512, 513, 1000, 1500, 1514, 2048, 4095, 4096, 4097, 8000};
        byte unsigned f [];
        phase.raise_objection(this, "t6_e2e_tx");
        bring_up();
        foreach (lens[i]) begin
            make_frame(lens[i], i, f);
            m_env.m_drv.xmit(f, 0);
        end
        wait_quiet();
        expect_counts(lens.size(), 0);
        phase.drop_objection(this, "t6_e2e_tx");
    endtask

endclass : t6_e2e_tx


// -----------------------------------------------------------------------------
// t6_e2e_rx - wire to host memory, same boundaries.
// -----------------------------------------------------------------------------
class t6_e2e_rx extends tier6_e2e_base;

    `uvm_component_utils(t6_e2e_rx)

    function new(string name = "t6_e2e_rx", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        int unsigned lens [] = '{60, 64, 65, 127, 128, 129, 255, 256, 257,
                                 511, 512, 513, 1000, 1500, 1514, 2048, 4095, 4096, 4097, 8000};
        byte unsigned f [];
        phase.raise_objection(this, "t6_e2e_rx");
        bring_up();
        foreach (lens[i]) begin
            make_frame(lens[i], 100 + i, f);
            send_rx(f);
        end
        wait_quiet();
        expect_counts(0, lens.size());
        phase.drop_objection(this, "t6_e2e_rx");
    endtask

endclass : t6_e2e_rx


// -----------------------------------------------------------------------------
// Base for tests that loop the TX MAC back into the RX MAC, as upstream's
// end-to-end test does (test_mqnic_core_pcie_us.py:374-381, loopback_enable).
// A frame then crosses the whole NIC twice: host memory -> wire -> host memory.
// -----------------------------------------------------------------------------
class tier6_e2e_loop_base extends tier6_e2e_base;

    `uvm_component_utils(tier6_e2e_loop_base)

    uvm_tlm_analysis_fifo #(axis_pkg::axis_item) m_tx_wire;
    bit m_loopback = 1'b0;

    function new(string name = "tier6_e2e_loop_base", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        m_tx_wire = new("m_tx_wire", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        m_env.m_eth_tx.ap.connect(m_tx_wire.analysis_export);
    endfunction

    // Every frame the DUT transmits is handed back to it, unchanged.
    protected task run_loopback();
        axis_pkg::axis_item it;
        byte unsigned       f [];
        forever begin
            m_tx_wire.get(it);
            if (m_loopback) begin
                f = it.data;
                send_rx(f);
            end
        end
    endtask

endclass : tier6_e2e_loop_base


// -----------------------------------------------------------------------------
// t6_e2e_loopback - upstream's "queue mapping offset test".
//
// Four RX queues. Indirection-table entry 0 is pointed at each queue in turn,
// frames are transmitted and looped back, and each must land in that queue -
// sb_e2e predicts the queue from the map the driver programmed.
// -----------------------------------------------------------------------------
class t6_e2e_loopback extends tier6_e2e_loop_base;

    `uvm_component_utils(t6_e2e_loopback)

    function new(string name = "t6_e2e_loopback", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        byte unsigned f [];
        int unsigned  n = 0;
        phase.raise_objection(this, "t6_e2e_loopback");
        n_txq = 1;
        n_rxq = 4;
        bring_up();
        fork run_loopback(); join_none
        m_loopback = 1'b1;
        for (int k = 0; k < 4; k++) begin
            m_env.m_drv.set_indir(0, k);
            m_env.m_drv.flush_writes();
            for (int j = 0; j < 4; j++) begin
                make_frame(64 + 300 * j + k, 10 * k + j, f);
                m_env.m_drv.xmit(f, 0);
                n++;
            end
            wait_quiet();
        end
        m_env.m_drv.set_indir(0, 0);
        expect_counts(n, n);
        foreach (m_env.m_drv.rxqs[i])
            if (m_env.m_drv.rxqs[i].n_done != 4)
                `uvm_error(get_type_name(),
                    $sformatf("RXQ %0d received %0d frame(s), expected 4", i, m_env.m_drv.rxqs[i].n_done))
        phase.drop_objection(this, "t6_e2e_loopback");
    endtask

endclass : t6_e2e_loopback


// -----------------------------------------------------------------------------
// t6_e2e_csum - checksum offload, both directions.
//
// TX: UDP/IPv4 frames are sent with the descriptor's checksum command
// (start 34 = UDP header, offset 6 = its checksum field), as Linux does for
// CHECKSUM_PARTIAL and as upstream's test does. sb_e2e predicts the inserted
// value with ref_checksum; independently, this test verifies that every UDP
// checksum on the wire VALIDATES (pseudo-header + segment sums to 0xFFFF) - a
// check that does not depend on the reference model being right.
// RX: each frame is fed back in, so the receive checksum in its completion is
// checked by sb_e2e. Payload lengths cover odd and even, short and long.
// -----------------------------------------------------------------------------
class t6_e2e_csum extends tier6_e2e_loop_base;

    `uvm_component_utils(t6_e2e_csum)

    function new(string name = "t6_e2e_csum", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // Valid UDP checksum over pseudo-header + UDP header + payload.
    protected function bit udp_valid(const ref byte unsigned f[]);
        bit [31:0]    sum;
        byte unsigned seg [];
        int unsigned  ulen;
        if (f.size() < 42) return 1'b0;
        ulen = f.size() - 34;
        seg  = new[ulen];
        for (int i = 0; i < int'(ulen); i++) seg[i] = f[34 + i];
        sum = 32'(mqnic_vrf_pkg::ones_complement_sum16(seg, 0, ulen));
        sum += {f[26], f[27]} + {f[28], f[29]} + {f[30], f[31]} + {f[32], f[33]}
               + 32'd17 + 32'(ulen);
        while (sum[31:16] != 0) sum = sum[15:0] + sum[31:16];
        return sum[15:0] == 16'hFFFF;
    endfunction

    virtual task run_phase(uvm_phase phase);
        int unsigned  plens [] = '{0, 1, 2, 17, 18, 64, 255, 256, 1000, 1001, 1472, 3000};
        byte unsigned f [];
        axis_pkg::axis_item it;
        int unsigned  n_valid = 0;
        phase.raise_objection(this, "t6_e2e_csum");
        bring_up();
        foreach (plens[i]) begin
            make_udp(plens[i], 16'(1000 + i), 16'(2000 + i), i, f);
            m_env.m_drv.xmit(f, 0, 1'b1, 34, 6);
            m_tx_wire.get(it);
            f = it.data;
            if (udp_valid(f)) n_valid++;
            else `uvm_error(get_type_name(),
                     $sformatf("UDP checksum on the wire does not validate (payload %0d B)", plens[i]))
            send_rx(f);
        end
        wait_quiet();
        expect_counts(plens.size(), plens.size());
        if (n_valid != plens.size())
            `uvm_error(get_type_name(), $sformatf("%0d/%0d UDP checksums valid", n_valid, plens.size()))
        phase.drop_objection(this, "t6_e2e_csum");
    endtask

endclass : t6_e2e_csum


// -----------------------------------------------------------------------------
// t6_e2e_rss - receive-side scaling, upstream's "queue mapping RSS mask test".
//
// RSS mask 3 and indirection entries 0-3 -> queues 0-3, then 64 UDP flows that
// differ only in destination port. sb_e2e checks every frame's queue against
// the Toeplitz hash (ref_hash, with the DUT's key) and the hash itself against
// the completion; this test additionally requires all four queues to be used.
// -----------------------------------------------------------------------------
class t6_e2e_rss extends tier6_e2e_base;

    `uvm_component_utils(t6_e2e_rss)

    function new(string name = "t6_e2e_rss", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        byte unsigned f [];
        int unsigned  used = 0;
        phase.raise_objection(this, "t6_e2e_rss");
        n_rxq = 4;
        bring_up();
        m_env.m_drv.set_rss_mask(32'h3);
        for (int k = 0; k < 4; k++) m_env.m_drv.set_indir(k, k);
        m_env.m_drv.flush_writes();
        for (int k = 0; k < 64; k++) begin
            make_udp(256, 16'd1, 16'(k), k, f);
            send_rx(f);
        end
        // A few non-IP frames: no hash, so they follow indirection entry 0.
        for (int k = 0; k < 4; k++) begin
            make_frame(200 + k, k, f);
            send_rx(f);
        end
        // IPv4 that is neither TCP nor UDP (ICMP): hashed on the addresses
        // only, hash type IPv4 without the port bit (rx_hash.v:268).
        for (int k = 0; k < 4; k++) begin
            make_udp(64, 16'd7, 16'd7, 200 + k, f);
            set_ip_proto(f, 8'd1);
            send_rx(f);
        end
        wait_quiet();
        expect_counts(0, 72);
        foreach (m_env.m_drv.rxqs[i]) if (m_env.m_drv.rxqs[i].n_done > 0) used++;
        if (used != 4)
            `uvm_error(get_type_name(), $sformatf("64 flows spread over %0d queue(s), expected 4", used))
        phase.drop_objection(this, "t6_e2e_rss");
    endtask

endclass : t6_e2e_rss


// -----------------------------------------------------------------------------
// t6_e2e_jumbo - the maximum frame sizes.
//
// TX up to 9213 B (mqnic.py requires len < MTU); RX up to the 9214 B MTU the
// driver programs. A jumbo frame spans three 4 KB descriptor segments and many
// MPS-sized TLPs in both directions.
// -----------------------------------------------------------------------------
class t6_e2e_jumbo extends tier6_e2e_base;

    `uvm_component_utils(t6_e2e_jumbo)

    function new(string name = "t6_e2e_jumbo", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        int unsigned  tx_lens [] = '{8192, 8193, 9000, 9213};
        int unsigned  rx_lens [] = '{8192, 9000, 9213, 9214};
        byte unsigned f [];
        phase.raise_objection(this, "t6_e2e_jumbo");
        bring_up();
        foreach (tx_lens[i]) begin make_frame(tx_lens[i], i, f); m_env.m_drv.xmit(f, 0); end
        foreach (rx_lens[i]) begin make_frame(rx_lens[i], 50 + i, f); send_rx(f); end
        wait_quiet();
        expect_counts(tx_lens.size(), rx_lens.size());
        phase.drop_objection(this, "t6_e2e_jumbo");
    endtask

endclass : t6_e2e_jumbo


// -----------------------------------------------------------------------------
// t6_e2e_ring_wrap - every ring wraps many times.
//
// 16-entry TX/RX/completion rings and a 16-entry event queue, 100 frames each
// way: producer and consumer pointers lap their rings six times, and the phase
// bit that marks a new completion or event flips on every lap. A driver or DUT
// that got the phase rule wrong would stall or re-read a stale entry here.
// -----------------------------------------------------------------------------
class t6_e2e_ring_wrap extends tier6_e2e_base;

    `uvm_component_utils(t6_e2e_ring_wrap)

    function new(string name = "t6_e2e_ring_wrap", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void start_of_simulation_phase(uvm_phase phase);
        super.start_of_simulation_phase(phase);
        m_env.m_drv.ring_log_size = 4;
        m_env.m_drv.eq_log_size   = 4;
        // A few frames in flight at most: an RX ring of 16, refilled in
        // batches of 8, must never run dry, or the DUT would (correctly) drop.
        rx_inflight_limit = 6000;
    endfunction

    protected task tx_side();
        byte unsigned f [];
        for (int i = 0; i < 100; i++) begin
            make_frame(60 + (i * 37) % 1400, i, f);
            m_env.m_drv.xmit(f, 0);
        end
    endtask

    protected task rx_side();
        byte unsigned f [];
        for (int i = 0; i < 100; i++) begin
            make_frame(60 + (i * 53) % 1400, 500 + i, f);
            send_rx(f);
        end
    endtask

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t6_e2e_ring_wrap");
        bring_up();
        fork
            tx_side();
            rx_side();
        join
        wait_quiet();
        expect_counts(100, 100);
        if (m_env.m_drv.eqs[0].cons < 16)
            `uvm_error(get_type_name(),
                $sformatf("event queue consumed only %0d event(s) - it never wrapped", m_env.m_drv.eqs[0].cons))
        phase.drop_objection(this, "t6_e2e_ring_wrap");
    endtask

endclass : t6_e2e_ring_wrap


// -----------------------------------------------------------------------------
// t6_e2e_desc_block1 - one descriptor per ring entry.
//
// The other tests use blocks of 4 (as mqnic.py does), so a TX frame is split
// 42 B + rest and RX buffers are four 4 KB segments. With a block of 1 the
// whole frame is one segment in both directions - the other descriptor path
// through the TX and RX engines.
// -----------------------------------------------------------------------------
class t6_e2e_desc_block1 extends tier6_e2e_base;

    `uvm_component_utils(t6_e2e_desc_block1)

    function new(string name = "t6_e2e_desc_block1", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void start_of_simulation_phase(uvm_phase phase);
        super.start_of_simulation_phase(phase);
        m_env.m_drv.desc_block = 1;
    endfunction

    virtual task run_phase(uvm_phase phase);
        int unsigned  tx_lens [] = '{14, 60, 64, 1514, 4096, 4097, 9000};
        int unsigned  rx_lens [] = '{60, 64, 1514, 4096, 4097, 9000};
        byte unsigned f [];
        phase.raise_objection(this, "t6_e2e_desc_block1");
        bring_up();
        foreach (tx_lens[i]) begin make_frame(tx_lens[i], i, f); m_env.m_drv.xmit(f, 0); end
        foreach (rx_lens[i]) begin make_frame(rx_lens[i], 20 + i, f); send_rx(f); end
        wait_quiet();
        expect_counts(tx_lens.size(), rx_lens.size());
        phase.drop_objection(this, "t6_e2e_desc_block1");
    endtask

endclass : t6_e2e_desc_block1


// -----------------------------------------------------------------------------
// t6_e2e_bad_frame - frames the MAC marks bad never reach the host.
//
// tuser[0] is the MAC's bad-frame flag (USER_BAD_FRAME_VALUE = 1,
// mqnic_port_rx.v:254); the RX frame FIFO drops such frames
// (DROP_BAD_FRAME, rx_fifo.v:126). Good and bad frames are interleaved, so a
// dropped frame that left debris behind would corrupt its neighbour.
// -----------------------------------------------------------------------------
class t6_e2e_bad_frame extends tier6_e2e_base;

    `uvm_component_utils(t6_e2e_bad_frame)

    function new(string name = "t6_e2e_bad_frame", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        byte unsigned f [];
        int unsigned  good = 0, bad = 0;
        bit           is_bad;
        phase.raise_objection(this, "t6_e2e_bad_frame");
        bring_up();
        for (int i = 0; i < 24; i++) begin
            is_bad = (i % 3 == 1);
            make_frame(64 + i * 97, i, f);
            send_rx(f, is_bad);
            if (is_bad) bad++; else good++;
        end
        wait_quiet();
        expect_counts(0, good);
        if (m_env.m_sb.n_rx_dropped_ok != bad)
            `uvm_error(get_type_name(),
                $sformatf("%0d bad frame(s) sent, scoreboard saw %0d", bad, m_env.m_sb.n_rx_dropped_ok))
        phase.drop_objection(this, "t6_e2e_bad_frame");
    endtask

endclass : t6_e2e_bad_frame


// -----------------------------------------------------------------------------
// t6_e2e_rx_overload - more traffic than the DUT can absorb.
//
// AXIS_ETH_RX_USE_READY = 0: the DUT cannot push back on the MAC, so when its
// RX FIFOs fill it must drop WHOLE frames (the port FIFO marks the frame in
// flight bad, MARK_WHEN_FULL; the frame FIFO discards it). Frames are sent at
// full bus rate with no in-flight limit. Required:
//   * some frames are dropped (otherwise this test proved nothing)
//   * every delivered frame is byte-exact and in order (sb_e2e overload mode)
//   * afterwards the datapath recovers: a paced batch is delivered in full.
// -----------------------------------------------------------------------------
class t6_e2e_rx_overload extends tier6_e2e_base;

    `uvm_component_utils(t6_e2e_rx_overload)

    function new(string name = "t6_e2e_rx_overload", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        byte unsigned f [];
        int unsigned  delivered_burst;
        phase.raise_objection(this, "t6_e2e_rx_overload");
        bring_up();

        m_env.m_sb.allow_rx_drops = 1'b1;
        rx_gbps           = 0.0;
        rx_inflight_limit = 0;
        for (int i = 0; i < 48; i++) begin
            make_frame(1500 + (i * 211) % 2600, i, f);
            send_rx(f);
        end
        idle(60000);
        m_env.m_sb.settle_drops();
        delivered_burst = m_env.m_sb.n_rx_ok;
        `uvm_info(get_type_name(),
            $sformatf("overload burst: 48 sent, %0d delivered, %0d dropped",
                      delivered_burst, m_env.m_sb.n_rx_overload_drops), UVM_LOW)
        if (m_env.m_sb.n_rx_overload_drops == 0)
            `uvm_error(get_type_name(), "no frame was dropped - the burst did not overload the DUT")
        if (delivered_burst == 0)
            `uvm_error(get_type_name(), "nothing was delivered during the overload")
        if (delivered_burst + m_env.m_sb.n_rx_overload_drops != 48)
            `uvm_error(get_type_name(),
                $sformatf("%0d delivered + %0d dropped != 48 sent",
                          delivered_burst, m_env.m_sb.n_rx_overload_drops))

        // Recovery, under the normal rules.
        m_env.m_sb.allow_rx_drops = 1'b0;
        rx_gbps           = 100.0;
        rx_inflight_limit = 16384;
        for (int i = 0; i < 16; i++) begin
            make_frame(64 + i * 150, 100 + i, f);
            send_rx(f);
        end
        wait_quiet();
        expect_counts(0, delivered_burst + 16);
        phase.drop_objection(this, "t6_e2e_rx_overload");
    endtask

endclass : t6_e2e_rx_overload


// -----------------------------------------------------------------------------
// t6_e2e_stress - everything at once, randomized.
//
// 4 TX and 4 RX queues with RSS; TX and RX concurrently; random frame lengths
// (with occasional jumbo), random TX queue, random TX buffer alignment, UDP
// frames with checksum offload mixed with raw frames; TX MAC back-pressure,
// root-complex completion reordering, and windows with no PCIe transmit
// credits. Every frame is still checked byte-exact by sb_e2e.
// -----------------------------------------------------------------------------
class t6_e2e_stress extends tier6_e2e_base;

    `uvm_component_utils(t6_e2e_stress)

    virtual pcie_us_fc_if m_fc_vif;
    int unsigned n_frames = 120;
    protected bit m_done;

    function new(string name = "t6_e2e_stress", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual pcie_us_fc_if)::get(this, "", "fc_vif", m_fc_vif))
            `uvm_fatal(get_type_name(), "fc_vif not set")
    endfunction

    virtual function void start_of_simulation_phase(uvm_phase phase);
        super.start_of_simulation_phase(phase);
        m_env.m_drv.random_tx_offset = 1'b1;
    endfunction

    protected function int unsigned rand_len();
        int unsigned r = $urandom_range(0, 99);
        if (r < 40) return $urandom_range(60, 256);
        if (r < 85) return $urandom_range(257, 2048);
        if (r < 97) return $urandom_range(2049, 6000);
        return $urandom_range(6001, 9213);
    endfunction

    protected task tx_side();
        byte unsigned f [];
        int unsigned  q;
        for (int i = 0; i < int'(n_frames); i++) begin
            q = $urandom_range(0, 3);
            if ($urandom_range(0, 1)) begin
                make_udp(rand_len() % 1400, 16'($urandom), 16'($urandom), i, f);
                m_env.m_drv.xmit(f, q, 1'b1, 34, 6);
            end
            else begin
                make_frame(rand_len(), i, f);
                m_env.m_drv.xmit(f, q);
            end
            if ($urandom_range(0, 3) == 0) idle($urandom_range(1, 200));
        end
    endtask

    protected task rx_side();
        byte unsigned f [];
        for (int i = 0; i < int'(n_frames); i++) begin
            if ($urandom_range(0, 2))
                make_udp(rand_len() % 1400, 16'($urandom), 16'($urandom), 1000 + i, f);
            else
                make_frame(rand_len(), 1000 + i, f);
            send_rx(f);
        end
    endtask

    protected task credit_side();
        while (!m_done) begin
            idle($urandom_range(500, 3000));
            case ($urandom_range(0, 2))
                0: m_fc_vif.starve_all();
                1: m_fc_vif.starve_np();
                default: m_fc_vif.starve_p();
            endcase
            idle($urandom_range(20, 300));
            m_fc_vif.init_unlimited();
        end
    endtask

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t6_e2e_stress");
        n_txq = 4;
        n_rxq = 4;
        bring_up();
        m_env.m_drv.set_rss_mask(32'h3);
        for (int k = 0; k < 4; k++) m_env.m_drv.set_indir(k, k);
        m_env.m_drv.flush_writes();
        m_env.m_eth_tx_cfg.bp_profile = BP_RANDOM;
        m_env.m_host.rc.reorder_depth = 4;
        m_done = 1'b0;

        fork
            credit_side();
        join_none
        fork
            tx_side();
            rx_side();
        join
        m_done = 1'b1;
        m_fc_vif.init_unlimited();
        wait_quiet(800000);
        expect_counts(n_frames, n_frames);
        phase.drop_objection(this, "t6_e2e_stress");
    endtask

endclass : t6_e2e_stress

`endif // TIER6_E2E_TESTS_SV

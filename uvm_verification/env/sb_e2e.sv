// SPDX-License-Identifier: BSD-2-Clause-Views
//
// sb_e2e - end-to-end datapath scoreboard (objective G5)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §1 G5, §11
// Introduced : G5 end-to-end datapath
//
// G5's acceptance criterion is "byte-exact packet match through host memory
// model". Both directions are checked against what the OTHER end saw, never
// against what the stimulus intended:
//
//   TX   expected = the frame the driver wrote into HOST MEMORY (plus the
//        checksum ref_checksum says the offload inserts)
//        actual   = the frame the TX MAC agent observed on the wire
//
//   RX   expected = the frame the RX MAC agent observed going INTO the DUT
//        actual   = the bytes the driver read back out of host memory at the
//                   buffer the completion pointed to, with the queue, the
//                   receive checksum and the RSS hash from that completion
//
// TX ORDER. The scheduler interleaves queues, so frames from different TX
// queues may legally overtake each other; within one queue they may not. An
// observed frame must match the HEAD of one queue's FIFO - not merely any
// pending frame - which keeps the per-queue ordering check honest.
//
// RX ORDER. Frames are in order WITHIN a receive queue only: the DUT works on
// several queues at once and the driver drains them in event order, so
// across queues the host may see them in any order. A delivered frame must be
// the OLDEST frame still expected for its queue.
//
// RX QUEUE PREDICTION. queue = indir[(dest & app_mask) + (hash & rss_mask)]
// (mqnic_rx_queue_map.v:257-276), with dest = 0 because the MAC supplies none.
// The driver reports every map write here, so the prediction follows the
// programmed state rather than a test's belief about it.
// -----------------------------------------------------------------------------

`ifndef SB_E2E_SV
`define SB_E2E_SV

// One packet as the driver sees it, in either direction.
class mqnic_e2e_pkt extends uvm_sequence_item;

    `uvm_object_utils(mqnic_e2e_pkt)

    byte unsigned data [];
    int           queue = -1;

    // TX: the checksum offload command the descriptor carried.
    bit           csum_enable;
    int unsigned  csum_start;
    int unsigned  csum_offset;     // relative to csum_start, as in the descriptor

    // RX: what the completion reported.
    bit [15:0]    rx_csum;
    bit [31:0]    rx_hash;
    bit [7:0]     rx_hash_type;
    bit [31:0]    ts_ns;
    bit [15:0]    ts_s;

    function new(string name = "mqnic_e2e_pkt");
        super.new(name);
    endfunction

    virtual function string convert2string();
        return $sformatf("len=%0d queue=%0d csum_en=%0b start=%0d off=%0d rx_csum=0x%04h hash=0x%08h/%0h %s",
                         data.size(), queue, csum_enable, csum_start, csum_offset,
                         rx_csum, rx_hash, rx_hash_type,
                         mqnic_vrf_pkg::bytes2str(data, 24));
    endfunction

endclass : mqnic_e2e_pkt


`uvm_analysis_imp_decl(_e2e_tx_exp)
`uvm_analysis_imp_decl(_e2e_tx_mac)
`uvm_analysis_imp_decl(_e2e_rx_mac)
`uvm_analysis_imp_decl(_e2e_rx_host)

class sb_e2e extends mqnic_scoreboard_base;

    `uvm_component_utils(sb_e2e)

    uvm_analysis_imp_e2e_tx_exp  #(mqnic_e2e_pkt,       sb_e2e) tx_exp_imp;
    uvm_analysis_imp_e2e_tx_mac  #(axis_pkg::axis_item, sb_e2e) tx_mac_imp;
    uvm_analysis_imp_e2e_rx_mac  #(axis_pkg::axis_item, sb_e2e) rx_mac_imp;
    uvm_analysis_imp_e2e_rx_host #(mqnic_e2e_pkt,       sb_e2e) rx_host_imp;

    ref_checksum m_csum;
    ref_hash     m_hash;

    // Feature bits read from IF_CTRL by the driver; the RX completion fields
    // are only meaningful where the feature exists.
    bit          rx_csum_feature = 1'b1;
    bit          rx_hash_feature = 1'b1;

    // Queue map state (one port).
    bit [31:0]   rss_mask = '0;
    bit [31:0]   app_mask = '0;
    int unsigned indir [bit [7:0]];

    protected byte unsigned m_tx_exp [int][$][];     // per TX queue, in order
    protected bit           m_tx_csum [int][$];      // offload used, same order
    protected int unsigned  m_tx_pending;

    typedef struct {
        byte unsigned data [];
        int           queue;
        bit [15:0]    csum;
        bit [31:0]    hash;
        bit [3:0]     hash_type;
        bit           bad;
    } rx_exp_t;
    protected rx_exp_t      m_rx_exp [$];

    // Overload mode. With AXIS_ETH_RX_USE_READY = 0 the DUT cannot push back
    // on the MAC, so under overload it drops WHOLE frames at its RX FIFOs. In
    // this mode a frame may be missing, but what does arrive must still be an
    // in-order subsequence of what went in, each frame byte-exact - a frame
    // that arrives truncated, merged or out of order is still an error.
    bit          allow_rx_drops = 1'b0;
    int unsigned n_rx_overload_drops;

    int unsigned n_tx_ok, n_rx_ok, n_rx_dropped_ok;

    // ---- functional coverage: what actually crossed the NIC -----------------
    // Sampled on MATCHED frames only, so a bin is evidence of a frame that
    // went through correctly, not merely of one that was offered.
    protected bit          s_rx;          // 0 = TX, 1 = RX
    protected int unsigned s_len;
    protected int unsigned s_queue;
    protected bit          s_csum;        // TX checksum offload used
    protected bit [3:0]    s_hash_type;   // RX: none / IPv4 / IPv4+UDP / IPv4+TCP

    covergroup cg_e2e;
        option.per_instance = 1;
        cp_dir : coverpoint s_rx { bins tx = {0}; bins rx = {1}; }
        // Boundaries the datapath cares about: the 42-byte first TX segment,
        // one 64-byte beat, MPS (256), a 4 KB descriptor segment, jumbo.
        cp_len : coverpoint s_len {
            bins b_tiny     = {[1:41]};
            bins b_min_eth  = {[42:64]};
            bins b_short    = {[65:256]};
            bins b_medium   = {[257:1514]};
            bins b_large    = {[1515:4096]};
            bins b_multiseg = {[4097:8192]};
            bins b_jumbo    = {[8193:9214]};
        }
        cp_queue : coverpoint s_queue { bins q[] = {[0:3]}; }
        cp_csum  : coverpoint s_csum iff (!s_rx) { bins off = {0}; bins on = {1}; }
        cp_hash  : coverpoint s_hash_type iff (s_rx) {
            bins none    = {4'b0000};
            bins ipv4    = {4'b0001};
            bins ipv4udp = {4'b1001};
        }
        x_dir_len   : cross cp_dir, cp_len {
            // The MAC's minimum frame is 60 B; RX is never offered less.
            ignore_bins rx_tiny = binsof(cp_dir.rx) && binsof(cp_len.b_tiny);
        }
        x_dir_queue : cross cp_dir, cp_queue;
    endgroup
    longint unsigned n_tx_bytes, n_rx_bytes;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        cg_e2e      = new();
        tx_exp_imp  = new("tx_exp_imp",  this);
        tx_mac_imp  = new("tx_mac_imp",  this);
        rx_mac_imp  = new("rx_mac_imp",  this);
        rx_host_imp = new("rx_host_imp", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        byte unsigned key [];
        bit [319:0]   k = 320'h6d5a56da255b0ec24167253d43a38fb0d0ca2bcbae7b30b477cb2da38030f20c6a42b73bbeac01fa;
        super.build_phase(phase);
        m_csum = ref_checksum::type_id::create("m_csum");
        m_hash = ref_hash::type_id::create("m_hash");
        // The key the DUT is built with (mqnic_ingress.v:107), byte 0 first.
        key = new[40];
        foreach (key[i]) key[i] = k[319 - i*8 -: 8];
        m_hash.set_key(key);
        indir[8'd0] = 0;
        cg_e2e.set_inst_name({get_full_name(), ".cg_e2e"});
    endfunction

    // =========================================================================
    // Queue map (driver -> scoreboard)
    // =========================================================================
    virtual function void set_indir(int unsigned index, int unsigned queue);
        indir[8'(index)] = queue;
    endfunction

    virtual function int unsigned predict_queue(bit [31:0] hash);
        bit [7:0] idx = 8'((32'd0 & app_mask) + (hash & rss_mask));
        return indir.exists(idx) ? indir[idx] : 0;
    endfunction

    // =========================================================================
    // TX
    // =========================================================================
    virtual function void write_e2e_tx_exp(mqnic_e2e_pkt p);
        byte unsigned exp [];
        m_csum.tx_expected(p.data, p.csum_enable, int'(p.csum_start),
                           int'(p.csum_start + p.csum_offset), 16'h0, exp);
        m_tx_exp[p.queue].push_back(exp);
        m_tx_csum[p.queue].push_back(p.csum_enable);
        m_tx_pending++;
        note_expected();
    endfunction

    virtual function void write_e2e_tx_mac(axis_pkg::axis_item t);
        int hit = -1;
        byte unsigned head [];
        byte unsigned got  [];
        got = t.data;
        note_actual();
        foreach (m_tx_exp[q]) begin
            if (m_tx_exp[q].size() == 0) continue;
            head = m_tx_exp[q][0];          // a copy: never const-ref a queue element
            if (same(head, got)) begin
                hit = q;
                break;
            end
        end
        if (hit < 0) begin
            mismatch($sformatf("TX frame on the MAC matches no queue's next frame (%0d pending)",
                               m_tx_pending),
                     describe_tx_heads(),
                     $sformatf("len=%0d %s", got.size(), mqnic_vrf_pkg::bytes2str(got, 32)));
            return;
        end
        void'(m_tx_exp[hit].pop_front());
        s_csum = m_tx_csum[hit].pop_front();
        m_tx_pending--;
        s_rx = 1'b0; s_len = got.size(); s_queue = hit;
        cg_e2e.sample();
        n_tx_ok++;
        n_tx_bytes += t.data.size();
        note_match($sformatf("TX frame from queue %0d, %0d B", hit, t.data.size()));
    endfunction

    protected function string describe_tx_heads();
        string s = "";
        byte unsigned head [];
        foreach (m_tx_exp[q])
            if (m_tx_exp[q].size() > 0) begin
                head = m_tx_exp[q][0];
                s = {s, $sformatf("q%0d: len=%0d %s; ", q, head.size(),
                                  mqnic_vrf_pkg::bytes2str(head, 16))};
            end
        return (s == "") ? "nothing" : s;
    endfunction

    // =========================================================================
    // RX
    // =========================================================================
    virtual function void write_e2e_rx_mac(axis_pkg::axis_item t);
        rx_exp_t      e;
        bit [3:0]     ht;
        bit [31:0]    h;
        byte unsigned d [];
        d       = t.data;
        e.data  = d;
        e.bad   = t.user[0];
        m_hash.predict(d, h, ht);
        e.hash      = h;
        e.hash_type = ht;
        e.csum  = m_csum.rx_expected(d);
        e.queue = int'(predict_queue(e.hash));
        if (e.bad) begin
            // A frame the MAC marks bad must never reach the host.
            n_rx_dropped_ok++;
            return;
        end
        m_rx_exp.push_back(e);
        note_expected();
    endfunction

    virtual function void write_e2e_rx_host(mqnic_e2e_pkt p);
        rx_exp_t      e;
        byte unsigned exp [];
        byte unsigned got [];
        note_actual();
        if (m_rx_exp.size() == 0) begin
            mismatch("packet delivered to the host that the MAC never received",
                     "nothing", p.convert2string());
            return;
        end
        got = p.data;
        begin
            int first = -1;     // oldest frame expected on this queue
            int hit   = -1;     // the frame this delivery is
            foreach (m_rx_exp[i]) begin
                if (m_rx_exp[i].queue != p.queue) continue;
                if (first < 0) first = i;
                exp = m_rx_exp[i].data;
                if (same(exp, got)) begin hit = i; break; end
                // In-order: only the oldest may match, unless the DUT is
                // allowed to have dropped the ones in between.
                if (!allow_rx_drops) break;
            end
            if (hit < 0) begin
                foreach (m_rx_exp[i]) begin
                    exp = m_rx_exp[i].data;
                    if (same(exp, got)) begin
                        mismatch("RX packet delivered to the wrong queue",
                                 $sformatf("queue %0d (hash 0x%08h)", m_rx_exp[i].queue, m_rx_exp[i].hash),
                                 $sformatf("queue %0d", p.queue));
                        m_rx_exp.delete(i);
                        return;
                    end
                end
                if (first < 0)
                    mismatch($sformatf("packet delivered on queue %0d, where no frame is expected", p.queue),
                             "nothing", $sformatf("len=%0d %s", got.size(), mqnic_vrf_pkg::bytes2str(got, 32)));
                else begin
                    exp = m_rx_exp[first].data;
                    mismatch($sformatf("RX packet on queue %0d is not the next frame expected there", p.queue),
                             $sformatf("len=%0d %s", exp.size(), mqnic_vrf_pkg::bytes2str(exp, 32)),
                             $sformatf("len=%0d %s", got.size(), mqnic_vrf_pkg::bytes2str(got, 32)),
                             first_diff(exp, got));
                    m_rx_exp.delete(first);
                end
                return;
            end
            // Overload mode: same-queue frames older than this one were dropped.
            for (int i = hit - 1; i >= 0; i--)
                if (m_rx_exp[i].queue == p.queue) begin
                    m_rx_exp.delete(i);
                    n_rx_overload_drops++;
                    hit--;
                end
            e = m_rx_exp[hit];
            m_rx_exp.delete(hit);
        end
        exp = e.data;
        if (!same(exp, got)) begin
            mismatch("RX packet contents differ from the frame on the wire",
                     $sformatf("len=%0d %s", exp.size(), mqnic_vrf_pkg::bytes2str(exp, 32)),
                     $sformatf("len=%0d %s", got.size(), mqnic_vrf_pkg::bytes2str(got, 32)),
                     first_diff(exp, got));
            return;
        end
        if (p.queue != e.queue) begin
            mismatch("RX packet delivered to the wrong queue",
                     $sformatf("queue %0d (hash 0x%08h)", e.queue, e.hash),
                     $sformatf("queue %0d", p.queue));
            return;
        end
        if (rx_csum_feature && p.rx_csum != e.csum) begin
            mismatch("RX checksum in the completion is wrong",
                     $sformatf("0x%04h", e.csum), $sformatf("0x%04h", p.rx_csum),
                     $sformatf("len=%0d", e.data.size()));
            return;
        end
        if (rx_hash_feature && (p.rx_hash != e.hash || p.rx_hash_type[3:0] != e.hash_type)) begin
            mismatch("RX hash in the completion is wrong",
                     $sformatf("0x%08h type 0x%0h", e.hash, e.hash_type),
                     $sformatf("0x%08h type 0x%0h", p.rx_hash, p.rx_hash_type));
            return;
        end
        n_rx_ok++;
        n_rx_bytes += p.data.size();
        s_rx = 1'b1; s_len = p.data.size(); s_queue = p.queue; s_hash_type = e.hash_type;
        cg_e2e.sample();
        note_match($sformatf("RX frame to queue %0d, %0d B", p.queue, p.data.size()));
    endfunction

    // =========================================================================
    protected function void mismatch(string what, string exp, string act, string extra = "");
        note_mismatch((extra == "") ? what : {what, " - ", extra}, exp, act);
    endfunction

    protected function bit same(const ref byte unsigned a[], const ref byte unsigned b[]);
        if (a.size() != b.size()) return 1'b0;
        foreach (a[i]) if (a[i] !== b[i]) return 1'b0;
        return 1'b1;
    endfunction

    protected function string first_diff(const ref byte unsigned a[], const ref byte unsigned b[]);
        int n = (a.size() < b.size()) ? a.size() : b.size();
        for (int i = 0; i < n; i++)
            if (a[i] !== b[i])
                return $sformatf("first difference at byte %0d: 0x%02h vs 0x%02h", i, a[i], b[i]);
        return $sformatf("lengths %0d vs %0d", a.size(), b.size());
    endfunction

    virtual function int unsigned pending_count();
        return m_tx_pending + (allow_rx_drops ? 0 : m_rx_exp.size());
    endfunction

    // Overload mode: whatever is still expected at the end was dropped.
    virtual function void settle_drops();
        if (!allow_rx_drops) return;
        n_rx_overload_drops += m_rx_exp.size();
        m_rx_exp.delete();
    endfunction

    virtual function int unsigned tx_pending();
        return m_tx_pending;
    endfunction

    virtual function int unsigned rx_pending();
        return m_rx_exp.size();
    endfunction

    // Bytes on the wire that have not yet reached host memory.
    virtual function int unsigned rx_pending_bytes();
        int unsigned n = 0;
        foreach (m_rx_exp[i]) n += m_rx_exp[i].data.size();
        return n;
    endfunction

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf("TX: %0d frame(s) / %0d B matched | RX: %0d frame(s) / %0d B matched, %0d bad frame(s) dropped, %0d dropped under overload | coverage %.1f%%",
                      n_tx_ok, n_tx_bytes, n_rx_ok, n_rx_bytes, n_rx_dropped_ok, n_rx_overload_drops,
                      cg_e2e.get_inst_coverage()), UVM_LOW)
    endfunction

endclass : sb_e2e

`endif // SB_E2E_SV

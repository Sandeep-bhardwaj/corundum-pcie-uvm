// SPDX-License-Identifier: BSD-2-Clause-Views
//
// dma_ram_driver / dma_ram_responder
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.4
// Introduced : Step 4 (Tier 2)
//
// dma_ram_driver    MODE_ACTIVE_MASTER - drives commands (Tier 2: DUT is the RAM)
// dma_ram_responder MODE_ACTIVE_SLAVE  - models the RAM  (Tier 3: DUT is the initiator)
//
// SEQUENCE COMPLETION IS NOT TRAFFIC COMPLETION.
//
// This driver accepts an item, routes it into a per-segment queue and returns
// item_done() immediately - that is what lets the segment servers run
// concurrently. The consequence is that seq.start() returns when every item has
// been QUEUED, not when the DUT has seen it. A test that follows seq.start()
// with a drain-wait on bus activity alone will find nothing outstanding and
// finish before the traffic happens.
//
// pending_items() therefore reports queued-plus-in-flight work, and a test must
// wait on BOTH that and the monitor's outstanding_reads(). VCS found this the
// hard way: t2_seg_independent_backpressure issued 5 of its 64 reads before the
// run ended, and reported a green-looking 35 matches for traffic that had
// barely started.
//
// PER-SEGMENT CONCURRENCY IS THE POINT. The driver does not drive one item at a
// time: it forks a server per segment, each with its own queue, and the
// sequencer thread only routes items into those queues. Segments therefore
// progress independently and can stall independently, which is the only way to
// exercise what STRATEGY §7.4 calls out - "any subset of segments active in a
// cycle". A serial driver would issue a clean one-segment-at-a-time pattern
// that no real DMA client ever produces.
// -----------------------------------------------------------------------------

`ifndef DMA_RAM_DRIVER_SV
`define DMA_RAM_DRIVER_SV

class dma_ram_driver extends uvm_driver #(dma_ram_item);

    `uvm_component_utils(dma_ram_driver)

    virtual dma_ram_if vif;
    dma_ram_cfg        cfg;

    // One pending queue per segment, plus a busy flag for the item a server has
    // popped but not yet finished driving. Both count as outstanding work.
    protected dma_ram_item m_q    [8][$];
    protected bit          m_busy [8];

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual dma_ram_if)::get(this, "", "vif", vif))
            `uvm_fatal(get_type_name(), "no dma_ram_if in config_db under key vif")
        if (!uvm_config_db #(dma_ram_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "no dma_ram_cfg in config_db under key cfg")
        foreach (m_busy[i]) m_busy[i] = 1'b0;
    endfunction

    // Items queued but not yet driven onto the bus, plus any item currently
    // mid-handshake. See the file header - a test must drain on this as well as
    // on bus activity.
    virtual function int unsigned pending_items();
        int unsigned n = 0;
        for (int s = 0; s < int'(cfg.seg_count); s++) begin
            n += m_q[s].size();
            if (m_busy[s]) n++;
        end
        return n;
    endfunction

    virtual task run_phase(uvm_phase phase);
        vif.init_idle_initiator();

        // Only start the servers for the channels this agent owns - the async
        // RAM splits write and read across two clock domains.
        for (int s = 0; s < int'(cfg.seg_count); s++) begin
            automatic int seg = s;
            if (cfg.has_wr()) fork wr_server(seg); join_none
            if (cfg.has_rd()) fork rd_server(seg); join_none
        end
        if (cfg.has_rd()) fork rd_resp_consumer(); join_none

        forever begin
            seq_item_port.get_next_item(req);
            if (req.seg >= cfg.seg_count) begin
                `uvm_error(get_type_name(),
                    $sformatf("item targets segment %0d but only %0d are configured",
                              req.seg, cfg.seg_count))
            end
            else begin
                m_q[req.seg].push_back(req);
            end
            seq_item_port.item_done();
        end
    endtask

    // -------------------------------------------------------------------------
    protected virtual task wr_server(int seg);
        dma_ram_item it;
        int aw = int'(cfg.seg_addr_width);
        int dw = int'(cfg.seg_data_width);
        int bw = int'(cfg.seg_be_width());
        int sw = int'(cfg.sel_width);

        forever begin
            @(vif.init_cb);
            if (vif.rst === 1'b1) continue;
            if (m_q[seg].size() == 0) continue;
            if (m_q[seg][0].kind != DMA_RAM_WRITE) continue;

            m_busy[seg] = 1'b1;
            it = m_q[seg].pop_front();
            repeat (it.delay) @(vif.init_cb);

            vif.init_cb.wr_cmd_addr[seg*DMA_RAM_MAX_SEG_ADDR_WIDTH +: 16] <= 16'(it.addr);
            vif.init_cb.wr_cmd_data[seg*DMA_RAM_MAX_SEG_DATA_WIDTH +: 256] <= it.data;
            vif.init_cb.wr_cmd_be[seg*DMA_RAM_MAX_SEG_BE_WIDTH +: 32]     <= it.be;
            if (cfg.has_sel)
                vif.init_cb.wr_cmd_sel[seg*DMA_RAM_MAX_SEL_WIDTH +: 8]    <= it.sel;
            vif.init_cb.wr_cmd_valid[seg] <= 1'b1;

            do @(vif.init_cb); while (vif.init_cb.wr_cmd_ready[seg] !== 1'b1);
            vif.init_cb.wr_cmd_valid[seg] <= 1'b0;
            it.stamp = $time;
            m_busy[seg] = 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    protected virtual task rd_server(int seg);
        dma_ram_item it;

        forever begin
            @(vif.init_cb);
            if (vif.rst === 1'b1) continue;
            if (m_q[seg].size() == 0) continue;
            if (m_q[seg][0].kind != DMA_RAM_READ) continue;

            m_busy[seg] = 1'b1;
            it = m_q[seg].pop_front();
            repeat (it.delay) @(vif.init_cb);

            vif.init_cb.rd_cmd_addr[seg*DMA_RAM_MAX_SEG_ADDR_WIDTH +: 16] <= 16'(it.addr);
            if (cfg.has_sel)
                vif.init_cb.rd_cmd_sel[seg*DMA_RAM_MAX_SEL_WIDTH +: 8]    <= it.sel;
            vif.init_cb.rd_cmd_valid[seg] <= 1'b1;

            do @(vif.init_cb); while (vif.init_cb.rd_cmd_ready[seg] !== 1'b1);
            vif.init_cb.rd_cmd_valid[seg] <= 1'b0;
            it.stamp = $time;
            m_busy[seg] = 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Read-response consumer. Independently shaped per segment - see
    // dma_ram_cfg.bp_profile.
    // -------------------------------------------------------------------------
    protected virtual task rd_resp_consumer();
        for (int s = 0; s < int'(cfg.seg_count); s++) begin
            automatic int seg = s;
            fork
                forever begin
                    vif.init_cb.rd_resp_ready[seg] <= 1'b0;
                    repeat (gap(cfg.bp_profile[seg])) @(vif.init_cb);
                    vif.init_cb.rd_resp_ready[seg] <= 1'b1;
                    @(vif.init_cb);
                end
            join_none
        end
    endtask

    protected virtual function int unsigned gap(mqnic_bp_profile_e p);
        case (p)
            BP_NONE:       return 0;
            BP_AGGRESSIVE: return $urandom_range(4, 12);
            BP_BURSTY:     return ($urandom_range(0, 9) < 3) ? $urandom_range(8, 20) : 0;
            default:       return $urandom_range(0, 3);
        endcase
    endfunction

endclass : dma_ram_driver


// -----------------------------------------------------------------------------
// dma_ram_responder - models the segmented RAM.
//
// Needed from Tier 3 on, where dma_if_pcie is the initiator and the testbench
// must be the memory. Backing store is a sparse associative array keyed by
// {segment, address}, matching how the real RAM is banked.
// -----------------------------------------------------------------------------
class dma_ram_responder extends uvm_driver #(dma_ram_item);

    `uvm_component_utils(dma_ram_responder)

    virtual dma_ram_if vif;
    dma_ram_cfg        cfg;

    protected bit [255:0] m_mem [longint unsigned];

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual dma_ram_if)::get(this, "", "vif", vif))
            `uvm_fatal(get_type_name(), "no dma_ram_if in config_db under key vif")
        if (!uvm_config_db #(dma_ram_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "no dma_ram_cfg in config_db under key cfg")
    endfunction

    protected function longint unsigned key(int seg, bit [15:0] addr);
        return (longint'(seg) << 32) | longint'(addr);
    endfunction

    virtual function bit [255:0] peek(int seg, bit [15:0] addr);
        longint unsigned k = key(seg, addr);
        return m_mem.exists(k) ? m_mem[k] : '0;
    endfunction

    virtual function void poke(int seg, bit [15:0] addr, bit [255:0] data);
        m_mem[key(seg, addr)] = data;
    endfunction

    virtual task run_phase(uvm_phase phase);
        vif.init_idle_responder();
        for (int s = 0; s < int'(cfg.seg_count); s++) begin
            automatic int seg = s;
            if (cfg.has_wr()) fork wr_server(seg); join_none
            if (cfg.has_rd()) fork rd_server(seg); join_none
        end
    endtask

    protected virtual task wr_server(int seg);
        bit [15:0]  a;
        bit [255:0] d;
        bit [31:0]  be;
        bit [255:0] old;

        forever begin
            vif.resp_cb.wr_cmd_ready[seg] <= 1'b0;
            repeat (gap(cfg.bp_profile[seg])) @(vif.resp_cb);
            vif.resp_cb.wr_cmd_ready[seg] <= 1'b1;
            do @(vif.resp_cb); while (vif.resp_cb.wr_cmd_valid[seg] !== 1'b1);

            a  = 16'(vif.resp_cb.wr_cmd_addr[seg*DMA_RAM_MAX_SEG_ADDR_WIDTH +: 16]);
            d  = vif.resp_cb.wr_cmd_data[seg*DMA_RAM_MAX_SEG_DATA_WIDTH +: 256];
            be = vif.resp_cb.wr_cmd_be[seg*DMA_RAM_MAX_SEG_BE_WIDTH +: 32];
            vif.resp_cb.wr_cmd_ready[seg] <= 1'b0;

            old = peek(seg, a);
            for (int b = 0; b < int'(cfg.seg_be_width()); b++)
                if (be[b]) old[b*8 +: 8] = d[b*8 +: 8];
            poke(seg, a, old);

            // wr_done is a PULSE: assert for exactly one cycle, no handshake.
            repeat ($urandom_range(cfg.resp_min_latency, cfg.resp_max_latency))
                @(vif.resp_cb);
            vif.resp_cb.wr_done[seg] <= 1'b1;
            @(vif.resp_cb);
            vif.resp_cb.wr_done[seg] <= 1'b0;
        end
    endtask

    protected virtual task rd_server(int seg);
        bit [15:0] a;

        forever begin
            vif.resp_cb.rd_cmd_ready[seg] <= 1'b0;
            repeat (gap(cfg.bp_profile[seg])) @(vif.resp_cb);
            vif.resp_cb.rd_cmd_ready[seg] <= 1'b1;
            do @(vif.resp_cb); while (vif.resp_cb.rd_cmd_valid[seg] !== 1'b1);

            a = 16'(vif.resp_cb.rd_cmd_addr[seg*DMA_RAM_MAX_SEG_ADDR_WIDTH +: 16]);
            vif.resp_cb.rd_cmd_ready[seg] <= 1'b0;

            repeat ($urandom_range(cfg.resp_min_latency, cfg.resp_max_latency))
                @(vif.resp_cb);

            vif.resp_cb.rd_resp_data[seg*DMA_RAM_MAX_SEG_DATA_WIDTH +: 256]
                <= peek(seg, a);
            vif.resp_cb.rd_resp_valid[seg] <= 1'b1;
            do @(vif.resp_cb); while (vif.resp_cb.rd_resp_ready[seg] !== 1'b1);
            vif.resp_cb.rd_resp_valid[seg] <= 1'b0;
        end
    endtask

    protected virtual function int unsigned gap(mqnic_bp_profile_e p);
        case (p)
            BP_NONE:       return 0;
            BP_AGGRESSIVE: return $urandom_range(4, 12);
            BP_BURSTY:     return ($urandom_range(0, 9) < 3) ? $urandom_range(8, 20) : 0;
            default:       return $urandom_range(0, 3);
        endcase
    endfunction

endclass : dma_ram_responder

`endif // DMA_RAM_DRIVER_SV

// SPDX-License-Identifier: BSD-2-Clause-Views
//
// dma_ram_monitor - segmented DMA RAM monitor
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.4, §4.3 rule 2
// Introduced : Step 4 (Tier 2); reused at Tiers 3 and 5
//
// FOUR CHANNELS, EACH SAMPLED ON EVERY SEGMENT, EVERY CYCLE.
//
// The segments are independent, so this monitor cannot "wait for a handshake"
// on anything - on any given clock an arbitrary subset of segments may fire.
// Every channel is therefore evaluated combinationally across all segments once
// per cycle, which is both simpler and correct.
//
// wr_done IS A PULSE WITH NO READY (dma_psdpram.v:61). Its qualifying condition
// is the level ALONE. This is the third instance of that shape in the project -
// after the queue_manager doorbell and the rx_checksum/rx_hash inputs - and the
// same failure applies: a collector written around valid/ready observes nothing
// and the test passes having checked nothing.
//
// Read data has no address on it. The RAM returns responses per segment IN
// ORDER, so the monitor pairs each rd_resp with the oldest outstanding rd_cmd
// on that same segment. That pairing is what makes a read checkable at all, and
// it is per-segment: segment 0's responses say nothing about segment 1's.
// -----------------------------------------------------------------------------

`ifndef DMA_RAM_MONITOR_SV
`define DMA_RAM_MONITOR_SV

class dma_ram_monitor extends uvm_monitor;

    `uvm_component_utils(dma_ram_monitor)

    virtual dma_ram_if vif;
    dma_ram_cfg        cfg;

    uvm_analysis_port #(dma_ram_item) wr_ap;      // accepted write commands
    uvm_analysis_port #(dma_ram_item) done_ap;    // wr_done pulses
    uvm_analysis_port #(dma_ram_item) rd_ap;      // accepted read commands
    uvm_analysis_port #(dma_ram_item) data_ap;    // read responses, address resolved

    // Outstanding read addresses per segment, oldest first.
    protected bit [15:0]   m_rd_pending [DMA_RAM_MAX_SEG_COUNT][$];

    protected int unsigned m_n_wr;
    protected int unsigned m_n_done;
    protected int unsigned m_n_rd;
    protected int unsigned m_n_data;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        wr_ap   = new("wr_ap", this);
        done_ap = new("done_ap", this);
        rd_ap   = new("rd_ap", this);
        data_ap = new("data_ap", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual dma_ram_if)::get(this, "", "vif", vif))
            `uvm_fatal(get_type_name(), "no dma_ram_if in config_db under key vif")
        if (!uvm_config_db #(dma_ram_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "no dma_ram_cfg in config_db under key cfg")
    endfunction

    virtual task run_phase(uvm_phase phase);
        forever begin
            fork
                collect();
                @(posedge vif.rst);
            join_any
            disable fork;
            flush_on_reset();
            while (vif.rst === 1'b1) @(vif.mon_cb);
        end
    endtask

    protected virtual function void flush_on_reset();
        int n = 0;
        foreach (m_rd_pending[s]) begin
            n += m_rd_pending[s].size();
            m_rd_pending[s].delete();
        end
        if (n != 0)
            `uvm_info(get_type_name(),
                $sformatf("reset discarded %0d outstanding read command(s)", n),
                UVM_MEDIUM)
    endfunction

    // -------------------------------------------------------------------------
    protected virtual task collect();
        dma_ram_item it;
        int          ns = int'(cfg.seg_count);

        forever begin
            @(vif.mon_cb);

            for (int s = 0; s < ns; s++) begin

                // ---- write command accepted ---------------------------------
                if (cfg.has_wr() &&
                    vif.mon_cb.wr_cmd_valid[s] === 1'b1 &&
                    vif.mon_cb.wr_cmd_ready[s] === 1'b1) begin
                    it       = dma_ram_item::type_id::create("wr");
                    it.kind  = DMA_RAM_WRITE;
                    it.seg   = s;
                    it.addr  = 16'(vif.mon_cb.wr_cmd_addr[s*DMA_RAM_MAX_SEG_ADDR_WIDTH +: 16]);
                    it.data  = vif.mon_cb.wr_cmd_data[s*DMA_RAM_MAX_SEG_DATA_WIDTH +: 256];
                    it.be    = vif.mon_cb.wr_cmd_be[s*DMA_RAM_MAX_SEG_BE_WIDTH +: 32];
                    it.sel   = cfg.has_sel
                             ? 8'(vif.mon_cb.wr_cmd_sel[s*DMA_RAM_MAX_SEL_WIDTH +: 8]) : 8'h0;
                    it.stamp = $time;
                    m_n_wr++;
                    `uvm_info(get_type_name(), it.convert2string(), UVM_HIGH)
                    wr_ap.write(it);
                end

                // ---- write done: PULSE, level-qualified only ----------------
                if (cfg.has_wr() && vif.mon_cb.wr_done[s] === 1'b1) begin
                    it       = dma_ram_item::type_id::create("done");
                    it.kind  = DMA_RAM_WR_DONE;
                    it.seg   = s;
                    it.stamp = $time;
                    m_n_done++;
                    `uvm_info(get_type_name(), it.convert2string(), UVM_HIGH)
                    done_ap.write(it);
                end

                // ---- read command accepted ----------------------------------
                if (cfg.has_rd() &&
                    vif.mon_cb.rd_cmd_valid[s] === 1'b1 &&
                    vif.mon_cb.rd_cmd_ready[s] === 1'b1) begin
                    it       = dma_ram_item::type_id::create("rd");
                    it.kind  = DMA_RAM_READ;
                    it.seg   = s;
                    it.addr  = 16'(vif.mon_cb.rd_cmd_addr[s*DMA_RAM_MAX_SEG_ADDR_WIDTH +: 16]);
                    it.sel   = cfg.has_sel
                             ? 8'(vif.mon_cb.rd_cmd_sel[s*DMA_RAM_MAX_SEL_WIDTH +: 8]) : 8'h0;
                    it.stamp = $time;
                    m_rd_pending[s].push_back(it.addr);
                    m_n_rd++;
                    `uvm_info(get_type_name(), it.convert2string(), UVM_HIGH)
                    rd_ap.write(it);
                end

                // ---- read response: pair with the oldest command on THIS seg -
                if (cfg.has_rd() &&
                    vif.mon_cb.rd_resp_valid[s] === 1'b1 &&
                    vif.mon_cb.rd_resp_ready[s] === 1'b1) begin
                    it       = dma_ram_item::type_id::create("data");
                    it.kind  = DMA_RAM_RD_DATA;
                    it.seg   = s;
                    it.data  = vif.mon_cb.rd_resp_data[s*DMA_RAM_MAX_SEG_DATA_WIDTH +: 256];
                    it.stamp = $time;

                    if (m_rd_pending[s].size() == 0) begin
                        `uvm_error(get_type_name(),
                            $sformatf({"seg %0d: read response with no outstanding ",
                                       "read command - the RAM returned data nobody asked for"},
                                      s))
                        it.addr = 16'hXXXX;
                    end
                    else begin
                        it.addr = m_rd_pending[s].pop_front();
                    end

                    m_n_data++;
                    `uvm_info(get_type_name(),
                        $sformatf("%s (addr 0x%0h)", it.convert2string(), it.addr), UVM_HIGH)
                    data_ap.write(it);
                end
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Read commands issued but not yet answered, across all segments.
    //
    // Exposed so a test can wait for the DUT to actually drain instead of
    // guessing a delay. Under BP_AGGRESSIVE the tail of a read burst can take
    // hundreds of cycles to come back, and a fixed idle() that is long enough
    // for one backpressure profile is too short for another.
    // -------------------------------------------------------------------------
    virtual function int unsigned outstanding_reads();
        int unsigned n = 0;
        foreach (m_rd_pending[s]) n += m_rd_pending[s].size();
        return n;
    endfunction

    // -------------------------------------------------------------------------
    virtual function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        foreach (m_rd_pending[s])
            if (m_rd_pending[s].size() != 0)
                `uvm_error(get_type_name(),
                    $sformatf("seg %0d: %0d read command(s) never answered",
                              s, m_rd_pending[s].size()))
    endfunction

    // Report only the channels this agent OWNS. Printing rd=0 data=0 for a
    // write-only agent reads like a coverage hole when it is a structural
    // impossibility - dma_if_pcie_rd has no RAM read ports at all, so there is
    // nothing on that channel to observe. Naming the configuration alongside
    // the counts makes "zero because absent" distinguishable from "zero because
    // nothing happened", which is the failure this line is meant to catch.
    virtual function void report_phase(uvm_phase phase);
        string s;

        super.report_phase(phase);

        s = $sformatf("channels=%s", cfg.channels.name());
        if (cfg.has_wr()) s = {s, $sformatf(" wr=%0d done=%0d", m_n_wr, m_n_done)};
        if (cfg.has_rd()) s = {s, $sformatf(" rd=%0d data=%0d", m_n_rd, m_n_data)};

        `uvm_info(get_type_name(), {"observed ", s}, UVM_LOW)

        // A channel that is present but silent IS worth flagging.
        if (cfg.has_wr() && m_n_wr == 0)
            `uvm_info(get_type_name(),
                "write channel is connected but saw no traffic", UVM_LOW)
        if (cfg.has_rd() && m_n_rd == 0)
            `uvm_info(get_type_name(),
                "read channel is connected but saw no traffic", UVM_LOW)
    endfunction

endclass : dma_ram_monitor

`endif // DMA_RAM_MONITOR_SV

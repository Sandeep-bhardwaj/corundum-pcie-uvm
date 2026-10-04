// SPDX-License-Identifier: BSD-2-Clause-Views
//
// axil_slave_driver - AXI4-Lite reactive slave
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §7.1 (MODE_ACTIVE_SLAVE)
// Introduced : Step 1 (Tier 1a)
//
// Needed because several DUT interfaces have the DUT as MASTER - notably
// m_axil_csr_* on mqnic_core_pcie (STRATEGY §3.2), where the NIC drives register
// accesses outward. The agent must then answer, not initiate.
//
// Backed by a sparse associative memory so a Tier 5/6 test can pre-load CSR
// space and have reads return meaningful values. Reads to never-written
// addresses return cfg.slave_default_data rather than X, so a scoreboard
// mismatch is legible instead of propagating unknowns.
//
// The three channel servers run independently and forever: AXI places no
// ordering between AW/W arrival, and a slave that waits for AW before accepting
// W will deadlock against a W-first master.
// -----------------------------------------------------------------------------

`ifndef AXIL_SLAVE_DRIVER_SV
`define AXIL_SLAVE_DRIVER_SV

class axil_slave_driver extends uvm_driver #(axil_item);

    `uvm_component_utils(axil_slave_driver)

    virtual axil_if vif;
    axil_cfg        cfg;

    // Sparse backing store, indexed by (masked) address.
    protected bit [63:0] m_mem [bit [63:0]];

    // Pending write address / data, decoupled because the channels are.
    protected bit [63:0] m_aw_q [$];
    protected bit [63:0] m_wd_q [$];
    protected bit [7:0]  m_ws_q [$];

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual axil_if)::get(this, "", "vif", vif))
            `uvm_fatal(get_type_name(), "no axil_if in config_db under key 'vif'")
        if (!uvm_config_db #(axil_cfg)::get(this, "", "cfg", cfg))
            `uvm_fatal(get_type_name(), "no axil_cfg in config_db under key 'cfg'")
    endfunction

    // -------------------------------------------------------------------------
    // Backdoor access for tests and for the RAL backdoor path.
    // -------------------------------------------------------------------------
    virtual function void poke(bit [63:0] addr, bit [63:0] data);
        m_mem[addr & cfg.addr_mask()] = data & cfg.data_mask();
    endfunction

    virtual function bit [63:0] peek(bit [63:0] addr);
        bit [63:0] a = addr & cfg.addr_mask();
        return m_mem.exists(a) ? m_mem[a] : cfg.slave_default_data & cfg.data_mask();
    endfunction

    // -------------------------------------------------------------------------
    virtual task run_phase(uvm_phase phase);
        drive_idle();
        forever begin
            fork
                begin : servers
                    fork
                        aw_server();
                        w_server();
                        b_server();
                        ar_r_server();
                    join
                end
                begin : reset_watch
                    @(posedge vif.rst);
                end
            join_any
            disable fork;

            drive_idle();
            m_aw_q.delete();
            m_wd_q.delete();
            m_ws_q.delete();
            while (vif.rst === 1'b1) @(vif.slave_cb);
        end
    endtask

    // -------------------------------------------------------------------------
    protected virtual task drive_idle();
        vif.slave_cb.awready <= 1'b0;
        vif.slave_cb.wready  <= 1'b0;
        vif.slave_cb.bresp   <= 2'b00;
        vif.slave_cb.bvalid  <= 1'b0;
        vif.slave_cb.arready <= 1'b0;
        vif.slave_cb.rdata   <= '0;
        vif.slave_cb.rresp   <= 2'b00;
        vif.slave_cb.rvalid  <= 1'b0;
    endtask

    // Ready shaping shared by all accept channels.
    protected virtual task ready_gap();
        int unsigned n;
        case (cfg.bp_profile)
            BP_NONE:       n = 0;
            BP_AGGRESSIVE: n = $urandom_range(4, 12);
            BP_BURSTY:     n = ($urandom_range(0, 9) < 3) ? $urandom_range(8, 20) : 0;
            default:       n = $urandom_range(0, 3);
        endcase
        repeat (n) @(vif.slave_cb);
    endtask

    protected virtual function axil_resp_e pick_resp();
        int unsigned r = $urandom_range(0, 99);
        if (r < cfg.decerr_rate_pct)                          return AXIL_DECERR;
        if (r < cfg.decerr_rate_pct + cfg.slverr_rate_pct)    return AXIL_SLVERR;
        return AXIL_OKAY;
    endfunction

    // -------------------------------------------------------------------------
    protected virtual task aw_server();
        forever begin
            ready_gap();
            vif.slave_cb.awready <= 1'b1;
            do @(vif.slave_cb); while (vif.slave_cb.awvalid !== 1'b1);
            m_aw_q.push_back(vif.slave_cb.awaddr & cfg.addr_mask());
            vif.slave_cb.awready <= 1'b0;
        end
    endtask

    protected virtual task w_server();
        forever begin
            ready_gap();
            vif.slave_cb.wready <= 1'b1;
            do @(vif.slave_cb); while (vif.slave_cb.wvalid !== 1'b1);
            m_wd_q.push_back(vif.slave_cb.wdata & cfg.data_mask());
            m_ws_q.push_back(vif.slave_cb.wstrb & cfg.strb_mask());
            vif.slave_cb.wready <= 1'b0;
        end
    endtask

    // Commit a write only once BOTH halves have arrived, in either order.
    protected virtual task b_server();
        bit [63:0]  a, d, old;
        bit [7:0]   s;
        axil_resp_e rsp;

        forever begin
            wait (m_aw_q.size() > 0 && m_wd_q.size() > 0);
            a = m_aw_q.pop_front();
            d = m_wd_q.pop_front();
            s = m_ws_q.pop_front();

            rsp = pick_resp();
            if (rsp == AXIL_OKAY) begin
                old = m_mem.exists(a) ? m_mem[a] : '0;
                for (int b = 0; b < int'(cfg.strb_width()); b++)
                    if (s[b]) old[b*8 +: 8] = d[b*8 +: 8];
                m_mem[a] = old;
            end

            repeat ($urandom_range(cfg.slave_min_latency, cfg.slave_max_latency))
                @(vif.slave_cb);

            vif.slave_cb.bresp  <= rsp;
            vif.slave_cb.bvalid <= 1'b1;
            do @(vif.slave_cb); while (vif.slave_cb.bready !== 1'b1);
            vif.slave_cb.bvalid <= 1'b0;
        end
    endtask

    protected virtual task ar_r_server();
        bit [63:0]  a;
        axil_resp_e rsp;

        forever begin
            ready_gap();
            vif.slave_cb.arready <= 1'b1;
            do @(vif.slave_cb); while (vif.slave_cb.arvalid !== 1'b1);
            a = vif.slave_cb.araddr & cfg.addr_mask();
            vif.slave_cb.arready <= 1'b0;

            rsp = pick_resp();
            repeat ($urandom_range(cfg.slave_min_latency, cfg.slave_max_latency))
                @(vif.slave_cb);

            vif.slave_cb.rdata  <= peek(a);
            vif.slave_cb.rresp  <= rsp;
            vif.slave_cb.rvalid <= 1'b1;
            do @(vif.slave_cb); while (vif.slave_cb.rready !== 1'b1);
            vif.slave_cb.rvalid <= 1'b0;
        end
    endtask

endclass : axil_slave_driver

`endif // AXIL_SLAVE_DRIVER_SV

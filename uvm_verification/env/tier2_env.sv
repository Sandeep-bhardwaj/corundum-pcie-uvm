// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tier2_env - Tier 2 environment (segmented memory subsystem)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §5 Tier 2, §11
// Introduced : Step 4
//
//   m_ram  dma_ram_agent MODE_ACTIVE_MASTER -> dma_psdpram
//   m_sb   sb_dma_ram                       -> reference-memory checking
//
// The agent is the INITIATOR here because the DUT is the RAM. At Tier 3 the
// same UVC flips to MODE_ACTIVE_SLAVE and models the RAM while dma_if_pcie
// drives - which is the reuse §5.1 is counting on.
//
// Backpressure is staggered across segments by default: a shared profile lets
// every segment stall in lockstep, and lockstep is the one pattern that will
// never expose a per-segment bug.
// -----------------------------------------------------------------------------

`ifndef TIER2_ENV_SV
`define TIER2_ENV_SV

class tier2_env extends uvm_env;

    `uvm_component_utils(tier2_env)

    dma_ram_cfg   m_ram_cfg;
    dma_ram_agent m_ram;
    sb_dma_ram    m_sb;

    // ---- dma_psdpram_async: one agent per clock domain ----------------------
    dma_ram_cfg   m_aram_wr_cfg;
    dma_ram_cfg   m_aram_rd_cfg;
    dma_ram_agent m_aram_wr;
    dma_ram_agent m_aram_rd;
    sb_dma_ram    m_asb;

    // ---- DMA stream clients --------------------------------------------------
    // The clients DRIVE the RAM, so those agents are RESPONDERs - the same UVC
    // as Tier 2's initiator, flipped. That flip is the reuse §5.1 counts on for
    // Tier 3, where dma_if_pcie is likewise the initiator.
    dma_desc_pkg::dma_desc_cfg   m_cli_wr_desc_cfg;
    dma_desc_pkg::dma_desc_cfg   m_cli_rd_desc_cfg;
    axis_cfg                     m_cli_wr_pkt_cfg;
    axis_cfg                     m_cli_rd_pkt_cfg;
    dma_ram_cfg                  m_cli_wr_ram_cfg;
    dma_ram_cfg                  m_cli_rd_ram_cfg;

    dma_desc_pkg::dma_desc_agent m_cli_wr_desc;
    dma_desc_pkg::dma_desc_agent m_cli_rd_desc;
    axis_agent                   m_cli_wr_pkt;
    axis_agent                   m_cli_rd_pkt;
    dma_ram_agent                m_cli_wr_ram;
    dma_ram_agent                m_cli_rd_ram;
    sb_dma_client                m_cli_sb;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db #(dma_ram_cfg)::get(this, "", "ram_cfg", m_ram_cfg)) begin
            m_ram_cfg = dma_ram_cfg::type_id::create("m_ram_cfg");
            m_ram_cfg.mode           = MODE_ACTIVE_MASTER;
            // dma_psdpram defaults: SEG_COUNT=2, SEG_DATA_WIDTH=128, SIZE=4096
            // -> SEG_ADDR_WIDTH = $clog2(4096/(2*16)) = 7
            m_ram_cfg.seg_count      = 2;
            m_ram_cfg.seg_data_width = 128;
            m_ram_cfg.seg_addr_width = 7;
            m_ram_cfg.has_sel        = 1'b0;   // plain dma_psdpram has no sel
            m_ram_cfg.stagger_backpressure();
        end

        uvm_config_db #(dma_ram_cfg)::set(this, "m_ram", "cfg", m_ram_cfg);
        uvm_config_db #(dma_ram_cfg)::set(this, "m_sb",  "cfg", m_ram_cfg);

        m_ram = dma_ram_agent::type_id::create("m_ram", this);
        m_sb  = sb_dma_ram::type_id::create("m_sb", this);
        m_sb.cov = cg_ram::type_id::create("m_ram_cov", this);

        // ---- async RAM: two agents, one per clock domain --------------------
        m_aram_wr_cfg = dma_ram_cfg::type_id::create("m_aram_wr_cfg");
        m_aram_wr_cfg.mode           = MODE_ACTIVE_MASTER;
        m_aram_wr_cfg.channels       = DMA_RAM_CH_WR_ONLY;
        m_aram_wr_cfg.seg_count      = 2;
        m_aram_wr_cfg.seg_data_width = 128;
        m_aram_wr_cfg.seg_addr_width = 7;
        m_aram_wr_cfg.stagger_backpressure();

        m_aram_rd_cfg = dma_ram_cfg::type_id::create("m_aram_rd_cfg");
        m_aram_rd_cfg.mode           = MODE_ACTIVE_MASTER;
        m_aram_rd_cfg.channels       = DMA_RAM_CH_RD_ONLY;
        m_aram_rd_cfg.seg_count      = 2;
        m_aram_rd_cfg.seg_data_width = 128;
        m_aram_rd_cfg.seg_addr_width = 7;
        m_aram_rd_cfg.stagger_backpressure();

        uvm_config_db #(dma_ram_cfg)::set(this, "m_aram_wr", "cfg", m_aram_wr_cfg);
        uvm_config_db #(dma_ram_cfg)::set(this, "m_aram_rd", "cfg", m_aram_rd_cfg);
        uvm_config_db #(dma_ram_cfg)::set(this, "m_asb",     "cfg", m_aram_wr_cfg);

        m_aram_wr = dma_ram_agent::type_id::create("m_aram_wr", this);
        m_aram_rd = dma_ram_agent::type_id::create("m_aram_rd", this);
        m_asb     = sb_dma_ram::type_id::create("m_asb", this);
        m_asb.cov = cg_ram::type_id::create("m_aram_cov", this);

        // ---- sink client: stream -> RAM -------------------------------------
        m_cli_wr_desc_cfg = dma_desc_pkg::dma_desc_cfg::type_id::create("m_cli_wr_desc_cfg");
        m_cli_wr_desc_cfg.mode   = MODE_ACTIVE_MASTER;
        m_cli_wr_desc_cfg.flavor = dma_desc_pkg::DMA_DESC_CLIENT_WR;

        m_cli_wr_pkt_cfg = axis_cfg::type_id::create("m_cli_wr_pkt_cfg");
        m_cli_wr_pkt_cfg.mode       = MODE_ACTIVE_MASTER;
        m_cli_wr_pkt_cfg.data_width = 64;
        m_cli_wr_pkt_cfg.has_tready = 1'b1;

        m_cli_wr_ram_cfg = dma_ram_cfg::type_id::create("m_cli_wr_ram_cfg");
        m_cli_wr_ram_cfg.mode           = MODE_ACTIVE_SLAVE;    // TB models the RAM
        m_cli_wr_ram_cfg.channels       = DMA_RAM_CH_WR_ONLY;
        m_cli_wr_ram_cfg.seg_count      = 2;
        m_cli_wr_ram_cfg.seg_data_width = 64;
        m_cli_wr_ram_cfg.seg_addr_width = 12;
        m_cli_wr_ram_cfg.stagger_backpressure();

        // ---- source client: RAM -> stream -----------------------------------
        m_cli_rd_desc_cfg = dma_desc_pkg::dma_desc_cfg::type_id::create("m_cli_rd_desc_cfg");
        m_cli_rd_desc_cfg.mode   = MODE_ACTIVE_MASTER;
        m_cli_rd_desc_cfg.flavor = dma_desc_pkg::DMA_DESC_CLIENT_RD;

        m_cli_rd_pkt_cfg = axis_cfg::type_id::create("m_cli_rd_pkt_cfg");
        m_cli_rd_pkt_cfg.mode       = MODE_ACTIVE_SLAVE;        // sinks + monitors
        m_cli_rd_pkt_cfg.data_width = 64;
        m_cli_rd_pkt_cfg.has_tready = 1'b1;

        m_cli_rd_ram_cfg = dma_ram_cfg::type_id::create("m_cli_rd_ram_cfg");
        m_cli_rd_ram_cfg.mode           = MODE_ACTIVE_SLAVE;
        m_cli_rd_ram_cfg.channels       = DMA_RAM_CH_RD_ONLY;
        m_cli_rd_ram_cfg.seg_count      = 2;
        m_cli_rd_ram_cfg.seg_data_width = 64;
        m_cli_rd_ram_cfg.seg_addr_width = 12;
        m_cli_rd_ram_cfg.stagger_backpressure();

        uvm_config_db #(dma_desc_pkg::dma_desc_cfg)::set(this, "m_cli_wr_desc", "cfg", m_cli_wr_desc_cfg);
        uvm_config_db #(dma_desc_pkg::dma_desc_cfg)::set(this, "m_cli_rd_desc", "cfg", m_cli_rd_desc_cfg);
        uvm_config_db #(axis_cfg)::set   (this, "m_cli_wr_pkt", "cfg", m_cli_wr_pkt_cfg);
        uvm_config_db #(axis_cfg)::set   (this, "m_cli_rd_pkt", "cfg", m_cli_rd_pkt_cfg);
        uvm_config_db #(dma_ram_cfg)::set(this, "m_cli_wr_ram", "cfg", m_cli_wr_ram_cfg);
        uvm_config_db #(dma_ram_cfg)::set(this, "m_cli_rd_ram", "cfg", m_cli_rd_ram_cfg);

        m_cli_wr_desc = dma_desc_pkg::dma_desc_agent::type_id::create("m_cli_wr_desc", this);
        m_cli_rd_desc = dma_desc_pkg::dma_desc_agent::type_id::create("m_cli_rd_desc", this);
        m_cli_wr_pkt  = axis_agent::type_id::create("m_cli_wr_pkt", this);
        m_cli_rd_pkt  = axis_agent::type_id::create("m_cli_rd_pkt", this);
        m_cli_wr_ram  = dma_ram_agent::type_id::create("m_cli_wr_ram", this);
        m_cli_rd_ram  = dma_ram_agent::type_id::create("m_cli_rd_ram", this);
        m_cli_sb      = sb_dma_client::type_id::create("m_cli_sb", this);
        m_cli_sb.cov  = cg_client::type_id::create("m_cli_cov", this);
        m_cli_sb.seg_count    = 2;
        m_cli_sb.seg_be_width = 8;
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        m_ram.wr_ap.connect(m_sb.wr_imp);
        m_ram.done_ap.connect(m_sb.done_imp);
        m_ram.data_ap.connect(m_sb.data_imp);

        // The async scoreboard is fed from BOTH domains: writes and completions
        // from the write-clock agent, read data from the read-clock agent. One
        // reference memory spanning the two is precisely what proves the CDC
        // carried the data across.
        m_aram_wr.wr_ap.connect(m_asb.wr_imp);
        m_aram_wr.done_ap.connect(m_asb.done_imp);
        m_aram_rd.data_ap.connect(m_asb.data_imp);

        // ---- clients --------------------------------------------------------
        m_cli_wr_desc.req_ap.connect(m_cli_sb.wr_desc_imp);
        m_cli_wr_desc.sts_ap.connect(m_cli_sb.wr_sts_imp);
        m_cli_wr_pkt.ap.connect(m_cli_sb.wr_pkt_imp);
        m_cli_wr_ram.wr_ap.connect(m_cli_sb.wr_ram_imp);

        m_cli_rd_desc.req_ap.connect(m_cli_sb.rd_desc_imp);
        m_cli_rd_pkt.ap.connect(m_cli_sb.rd_pkt_imp);
    endfunction

endclass : tier2_env

`endif // TIER2_ENV_SV

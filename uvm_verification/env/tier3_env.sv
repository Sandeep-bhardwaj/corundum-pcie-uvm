// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tier3_env - Tier 3a environment (dma_if_pcie_rd)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §5 Tier 3, §11
// Introduced : Step 5
//
//   m_desc    dma_desc_agent  MASTER   -> descriptors into the DUT
//   m_rd_req  pcie_tlp_agent  SLAVE    -> sinks + monitors the read requests
//   m_rx_cpl  pcie_tlp_agent  MASTER   -> the root complex drives completions
//   m_ram     dma_ram_agent   SLAVE    -> models the RAM the DUT writes into
//   m_rc      rc_responder             -> request -> completion, with timing
//   m_sb      sb_dma                   -> the three checks
//
// EVERY UVC HERE WAS BUILT AND PROVEN AT A LOWER TIER: pcie_tlp at 1b,
// dma_ram at 2, dma_desc at 2. Tier 3 adds models and checking, not plumbing -
// which is exactly the return §5.1 promises for the bottom-up ordering.
//
// The host memory model is shared by the RC responder (which reads it to build
// completions) and the scoreboard (which reads it to predict what RAM should
// end up holding). One instance, so the two cannot disagree about what was in
// memory - the same discipline as the RSS key at Tier 1c.
// -----------------------------------------------------------------------------

`ifndef TIER3_ENV_SV
`define TIER3_ENV_SV

class tier3_env extends uvm_env;

    `uvm_component_utils(tier3_env)

    dma_desc_pkg::dma_desc_cfg   m_desc_cfg;
    pcie_tlp_cfg                 m_rd_req_cfg;
    pcie_tlp_cfg                 m_rx_cpl_cfg;
    dma_ram_cfg                  m_ram_cfg;

    dma_desc_pkg::dma_desc_agent m_desc;
    pcie_tlp_agent               m_rd_req;
    pcie_tlp_agent               m_rx_cpl;
    dma_ram_agent                m_ram;
    rc_responder                 m_rc;
    sb_dma                       m_sb;

    mqnic_host_mem_model         m_mem;
    ref_dma                      m_ref;
    cg_dma                       m_cov;

    bit enable_coverage = 1'b1;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // Shared by the RC responder and the scoreboard - see the file header.
        m_mem = mqnic_host_mem_model::type_id::create("m_mem");
        m_ref = ref_dma::type_id::create("m_ref");

        // ---- descriptors ----------------------------------------------------
        m_desc_cfg = dma_desc_pkg::dma_desc_cfg::type_id::create("m_desc_cfg");
        m_desc_cfg.mode   = MODE_ACTIVE_MASTER;
        m_desc_cfg.flavor = dma_desc_pkg::DMA_DESC_PCIE_RD;

        // ---- read requests: the TB is the completer, so it sinks them -------
        m_rd_req_cfg = pcie_tlp_cfg::type_id::create("m_rd_req_cfg");
        m_rd_req_cfg.mode         = MODE_ACTIVE_SLAVE;
        m_rd_req_cfg.channel      = TLP_CH_TX_RD_REQ;
        m_rd_req_cfg.data_width   = 256;
        m_rd_req_cfg.seg_count    = 1;
        m_rd_req_cfg.has_bar_id   = 1'b0;   // request channel has no BAR
        m_rd_req_cfg.has_error    = 1'b0;
        m_rd_req_cfg.bp_profile   = BP_RANDOM;

        // ---- completions: driven in --------------------------------------
        m_rx_cpl_cfg = pcie_tlp_cfg::type_id::create("m_rx_cpl_cfg");
        m_rx_cpl_cfg.mode         = MODE_ACTIVE_MASTER;
        m_rx_cpl_cfg.channel      = TLP_CH_RX_CPL;
        m_rx_cpl_cfg.data_width   = 256;
        m_rx_cpl_cfg.seg_count    = 1;
        m_rx_cpl_cfg.has_bar_id   = 1'b0;
        m_rx_cpl_cfg.has_seq      = 1'b0;   // completions carry no sequence number

        // ---- RAM: the DUT writes into it, so the TB responds ---------------
        m_ram_cfg = dma_ram_cfg::type_id::create("m_ram_cfg");
        m_ram_cfg.mode           = MODE_ACTIVE_SLAVE;
        m_ram_cfg.channels       = DMA_RAM_CH_WR_ONLY;
        m_ram_cfg.seg_count      = 2;       // RAM_SEG_COUNT = TLP_SEG_COUNT*2
        m_ram_cfg.seg_data_width = 256;     // TLP_DATA_WIDTH*2/RAM_SEG_COUNT
        m_ram_cfg.seg_addr_width = 10;      // 16 - $clog2(2*32)
        m_ram_cfg.has_sel        = 1'b1;    // dma_if_pcie_rd drives ram_wr_cmd_sel
        m_ram_cfg.sel_width      = 2;
        m_ram_cfg.stagger_backpressure();

        uvm_config_db #(dma_desc_pkg::dma_desc_cfg)::set(this, "m_desc", "cfg", m_desc_cfg);
        uvm_config_db #(pcie_tlp_cfg)::set(this, "m_rd_req", "cfg", m_rd_req_cfg);
        uvm_config_db #(pcie_tlp_cfg)::set(this, "m_rx_cpl", "cfg", m_rx_cpl_cfg);
        uvm_config_db #(dma_ram_cfg)::set (this, "m_ram",    "cfg", m_ram_cfg);

        m_desc   = dma_desc_pkg::dma_desc_agent::type_id::create("m_desc", this);
        m_rd_req = pcie_tlp_agent::type_id::create("m_rd_req", this);
        m_rx_cpl = pcie_tlp_agent::type_id::create("m_rx_cpl", this);
        m_ram    = dma_ram_agent::type_id::create("m_ram", this);
        m_rc     = rc_responder::type_id::create("m_rc", this);
        m_sb     = sb_dma::type_id::create("m_sb", this);

        if (enable_coverage) m_cov = cg_dma::type_id::create("m_cov", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        m_rc.mem  = m_mem;
        m_rc.rc.mem = m_mem;
        m_sb.mem  = m_mem;
        m_sb.ref_model = m_ref;
        m_sb.ram_seg_count    = m_ram_cfg.seg_count;
        m_sb.ram_seg_be_width = m_ram_cfg.seg_be_width();
        m_sb.cov              = m_cov;

        // Observed read requests feed BOTH the responder (which answers them)
        // and the scoreboard (which checks them). Two subscribers on one port,
        // no ordering dependency between them.
        m_rd_req.ap.connect(m_rc.req_imp);
        m_rd_req.ap.connect(m_sb.req_imp);

        m_rc.cpl_seqr = m_rx_cpl.sequencer;

        // Completions go to the scoreboard only so it knows when a PCIe tag is
        // free again - see sb_dma.write_dma_cpl.
        m_rx_cpl.ap.connect(m_sb.cpl_imp);

        m_desc.req_ap.connect(m_sb.desc_imp);
        m_desc.sts_ap.connect(m_sb.sts_imp);
        m_ram.wr_ap.connect(m_sb.ram_imp);
    endfunction

    // Everything quiet: every descriptor answered, every request completed, no
    // completion waiting to go out, nothing predicted but unseen.
    //
    // outstanding_desc() is the load-bearing term. The others can all read zero
    // while the DUT is still mid-operation, which is exactly how Tier 2's
    // drain-wait passed a test that had issued 5 of its 64 reads.
    virtual function bit is_idle();
        return m_rc.is_idle()
            && (m_sb.pending_count()   == 0)
            && (m_sb.outstanding_desc() == 0);
    endfunction

endclass : tier3_env

`endif // TIER3_ENV_SV

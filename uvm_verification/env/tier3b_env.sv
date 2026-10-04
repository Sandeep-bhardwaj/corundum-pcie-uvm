// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tier3b_env - Tier 3b environment (dma_if_pcie_wr)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §5 Tier 3, §11
// Introduced : Step 5 (Tier 3b)
//
//   m_desc    dma_desc_agent  MASTER  -> descriptors into the DUT
//   m_wr_req  pcie_tlp_agent  SLAVE   -> sinks + monitors the write requests
//   m_ram     dma_ram_agent   SLAVE   -> models the RAM the DUT READS
//   m_sb      sb_dma_wr
//
// NO ROOT COMPLEX AND NO COMPLETION CHANNEL. A posted write gets no answer, so
// there is nothing for mqnic_rc_model to do here - which is exactly why 3b is
// a smaller problem than 3a and worth keeping separate from it.
//
// The RAM agent is RD_ONLY, the mirror of Tier 3a: the write engine READS RAM
// to build its payload. Same UVC, opposite channel - which is the reuse §5.1
// was set up for.
// -----------------------------------------------------------------------------

`ifndef TIER3B_ENV_SV
`define TIER3B_ENV_SV

class tier3b_env extends uvm_env;

    `uvm_component_utils(tier3b_env)

    dma_desc_pkg::dma_desc_cfg   m_desc_cfg;
    pcie_tlp_cfg                 m_wr_req_cfg;
    dma_ram_cfg                  m_ram_cfg;

    dma_desc_pkg::dma_desc_agent m_desc;
    pcie_tlp_agent               m_wr_req;
    dma_ram_agent                m_ram;
    sb_dma_wr                    m_sb;

    ref_dma                      m_ref;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        m_ref = ref_dma::type_id::create("m_ref");

        m_desc_cfg = dma_desc_pkg::dma_desc_cfg::type_id::create("m_desc_cfg");
        m_desc_cfg.mode   = MODE_ACTIVE_MASTER;
        m_desc_cfg.flavor = dma_desc_pkg::DMA_DESC_PCIE_WR;

        // The write requests carry payload, so this channel has data and strb -
        // unlike Tier 3a's header-only request channel.
        m_wr_req_cfg = pcie_tlp_cfg::type_id::create("m_wr_req_cfg");
        m_wr_req_cfg.mode       = MODE_ACTIVE_SLAVE;
        m_wr_req_cfg.channel    = TLP_CH_TX_WR_REQ;
        m_wr_req_cfg.data_width = 256;
        m_wr_req_cfg.seg_count  = 1;
        m_wr_req_cfg.has_bar_id = 1'b0;
        m_wr_req_cfg.has_error  = 1'b0;
        m_wr_req_cfg.bp_profile = BP_RANDOM;

        m_ram_cfg = dma_ram_cfg::type_id::create("m_ram_cfg");
        m_ram_cfg.mode           = MODE_ACTIVE_SLAVE;
        m_ram_cfg.channels       = DMA_RAM_CH_RD_ONLY;   // the DUT reads RAM
        m_ram_cfg.seg_count      = 2;
        m_ram_cfg.seg_data_width = 256;
        m_ram_cfg.seg_addr_width = 10;
        m_ram_cfg.has_sel        = 1'b1;
        m_ram_cfg.sel_width      = 2;
        m_ram_cfg.stagger_backpressure();

        uvm_config_db #(dma_desc_pkg::dma_desc_cfg)::set(this, "m_desc", "cfg", m_desc_cfg);
        uvm_config_db #(pcie_tlp_cfg)::set(this, "m_wr_req", "cfg", m_wr_req_cfg);
        uvm_config_db #(dma_ram_cfg)::set (this, "m_ram",    "cfg", m_ram_cfg);

        m_desc   = dma_desc_pkg::dma_desc_agent::type_id::create("m_desc", this);
        m_wr_req = pcie_tlp_agent::type_id::create("m_wr_req", this);
        m_ram    = dma_ram_agent::type_id::create("m_ram", this);
        m_sb     = sb_dma_wr::type_id::create("m_sb", this);
        m_sb.cov = cg_dma_wr::type_id::create("m_cov", this);   // build phase: components only
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        m_sb.m_ref = m_ref;
        m_desc.req_ap.connect(m_sb.desc_imp);
        m_desc.sts_ap.connect(m_sb.sts_imp);
        m_wr_req.ap.connect(m_sb.req_imp);
    endfunction

    // -------------------------------------------------------------------------
    // Preload one RAM byte, in BOTH the responder and the scoreboard's shadow.
    //
    // One entry point so the two cannot disagree about what the RAM held - the
    // same discipline as Tier 2's cli_preload(). The linear-to-segmented split
    // is the same one documented in sb_dma.
    // -------------------------------------------------------------------------
    virtual function void preload(int unsigned lin_addr, byte unsigned d);
        int unsigned seg_be   = m_ram_cfg.seg_be_width();          // 32
        int unsigned n_seg    = m_ram_cfg.seg_count;               // 2
        int unsigned byte_in  = lin_addr % seg_be;
        int unsigned seg      = (lin_addr / seg_be) % n_seg;
        int unsigned seg_addr = lin_addr / (seg_be * n_seg);
        bit [255:0]  w        = m_ram.peek(seg, 16'(seg_addr));

        w[byte_in*8 +: 8] = d;
        m_ram.poke(seg, 16'(seg_addr), w);
        m_sb.preload(lin_addr, d);
    endfunction

    virtual function bit is_idle();
        return (m_sb.pending_count() == 0) && (m_sb.outstanding_desc() == 0);
    endfunction

endclass : tier3b_env

`endif // TIER3B_ENV_SV

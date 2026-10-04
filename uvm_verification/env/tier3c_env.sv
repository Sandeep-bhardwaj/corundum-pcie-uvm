// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tier3c_env - Tier 3c environment (full dma_if_pcie)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §5 Tier 3, §11
// Introduced : Step 5 (Tier 3c)
//
// dma_if_pcie is a thin wrapper: dma_if_pcie_rd and dma_if_pcie_wr side by
// side, sharing one segmented RAM interface. So this environment is 3a's plus
// 3b's, and almost nothing here is new code - which is the point. What IS new
// is the only question 3c can ask:
//
//   DO THE TWO ENGINES INTERFERE?
//
// They contend for one RAM (the read engine writes it, the write engine reads
// it) and for the requester ID and address space. Tiers 3a and 3b each proved
// one direction in isolation; neither can say anything about the pair.
//
//   m_rd_desc  dma_desc_agent  MASTER -> read descriptors
//   m_wr_desc  dma_desc_agent  MASTER -> write descriptors
//   m_rd_req   pcie_tlp_agent  SLAVE  -> read requests out
//   m_rx_cpl   pcie_tlp_agent  MASTER -> completions in
//   m_wr_req   pcie_tlp_agent  SLAVE  -> write requests out
//   m_ram      dma_ram_agent   SLAVE  -> BOTH channels, one memory
//   m_rc       rc_responder
//   m_hmw      host_mem_writer        -> closes the loop into host memory
//   m_sb / m_sb_wr
//
// ONE host memory model, shared by the RC responder, the write committer and
// the read scoreboard. That sharing is what makes the loopback test meaningful:
// bytes read out of it come back into it, and the comparison is between two
// regions of the same memory rather than against a model of it.
// -----------------------------------------------------------------------------

`ifndef TIER3C_ENV_SV
`define TIER3C_ENV_SV

class tier3c_env extends uvm_env;

    `uvm_component_utils(tier3c_env)

    dma_desc_pkg::dma_desc_cfg   m_rd_desc_cfg;
    dma_desc_pkg::dma_desc_cfg   m_wr_desc_cfg;
    pcie_tlp_cfg                 m_rd_req_cfg;
    pcie_tlp_cfg                 m_rx_cpl_cfg;
    pcie_tlp_cfg                 m_wr_req_cfg;
    dma_ram_cfg                  m_ram_cfg;

    dma_desc_pkg::dma_desc_agent m_rd_desc;
    dma_desc_pkg::dma_desc_agent m_wr_desc;
    pcie_tlp_agent               m_rd_req;
    pcie_tlp_agent               m_rx_cpl;
    pcie_tlp_agent               m_wr_req;
    dma_ram_agent                m_ram;
    rc_responder                 m_rc;
    host_mem_writer              m_hmw;
    sb_dma                       m_sb;
    sb_dma_wr                    m_sb_wr;
    cg_dma                       m_cov;

    mqnic_host_mem_model         m_mem;
    ref_dma                      m_ref;

    bit enable_coverage = 1'b1;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        m_mem = mqnic_host_mem_model::type_id::create("m_mem");
        m_ref = ref_dma::type_id::create("m_ref");

        m_rd_desc_cfg = dma_desc_pkg::dma_desc_cfg::type_id::create("m_rd_desc_cfg");
        m_rd_desc_cfg.mode   = MODE_ACTIVE_MASTER;
        m_rd_desc_cfg.flavor = dma_desc_pkg::DMA_DESC_PCIE_RD;

        m_wr_desc_cfg = dma_desc_pkg::dma_desc_cfg::type_id::create("m_wr_desc_cfg");
        m_wr_desc_cfg.mode   = MODE_ACTIVE_MASTER;
        m_wr_desc_cfg.flavor = dma_desc_pkg::DMA_DESC_PCIE_WR;

        m_rd_req_cfg = pcie_tlp_cfg::type_id::create("m_rd_req_cfg");
        m_rd_req_cfg.mode       = MODE_ACTIVE_SLAVE;
        m_rd_req_cfg.channel    = TLP_CH_TX_RD_REQ;
        m_rd_req_cfg.data_width = 256;
        m_rd_req_cfg.seg_count  = 1;
        m_rd_req_cfg.has_bar_id = 1'b0;
        m_rd_req_cfg.has_error  = 1'b0;
        m_rd_req_cfg.bp_profile = BP_RANDOM;

        m_rx_cpl_cfg = pcie_tlp_cfg::type_id::create("m_rx_cpl_cfg");
        m_rx_cpl_cfg.mode       = MODE_ACTIVE_MASTER;
        m_rx_cpl_cfg.channel    = TLP_CH_RX_CPL;
        m_rx_cpl_cfg.data_width = 256;
        m_rx_cpl_cfg.seg_count  = 1;
        m_rx_cpl_cfg.has_bar_id = 1'b0;
        m_rx_cpl_cfg.has_seq    = 1'b0;

        m_wr_req_cfg = pcie_tlp_cfg::type_id::create("m_wr_req_cfg");
        m_wr_req_cfg.mode       = MODE_ACTIVE_SLAVE;
        m_wr_req_cfg.channel    = TLP_CH_TX_WR_REQ;
        m_wr_req_cfg.data_width = 256;
        m_wr_req_cfg.seg_count  = 1;
        m_wr_req_cfg.has_bar_id = 1'b0;
        m_wr_req_cfg.has_error  = 1'b0;
        m_wr_req_cfg.bp_profile = BP_RANDOM;

        // BOTH channels on ONE agent: the two engines share this interface,
        // and modelling them as one memory is what lets a loopback work.
        m_ram_cfg = dma_ram_cfg::type_id::create("m_ram_cfg");
        m_ram_cfg.mode           = MODE_ACTIVE_SLAVE;
        m_ram_cfg.channels       = DMA_RAM_CH_BOTH;
        m_ram_cfg.seg_count      = 2;
        m_ram_cfg.seg_data_width = 256;
        m_ram_cfg.seg_addr_width = 10;
        m_ram_cfg.has_sel        = 1'b1;
        m_ram_cfg.sel_width      = 2;
        m_ram_cfg.stagger_backpressure();

        uvm_config_db #(dma_desc_pkg::dma_desc_cfg)::set(this, "m_rd_desc", "cfg", m_rd_desc_cfg);
        uvm_config_db #(dma_desc_pkg::dma_desc_cfg)::set(this, "m_wr_desc", "cfg", m_wr_desc_cfg);
        uvm_config_db #(pcie_tlp_cfg)::set(this, "m_rd_req", "cfg", m_rd_req_cfg);
        uvm_config_db #(pcie_tlp_cfg)::set(this, "m_rx_cpl", "cfg", m_rx_cpl_cfg);
        uvm_config_db #(pcie_tlp_cfg)::set(this, "m_wr_req", "cfg", m_wr_req_cfg);
        uvm_config_db #(dma_ram_cfg)::set (this, "m_ram",    "cfg", m_ram_cfg);

        m_rd_desc = dma_desc_pkg::dma_desc_agent::type_id::create("m_rd_desc", this);
        m_wr_desc = dma_desc_pkg::dma_desc_agent::type_id::create("m_wr_desc", this);
        m_rd_req  = pcie_tlp_agent::type_id::create("m_rd_req", this);
        m_rx_cpl  = pcie_tlp_agent::type_id::create("m_rx_cpl", this);
        m_wr_req  = pcie_tlp_agent::type_id::create("m_wr_req", this);
        m_ram     = dma_ram_agent::type_id::create("m_ram", this);
        m_rc      = rc_responder::type_id::create("m_rc", this);
        m_hmw     = host_mem_writer::type_id::create("m_hmw", this);
        m_sb      = sb_dma::type_id::create("m_sb", this);
        m_sb_wr   = sb_dma_wr::type_id::create("m_sb_wr", this);

        if (enable_coverage) m_cov = cg_dma::type_id::create("m_cov", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        m_rc.mem    = m_mem;
        m_rc.rc.mem = m_mem;
        m_hmw.mem   = m_mem;

        m_sb.mem              = m_mem;
        m_sb.ref_model        = m_ref;
        m_sb.ram_seg_count    = m_ram_cfg.seg_count;
        m_sb.ram_seg_be_width = m_ram_cfg.seg_be_width();
        m_sb.cov              = m_cov;

        m_sb_wr.m_ref = m_ref;

        // Read side
        m_rd_req.ap.connect(m_rc.req_imp);
        m_rd_req.ap.connect(m_sb.req_imp);
        m_rx_cpl.ap.connect(m_sb.cpl_imp);
        m_rc.cpl_seqr = m_rx_cpl.sequencer;
        m_rd_desc.req_ap.connect(m_sb.desc_imp);
        m_rd_desc.sts_ap.connect(m_sb.sts_imp);
        m_ram.wr_ap.connect(m_sb.ram_imp);

        // Write side. The observed write requests go to BOTH the checker and
        // the committer - the committer is what makes a loopback observable.
        m_wr_req.ap.connect(m_sb_wr.req_imp);
        m_wr_req.ap.connect(m_hmw.req_imp);
        m_wr_desc.req_ap.connect(m_sb_wr.desc_imp);
        m_wr_desc.sts_ap.connect(m_sb_wr.sts_imp);
    endfunction

    // -------------------------------------------------------------------------
    // Preload one RAM byte in the responder and the write scoreboard's shadow.
    // -------------------------------------------------------------------------
    virtual function void preload(int unsigned lin_addr, byte unsigned d);
        int unsigned seg_be   = m_ram_cfg.seg_be_width();
        int unsigned n_seg    = m_ram_cfg.seg_count;
        int unsigned byte_in  = lin_addr % seg_be;
        int unsigned seg      = (lin_addr / seg_be) % n_seg;
        int unsigned seg_addr = lin_addr / (seg_be * n_seg);
        bit [255:0]  w        = m_ram.peek(seg, 16'(seg_addr));

        w[byte_in*8 +: 8] = d;
        m_ram.poke(seg, 16'(seg_addr), w);
        m_sb_wr.preload(lin_addr, d);
    endfunction

    // Both engines quiet.
    virtual function bit is_idle();
        return m_rc.is_idle()
            && (m_sb.pending_count()     == 0)
            && (m_sb.outstanding_desc()  == 0)
            && (m_sb_wr.pending_count()  == 0)
            && (m_sb_wr.outstanding_desc() == 0);
    endfunction

endclass : tier3c_env

`endif // TIER3C_ENV_SV

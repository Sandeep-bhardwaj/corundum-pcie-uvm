// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tier4a_env - Tier 4a environment (pcie_us_if_rc, pcie_us_if_cq)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §5 Tier 4, §11, §22 R2
// Introduced : Step 6 (Tier 4a)
//
// TWO ISOLATED SHIMS, SIDE BY SIDE. §22 R2 says to close the tuser risk "at
// Tier 4a on isolated pcie_us_if_* blocks" rather than inside the full wrapper,
// and these two are the receive direction: AXI-Stream in, generic TLP out.
// Nothing else is in the path, so a mismatch has exactly one plausible cause.
//
//   m_rc_axis  pcie_us_axis_agent MASTER -> drives RC, encoding tuser
//   m_rc_tlp   pcie_tlp_agent     SLAVE  -> sinks + monitors the generic side
//   m_cq_axis  pcie_us_axis_agent MASTER -> drives CQ
//   m_cq_tlp   pcie_tlp_agent     SLAVE
//   m_rc_sb / m_cq_sb             sb_shim, one per channel
//
// THE GENERIC-SIDE AGENT IS THE ONE BUILT AT TIER 1b. That reuse is the whole
// argument of §5.1 arriving at its furthest point so far: the output of these
// shims is the exact interface the demux, the mux and the DMA engine already
// speak, so the monitor that checks them needed no changes at all.
//
// ONE COVERAGE INSTANCE, SHARED. §14.4's cross has channel as an axis, so the
// two scoreboards must sample into the same covergroup or neither will ever
// show the cross filled.
// -----------------------------------------------------------------------------

`ifndef TIER4A_ENV_SV
`define TIER4A_ENV_SV

class tier4a_env extends uvm_env;

    `uvm_component_utils(tier4a_env)

    pcie_us_axis_pkg::pcie_us_axis_cfg   m_rc_axis_cfg;
    pcie_us_axis_pkg::pcie_us_axis_cfg   m_cq_axis_cfg;
    pcie_tlp_cfg                         m_rc_tlp_cfg;
    pcie_tlp_cfg                         m_cq_tlp_cfg;

    pcie_us_axis_pkg::pcie_us_axis_agent m_rc_axis;
    pcie_us_axis_pkg::pcie_us_axis_agent m_cq_axis;
    pcie_tlp_agent                       m_rc_tlp;
    pcie_tlp_agent                       m_cq_tlp;

    sb_shim                              m_rc_sb;
    sb_shim                              m_cq_sb;
    cg_straddle                          m_cov;

    ref_tlp_shim                         m_shim;

    // Golden width. mqnic_core_pcie_us.v:157 builds at 256, where RC straddles
    // and the other three channels do not.
    int unsigned data_width     = 256;
    bit          enable_coverage = 1'b1;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        m_shim = ref_tlp_shim::type_id::create("m_shim");

        // ---- Xilinx side: the TB is the source on both channels -------------
        m_rc_axis_cfg = pcie_us_axis_pkg::pcie_us_axis_cfg::type_id::create("m_rc_axis_cfg");
        m_rc_axis_cfg.mode       = MODE_ACTIVE_MASTER;
        m_rc_axis_cfg.channel    = PCIE_CH_RC;
        m_rc_axis_cfg.data_width = data_width;

        m_cq_axis_cfg = pcie_us_axis_pkg::pcie_us_axis_cfg::type_id::create("m_cq_axis_cfg");
        m_cq_axis_cfg.mode       = MODE_ACTIVE_MASTER;
        m_cq_axis_cfg.channel    = PCIE_CH_CQ;
        m_cq_axis_cfg.data_width = data_width;

        // ---- generic side: the DUT drives, so the TB sinks ------------------
        m_rc_tlp_cfg = pcie_tlp_cfg::type_id::create("m_rc_tlp_cfg");
        m_rc_tlp_cfg.mode         = MODE_ACTIVE_SLAVE;
        m_rc_tlp_cfg.channel      = TLP_CH_RX_CPL;
        m_rc_tlp_cfg.data_width   = data_width;
        m_rc_tlp_cfg.seg_count    = 1;
        m_rc_tlp_cfg.has_bar_id   = 1'b0;
        m_rc_tlp_cfg.has_seq      = 1'b0;
        m_rc_tlp_cfg.bp_profile   = BP_RANDOM;

        m_cq_tlp_cfg = pcie_tlp_cfg::type_id::create("m_cq_tlp_cfg");
        m_cq_tlp_cfg.mode         = MODE_ACTIVE_SLAVE;
        m_cq_tlp_cfg.channel      = TLP_CH_RX_REQ;
        m_cq_tlp_cfg.data_width   = data_width;
        m_cq_tlp_cfg.seg_count    = 1;
        m_cq_tlp_cfg.has_error    = 1'b0;
        m_cq_tlp_cfg.has_seq      = 1'b0;
        m_cq_tlp_cfg.bp_profile   = BP_RANDOM;

        uvm_config_db #(pcie_us_axis_pkg::pcie_us_axis_cfg)::set(this, "m_rc_axis", "cfg", m_rc_axis_cfg);
        uvm_config_db #(pcie_us_axis_pkg::pcie_us_axis_cfg)::set(this, "m_cq_axis", "cfg", m_cq_axis_cfg);
        uvm_config_db #(pcie_tlp_cfg)::set(this, "m_rc_tlp", "cfg", m_rc_tlp_cfg);
        uvm_config_db #(pcie_tlp_cfg)::set(this, "m_cq_tlp", "cfg", m_cq_tlp_cfg);

        m_rc_axis = pcie_us_axis_pkg::pcie_us_axis_agent::type_id::create("m_rc_axis", this);
        m_cq_axis = pcie_us_axis_pkg::pcie_us_axis_agent::type_id::create("m_cq_axis", this);
        m_rc_tlp  = pcie_tlp_agent::type_id::create("m_rc_tlp", this);
        m_cq_tlp  = pcie_tlp_agent::type_id::create("m_cq_tlp", this);

        m_rc_sb = sb_shim::type_id::create("m_rc_sb", this);
        m_cq_sb = sb_shim::type_id::create("m_cq_sb", this);

        // Shared: §14.4's cross has channel as an axis, so one instance.
        if (enable_coverage) m_cov = cg_straddle::type_id::create("m_cov", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        m_rc_sb.m_shim  = m_shim;
        m_rc_sb.channel = PCIE_CH_RC;
        m_rc_sb.cov     = m_cov;

        m_cq_sb.m_shim  = m_shim;
        m_cq_sb.channel = PCIE_CH_CQ;
        m_cq_sb.cov     = m_cov;

        m_rc_axis.ap.connect(m_rc_sb.axis_imp);
        m_rc_tlp.ap.connect(m_rc_sb.tlp_imp);

        m_cq_axis.ap.connect(m_cq_sb.axis_imp);
        m_cq_tlp.ap.connect(m_cq_sb.tlp_imp);
    endfunction

    // Nothing held back for straddling, nothing converted but unseen.
    virtual function bit is_idle();
        return m_rc_axis.is_idle() && m_cq_axis.is_idle()
            && (m_rc_sb.pending_count() == 0)
            && (m_cq_sb.pending_count() == 0);
    endfunction

endclass : tier4a_env

`endif // TIER4A_ENV_SV

// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tier4d_env - Tier 4d environment (pcie_us_if)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §5 (the plan's Tier 4b), §11
//
// THE SHIM INTEGRATION. Tiers 4a/4b/4c drive one shim each, where a mismatch
// has exactly one plausible cause. This env drives all four at once, and every
// agent in it was built at an earlier tier and reused unchanged - which is
// §5.1's argument reaching its last stop before Tier 5.
//
//   m_rc_axis   pcie_us_axis_agent MASTER (RC) -> m_cpl_tlp   SLAVE  (rx_cpl)
//   m_cq_axis   pcie_us_axis_agent MASTER (CQ) -> m_req_tlp   SLAVE  (rx_req)
//   m_txcpl_tlp pcie_tlp_agent     MASTER      -> m_cc_axis   SLAVE  (CC)
//   m_rq_axis   pcie_us_axis_agent SLAVE  (RQ) - sinks and monitors only
//
// TWO DIRECTIONS, SO TWO sb_shim ORIENTATIONS. sb_shim already handles both via
// tx_direction (it was made bidirectional for Tier 4b), so the inbound and
// outbound scoreboards differ only in configuration.
//
// WHAT THIS ENV CANNOT CHECK, AND WHY THE TEST DOES IT DIRECTLY
// -------------------------------------------------------------
// pcie_us_cfg drives max_payload_size / max_read_request_size / ext_tag_enable,
// which are plain output pins rather than a transaction stream. There is no
// UVC for a static status pin and inventing one would be ceremony, so
// t4d_cfg_extract samples them in the test through the DUT hierarchy. It is
// the tier's most important check and it is deliberately not a scoreboard.
// -----------------------------------------------------------------------------

`ifndef TIER4D_ENV_SV
`define TIER4D_ENV_SV

class tier4d_env extends uvm_env;

    `uvm_component_utils(tier4d_env)

    pcie_us_axis_pkg::pcie_us_axis_cfg   m_rc_axis_cfg;
    pcie_us_axis_pkg::pcie_us_axis_cfg   m_cq_axis_cfg;
    pcie_us_axis_pkg::pcie_us_axis_cfg   m_cc_axis_cfg;
    pcie_us_axis_pkg::pcie_us_axis_cfg   m_rq_axis_cfg;
    pcie_tlp_cfg                         m_req_tlp_cfg;
    pcie_tlp_cfg                         m_cpl_tlp_cfg;
    pcie_tlp_cfg                         m_txcpl_tlp_cfg;

    pcie_us_axis_pkg::pcie_us_axis_agent m_rc_axis;
    pcie_us_axis_pkg::pcie_us_axis_agent m_cq_axis;
    pcie_us_axis_pkg::pcie_us_axis_agent m_cc_axis;
    pcie_us_axis_pkg::pcie_us_axis_agent m_rq_axis;
    pcie_tlp_agent                       m_req_tlp;
    pcie_tlp_agent                       m_cpl_tlp;
    pcie_tlp_agent                       m_txcpl_tlp;

    sb_shim                              m_rc_sb;    // RC  -> rx_cpl
    sb_shim                              m_cq_sb;    // CQ  -> rx_req
    sb_shim                              m_cc_sb;    // tx_cpl -> CC
    cg_straddle                          m_cov;

    ref_tlp_shim                         m_shim;

    // Golden width. mqnic_core_pcie_us.v:157 builds at 256, where RC straddles
    // and the other three channels do not.
    int unsigned data_width      = 256;
    bit          enable_coverage = 1'b1;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        m_shim = ref_tlp_shim::type_id::create("m_shim");

        // ---- inbound: the TB is the Xilinx source ---------------------------
        m_rc_axis_cfg = pcie_us_axis_pkg::pcie_us_axis_cfg::type_id::create("m_rc_axis_cfg");
        m_rc_axis_cfg.mode       = MODE_ACTIVE_MASTER;
        m_rc_axis_cfg.channel    = PCIE_CH_RC;
        m_rc_axis_cfg.data_width = data_width;

        m_cq_axis_cfg = pcie_us_axis_pkg::pcie_us_axis_cfg::type_id::create("m_cq_axis_cfg");
        m_cq_axis_cfg.mode       = MODE_ACTIVE_MASTER;
        m_cq_axis_cfg.channel    = PCIE_CH_CQ;
        m_cq_axis_cfg.data_width = data_width;

        // ---- outbound: the DUT is the Xilinx source, TB sinks ---------------
        m_cc_axis_cfg = pcie_us_axis_pkg::pcie_us_axis_cfg::type_id::create("m_cc_axis_cfg");
        m_cc_axis_cfg.mode       = MODE_ACTIVE_SLAVE;
        m_cc_axis_cfg.channel    = PCIE_CH_CC;
        m_cc_axis_cfg.data_width = data_width;

        m_rq_axis_cfg = pcie_us_axis_pkg::pcie_us_axis_cfg::type_id::create("m_rq_axis_cfg");
        m_rq_axis_cfg.mode       = MODE_ACTIVE_SLAVE;
        m_rq_axis_cfg.channel    = PCIE_CH_RQ;
        m_rq_axis_cfg.data_width = data_width;

        // ---- generic side ---------------------------------------------------
        m_cpl_tlp_cfg = pcie_tlp_cfg::type_id::create("m_cpl_tlp_cfg");
        m_cpl_tlp_cfg.mode       = MODE_ACTIVE_SLAVE;
        m_cpl_tlp_cfg.channel    = TLP_CH_RX_CPL;
        m_cpl_tlp_cfg.data_width = data_width;
        m_cpl_tlp_cfg.seg_count  = 1;
        m_cpl_tlp_cfg.has_bar_id = 1'b0;
        m_cpl_tlp_cfg.has_seq    = 1'b0;
        m_cpl_tlp_cfg.bp_profile = BP_RANDOM;

        m_req_tlp_cfg = pcie_tlp_cfg::type_id::create("m_req_tlp_cfg");
        m_req_tlp_cfg.mode       = MODE_ACTIVE_SLAVE;
        m_req_tlp_cfg.channel    = TLP_CH_RX_REQ;
        m_req_tlp_cfg.data_width = data_width;
        m_req_tlp_cfg.seg_count  = 1;
        m_req_tlp_cfg.has_error  = 1'b0;
        m_req_tlp_cfg.has_seq    = 1'b0;
        m_req_tlp_cfg.bp_profile = BP_RANDOM;

        m_txcpl_tlp_cfg = pcie_tlp_cfg::type_id::create("m_txcpl_tlp_cfg");
        m_txcpl_tlp_cfg.mode       = MODE_ACTIVE_MASTER;
        m_txcpl_tlp_cfg.channel    = TLP_CH_TX_CPL;
        m_txcpl_tlp_cfg.data_width = data_width;
        m_txcpl_tlp_cfg.seg_count  = 1;
        m_txcpl_tlp_cfg.has_bar_id = 1'b0;
        m_txcpl_tlp_cfg.has_error  = 1'b0;
        m_txcpl_tlp_cfg.has_seq    = 1'b0;

        uvm_config_db #(pcie_us_axis_pkg::pcie_us_axis_cfg)::set(this, "m_rc_axis",   "cfg", m_rc_axis_cfg);
        uvm_config_db #(pcie_us_axis_pkg::pcie_us_axis_cfg)::set(this, "m_cq_axis",   "cfg", m_cq_axis_cfg);
        uvm_config_db #(pcie_us_axis_pkg::pcie_us_axis_cfg)::set(this, "m_cc_axis",   "cfg", m_cc_axis_cfg);
        uvm_config_db #(pcie_us_axis_pkg::pcie_us_axis_cfg)::set(this, "m_rq_axis",   "cfg", m_rq_axis_cfg);
        uvm_config_db #(pcie_tlp_cfg)::set(this, "m_req_tlp",   "cfg", m_req_tlp_cfg);
        uvm_config_db #(pcie_tlp_cfg)::set(this, "m_cpl_tlp",   "cfg", m_cpl_tlp_cfg);
        uvm_config_db #(pcie_tlp_cfg)::set(this, "m_txcpl_tlp", "cfg", m_txcpl_tlp_cfg);

        m_rc_axis   = pcie_us_axis_pkg::pcie_us_axis_agent::type_id::create("m_rc_axis", this);
        m_cq_axis   = pcie_us_axis_pkg::pcie_us_axis_agent::type_id::create("m_cq_axis", this);
        m_cc_axis   = pcie_us_axis_pkg::pcie_us_axis_agent::type_id::create("m_cc_axis", this);
        m_rq_axis   = pcie_us_axis_pkg::pcie_us_axis_agent::type_id::create("m_rq_axis", this);
        m_req_tlp   = pcie_tlp_agent::type_id::create("m_req_tlp", this);
        m_cpl_tlp   = pcie_tlp_agent::type_id::create("m_cpl_tlp", this);
        m_txcpl_tlp = pcie_tlp_agent::type_id::create("m_txcpl_tlp", this);

        m_rc_sb = sb_shim::type_id::create("m_rc_sb", this);
        m_cq_sb = sb_shim::type_id::create("m_cq_sb", this);
        m_cc_sb = sb_shim::type_id::create("m_cc_sb", this);

        // Shared instance: §14.4's cross has channel as an axis.
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

        // Outbound: the generic side is the SOURCE here, so sb_shim runs in the
        // transmit orientation it grew for Tier 4b.
        m_cc_sb.m_shim       = m_shim;
        m_cc_sb.channel      = PCIE_CH_CC;
        m_cc_sb.tx_direction = 1'b1;
        m_cc_sb.cov          = m_cov;

        m_rc_axis.ap.connect(m_rc_sb.axis_imp);
        m_cpl_tlp.ap.connect(m_rc_sb.tlp_imp);

        m_cq_axis.ap.connect(m_cq_sb.axis_imp);
        m_req_tlp.ap.connect(m_cq_sb.tlp_imp);

        m_cc_axis.ap.connect(m_cc_sb.axis_imp);
        m_txcpl_tlp.ap.connect(m_cc_sb.tlp_imp);
    endfunction

    virtual function bit is_idle();
        return m_rc_axis.is_idle() && m_cq_axis.is_idle()
            && (m_rc_sb.pending_count() == 0)
            && (m_cq_sb.pending_count() == 0)
            && (m_cc_sb.pending_count() == 0);
    endfunction

endclass : tier4d_env

`endif // TIER4D_ENV_SV

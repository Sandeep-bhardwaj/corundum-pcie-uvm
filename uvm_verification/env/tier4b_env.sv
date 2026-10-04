// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tier4b_env - Tier 4b environment (pcie_us_if_cc)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §5 Tier 4, §11, §19 Tier 4
// Introduced : Step 6 (Tier 4b)
//
// THE TRANSMIT DIRECTION, and every arrow is reversed from Tier 4a:
//
//   m_cc_tlp   pcie_tlp_agent     MASTER -> drives the generic completion in
//   m_cc_axis  pcie_us_axis_agent SLAVE  -> sinks + monitors the Xilinx side
//   m_cc_sb    sb_shim with tx_direction = 1
//
// §19's Tier 4 criterion is BIDIRECTIONAL EQUIVALENCE, and this is the second
// direction. It is checked with the same `sb_shim` and the same `ref_tlp_shim`
// as Tier 4a - deliberately, because a separate model for each direction is a
// second place for the field list to drift, which is what §22 R2 is about.
//
// This is also the first time the TB DECODES a tuser it did not encode. The
// codec's RQ/CC accessors were written at the same time as the RC/CQ encoders
// and have never been exercised until now.
// -----------------------------------------------------------------------------

`ifndef TIER4B_ENV_SV
`define TIER4B_ENV_SV

class tier4b_env extends uvm_env;

    `uvm_component_utils(tier4b_env)

    pcie_tlp_cfg                         m_cc_tlp_cfg;
    pcie_us_axis_pkg::pcie_us_axis_cfg   m_cc_axis_cfg;

    pcie_tlp_agent                       m_cc_tlp;
    pcie_us_axis_pkg::pcie_us_axis_agent m_cc_axis;

    sb_shim                              m_cc_sb;
    cg_straddle                          m_cov;
    ref_tlp_shim                         m_shim;

    // 256 - the golden width, reachable thanks to rtl_patched/.
    int unsigned data_width      = 256;
    bit          enable_coverage = 1'b1;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        m_shim = ref_tlp_shim::type_id::create("m_shim");

        // Generic side: the TB is the source here, unlike Tier 4a.
        m_cc_tlp_cfg = pcie_tlp_cfg::type_id::create("m_cc_tlp_cfg");
        m_cc_tlp_cfg.mode         = MODE_ACTIVE_MASTER;
        m_cc_tlp_cfg.channel      = TLP_CH_TX_CPL;
        m_cc_tlp_cfg.data_width   = data_width;
        m_cc_tlp_cfg.seg_count    = 1;   // IN_ side; see tb_top_tier4b
        m_cc_tlp_cfg.has_bar_id   = 1'b0;
        m_cc_tlp_cfg.has_error    = 1'b0;
        m_cc_tlp_cfg.has_seq      = 1'b0;

        // Xilinx side: the DUT drives, so the TB sinks.
        m_cc_axis_cfg = pcie_us_axis_pkg::pcie_us_axis_cfg::type_id::create("m_cc_axis_cfg");
        m_cc_axis_cfg.mode       = MODE_ACTIVE_SLAVE;
        m_cc_axis_cfg.channel    = PCIE_CH_CC;
        m_cc_axis_cfg.data_width = data_width;
        m_cc_axis_cfg.bp_profile = BP_RANDOM;

        uvm_config_db #(pcie_tlp_cfg)::set(this, "m_cc_tlp", "cfg", m_cc_tlp_cfg);
        uvm_config_db #(pcie_us_axis_pkg::pcie_us_axis_cfg)::set(this, "m_cc_axis", "cfg", m_cc_axis_cfg);

        m_cc_tlp  = pcie_tlp_agent::type_id::create("m_cc_tlp", this);
        m_cc_axis = pcie_us_axis_pkg::pcie_us_axis_agent::type_id::create("m_cc_axis", this);
        m_cc_sb   = sb_shim::type_id::create("m_cc_sb", this);

        if (enable_coverage) m_cov = cg_straddle::type_id::create("m_cov", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        m_cc_sb.m_shim       = m_shim;
        m_cc_sb.channel      = PCIE_CH_CC;
        m_cc_sb.tx_direction = 1'b1;      // generic is the stimulus here
        m_cc_sb.cov          = m_cov;

        m_cc_tlp.ap.connect(m_cc_sb.tlp_imp);
        m_cc_axis.ap.connect(m_cc_sb.axis_imp);
    endfunction

    virtual function bit is_idle();
        return (m_cc_sb.pending_count() == 0);
    endfunction

endclass : tier4b_env

`endif // TIER4B_ENV_SV

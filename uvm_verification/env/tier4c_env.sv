// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tier4c_env - Tier 4c environment (pcie_us_if_rq)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §5 Tier 4, §11
// Introduced : Step 6 (Tier 4c)
//
//   m_rd_tlp   pcie_tlp_agent     MASTER -> read requests in  (non-posted)
//   m_wr_tlp   pcie_tlp_agent     MASTER -> write requests in (posted)
//   m_rq_axis  pcie_us_axis_agent SLAVE  -> the merged RQ stream out
//   m_sb       sb_rq
//
// TWO generic-side masters feeding ONE Xilinx-side sink. That asymmetry is the
// whole of Tier 4c: the other three shims are one-in one-out, and this one
// arbitrates.
//
// The credit model in sb_rq must track the interface the top drives, or the
// arbitration check is made against a fiction. tier4c_base_test.set_credits()
// is the only place either is written - the same single-entry-point discipline
// as tier3_base_test.set_config().
// -----------------------------------------------------------------------------

`ifndef TIER4C_ENV_SV
`define TIER4C_ENV_SV

class tier4c_env extends uvm_env;

    `uvm_component_utils(tier4c_env)

    pcie_tlp_cfg                         m_rd_tlp_cfg;
    pcie_tlp_cfg                         m_wr_tlp_cfg;
    pcie_us_axis_pkg::pcie_us_axis_cfg   m_rq_axis_cfg;

    pcie_tlp_agent                       m_rd_tlp;
    pcie_tlp_agent                       m_wr_tlp;
    pcie_us_axis_pkg::pcie_us_axis_agent m_rq_axis;

    sb_rq                                m_sb;
    ref_tlp_shim                         m_shim;
    ref_rq_arb                           m_arb;

    int unsigned data_width = 256;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        m_shim = ref_tlp_shim::type_id::create("m_shim");
        m_arb  = ref_rq_arb::type_id::create("m_arb");

        m_rd_tlp_cfg = pcie_tlp_cfg::type_id::create("m_rd_tlp_cfg");
        m_rd_tlp_cfg.mode       = MODE_ACTIVE_MASTER;
        m_rd_tlp_cfg.channel    = TLP_CH_TX_RD_REQ;
        m_rd_tlp_cfg.data_width = data_width;
        m_rd_tlp_cfg.seg_count  = 1;
        m_rd_tlp_cfg.has_bar_id = 1'b0;
        m_rd_tlp_cfg.has_error  = 1'b0;

        m_wr_tlp_cfg = pcie_tlp_cfg::type_id::create("m_wr_tlp_cfg");
        m_wr_tlp_cfg.mode       = MODE_ACTIVE_MASTER;
        m_wr_tlp_cfg.channel    = TLP_CH_TX_WR_REQ;
        m_wr_tlp_cfg.data_width = data_width;
        m_wr_tlp_cfg.seg_count  = 1;
        m_wr_tlp_cfg.has_bar_id = 1'b0;
        m_wr_tlp_cfg.has_error  = 1'b0;

        m_rq_axis_cfg = pcie_us_axis_pkg::pcie_us_axis_cfg::type_id::create("m_rq_axis_cfg");
        m_rq_axis_cfg.mode       = MODE_ACTIVE_SLAVE;
        m_rq_axis_cfg.channel    = PCIE_CH_RQ;
        m_rq_axis_cfg.data_width = data_width;
        m_rq_axis_cfg.bp_profile = BP_RANDOM;

        uvm_config_db #(pcie_tlp_cfg)::set(this, "m_rd_tlp", "cfg", m_rd_tlp_cfg);
        uvm_config_db #(pcie_tlp_cfg)::set(this, "m_wr_tlp", "cfg", m_wr_tlp_cfg);
        uvm_config_db #(pcie_us_axis_pkg::pcie_us_axis_cfg)::set(this, "m_rq_axis", "cfg", m_rq_axis_cfg);

        m_rd_tlp  = pcie_tlp_agent::type_id::create("m_rd_tlp", this);
        m_wr_tlp  = pcie_tlp_agent::type_id::create("m_wr_tlp", this);
        m_rq_axis = pcie_us_axis_pkg::pcie_us_axis_agent::type_id::create("m_rq_axis", this);
        m_sb      = sb_rq::type_id::create("m_sb", this);
        m_sb.cov  = cg_rq::type_id::create("m_cov", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        m_sb.m_shim = m_shim;
        m_sb.m_arb  = m_arb;

        m_rd_tlp.ap.connect(m_sb.rd_imp);
        m_wr_tlp.ap.connect(m_sb.wr_imp);
        m_rq_axis.ap.connect(m_sb.out_imp);
    endfunction

    virtual function bit is_idle();
        return (m_sb.pending_count() == 0) && m_rq_axis.is_idle();
    endfunction

endclass : tier4c_env

`endif // TIER4C_ENV_SV

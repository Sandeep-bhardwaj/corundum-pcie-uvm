// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tier6_env - Tier 6 environment (mqnic_core_pcie_us)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §5 Tier 6, §5.1, §11
//
// THE TOP DUT, AND THE PAYOFF FOR §5.1.
//
// Every agent here was built at an earlier tier and is reused WITHOUT
// MODIFICATION:
//
//   m_cq_axis   pcie_us_axis_agent MASTER (CQ)  built at Tier 4a
//   m_cc_axis   pcie_us_axis_agent SLAVE  (CC)  built at Tier 4a
//   m_rc_axis   pcie_us_axis_agent MASTER (RC)  built at Tier 4a
//   m_rq_axis   pcie_us_axis_agent SLAVE  (RQ)  built at Tier 4a
//
// The host now speaks to the DUT ONLY over the Xilinx streams - there is no
// generic TLP interface at this level, because pcie_us_if has absorbed it. So
// the pcie_tlp agent, which every tier from 1b to 5 used, is absent here. That
// is not a regression: it is the interface disappearing INSIDE the DUT, which
// is exactly what integrating the shim means.
//
// THE END-TO-END DATAPATH (objective G5), enabled by `e2e`:
//
//   m_eth_tx    axis_agent SLAVE  (MAC TX, 512 bit)   the frames that leave
//   m_eth_rx    axis_agent MASTER (MAC RX, 512 bit)   the frames that arrive
//   m_host      us_host     BAR master + DMA target behind RQ/RC
//   m_drv       mqnic_drv   upstream's mqnic.py driver, in SV
//   m_sb        sb_e2e      byte-exact TX and RX through host memory
//
// MSI-X (objective G7), enabled by `msix` on top of `e2e`:
//
//   m_msix_hip  us_msix_hip  the hard IP's interrupt handshake
//   m_msix_sb   sb_msix      every message against the programmed table
//
// The MAC agents are built always: m_eth_tx's sink drives tready, and an
// undriven ready into the DUT would be X in every test, not just these. The
// host, driver and scoreboard are built only for e2e tests, because the
// register tests run their own completion collector on the same CC stream.
//
// The register tests still need no scoreboard: they check VALUES against
// mqnic_hw.h, which is what §8.2 asks for.
// -----------------------------------------------------------------------------

`ifndef TIER6_ENV_SV
`define TIER6_ENV_SV

class tier6_env extends uvm_env;

    `uvm_component_utils(tier6_env)

    pcie_us_axis_pkg::pcie_us_axis_cfg   m_cq_axis_cfg;
    pcie_us_axis_pkg::pcie_us_axis_cfg   m_cc_axis_cfg;
    pcie_us_axis_pkg::pcie_us_axis_cfg   m_rc_axis_cfg;
    pcie_us_axis_pkg::pcie_us_axis_cfg   m_rq_axis_cfg;

    pcie_us_axis_pkg::pcie_us_axis_agent m_cq_axis;
    pcie_us_axis_pkg::pcie_us_axis_agent m_cc_axis;
    pcie_us_axis_pkg::pcie_us_axis_agent m_rc_axis;
    pcie_us_axis_pkg::pcie_us_axis_agent m_rq_axis;

    ref_tlp_shim                         m_shim;

    // The test needs to CONSUME completions, and an agent exposes an
    // analysis PORT rather than a fifo. One subscriber fifo here beats a
    // bespoke subscriber component in the test.
    uvm_tlm_analysis_fifo #(pcie_us_axis_pkg::pcie_us_axis_item) m_cc_fifo;

    cg_csr                               m_cov;

    axis_pkg::axis_cfg                   m_eth_tx_cfg;
    axis_pkg::axis_cfg                   m_eth_rx_cfg;
    axis_pkg::axis_agent                 m_eth_tx;
    axis_pkg::axis_agent                 m_eth_rx;

    // Set by a test between creating this env and its build_phase.
    bit                                  e2e = 1'b0;
    bit                                  msix = 1'b0;
    us_msix_hip                          m_msix_hip;
    sb_msix                              m_msix_sb;
    us_host                              m_host;
    mqnic_drv                            m_drv;
    sb_e2e                               m_sb;

    // Golden width. mqnic_core_pcie_us.v:157 builds at 256.
    int unsigned data_width = 256;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        m_shim = ref_tlp_shim::type_id::create("m_shim");

        m_cq_axis_cfg = pcie_us_axis_pkg::pcie_us_axis_cfg::type_id::create("m_cq_axis_cfg");
        m_cq_axis_cfg.mode       = MODE_ACTIVE_MASTER;
        m_cq_axis_cfg.channel    = PCIE_CH_CQ;
        m_cq_axis_cfg.data_width = data_width;

        m_rc_axis_cfg = pcie_us_axis_pkg::pcie_us_axis_cfg::type_id::create("m_rc_axis_cfg");
        m_rc_axis_cfg.mode       = MODE_ACTIVE_MASTER;
        m_rc_axis_cfg.channel    = PCIE_CH_RC;
        m_rc_axis_cfg.data_width = data_width;

        m_cc_axis_cfg = pcie_us_axis_pkg::pcie_us_axis_cfg::type_id::create("m_cc_axis_cfg");
        m_cc_axis_cfg.mode       = MODE_ACTIVE_SLAVE;
        m_cc_axis_cfg.channel    = PCIE_CH_CC;
        m_cc_axis_cfg.data_width = data_width;

        m_rq_axis_cfg = pcie_us_axis_pkg::pcie_us_axis_cfg::type_id::create("m_rq_axis_cfg");
        m_rq_axis_cfg.mode       = MODE_ACTIVE_SLAVE;
        m_rq_axis_cfg.channel    = PCIE_CH_RQ;
        m_rq_axis_cfg.data_width = data_width;

        uvm_config_db #(pcie_us_axis_pkg::pcie_us_axis_cfg)::set(this, "m_cq_axis", "cfg", m_cq_axis_cfg);
        uvm_config_db #(pcie_us_axis_pkg::pcie_us_axis_cfg)::set(this, "m_cc_axis", "cfg", m_cc_axis_cfg);
        uvm_config_db #(pcie_us_axis_pkg::pcie_us_axis_cfg)::set(this, "m_rc_axis", "cfg", m_rc_axis_cfg);
        uvm_config_db #(pcie_us_axis_pkg::pcie_us_axis_cfg)::set(this, "m_rq_axis", "cfg", m_rq_axis_cfg);

        m_cq_axis = pcie_us_axis_pkg::pcie_us_axis_agent::type_id::create("m_cq_axis", this);
        m_cc_axis = pcie_us_axis_pkg::pcie_us_axis_agent::type_id::create("m_cc_axis", this);
        m_rc_axis = pcie_us_axis_pkg::pcie_us_axis_agent::type_id::create("m_rc_axis", this);
        m_rq_axis = pcie_us_axis_pkg::pcie_us_axis_agent::type_id::create("m_rq_axis", this);

        m_cc_fifo = new("m_cc_fifo", this);
        m_cov     = cg_csr::type_id::create("m_cov", this);

        // Ethernet MAC port, 512 bits (AXIS_ETH_DATA_WIDTH default).
        m_eth_tx_cfg = axis_pkg::axis_cfg::type_id::create("m_eth_tx_cfg");
        m_eth_tx_cfg.mode       = MODE_ACTIVE_SLAVE;
        m_eth_tx_cfg.data_width = 512;
        m_eth_tx_cfg.bp_profile = BP_NONE;
        m_eth_rx_cfg = axis_pkg::axis_cfg::type_id::create("m_eth_rx_cfg");
        m_eth_rx_cfg.mode       = MODE_ACTIVE_MASTER;
        m_eth_rx_cfg.data_width = 512;
        uvm_config_db #(axis_pkg::axis_cfg)::set(this, "m_eth_tx", "cfg", m_eth_tx_cfg);
        uvm_config_db #(axis_pkg::axis_cfg)::set(this, "m_eth_rx", "cfg", m_eth_rx_cfg);
        m_eth_tx = axis_pkg::axis_agent::type_id::create("m_eth_tx", this);
        m_eth_rx = axis_pkg::axis_agent::type_id::create("m_eth_rx", this);

        if (e2e) begin
            m_host = us_host::type_id::create("m_host", this);
            m_drv  = mqnic_drv::type_id::create("m_drv", this);
            m_sb   = sb_e2e::type_id::create("m_sb", this);
        end
        if (msix) begin
            m_msix_hip = us_msix_hip::type_id::create("m_msix_hip", this);
            m_msix_sb  = sb_msix::type_id::create("m_msix_sb", this);
        end
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        m_cc_axis.ap.connect(m_cc_fifo.analysis_export);
        m_cq_axis.ap.connect(m_cov.cq_imp);
        m_cc_axis.ap.connect(m_cov.cc_imp);

        if (e2e) begin
            m_host.cq_seqr = m_cq_axis.sequencer;
            m_host.rc_seqr = m_rc_axis.sequencer;
            m_host.shim    = m_shim;
            m_cc_axis.ap.connect(m_host.cc_imp);
            m_rq_axis.ap.connect(m_host.rq_imp);

            m_drv.host = m_host;
            m_drv.sb   = m_sb;
            m_drv.tx_ap.connect(m_sb.tx_exp_imp);
            m_drv.rx_ap.connect(m_sb.rx_host_imp);
            m_eth_tx.ap.connect(m_sb.tx_mac_imp);
            m_eth_rx.ap.connect(m_sb.rx_mac_imp);
        end
        if (msix) begin
            m_msix_sb.hip = m_msix_hip;
            m_msix_hip.ap.connect(m_msix_sb.imp);
            if (e2e) begin
                m_drv.msb = m_msix_sb;
                m_msix_hip.ap.connect(m_drv.msix_imp);
            end
        end
    endfunction

    virtual function bit is_idle();
        return m_cq_axis.is_idle() && m_rc_axis.is_idle();
    endfunction

endclass : tier6_env

`endif // TIER6_ENV_SV

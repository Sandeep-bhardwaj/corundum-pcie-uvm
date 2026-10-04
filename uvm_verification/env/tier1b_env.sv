// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tier1b_env - Tier 1b environment (TLP routing and buffering)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §5 Tier 1b, §11
// Introduced : Step 2
//
// Two DUTs, checked through the shared pcie_tlp UVC:
//
//   demux : m_dmx_in (master) -> pcie_tlp_demux_bar -> m_dmx_out[0..1] (slave)
//           checked by m_sb_dmx with BAR_BASE=0, BAR_STRIDE=2
//   mux   : m_mux_in[0..1] (master) -> pcie_tlp_mux -> m_mux_out (slave)
//           checked by m_sb_mux in merge mode; round-robin as mqnic_core_pcie
//           instantiates it (:778-785)
//
// pcie_tlp_fifo is not present - VCS rejects it at SEG_COUNT=1. The reason and
// the conditions for bringing it back are documented in tb_top_tier1b.sv.
//
// The demux configuration matches the one mqnic_core_pcie actually uses
// (:730-732), so BAR 0 goes to port 0, BAR 2 to port 1, and BAR 1 is dropped.
//
// The output agents are MODE_ACTIVE_SLAVE: they supply tlp_ready backpressure
// and monitor at the same time. Randomizing that backpressure is what makes the
// demux stall its input rather than drop - the property t1b_backpressure tests.
// -----------------------------------------------------------------------------

`ifndef TIER1B_ENV_SV
`define TIER1B_ENV_SV

// pcie_tlp_mux's `pause` input, set by tests and applied by tb_top_tier1b on the
// next clock. An object rather than an interface so no other tier's filelist
// has to carry a new interface for a Tier-1b-only control.
class tlp_mux_pause_ctrl extends uvm_object;
    `uvm_object_utils(tlp_mux_pause_ctrl)
    bit [1:0] pause;
    function new(string name = "tlp_mux_pause_ctrl");
        super.new(name);
    endfunction
endclass : tlp_mux_pause_ctrl

class tier1b_env extends uvm_env;

    `uvm_component_utils(tier1b_env)

    localparam int DEMUX_PORTS = 2;
    localparam int BAR_BASE    = 0;
    localparam int BAR_STRIDE  = 2;

    localparam int MUX_PORTS   = 2;

    pcie_tlp_cfg   m_dmx_in_cfg;
    pcie_tlp_cfg   m_dmx_out_cfg [DEMUX_PORTS];

    pcie_tlp_agent m_dmx_in;
    pcie_tlp_agent m_dmx_out [DEMUX_PORTS];

    sb_tlp         m_sb_dmx;
    cg_tlp         m_cov;

    // ---- mux: m_mux_in[0..1] (master) -> pcie_tlp_mux -> m_mux_out (slave) --
    pcie_tlp_cfg       m_mux_in_cfg [MUX_PORTS];
    pcie_tlp_cfg       m_mux_out_cfg;
    pcie_tlp_agent     m_mux_in [MUX_PORTS];
    pcie_tlp_agent     m_mux_out;
    sb_tlp             m_sb_mux;
    tlp_mux_pause_ctrl m_mux_pause;
    bit                has_mux;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    protected function pcie_tlp_cfg make_cfg(string name,
                                             mqnic_agent_mode_e mode);
        pcie_tlp_cfg c = pcie_tlp_cfg::type_id::create(name);
        c.mode       = mode;
        c.channel    = TLP_CH_RX_REQ;
        c.data_width = 256;
        c.seg_count  = 1;
        c.seq_width  = 6;
        c.bp_profile = BP_RANDOM;
        return c;
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // ---- demux ----------------------------------------------------------
        m_dmx_in_cfg = make_cfg("m_dmx_in_cfg", MODE_ACTIVE_MASTER);
        uvm_config_db #(pcie_tlp_cfg)::set(this, "m_dmx_in", "cfg", m_dmx_in_cfg);
        m_dmx_in = pcie_tlp_agent::type_id::create("m_dmx_in", this);

        foreach (m_dmx_out[p]) begin
            m_dmx_out_cfg[p] = make_cfg($sformatf("m_dmx_out_cfg%0d", p),
                                        MODE_ACTIVE_SLAVE);
            uvm_config_db #(pcie_tlp_cfg)::set(this, $sformatf("m_dmx_out%0d", p),
                                               "cfg", m_dmx_out_cfg[p]);
            uvm_config_db #(int)::set(this, $sformatf("m_dmx_out%0d", p),
                                      "port_id", p);
            m_dmx_out[p] = pcie_tlp_agent::type_id::create(
                               $sformatf("m_dmx_out%0d", p), this);
        end

        m_sb_dmx = sb_tlp::type_id::create("m_sb_dmx", this);
        m_sb_dmx.n_ports      = DEMUX_PORTS;
        m_sb_dmx.bar_base     = BAR_BASE;
        m_sb_dmx.bar_stride   = BAR_STRIDE;
        m_sb_dmx.route_by_bar = 1'b1;

        m_cov = cg_tlp::type_id::create("m_cov", this);
        m_sb_dmx.cov = m_cov;

        // ---- mux ------------------------------------------------------------
        // Built only when the top instantiates the mux (it publishes mux_pause);
        // the unified tb_top_tier1 carries the demux alone.
        has_mux = uvm_config_db #(tlp_mux_pause_ctrl)::get(this, "", "mux_pause", m_mux_pause);
        if (!has_mux) return;

        foreach (m_mux_in[p]) begin
            m_mux_in_cfg[p] = make_cfg($sformatf("m_mux_in_cfg%0d", p), MODE_ACTIVE_MASTER);
            uvm_config_db #(pcie_tlp_cfg)::set(this, $sformatf("m_mux_in%0d", p),
                                               "cfg", m_mux_in_cfg[p]);
            uvm_config_db #(int)::set(this, $sformatf("m_mux_in%0d", p), "port_id", p);
            m_mux_in[p] = pcie_tlp_agent::type_id::create($sformatf("m_mux_in%0d", p), this);
        end
        m_mux_out_cfg = make_cfg("m_mux_out_cfg", MODE_ACTIVE_SLAVE);
        uvm_config_db #(pcie_tlp_cfg)::set(this, "m_mux_out", "cfg", m_mux_out_cfg);
        m_mux_out = pcie_tlp_agent::type_id::create("m_mux_out", this);

        m_sb_mux = sb_tlp::type_id::create("m_sb_mux", this);
        m_sb_mux.n_ports      = MUX_PORTS;
        m_sb_mux.merge_inputs = 1'b1;
        m_sb_mux.route_by_bar = 1'b0;
        m_sb_mux.cov          = m_cov;
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        m_dmx_in.ap.connect(m_sb_dmx.in_imp);
        foreach (m_dmx_out[p])
            m_dmx_out[p].ap.connect(m_sb_dmx.out_imp);

        if (has_mux) begin
            foreach (m_mux_in[p])
                m_mux_in[p].ap.connect(m_sb_mux.in_imp);
            m_mux_out.ap.connect(m_sb_mux.out_imp);
        end

    endfunction

endclass : tier1b_env

`endif // TIER1B_ENV_SV

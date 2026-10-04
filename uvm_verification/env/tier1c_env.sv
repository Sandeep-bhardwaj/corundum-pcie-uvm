// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tier1c_env - Tier 1c environment (offload blocks)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §5 Tier 1c, §11
// Introduced : Step 3
//
//   m_stim  axis_agent MODE_ACTIVE_MASTER  -> shared ingress stream
//   m_csum  axis_agent MODE_PASSIVE        -> rx_checksum result
//   m_hash  axis_agent MODE_PASSIVE        -> rx_hash result
//   m_sb    sb_offload                     -> ref_checksum / ref_hash checking
//
// The stimulus agent's cfg has has_tready = 0: rx_checksum and rx_hash have no
// tready on their AXI-S inputs (verified against the RTL), so the driver
// presents one beat per clock and the monitor qualifies on tvalid alone.
//
// The two result agents reuse axis_agent rather than introducing a UVC for two
// non-streaming outputs. Their "packets" are single beats carrying the result:
// 16 bits of checksum, or 32 bits of hash with the 4-bit type on tuser.
// -----------------------------------------------------------------------------

`ifndef TIER1C_ENV_SV
`define TIER1C_ENV_SV

class tier1c_env extends uvm_env;

    `uvm_component_utils(tier1c_env)

    axis_cfg   m_stim_cfg;
    axis_cfg   m_csum_cfg;
    axis_cfg   m_hash_cfg;

    axis_agent m_stim;
    axis_agent m_csum;
    axis_agent m_hash;
    sb_offload m_sb;
    cg_offload m_cov;

    // ---- tx_checksum ---------------------------------------------------------
    axis_cfg        m_tx_in_cfg;
    axis_cfg        m_tx_out_cfg;
    axis_agent      m_tx_in;
    axis_agent      m_tx_out;
    csum_cmd_agent  m_tx_cmd;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // ---- stimulus: 256-bit ingress stream, NO tready ---------------------
        m_stim_cfg            = axis_cfg::type_id::create("m_stim_cfg");
        m_stim_cfg.mode       = MODE_ACTIVE_MASTER;
        m_stim_cfg.data_width = 256;
        m_stim_cfg.has_tready = 1'b0;
        m_stim_cfg.has_tlast  = 1'b1;
        m_stim_cfg.has_tkeep  = 1'b1;

        // ---- checksum result: 16 bits, valid-only, no packet boundary -------
        m_csum_cfg            = axis_cfg::type_id::create("m_csum_cfg");
        m_csum_cfg.mode       = MODE_PASSIVE;
        m_csum_cfg.data_width = 16;
        m_csum_cfg.has_tready = 1'b0;
        m_csum_cfg.has_tlast  = 1'b0;
        m_csum_cfg.has_tkeep  = 1'b0;

        // ---- hash result: 32 bits + 4-bit type on tuser ---------------------
        m_hash_cfg            = axis_cfg::type_id::create("m_hash_cfg");
        m_hash_cfg.mode       = MODE_PASSIVE;
        m_hash_cfg.data_width = 32;
        m_hash_cfg.has_tready = 1'b0;
        m_hash_cfg.has_tlast  = 1'b0;
        m_hash_cfg.has_tkeep  = 1'b0;

        uvm_config_db #(axis_cfg)::set(this, "m_stim", "cfg", m_stim_cfg);
        uvm_config_db #(axis_cfg)::set(this, "m_csum", "cfg", m_csum_cfg);
        uvm_config_db #(axis_cfg)::set(this, "m_hash", "cfg", m_hash_cfg);

        m_stim = axis_agent::type_id::create("m_stim", this);
        m_csum = axis_agent::type_id::create("m_csum", this);
        m_hash = axis_agent::type_id::create("m_hash", this);
        // ---- tx_checksum: full AXI-S both sides, WITH tready ---------------
        m_tx_in_cfg            = axis_cfg::type_id::create("m_tx_in_cfg");
        m_tx_in_cfg.mode       = MODE_ACTIVE_MASTER;
        m_tx_in_cfg.data_width = 256;
        m_tx_in_cfg.has_tready = 1'b1;

        m_tx_out_cfg            = axis_cfg::type_id::create("m_tx_out_cfg");
        m_tx_out_cfg.mode       = MODE_ACTIVE_SLAVE;   // supplies tready + monitors
        m_tx_out_cfg.data_width = 256;
        m_tx_out_cfg.has_tready = 1'b1;

        uvm_config_db #(axis_cfg)::set(this, "m_tx_in",  "cfg", m_tx_in_cfg);
        uvm_config_db #(axis_cfg)::set(this, "m_tx_out", "cfg", m_tx_out_cfg);

        m_tx_in  = axis_agent::type_id::create("m_tx_in", this);
        m_tx_out = axis_agent::type_id::create("m_tx_out", this);
        m_tx_cmd = csum_cmd_agent::type_id::create("m_tx_cmd", this);

        m_sb   = sb_offload::type_id::create("m_sb", this);
        m_cov  = cg_offload::type_id::create("m_cov", this);
        m_sb.cov = m_cov;
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        // The reference model must use the SAME key the top drives into
        // rx_hash.hash_key, or every hash mismatches for an uninteresting reason.
        begin
            byte unsigned k [];
            rss_key_default_bytes(k);
            m_sb.m_ref_hash.set_key(k);
        end

        m_stim.ap.connect(m_sb.stim_imp);
        m_csum.ap.connect(m_sb.csum_imp);
        m_hash.ap.connect(m_sb.hash_imp);

        m_tx_in.ap.connect(m_sb.tx_in_imp);
        m_tx_cmd.ap.connect(m_sb.tx_cmd_imp);
        m_tx_out.ap.connect(m_sb.tx_out_imp);
    endfunction

endclass : tier1c_env

`endif // TIER1C_ENV_SV

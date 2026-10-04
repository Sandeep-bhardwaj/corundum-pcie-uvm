// SPDX-License-Identifier: BSD-2-Clause-Views
//
// tier5_env - Tier 5 environment (mqnic_core_pcie)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §5 Tier 5, §8.2, §11
// Introduced : Step 7 (Tier 5)
//
//   m_req  pcie_tlp_agent MASTER -> BAR requests into the core
//   m_cpl  pcie_tlp_agent SLAVE  -> completions back out
//   m_cpl_collect                -> feeds completion data to mqnic_csr_ctx
//
// TWO AGENTS. THAT IS THE WHOLE ENVIRONMENT so far, and it is the clearest
// evidence the tiering worked: the DUT is 2,141 lines wrapping everything
// verified in Tiers 1-4, and the first test needs only the pcie_tlp UVC built
// at Tier 1b on a stateless demux.
//
// The register path is a SPLIT TRANSACTION - request out, completion back,
// matched by tag (see mqnic_csr_seq). The collector below is what closes that
// loop: a sequence cannot subscribe to an analysis port, so it parks a tag in
// the shared context and the collector fills in the data.
// -----------------------------------------------------------------------------

`ifndef TIER5_ENV_SV
`define TIER5_ENV_SV

// Turns observed completions into data the CSR sequences are waiting on.
class mqnic_cpl_collector extends uvm_subscriber #(pcie_tlp_item);

    `uvm_component_utils(mqnic_cpl_collector)

    mqnic_csr_ctx ctx;

    protected int unsigned m_n_cpl;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void write(pcie_tlp_item t);
        bit [7:0]  tag;
        bit [31:0] data;

        m_n_cpl++;
        if (ctx == null) return;

        tag = mqnic_vrf_pkg::tlp_hdr_cpl_tag(t.hdr);

        // A register read returns one DWORD. A completion with no payload is a
        // status-only response - deliver a recognisable poison value rather
        // than silently handing back zero, which reads like a real register.
        if (t.payload.size() >= 4)
            for (int b = 0; b < 4; b++) data[b*8 +: 8] = t.payload[b];
        else
            data = 32'hBAD0_C0DE;

        ctx.deliver(tag, data);
    endfunction

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf("collected %0d completion(s)", m_n_cpl), UVM_LOW)
    endfunction

endclass : mqnic_cpl_collector


class tier5_env extends uvm_env;

    `uvm_component_utils(tier5_env)

    pcie_tlp_cfg        m_req_cfg;
    pcie_tlp_cfg        m_cpl_cfg;

    pcie_tlp_agent      m_req;
    pcie_tlp_agent      m_cpl;
    mqnic_cpl_collector m_cpl_collect;

    mqnic_csr_ctx       m_ctx;
    cg_csr              m_cov;

    int unsigned data_width = 256;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        m_ctx = mqnic_csr_ctx::type_id::create("m_ctx");

        m_req_cfg = pcie_tlp_cfg::type_id::create("m_req_cfg");
        m_req_cfg.mode       = MODE_ACTIVE_MASTER;
        m_req_cfg.channel    = TLP_CH_RX_REQ;
        m_req_cfg.data_width = data_width;
        m_req_cfg.seg_count  = 1;
        m_req_cfg.has_error  = 1'b0;
        m_req_cfg.has_seq    = 1'b0;

        m_cpl_cfg = pcie_tlp_cfg::type_id::create("m_cpl_cfg");
        m_cpl_cfg.mode       = MODE_ACTIVE_SLAVE;
        m_cpl_cfg.channel    = TLP_CH_TX_CPL;
        m_cpl_cfg.data_width = data_width;
        m_cpl_cfg.seg_count  = 1;
        m_cpl_cfg.has_bar_id = 1'b0;
        m_cpl_cfg.has_error  = 1'b0;
        m_cpl_cfg.has_seq    = 1'b0;
        m_cpl_cfg.bp_profile = BP_NONE;   // never stall a register completion

        uvm_config_db #(pcie_tlp_cfg)::set(this, "m_req", "cfg", m_req_cfg);
        uvm_config_db #(pcie_tlp_cfg)::set(this, "m_cpl", "cfg", m_cpl_cfg);

        m_req         = pcie_tlp_agent::type_id::create("m_req", this);
        m_cpl         = pcie_tlp_agent::type_id::create("m_cpl", this);
        m_cpl_collect = mqnic_cpl_collector::type_id::create("m_cpl_collect", this);
        m_cov         = cg_csr::type_id::create("m_cov", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        m_cpl_collect.ctx = m_ctx;
        m_cpl.ap.connect(m_cpl_collect.analysis_export);
        m_req.ap.connect(m_cov.req_imp);
        m_cpl.ap.connect(m_cov.cpl_imp);
    endfunction

endclass : tier5_env

`endif // TIER5_ENV_SV

// SPDX-License-Identifier: BSD-2-Clause-Views
//
// cg_csr - Tier 5 / Tier 6 functional coverage (host register access)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §14 (Tiers 5-6)
// Introduced : coverage closure, after the 20-seed regression
//
// Fed from the MONITORS (§14.1): requests into the core and completions out of
// it, paired by tag. Tier 5 sees generic TLPs (req_imp / cpl_imp); Tier 6 sees
// the Xilinx CQ / CC streams (cq_imp / cc_imp), decoded at the same bit
// positions ref_tlp_shim uses (cq_parse :179, cc_encode :57).
//
// What is covered: every register block of the map (mqnic_core.v:776-812) and
// its header registers (TYPE / VER / NEXT) plus body, read and write, the
// completion status, and how many reads were already in flight when one was
// issued - the split-transaction depth t5_csr_outstanding exercises.
// -----------------------------------------------------------------------------

`ifndef CG_CSR_SV
`define CG_CSR_SV

`uvm_analysis_imp_decl(_csr_req)
`uvm_analysis_imp_decl(_csr_cpl)
`uvm_analysis_imp_decl(_csr_cq)
`uvm_analysis_imp_decl(_csr_cc)

class cg_csr extends uvm_component;

    `uvm_component_utils(cg_csr)

    uvm_analysis_imp_csr_req #(pcie_tlp_item, cg_csr)                   req_imp;
    uvm_analysis_imp_csr_cpl #(pcie_tlp_item, cg_csr)                   cpl_imp;
    uvm_analysis_imp_csr_cq  #(pcie_us_axis_pkg::pcie_us_axis_item, cg_csr) cq_imp;
    uvm_analysis_imp_csr_cc  #(pcie_us_axis_pkg::pcie_us_axis_item, cg_csr) cc_imp;

    // tag -> {address, reads outstanding when issued}
    protected bit [63:0]   m_pend_addr  [bit [7:0]];
    protected int unsigned m_pend_depth [bit [7:0]];

    protected int unsigned m_block;     // 0 FW_ID .. 6 CLK_INFO, 7 beyond the list
    protected int unsigned m_reg;       // 0 TYPE, 1 VER, 2 NEXT, 3 body
    protected bit          m_is_write;
    protected bit [2:0]    m_status;
    protected int unsigned m_depth;

    covergroup cg_access;
        option.per_instance = 1;

        cp_block : coverpoint m_block {
            bins fw_id = {0}; bins irq = {1}; bins iface = {2}; bins app = {3};
            bins stats = {4}; bins phc = {5}; bins clk_info = {6}; bins beyond = {7};
        }
        cp_reg   : coverpoint m_reg { bins type_ = {0}; bins ver = {1}; bins next_ = {2}; bins body = {3}; }
        cp_dir   : coverpoint m_is_write { bins read = {0}; bins write = {1}; }
        // pcie_axil_master answers every memory read with SC and every other
        // non-posted request with UR (:560-569). CA is defined (:159) but never
        // sent - AXI-Lite error responses are not propagated - so it is illegal
        // here: seeing it would be new behaviour.
        cp_status : coverpoint m_status iff (!m_is_write) {
            bins sc = {3'b000}; bins ur = {3'b001};
            illegal_bins never_sent = default;
        }
        cp_depth : coverpoint m_depth iff (!m_is_write) {
            bins alone = {0}; bins two_to_4 = {[1:3]}; bins deep = {[4:$]};
        }

        // Every block's list header is read - the walk the driver performs.
        x_walk   : cross cp_block, cp_reg iff (!m_is_write) {
            ignore_bins beyond_hdr = binsof(cp_block.beyond) && !binsof(cp_reg.body);
        }
        // No block x status cross: UR depends on the request TYPE, not the
        // address (pcie_axil_master.v:560), so "UR from each block" would be
        // 16 bins of the same behaviour.
    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        req_imp = new("req_imp", this);
        cpl_imp = new("cpl_imp", this);
        cq_imp  = new("cq_imp", this);
        cc_imp  = new("cc_imp", this);
        cg_access = new();
        cg_access.set_inst_name({get_full_name(), ".cg_access"});
    endfunction

    // Register block list of mqnic_core.v:776-812 (as walked by t5/t6_rb_walk).
    protected function void classify(bit [63:0] addr);
        int unsigned a = int'(addr & 64'hFFFF_FFFF);
        int unsigned bases [7] = '{'h000, 'h040, 'h050, 'h070, 'h080, 'h100, 'h200};
        int unsigned sizes [7] = '{'h040, 'h010, 'h020, 'h010, 'h080, 'h100, 'h100};
        m_block = 7;
        m_reg   = 3;
        foreach (bases[i])
            if (a >= bases[i] && a < bases[i] + sizes[i]) begin
                m_block = i;
                case (a - bases[i])
                    0: m_reg = 0;  4: m_reg = 1;  8: m_reg = 2;  default: m_reg = 3;
                endcase
            end
    endfunction

    protected function void on_request(bit [7:0] tag, bit [63:0] addr, bit is_write);
        if (is_write) begin                 // posted: no completion to wait for
            classify(addr);
            m_is_write = 1'b1;
            m_depth    = 0;
            cg_access.sample();
            return;
        end
        m_pend_depth[tag] = m_pend_addr.size();
        m_pend_addr[tag]  = addr;
    endfunction

    protected function void on_completion(bit [7:0] tag, bit [2:0] status);
        if (!m_pend_addr.exists(tag)) return;
        classify(m_pend_addr[tag]);
        m_is_write = 1'b0;
        m_status   = status;
        m_depth    = m_pend_depth[tag];
        m_pend_addr.delete(tag);
        m_pend_depth.delete(tag);
        cg_access.sample();
    endfunction

    // ---- Tier 5: generic TLP ------------------------------------------------
    virtual function void write_csr_req(pcie_tlp_item t);
        on_request(mqnic_vrf_pkg::tlp_hdr_req_tag(t.hdr),
                   mqnic_vrf_pkg::tlp_hdr_req_byte_addr(t.hdr),
                   t.hdr[126]);                             // fmt[1]: has payload
    endfunction

    virtual function void write_csr_cpl(pcie_tlp_item t);
        on_completion(mqnic_vrf_pkg::tlp_hdr_cpl_tag(t.hdr),
                      mqnic_vrf_pkg::tlp_hdr_cpl_status(t.hdr));
    endfunction

    // ---- Tier 6: Xilinx CQ / CC descriptors ---------------------------------
    virtual function void write_csr_cq(pcie_us_axis_pkg::pcie_us_axis_item t);
        bit [127:0] d;
        if (t.dwords.size() < 4) return;
        for (int i = 0; i < 4; i++) d[i*32 +: 32] = t.dwords[i];
        // d[63:2] address, d[78:75] request type (1 = memory write), d[103:96] tag
        on_request(d[103:96], {d[63:2], 2'b00}, d[78:75] == 4'b0001);
    endfunction

    virtual function void write_csr_cc(pcie_us_axis_pkg::pcie_us_axis_item t);
        bit [95:0] d;
        if (t.dwords.size() < 3) return;
        for (int i = 0; i < 3; i++) d[i*32 +: 32] = t.dwords[i];
        on_completion(d[71:64], d[45:43]);                   // tag, status
    endfunction

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf("register access coverage %.2f%%", cg_access.get_coverage()), UVM_LOW)
    endfunction

endclass : cg_csr

`endif // CG_CSR_SV

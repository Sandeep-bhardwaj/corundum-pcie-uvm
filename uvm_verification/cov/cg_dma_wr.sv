// SPDX-License-Identifier: BSD-2-Clause-Views
//
// cg_dma_wr - Tier 3b functional coverage (PCIe DMA WRITE engine)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §14.3 (write side)
// Introduced : coverage closure, after the 20-seed regression
//
// The write engine's splitting rules are the read engine's with MPS in place of
// MRRS and no RCB rule: a request may not exceed MPS or cross 4 KB, and the
// first request is shortened to reach an MPS-aligned boundary. As in cg_dma the
// axes that INTERACT are crossed (length x PCIe alignment x MPS), coarsely
// enough that every bin is reachable.
//
// Immediate descriptors (imm_en) take their data from the descriptor, not RAM -
// a separate datapath through dma_if_pcie_wr - so they get their own cross.
// Sampled by sb_dma_wr on every descriptor, with the request count known from
// ref_dma.split_write.
// -----------------------------------------------------------------------------

`ifndef CG_DMA_WR_SV
`define CG_DMA_WR_SV

class cg_dma_wr extends uvm_component;

    `uvm_component_utils(cg_dma_wr)

    protected int unsigned m_len;
    protected bit [63:0]   m_pcie_addr;
    protected int unsigned m_ram_addr;
    protected int unsigned m_n_req;
    protected bit          m_crossed_4k;
    protected bit [2:0]    m_mps;
    protected bit          m_imm;
    protected bit [3:0]    m_error;

    covergroup cg_descriptor;
        option.per_instance = 1;
        option.name         = "cg_dma_wr_descriptor";

        cp_len : coverpoint m_len {
            bins b_1       = {1};
            bins b_small   = {[2:127]};
            bins b_128     = {128};
            bins b_mid     = {[129:255]};
            bins b_256     = {256};
            bins b_large   = {[257:4095]};
            bins b_4k      = {4096};
            bins b_huge    = {[4097:$]};
        }
        // Offset within a DWORD (the payload is sent in whole DWORDs, so a
        // non-zero offset needs leading pad) and within the 128-byte minimum MPS.
        cp_dw_off  : coverpoint m_pcie_addr[1:0] { bins b_0 = {0}; bins b_1_3 = {[1:3]}; }
        cp_mps_off : coverpoint int'(m_pcie_addr % 128) {
            bins b_0 = {0}; bins b_low = {[1:63]}; bins b_high = {[64:127]};
        }
        cp_ram_align : coverpoint int'(m_ram_addr % 64) {
            bins b_0 = {0}; bins b_1_3 = {[1:3]}; bins b_rest = {[4:63]};
        }
        // 128..1024: the values the Tier 3b tests configure (t3b_mps_sweep).
        cp_mps : coverpoint m_mps {
            bins b_128 = {3'd0}; bins b_256 = {3'd1}; bins b_512 = {3'd2}; bins b_1k = {3'd3};
        }
        cp_n_req : coverpoint m_n_req {
            bins b_1 = {1}; bins b_2 = {2}; bins b_3_8 = {[3:8]}; bins b_many = {[9:$]};
        }
        cp_4k  : coverpoint m_crossed_4k { bins b_no = {0}; bins b_yes = {1}; }
        cp_imm : coverpoint m_imm { bins ram = {0}; bins immediate = {1}; }

        x_split   : cross cp_len, cp_mps_off, cp_mps;
        x_realign : cross cp_dw_off, cp_ram_align;
        x_4k      : cross cp_4k, cp_len {
            ignore_bins short_never_crosses = binsof(cp_len.b_1) && binsof(cp_4k.b_yes);
            // More than 4096 bytes cannot fit between two 4 KB boundaries.
            ignore_bins huge_always_crosses = binsof(cp_len.b_huge) && binsof(cp_4k.b_no);
        }
        // Immediate data is IMM_WIDTH = 32 bits (tb_top_tier3b.sv:43), so an
        // immediate descriptor is at most 4 bytes long.
        x_imm     : cross cp_imm, cp_dw_off, cp_len {
            ignore_bins imm_is_short = binsof(cp_imm.immediate)
                && !binsof(cp_len) intersect {[1:4]};
        }
    endgroup

    covergroup cg_status;
        option.per_instance = 1;
        option.name         = "cg_dma_wr_status";
        cp_error : coverpoint m_error {
            bins b_none = {4'd0};
            bins b_other = default;
        }
    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        cg_descriptor = new();
        cg_descriptor.set_inst_name({get_full_name(), ".cg_descriptor"});
        cg_status     = new();
        cg_status.set_inst_name({get_full_name(), ".cg_status"});
    endfunction

    virtual function void sample_descriptor(int unsigned len, bit [63:0] pcie_addr,
                                            int unsigned ram_addr, int unsigned n_req,
                                            bit [2:0] mps, bit imm);
        m_len        = len;
        m_pcie_addr  = pcie_addr;
        m_ram_addr   = ram_addr;
        m_n_req      = n_req;
        m_crossed_4k = (int'(pcie_addr % 4096) + len) > 4096;
        m_mps        = mps;
        m_imm        = imm;
        cg_descriptor.sample();
    endfunction

    virtual function void sample_status(bit [3:0] error);
        m_error = error;
        cg_status.sample();
    endfunction

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf("write descriptor coverage %.2f%%", cg_descriptor.get_coverage()),
            UVM_LOW)
    endfunction

endclass : cg_dma_wr

`endif // CG_DMA_WR_SV

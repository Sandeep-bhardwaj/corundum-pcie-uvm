// SPDX-License-Identifier: BSD-2-Clause-Views
//
// cg_dma - Tier 3 functional coverage (PCIe DMA engine)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §14.3
// Introduced : Step 5 (Tier 3)
//
// §14.3 asks for a CROSS, not a set of independent bins, and the distinction is
// the whole point. The splitting rules INTERACT: a length that is legal on its
// own becomes a 4 KB crossing at one alignment and not at another, and an RCB of
// 128 changes where the first request ends. Covering length and alignment
// separately can reach 100% while never once producing the combination that
// breaks the DUT.
//
// The cross is deliberately coarse on each axis. length x pcie_align x ram_align
// x MRRS x RCB at full resolution is millions of bins that no regression will
// ever fill; binned as below it is a few hundred, all of them reachable, and
// each one naming a real behaviour.
// -----------------------------------------------------------------------------

`ifndef CG_DMA_SV
`define CG_DMA_SV

class cg_dma extends uvm_component;

    `uvm_component_utils(cg_dma)

    // Sampled from the descriptor.
    protected int unsigned m_len;
    protected bit [63:0]   m_pcie_addr;
    protected int unsigned m_ram_addr;
    protected int unsigned m_n_req;      // how many TLPs this descriptor produced
    protected bit          m_crossed_4k;

    // Configuration in force when it was sampled.
    protected bit [2:0]    m_mrrs;
    protected bit          m_rcb_128b;
    protected bit          m_ext_tag;

    // Sampled from the status.
    protected bit [3:0]    m_error;

    // -------------------------------------------------------------------------
    covergroup cg_descriptor;
        option.per_instance = 1;
        option.name         = "cg_dma_descriptor";

        // Lengths chosen around the boundaries that matter: one DWORD, one RCB,
        // one MRRS, and either side of each.
        cp_len : coverpoint m_len {
            bins b_1        = {1};
            bins b_small    = {[2:63]};
            bins b_rcb      = {64};
            bins b_63_65    = {63, 65};
            bins b_mid      = {[66:511]};
            bins b_mrrs     = {512};
            bins b_511_513  = {511, 513};
            bins b_large    = {[514:4095]};
            bins b_4k       = {4096};
            bins b_huge     = {[4097:65535]};
        }

        // Alignment of the SOURCE address within an RCB block. Offset 0 is the
        // case where rule 3 does nothing; every other value shortens the first
        // request, which is the behaviour most easily got wrong.
        cp_pcie_align : coverpoint int'(m_pcie_addr % 64) {
            bins b_0    = {0};
            bins b_4    = {4};
            bins b_1_3  = {[1:3]};
            bins b_low  = {[5:31]};
            bins b_32   = {32};
            bins b_high = {[33:63]};
        }

        // Alignment of the DESTINATION within a RAM segment word. The DMA has to
        // realign when source and destination offsets differ, and that path is
        // only reached when they actually do.
        cp_ram_align : coverpoint int'(m_ram_addr % 64) {
            bins b_0    = {0};
            bins b_4    = {4};
            bins b_1_3  = {[1:3]};
            bins b_low  = {[5:31]};
            bins b_32   = {32};
            bins b_high = {[33:63]};
        }

        cp_mrrs : coverpoint m_mrrs {
            bins b_128  = {3'd0};
            bins b_256  = {3'd1};
            bins b_512  = {3'd2};
            bins b_1k   = {3'd3};
            bins b_2k   = {3'd4};
            bins b_4k   = {3'd5};
        }

        cp_rcb : coverpoint m_rcb_128b { bins b_64 = {0}; bins b_128 = {1}; }

        cp_ext_tag : coverpoint m_ext_tag { bins b_off = {0}; bins b_on = {1}; }

        // Did this descriptor actually have to be split?
        cp_n_req : coverpoint m_n_req {
            bins b_1     = {1};
            bins b_2     = {2};
            bins b_3_4   = {[3:4]};
            bins b_5_8   = {[5:8]};
            bins b_many  = {[9:$]};
        }

        cp_4k : coverpoint m_crossed_4k { bins b_no = {0}; bins b_yes = {1}; }

        // ---- the cross §14.3 actually asks for ------------------------------
        // Only the axes that interact. Adding ext_tag here would multiply the
        // bin count for no extra behaviour: tag width does not change where a
        // request is split.
        x_split : cross cp_len, cp_pcie_align, cp_mrrs, cp_rcb {
            // A descriptor shorter than one DWORD past an aligned start can
            // never be split, so those combinations are not reachable.
            ignore_bins tiny_never_splits =
                binsof(cp_len) intersect {1} && binsof(cp_pcie_align) intersect {0};
        }

        // Realignment: source offset against destination offset.
        x_realign : cross cp_pcie_align, cp_ram_align;

        // Boundary crossing against length.
        x_4k : cross cp_4k, cp_len {
            // One byte cannot cross a 4 KB boundary; more than 4096 bytes must.
            ignore_bins one_byte_never = binsof(cp_len.b_1) && binsof(cp_4k.b_yes);
            ignore_bins huge_always    = binsof(cp_len.b_huge) && binsof(cp_4k.b_no);
        }
    endgroup

    // -------------------------------------------------------------------------
    covergroup cg_status;
        option.per_instance = 1;
        option.name         = "cg_dma_status";

        // Codes are the DUT's own (dma_if_pcie_rd.v:281-291), not a local
        // invention - see mqnic_dma_error_e.
        cp_error : coverpoint m_error {
            bins b_none    = {4'd0};    // DMA_ERROR_NONE
            bins b_timeout = {4'd1};    // DMA_ERROR_TIMEOUT
            bins b_flr     = {4'd8};    // DMA_ERROR_PCIE_FLR
            bins b_poison  = {4'd9};    // DMA_ERROR_PCIE_CPL_POISONED
            bins b_ur      = {4'd10};   // DMA_ERROR_PCIE_CPL_STATUS_UR
            bins b_ca      = {4'd11};   // DMA_ERROR_PCIE_CPL_STATUS_CA
            bins b_other   = default;
        }
    endgroup

    // -------------------------------------------------------------------------
    function new(string name, uvm_component parent);
        super.new(name, parent);
        cg_descriptor = new();
        cg_descriptor.set_inst_name({get_full_name(), ".cg_descriptor"});
        cg_status     = new();
        cg_status.set_inst_name({get_full_name(), ".cg_status"});
    endfunction

    // Called once per descriptor, AFTER its requests are known - the request
    // count is part of what is being covered.
    virtual function void sample_descriptor(int unsigned len,
                                            bit [63:0]   pcie_addr,
                                            int unsigned ram_addr,
                                            int unsigned n_req,
                                            bit          crossed_4k,
                                            bit [2:0]    mrrs,
                                            bit          rcb_128b,
                                            bit          ext_tag);
        m_len        = len;
        m_pcie_addr  = pcie_addr;
        m_ram_addr   = ram_addr;
        m_n_req      = n_req;
        m_crossed_4k = crossed_4k;
        m_mrrs       = mrrs;
        m_rcb_128b   = rcb_128b;
        m_ext_tag    = ext_tag;
        cg_descriptor.sample();
    endfunction

    virtual function void sample_status(bit [3:0] error);
        m_error = error;
        cg_status.sample();
    endfunction

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf("descriptor coverage %.2f%%, status coverage %.2f%%",
                      cg_descriptor.get_coverage(), cg_status.get_coverage()),
            UVM_LOW)
    endfunction

endclass : cg_dma

`endif // CG_DMA_SV

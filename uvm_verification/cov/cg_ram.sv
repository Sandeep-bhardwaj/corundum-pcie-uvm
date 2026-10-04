// SPDX-License-Identifier: BSD-2-Clause-Views
//
// cg_ram / cg_client - Tier 2 functional coverage
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §14 (Tier 2)
// Introduced : coverage closure, after the 20-seed regression
//
// cg_ram (dma_psdpram and its async/CDC variant), sampled by sb_dma_ram:
//   every segment x byte-enable shape - a partial write must leave the other
//   bytes alone, and a per-segment bug shows only on the segment it lives in -
//   and reads of written vs never-written words.
//
// cg_client (dma_client_axis_sink / _source), sampled by sb_dma_client: the
// sink writes min(descriptor, packet) bytes, so the packet can be shorter,
// equal or longer than the descriptor; both clients scatter/gather across the
// segments, so the start (segment 0 or 1 of the 16-byte client RAM word) and
// the length relative to it exercise the scatter/gather. Only 8-byte-aligned
// starts are legal: both clients mask the low address bits.
// -----------------------------------------------------------------------------

`ifndef CG_RAM_SV
`define CG_RAM_SV

class cg_ram extends uvm_component;

    `uvm_component_utils(cg_ram)

    int unsigned seg_be_width = 16;

    protected int unsigned m_seg;
    protected int unsigned m_be_cls;    // 0 full, 1 single, 2 low half, 3 high half, 4 sparse
    protected bit          m_is_read;
    protected bit          m_written;   // read of a word written earlier

    covergroup cg_access;
        option.per_instance = 1;

        cp_seg  : coverpoint m_seg { bins s0 = {0}; bins s1 = {1}; }
        cp_kind : coverpoint m_is_read { bins write = {0}; bins read = {1}; }
        cp_be   : coverpoint m_be_cls iff (!m_is_read) {
            bins full = {0}; bins single = {1}; bins low_half = {2};
            bins high_half = {3}; bins sparse = {4};
        }
        cp_hit  : coverpoint m_written iff (m_is_read) {
            bins never_written = {0}; bins written = {1};
        }
        x_seg_be   : cross cp_seg, cp_be;
        x_seg_kind : cross cp_seg, cp_kind;
        x_seg_hit  : cross cp_seg, cp_hit;
    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        cg_access = new();
        cg_access.set_inst_name({get_full_name(), ".cg_access"});
    endfunction

    protected function int unsigned be_class(bit [63:0] be);
        int unsigned n = $countones(be[15:0]);
        bit [15:0]   b = be[15:0];
        if (n == seg_be_width)          return 0;
        if (n == 1)                     return 1;
        if (b == 16'h00FF)              return 2;
        if (b == 16'hFF00)              return 3;
        return 4;
    endfunction

    virtual function void sample_write(int unsigned seg, bit [63:0] be);
        m_seg = seg; m_is_read = 0; m_be_cls = be_class(be);
        cg_access.sample();
    endfunction

    virtual function void sample_read(int unsigned seg, bit written);
        m_seg = seg; m_is_read = 1; m_written = written;
        cg_access.sample();
    endfunction

endclass : cg_ram


class cg_client extends uvm_component;

    `uvm_component_utils(cg_client)

    // Client RAM geometry (tier2_env m_cli_*_ram_cfg): 2 segments x 64 bits, so
    // a RAM word is 16 bytes and segment 1 starts at byte 8.
    localparam int WORD = 16;

    protected bit          m_is_source;
    protected int unsigned m_len;
    protected int unsigned m_align;     // ram_addr % WORD
    protected int unsigned m_rel;       // sink: 0 pkt<desc, 1 equal, 2 pkt>desc

    covergroup cg_xfer;
        option.per_instance = 1;
        option.name         = "cg_client_xfer";

        cp_dir : coverpoint m_is_source { bins sink = {0}; bins source = {1}; }
        cp_len : coverpoint m_len {
            bins one        = {1};
            bins in_seg     = {[2:7]};
            bins one_seg    = {8};
            bins in_word    = {[9:15]};
            bins one_word   = {16};
            bins multi_word = {[17:$]};
        }
        // Both clients mask ram_addr to the AXI-stream word (ADDR_MASK,
        // dma_client_axis_source.v:137 / _sink.v:139): 8 bytes at this 64-bit
        // stream width. An unaligned descriptor is outside the DUT's contract.
        cp_align : coverpoint m_align {
            bins word_start = {0};
            bins seg1_start = {8};
            illegal_bins unaligned = {[1:7], [9:15]};
        }
        cp_rel : coverpoint m_rel iff (!m_is_source) {
            bins pkt_shorter = {0}; bins equal = {1}; bins pkt_longer = {2};
        }
        x_dir_len_align : cross cp_dir, cp_len, cp_align;
        x_sink_rel_len  : cross cp_rel, cp_len;
    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        cg_xfer = new();
        cg_xfer.set_inst_name({get_full_name(), ".cg_xfer"});
    endfunction

    virtual function void sample_sink(int unsigned desc_len, int unsigned pkt_len,
                                      int unsigned ram_addr);
        m_is_source = 0;
        m_len   = (pkt_len < desc_len) ? pkt_len : desc_len;    // bytes written
        m_align = ram_addr % WORD;
        m_rel   = (pkt_len < desc_len) ? 0 : (pkt_len == desc_len) ? 1 : 2;
        cg_xfer.sample();
    endfunction

    virtual function void sample_source(int unsigned len, int unsigned ram_addr);
        m_is_source = 1;
        m_len   = len;
        m_align = ram_addr % WORD;
        cg_xfer.sample();
    endfunction

endclass : cg_client

`endif // CG_RAM_SV

// SPDX-License-Identifier: BSD-2-Clause-Views
//
// us_host - the host, as seen from mqnic_core_pcie_us (objective G5)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §9 (host memory / root complex), §5 Tier 6
// Introduced : G5 end-to-end datapath
//
// Everything the DUT can reach on the PCIe side, in one place:
//
//   BAR MASTER  read32()/write32() as CQ requests, completions collected off CC
//               by tag. This is the driver's only window into the device.
//   DMA TARGET  every RQ TLP the DUT issues is decoded and acted on: writes
//               land in mqnic_host_mem_model, reads are answered with RC
//               completions built by mqnic_rc_model from that same memory.
//
// NOTHING HERE KNOWS A DESCRIPTOR BIT POSITION. An RQ descriptor has the CQ
// layout (both are Xilinx "request" descriptors), so ref_tlp_shim.cq_parse()
// turns it into a generic header; completions go out through cc_encode(),
// which rc_parse() inverts (the RC and CC descriptors share a layout). Both
// directions were round-trip checked at Tier 4, so the host model inherits
// that validation instead of re-deriving the Xilinx formats.
//
// The completer obeys the same legality rules as at Tier 3 (RCB-aligned
// splits, byte_count to the end of the request, byte-exact lower address),
// because it IS the Tier 3 model - only the transport differs.
// -----------------------------------------------------------------------------

`ifndef US_HOST_SV
`define US_HOST_SV

`uvm_analysis_imp_decl(_host_cc)
`uvm_analysis_imp_decl(_host_rq)

class us_host extends uvm_component;

    `uvm_component_utils(us_host)

    uvm_analysis_imp_host_cc #(pcie_us_axis_pkg::pcie_us_axis_item, us_host) cc_imp;
    uvm_analysis_imp_host_rq #(pcie_us_axis_pkg::pcie_us_axis_item, us_host) rq_imp;

    pcie_us_axis_pkg::pcie_us_axis_sequencer cq_seqr;   // host -> device requests
    pcie_us_axis_pkg::pcie_us_axis_sequencer rc_seqr;   // host -> device completions

    ref_tlp_shim         shim;
    mqnic_host_mem_model mem;
    mqnic_rc_model       rc;

    virtual mqnic_reset_if rst_vif;

    // ---- BAR master state ----------------------------------------------------
    protected bit [31:0] m_cpl_data [bit [7:0]];
    protected bit [2:0]  m_cpl_status [bit [7:0]];
    protected bit        m_tag_busy [bit [7:0]];
    protected bit [7:0]  m_next_tag;
    protected semaphore  m_tag_lock;
    int unsigned         bar_timeout_cycles = 20000;

    // ---- DMA target state ----------------------------------------------------
    protected rc_completion m_pending [$];
    protected event         m_work;
    protected int unsigned  m_reads_outstanding;

    // ---- statistics ----------------------------------------------------------
    int unsigned n_bar_reads, n_bar_writes;
    int unsigned n_dma_rd_tlp, n_dma_wr_tlp, n_rc_cpl;
    longint unsigned n_dma_rd_bytes, n_dma_wr_bytes;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        cc_imp     = new("cc_imp", this);
        rq_imp     = new("rq_imp", this);
        m_tag_lock = new(1);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (shim == null) shim = ref_tlp_shim::type_id::create("shim");
        if (mem  == null) mem  = mqnic_host_mem_model::type_id::create("mem");
        if (rc   == null) rc   = mqnic_rc_model::type_id::create("rc");
        rc.mem = mem;
        if (!uvm_config_db #(virtual mqnic_reset_if)::get(this, "", "rst_vif", rst_vif))
            void'(uvm_config_db #(virtual mqnic_reset_if)::get(null, "uvm_test_top", "rst_vif", rst_vif));
        if (rst_vif == null)
            `uvm_fatal(get_type_name(), "no mqnic_reset_if available for timing")
    endfunction

    // =========================================================================
    // BAR master
    // =========================================================================

    // Tags are allocated from a free set rather than a bare counter: a slow
    // read must never share a tag with a later one.
    protected task alloc_tag(output bit [7:0] tag);
        m_tag_lock.get();
        while (m_tag_busy.exists(m_next_tag)) m_next_tag++;
        tag = m_next_tag;
        m_tag_busy[tag] = 1'b1;
        m_next_tag++;
        m_tag_lock.put();
    endtask

    protected task send_cq(bit [127:0] hdr, bit [31:0] payload [$] = {});
        pcie_us_axis_pkg::pcie_us_axis_single_seq s;
        bit [127:0] desc = shim.cq_encode(hdr);
        s = pcie_us_axis_pkg::pcie_us_axis_single_seq::type_id::create("cq");
        s.dwords = new[4 + payload.size()];
        for (int i = 0; i < 4; i++) s.dwords[i] = desc[i*32 +: 32];
        foreach (payload[i]) s.dwords[4 + i] = payload[i];
        if (!s.randomize() with { delay inside {[0:2]}; })
            `uvm_fatal(get_type_name(), "randomize failed")
        s.start(cq_seqr);
    endtask

    // One 32-bit BAR read (non-posted; waits for its completion).
    virtual task read32(input bit [63:0] addr, output bit [31:0] data);
        bit [127:0] hdr;
        bit [7:0]   tag;
        int         waited = 0;
        int         limit  = bar_timeout_cycles;   // no cast in the while: xsim lint rule 6

        alloc_tag(tag);
        m_cpl_data.delete(tag);
        hdr = mqnic_vrf_pkg::tlp_hdr_read_req(.addr(addr), .dw_len(1),
                                              .tag(tag), .requester_id(16'h0000));
        send_cq(hdr);
        n_bar_reads++;

        while (!m_cpl_data.exists(tag) && waited < limit) begin
            @(posedge rst_vif.clk);
            waited++;
        end
        if (!m_cpl_data.exists(tag)) begin
            `uvm_error(get_type_name(),
                $sformatf("BAR read at 0x%0h (tag 0x%02h) got no completion in %0d cycles",
                          addr, tag, bar_timeout_cycles))
            data = 32'hDEAD_BEEF;
        end
        else begin
            data = m_cpl_data[tag];
            if (m_cpl_status[tag] != 3'b000)
                `uvm_error(get_type_name(),
                    $sformatf("BAR read at 0x%0h completed with status %0d", addr,
                              m_cpl_status[tag]))
        end
        m_tag_lock.get();
        m_tag_busy.delete(tag);
        m_cpl_data.delete(tag);
        m_tag_lock.put();
    endtask

    // One posted 32-bit BAR write.
    virtual task write32(bit [63:0] addr, bit [31:0] data);
        bit [127:0] h = '0;
        h[127:125] = mqnic_vrf_pkg::TLP_FMT_3DW_DATA;
        h[124:120] = mqnic_vrf_pkg::TLP_TYPE_MEM;
        h[105:96]  = 10'd1;
        h[95:80]   = 16'h0000;
        h[67:64]   = 4'b1111;
        h[63:34]   = addr[31:2];
        send_cq(h, '{data});
        n_bar_writes++;
    endtask

    // Completions for BAR reads. Status-only completions carry no data.
    virtual function void write_host_cc(pcie_us_axis_pkg::pcie_us_axis_item it);
        bit [95:0] desc;
        bit [7:0]  tag;
        if (it.dwords.size() < 3) begin
            `uvm_error(get_type_name(), "CC TLP shorter than its descriptor")
            return;
        end
        for (int i = 0; i < 3; i++) desc[i*32 +: 32] = it.dwords[i];
        tag = shim.rc_parse(desc)[47:40];
        if (!m_tag_busy.exists(tag)) begin
            `uvm_error(get_type_name(),
                $sformatf("CC completion for tag 0x%02h, which no BAR read is waiting on", tag))
            return;
        end
        m_cpl_status[tag] = desc[45:43];
        m_cpl_data[tag]   = (it.dwords.size() >= 4) ? it.dwords[3] : 32'hBAD0_C0DE;
    endfunction

    // =========================================================================
    // DMA target
    // =========================================================================
    virtual function void write_host_rq(pcie_us_axis_pkg::pcie_us_axis_item it);
        bit [127:0]  desc, hdr;
        bit [63:0]   addr;
        int unsigned len, pad;
        bit [3:0]    req;
        bit [7:0]    tag;
        bit [15:0]   rid;
        byte unsigned wire_bytes [];
        rc_completion cpls [$];

        if (it.dwords.size() < 4) begin
            `uvm_error(get_type_name(), "RQ TLP shorter than its descriptor")
            return;
        end
        desc = shim.unpack_desc(it.dwords, 4);
        // An RQ descriptor IS a request descriptor - same layout as CQ.
        hdr  = shim.cq_parse(desc, it.first_be, it.last_be);
        req  = desc[78:75];
        addr = mqnic_vrf_pkg::tlp_hdr_req_byte_addr(hdr);
        len  = mqnic_vrf_pkg::tlp_hdr_req_byte_len(hdr);
        tag  = hdr[79:72];
        rid  = hdr[95:80];

        case (req)
            4'b0001: begin   // memory write
                pad = int'(addr[1:0]);
                if ((it.dwords.size() - 4) * 4 < pad + len) begin
                    `uvm_error(get_type_name(),
                        $sformatf({"DMA write at 0x%0h claims %0d byte(s) but carries ",
                                   "%0d payload DWORD(s)"}, addr, len, it.dwords.size() - 4))
                    return;
                end
                wire_bytes = new[len];
                for (int i = 0; i < int'(len); i++)
                    wire_bytes[i] = it.dwords[4 + (pad + i) / 4][((pad + i) % 4) * 8 +: 8];
                mem.write_bytes(addr, wire_bytes);
                n_dma_wr_tlp++;
                n_dma_wr_bytes += len;
                `uvm_info(get_type_name(),
                    $sformatf("DMA write 0x%0h len %0d", addr, len), UVM_HIGH)
            end
            4'b0000: begin   // memory read
                if (len == 0) len = 1;   // zero-length read still completes
                rc.complete_read(addr, len, tag, rid, cpls);
                if (cpls.size() == 0) return;
                n_dma_rd_tlp++;
                n_dma_rd_bytes += len;
                m_reads_outstanding++;
                foreach (cpls[i]) m_pending.push_back(cpls[i]);
                rc.reorder(m_pending);
                ->m_work;
                `uvm_info(get_type_name(),
                    $sformatf("DMA read 0x%0h len %0d tag 0x%02h -> %0d completion(s)",
                              addr, len, tag, cpls.size()), UVM_HIGH)
            end
            default:
                `uvm_error(get_type_name(),
                    $sformatf("RQ request type %04b - the DMA engines issue only memory reads and writes",
                              req))
        endcase
    endfunction

    virtual task run_phase(uvm_phase phase);
        rc_completion c;
        forever begin
            while (m_pending.size() == 0) @m_work;
            c = m_pending.pop_front();
            emit_rc(c);
            n_rc_cpl++;
            if (c.is_last && m_reads_outstanding > 0) m_reads_outstanding--;
        end
    endtask

    // One completion onto RC: descriptor (3 DWORDs) then the wire payload.
    protected virtual task emit_rc(rc_completion c);
        pcie_us_axis_pkg::pcie_us_axis_single_seq s;
        bit [127:0] hdr;
        bit [95:0]  desc;
        int unsigned n_dw = c.payload.size() / 4;

        hdr  = mqnic_vrf_pkg::tlp_hdr_completion(rc.completer_id, c.status, c.byte_count,
                                                 c.requester_id, c.tag, c.lower_address,
                                                 n_dw, c.poisoned);
        desc = shim.cc_encode(hdr);

        s = pcie_us_axis_pkg::pcie_us_axis_single_seq::type_id::create("rc");
        s.dwords = new[3 + n_dw];
        for (int i = 0; i < 3; i++) s.dwords[i] = desc[i*32 +: 32];
        for (int i = 0; i < int'(n_dw); i++)
            s.dwords[3 + i] = {c.payload[i*4 + 3], c.payload[i*4 + 2],
                               c.payload[i*4 + 1], c.payload[i*4]};
        if (!s.randomize() with { delay inside {[0:1]}; })
            `uvm_fatal(get_type_name(), "randomize failed")
        s.start(rc_seqr);
    endtask

    // Reads answered in full and nothing queued.
    virtual function bit is_idle();
        return (m_pending.size() == 0) && (m_reads_outstanding == 0);
    endfunction

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf({"BAR: %0d read(s), %0d write(s) | DMA: %0d read TLP(s) / %0d B, ",
                       "%0d write TLP(s) / %0d B, %0d RC completion(s)"},
                      n_bar_reads, n_bar_writes, n_dma_rd_tlp, n_dma_rd_bytes,
                      n_dma_wr_tlp, n_dma_wr_bytes, n_rc_cpl), UVM_LOW)
        if (!is_idle())
            `uvm_error(get_type_name(),
                $sformatf("%0d DMA read(s) not fully completed at end of test",
                          m_reads_outstanding))
    endfunction

endclass : us_host

`endif // US_HOST_SV

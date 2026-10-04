// SPDX-License-Identifier: BSD-2-Clause-Views
//
// sb_dma_wr - Tier 3b scoreboard (PCIe DMA write engine)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §11, §10 (ref_dma), §15.2
// Introduced : Step 5 (Tier 3b)
//
// THE MIRROR OF sb_dma, AND THE DIRECTIONS ARE NOT SYMMETRIC.
//
// On the read side the DUT emits header-only requests and the data comes back
// later, so request checking and data checking are separate in time. On the
// write side the request CARRIES its payload, so a single TLP is both the
// request to check and the data to check - and the data it should carry is
// whatever the RAM held, which the testbench must know independently.
//
// Three checks, kept apart for the same reason as Tier 3a:
//
//   1. REQUEST SET      - the write TLPs match what ref_dma.split_write
//                         predicts: same addresses, same lengths.
//   2. REQUEST LEGALITY - no 4 KB crossing, within max_payload_size. Run
//                         unconditionally, even after check 1 has failed.
//   3. PAYLOAD INTEGRITY- the bytes in the TLP equal the bytes the RAM held at
//                         the corresponding address.
//
// THE RAM IMAGE IS THE REFERENCE HERE, not host memory. The testbench preloads
// the RAM responder and keeps a byte-addressed shadow of what it wrote; that
// shadow is what the payload is compared against. Reading it back out of the
// responder instead would compare the DUT against a memory the DUT itself could
// have disturbed.
// -----------------------------------------------------------------------------

`ifndef SB_DMA_WR_SV
`define SB_DMA_WR_SV

`uvm_analysis_imp_decl(_wr_desc)
`uvm_analysis_imp_decl(_wr_req)
`uvm_analysis_imp_decl(_wr_sts)

class sb_dma_wr extends mqnic_scoreboard_base;

    `uvm_component_utils(sb_dma_wr)

    uvm_analysis_imp_wr_desc #(dma_desc_pkg::dma_desc_item, sb_dma_wr) desc_imp;
    uvm_analysis_imp_wr_req  #(pcie_tlp_item,               sb_dma_wr) req_imp;
    uvm_analysis_imp_wr_sts  #(dma_desc_pkg::dma_desc_item, sb_dma_wr) sts_imp;

    ref_dma m_ref;

    // Shadow of what the testbench preloaded into the RAM responder, byte
    // addressed and linear. See the file header for why this rather than a
    // read-back.
    protected byte unsigned m_ram_image [int unsigned];

    // Expected write requests, in prediction order.
    protected ref_dma_req m_exp_req [$];

    // Immediate-mode descriptors carry their data in the descriptor itself
    // rather than reading RAM, keyed by the PCIe address the write targets.
    protected bit [31:0] m_imm      [bit [63:0]];
    protected int unsigned m_imm_len[bit [63:0]];

    bit check_payload = 1'b1;

    protected int unsigned m_n_desc;
    protected int unsigned m_n_sts;
    protected int unsigned m_n_req;

    cg_dma_wr cov;           // optional functional coverage
    protected int unsigned m_n_illegal;
    protected int unsigned m_n_bytes;
    protected int unsigned m_err_count [bit [3:0]];

    function new(string name, uvm_component parent);
        super.new(name, parent);
        desc_imp = new("desc_imp", this);
        req_imp  = new("req_imp", this);
        sts_imp  = new("sts_imp", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (m_ref == null) m_ref = ref_dma::type_id::create("m_ref");
    endfunction

    virtual function int unsigned pending_count();
        return m_exp_req.size();
    endfunction

    virtual function int unsigned outstanding_desc();
        return (m_n_desc > m_n_sts) ? (m_n_desc - m_n_sts) : 0;
    endfunction

    virtual function int unsigned status_count();
        return m_n_sts;
    endfunction

    virtual function int unsigned error_count(bit [3:0] code);
        return m_err_count.exists(code) ? m_err_count[code] : 0;
    endfunction

    // -------------------------------------------------------------------------
    // Called by the test alongside the RAM poke, so the two cannot drift.
    // -------------------------------------------------------------------------
    virtual function void preload(int unsigned lin_addr, byte unsigned d);
        m_ram_image[lin_addr] = d;
    endfunction

    // -------------------------------------------------------------------------
    virtual function void write_wr_desc(dma_desc_pkg::dma_desc_item t);
        ref_dma_req reqs [$];

        m_n_desc++;
        m_ref.split_write(t.pcie_addr, int'(t.ram_addr), int'(t.len), reqs);
        if (cov != null)
            cov.sample_descriptor(int'(t.len), t.pcie_addr, int'(t.ram_addr),
                                  reqs.size(), m_ref.max_payload_size, t.imm_en);
        foreach (reqs[i]) begin
            m_exp_req.push_back(reqs[i]);
            note_expected();
        end

        // An immediate descriptor writes the descriptor's own data, not RAM.
        // Recorded per target address so the payload check knows which source
        // to expect.
        if (t.imm_en) begin
            m_imm[t.pcie_addr]     = t.imm;
            m_imm_len[t.pcie_addr] = int'(t.len);
        end

        `uvm_info(get_type_name(),
            $sformatf("descriptor pcie=0x%0h ram=0x%0h len=%0d imm=%0b -> %0d request(s)",
                      t.pcie_addr, t.ram_addr, t.len, t.imm_en, reqs.size()), UVM_HIGH)
    endfunction

    // -------------------------------------------------------------------------
    virtual function void write_wr_req(pcie_tlp_item t);
        bit [63:0]   addr;
        int unsigned len;
        ref_dma_req  e;
        int          idx;

        note_actual();
        m_n_req++;

        addr = mqnic_vrf_pkg::tlp_hdr_req_byte_addr(t.hdr);
        len  = mqnic_vrf_pkg::tlp_hdr_req_byte_len(t.hdr);

        // ---- check 2: legality, unconditional -------------------------------
        if (m_ref.crosses_4k(addr, len)) begin
            m_n_illegal++;
            note_mismatch($sformatf("write request 0x%0h len %0d crosses a 4 KB boundary",
                                    addr, len),
                          "no 4 KB crossing", $sformatf("0x%0h..0x%0h", addr, addr+len-1));
        end
        if (m_ref.exceeds_mps(len)) begin
            m_n_illegal++;
            note_mismatch("write request longer than max_payload_size",
                          $sformatf("<= %0d bytes", m_ref.mps_bytes()),
                          $sformatf("%0d bytes", len));
        end

        // ---- check 1: membership of the predicted SET -----------------------
        // A set, not a sequence - see sb_dma.write_dma_req for why.
        if (m_exp_req.size() == 0) begin
            note_mismatch("write request with no descriptor outstanding",
                          "no request", $sformatf("addr=0x%0h len=%0d", addr, len));
            return;
        end

        idx = -1;
        foreach (m_exp_req[i])
            if (m_exp_req[i].addr === addr && m_exp_req[i].len == len) begin
                idx = i;
                break;
            end

        if (idx < 0) begin
            e = m_exp_req[0];
            note_mismatch($sformatf({"write request matches no outstanding ",
                                     "prediction (%0d pending; oldest shown)"},
                                    m_exp_req.size()),
                          e.convert2string(),
                          $sformatf("addr=0x%0h len=%0d", addr, len));
            return;
        end

        e = m_exp_req[idx];
        m_exp_req.delete(idx);

        // ---- check 3: does it carry the right bytes? ------------------------
        if (check_payload) check_bytes(t, e, addr, len);

        note_match($sformatf("write request 0x%0h len %0d", addr, len));
    endfunction

    // -------------------------------------------------------------------------
    // The TLP payload is transmitted in whole DWORDs, so the first
    // (addr & 3) bytes on the wire precede the data - the same padding the read
    // side deals with, in the other direction.
    // -------------------------------------------------------------------------
    protected virtual function void check_bytes(pcie_tlp_item t,
                                                ref_dma_req  e,
                                                bit [63:0]   addr,
                                                int unsigned len);
        int unsigned  pad = int'(addr[1:0]);
        byte unsigned exp;
        byte unsigned act;

        if (t.payload.size() < pad + len) begin
            note_mismatch($sformatf("write request 0x%0h payload too short", addr),
                          $sformatf(">= %0d bytes", pad + len),
                          $sformatf("%0d bytes", t.payload.size()));
            return;
        end

        // An IMMEDIATE descriptor's data comes from the descriptor, byte 0 =
        // imm[7:0]; it is one request (<= 4 bytes) at the descriptor's address.
        // These were recorded in m_imm but never checked - t3b_immediate had
        // to switch payload checking off, so immediate data went unverified.
        if (m_imm.exists(addr)) begin
            for (int i = 0; i < int'(len); i++) begin
                m_n_bytes++;
                exp = m_imm[addr][i*8 +: 8];
                act = t.payload[pad + i];
                if (exp !== act) begin
                    note_mismatch($sformatf("immediate write payload at PCIe 0x%0h byte %0d of %0d",
                                            addr + i, i, len),
                                  $sformatf("0x%02h", exp), $sformatf("0x%02h", act));
                    return;
                end
            end
            return;
        end

        for (int i = 0; i < int'(len); i++) begin
            m_n_bytes++;

            if (!m_ram_image.exists(e.ram_addr + i)) begin
                note_mismatch($sformatf({"write request 0x%0h reads RAM 0x%0h, which ",
                                         "was never preloaded"}, addr, e.ram_addr + i),
                              "preloaded byte", $sformatf("0x%02h", t.payload[pad + i]));
                return;
            end

            exp = m_ram_image[e.ram_addr + i];
            act = t.payload[pad + i];
            if (exp !== act) begin
                note_mismatch($sformatf({"write payload at PCIe 0x%0h (RAM 0x%0h, ",
                                         "byte %0d of %0d)"},
                                        addr + i, e.ram_addr + i, i, len),
                              $sformatf("0x%02h", exp), $sformatf("0x%02h", act));
                return;
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    virtual function void write_wr_sts(dma_desc_pkg::dma_desc_item t);
        mqnic_dma_error_e code;

        m_n_sts++;
        if (cov != null) cov.sample_status(t.error);
        if (m_err_count.exists(t.error)) m_err_count[t.error]++;
        else                             m_err_count[t.error] = 1;

        if (t.error != 0) begin
            code = mqnic_dma_error_e'(t.error);
            `uvm_info(get_type_name(),
                $sformatf("write status tag 0x%0h reports error %0d (%s)",
                          t.tag, t.error, code.name()), UVM_MEDIUM)
        end
    endfunction

    // -------------------------------------------------------------------------
    virtual function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        if (!m_enable_end_check) return;

        if (m_n_sts != m_n_desc)
            `uvm_error(get_type_name(),
                $sformatf({"%0d descriptor(s) accepted but %0d status(es) reported - ",
                           "%0d never completed"},
                          m_n_desc, m_n_sts, m_n_desc - m_n_sts))
    endfunction

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf({"descriptors=%0d status=%0d requests=%0d illegal=%0d ",
                       "payload_bytes=%0d unmatched=%0d"},
                      m_n_desc, m_n_sts, m_n_req, m_n_illegal, m_n_bytes,
                      m_exp_req.size()), UVM_LOW)
    endfunction

endclass : sb_dma_wr

`endif // SB_DMA_WR_SV

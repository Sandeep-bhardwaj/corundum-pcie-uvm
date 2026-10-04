// SPDX-License-Identifier: BSD-2-Clause-Views
//
// sb_dma - Tier 3 scoreboard (PCIe DMA engine)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §11 (sb_dma), §10 (ref_dma), §15.2
// Introduced : Step 5 (Tier 3)
//
// Three INDEPENDENT checks, deliberately kept apart so one cannot mask another:
//
//   1. REQUEST SET     - the TLPs the DUT emits match what ref_dma predicts for
//                        the descriptor: same addresses, same lengths, same
//                        order.
//   2. REQUEST LEGALITY- every emitted TLP obeys the §15.2 rules regardless of
//                        whether it matched: no 4 KB crossing, within MRRS,
//                        tag in range, tag unique while outstanding.
//   3. DATA INTEGRITY  - the bytes that end up in RAM equal the bytes that were
//                        in host memory at the source address.
//
// Check 2 runs even when check 1 already failed. A DUT that emits the wrong
// set of requests can still be emitting ILLEGAL ones, and finding out on the
// same run is worth more than a tidy single failure.
//
// ADDRESS MAPPING. The RAM side is segmented; a linear RAM byte address splits
// as (dma_if_pcie_rd's RAM_SEG_COUNT=2, RAM_SEG_BE_WIDTH=32):
//
//   byte_in_seg = addr % 32        segment = (addr / 32) % 2
//   seg_addr    = addr / 64
//
// Same shape as Tier 2's clients, one tier up and twice as wide. It is spelled
// out again here because getting it wrong produces data that is off by exactly
// one segment stride - which looks like a DMA bug and is not.
// -----------------------------------------------------------------------------

`ifndef SB_DMA_SV
`define SB_DMA_SV

`uvm_analysis_imp_decl(_dma_desc)
`uvm_analysis_imp_decl(_dma_req)
`uvm_analysis_imp_decl(_dma_ram)
`uvm_analysis_imp_decl(_dma_sts)
`uvm_analysis_imp_decl(_dma_cpl)

class sb_dma extends mqnic_scoreboard_base;

    `uvm_component_utils(sb_dma)

    uvm_analysis_imp_dma_desc #(dma_desc_pkg::dma_desc_item, sb_dma) desc_imp;
    uvm_analysis_imp_dma_req  #(pcie_tlp_item,               sb_dma) req_imp;
    uvm_analysis_imp_dma_ram  #(dma_ram_item,                sb_dma) ram_imp;
    uvm_analysis_imp_dma_sts  #(dma_desc_pkg::dma_desc_item, sb_dma) sts_imp;
    uvm_analysis_imp_dma_cpl  #(pcie_tlp_item,               sb_dma) cpl_imp;

    mqnic_host_mem_model mem;
    ref_dma              ref_model;

    // Optional. Sampled here rather than in the env because this is the only
    // place a descriptor and the number of requests it produced are both known.
    cg_dma               cov;

    // RAM geometry, for the linear <-> segmented mapping.
    int unsigned ram_seg_count    = 2;
    int unsigned ram_seg_be_width = 32;

    // ---- check enables -------------------------------------------------------
    // Each check is separately disableable because the error tests deliberately
    // create conditions under which one of them is meaningless. Disabling the
    // WHOLE scoreboard for those would throw away the checks that still apply -
    // which is exactly what makes error tests weak in practice.

    // A tag is retired when its last completion arrives. A test that DROPS
    // completions (t3_cpl_timeout) never retires them, so the DUT's legitimate
    // reuse after its own timeout would be reported as illegal.
    bit check_tag_reuse = 1'b1;

    // A poisoned completion carries data the DUT is entitled to discard, so
    // "these bytes must reach RAM" does not hold for t3_err_poison.
    bit check_ram_data  = 1'b1;

    // Expected read requests, in the order ref_dma predicts them.
    protected ref_dma_req m_exp_req [$];

    // What RAM should contain once the DMA lands, byte addressed.
    protected byte unsigned m_exp_ram [int unsigned];

    // Tags handed out by the DUT and not yet retired by a status.
    protected bit m_tag_busy [bit [7:0]];

    protected int unsigned m_n_desc;
    protected int unsigned m_n_sts;
    protected int unsigned m_n_req;
    protected int unsigned m_n_illegal;
    protected int unsigned m_n_ram_bytes;

    // Error codes seen on the status channel, so an error test can assert that
    // the DUT reported the RIGHT failure rather than merely some failure.
    protected int unsigned m_err_count [bit [3:0]];

    function new(string name, uvm_component parent);
        super.new(name, parent);
        desc_imp = new("desc_imp", this);
        req_imp  = new("req_imp", this);
        ram_imp  = new("ram_imp", this);
        sts_imp  = new("sts_imp", this);
        cpl_imp  = new("cpl_imp", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (ref_model == null) ref_model = ref_dma::type_id::create("ref_model");
    endfunction

    virtual function int unsigned pending_count();
        return m_exp_req.size();
    endfunction

    // Descriptors accepted by the DUT that have not yet produced a status.
    //
    // This is the drain condition Tier 3 tests wait on. It is stronger than
    // watching the bus go quiet: a DUT that silently drops a descriptor leaves
    // this non-zero forever and the wait reports it, whereas a bus-quiet check
    // would call that a clean finish.
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
    // A descriptor predicts BOTH the request set and the eventual RAM contents.
    // -------------------------------------------------------------------------
    virtual function void write_dma_desc(dma_desc_pkg::dma_desc_item t);
        ref_dma_req reqs [$];

        m_n_desc++;

        ref_model.split_read(t.pcie_addr, int'(t.ram_addr), int'(t.len), reqs);
        foreach (reqs[i]) begin
            m_exp_req.push_back(reqs[i]);
            note_expected();
        end

        // Every byte the DMA moves must end up in RAM unchanged.
        for (int i = 0; i < int'(t.len); i++)
            m_exp_ram[int'(t.ram_addr) + i] = mem.read_byte(t.pcie_addr + i);

        if (cov != null)
            cov.sample_descriptor(int'(t.len), t.pcie_addr, int'(t.ram_addr),
                                  reqs.size(),
                                  ref_model.crosses_4k(t.pcie_addr, int'(t.len)),
                                  ref_model.max_read_request_size,
                                  ref_model.rcb_128b,
                                  ref_model.ext_tag_enable);

        `uvm_info(get_type_name(),
            $sformatf("descriptor pcie=0x%0h ram=0x%0h len=%0d -> %0d request(s)",
                      t.pcie_addr, t.ram_addr, t.len, reqs.size()), UVM_HIGH)
    endfunction

    // -------------------------------------------------------------------------
    // Every emitted read request: legality first, then set membership.
    // -------------------------------------------------------------------------
    virtual function void write_dma_req(pcie_tlp_item t);
        bit [63:0]   addr;
        int unsigned len;
        bit [7:0]    tag;
        ref_dma_req  e;
        int          idx;

        note_actual();
        m_n_req++;

        // Decode through the shared helpers. Doing it by hand here is how the
        // first version of this scoreboard read the tag from [103:96] and the
        // address from the wrong slice - both plausible-looking and both wrong.
        //
        // BYTE-EXACT, from the byte enables. ref_dma predicts byte ranges; the
        // header holds a DWORD-aligned address and a DWORD count. Comparing
        // those two directly reports a mismatch on every descriptor whose
        // address or length is not a multiple of 4 - which is most of
        // t3_len_sweep and t3_alignment_sweep.
        addr = mqnic_vrf_pkg::tlp_hdr_req_byte_addr(t.hdr);
        len  = mqnic_vrf_pkg::tlp_hdr_req_byte_len(t.hdr);
        tag  = t.hdr_req_tag();

        // ---- check 2: legality, run unconditionally -------------------------
        // A zero-length request carries no data, so the 4 KB and MRRS rules
        // are vacuous for it - and crosses_4k(addr, 0) would read past the
        // end. Skip the size checks, keep the tag checks.
        if (len != 0 && ref_model.crosses_4k(addr, len)) begin
            m_n_illegal++;
            note_mismatch($sformatf("read request 0x%0h len %0d crosses a 4 KB boundary",
                                    addr, len),
                          "no 4 KB crossing", $sformatf("0x%0h..0x%0h", addr, addr+len-1));
        end
        if (len != 0 && ref_model.exceeds_mrrs(len)) begin
            m_n_illegal++;
            note_mismatch("read request longer than max_read_request_size",
                          $sformatf("<= %0d bytes", ref_model.mrrs_bytes()),
                          $sformatf("%0d bytes", len));
        end
        if (!ref_model.tag_in_range(int'(tag))) begin
            m_n_illegal++;
            note_mismatch("read request tag out of range for ext_tag_enable",
                          ref_model.ext_tag_enable ? "< 256" : "< 32",
                          $sformatf("%0d", tag));
        end
        if (check_tag_reuse && m_tag_busy.exists(tag)) begin
            m_n_illegal++;
            note_mismatch($sformatf("tag 0x%0h reissued while still outstanding", tag),
                          "unique tag", $sformatf("duplicate tag 0x%0h", tag));
        end
        m_tag_busy[tag] = 1'b1;

        // ---- check 1: does it match the predicted SET? ----------------------
        //
        // A SET, not a sequence. Several descriptors are in flight at once from
        // Tier 3 on, and the DUT is free to interleave their requests - it
        // issues whatever has a free tag. Popping the front and comparing
        // positionally would fail on legal interleaving, so this searches for
        // a match and removes it.
        //
        // Order WITHIN one descriptor is still checked, by the first-match rule
        // below: because the queue is in prediction order, taking the earliest
        // match means a descriptor's own requests must still arrive in order.
        if (m_exp_req.size() == 0) begin
            note_mismatch("read request with no descriptor outstanding",
                          "no request", $sformatf("addr=0x%0h len=%0d", addr, len));
            return;
        end

        idx = -1;
        foreach (m_exp_req[i]) begin
            if (m_exp_req[i].addr === addr && m_exp_req[i].len == len) begin
                idx = i;
                break;
            end
        end

        if (idx < 0) begin
            e = m_exp_req[0];
            note_mismatch($sformatf({"read request matches no outstanding ",
                                     "prediction (%0d pending; oldest shown)"},
                                    m_exp_req.size()),
                          e.convert2string(),
                          $sformatf("addr=0x%0h len=%0d", addr, len));
            return;
        end

        m_exp_req.delete(idx);
        note_match($sformatf("read request 0x%0h len %0d", addr, len));
    endfunction

    // -------------------------------------------------------------------------
    // Check 3: data landing in RAM.
    // -------------------------------------------------------------------------
    virtual function void write_dma_ram(dma_ram_item t);
        int unsigned  lin_base;
        byte unsigned exp;
        byte unsigned act;

        note_actual();
        if (!check_ram_data) return;

        lin_base = (int'(t.addr) * ram_seg_count + int'(t.seg)) * ram_seg_be_width;

        for (int b = 0; b < int'(ram_seg_be_width); b++) begin
            if (!t.be[b]) continue;
            m_n_ram_bytes++;

            if (!m_exp_ram.exists(lin_base + b)) begin
                note_mismatch($sformatf({"RAM write to 0x%0h, which no descriptor ",
                                         "covers"}, lin_base + b),
                              "no write here", $sformatf("0x%02h", t.data[b*8 +: 8]));
                return;
            end

            exp = m_exp_ram[lin_base + b];
            act = t.data[b*8 +: 8];
            if (exp !== act) begin
                note_mismatch($sformatf({"DMA data at RAM 0x%0h (seg %0d seg_addr ",
                                         "0x%0h byte %0d)"},
                                        lin_base + b, t.seg, t.addr, b),
                              $sformatf("0x%02h", exp), $sformatf("0x%02h", act));
                return;
            end
        end
        note_match($sformatf("RAM write seg %0d addr 0x%0h", t.seg, t.addr));
    endfunction

    // -------------------------------------------------------------------------
    // A completion retires a PCIe tag once it is the LAST one for that request.
    //
    // "Last" is not a header field - it is derived: byte_count counts to the end
    // of the original request, so a completion whose byte_count equals its own
    // payload length is the final one. That is the same rule the DUT applies
    // (dma_if_pcie_rd.v:988), and using it here is what makes the duplicate-tag
    // check above mean anything.
    //
    // The alternative the first version used - clearing every tag on a
    // descriptor status - is wrong the moment two descriptors overlap, which is
    // most of this tier. It would have silently disabled the check.
    //
    // These completions are TB-generated, so nothing here checks them; this
    // subscriber exists purely to know when a tag is free again.
    // -------------------------------------------------------------------------
    virtual function void write_dma_cpl(pcie_tlp_item t);
        bit [7:0]    tag = mqnic_vrf_pkg::tlp_hdr_cpl_tag(t.hdr);
        int unsigned bc  = mqnic_vrf_pkg::tlp_hdr_cpl_byte_count(t.hdr);
        bit [2:0]    st  = mqnic_vrf_pkg::tlp_hdr_cpl_status(t.hdr);
        int unsigned pad = int'(mqnic_vrf_pkg::tlp_hdr_cpl_lower_addr(t.hdr) & 7'h3);
        bit          last;

        // "More completions follow" is exactly the DUT's own test
        // (dma_if_pcie_rd.v:1010): byte_count > (length_dw*4) - lower_addr[1:0].
        // Using the same rule here means the two cannot disagree about when a
        // tag becomes free - the alternative, bc <= payload.size(), is off by
        // the leading pad and retires some tags a completion early.
        last = !(bc > (t.payload.size() - pad));

        // A non-success status terminates the request outright, whatever the
        // byte count says.
        if (st != 3'(CPL_STATUS_SC) || last)
            if (m_tag_busy.exists(tag)) m_tag_busy.delete(tag);
    endfunction

    // -------------------------------------------------------------------------
    virtual function void write_dma_sts(dma_desc_pkg::dma_desc_item t);
        // Held in a variable rather than written as mqnic_dma_error_e'(t.error)
        // .name() inline: VCS rejects a method call applied directly to a cast
        // expression (SE, token is '.'). slang accepts it, so this is one more
        // construct that only a real compiler catches.
        mqnic_dma_error_e code;

        m_n_sts++;

        if (m_err_count.exists(t.error)) m_err_count[t.error]++;
        else                             m_err_count[t.error] = 1;

        if (cov != null) cov.sample_status(t.error);

        if (t.error != 0) begin
            code = mqnic_dma_error_e'(t.error);
            `uvm_info(get_type_name(),
                $sformatf("descriptor status tag 0x%0h reports error %0d (%s)",
                          t.tag, t.error, code.name()), UVM_MEDIUM)
        end
    endfunction

    // -------------------------------------------------------------------------
    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf({"descriptors=%0d status=%0d requests=%0d illegal=%0d ",
                       "ram_bytes=%0d unmatched requests=%0d"},
                      m_n_desc, m_n_sts, m_n_req, m_n_illegal, m_n_ram_bytes,
                      m_exp_req.size()), UVM_LOW)
    endfunction

    // -------------------------------------------------------------------------
    virtual function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        if (!m_enable_end_check) return;

        // The base class already reports unmatched expected requests. This adds
        // the one thing it cannot know: a descriptor the DUT accepted and then
        // never answered for.
        if (m_n_sts != m_n_desc)
            `uvm_error(get_type_name(),
                $sformatf({"%0d descriptor(s) accepted but %0d status(es) reported - ",
                           "%0d never completed"},
                          m_n_desc, m_n_sts, m_n_desc - m_n_sts))
    endfunction

endclass : sb_dma

`endif // SB_DMA_SV

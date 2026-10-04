// SPDX-License-Identifier: BSD-2-Clause-Views
//
// mqnic_csr_seq / mqnic_rb_walker - host register access over PCIe
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §8.2 (block discovery), §12.2 (driver model)
// Introduced : Step 7 (Tier 5)
//
// THERE IS NO AXI-LITE SLAVE ON mqnic_core_pcie. That is the fact that shapes
// this whole layer. The host does not write registers over a bus the testbench
// can drive directly - it issues PCIe MEMORY REQUESTS TO A BAR
// (pcie_rx_req_tlp_*) and the answers come back as COMPLETIONS
// (pcie_tx_cpl_tlp_*). `m_axil_csr_*` is an OUTPUT: the core's own master
// towards application logic, not a way in.
//
// So a register read is a SPLIT TRANSACTION, and this layer is what makes it
// look like a function call:
//
//     read32(addr)  ->  build a read request TLP, tag it, send it, wait for the
//                       completion CARRYING THAT TAG, extract the DWORD
//
// TAG MATCHING IS NOT OPTIONAL. Completions may return out of order, so pairing
// them positionally would silently return another register's value. This is the
// same rule the DMA engine relies on at Tier 3, applied in the opposite
// direction: there the DUT was the requester, here the testbench is.
//
// The transport is the pcie_tlp UVC built at Tier 1b on stateless routing
// blocks. Nothing about it changed to serve this - which is the §5.1 argument
// reaching its furthest point in the project.
// -----------------------------------------------------------------------------

`ifndef MQNIC_CSR_SEQ_SV
`define MQNIC_CSR_SEQ_SV

// -----------------------------------------------------------------------------
// Shared state between the requester sequence and the completion collector.
//
// A sequence cannot see the analysis port, so the test wires this object to
// both: the sequence parks a tag in it, the collector fills in the data.
// -----------------------------------------------------------------------------
class mqnic_csr_ctx extends uvm_object;

    `uvm_object_utils(mqnic_csr_ctx)

    bit [15:0] requester_id = 16'h0100;
    bit [2:0]  bar_id       = 3'd0;

    // Completions indexed by tag. An associative array rather than a queue
    // because out-of-order return is legal and expected.
    bit [31:0] m_data [bit [7:0]];
    bit        m_done [bit [7:0]];

    protected bit [7:0] m_next_tag;

    function new(string name = "mqnic_csr_ctx");
        super.new(name);
    endfunction

    virtual function bit [7:0] alloc_tag();
        bit [7:0] t = m_next_tag;
        m_next_tag = m_next_tag + 1;
        m_done.delete(t);
        m_data.delete(t);
        return t;
    endfunction

    // Called by the collector when a completion arrives.
    virtual function void deliver(bit [7:0] tag, bit [31:0] data);
        m_data[tag] = data;
        m_done[tag] = 1'b1;
    endfunction

    virtual function bit have(bit [7:0] tag);
        return m_done.exists(tag) && m_done[tag];
    endfunction

    virtual function bit [31:0] take(bit [7:0] tag);
        bit [31:0] d = m_data.exists(tag) ? m_data[tag] : 32'hDEAD_BEEF;
        m_data.delete(tag);
        m_done.delete(tag);
        return d;
    endfunction

endclass : mqnic_csr_ctx


// -----------------------------------------------------------------------------
// One 32-bit register read, as a blocking call.
// -----------------------------------------------------------------------------
class mqnic_csr_read_seq extends mqnic_base_seq #(pcie_tlp_item);

    `uvm_object_utils(mqnic_csr_read_seq)

    bit [63:0]     addr;
    mqnic_csr_ctx  ctx;

    // Filled in on completion.
    bit [31:0]     data;
    bit            timed_out;

    // Long enough for a completion to cross the core, short enough that a lost
    // one reports here rather than at the global watchdog with no context.
    int unsigned   timeout_cycles = 20000;

    function new(string name = "mqnic_csr_read_seq");
        super.new(name);
    endfunction

    virtual task body();
        pcie_tlp_item it;
        bit [7:0]     tag;
        int unsigned  waited;

        if (ctx == null)
            `uvm_fatal(get_type_name(), "ctx not set - the collector shares it")

        tag = ctx.alloc_tag();

        it        = pcie_tlp_item::type_id::create("csr_rd");
        it.hdr    = mqnic_vrf_pkg::tlp_hdr_read_req(addr, 1, tag,
                                                    ctx.requester_id);
        it.bar_id = ctx.bar_id;
        it.payload = new[0];
        it.delay   = 0;

        start_item(it);
        finish_item(it);

        // Wait for the completion CARRYING THIS TAG. Positional pairing would
        // return another register's value whenever two reads overlap.
        waited = 0;
        while (!ctx.have(tag) && waited < timeout_cycles) begin
            #10ns;
            waited++;
        end

        if (!ctx.have(tag)) begin
            timed_out = 1'b1;
            `uvm_error(get_type_name(),
                $sformatf({"register read at 0x%0h (tag 0x%0h) got no completion ",
                           "within %0d polls"}, addr, tag, timeout_cycles))
        end
        else begin
            data = ctx.take(tag);
        end
    endtask

endclass : mqnic_csr_read_seq


// -----------------------------------------------------------------------------
// One 32-bit register write. POSTED - there is no completion to wait for, and
// waiting for one would hang.
// -----------------------------------------------------------------------------
class mqnic_csr_write_seq extends mqnic_base_seq #(pcie_tlp_item);

    `uvm_object_utils(mqnic_csr_write_seq)

    bit [63:0]    addr;
    bit [31:0]    data;
    mqnic_csr_ctx ctx;

    function new(string name = "mqnic_csr_write_seq");
        super.new(name);
    endfunction

    virtual task body();
        pcie_tlp_item it;
        bit [127:0]   h;

        if (ctx == null)
            `uvm_fatal(get_type_name(), "ctx not set")

        // Format and address placement follow the SAME rule as
        // mqnic_vrf_pkg::tlp_hdr_read_req (:455-470): 3DW below 4 GiB, 4DW
        // above, and a 3DW request carries addr[31:2] at [63:34] rather than
        // [63:2]. Hardcoding the 4DW form worked only because nothing checked.
        h            = '0;
        h[124:120]   = mqnic_vrf_pkg::TLP_TYPE_MEM;
        h[105:96]    = 10'd1;                 // one DWORD
        h[95:80]     = ctx.requester_id;
        // PCIe requires LAST BE == 0 on a single-DWORD transfer. This said
        // 8'hFF, i.e. last_be = 4'hF with length 1 - malformed, and free to be
        // rejected or mis-lengthed by a compliant receiver.
        h[71:68]     = 4'b0000;               // last BE  - none, length is 1
        h[67:64]     = 4'b1111;               // first BE - all four bytes

        if ((addr[63:2] >> 30) != 0) begin
            h[127:125] = mqnic_vrf_pkg::TLP_FMT_4DW_DATA;
            h[63:2]    = addr[63:2];
        end
        else begin
            h[127:125] = mqnic_vrf_pkg::TLP_FMT_3DW_DATA;
            h[63:34]   = addr[31:2];
        end

        it         = pcie_tlp_item::type_id::create("csr_wr");
        it.hdr     = h;
        it.bar_id  = ctx.bar_id;
        it.payload = new[4];
        for (int b = 0; b < 4; b++) it.payload[b] = data[b*8 +: 8];
        it.delay   = 0;

        start_item(it);
        finish_item(it);
    endtask

endclass : mqnic_csr_write_seq


// -----------------------------------------------------------------------------
// mqnic_rb_walker - discovers the register-block list (§8.2).
//
// THE FIRST THING TIER 5 SHOULD DO. Every other register test needs a base
// address, and a hardcoded one is a guess about how the DUT was parameterised.
// Walking the list is how the Linux driver finds its registers, so a testbench
// that walks it is exercising the same path the real software does.
//
// The walk itself is the check: a block whose version does not match the header,
// a next_ptr that does not advance, or a type the RAL has never heard of are all
// reported. §8.2 asks for the discovered set to be compared against the DUT's
// configured parameters, which the test does on top of this.
// -----------------------------------------------------------------------------
class mqnic_rb_walker extends uvm_object;

    `uvm_object_utils(mqnic_rb_walker)

    // One discovered block.
    typedef struct {
        bit [63:0] base;
        bit [31:0] rb_type;
        bit [31:0] version;
        bit [63:0] next_ptr;
    } rb_entry_t;

    rb_entry_t    blocks [$];
    mqnic_csr_ctx ctx;

    // A malformed list can loop forever; this bounds it and reports rather
    // than hanging until the global watchdog.
    int unsigned max_blocks = 64;

    function new(string name = "mqnic_rb_walker");
        super.new(name);
    endfunction

    virtual task walk(uvm_sequencer_base seqr, bit [63:0] first_base);
        mqnic_csr_read_seq rd;
        rb_entry_t         e;
        bit [63:0]         cur = first_base;
        bit [63:0]         seen [bit [63:0]];
        bit                first = 1'b1;

        blocks.delete();

        // `first` because the list HEAD is normally at offset 0 - the FW ID block
        // sits at BAR offset 0 - so 0 cannot also mean "end of list" until a
        // block's next pointer says it. `while (cur != 0)` read nothing at all.
        while ((first || cur != 0) && blocks.size() < max_blocks) begin
            first = 1'b0;
            // A repeated base means the list loops. Detect it here rather than
            // spinning to max_blocks and reporting a length that means nothing.
            if (seen.exists(cur)) begin
                `uvm_error(get_type_name(),
                    $sformatf("register block list loops back to 0x%0h", cur))
                return;
            end
            seen[cur] = cur;

            e.base = cur;

            rd = mqnic_csr_read_seq::type_id::create("rb_type");
            rd.ctx  = ctx;
            rd.addr = cur + mqnic_ral_pkg::RB_REG_TYPE;
            rd.start(seqr);
            if (rd.timed_out) return;
            e.rb_type = rd.data;

            rd = mqnic_csr_read_seq::type_id::create("rb_ver");
            rd.ctx  = ctx;
            rd.addr = cur + mqnic_ral_pkg::RB_REG_VER;
            rd.start(seqr);
            if (rd.timed_out) return;
            e.version = rd.data;

            rd = mqnic_csr_read_seq::type_id::create("rb_next");
            rd.ctx  = ctx;
            rd.addr = cur + mqnic_ral_pkg::RB_REG_NEXT_PTR;
            rd.start(seqr);
            if (rd.timed_out) return;
            e.next_ptr = 64'(rd.data);

            blocks.push_back(e);

            `uvm_info(get_type_name(),
                $sformatf("block %0d @ 0x%0h: type 0x%08h (%s) ver 0x%08h next 0x%0h",
                          blocks.size()-1, e.base, e.rb_type,
                          mqnic_ral_pkg::rb_type_name(e.rb_type),
                          e.version, e.next_ptr), UVM_LOW)

            cur = e.next_ptr;
        end

        if (blocks.size() >= max_blocks)
            `uvm_error(get_type_name(),
                $sformatf("register block list did not terminate within %0d blocks",
                          max_blocks));
    endtask

    // -------------------------------------------------------------------------
    // Checks that do not need to know the DUT's parameters.
    // -------------------------------------------------------------------------
    virtual function void check_types_known();
        foreach (blocks[i]) begin
            // A disabled block stays in the list reading type 0, version 0:
            // mqnic_core.v:800-801 (App info, APP_ENABLE ? 0xC005 : 0). Type 0
            // with a non-zero version is still reported.
            if (blocks[i].rb_type == 0 && blocks[i].version == 0) continue;
            if (!mqnic_ral_pkg::rb_type_known(blocks[i].rb_type))
                `uvm_error(get_type_name(),
                    $sformatf({"block %0d @ 0x%0h has type 0x%08h, which is not in ",
                               "mqnic_hw.h - either the RAL is stale or the DUT ",
                               "returned garbage"},
                              i, blocks[i].base, blocks[i].rb_type))
        end
    endfunction

    virtual function void check_versions();
        bit [31:0] exp;
        foreach (blocks[i]) begin
            if (!mqnic_ral_pkg::rb_type_known(blocks[i].rb_type)) continue;
            exp = mqnic_ral_pkg::rb_expected_version(
                      mqnic_ral_pkg::mqnic_rb_type_e'(blocks[i].rb_type));
            // Zero means the header declares no version for that block, so
            // there is nothing to compare against - not a mismatch.
            if (exp != 0 && blocks[i].version != exp)
                `uvm_error(get_type_name(),
                    $sformatf({"block %s @ 0x%0h reports version 0x%08h, ",
                               "mqnic_hw.h says 0x%08h"},
                              mqnic_ral_pkg::rb_type_name(blocks[i].rb_type),
                              blocks[i].base, blocks[i].version, exp))
        end
    endfunction

    virtual function bit has_type(bit [31:0] t);
        foreach (blocks[i]) if (blocks[i].rb_type == t) return 1'b1;
        return 1'b0;
    endfunction

    virtual function bit [63:0] base_of(bit [31:0] t);
        foreach (blocks[i]) if (blocks[i].rb_type == t) return blocks[i].base;
        return 64'h0;
    endfunction

    virtual function int unsigned count_of(bit [31:0] t);
        int unsigned n = 0;
        foreach (blocks[i]) if (blocks[i].rb_type == t) n++;
        return n;
    endfunction

endclass : mqnic_rb_walker

`endif // MQNIC_CSR_SEQ_SV

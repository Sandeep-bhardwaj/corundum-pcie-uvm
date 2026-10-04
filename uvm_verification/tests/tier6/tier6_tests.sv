// SPDX-License-Identifier: BSD-2-Clause-Views
//
// Tier 6 test suite - mqnic_core_pcie_us, the strategy's TOP DUT
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §3.1, §5 Tier 6, §8.2, §19
//
// THE SEAM. Both halves of this DUT already pass in isolation. What only exists
// here is the joint between them: at Tier 5 a register read was driven straight
// onto the generic TLP interface, and here the same read must arrive as a
// XILINX CQ DESCRIPTOR, cross the entire core, and return as a CC descriptor.
//
// Two independently correct halves can still disagree - about byte enables,
// about straddling, about where a tag lives - and neither half's own testbench
// can see that. These tests are the first thing in the project that can.
//
// The CHECKS are Tier 5's, unchanged. Only the transport underneath differs, so
// a failure here is a statement about the joint and nothing else.
// -----------------------------------------------------------------------------

`ifndef TIER6_TESTS_SV
`define TIER6_TESTS_SV

class tier6_base_test extends mqnic_base_test;

    `uvm_component_utils(tier6_base_test)

    tier6_env                     m_env;
    virtual pcie_us_cfg_status_if m_cfg_vif;

    // Completions collected off the CC stream, keyed by tag. Keyed, never
    // positional: pairing by arrival order returns another register's value the
    // moment two reads overlap.
    protected bit [31:0] m_cpl_data [bit [7:0]];
    protected bit        m_cpl_seen [bit [7:0]];
    protected bit [7:0]  m_next_tag;

    function new(string name = "tier6_base_test", uvm_component parent = null);
        super.new(name, parent);
        m_x_safe_reset = 1'b1;   // AXI-Lite tree - see mqnic_reset_if.pulse_reset_x_safe()
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        m_env = tier6_env::type_id::create("m_env", this);
        if (!uvm_config_db #(virtual pcie_us_cfg_status_if)::get(
                this, "", "cfg_status_vif", m_cfg_vif))
            `uvm_fatal(get_type_name(), "cfg_status_vif not set")
    endfunction

    protected task idle(int n);
        repeat (n) @(posedge m_rst_vif.clk);
    endtask

    // -------------------------------------------------------------------------
    // One BAR register read, all the way through the Xilinx shim.
    //
    // Out : a memory-read request, encoded as a CQ descriptor by ref_tlp_shim.
    // Back: a CC descriptor plus one payload DWORD.
    //
    // Nothing in this file knows a descriptor bit position - the same rule the
    // Tier 4 suites follow, and the reason bug 12 and bug 33 cannot recur here.
    // -------------------------------------------------------------------------
    protected task csr_read(input bit [63:0] addr,
                            output bit [31:0] data,
                            output bit ok);
        pcie_us_axis_pkg::pcie_us_axis_single_seq s;
        bit [127:0] hdr, desc;
        bit [31:0]  dw [];
        bit [7:0]   tag;
        int         waited;

        tag = m_next_tag;
        m_next_tag = m_next_tag + 1;
        m_cpl_seen.delete(tag);

        hdr  = mqnic_vrf_pkg::tlp_hdr_read_req(.addr(addr), .dw_len(1),
                                               .tag(tag), .requester_id(16'h0100));
        desc = m_env.m_shim.cq_encode(hdr);

        dw = new[4];
        for (int i = 0; i < 4; i++) dw[i] = desc[i*32 +: 32];

        s = pcie_us_axis_pkg::pcie_us_axis_single_seq::type_id::create("cq");
        s.dwords = new[dw.size()];
        foreach (dw[i]) s.dwords[i] = dw[i];
        if (!s.randomize() with { delay inside {[0:2]}; })
            `uvm_fatal(get_type_name(), "randomize failed")
        s.start(m_env.m_cq_axis.sequencer);

        waited = 0;
        while (!m_cpl_seen.exists(tag) && waited < 20000) begin
            @(posedge m_rst_vif.clk);
            waited++;
        end

        ok   = m_cpl_seen.exists(tag);
        data = ok ? m_cpl_data[tag] : 32'hDEAD_BEEF;
        if (!ok)
            `uvm_error(get_type_name(),
                $sformatf({"no completion for the read at 0x%0h (tag 0x%0h) - ",
                           "the BAR path through the Xilinx shim is not ",
                           "responding"}, addr, tag))
    endtask

    // Collect completions off the CC stream into the tag-keyed table.
    protected task run_cc_collector();
        pcie_us_axis_pkg::pcie_us_axis_item it;
        bit [95:0] desc;
        bit [7:0]  tag;
        forever begin
            m_env.m_cc_fifo.get(it);
            if (it.dwords.size() < 3) continue;   // not even a descriptor
            for (int i = 0; i < 3; i++) desc[i*32 +: 32] = it.dwords[i];
            tag = desc[71:64];                     // ref_tlp_shim.sv:68
            // A status-only completion (e.g. UR) carries no data; deliver the
            // same marker Tier 5's collector uses rather than dropping it.
            m_cpl_data[tag] = (it.dwords.size() >= 4) ? it.dwords[3] : 32'hBAD0_C0DE;
            m_cpl_seen[tag] = 1'b1;
        end
    endtask

    // Send any generic TLP header (plus payload DWORDs) as a CQ request.
    protected task send_cq(bit [127:0] hdr, bit [31:0] payload [$] = {});
        pcie_us_axis_pkg::pcie_us_axis_single_seq s;
        bit [127:0] desc = m_env.m_shim.cq_encode(hdr);
        s = pcie_us_axis_pkg::pcie_us_axis_single_seq::type_id::create("cq");
        s.dwords = new[4 + payload.size()];
        for (int i = 0; i < 4; i++) s.dwords[i] = desc[i*32 +: 32];
        foreach (payload[i]) s.dwords[4 + i] = payload[i];
        if (!s.randomize() with { delay inside {[0:2]}; })
            `uvm_fatal(get_type_name(), "randomize failed")
        s.start(m_env.m_cq_axis.sequencer);
    endtask

    // One posted 32-bit register write (3DW memory write).
    protected task csr_write(bit [63:0] addr, bit [31:0] data);
        bit [127:0] h = '0;
        h[127:125] = mqnic_vrf_pkg::TLP_FMT_3DW_DATA;
        h[124:120] = mqnic_vrf_pkg::TLP_TYPE_MEM;
        h[105:96]  = 10'd1;
        h[95:80]   = 16'h0100;
        h[67:64]   = 4'b1111;
        h[63:34]   = addr[31:2];
        send_cq(h, '{data});
    endtask

endclass : tier6_base_test


// -----------------------------------------------------------------------------
// t6_reset - the whole stack comes up idle.
// -----------------------------------------------------------------------------
class t6_reset extends tier6_base_test;

    `uvm_component_utils(t6_reset)

    function new(string name = "t6_reset", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t6_reset");
        apply_power_on_reset();
        idle(200);
        m_rst_vif.inject_reset(8);
        idle(200);
        phase.drop_objection(this, "t6_reset");
    endtask

endclass : t6_reset


// -----------------------------------------------------------------------------
// t6_rb_walk - THE TIER 6 TEST.
//
// The Linux driver's first act, performed end to end over the Xilinx transport.
// -----------------------------------------------------------------------------
class t6_rb_walk extends tier6_base_test;

    `uvm_component_utils(t6_rb_walk)

    function new(string name = "t6_rb_walk", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [63:0] cur = 64'd0;
        bit [31:0] rb_type, ver, nxt;
        bit        ok;
        int        n_blocks = 0;
        bit        saw_fw_id = 1'b0;
        int        n_fw_id = 0;
        bit        terminated = 1'b0;
        bit        visited [bit [63:0]];

        phase.raise_objection(this, "t6_rb_walk");
        fork run_cc_collector(); join_none

        apply_power_on_reset();
        idle(400);                       // let pcie_us_cfg finish polling

        while (n_blocks < 64) begin
            csr_read(cur + mqnic_ral_pkg::RB_REG_TYPE, rb_type, ok);
            if (!ok) break;
            csr_read(cur + mqnic_ral_pkg::RB_REG_VER, ver, ok);
            if (!ok) break;
            csr_read(cur + mqnic_ral_pkg::RB_REG_NEXT_PTR, nxt, ok);
            if (!ok) break;

            `uvm_info(get_type_name(),
                $sformatf("block %0d @ 0x%0h: type 0x%08h (%s) ver 0x%08h next 0x%0h",
                          n_blocks, cur, rb_type,
                          mqnic_ral_pkg::rb_type_name(rb_type), ver, nxt), UVM_LOW)

            // Shape checks. Without them a transport that returns all-ones for
            // every read "walks" 64 FW ID blocks and passes - it did (bug 38).
            if (visited.exists(cur)) begin
                `uvm_error(get_type_name(),
                    $sformatf("register block list revisits 0x%0h - it is a loop", cur))
                break;
            end
            visited[cur] = 1'b1;
            if (rb_type == 32'hFFFFFFFF) begin
                saw_fw_id = 1'b1;
                n_fw_id++;
                if (cur != 0)
                    `uvm_error(get_type_name(),
                        $sformatf("FW ID block at 0x%0h - the driver expects it at 0x0", cur))
            end

            // Type 0 is legal: mqnic_core.v:800 reads APP_ENABLE ? ... : 0, so
            // a disabled block sits in the list with a zero type.
            if (rb_type != 0) begin
                if (!mqnic_ral_pkg::rb_type_known(rb_type))
                    `uvm_error(get_type_name(),
                        $sformatf({"block at 0x%0h has type 0x%08h, which is not ",
                                   "in mqnic_hw.h"}, cur, rb_type))
                else begin
                    bit [31:0] exp = mqnic_ral_pkg::rb_expected_version(
                        mqnic_ral_pkg::mqnic_rb_type_e'(rb_type));
                    if (exp != 0 && ver != exp)
                        `uvm_error(get_type_name(),
                            $sformatf({"%s at 0x%0h reports version 0x%08h, ",
                                       "mqnic_hw.h says 0x%08h"},
                                      mqnic_ral_pkg::rb_type_name(rb_type),
                                      cur, ver, exp))
                end
            end

            n_blocks++;
            if (nxt == 0) begin
                terminated = 1'b1;
                break;
            end
            cur = 64'(nxt);
        end

        if (n_blocks > 0 && !terminated)
            `uvm_error(get_type_name(),
                $sformatf("walk stopped after %0d block(s) without reaching a next pointer of 0",
                          n_blocks))
        if (n_fw_id > 1)
            `uvm_error(get_type_name(),
                $sformatf("%0d FW ID blocks in the list - there must be exactly one", n_fw_id))
        if (n_blocks == 0)
            `uvm_error(get_type_name(),
                "no register block was read - this run checked nothing")
        if (!saw_fw_id)
            `uvm_error(get_type_name(),
                "no FW ID block in the list - the driver anchors on it")

        `uvm_info(get_type_name(),
            $sformatf("%0d block(s) discovered through the Xilinx transport",
                      n_blocks), UVM_LOW)

        idle(100);
        phase.drop_objection(this, "t6_rb_walk");
    endtask

endclass : t6_rb_walk


// -----------------------------------------------------------------------------
// t6_seam - the map read over the Xilinx transport must match the RTL.
//
// THE CHECK THAT ONLY EXISTS AT THIS TIER. Tier 5 walked this list over the
// generic TLP interface. Any disagreement between the two halves shows up as a
// DIFFERENT MAP, and neither half's own testbench can see it.
//
// The expected map is written out from mqnic_core.v:776-812 rather than read
// from the DUT a second time. Reading it twice would compare the transport with
// itself, which is precisely what this test exists not to do.
// -----------------------------------------------------------------------------
class t6_seam extends tier6_base_test;

    `uvm_component_utils(t6_seam)

    function new(string name = "t6_seam", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [31:0] exp_base [7] = '{32'h000, 32'h040, 32'h050, 32'h070,
                                    32'h080, 32'h100, 32'h200};
        bit [31:0] exp_type [7] = '{32'hFFFFFFFF, 32'h0000C007, 32'h0000C000,
                                    32'h00000000, 32'h0000C006, 32'h0000C080,
                                    32'h0000C008};
        bit [31:0] exp_next [7] = '{32'h040, 32'h050, 32'h070, 32'h080,
                                    32'h100, 32'h200, 32'h000};
        bit [31:0] rb_type, ver, nxt;
        bit        ok;

        phase.raise_objection(this, "t6_seam");
        fork run_cc_collector(); join_none

        apply_power_on_reset();
        idle(400);

        foreach (exp_base[i]) begin
            csr_read(64'(exp_base[i]) + mqnic_ral_pkg::RB_REG_TYPE, rb_type, ok);
            if (!ok) begin
                `uvm_error(get_type_name(),
                    $sformatf("block %0d @ 0x%0h did not respond", i, exp_base[i]))
                break;
            end
            csr_read(64'(exp_base[i]) + mqnic_ral_pkg::RB_REG_NEXT_PTR, nxt, ok);

            if (rb_type !== exp_type[i])
                `uvm_error(get_type_name(),
                    $sformatf({"block %0d @ 0x%0h: the XILINX transport reports ",
                               "type 0x%08h, mqnic_core.v defines 0x%08h - the ",
                               "two halves disagree"},
                              i, exp_base[i], rb_type, exp_type[i]))
            if (nxt !== exp_next[i])
                `uvm_error(get_type_name(),
                    $sformatf({"block %0d @ 0x%0h: next pointer 0x%0h over the ",
                               "Xilinx transport, 0x%0h in mqnic_core.v"},
                              i, exp_base[i], nxt, exp_next[i]))
        end

        `uvm_info(get_type_name(),
            "register map identical through the Xilinx transport and in mqnic_core.v",
            UVM_LOW)

        idle(100);
        phase.drop_objection(this, "t6_seam");
    endtask

endclass : t6_seam


// -----------------------------------------------------------------------------
// t6_cfg_sources - where MPS, MRRS and ext_tag actually come from here.
//
// NOT the Tier 4d test repeated. Reading mqnic_core_pcie_us.v shows the wiring
// is not what Tier 4d would lead you to expect:
//
//   :861-862   pcie_us_if .max_payload_size()  DISCARDED
//   :1159-60   the core takes cfg_max_payload / cfg_max_read_req instead
//   :283-284   which are INPUT PINS
//
// So the values pcie_us_cfg polls out of config space are THROWN AWAY at this
// level for two of its three outputs; only ext_tag_enable survives. A test that
// assumed otherwise would pass for the wrong reason.
// -----------------------------------------------------------------------------
class t6_cfg_sources extends tier6_base_test;

    `uvm_component_utils(t6_cfg_sources)

    function new(string name = "t6_cfg_sources", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [2:0] mps_v  [4] = '{3'd2, 3'd0, 3'd5, 3'd7};
        bit [2:0] mrrs_v [4] = '{3'd5, 3'd0, 3'd2, 3'd7};

        phase.raise_objection(this, "t6_cfg_sources");
        apply_power_on_reset();
        idle(200);

        // MPS and MRRS are driven straight into the DUT on pins here, so this
        // checks the PIN PATH rather than the polling path.
        foreach (mps_v[i]) begin
            m_cfg_vif.max_payload_size      = mps_v[i];
            m_cfg_vif.max_read_request_size = mrrs_v[i];
            idle(40);
            `uvm_info(get_type_name(),
                $sformatf("cfg_max_payload=%0d cfg_max_read_req=%0d driven",
                          mps_v[i], mrrs_v[i]), UVM_MEDIUM)
        end

        // ext_tag_enable DOES come from the polled configuration.
        m_cfg_vif.set_dev_ctrl(3'd2, 3'd5, 1'b0);
        idle(600);
        m_cfg_vif.set_dev_ctrl(3'd2, 3'd5, 1'b1);
        idle(600);

        idle(100);
        phase.drop_objection(this, "t6_cfg_sources");
    endtask

endclass : t6_cfg_sources


// -----------------------------------------------------------------------------
// t6_cov_closure - Tier 5's register-access closure, through the Xilinx
// transport (cg_csr holes on Tier 6):
//   * writes to every block's read-only list header, read back unchanged
//   * body registers of each block and an address past the list
//   * several reads IN FLIGHT at once, each completion paired by tag
//   * an I/O read, which must come back as a no-data UR completion
// -----------------------------------------------------------------------------
class t6_cov_closure extends tier6_base_test;

    `uvm_component_utils(t6_cov_closure)

    function new(string name = "t6_cov_closure", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [31:0] bases [7] = '{32'h000, 32'h040, 32'h050, 32'h070,
                                 32'h080, 32'h100, 32'h200};
        bit [31:0] hdr0 [7][3];
        bit [31:0] d;
        bit        ok;

        phase.raise_objection(this, "t6_cov_closure");
        fork run_cc_collector(); join_none
        apply_power_on_reset();
        idle(400);                         // let pcie_us_cfg finish polling

        // ---- read-only headers: read, write, read back ----------------------
        foreach (bases[b])
            for (int r = 0; r < 3; r++) csr_read(64'(bases[b] + 4 * r), hdr0[b][r], ok);
        foreach (bases[b])
            for (int r = 0; r < 3; r++) csr_write(64'(bases[b] + 4 * r), 32'h5A5A_A5A5 ^ bases[b]);
        idle(100);
        foreach (bases[b])
            for (int r = 0; r < 3; r++) begin
                csr_read(64'(bases[b] + 4 * r), d, ok);
                if (ok && d !== hdr0[b][r])
                    `uvm_error(get_type_name(),
                        $sformatf("read-only header 0x%0h changed after a write: 0x%08h -> 0x%08h",
                                  bases[b] + 4 * r, hdr0[b][r], d))
            end

        // ---- bodies and beyond ----------------------------------------------
        foreach (bases[b]) csr_read(64'(bases[b] + 32'hC), d, ok);
        csr_read(64'h300, d, ok);

        // ---- concurrent reads: each round in flight together ----------------
        // Wrapped in fork..join so `wait fork` sees only these reads: at this
        // level it would also wait for run_cc_collector(), a forever loop, and
        // never return (the first run hung to the 10 ms watchdog that way).
        for (int rep = 0; rep < 3; rep++) begin
            fork begin
                foreach (bases[b]) begin
                    automatic int k = b;
                    fork begin
                        bit [31:0] dk;
                        bit        okk;
                        csr_read(64'(bases[k]), dk, okk);
                        if (okk && dk !== hdr0[k][0])
                            `uvm_error(get_type_name(),
                                $sformatf("block %0d type 0x%08h under load, 0x%08h alone - wrong pairing",
                                          k, dk, hdr0[k][0]))
                    end join_none
                end
                wait fork;
            end join
        end

        // ---- UR: an I/O read is not a memory request ------------------------
        begin
            bit [127:0] h = '0;
            bit [7:0]   tag = m_next_tag;
            int         waited = 0;
            m_next_tag = m_next_tag + 1;
            m_cpl_seen.delete(tag);
            h[127:125] = mqnic_vrf_pkg::TLP_FMT_3DW;
            h[124:120] = 5'b00010;                  // I/O request
            h[105:96]  = 10'd1;
            h[95:80]   = 16'h0100;
            h[79:72]   = tag;
            h[67:64]   = 4'b1111;
            send_cq(h);
            while (!m_cpl_seen.exists(tag) && waited < 20000) begin
                @(posedge m_rst_vif.clk);
                waited++;
            end
            if (!m_cpl_seen.exists(tag))
                `uvm_error(get_type_name(), "I/O read got no completion - UR must still be returned")
            else if (m_cpl_data[tag] !== 32'hBAD0_C0DE)
                `uvm_error(get_type_name(),
                    $sformatf("I/O read returned data 0x%08h; a UR completion carries none",
                              m_cpl_data[tag]))
        end

        idle(100);
        phase.drop_objection(this, "t6_cov_closure");
    endtask

endclass : t6_cov_closure

`endif // TIER6_TESTS_SV

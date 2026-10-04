// SPDX-License-Identifier: BSD-2-Clause-Views
//
// Tier 4d test suite - pcie_us_if (the plan's Tier 4b)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §13 Tier 4, §19 Tier 4, §5
//
// THE SHIM INTEGRATION. Tiers 4a/4b/4c each drive one shim in isolation, which
// is where a tuser or descriptor mismatch has exactly one plausible cause. This
// suite drives all four together and checks only what the isolation tiers
// structurally cannot see:
//
//   * the CONFIGURATION path, which exists only in this wrapper
//   * the four channels running CONCURRENTLY without interference
//
// It deliberately does NOT re-run the per-channel equivalence sweeps. Repeating
// them here would add runtime and no information, and would make an integration
// failure hard to tell from a shim failure - the opposite of why §22 R2 asked
// for the shims to be verified in isolation first.
// -----------------------------------------------------------------------------

`ifndef TIER4D_TESTS_SV
`define TIER4D_TESTS_SV

class tier4d_base_test extends mqnic_base_test;

    `uvm_component_utils(tier4d_base_test)

    tier4d_env                    m_env;
    virtual pcie_us_cfg_status_if m_cfg_vif;

    function new(string name = "tier4d_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        m_env = tier4d_env::type_id::create("m_env", this);
        if (!uvm_config_db #(virtual pcie_us_cfg_status_if)::get(
                this, "", "cfg_status_vif", m_cfg_vif))
            `uvm_fatal(get_type_name(), "cfg_status_vif not set")
    endfunction

    protected task idle(int n);
        repeat (n) @(posedge m_rst_vif.clk);
    endtask

    // Has the wrapper extracted exactly this configuration? Compared HERE rather
    // than through pcie_us_cfg_status_if.is_extracted(): on Vivado xsim 2026.1
    // that interface function returned 0 in t4d_concurrent while the same three
    // `===` comparisons made inline returned 1 at the same instant. Not
    // reproduced in isolation; see "Vivado xsim" in docs/bringup_log.md.
    protected function bit cfg_is(bit [2:0] mps, bit [2:0] mrrs, bit ext_tag);
        return (m_cfg_vif.max_payload_size      === mps)
            && (m_cfg_vif.max_read_request_size === mrrs)
            && (m_cfg_vif.ext_tag_enable        === ext_tag);
    endfunction

    // ---- inbound stimulus ---------------------------------------------------
    // Descriptors are built by ref_tlp_shim, exactly as Tier 4a does. Nothing
    // in this file knows a descriptor bit position.
    protected task send_cq_req(bit [63:0]   addr,
                               int unsigned dw_len = 1,
                               bit [7:0]    tag    = 8'h10);
        pcie_us_axis_pkg::pcie_us_axis_single_seq s;
        bit [127:0] hdr, desc;
        bit [31:0]  dw [];

        hdr  = mqnic_vrf_pkg::tlp_hdr_read_req(.addr(addr), .dw_len(dw_len),
                                               .tag(tag), .requester_id(16'h0100));
        desc = m_env.m_shim.cq_encode(hdr);

        dw = new[4];
        for (int i = 0; i < 4; i++) dw[i] = desc[i*32 +: 32];

        s = pcie_us_axis_pkg::pcie_us_axis_single_seq::type_id::create("cq");
        s.dwords = new[dw.size()];
        foreach (dw[i]) s.dwords[i] = dw[i];
        if (!s.randomize() with { delay inside {[0:3]}; })
            `uvm_fatal(get_type_name(), "randomize failed")
        s.start(m_env.m_cq_axis.sequencer);
    endtask

    // Memory WRITE on CQ: the read header with the has-data format bit set,
    // followed by the payload. The other tests send only 4-DWORD reads, which
    // leaves every CQ length class but one unexercised.
    protected task send_cq_wr(bit [63:0]   addr,
                              int unsigned dw_len,
                              bit [7:0]    tag = 8'h11);
        pcie_us_axis_pkg::pcie_us_axis_single_seq s;
        bit [127:0] hdr, desc;
        bit [31:0]  dw [];

        hdr  = mqnic_vrf_pkg::tlp_hdr_read_req(.addr(addr), .dw_len(dw_len),
                                               .tag(tag), .requester_id(16'h0100));
        hdr[126] = 1'b1;                      // 3DW/4DW -> 3DW/4DW with data
        desc = m_env.m_shim.cq_encode(hdr);

        dw = new[4 + dw_len];
        for (int i = 0; i < 4; i++) dw[i] = desc[i*32 +: 32];
        for (int i = 0; i < int'(dw_len); i++) dw[4 + i] = {8'hD0 + 8'(i), tag, 16'(i)};

        s = pcie_us_axis_pkg::pcie_us_axis_single_seq::type_id::create("cqwr");
        s.dwords = new[dw.size()];
        foreach (dw[i]) s.dwords[i] = dw[i];
        if (!s.randomize() with { delay inside {[0:3]}; })
            `uvm_fatal(get_type_name(), "randomize failed")
        s.start(m_env.m_cq_axis.sequencer);
    endtask

    // A completion returning on RC.
    protected task send_rc_cpl(int unsigned payload_dw = 1,
                               bit [7:0]    tag        = 8'h20);
        pcie_us_axis_pkg::pcie_us_axis_single_seq s;
        bit [127:0] hdr;
        bit [95:0]  desc;          // RC/CC completion descriptors are 3 DW
        bit [31:0]  dw [];

        hdr = mqnic_vrf_pkg::tlp_hdr_completion(
                  .completer_id(16'h0100), .status(3'b000),
                  .byte_count(payload_dw * 4), .requester_id(16'h0200),
                  .tag(tag), .lower_addr(7'h00), .dw_len(payload_dw));
        // cc_encode, not rc_encode: RC and CC share the completion descriptor
        // layout, so ref_tlp_shim has one encoder for both (:57).
        desc = m_env.m_shim.cc_encode(hdr);

        dw = new[3 + payload_dw];
        for (int i = 0; i < 3; i++) dw[i] = desc[i*32 +: 32];
        for (int i = 0; i < int'(payload_dw); i++)
            dw[3 + i] = {8'hB0 + 8'(i), tag, 16'(i)};

        s = pcie_us_axis_pkg::pcie_us_axis_single_seq::type_id::create("rc");
        s.dwords = new[dw.size()];
        foreach (dw[i]) s.dwords[i] = dw[i];
        if (!s.randomize() with { delay inside {[0:3]}; })
            `uvm_fatal(get_type_name(), "randomize failed")
        s.start(m_env.m_rc_axis.sequencer);
    endtask

    // ---- outbound stimulus --------------------------------------------------
    // Our completion heading out over CC, driven on the GENERIC side.
    protected task send_tx_cpl(int unsigned payload_dw = 1,
                               bit [7:0]    tag        = 8'h30);
        pcie_tlp_single_seq s;
        bit [127:0] hdr;

        hdr = mqnic_vrf_pkg::tlp_hdr_completion(
                  .completer_id(16'h0100), .status(3'b000),
                  .byte_count(payload_dw * 4), .requester_id(16'h0200),
                  .tag(tag), .lower_addr(7'h00), .dw_len(payload_dw));

        s = pcie_tlp_single_seq::type_id::create("txcpl");
        if (!s.randomize() with { hdr           == local::hdr;
                                  payload_bytes == local::payload_dw * 4;
                                  delay inside {[0:3]}; })
            `uvm_fatal(get_type_name(), "randomize failed")
        s.start(m_env.m_txcpl_tlp.sequencer);
    endtask

    protected task wait_drained(int max_cycles = 100000);
        int n = 0;
        while (!m_env.is_idle() && n < max_cycles) begin
            @(posedge m_rst_vif.clk);
            n++;
        end
        if (!m_env.is_idle())
            `uvm_error(get_type_name(),
                $sformatf("did not drain in %0d cycles", max_cycles))
        else
            idle(100);
    endtask

endclass : tier4d_base_test


// -----------------------------------------------------------------------------
// t4d_reset - quiescent through reset.
// -----------------------------------------------------------------------------
class t4d_reset extends tier4d_base_test;

    `uvm_component_utils(t4d_reset)

    function new(string name = "t4d_reset", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // No transactions by design, so the §11 "at least one comparison" rule is
    // the documented exception rather than a failure.
    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_rc_sb.m_enable_end_check = 1'b0;
        m_env.m_cq_sb.m_enable_end_check = 1'b0;
        m_env.m_cc_sb.m_enable_end_check = 1'b0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t4d_reset");
        apply_power_on_reset();
        idle(100);
        m_rst_vif.inject_reset(8);
        idle(100);
        phase.drop_objection(this, "t4d_reset");
    endtask

endclass : t4d_reset


// -----------------------------------------------------------------------------
// t4d_cfg_extract - the wrapper reads its own PCIe configuration correctly.
//
// THE TIER'S REASON TO EXIST, and the one check no other tier can make.
//
// pcie_us_cfg polls config space and extracts (pcie_us_cfg.v:121-123)
//     ext_tag_enable        <- cfg_mgmt_read_data[8]
//     max_read_request_size <- cfg_mgmt_read_data[14:12]
//     max_payload_size      <- cfg_mgmt_read_data[7:5]
//
// MPS and MRRS are the INPUTS to the DMA split rules that Tier 3 verified
// against ~390k cases - but Tier 3 is handed those limits directly, so it can
// never see them being read from the wrong bits. If this extraction is wrong,
// every split in the design is computed against the wrong limit and every
// lower tier still passes.
// -----------------------------------------------------------------------------
class t4d_cfg_extract extends tier4d_base_test;

    `uvm_component_utils(t4d_cfg_extract)

    function new(string name = "t4d_cfg_extract", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_rc_sb.m_enable_end_check = 1'b0;
        m_env.m_cq_sb.m_enable_end_check = 1'b0;
        m_env.m_cc_sb.m_enable_end_check = 1'b0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        bit [2:0]    mps_v  [5] = '{3'd2, 3'd0, 3'd5, 3'd7, 3'd1};
        bit [2:0]    mrrs_v [5] = '{3'd5, 3'd0, 3'd2, 3'd7, 3'd3};
        bit          ext_v  [5] = '{1'b1, 1'b0, 1'b0, 1'b1, 1'b1};
        int unsigned waited;

        phase.raise_objection(this, "t4d_cfg_extract");
        apply_power_on_reset();
        idle(50);

        foreach (mps_v[i]) begin
            m_cfg_vif.set_dev_ctrl(mps_v[i], mrrs_v[i], ext_v[i]);

            // pcie_us_cfg waits 0xff cycles between polls (:136), so a changed
            // value takes up to ~300 cycles to be picked up.
            waited = 0;
            while (waited < 2000 &&
                   !cfg_is(mps_v[i], mrrs_v[i], ext_v[i])) begin
                @(posedge m_rst_vif.clk);
                waited++;
            end

            if (m_cfg_vif.max_payload_size !== mps_v[i])
                `uvm_error(get_type_name(),
                    $sformatf({"max_payload_size is %0d, expected %0d - the DMA ",
                               "engine would split every write against the wrong ",
                               "limit"}, m_cfg_vif.max_payload_size, mps_v[i]))
            else if (m_cfg_vif.max_read_request_size !== mrrs_v[i])
                `uvm_error(get_type_name(),
                    $sformatf({"max_read_request_size is %0d, expected %0d - ",
                               "every read would be split against the wrong ",
                               "limit"}, m_cfg_vif.max_read_request_size, mrrs_v[i]))
            else if (m_cfg_vif.ext_tag_enable !== ext_v[i])
                `uvm_error(get_type_name(),
                    $sformatf("ext_tag_enable is %0d, expected %0d",
                              m_cfg_vif.ext_tag_enable, ext_v[i]))
            else
                `uvm_info(get_type_name(),
                    $sformatf({"dev_ctrl mps=%0d mrrs=%0d ext=%0d extracted ",
                               "after %0d cycles"},
                              mps_v[i], mrrs_v[i], ext_v[i], waited), UVM_LOW)
        end

        phase.drop_objection(this, "t4d_cfg_extract");
    endtask

endclass : t4d_cfg_extract


// -----------------------------------------------------------------------------
// t4d_cq_to_rx_req - a host BAR request crosses the whole wrapper.
// -----------------------------------------------------------------------------
class t4d_cq_to_rx_req extends tier4d_base_test;

    `uvm_component_utils(t4d_cq_to_rx_req)

    function new(string name = "t4d_cq_to_rx_req", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // Only CQ is driven; the other channels' scoreboards have nothing to see.
    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_rc_sb.m_enable_end_check = 1'b0;
        m_env.m_cc_sb.m_enable_end_check = 1'b0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t4d_cq_to_rx_req");
        apply_power_on_reset();
        idle(50);

        for (int i = 0; i < 16; i++)
            send_cq_req(.addr(64'h0000_1000 + i * 64'h40), .dw_len(1),
                        .tag(8'(8'h10 + i)));

        wait_drained();
        phase.drop_objection(this, "t4d_cq_to_rx_req");
    endtask

endclass : t4d_cq_to_rx_req


// -----------------------------------------------------------------------------
// t4d_tx_cpl_to_cc - our completion reaches the Xilinx CC stream.
// -----------------------------------------------------------------------------
class t4d_tx_cpl_to_cc extends tier4d_base_test;

    `uvm_component_utils(t4d_tx_cpl_to_cc)

    function new(string name = "t4d_tx_cpl_to_cc", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // Only CC is driven; the other channels' scoreboards have nothing to see.
    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        m_env.m_rc_sb.m_enable_end_check = 1'b0;
        m_env.m_cq_sb.m_enable_end_check = 1'b0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t4d_tx_cpl_to_cc");
        apply_power_on_reset();
        idle(50);

        for (int i = 0; i < 16; i++)
            send_tx_cpl(.payload_dw(1 + (i % 4)), .tag(8'(8'h30 + i)));

        wait_drained();
        phase.drop_objection(this, "t4d_tx_cpl_to_cc");
    endtask

endclass : t4d_tx_cpl_to_cc


// -----------------------------------------------------------------------------
// t4d_concurrent - all four channels at once.
//
// THE OTHER REASON THIS TIER EXISTS. The four shims share only this wrapper, so
// interference between them is invisible to every isolation tier. Running them
// together is the only way to see it.
// -----------------------------------------------------------------------------
class t4d_concurrent extends tier4d_base_test;

    `uvm_component_utils(t4d_concurrent)

    function new(string name = "t4d_concurrent", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        int unsigned waited = 0;
        bit          extracted;

        phase.raise_objection(this, "t4d_concurrent");
        apply_power_on_reset();
        idle(50);

        // Establish the configuration BEFORE the traffic. pcie_us_cfg polls every
        // 0xff cycles (:136) and the traffic below finishes in ~200, so without
        // this the final check compared against a value never extracted in the
        // first place - it read 0 and blamed the traffic.
        m_cfg_vif.set_dev_ctrl(3'd2, 3'd5, 1'b1);
        // One evaluation per cycle, recorded, and reported from that record.
        forever begin
            extracted = cfg_is(3'd2, 3'd5, 1'b1);
            if (extracted || waited >= 2000) break;
            @(posedge m_rst_vif.clk);
            waited++;
        end
        if (!extracted)
            `uvm_error(get_type_name(),
                $sformatf({"configuration not extracted after %0d cycles (mps=%0d mrrs=%0d ",
                           "ext=%0d) - the traffic check below would mean nothing"},
                          waited, m_cfg_vif.max_payload_size,
                          m_cfg_vif.max_read_request_size, m_cfg_vif.ext_tag_enable))

        fork
            begin
                for (int i = 0; i < 12; i++)
                    send_cq_req(.addr(64'h0000_4000 + i * 64'h40),
                                .tag(8'(8'h50 + i)));
            end
            begin
                for (int i = 0; i < 12; i++)
                    send_rc_cpl(.payload_dw(1 + (i % 3)), .tag(8'(8'h60 + i)));
            end
            begin
                for (int i = 0; i < 12; i++)
                    send_tx_cpl(.payload_dw(1 + (i % 4)), .tag(8'(8'h70 + i)));
            end
        join

        wait_drained();

        // The configuration the wrapper learned must be undisturbed by traffic.
        if (m_cfg_vif.max_payload_size !== 3'd2)
            `uvm_error(get_type_name(),
                $sformatf("max_payload_size became %0d while the datapath was busy",
                          m_cfg_vif.max_payload_size))

        phase.drop_objection(this, "t4d_concurrent");
    endtask

endclass : t4d_concurrent


// -----------------------------------------------------------------------------
// t4d_random_stress - randomized traffic on all channels.
// -----------------------------------------------------------------------------
class t4d_random_stress extends tier4d_base_test;

    `uvm_component_utils(t4d_random_stress)

    function new(string name = "t4d_random_stress", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t4d_random_stress");
        apply_power_on_reset();
        idle(50);

        fork
            begin
                for (int i = 0; i < 40; i++)
                    send_cq_req(.addr(64'($urandom()) & 64'hFFFF_FFFC),
                                .dw_len(1 + ($urandom() % 4)),
                                .tag(8'($urandom())));
            end
            begin
                for (int i = 0; i < 40; i++)
                    send_rc_cpl(.payload_dw(1 + ($urandom() % 8)),
                                .tag(8'($urandom())));
            end
            begin
                for (int i = 0; i < 40; i++)
                    send_tx_cpl(.payload_dw(1 + ($urandom() % 8)),
                                .tag(8'($urandom())));
            end
        join

        wait_drained();
        phase.drop_objection(this, "t4d_random_stress");
    endtask

endclass : t4d_random_stress


// -----------------------------------------------------------------------------
// t4d_cov_closure - the straddle/length shapes the tests above never send.
//
//   * CQ memory writes of 1..20 payload DWORDs: every CQ end lane and length
//     class (the other tests send 4-DWORD reads only);
//   * RC pairs of a 3-DWORD and a 4-DWORD completion: the second starts in
//     slot 1 and ends on lane 7;
//   * long (17+ DWORD) TLPs on RC and CC.
// -----------------------------------------------------------------------------
class t4d_cov_closure extends tier4d_base_test;

    `uvm_component_utils(t4d_cov_closure)

    function new(string name = "t4d_cov_closure", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "t4d_cov_closure");
        apply_power_on_reset();
        idle(50);

        for (int n = 1; n <= 20; n++)
            send_cq_wr(.addr(64'h0000_6000 + 64'(n) * 64'h100), .dw_len(n),
                       .tag(8'(8'h80 + n)));
        wait_drained();

        for (int i = 0; i < 4; i++) begin
            send_rc_cpl(.payload_dw(0), .tag(8'(8'hA0 + 2 * i)));
            send_rc_cpl(.payload_dw(1), .tag(8'(8'hA1 + 2 * i)));
        end
        wait_drained();

        // A long TLP as the SECOND of a pair: straddled AND long (x_len).
        for (int i = 0; i < 2; i++) begin
            send_rc_cpl(.payload_dw(0), .tag(8'(8'hB0 + 2 * i)));
            send_rc_cpl(.payload_dw(16 + i), .tag(8'(8'hB1 + 2 * i)));
        end
        wait_drained();

        for (int n = 14; n <= 20; n += 3) begin
            send_rc_cpl(.payload_dw(n), .tag(8'(8'hC0 + n)));
            send_tx_cpl(.payload_dw(n), .tag(8'(8'hD0 + n)));
        end
        wait_drained();

        phase.drop_objection(this, "t4d_cov_closure");
    endtask

endclass : t4d_cov_closure

`endif // TIER4D_TESTS_SV

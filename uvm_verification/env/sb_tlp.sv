// SPDX-License-Identifier: BSD-2-Clause-Views
//
// sb_tlp - Tier 1b scoreboard (TLP routing and buffering)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §11 (sb_protocol), §5 Tier 1b
// Introduced : Step 2 (Tier 1b)
//
// One scoreboard serves every Tier 1b DUT shape:
//
//   pcie_tlp_demux_bar   n_ports outputs, routed by bar_id
//   pcie_tlp_fifo        1 output, everything passes through
//   pcie_tlp_mux         n_ports INPUTS merged onto 1 output (merge_inputs)
//
// ROUTING RULE, from pcie_tlp_demux_bar.v:160
//
//     select[port] = (tlp_bar_id == BAR_IDS_INT[port])
//
// and with BAR_IDS = 0 the per-port BAR id is BAR_BASE + port*BAR_STRIDE.
// mqnic_core_pcie instantiates it with BAR_BASE=0, BAR_STRIDE=2 (:730-732), so
// port 0 owns BAR 0 and port 1 owns BAR 2 - and BAR 1 matches NOTHING.
//
// A TLP whose bar_id matches no port is DROPPED. Predicting that is as much a
// part of the model as predicting where matching TLPs go: a demux that leaked
// unmatched traffic to port 0 would otherwise pass every test.
// -----------------------------------------------------------------------------

`ifndef SB_TLP_SV
`define SB_TLP_SV

`uvm_analysis_imp_decl(_tlp_in)
`uvm_analysis_imp_decl(_tlp_out)

class sb_tlp extends mqnic_scoreboard_base;

    `uvm_component_utils(sb_tlp)

    uvm_analysis_imp_tlp_in  #(pcie_tlp_item, sb_tlp) in_imp;
    uvm_analysis_imp_tlp_out #(pcie_tlp_item, sb_tlp) out_imp;

    // ---- routing configuration ----------------------------------------------
    int  n_ports    = 1;
    int  bar_base   = 0;
    int  bar_stride = 1;
    // When clear every TLP goes to port 0 regardless of bar_id (fifo shape).
    bit  route_by_bar = 1'b1;

    // ---- merge shape (pcie_tlp_mux) -----------------------------------------
    // n_ports INPUTS, one output. The order ACROSS inputs is the arbiter's
    // choice, but each input's own order must survive, so an output TLP has to
    // equal the HEAD of exactly one input queue. seq is compared too: the mux
    // carries it through (pcie_tlp_mux.v:342).
    bit  merge_inputs = 1'b0;
    // Starvation bound: most outputs in a row from one port while another port
    // had a TLP waiting. Round-robin (mqnic_core_pcie.v:784) should give 1; the
    // bound allows for the input register stage. 0 disables the check.
    int  max_run_while_waiting = 0;
    int  m_worst_run;
    int  m_per_port_out [];

    // Optional functional coverage; sampled only on matched (or correctly
    // dropped) traffic.
    cg_tlp cov;

    // Expected TLPs per output port (routed shape) or per INPUT port (merge
    // shape), in order.
    protected pcie_tlp_item m_exp [][$];
    protected int unsigned  m_n_dropped;
    protected int           m_last_src = -1;
    protected int           m_run;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        in_imp  = new("in_imp", this);
        out_imp = new("out_imp", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        m_exp = new[n_ports];
        m_per_port_out = new[n_ports];
    endfunction

    virtual function int unsigned pending_count();
        int unsigned n = 0;
        foreach (m_exp[p]) n += m_exp[p].size();
        return n;
    endfunction

    // -------------------------------------------------------------------------
    // Which output port owns this BAR, or -1 if none does (TLP is dropped).
    // -------------------------------------------------------------------------
    virtual function int port_for_bar(bit [2:0] bar_id);
        if (!route_by_bar) return 0;
        for (int p = 0; p < n_ports; p++)
            if (int'(bar_id) == bar_base + p * bar_stride) return p;
        return -1;
    endfunction

    // -------------------------------------------------------------------------
    virtual function void write_tlp_in(pcie_tlp_item t);
        int p;

        if (merge_inputs) begin
            if (t.src_port < 0 || t.src_port >= n_ports)
                `uvm_fatal(get_type_name(),
                    $sformatf("input TLP from port %0d, merge scoreboard has %0d inputs",
                              t.src_port, n_ports))
            m_exp[t.src_port].push_back(t);
            note_expected();
            return;
        end

        p = port_for_bar(t.bar_id);
        if (p < 0) begin
            m_n_dropped++;
            // A drop cannot be observed, only the absence of output; a leaked
            // TLP fails write_tlp_out as unexpected, so sampling here is safe.
            if (cov != null) cov.sample_route(t.bar_id, 2, t.payload.size());
            `uvm_info(get_type_name(),
                $sformatf("bar_id %0d matches no port - TLP expected to be DROPPED",
                          t.bar_id), UVM_HIGH)
            return;
        end

        m_exp[p].push_back(t);
        note_expected();
        `uvm_info(get_type_name(),
            $sformatf("expect on port %0d: %s", p, t.convert2string()), UVM_HIGH)
    endfunction

    // -------------------------------------------------------------------------
    virtual function void write_tlp_out(pcie_tlp_item t);
        pcie_tlp_item e;
        int           p = t.src_port;
        int           first_diff;
        string        ctx;

        note_actual();

        if (merge_inputs) begin
            check_merged(t);
            return;
        end

        if (p < 0 || p >= n_ports) begin
            note_mismatch("output from an unknown port",
                          $sformatf("port in [0,%0d)", n_ports),
                          $sformatf("port %0d", p));
            return;
        end

        if (m_exp[p].size() == 0) begin
            note_mismatch($sformatf("unexpected TLP on port %0d - nothing routed there", p),
                          "no TLP", t.convert2string());
            return;
        end

        e   = m_exp[p].pop_front();
        ctx = $sformatf("TLP on port %0d", p);

        // The routing DUTs must not alter anything: header, payload and every
        // sideband arrive bit-identical.
        if (e.hdr !== t.hdr) begin
            note_mismatch({ctx, " header"},
                          $sformatf("0x%032h", e.hdr),
                          $sformatf("0x%032h", t.hdr));
            return;
        end
        if (e.bar_id !== t.bar_id || e.func_num !== t.func_num ||
            e.error !== t.error) begin
            note_mismatch({ctx, " sidebands"},
                $sformatf("bar=%0d func=%0d err=%0d", e.bar_id, e.func_num, e.error),
                $sformatf("bar=%0d func=%0d err=%0d", t.bar_id, t.func_num, t.error));
            return;
        end
        if (!mqnic_vrf_pkg::bytes_equal(e.payload, t.payload, first_diff)) begin
            if (e.payload.size() != t.payload.size())
                note_mismatch({ctx, " payload length"},
                              $sformatf("%0d bytes", e.payload.size()),
                              $sformatf("%0d bytes", t.payload.size()));
            else
                note_mismatch($sformatf("%s payload (first difference at byte %0d)",
                                        ctx, first_diff),
                              $sformatf("0x%02h", e.payload[first_diff]),
                              $sformatf("0x%02h", t.payload[first_diff]));
            return;
        end

        note_match(ctx);
        if (cov != null) cov.sample_route(t.bar_id, p, t.payload.size());
    endfunction

    // -------------------------------------------------------------------------
    // Merge shape: which input head is this? Exactly-equal on everything the
    // mux must carry through - header, payload and all four sidebands.
    // -------------------------------------------------------------------------
    protected function bit same_tlp(pcie_tlp_item e, pcie_tlp_item t);
        int first_diff;
        return e.hdr === t.hdr && e.bar_id === t.bar_id && e.func_num === t.func_num
            && e.error === t.error && e.seq === t.seq
            && mqnic_vrf_pkg::bytes_equal(e.payload, t.payload, first_diff);
    endfunction

    protected function void check_merged(pcie_tlp_item t);
        int src = -1;

        foreach (m_exp[p])
            if (m_exp[p].size() > 0 && same_tlp(m_exp[p][0], t)) begin
                src = p;
                break;
            end

        if (src < 0) begin
            string heads = "";
            foreach (m_exp[p])
                heads = {heads, $sformatf("\n            port %0d head: %s", p,
                         (m_exp[p].size() > 0) ? m_exp[p][0].convert2string() : "(empty)")};
            // Distinguish "reordered within a port" from "corrupted / invented".
            foreach (m_exp[p])
                foreach (m_exp[p][i])
                    if (i > 0 && same_tlp(m_exp[p][i], t)) begin
                        note_mismatch($sformatf("merged output is port %0d's TLP #%0d - it overtook earlier TLPs from the same port", p, i),
                                      "the head of that port's queue", t.convert2string());
                        return;
                    end
            note_mismatch({"merged output matches no input port's next TLP", heads},
                          "the head of some input queue", t.convert2string());
            return;
        end

        // Starvation: consecutive outputs from one port while another waited.
        if (src == m_last_src) m_run++;
        else                   m_run = 1;
        m_last_src = src;
        void'(m_exp[src].pop_front());
        m_per_port_out[src]++;
        begin
            bit other_waiting = 1'b0;
            foreach (m_exp[p]) if (p != src && m_exp[p].size() > 0) other_waiting = 1'b1;
            if (other_waiting && m_run > m_worst_run) m_worst_run = m_run;
            if (max_run_while_waiting > 0 && other_waiting && m_run > max_run_while_waiting)
                note_mismatch($sformatf("port %0d won %0d arbitrations in a row while another port was waiting",
                                        src, m_run),
                              $sformatf("at most %0d (round-robin)", max_run_while_waiting),
                              $sformatf("%0d", m_run));
            if (cov != null) cov.sample_merge(src, other_waiting, t.payload.size(), m_run);
        end
        note_match($sformatf("merged TLP from input port %0d", src));
    endfunction

    // -------------------------------------------------------------------------
    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        if (merge_inputs) begin
            string s = "";
            foreach (m_per_port_out[p]) s = {s, $sformatf(" port%0d=%0d", p, m_per_port_out[p])};
            `uvm_info(get_type_name(),
                $sformatf("merged TLPs per input:%s; longest same-port run while another waited: %0d",
                          s, m_worst_run), UVM_LOW)
        end
        else
            `uvm_info(get_type_name(),
                $sformatf("TLPs dropped by BAR mismatch: %0d", m_n_dropped), UVM_LOW)
    endfunction

endclass : sb_tlp

`endif // SB_TLP_SV

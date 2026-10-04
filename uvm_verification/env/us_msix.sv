// SPDX-License-Identifier: BSD-2-Clause-Views
//
// us_msix - MSI-X at the UltraScale boundary (objective G7)
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §1 G7 ("MSI-X TLP address/data match
//              table contents")
// Introduced : G7 MSI-X
//
//   us_msix_hip  plays the hard IP: answers each cfg_interrupt_msix_int with
//                cfg_interrupt_msix_sent (or _fail, on request) after a random
//                latency, and publishes every message it accepted.
//   sb_msix      checks every message against the MSI-X table the driver
//                programmed: address and data must be those of a vector that
//                is unmasked, while the function is enabled and unmasked.
//
// WHAT IS NOT MODELLED. A real hard IP turns an accepted message into a memory
// write on the link; nothing in the DUT observes that write, so the model
// stops at the handshake and hands the message to the host side directly.
// -----------------------------------------------------------------------------

`ifndef US_MSIX_SV
`define US_MSIX_SV

class msix_msg extends uvm_sequence_item;

    `uvm_object_utils(msix_msg)

    bit [63:0] address;
    bit [31:0] data;
    bit [7:0]  func;
    bit        failed;          // the hard IP answered _fail
    time       stamp;

    function new(string name = "msix_msg");
        super.new(name);
    endfunction

    virtual function string convert2string();
        return $sformatf("MSI-X addr=0x%016h data=0x%08h func=%0d%s",
                         address, data, func, failed ? " (FAILED)" : "");
    endfunction

endclass : msix_msg


class us_msix_hip extends uvm_component;

    `uvm_component_utils(us_msix_hip)

    virtual pcie_us_msix_if vif;
    uvm_analysis_port #(msix_msg) ap;

    int unsigned min_latency = 2;
    int unsigned max_latency = 24;
    // Answer the next N requests with _fail instead of _sent.
    int unsigned fail_next   = 0;

    int unsigned n_sent, n_failed;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual pcie_us_msix_if)::get(this, "", "msix_vif", vif))
            `uvm_fatal(get_type_name(), "msix_vif not set")
    endfunction

    // Config-space side: what the function's MSI-X capability says.
    virtual function void set_function(bit enable, bit mask);
        // Whole-vector writes: PF0 is bit 0, the other functions do not exist.
        vif.enable = {3'b000, enable};
        vif.mask   = {3'b000, mask};
    endfunction

    virtual task run_phase(uvm_phase phase);
        msix_msg m;
        vif.sent = 1'b0;
        vif.fail = 1'b0;
        forever begin
            @(posedge vif.clk);
            if (vif.rst === 1'b1 || vif.int_req !== 1'b1) continue;

            m = msix_msg::type_id::create("msix");
            m.address = vif.address;
            m.data    = vif.data;
            m.func    = vif.function_number;
            m.stamp   = $time;
            m.failed  = (fail_next > 0);
            if (fail_next > 0) fail_next--;

            // The DUT must hold the request until answered (pcie_us_if.v:592-603)
            // and must not raise another meanwhile.
            repeat ($urandom_range(min_latency, max_latency)) begin
                @(posedge vif.clk);
                if (vif.int_req === 1'b1)
                    `uvm_error(get_type_name(),
                        "second cfg_interrupt_msix_int while the first is unanswered")
                if (vif.address !== m.address || vif.data !== m.data)
                    `uvm_error(get_type_name(),
                        $sformatf("MSI-X address/data changed while pending: %s -> 0x%016h/0x%08h",
                                  m.convert2string(), vif.address, vif.data))
            end
            if (m.failed) begin vif.fail <= 1'b1; n_failed++; end
            else          begin vif.sent <= 1'b1; n_sent++;   end
            @(posedge vif.clk);
            vif.sent <= 1'b0;
            vif.fail <= 1'b0;
            ap.write(m);
        end
    endtask

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf("MSI-X: %0d sent, %0d failed", n_sent, n_failed), UVM_LOW)
    endfunction

endclass : us_msix_hip


`uvm_analysis_imp_decl(_sb_msix)

class sb_msix extends mqnic_scoreboard_base;

    `uvm_component_utils(sb_msix)

    uvm_analysis_imp_sb_msix #(msix_msg, sb_msix) imp;

    us_msix_hip hip;     // for the function enable/mask levels

    // The table as the driver programmed it.
    protected bit [63:0] m_addr   [int unsigned];
    protected bit [31:0] m_data   [int unsigned];
    protected bit        m_masked [int unsigned];

    int unsigned n_per_vector [int unsigned];
    int unsigned n_ok, n_failed_seen;

    // ---- coverage ------------------------------------------------------------
    protected int unsigned s_vector;
    protected bit          s_failed;
    protected bit          s_was_pending;    // delivered after being held masked
    protected bit          m_held [int unsigned];

    covergroup cg_msix;
        option.per_instance = 1;
        cp_vector  : coverpoint s_vector { bins v[] = {[0:3]}; bins high = {[4:31]}; }
        cp_outcome : coverpoint s_failed { bins sent = {0}; bins failed = {1}; }
        cp_pending : coverpoint s_was_pending { bins direct = {0}; bins after_unmask = {1}; }
    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        imp     = new("imp", this);
        cg_msix = new();
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        cg_msix.set_inst_name({get_full_name(), ".cg_msix"});
    endfunction

    // Driver -> scoreboard: a table entry was written.
    virtual function void set_entry(int unsigned v, bit [63:0] addr, bit [31:0] data, bit masked);
        m_addr[v]   = addr;
        m_data[v]   = data;
        if (masked) m_held[v] = 1'b1;     // an interrupt may now be held pending
        m_masked[v] = masked;
    endfunction

    virtual function void write_sb_msix(msix_msg m);
        int found = -1;
        note_actual();
        foreach (m_addr[v])
            if (m_addr[v] == m.address && m_data[v] == m.data) begin found = v; break; end

        if (found < 0) begin
            note_mismatch("MSI-X message matches no programmed table entry",
                          "address/data of an entry", m.convert2string());
            return;
        end
        if (m_masked[found]) begin
            note_mismatch($sformatf("MSI-X message for vector %0d, which is masked", found),
                          "nothing while masked", m.convert2string());
            return;
        end
        if (hip.vif.enable[0] !== 1'b1 || hip.vif.mask[0] !== 1'b0) begin
            note_mismatch("MSI-X message while the function is disabled or masked",
                          $sformatf("enable=1 mask=0 (have %b/%b)", hip.vif.enable[0], hip.vif.mask[0]),
                          m.convert2string());
            return;
        end
        if (m.func != 0)
            note_mismatch("MSI-X message from a function other than PF0", "0",
                          $sformatf("%0d", m.func));

        s_vector      = found;
        s_failed      = m.failed;
        s_was_pending = m_held.exists(found);
        m_held.delete(found);
        cg_msix.sample();

        if (m.failed) n_failed_seen++;
        else begin
            n_ok++;
            if (!n_per_vector.exists(found)) n_per_vector[found] = 0;
            n_per_vector[found]++;
        end
        note_match($sformatf("MSI-X vector %0d", found));
    endfunction

    virtual function int unsigned pending_count();
        return 0;      // nothing is expected in advance; every message is checked
    endfunction

    virtual function int unsigned count(int unsigned v);
        return n_per_vector.exists(v) ? n_per_vector[v] : 0;
    endfunction

    virtual function void report_phase(uvm_phase phase);
        string s = "";
        super.report_phase(phase);
        foreach (n_per_vector[v]) s = {s, $sformatf(" v%0d:%0d", v, n_per_vector[v])};
        `uvm_info(get_type_name(),
            $sformatf("MSI-X messages checked: %0d delivered (%s ), %0d failed | coverage %.1f%%",
                      n_ok, s, n_failed_seen, cg_msix.get_inst_coverage()), UVM_LOW)
    endfunction

endclass : sb_msix

`endif // US_MSIX_SV

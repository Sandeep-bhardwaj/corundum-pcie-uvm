// SPDX-License-Identifier: BSD-2-Clause-Views
//
// mqnic_base_test
// -----------------------------------------------------------------------------
// Root test class. Every test in every tier extends this.
//
// Implements : VERIFICATION_STRATEGY.md  §4.1 (test layer), §17.4 (messaging),
//                                        §19 E8 (no silent pass)
// Introduced : Step 0 (infrastructure)
//
// Responsibilities:
//   * global timeout, overridable from the command line
//   * reset interface lookup and the default power-on reset
//   * topology + factory-override print at end of elaboration
//   * the authoritative PASS/FAIL verdict in report_phase
//
// The verdict is computed from the report server, not from a flag any test
// could forget to set. A test with zero UVM_ERROR and zero UVM_FATAL passes;
// anything else fails. STRATEGY §19 E8.
//
// Plusargs:
//   +MQNIC_TIMEOUT_NS=<n>   override the global timeout (default 10 ms)
//   +MQNIC_RESET_CYCLES=<n> length of the power-on reset (default 20)
//   +MQNIC_NO_AUTO_RESET    skip the automatic power-on reset
// -----------------------------------------------------------------------------

`ifndef MQNIC_BASE_TEST_SV
`define MQNIC_BASE_TEST_SV

class mqnic_base_test extends uvm_test;

    `uvm_component_utils(mqnic_base_test)

    // Reset driver for the primary clock domain. Optional: a tier whose DUT is
    // driven entirely by an agent may not register one.
    virtual mqnic_reset_if m_rst_vif;

    // Kept as `time` so the multiply below stays integral - mixing an integer
    // count with a realtime literal such as 1ns produces a type-mismatch
    // diagnostic and silently changes precision.
    localparam time ONE_NS = 1ns;

    protected longint unsigned m_timeout_ns   = 10_000_000;   // 10 ms
    protected int              m_reset_cycles = 20;
    protected bit              m_auto_reset   = 1'b1;
    // Tiers whose DUT contains the AXI-Lite register tree (5, 6) set this: see
    // mqnic_reset_if.pulse_reset_x_safe() for why one reset pulse is not enough.
    protected bit              m_x_safe_reset = 1'b0;

    function new(string name = "mqnic_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // -------------------------------------------------------------------------
    virtual function void build_phase(uvm_phase phase);
        int             val;
        string          sval;

        super.build_phase(phase);

        if ($value$plusargs("MQNIC_TIMEOUT_NS=%d", val))
            m_timeout_ns = val;
        if ($value$plusargs("MQNIC_RESET_CYCLES=%d", val))
            m_reset_cycles = val;
        if ($test$plusargs("MQNIC_NO_AUTO_RESET"))
            m_auto_reset = 1'b0;

        // Global watchdog. A hung DUT must fail, not run until the grid kills it.
        uvm_top.set_timeout(m_timeout_ns * ONE_NS, 1);

        // Optional - not every tier registers a reset interface.
        if (!uvm_config_db#(virtual mqnic_reset_if)::get(this, "", "rst_vif", m_rst_vif)) begin
            `uvm_info(get_type_name(),
                "no rst_vif registered; the test is responsible for its own reset",
                UVM_MEDIUM)
        end

        sval = "";
        void'($value$plusargs("UVM_TESTNAME=%s", sval));
        `uvm_info(get_type_name(),
            $sformatf("test=%s timeout=%0d ns reset_cycles=%0d auto_reset=%0b",
                      (sval == "") ? get_type_name() : sval,
                      m_timeout_ns, m_reset_cycles, m_auto_reset),
            UVM_LOW)
    endfunction

    // -------------------------------------------------------------------------
    // One message once simulated time passes 1 us. xsim_run.py treats a log
    // with nothing after time 0 for 5 minutes as a stalled launch; a test
    // that is silent until its watchdog fires must not look like one.
    virtual function void start_of_simulation_phase(uvm_phase phase);
        super.start_of_simulation_phase(phase);
        fork
            begin
                #1us;
                `uvm_info("HEARTBEAT", "simulated time is advancing", UVM_LOW)
            end
        join_none
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        if (uvm_report_enabled(UVM_HIGH) != 0) begin
            uvm_factory f = uvm_coreservice_t::get().get_factory();
            uvm_top.print_topology();
            f.print();
        end
    endfunction

    // -------------------------------------------------------------------------
    // Default run: power-on reset only. Derived tests override run_phase and
    // should call apply_power_on_reset() first unless they drive reset
    // themselves.
    // -------------------------------------------------------------------------
    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "base test run_phase");
        apply_power_on_reset();
        phase.drop_objection(this, "base test run_phase");
    endtask

    // -------------------------------------------------------------------------
    virtual task apply_power_on_reset();
        if (!m_auto_reset) begin
            `uvm_info(get_type_name(), "auto reset disabled by plusarg", UVM_MEDIUM)
            return;
        end
        if (m_rst_vif == null) begin
            `uvm_info(get_type_name(), "no rst_vif; skipping power-on reset", UVM_MEDIUM)
            return;
        end
        `uvm_info(get_type_name(),
            $sformatf("applying power-on reset (%0d cycles)", m_reset_cycles), UVM_MEDIUM)
        if (m_x_safe_reset)
            m_rst_vif.pulse_reset_x_safe(m_reset_cycles);
        else
            m_rst_vif.pulse_reset(m_reset_cycles);
    endtask

    // -------------------------------------------------------------------------
    // Authoritative verdict. Printed in a fixed format so the regression
    // runner can scrape it without parsing UVM's own summary.
    // -------------------------------------------------------------------------
    virtual function void report_phase(uvm_phase phase);
        uvm_report_server svr;
        int               n_error;
        int               n_fatal;
        int               n_warning;

        super.report_phase(phase);

        svr       = uvm_report_server::get_server();
        n_fatal   = svr.get_severity_count(UVM_FATAL);
        n_error   = svr.get_severity_count(UVM_ERROR);
        n_warning = svr.get_severity_count(UVM_WARNING);

        $display("");
        $display("=========================================================");
        $display(" test      : %s", get_type_name());
        $display(" errors    : %0d", n_error);
        $display(" fatals    : %0d", n_fatal);
        $display(" warnings  : %0d", n_warning);
        if (n_error == 0 && n_fatal == 0)
            $display(" TEST PASSED");
        else
            $display(" TEST FAILED");
        $display("=========================================================");
        $display("");
    endfunction

endclass : mqnic_base_test

`endif // MQNIC_BASE_TEST_SV

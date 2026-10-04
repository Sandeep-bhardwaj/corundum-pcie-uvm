// SPDX-License-Identifier: BSD-2-Clause-Views
//
// host_mem_writer - commits observed write TLPs into the host memory model
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §9 (host memory model), §13 Tier 3c
// Introduced : Step 5 (Tier 3c); reused at Tiers 5 and 6
//
// THE PIECE THAT CLOSES THE LOOP.
//
// Tiers 3a and 3b each check one direction against a reference the testbench
// supplied. Tier 3c can do something neither can: run a descriptor pair that
// reads host memory into RAM and writes that RAM back out to a DIFFERENT host
// address, then compare the two host regions. That is an end-to-end check of
// the whole engine with no reference model in the middle at all - and it only
// works if the testbench actually APPLIES the outbound writes to host memory,
// which is this component's entire job.
//
// It is a pure actuator: no checking happens here. Mixing the two would make
// "the write landed in the wrong place" and "the comparison is wrong"
// indistinguishable, which is the same separation rc_responder keeps between
// mqnic_rc_model and the driving of completions.
//
// The payload is transmitted in whole DWORDs, so the leading (addr & 3) bytes
// on the wire precede the data and must not be committed - the same padding
// rule as everywhere else on this interface.
// -----------------------------------------------------------------------------

`ifndef HOST_MEM_WRITER_SV
`define HOST_MEM_WRITER_SV

`uvm_analysis_imp_decl(_hmw)

class host_mem_writer extends uvm_component;

    `uvm_component_utils(host_mem_writer)

    uvm_analysis_imp_hmw #(pcie_tlp_item, host_mem_writer) req_imp;

    mqnic_host_mem_model mem;

    protected int unsigned m_n_tlp;
    protected int unsigned m_n_bytes;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        req_imp = new("req_imp", this);
    endfunction

    virtual function void write_hmw(pcie_tlp_item t);
        bit [63:0]   addr;
        int unsigned len;
        int unsigned pad;

        if (mem == null)
            `uvm_fatal(get_type_name(), "host memory model not connected")

        addr = mqnic_vrf_pkg::tlp_hdr_req_byte_addr(t.hdr);
        len  = mqnic_vrf_pkg::tlp_hdr_req_byte_len(t.hdr);
        pad  = int'(addr[1:0]);

        if (t.payload.size() < pad + len) begin
            `uvm_error(get_type_name(),
                $sformatf({"write TLP at 0x%0h claims %0d bytes but carries only ",
                           "%0d on the wire"}, addr, pad + len, t.payload.size()))
            return;
        end

        for (int i = 0; i < int'(len); i++)
            mem.write_byte(addr + i, t.payload[pad + i]);

        m_n_tlp++;
        m_n_bytes += len;

        `uvm_info(get_type_name(),
            $sformatf("committed %0d byte(s) to host memory at 0x%0h", len, addr),
            UVM_HIGH)
    endfunction

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf("committed %0d write TLP(s), %0d byte(s)", m_n_tlp, m_n_bytes),
            UVM_LOW)
    endfunction

endclass : host_mem_writer

`endif // HOST_MEM_WRITER_SV

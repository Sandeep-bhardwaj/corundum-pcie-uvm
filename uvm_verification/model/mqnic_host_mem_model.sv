// SPDX-License-Identifier: BSD-2-Clause-Views
//
// mqnic_host_mem_model - sparse host memory behind the root complex
// -----------------------------------------------------------------------------
// Implements : VERIFICATION_STRATEGY.md  §9 (host memory model)
// Introduced : Step 5 (Tier 3); reused at Tiers 5 and 6
//
// SPARSE BY NECESSITY. The DUT addresses a 64-bit space, so dense allocation is
// impossible - this is an associative array of bytes, exactly as §9 requires.
//
// Beyond storage it does two jobs that make DMA checkable:
//
//   1. AN ACCESS LOG with timestamps, so the DMA scoreboard can correlate TLP
//      activity against memory state rather than guessing.
//   2. REGION ATTRIBUTES for error injection - a range can be marked
//      unsupported-request, completer-abort or poisoned, and the root complex
//      model turns that into the matching completion status. Without this the
//      error paths in §13's t3_err_* tests cannot be reached at all, and those
//      are the paths that are almost never covered by directed tests.
// -----------------------------------------------------------------------------

`ifndef MQNIC_HOST_MEM_MODEL_SV
`define MQNIC_HOST_MEM_MODEL_SV

// How a region responds to an access.
typedef enum {
    HOST_MEM_OK,
    HOST_MEM_UR,        // unsupported request
    HOST_MEM_CA,        // completer abort
    HOST_MEM_POISON     // returns data, but the completion is marked poisoned
} host_mem_status_e;


class host_mem_region;
    bit [63:0]        base;
    bit [63:0]        limit;      // inclusive
    host_mem_status_e status;
endclass


class host_mem_access;
    bit          is_write;
    bit [63:0]   addr;
    int unsigned len;
    time         stamp;
endclass


class mqnic_host_mem_model extends uvm_object;

    `uvm_object_utils(mqnic_host_mem_model)

    // Sparse byte store. A 64-bit space cannot be modelled any other way.
    protected byte unsigned m_mem [bit [63:0]];

    // Regions with non-OK behaviour. Kept as a small list rather than a map
    // because it is searched per access and is expected to hold a handful of
    // entries at most.
    protected host_mem_region m_regions [$];

    // Access log, for the scoreboard to correlate against TLP activity.
    protected host_mem_access m_log [$];
    bit          log_enable   = 1'b1;
    int unsigned log_max      = 100000;

    // Reads of never-written memory return this rather than X, so a scoreboard
    // mismatch on untouched memory is legible instead of propagating unknowns.
    byte unsigned default_byte = 8'h00;

    // Simple bump allocator for test-allocated buffers.
    protected bit [63:0] m_alloc_next = 64'h0000_0001_0000_0000;

    function new(string name = "mqnic_host_mem_model");
        super.new(name);
    endfunction

    // -------------------------------------------------------------------------
    virtual function void reset();
        m_mem.delete();
        m_regions.delete();
        m_log.delete();
        m_alloc_next = 64'h0000_0001_0000_0000;
    endfunction

    // -------------------------------------------------------------------------
    // Byte access
    // -------------------------------------------------------------------------
    virtual function void write_byte(bit [63:0] addr, byte unsigned d);
        m_mem[addr] = d;
    endfunction

    virtual function byte unsigned read_byte(bit [63:0] addr);
        return m_mem.exists(addr) ? m_mem[addr] : default_byte;
    endfunction

    virtual function void write_bytes(bit [63:0] addr, const ref byte unsigned d[]);
        foreach (d[i]) m_mem[addr + i] = d[i];
        note_access(1'b1, addr, d.size());
    endfunction

    virtual function void read_bytes(bit [63:0] addr, input int unsigned len,
                                     output byte unsigned d[]);
        d = new[len];
        for (int i = 0; i < int'(len); i++)
            d[i] = read_byte(addr + i);
        note_access(1'b0, addr, len);
    endfunction

    // Fill with a value derived from the address, so a misdirected DMA shows up
    // as wrong data rather than plausible-looking data.
    virtual function void fill_pattern(bit [63:0] addr, int unsigned len);
        for (int i = 0; i < int'(len); i++)
            m_mem[addr + i] = 8'((addr + i) ^ ((addr + i) >> 8));
    endfunction

    virtual function bit compare_region(bit [63:0] addr,
                                        const ref byte unsigned expected[],
                                        output int first_diff);
        first_diff = -1;
        foreach (expected[i]) begin
            if (read_byte(addr + i) !== expected[i]) begin
                first_diff = i;
                return 1'b0;
            end
        end
        return 1'b1;
    endfunction

    // -------------------------------------------------------------------------
    // Allocation
    // -------------------------------------------------------------------------
    virtual function bit [63:0] alloc_region(int unsigned size,
                                             int unsigned align = 4096);
        bit [63:0] a = (m_alloc_next + align - 1) & ~(64'(align) - 64'd1);
        m_alloc_next = a + size + align;   // leave a gap so overruns are visible
        return a;
    endfunction

    // -------------------------------------------------------------------------
    // Region attributes - how error injection is reached (§13 t3_err_*).
    // -------------------------------------------------------------------------
    virtual function void set_region_status(bit [63:0] base, bit [63:0] limit,
                                            host_mem_status_e st);
        host_mem_region r = new();
        r.base   = base;
        r.limit  = limit;
        r.status = st;
        m_regions.push_back(r);
    endfunction

    virtual function void clear_regions();
        m_regions.delete();
    endfunction

    // Status for an access. The FIRST matching region wins, so a test can lay a
    // small error window over a larger OK region.
    virtual function host_mem_status_e status_for(bit [63:0] addr,
                                                  int unsigned len);
        bit [63:0] last = addr + len - 1;
        foreach (m_regions[i])
            if (!(last < m_regions[i].base || addr > m_regions[i].limit))
                return m_regions[i].status;
        return HOST_MEM_OK;
    endfunction

    // -------------------------------------------------------------------------
    // Access log
    // -------------------------------------------------------------------------
    protected virtual function void note_access(bit is_write, bit [63:0] addr,
                                                int unsigned len);
        host_mem_access a;
        if (!log_enable) return;
        if (m_log.size() >= log_max) return;
        a = new();
        a.is_write = is_write;
        a.addr     = addr;
        a.len      = len;
        a.stamp    = $time;
        m_log.push_back(a);
    endfunction

    virtual function int unsigned log_size();
        return m_log.size();
    endfunction

    virtual function host_mem_access log_entry(int unsigned i);
        return (i < m_log.size()) ? m_log[i] : null;
    endfunction

    virtual function void clear_log();
        m_log.delete();
    endfunction

    // -------------------------------------------------------------------------
    virtual function string convert2string();
        return $sformatf("host_mem: %0d byte(s) stored, %0d region(s), %0d log entries",
                         m_mem.size(), m_regions.size(), m_log.size());
    endfunction

endclass : mqnic_host_mem_model

`endif // MQNIC_HOST_MEM_MODEL_SV

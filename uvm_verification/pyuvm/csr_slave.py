"""A minimal AXI-Lite slave for the core's m_axil_csr_* master.

Implements : VERIFICATION_STRATEGY.md  §7.1 (MODE_ACTIVE_SLAVE)

WHY THIS IS NEEDED, and why its absence was invisible
-----------------------------------------------------
m_axil_csr_* is an OUTPUT of mqnic_core_pcie - the core's own master towards
application logic. Its handshake and response signals are therefore INPUTS to
the core, and tying them to zero (the correct default for an unused input) holds
the bus permanently not-ready.

The effect is not a failure anywhere near the cause: a BAR register read is
accepted, routed correctly by the TLP demux, handed to pcie_axil_master, and
then stalls on m_axil_csr_arready with no error and no timeout. The symptom is
"no completion", three levels away.

This responder accepts everything and returns a readable pattern, which is
enough for register discovery. A real application model belongs at Tier 6.
"""

import cocotb
from cocotb.triggers import RisingEdge


def _i(sig):
    """Read a signal as an int, treating X/Z as 0.

    During and just after reset the core's CSR master outputs are unresolved,
    and int() raises on them. Treating unknown as 'not asserted' is the same
    convention the SystemVerilog monitors use (=== 1'b1), and it keeps the
    responder from dying on the first cycle.
    """
    try:
        return int(sig.value)
    except Exception:
        return 0


async def run_csr_slave(dut, log=None):
    """Always-ready AXI-Lite slave on m_axil_csr_*."""
    dut.m_axil_csr_awready.value = 1
    dut.m_axil_csr_wready.value = 1
    dut.m_axil_csr_bresp.value = 0
    dut.m_axil_csr_bvalid.value = 0
    dut.m_axil_csr_arready.value = 1
    dut.m_axil_csr_rdata.value = 0
    dut.m_axil_csr_rresp.value = 0
    dut.m_axil_csr_rvalid.value = 0

    mem = {}
    n_rd = n_wr = 0

    while True:
        await RisingEdge(dut.clk)

        # Write: address and data arrive independently, so latch each.
        if _i(dut.m_axil_csr_awvalid) and _i(dut.m_axil_csr_awready):
            wa = _i(dut.m_axil_csr_awaddr)
        if _i(dut.m_axil_csr_wvalid) and _i(dut.m_axil_csr_wready):
            mem[wa] = _i(dut.m_axil_csr_wdata)
            n_wr += 1
            dut.m_axil_csr_bvalid.value = 1
        elif _i(dut.m_axil_csr_bready):
            dut.m_axil_csr_bvalid.value = 0

        # Read: one cycle of latency, data from the sparse store.
        if _i(dut.m_axil_csr_rvalid) and _i(dut.m_axil_csr_rready):
            dut.m_axil_csr_rvalid.value = 0
        if _i(dut.m_axil_csr_arvalid) and _i(dut.m_axil_csr_arready):
            ra = _i(dut.m_axil_csr_araddr)
            # A distinctive default, so a read of never-written CSR space is
            # visibly "the slave answered" rather than indistinguishable from 0.
            dut.m_axil_csr_rdata.value = mem.get(ra, 0xC5C5_0000 | (ra & 0xFFFF))
            dut.m_axil_csr_rvalid.value = 1
            n_rd += 1
            if log and n_rd <= 4:
                log.info(f"csr_slave: read 0x{ra:x}")

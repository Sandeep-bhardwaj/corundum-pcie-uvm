"""probe_axil.py - trace a BAR register read along the ACTUAL AXI-Lite topology.

Every earlier probe asked "where is the transaction now" and none asked "where
is it supposed to go". Reading mqnic_core.v and mqnic_interface.v answered the
second question, and it is not the obvious one:

    s_axil_ctrl (BAR)
      -> mqnic_core.axil_ctrl_xbar          (S = main + app)
      -> mqnic_core.axil_crossbar_inst      M_COUNT = IF_COUNT
      -> mqnic_core.axil_if_ctrl[n]         <-- masters are the INTERFACES
      -> mqnic_interface.axil_crossbar_inst M_COUNT = 7 + SCHEDULERS
      -> master 0 = m_axil_csr              <-- AXIL_CSR_BASE_ADDR = 0
      -> mqnic_core.axil_if_csr[n]
      -> mqnic_core.axil_csr_crossbar_inst  S = IF_COUNT
      -> mqnic_core.axil_csr                master CSR_XBAR_CSR_OFFSET
      -> mqnic_core.axil_reg_if_inst
      -> ctrl_reg_* -> the FW ID / PHC / CLK register blocks

So a read of offset 0 leaves the core, enters interface 0, and comes back. This
probe samples every hop on that path so the first one that never asserts is the
answer, rather than another round of guessing.
"""

import cocotb
RTL = __import__("pathlib").Path(__file__).resolve().parents[1].parent / "fpga" / "common" / "rtl" / "mqnic_core_pcie.v"
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

# The cocotb top IS mqnic_core_pcie (runner.py drives the RTL directly, not the
# SystemVerilog tb top), so `dut` is already the core wrapper.
TOP = ()
CORE = ("core_inst",)
IFACE = CORE + ("interface_inst",)

# (label, hierarchy path) - sampled every cycle, reported as "first cycle high".
HOPS = [
    ("1 bar   s_axil_ctrl_arvalid", TOP + ("s_axil_ctrl_arvalid",)),
    ("1 bar   s_axil_ctrl_arready", TOP + ("s_axil_ctrl_arready",)),
    ("2 xbar  axil_ctrl_xbar_arvalid", CORE + ("axil_ctrl_xbar_arvalid",)),
    ("2 xbar  axil_ctrl_xbar_arready", CORE + ("axil_ctrl_xbar_arready",)),
    ("3 if_in axil_if_ctrl_arvalid", CORE + ("axil_if_ctrl_arvalid",)),
    ("3 if_in axil_if_ctrl_arready", CORE + ("axil_if_ctrl_arready",)),
    ("4 ifxb  s_axil_arvalid", IFACE + ("s_axil_arvalid",)),
    ("4 ifxb  s_axil_arready", IFACE + ("s_axil_arready",)),
    ("5 ifcsr m_axil_csr_arvalid", IFACE + ("m_axil_csr_arvalid",)),
    ("5 ifcsr m_axil_csr_arready", IFACE + ("m_axil_csr_arready",)),
    ("6 csrin axil_if_csr_arvalid", CORE + ("axil_if_csr_arvalid",)),
    ("6 csrin axil_if_csr_arready", CORE + ("axil_if_csr_arready",)),
    ("7 csr   axil_csr_arvalid", CORE + ("axil_csr_arvalid",)),
    ("7 csr   axil_csr_arready", CORE + ("axil_csr_arready",)),
    ("8 reg   ctrl_reg_rd_en", CORE + ("ctrl_reg_rd_en",)),
    ("8 reg   ctrl_reg_rd_ack", CORE + ("ctrl_reg_rd_ack",)),
    ("9 back  axil_csr_rvalid", CORE + ("axil_csr_rvalid",)),
    ("9 back  s_axil_ctrl_rvalid", TOP + ("s_axil_ctrl_rvalid",)),
]


def resolve(dut, path):
    h = dut
    for p in path:
        h = getattr(h, p)
    return h


@cocotb.test()
async def probe_axil(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())

    from tieoff import drive_all_inputs, power_on_reset
    OWNED = ("clk", "rst", "pcie_rx_req_tlp_hdr", "pcie_rx_req_tlp_valid",
             "pcie_rx_req_tlp_sop", "pcie_rx_req_tlp_eop",
             "pcie_rx_req_tlp_bar_id", "pcie_rx_req_tlp_func_num",
             "pcie_tx_cpl_tlp_ready")
    drive_all_inputs(dut, RTL, "mqnic_core_pcie", skip=OWNED, log=dut._log)

    dut.pcie_rx_req_tlp_valid.value = 0
    dut.pcie_tx_cpl_tlp_ready.value = 1
    await power_on_reset(dut, dut.rst, lambda: RisingEdge(dut.clk))

    # Resolve up front so a bad path is reported as a path problem, not as a
    # signal that never asserted - the two look identical in the output.
    hops, missing = [], []
    for label, path in HOPS:
        try:
            hops.append((label, resolve(dut, path)))
        except AttributeError:
            missing.append((label, ".".join(path)))
    for label, p in missing:
        dut._log.warning(f"UNRESOLVED {label}  ({p})")

    # 3DW memory read, BAR 0, offset 0, tag 0.
    h = (0b000 << 125) | (0 << 120) | (1 << 96) | (0x0100 << 80) | (0xF << 64)
    dut.pcie_rx_req_tlp_hdr.value = h
    dut.pcie_rx_req_tlp_bar_id.value = 0
    dut.pcie_rx_req_tlp_func_num.value = 0
    dut.pcie_rx_req_tlp_valid.value = 1
    dut.pcie_rx_req_tlp_sop.value = 1
    dut.pcie_rx_req_tlp_eop.value = 1

    first = {}
    for cyc in range(3000):
        await RisingEdge(dut.clk)
        if cyc < 40 and int(dut.pcie_rx_req_tlp_ready.value):
            dut.pcie_rx_req_tlp_valid.value = 0
            dut.pcie_rx_req_tlp_sop.value = 0
            dut.pcie_rx_req_tlp_eop.value = 0
        for label, handle in hops:
            if label in first:
                continue
            try:
                v = handle.value
                if "x" in str(v) or "z" in str(v):
                    continue
                if int(v) != 0:
                    first[label] = cyc
            except Exception:
                pass

    dut._log.info("=" * 62)
    dut._log.info("AXI-Lite hop trace (first cycle each signal went non-zero)")
    dut._log.info("=" * 62)
    for label, _ in hops:
        when = first.get(label)
        dut._log.info(f"  {label:<34} {'never' if when is None else f'cycle {when}'}")
    dut._log.info("=" * 62)

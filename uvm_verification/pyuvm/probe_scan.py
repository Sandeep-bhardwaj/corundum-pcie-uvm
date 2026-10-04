"""probe_scan.py - find every X in the AXI-Lite path instead of stepping to it.

Six rounds of "probe the next signal upstream" have each answered one question
and raised another, because the X sits in a handshake LOOP: an X valid makes an
X ready which makes an X valid. Stepping around a loop does not terminate.

So this scans instead. Right after reset is released it walks the AXI-Lite
subtree, records every signal that is not fully known, and reports them grouped
by instance. The one that matters is the shallowest instance whose INPUTS are
all clean and whose OUTPUT is X - that is where the X is manufactured rather
than merely passed on.
"""

import cocotb
import pathlib
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from tieoff import drive_all_inputs, power_on_reset

RTL = pathlib.Path(__file__).resolve().parents[1].parent / "fpga" / "common" / "rtl" / "mqnic_core_pcie.v"

ROOTS = [
    ("pcie_axil_master", ("core_inst", "pcie_axil_master_inst")),
    ("core.xbar", ("core_inst", "axil_crossbar_inst")),
    ("core.csrxbar", ("core_inst", "axil_csr_crossbar_inst")),
    ("core.regif", ("core_inst", "axil_reg_if_inst")),
    ("iface.xbar", ("core_inst", "iface[0]", "interface_inst", "axil_crossbar_inst")),
    ("iface.regif", ("core_inst", "iface[0]", "interface_inst", "axil_reg_if_inst")),
]

MAX_DEPTH = 3


def resolve(dut, path):
    h = dut
    for p in path:
        h = h._id(p, extended=False) if "[" in p else getattr(h, p)
    return h


def scan(handle, name, depth, out):
    """Collect (full_name, value) for signals whose value contains x/z."""
    try:
        kids = list(handle)
    except Exception:
        kids = []
    if not kids:
        try:
            v = str(handle.value)
        except Exception:
            return
        if "x" in v.lower() or "z" in v.lower():
            out.append((name, v if len(v) <= 40 else v[:37] + "..."))
        return
    if depth <= 0:
        return
    for k in kids:
        try:
            kn = k._name
        except Exception:
            continue
        scan(k, f"{name}.{kn}", depth - 1, out)


@cocotb.test()
async def probe_scan(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    OWNED = ("clk", "rst", "pcie_rx_req_tlp_hdr", "pcie_rx_req_tlp_valid",
             "pcie_rx_req_tlp_sop", "pcie_rx_req_tlp_eop",
             "pcie_rx_req_tlp_bar_id", "pcie_rx_req_tlp_func_num",
             "pcie_tx_cpl_tlp_ready")
    drive_all_inputs(dut, RTL, "mqnic_core_pcie", skip=OWNED, log=dut._log)
    dut.pcie_rx_req_tlp_valid.value = 0
    dut.pcie_tx_cpl_tlp_ready.value = 1
    await power_on_reset(dut, dut.rst, lambda: RisingEdge(dut.clk))

    for label, path in ROOTS:
        try:
            h = resolve(dut, path)
        except Exception as e:
            dut._log.warning(f"{label}: UNRESOLVED ({type(e).__name__})")
            continue
        found = []
        scan(h, label, MAX_DEPTH, found)
        dut._log.info(f"---- {label}: {len(found)} X/Z signal(s) ----")
        for n, v in found[:25]:
            dut._log.info(f"      {n} = {v}")

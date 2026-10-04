import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from csr_slave import run_csr_slave

@cocotb.test()
async def probe(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    # SYSTEMATIC: every input named *ready on a core-MASTERED interface was
    # tied to 0 by the generated port map, and a permanently-not-ready slave
    # stalls whatever is upstream of it. Drive them all high and see whether the
    # register path comes alive - one experiment instead of one probe per port.
    n_ready = 0
    for name in dir(dut):
        if not (name.endswith("ready") or name.endswith("ack")):
            continue
        try:
            h = getattr(dut, name)
            h.value = 1
            n_ready += 1
        except Exception:
            pass
    dut._log.info(f"drove {n_ready} *ready/*ack input(s) high")

    cocotb.start_soon(run_csr_slave(dut, dut._log))
    dut.rst.value = 1
    dut.pcie_rx_req_tlp_valid.value = 0
    dut.pcie_rx_req_tlp_sop.value = 0
    dut.pcie_rx_req_tlp_eop.value = 0
    dut.pcie_tx_cpl_tlp_ready.value = 1     # ready from the start
    for _ in range(20): await RisingEdge(dut.clk)
    dut.rst.value = 0
    for _ in range(50): await RisingEdge(dut.clk)

    dut._log.info(f"after reset: rx_req_ready={int(dut.pcie_rx_req_tlp_ready.value)}")

    # Minimal 3DW memory read to BAR 0, address 0, tag 0.
    h = (0b000 << 125) | (0 << 120) | (1 << 96) | (0x0100 << 80) | (0 << 72) | (0xF << 64)
    dut.pcie_rx_req_tlp_hdr.value = h
    dut.pcie_rx_req_tlp_bar_id.value = 0
    dut.pcie_rx_req_tlp_func_num.value = 0
    dut.pcie_rx_req_tlp_valid.value = 1
    dut.pcie_rx_req_tlp_sop.value = 1
    dut.pcie_rx_req_tlp_eop.value = 1

    accepted = -1
    for i in range(200):
        await RisingEdge(dut.clk)
        if int(dut.pcie_rx_req_tlp_ready.value):
            accepted = i
            break
    dut.pcie_rx_req_tlp_valid.value = 0
    dut.pcie_rx_req_tlp_sop.value = 0
    dut.pcie_rx_req_tlp_eop.value = 0
    dut._log.info(f"request accepted after {accepted} cycles (-1 = never)")

    # Trace where the request dies inside the core.
    for nm in ("pcie_ctrl_rx_req_tlp_valid", "pcie_ctrl_tx_cpl_tlp_valid"):
        try:
            dut._log.info(f"  {nm} = {int(getattr(dut, nm).value)}")
        except Exception as e:
            dut._log.info(f"  {nm}: {e}")
    try:
        m = dut.pcie_axil_master_inst
        for nm in ("m_axil_arvalid", "m_axil_arready", "m_axil_rvalid", "m_axil_rready"):
            dut._log.info(f"  axil_master.{nm} = {int(getattr(m, nm).value)}")
    except Exception as e:
        dut._log.info(f"  axil_master probe: {e}")

    # Watch the internal AXIL over time rather than at one instant.
    m = dut.pcie_axil_master_inst
    seen = {}
    for i in range(400):
        await RisingEdge(dut.clk)
        for nm in ("m_axil_arvalid", "m_axil_arready", "m_axil_rvalid"):
            try:
                v = int(getattr(m, nm).value)
            except Exception:
                continue
            if v and nm not in seen:
                seen[nm] = i
    dut._log.info(f"axil_master activity (cycle first seen high): {seen}")
    for nm in ("ctrl_reg_rd_ack", "ctrl_reg_wr_ack"):
        try:
            dut._log.info(f"  {nm} tied = {int(getattr(dut, nm).value)}")
        except Exception as e:
            dut._log.info(f"  {nm}: n/a")

    # Which AXI-Lite slave inside mqnic_core is refusing the read?
    def probe(path, names):
        node = dut
        try:
            for part in path.split("."):
                node = getattr(node, part)
        except Exception as e:
            dut._log.info(f"  {path}: unreachable ({e})")
            return
        out = []
        for nm in names:
            try:
                out.append(f"{nm}={int(getattr(node, nm).value)}")
            except Exception:
                out.append(f"{nm}=X")
        dut._log.info(f"  {path}: " + " ".join(out))

    probe("core_inst", ["s_axil_ctrl_arvalid", "s_axil_ctrl_arready",
                        "s_axil_ctrl_rvalid"])
    probe("core_inst.axil_crossbar_inst",
          ["s_axil_arvalid", "s_axil_arready", "m_axil_arvalid", "m_axil_arready"])
    probe("core_inst.axil_csr_crossbar_inst",
          ["s_axil_arvalid", "s_axil_arready", "m_axil_arvalid", "m_axil_arready"])

    # Does the read reach the CSR master port (the only slave the TB models)?
    hit = {}
    for i in range(600):
        await RisingEdge(dut.clk)
        for nm in ("m_axil_csr_arvalid", "m_axil_csr_rvalid",
                   "ctrl_reg_rd_en", "ctrl_reg_wr_en"):
            try:
                if int(getattr(dut, nm).value) and nm not in hit:
                    hit[nm] = i
            except Exception:
                pass
    dut._log.info(f"core master-port activity: {hit}")

    cpl = -1
    for i in range(3000):
        await RisingEdge(dut.clk)
        if int(dut.pcie_tx_cpl_tlp_valid.value):
            cpl = i
            dut._log.info(f"COMPLETION at cycle {i}: "
                          f"data=0x{int(dut.pcie_tx_cpl_tlp_data.value) & 0xFFFFFFFF:08x}")
            break
    dut._log.info(f"completion after {cpl} cycles (-1 = never)")
    assert accepted >= 0, "the core never accepted the request"
    assert cpl >= 0, "the core never returned a completion"

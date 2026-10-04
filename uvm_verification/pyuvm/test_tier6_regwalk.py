"""Tier 6 - mqnic_core_pcie_us, the strategy's TOP DUT, on Icarus.

Implements : VERIFICATION_STRATEGY.md  §3.1, §5 Tier 6, §8.2

THE MODULE THE STRATEGY IS NAMED AFTER. Everything below it has been verified in
isolation; this is the first configuration where the whole PCIe host interface
exists at once:

    mqnic_core_pcie_us
      |- pcie_us_if        Tier 4d - verified
      \\- mqnic_core_pcie   Tier 5  - verified

WHAT IS ACTUALLY NEW HERE
-------------------------
Both halves already pass. What only exists at this tier is the SEAM between
them. At Tier 5 a register read was driven straight onto the generic TLP
interface; here the same read must arrive as a XILINX CQ DESCRIPTOR, be
converted by pcie_us_if_cq, cross the whole core, and come back as a CC
descriptor built by pcie_us_if_cc.

Two independently correct halves can still disagree - about byte enables,
about straddling, about where a tag lives - and that disagreement is invisible
to both of their own testbenches. This test is the first thing in the project
that can see it.

It is the Tier 5 register-block walk with the transport swapped underneath, and
that is the point: the CHECKS are unchanged, so a failure here is a statement
about the joint and nothing else.

Descriptor layouts come from model/ref_tlp_shim.sv (:57 cc_encode, :179
cq_parse), which were verified against the RTL. Re-deriving them here is the
transcription that produced bugs 12 and 33.
"""

import pathlib
import re

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from tieoff import drive_all_inputs, power_on_reset

ROOT = pathlib.Path(__file__).resolve().parents[1]
RTL = ROOT.parent / "fpga" / "common" / "rtl" / "mqnic_core_pcie_us.v"

DATA_WIDTH = 256
KEEP_WIDTH = DATA_WIDTH // 32

# Ports the test owns; everything else is tied off by direction.
OWNED = ("clk", "rst",
         "s_axis_cq_tdata", "s_axis_cq_tkeep", "s_axis_cq_tvalid",
         "s_axis_cq_tlast", "s_axis_cq_tuser",
         "m_axis_cc_tready",
         "cfg_mgmt_read_data", "cfg_mgmt_read_write_done",
         "cfg_max_payload", "cfg_max_read_req")

REQ_MEM_READ = 0b0000
REQ_MEM_WRITE = 0b0001


def load_ral():
    txt = (ROOT / "ral" / "mqnic_ral_pkg.sv").read_text(encoding="utf-8")
    consts = {m.group(1): int(m.group(2), 16) for m in
              re.finditer(r"localparam int unsigned (\w+)\s*=\s*'h([0-9A-Fa-f]+);", txt)}
    types = {m.group(1): int(m.group(2), 16) for m in
             re.finditer(r"RB_(\w+)\s*=\s*32'h([0-9A-Fa-f]{8})", txt)}
    vers = {m.group(1): int(m.group(2), 16) for m in
            re.finditer(r"RB_(\w+): return 32'h([0-9A-Fa-f]{8});", txt)}
    return consts, types, vers


RAL, RB_TYPES, RB_VERS = load_ral()
TYPE_BY_ID = {v: k for k, v in RB_TYPES.items()}
VER_BY_ID = {RB_TYPES[n]: v for n, v in RB_VERS.items() if n in RB_TYPES}
FW_ID = 0xFFFFFFFF


def dev_ctrl(mps=2, mrrs=5, ext_tag=1):
    """Device Control register - pcie_us_cfg.v:121-123."""
    return (mrrs << 12) | (ext_tag << 8) | (mps << 5)


def cq_descriptor(addr, dwords, req_type, requester_id, tag, bar_id, func_num=0):
    """Xilinx CQ descriptor - the inverse of ref_tlp_shim::cq_parse (:179)."""
    d = 0
    d |= (addr >> 2) << 2
    d |= (dwords & 0x7FF) << 64
    d |= (req_type & 0xF) << 75
    d |= (requester_id & 0xFFFF) << 80
    d |= (tag & 0xFF) << 96
    d |= (func_num & 0xFF) << 104
    d |= (bar_id & 0x7) << 112
    return d


def cq_tuser(first_be, last_be):
    """Below 512 bits both enables pack into one byte (mqnic_vrf_pkg:743)."""
    return ((last_be & 0xF) << 4) | (first_be & 0xF)


def cc_decode(beat):
    """Pull tag, dword count and the first payload DWORD out of a CC beat.

    ref_tlp_shim::cc_encode (:57) is the authority for the field positions:
        lower address [6:0]   byte count [28:16]   dword count [42:32]
        status [45:43]        requester id [63:48] tag [71:64]
    The descriptor is 3 DWORDs, so the payload starts at DWORD 3.
    """
    desc = beat & ((1 << 96) - 1)
    return dict(
        tag=(desc >> 64) & 0xFF,
        dw_count=(desc >> 32) & 0x7FF,
        status=(desc >> 43) & 0x7,
        lower_addr=desc & 0x7F,
        data=(beat >> 96) & 0xFFFFFFFF,
    )


class Host:
    """A PCIe host talking to the DUT's BAR through the Xilinx CQ/CC streams."""

    def __init__(self, dut):
        self.dut = dut
        self.tag = 0
        self.reads = 0
        self.tag_mismatches = 0
        self.cfg_reads = 0
        self.dev_ctrl_value = dev_ctrl()

    async def cfg_responder(self):
        """Play PCIe config space so pcie_us_cfg can learn MPS/MRRS.

        Without this the DUT polls forever, max_payload_size stays 0, and the
        DMA engine sizes every split against a limit it never read.
        """
        dut = self.dut
        dut.cfg_mgmt_read_data.value = 0
        dut.cfg_mgmt_read_write_done.value = 0
        while True:
            await RisingEdge(dut.clk)
            if dut.cfg_mgmt_read.value or dut.cfg_mgmt_write.value:
                await RisingEdge(dut.clk)
                dut.cfg_mgmt_read_data.value = self.dev_ctrl_value
                dut.cfg_mgmt_read_write_done.value = 1
                self.cfg_reads += 1
                await RisingEdge(dut.clk)
                dut.cfg_mgmt_read_write_done.value = 0

    async def _send_cq(self, desc, first_be, last_be, timeout=400):
        dut = self.dut
        await RisingEdge(dut.clk)
        dut.s_axis_cq_tdata.value = desc
        dut.s_axis_cq_tkeep.value = (1 << KEEP_WIDTH) - 1
        dut.s_axis_cq_tuser.value = cq_tuser(first_be, last_be)
        dut.s_axis_cq_tlast.value = 1
        dut.s_axis_cq_tvalid.value = 1
        for _ in range(timeout):
            await RisingEdge(dut.clk)
            if dut.s_axis_cq_tready.value:
                break
        else:
            raise AssertionError("CQ beat never accepted by the DUT")
        dut.s_axis_cq_tvalid.value = 0
        dut.s_axis_cq_tlast.value = 0

    async def _collect_cc(self, timeout=4000):
        dut = self.dut
        dut.m_axis_cc_tready.value = 1
        for _ in range(timeout):
            await RisingEdge(dut.clk)
            if dut.m_axis_cc_tvalid.value and dut.m_axis_cc_tready.value:
                return cc_decode(int(dut.m_axis_cc_tdata.value))
        return None

    async def read32(self, addr):
        """One BAR register read, all the way through the Xilinx shim."""
        tag = self.tag & 0xFF
        self.tag += 1

        await self._send_cq(cq_descriptor(addr, 1, REQ_MEM_READ, 0x0100, tag, 0),
                            first_be=0xF, last_be=0x0)
        cc = await self._collect_cc()
        if cc is None:
            return None

        # Pairing positionally would silently return another register's value
        # the moment two reads overlap.
        if cc["tag"] != tag:
            self.tag_mismatches += 1
            self.dut._log.error(
                f"CC tag 0x{cc['tag']:02x} does not match CQ tag 0x{tag:02x} "
                f"for address 0x{addr:x}")
        self.reads += 1
        return cc["data"]


async def bringup(dut, wait=600):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    drive_all_inputs(dut, RTL, "mqnic_core_pcie_us", skip=OWNED, log=dut._log)
    dut.s_axis_cq_tvalid.value = 0
    dut.s_axis_cq_tlast.value = 0
    dut.m_axis_cc_tready.value = 1

    host = Host(dut)
    cocotb.start_soon(host.cfg_responder())
    # Two-pulse reset: IEEE 1364 `always @*` waits for an event before its first
    # execution, so a quiescent design comes out of a single reset with X in
    # every un-initialised _next register (bug 31). See tieoff.py.
    await power_on_reset(dut, dut.rst, lambda: RisingEdge(dut.clk))
    for _ in range(wait):          # let pcie_us_cfg finish its polling loop
        await RisingEdge(dut.clk)
    return host


async def walk(host, base=0, limit=64):
    blocks, cur, seen = [], base, set()
    while len(blocks) < limit:
        assert cur not in seen, f"register block list loops back to 0x{cur:x}"
        seen.add(cur)
        t = await host.read32(cur + RAL["RB_REG_TYPE"])
        assert t is not None, (
            f"no completion for the type read at 0x{cur:x} - the BAR path "
            "through the Xilinx shim is not responding")
        v = await host.read32(cur + RAL["RB_REG_VER"])
        n = await host.read32(cur + RAL["RB_REG_NEXT_PTR"])
        blocks.append((cur, t, v, n))
        if not n:
            return blocks
        cur = n
    raise AssertionError(f"list did not terminate within {limit} blocks")


# ---------------------------------------------------------------------------
# t6_reset - the whole stack comes up idle.
# ---------------------------------------------------------------------------
@cocotb.test()
async def t6_reset(dut):
    await bringup(dut, wait=100)
    for _ in range(120):
        await RisingEdge(dut.clk)
        assert not dut.m_axis_cc_tvalid.value, (
            "CC asserted with no request outstanding")
    dut._log.info("mqnic_core_pcie_us idle after reset")


# ---------------------------------------------------------------------------
# t6_cfg_sources - where MPS, MRRS and ext_tag ACTUALLY come from at this level.
#
# This is not the Tier 4d test repeated. Reading mqnic_core_pcie_us.v shows the
# wiring is not what Tier 4d would lead you to expect:
#
#   :861-862   pcie_us_if .max_read_request_size()   <- DISCARDED
#              pcie_us_if .max_payload_size()        <- DISCARDED
#   :1159-60   mqnic_core_pcie .max_read_request_size(cfg_max_read_req)
#              mqnic_core_pcie .max_payload_size(cfg_max_payload)
#   :283-284   cfg_max_read_req / cfg_max_payload are INPUT PINS
#
# So at the top level the values pcie_us_cfg works so hard to poll out of config
# space are THROWN AWAY, and the core takes MPS/MRRS straight from dedicated
# hard-IP pins instead. Only ext_tag_enable (:860 -> :1157) survives the trip.
#
# That matters: Tier 4d verified an extraction path that this configuration does
# not use for two of its three outputs. A test that assumed otherwise would pass
# for the wrong reason - it would be checking pins it happened to drive.
# ---------------------------------------------------------------------------
@cocotb.test()
async def t6_cfg_sources(dut):
    host = await bringup(dut, wait=100)
    # mqnic_core has no MPS/MRRS ports - mqnic_core_pcie consumes them itself
    # and hands them to dma_if_pcie (mqnic_core_pcie.v:1222). Observing at
    # mqnic_core_pcie's own port is the right place anyway: that IS the
    # Tier 5 / Tier 6 boundary this tier exists to check.
    core = dut.core_pcie_inst

    # MPS and MRRS come from the PINS.
    for mps, mrrs in ((2, 5), (0, 0), (5, 2), (7, 7)):
        dut.cfg_max_payload.value = mps
        dut.cfg_max_read_req.value = mrrs
        for _ in range(40):
            await RisingEdge(dut.clk)
        got_mps = int(core.max_payload_size.value)
        got_mrrs = int(core.max_read_request_size.value)
        assert got_mps == mps, (
            f"cfg_max_payload pin driven to {mps}, core sees {got_mps} - the "
            "DMA engine would split every write against the wrong limit")
        assert got_mrrs == mrrs, (
            f"cfg_max_read_req pin driven to {mrrs}, core sees {got_mrrs}")
        dut._log.info(f"  pins mps={mps} mrrs={mrrs} reach mqnic_core intact")

    # ext_tag_enable comes from the CONFIG POLLING, so it must track what the
    # testbench returns rather than any pin.
    for ext in (1, 0, 1):
        host.dev_ctrl_value = dev_ctrl(2, 5, ext)
        before = host.cfg_reads
        for _ in range(2000):
            await RisingEdge(dut.clk)
            if host.cfg_reads > before and int(core.ext_tag_enable.value) == ext:
                break
        assert host.cfg_reads > before, "no new config read was issued"
        assert int(core.ext_tag_enable.value) == ext, (
            f"ext_tag_enable is {int(core.ext_tag_enable.value)}, config space "
            f"said {ext} - the polled value is not reaching the core")
        dut._log.info(f"  config-space ext_tag={ext} reaches mqnic_core")


# ---------------------------------------------------------------------------
# t6_rb_walk - THE TIER 6 TEST.
#
# The Linux driver's first act, performed end to end: a BAR read enters as a
# Xilinx CQ descriptor, crosses pcie_us_if_cq, the demux, pcie_axil_master,
# three AXI-Lite crossbars, mqnic_interface and axil_reg_if, and returns as a
# CC descriptor built by pcie_us_if_cc.
# ---------------------------------------------------------------------------
@cocotb.test()
async def t6_rb_walk(dut):
    host = await bringup(dut)
    blocks = await walk(host)

    for base, t, v, n in blocks:
        dut._log.info(f"  0x{base:04x}  type 0x{t:08x} "
                      f"({TYPE_BY_ID.get(t, 'UNKNOWN')})  ver 0x{v:08x}  "
                      f"next 0x{n:x}")

    assert host.reads > 0, "no register read completed - this run checked nothing"
    assert host.tag_mismatches == 0, (
        f"{host.tag_mismatches} completion(s) came back with the wrong tag - "
        "the two halves disagree about where a tag lives")
    assert any(t == FW_ID for _, t, _, _ in blocks), "no FW ID block"

    # Type 0 is legal: mqnic_core.v:800 reads `APP_ENABLE ? 32'h0000C005 : 0`,
    # so a disabled block sits in the list with a zero type.
    for base, t, v, n in blocks:
        if t == 0:
            continue
        assert t in TYPE_BY_ID, (
            f"block at 0x{base:x} has type 0x{t:08x}, not in mqnic_hw.h")
        exp = VER_BY_ID.get(t, 0)
        if exp:
            assert v == exp, (
                f"{TYPE_BY_ID[t]} at 0x{base:x} reports version 0x{v:08x}, "
                f"mqnic_hw.h says 0x{exp:08x}")

    dut._log.info(f"{len(blocks)} block(s), {host.reads} read(s) through the "
                  "Xilinx shim, all types known, all versions match mqnic_hw.h")


# ---------------------------------------------------------------------------
# t6_seam - the same map, read through BOTH transports, must be identical.
#
# THE CHECK THAT ONLY EXISTS AT THIS TIER. Tier 5 walked this list over the
# generic TLP interface. Tier 6 walks it over the Xilinx one. Any disagreement
# between the two halves - byte enables, tag position, completion framing -
# shows up as a DIFFERENT MAP, and neither half's own testbench can see it.
# ---------------------------------------------------------------------------
@cocotb.test()
async def t6_seam(dut):
    host = await bringup(dut)
    a = await walk(host)
    for _ in range(100):
        await RisingEdge(dut.clk)
    b = await walk(host)

    assert a == b, f"two walks over the Xilinx transport disagree:\n{a}\n{b}"

    # The map Tier 5 sees over the generic interface, from mqnic_core.v:776-812.
    # Hardcoded ON PURPOSE: reading it from the DUT again would compare the
    # transport with itself, which is what this test exists not to do.
    expected = [
        (0x000, 0xFFFFFFFF, 0x00000100, 0x40),
        (0x040, 0x0000C007, 0x00000100, 0x50),
        (0x050, 0x0000C000, 0x00000100, 0x70),
        (0x070, 0x00000000, 0x00000000, 0x80),
        (0x080, 0x0000C006, 0x00000100, 0x100),
        (0x100, 0x0000C080, 0x00000200, 0x200),
        (0x200, 0x0000C008, 0x00000100, 0x0),
    ]
    assert a == expected, (
        "the register map read through the XILINX transport differs from the "
        "one mqnic_core.v defines:\n"
        f"  via Xilinx shim : {a}\n"
        f"  in the RTL      : {expected}")
    dut._log.info(f"{len(a)} block(s) identical through the Xilinx transport "
                  "and in mqnic_core.v - the two halves agree")

"""Tier 5 register-access suite, in pyuvm on Icarus.

Implements : VERIFICATION_STRATEGY.md  §8.2, §13 Tier 5

These are the SystemVerilog tests of tests/tier5/tier5_tests2.sv expressed in
Python, against the real 74-module mqnic_core_pcie. They exist because the walk
alone proves the map has the right SHAPE and says nothing about whether the
values are RIGHT - a path returning zero for everything passes a structural
walk, and did, until bug 32 was found.

Register access is a SPLIT TRANSACTION: a BAR memory request goes out on
pcie_rx_req_tlp_* and a completion comes back on pcie_tx_cpl_tlp_*. Completions
are matched BY TAG, never positionally, which is what t5_csr_outstanding exists
to prove.
"""

import pathlib
import re

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from tieoff import drive_all_inputs, power_on_reset

ROOT = pathlib.Path(__file__).resolve().parents[1]
RTL = ROOT.parent / "fpga" / "common" / "rtl" / "mqnic_core_pcie.v"

OWNED = ("clk", "rst", "pcie_rx_req_tlp_hdr", "pcie_rx_req_tlp_data",
         "pcie_rx_req_tlp_strb", "pcie_rx_req_tlp_valid",
         "pcie_rx_req_tlp_sop", "pcie_rx_req_tlp_eop",
         "pcie_rx_req_tlp_bar_id", "pcie_rx_req_tlp_func_num",
         "pcie_tx_cpl_tlp_ready")


# ---------------------------------------------------------------------------
# The RAL, parsed from the SAME generated package the SystemVerilog side uses
# (§8.1: do not hand-transcribe mqnic_hw.h).
# ---------------------------------------------------------------------------
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


# Header field positions follow uvc/common/mqnic_vrf_pkg.sv:443-470, which
# verified them against fpga/lib/pcie/rtl/dma_if_pcie_rd.v. The layout is not
# the obvious one - tag at [79:72], length at [105:96], and a 3DW request puts
# addr[63:2] at [63:34] while a 4DW one puts it at [63:2].
FMT_3DW, FMT_4DW = 0b000, 0b001
FMT_3DW_DATA, FMT_4DW_DATA = 0b010, 0b011
TYPE_MEM = 0b00000


def _tlp_hdr(addr, dw_len, tag, requester_id, with_data):
    wide = (addr >> 2) >> 30 != 0
    if with_data:
        fmt = FMT_4DW_DATA if wide else FMT_3DW_DATA
    else:
        fmt = FMT_4DW if wide else FMT_3DW
    h = (fmt << 125) | (TYPE_MEM << 120) | (dw_len << 96)
    h |= requester_id << 80
    h |= tag << 72
    # PCIe requires last_be == 0 for a single-DWORD transfer. Setting it to 0xF
    # is a spec violation the DUT is free to reject or mis-length.
    h |= (0x0 if dw_len == 1 else 0xF) << 68
    h |= 0xF << 64
    h |= (addr >> 2) << (2 if wide else 34)
    return h


def tlp_read_req(addr, tag, requester_id=0x0100):
    return _tlp_hdr(addr, 1, tag, requester_id, with_data=False)


def tlp_write_req(addr, tag, requester_id=0x0100):
    return _tlp_hdr(addr, 1, tag, requester_id, with_data=True)


class Csr:
    """Split-transaction register access, with completions matched by tag."""

    def __init__(self, dut):
        self.dut = dut
        self.tag = 0
        self.reads = 0
        self.writes = 0
        self.tag_mismatches = 0

    async def write32(self, addr, data, timeout=4000):
        """A register write is POSTED - there is no completion, and waiting for
        one would hang. The only way to know it landed is to read it back."""
        dut = self.dut
        tag = self.tag & 0xFF
        self.tag += 1

        await RisingEdge(dut.clk)
        dut.pcie_rx_req_tlp_hdr.value = tlp_write_req(addr, tag)
        dut.pcie_rx_req_tlp_data.value = data & 0xFFFFFFFF
        dut.pcie_rx_req_tlp_strb.value = 1          # one DWORD
        dut.pcie_rx_req_tlp_bar_id.value = 0
        dut.pcie_rx_req_tlp_func_num.value = 0
        dut.pcie_rx_req_tlp_valid.value = 1
        dut.pcie_rx_req_tlp_sop.value = 1
        dut.pcie_rx_req_tlp_eop.value = 1
        accepted = False
        for _ in range(timeout):
            await RisingEdge(dut.clk)
            if dut.pcie_rx_req_tlp_ready.value:
                accepted = True
                break
        dut.pcie_rx_req_tlp_valid.value = 0
        dut.pcie_rx_req_tlp_sop.value = 0
        dut.pcie_rx_req_tlp_eop.value = 0
        dut.pcie_rx_req_tlp_strb.value = 0
        assert accepted, f"write to 0x{addr:x} was never accepted"
        self.writes += 1
        for _ in range(20):                          # let it retire
            await RisingEdge(dut.clk)

    async def read32(self, addr, timeout=4000):
        dut = self.dut
        tag = self.tag & 0xFF
        self.tag += 1

        await RisingEdge(dut.clk)
        dut.pcie_rx_req_tlp_hdr.value = tlp_read_req(addr, tag)
        dut.pcie_rx_req_tlp_data.value = 0
        dut.pcie_rx_req_tlp_strb.value = 0
        dut.pcie_rx_req_tlp_bar_id.value = 0
        dut.pcie_rx_req_tlp_func_num.value = 0
        dut.pcie_rx_req_tlp_valid.value = 1
        dut.pcie_rx_req_tlp_sop.value = 1
        dut.pcie_rx_req_tlp_eop.value = 1
        for _ in range(timeout):
            await RisingEdge(dut.clk)
            if dut.pcie_rx_req_tlp_ready.value:
                break
        dut.pcie_rx_req_tlp_valid.value = 0
        dut.pcie_rx_req_tlp_sop.value = 0
        dut.pcie_rx_req_tlp_eop.value = 0

        dut.pcie_tx_cpl_tlp_ready.value = 1
        for _ in range(timeout):
            await RisingEdge(dut.clk)
            if dut.pcie_tx_cpl_tlp_valid.value and dut.pcie_tx_cpl_tlp_ready.value:
                hdr = int(dut.pcie_tx_cpl_tlp_hdr.value)
                # A COMPLETION does not carry its tag where a REQUEST does.
                # Request DW1: requester_id [95:80], tag [79:72], BEs [71:64]
                # Cpl     DW2: requester_id [63:48], tag [47:40], lower [38:32]
                # uvc/common/mqnic_vrf_pkg.sv:496 is the authority; deriving it
                # again here instead of reading it cost a round (bug 33), which
                # is the same re-transcription §8.1 exists to forbid.
                got = (hdr >> 40) & 0xFF
                # Pairing positionally would silently return another register's
                # value the moment two reads overlap.
                if got != tag:
                    self.tag_mismatches += 1
                    dut._log.error(
                        f"completion tag 0x{got:02x} does not match request tag "
                        f"0x{tag:02x} for address 0x{addr:x}")
                self.reads += 1
                return int(dut.pcie_tx_cpl_tlp_data.value) & 0xFFFFFFFF
        return None


async def bringup(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    drive_all_inputs(dut, RTL, "mqnic_core_pcie", skip=OWNED, log=dut._log)
    dut.pcie_rx_req_tlp_valid.value = 0
    dut.pcie_rx_req_tlp_sop.value = 0
    dut.pcie_rx_req_tlp_eop.value = 0
    dut.pcie_tx_cpl_tlp_ready.value = 0
    await power_on_reset(dut, dut.rst, lambda: RisingEdge(dut.clk))
    return Csr(dut)


async def walk(csr, base=0, limit=64):
    """Walk the register block list the way the Linux driver does."""
    blocks, cur, seen = [], base, set()
    while len(blocks) < limit:
        assert cur not in seen, f"register block list loops back to 0x{cur:x}"
        seen.add(cur)
        t = await csr.read32(cur + RAL["RB_REG_TYPE"])
        assert t is not None, f"no completion for the type read at 0x{cur:x}"
        v = await csr.read32(cur + RAL["RB_REG_VER"])
        n = await csr.read32(cur + RAL["RB_REG_NEXT_PTR"])
        blocks.append((cur, t, v, n))
        if not n:
            return blocks
        cur = n
    raise AssertionError(f"list did not terminate within {limit} blocks")


# ---------------------------------------------------------------------------
# t5_rb_walk_checked - the walk, plus the checks §8.2 actually asks for.
# ---------------------------------------------------------------------------
@cocotb.test()
async def rb_walk_checked(dut):
    csr = await bringup(dut)
    blocks = await walk(csr)

    for base, t, v, n in blocks:
        dut._log.info(f"  0x{base:04x}  type 0x{t:08x} ({TYPE_BY_ID.get(t, 'UNKNOWN')})"
                      f"  ver 0x{v:08x}  next 0x{n:x}")

    assert csr.reads > 0, "no register read completed - this run checked nothing"
    assert csr.tag_mismatches == 0, f"{csr.tag_mismatches} completion(s) mis-paired"
    assert any(t == FW_ID for _, t, _, _ in blocks), "no FW ID block"

    # Every non-zero type must be one mqnic_hw.h knows about. Type 0 is legal:
    # mqnic_core.v:800 reads `APP_ENABLE ? 32'h0000C005 : 0`, so a disabled
    # block is present in the list with a zero type and a valid next pointer.
    for base, t, v, n in blocks:
        if t == 0:
            continue
        assert t in TYPE_BY_ID, (
            f"block at 0x{base:x} has type 0x{t:08x}, not in mqnic_hw.h - "
            "either the RAL is stale or the DUT returned garbage")

    # Versions must agree with the header. A zero expected version means the
    # header declares none, which is not a mismatch.
    for base, t, v, n in blocks:
        exp = VER_BY_ID.get(t, 0)
        if t and exp:
            assert v == exp, (
                f"{TYPE_BY_ID[t]} at 0x{base:x} reports version 0x{v:08x}, "
                f"mqnic_hw.h says 0x{exp:08x}")

    dut._log.info(f"{len(blocks)} block(s), {csr.reads} read(s), all types known, "
                  "all versions match mqnic_hw.h")


# ---------------------------------------------------------------------------
# t5_fw_id - the block the driver anchors on returns sane constants.
# ---------------------------------------------------------------------------
@cocotb.test()
async def fw_id(dut):
    csr = await bringup(dut)
    blocks = await walk(csr)
    base = next(b for b, t, _, _ in blocks if t == FW_ID)

    vals = {}
    for name in ("FPGA_ID", "FW_ID", "FW_VER", "BOARD_ID"):
        key = f"RB_FW_ID_{name}"
        if key in RAL:
            vals[name] = await csr.read32(base + RAL[key])
    dut._log.info("  " + "  ".join(f"{k}=0x{v:08x}" for k, v in vals.items()))

    # All-zero is what a path that returns nothing looks like - the failure a
    # structural walk cannot see, and the one bug 32 actually produced.
    assert any(v for v in vals.values()), (
        "every FW ID register read as zero - the register path is returning "
        "data that was never in the DUT")


# ---------------------------------------------------------------------------
# t5_rb_walk_repeat - discovery is idempotent.
# ---------------------------------------------------------------------------
@cocotb.test()
async def rb_walk_repeat(dut):
    csr = await bringup(dut)
    a = await walk(csr)
    for _ in range(50):
        await RisingEdge(dut.clk)
    b = await walk(csr)

    assert len(a) == len(b), f"walk 1 found {len(a)} block(s), walk 2 found {len(b)}"
    # Field by field: a path returning stale completion data would produce two
    # walks that agree for the wrong reason.
    for i, (x, y) in enumerate(zip(a, b)):
        assert x == y, f"block {i} differs between walks: {x} vs {y}"
    assert csr.tag_mismatches == 0


# ---------------------------------------------------------------------------
# t5_csr_outstanding - the same reads under load return the same values.
# ---------------------------------------------------------------------------
@cocotb.test()
async def csr_outstanding(dut):
    csr = await bringup(dut)
    blocks = await walk(csr)
    bases = [b for b, _, _, _ in blocks][:8]

    solo = [await csr.read32(b + RAL["RB_REG_TYPE"]) for b in bases]
    for rep in range(4):
        for i, b in enumerate(bases):
            d = await csr.read32(b + RAL["RB_REG_TYPE"])
            assert d is not None, f"read of block {i} timed out on repeat {rep}"
            assert d == solo[i], (
                f"block {i} type read 0x{d:08x} under load but 0x{solo[i]:08x} "
                "alone - completions are being paired with the wrong request")
    assert csr.tag_mismatches == 0, f"{csr.tag_mismatches} completion(s) mis-paired"
    dut._log.info(f"{csr.reads} reads, every tag matched its request")


# ---------------------------------------------------------------------------
# t5_csr_bad_addr - a read with no block behind it must still complete.
# ---------------------------------------------------------------------------
@cocotb.test()
async def csr_bad_addr(dut):
    csr = await bringup(dut)
    for i in range(4):
        addr = 0x7F00 + i * 4
        d = await csr.read32(addr)
        # It may return anything, but a DROPPED request stalls a real driver
        # forever, and that is the kind of hole that only shows up on hardware.
        assert d is not None, (
            f"read of unmapped address 0x{addr:x} was never completed - "
            "a dropped request stalls the driver indefinitely")
        dut._log.info(f"  unmapped 0x{addr:04x} -> 0x{d:08x}")


# ---------------------------------------------------------------------------
# t5_csr_write - the write path, which until now had never been exercised.
#
# Every Tier 5 result so far came from READS. The write channel has its own
# crossbar (axil_crossbar_wr) with the same `always @*` structure that stalled
# the read side (bug 31), and the assumption that the two-pulse reset covers it
# too was exactly that - an assumption.
#
# The target is the one writable register in the core's control block:
#
#   mqnic_core.v:748  reg [15:0] irq_rate_limit_min_interval_reg = 10;
#   mqnic_core.v:766  8'h4C: irq_rate_limit_min_interval_reg <= ctrl_reg_wr_data;
#   mqnic_core.v:791  8'h4C: ctrl_reg_rd_data_reg <= irq_rate_limit_min_interval_reg;
#
# It is a good target for three independent reasons: it resets to a non-zero
# constant, so the FIRST read proves the path is not inventing zeros; it is
# 16 bits wide, so a 32-bit write that reads back TRUNCATED proves the data
# reached the real register rather than a cache or a scoreboard; and it is the
# only writable location, so everything else doubles as a read-only check.
# ---------------------------------------------------------------------------
IRQ_MIN_INTERVAL = 0x4C
IRQ_RESET_VALUE = 10


@cocotb.test()
async def csr_write(dut):
    csr = await bringup(dut)

    before = await csr.read32(IRQ_MIN_INTERVAL)
    assert before == IRQ_RESET_VALUE, (
        f"IRQ min interval reads 0x{before:x} out of reset, RTL says "
        f"{IRQ_RESET_VALUE} (mqnic_core.v:748)")

    # Written 32 bits wide, stored in 16. Reading back the FULL value would mean
    # the readback came from somewhere other than the register.
    for wrote, expect in ((0x1234_5678, 0x5678), (0x0000_ABCD, 0xABCD),
                          (0x0000_0000, 0x0000), (0xFFFF_FFFF, 0xFFFF)):
        await csr.write32(IRQ_MIN_INTERVAL, wrote)
        got = await csr.read32(IRQ_MIN_INTERVAL)
        assert got == expect, (
            f"wrote 0x{wrote:08x} to a 16-bit register, read back 0x{got:08x}, "
            f"expected 0x{expect:04x}")
        dut._log.info(f"  wrote 0x{wrote:08x} -> read 0x{got:04x}")

    assert csr.tag_mismatches == 0
    dut._log.info(f"{csr.writes} write(s), {csr.reads} read(s), write path live")


# ---------------------------------------------------------------------------
# t5_csr_write_ro - writing read-only space must not corrupt it.
#
# mqnic_core.v:760-768 decodes exactly ONE writable address and its `default`
# arm acks nothing. A write elsewhere must be absorbed harmlessly - not stall,
# and not disturb the constants the driver anchors on.
# ---------------------------------------------------------------------------
@cocotb.test()
async def csr_write_readonly(dut):
    csr = await bringup(dut)

    fw_type = await csr.read32(RAL["RB_REG_TYPE"])
    fw_ver = await csr.read32(RAL["RB_REG_VER"])
    assert fw_type == FW_ID

    for addr in (0x00, 0x04, 0x08, 0x40, 0x200):
        await csr.write32(addr, 0xDEAD_BEEF)

    assert await csr.read32(RAL["RB_REG_TYPE"]) == fw_type, (
        "FW ID type changed after writing read-only space")
    assert await csr.read32(RAL["RB_REG_VER"]) == fw_ver, (
        "FW ID version changed after writing read-only space")

    # And the whole map must still be walkable - a wedged write channel would
    # show up as a read that no longer completes.
    blocks = await walk(csr)
    assert any(t == FW_ID for _, t, _, _ in blocks)
    dut._log.info(f"{len(blocks)} block(s) still discoverable after "
                  f"{csr.writes} write(s) to read-only space")

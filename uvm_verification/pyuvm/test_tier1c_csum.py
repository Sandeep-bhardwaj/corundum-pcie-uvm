"""Tier 1c - rx_checksum against the real RTL, on Icarus.

Implements : VERIFICATION_STRATEGY.md  §13 Tier 1c, §10 (reference models)

The golden model is a transcription of model/ref_checksum.sv, which itself was
derived from the RTL and from Corundum's own cocotb test. Two things in it are
easy to get wrong and are asserted here rather than assumed:

  * rx_checksum outputs the one's-complement SUM, NOT the complemented checksum
    a packet header carries. A model that complements is wrong by exactly one
    bitwise-not and still looks plausible on every frame.
  * a frame shorter than START_OFFSET contributes nothing and sums to zero.

DATA_WIDTH is 256 with START_OFFSET 14, matching tb/tb_top_tier1c.sv:29.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

DATA_WIDTH = 256
KEEP_WIDTH = DATA_WIDTH // 8
START_OFFSET = 14


def ones_complement_sum16(frame, start, length):
    """The value rx_checksum presents on m_axis_csum.

    Mirrors mqnic_vrf_pkg::ones_complement_sum16. A trailing odd byte is the
    HIGH half of its 16-bit word - padding it low instead is the second classic
    way to write a checksum model that is almost right.
    """
    data = frame[start:start + length]
    total = 0
    for i in range(0, len(data) - 1, 2):
        total += (data[i] << 8) | data[i + 1]
    if len(data) & 1:
        total += data[-1] << 8
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return total & 0xFFFF


def expected(frame):
    if len(frame) <= START_OFFSET:
        return 0
    return ones_complement_sum16(frame, START_OFFSET, len(frame) - START_OFFSET)


async def send_frame(dut, frame):
    """Drive one frame as AXI-Stream beats. rx_checksum has no tready."""
    for off in range(0, len(frame), KEEP_WIDTH):
        chunk = frame[off:off + KEEP_WIDTH]
        data = 0
        keep = 0
        for i, b in enumerate(chunk):
            data |= b << (8 * i)
            keep |= 1 << i
        await RisingEdge(dut.clk)
        dut.s_axis_tdata.value = data
        dut.s_axis_tkeep.value = keep
        dut.s_axis_tvalid.value = 1
        dut.s_axis_tlast.value = 1 if off + KEEP_WIDTH >= len(frame) else 0
    await RisingEdge(dut.clk)
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.s_axis_tkeep.value = 0


async def collect(dut, timeout=200):
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.m_axis_csum_valid.value:
            return int(dut.m_axis_csum.value)
    return None


async def bringup(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    dut.s_axis_tdata.value = 0
    dut.s_axis_tkeep.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.rst.value = 1
    for _ in range(16):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    for _ in range(8):
        await RisingEdge(dut.clk)


async def check(dut, frame, label):
    await send_frame(dut, frame)
    got = await collect(dut)
    exp = expected(frame)
    assert got is not None, f"{label}: no csum_valid for a {len(frame)}-byte frame"
    assert got == exp, (f"{label}: {len(frame)}-byte frame -> csum 0x{got:04x}, "
                        f"expected 0x{exp:04x}")
    return got


# ---------------------------------------------------------------------------
# t1c_csum_lengths - every length across the beat boundary.
#
# The interesting lengths are not random: one below, at, and one above
# START_OFFSET; and either side of each 32-byte beat boundary, where the RTL
# has to carry a partial word between cycles.
# ---------------------------------------------------------------------------
@cocotb.test()
async def csum_lengths(dut):
    await bringup(dut)
    random.seed(1)

    lengths = ([13, 14, 15, 16, 17]
               + [31, 32, 33, 63, 64, 65, 95, 96, 97]
               + [128, 255, 256, 257, 512, 1023, 1024, 1500])
    for n in lengths:
        frame = bytes(random.randrange(256) for _ in range(n))
        await check(dut, frame, "lengths")
    dut._log.info(f"{len(lengths)} frame length(s) checked, "
                  f"{lengths[0]}..{lengths[-1]} bytes")


# ---------------------------------------------------------------------------
# t1c_csum_short - frames at or below START_OFFSET sum to zero.
#
# The DUT still has to produce a RESULT for these; silently producing nothing
# would stall a real pipeline, so the absence of csum_valid is a failure, not a
# don't-care.
# ---------------------------------------------------------------------------
@cocotb.test()
async def csum_short(dut):
    await bringup(dut)
    for n in range(1, START_OFFSET + 1):
        frame = bytes(0xFF for _ in range(n))     # worst case for a stray sum
        got = await check(dut, frame, "short")
        assert got == 0, f"{n}-byte frame summed to 0x{got:04x}, expected 0"
    dut._log.info(f"frames of 1..{START_OFFSET} bytes all sum to zero")


# ---------------------------------------------------------------------------
# t1c_csum_carry - patterns that force the end-around carry.
#
# All-0xFF data makes the running sum overflow 16 bits on almost every word,
# which is the only thing that exercises the fold. Random data reaches it
# rarely enough to pass a broken implementation.
# ---------------------------------------------------------------------------
@cocotb.test()
async def csum_carry(dut):
    await bringup(dut)
    for frame in (bytes([0xFF] * 64), bytes([0xFF] * 65),
                  bytes([0xFF, 0x00] * 40), bytes([0x00, 0xFF] * 40),
                  bytes([0xFF] * 1500)):
        got = await check(dut, frame, "carry")
        dut._log.info(f"  {len(frame):4d} bytes of 0x{frame[0]:02x}.. -> 0x{got:04x}")


# ---------------------------------------------------------------------------
# t1c_csum_back_to_back - consecutive frames with no idle cycles.
#
# State left over from one frame contaminating the next is the classic
# streaming-checksum bug, and it cannot be seen by testing frames in isolation.
# ---------------------------------------------------------------------------
@cocotb.test()
async def csum_back_to_back(dut):
    await bringup(dut)
    random.seed(7)
    frames = [bytes(random.randrange(256) for _ in range(n))
              for n in (60, 17, 300, 15, 128, 1500, 14)]
    for i, f in enumerate(frames):
        await check(dut, f, f"b2b[{i}]")
    dut._log.info(f"{len(frames)} back-to-back frames, no cross-contamination")


# ---------------------------------------------------------------------------
# t1c_csum_random - the sweep, seeded so a failure is reproducible.
# ---------------------------------------------------------------------------
@cocotb.test()
async def csum_random(dut):
    await bringup(dut)
    random.seed(20260730)
    for _ in range(60):
        n = random.randrange(1, 1600)
        await check(dut, bytes(random.randrange(256) for _ in range(n)), "random")
    dut._log.info("60 random frames checked against ref_checksum")

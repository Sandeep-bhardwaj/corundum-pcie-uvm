"""Tier 1b - pcie_tlp_demux_bar against the real RTL, on Icarus.

Implements : VERIFICATION_STRATEGY.md  §13 Tier 1b

The DUT routes a TLP to an output port by BAR ID. tb_top_tier1b.sv configures
PORTS=2, BAR_BASE=0, BAR_STRIDE=2, so calcBarIds gives

    port 0 <- bar_id 0        port 1 <- bar_id 2

and the match is an EXACT COMPARE (pcie_tlp_demux_bar.v:160), not a range. BAR
IDs 1, 3, 4 and 5 therefore match no port at all, and pcie_tlp_demux.v:282
sets drop for them: the TLP is ACCEPTED on the input and forwarded nowhere.

That drop path is the interesting one. A demux that stalled instead would
deadlock the whole PCIe ingress on a single stray BAR ID, and it is invisible
unless a test deliberately sends one.

FIFO_ENABLE is 0, so this is the stateless demux with no buffering - a routing
failure cannot be confused with a FIFO failure.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

PORTS = 2
TLP_DATA_WIDTH = 256
TLP_STRB_WIDTH = TLP_DATA_WIDTH // 32
TLP_HDR_WIDTH = 128

# bar_id -> expected port, or None for "dropped". From BAR_BASE=0, BAR_STRIDE=2.
ROUTE = {0: 0, 1: None, 2: 1, 3: None, 4: None, 5: None}


async def bringup(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    for sig, val in (("in_tlp_data", 0), ("in_tlp_strb", 0), ("in_tlp_hdr", 0),
                     ("in_tlp_seq", 0), ("in_tlp_bar_id", 0),
                     ("in_tlp_func_num", 0), ("in_tlp_error", 0),
                     ("in_tlp_valid", 0), ("in_tlp_sop", 0), ("in_tlp_eop", 0),
                     ("out_tlp_ready", (1 << PORTS) - 1), ("enable", 1)):
        getattr(dut, sig).value = val
    dut.rst.value = 1
    for _ in range(16):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    for _ in range(8):
        await RisingEdge(dut.clk)


async def send_tlp(dut, bar_id, hdr, beats=1, timeout=200):
    """Drive one TLP and record which output ports saw a valid beat.

    Sampling happens on the SAME cycles the input is driven, because with
    FIFO_ENABLE=0 the demux is registered once - a port that only asserts after
    the input has gone idle would be a different bug, and the trailing drain
    loop below would catch it.
    """
    seen = {p: 0 for p in range(PORTS)}
    captured = {}

    async def sample():
        v = int(dut.out_tlp_valid.value)
        for p in range(PORTS):
            if v & (1 << p):
                seen[p] += 1
                if p not in captured:
                    h = int(dut.out_tlp_hdr.value)
                    captured[p] = (h >> (p * TLP_HDR_WIDTH)) & ((1 << TLP_HDR_WIDTH) - 1)

    for b in range(beats):
        await RisingEdge(dut.clk)
        dut.in_tlp_hdr.value = hdr
        dut.in_tlp_bar_id.value = bar_id
        dut.in_tlp_data.value = 0xA5A5A5A5 + b
        dut.in_tlp_strb.value = 1
        dut.in_tlp_valid.value = 1
        dut.in_tlp_sop.value = 1 if b == 0 else 0
        dut.in_tlp_eop.value = 1 if b == beats - 1 else 0
        # Hold until accepted.
        for _ in range(timeout):
            await RisingEdge(dut.clk)
            await sample()
            if dut.in_tlp_ready.value:
                break
        else:
            raise AssertionError(f"input never accepted (bar_id={bar_id})")

    dut.in_tlp_valid.value = 0
    dut.in_tlp_sop.value = 0
    dut.in_tlp_eop.value = 0
    for _ in range(6):
        await RisingEdge(dut.clk)
        await sample()
    return seen, captured


# ---------------------------------------------------------------------------
# t1b_route - each BAR ID reaches exactly its own port.
# ---------------------------------------------------------------------------
@cocotb.test()
async def demux_route(dut):
    await bringup(dut)
    for bar_id, want in ROUTE.items():
        hdr = 0x1234_0000_0000_0000_0000_0000_0000_0000 | bar_id
        seen, captured = await send_tlp(dut, bar_id, hdr)
        if want is None:
            assert sum(seen.values()) == 0, (
                f"bar_id {bar_id} matches no port but reached {seen} - "
                "an unrouted TLP must be dropped, not misdelivered")
        else:
            other = [p for p in range(PORTS) if p != want]
            assert seen[want] > 0, f"bar_id {bar_id} never reached port {want}"
            for p in other:
                assert seen[p] == 0, (
                    f"bar_id {bar_id} routed to port {want} ALSO reached port {p}")
            assert captured[want] == hdr, (
                f"port {want} header 0x{captured[want]:032x} != sent 0x{hdr:032x}")
        dut._log.info(f"  bar_id {bar_id} -> "
                      f"{'dropped' if want is None else f'port {want}'}  {seen}")


# ---------------------------------------------------------------------------
# t1b_drop_no_stall - an unmatched BAR ID must not wedge the input.
#
# This is the failure that matters. A stray BAR ID on a real link is a
# configuration error, not a fatal one, and a demux that stalls on it takes the
# entire PCIe ingress path down with it.
# ---------------------------------------------------------------------------
@cocotb.test()
async def demux_drop_no_stall(dut):
    await bringup(dut)
    for bar_id in (1, 3, 4, 5):
        seen, _ = await send_tlp(dut, bar_id, 0xDEAD)
        assert sum(seen.values()) == 0, f"dropped bar_id {bar_id} still emitted"
    # And the path still works afterwards.
    seen, _ = await send_tlp(dut, 0, 0xBEEF)
    assert seen[0] > 0, "port 0 stopped working after four dropped TLPs"
    dut._log.info("four unmatched BAR IDs dropped, routing still live")


# ---------------------------------------------------------------------------
# t1b_multibeat - the routing decision is made at SOP and held to EOP.
#
# pcie_tlp_demux.v:279-288 latches select on sop only. A multi-beat TLP whose
# middle beats went somewhere else would corrupt two streams at once, and a
# single-beat test can never see it.
# ---------------------------------------------------------------------------
@cocotb.test()
async def demux_multibeat(dut):
    await bringup(dut)
    for bar_id, want in ((0, 0), (2, 1)):
        for beats in (2, 3, 8):
            seen, _ = await send_tlp(dut, bar_id, 0xC0FFEE, beats=beats)
            assert seen[want] == beats, (
                f"{beats}-beat TLP on bar_id {bar_id}: port {want} saw "
                f"{seen[want]} beat(s)")
            for p in range(PORTS):
                if p != want:
                    assert seen[p] == 0, f"beats leaked to port {p}"
            dut._log.info(f"  bar_id {bar_id}, {beats} beats -> port {want} intact")


# ---------------------------------------------------------------------------
# t1b_interleave - consecutive TLPs alternating between ports.
#
# Stale select state from the previous frame is the classic demux bug and only
# shows up when the destination changes every frame.
# ---------------------------------------------------------------------------
@cocotb.test()
async def demux_interleave(dut):
    await bringup(dut)
    order = [0, 2, 0, 2, 2, 0, 1, 0, 2, 3, 2, 0]
    for i, bar_id in enumerate(order):
        want = ROUTE[bar_id]
        seen, _ = await send_tlp(dut, bar_id, 0x1000 + i)
        if want is None:
            assert sum(seen.values()) == 0, f"[{i}] bar {bar_id} should drop"
        else:
            assert seen[want] > 0, f"[{i}] bar {bar_id} missed port {want}"
            for p in range(PORTS):
                if p != want:
                    assert seen[p] == 0, f"[{i}] bar {bar_id} leaked to port {p}"
    dut._log.info(f"{len(order)} interleaved TLPs routed correctly")


# ---------------------------------------------------------------------------
# t1b_disabled - enable low means nothing is accepted at all.
#
# pcie_tlp_demux.v:154 gates in_tlp_ready with enable.
# ---------------------------------------------------------------------------
@cocotb.test()
async def demux_disabled(dut):
    await bringup(dut)
    dut.enable.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.in_tlp_hdr.value = 0x5555
    dut.in_tlp_bar_id.value = 0
    dut.in_tlp_valid.value = 1
    dut.in_tlp_sop.value = 1
    dut.in_tlp_eop.value = 1
    accepted = False
    for _ in range(40):
        await RisingEdge(dut.clk)
        if dut.in_tlp_ready.value:
            accepted = True
        assert int(dut.out_tlp_valid.value) == 0, "output valid while disabled"
    assert not accepted, "input accepted while enable was low"

    dut.enable.value = 1
    for _ in range(40):
        await RisingEdge(dut.clk)
        if dut.in_tlp_ready.value:
            break
    else:
        raise AssertionError("input never accepted after re-enable")
    dut.in_tlp_valid.value = 0
    dut.in_tlp_sop.value = 0
    dut.in_tlp_eop.value = 0
    dut._log.info("disabled demux accepts nothing and recovers on re-enable")

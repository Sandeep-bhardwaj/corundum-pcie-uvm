"""Tier 1a - cpl_queue_manager against the real RTL, on Icarus.

Implements : VERIFICATION_STRATEGY.md  §13 Tier 1a

The completion queue manager is the mirror of queue_manager: the host is the
CONSUMER, so the DUT hands out ENQUEUE slots and reports FULL rather than empty.
Two differences bite anyone porting the descriptor-queue test:

  * FOUR dwords per queue, not eight - AXIL_ADDR_WIDTH is QUEUE_INDEX_WIDTH+4,
    so the register address is (q << 4) | (r << 2). Using the descriptor
    queue's << 5 addresses every OTHER queue and still looks plausible.
  * the response field is `full`, not `empty`, and the pointer the host moves is
    the CONSUMER pointer (0x8090_0000), not the producer pointer.

Encoding taken from tests/tier1a/tier1a_tests.sv:41-70; parameters from
tb/tb_top_tier1a.sv:51-55.

ARMING AND EVENTS: a completion queue can be ARMED (0x4000_0200), and an
enqueue on an armed queue emits an event and disarms it. That one-shot
behaviour is the thing worth testing - a queue that stayed armed would storm
the event path.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

CMD_SET_SIZE = 0x8002_0000
CMD_SET_EQN = 0xC000_0000
CMD_SET_ENABLE = 0x4000_0100
CMD_SET_ARM = 0x4000_0200
CMD_SET_CONS_PTR = 0x8090_0000
CMD_SET_CONS_PTR_ARM = 0x8091_0000


def cq_reg_addr(q, r):
    """FOUR dwords per queue - see the module docstring."""
    return (q << 4) | (r << 2)


class Cqm:
    def __init__(self, dut):
        self.dut = dut
        self.events = []

    async def axil_write(self, addr, data, timeout=200):
        dut = self.dut
        await RisingEdge(dut.clk)
        dut.s_axil_awaddr.value = addr
        dut.s_axil_awvalid.value = 1
        dut.s_axil_wdata.value = data
        dut.s_axil_wstrb.value = 0xF
        dut.s_axil_wvalid.value = 1
        dut.s_axil_bready.value = 1
        aw = w = False
        for _ in range(timeout):
            await RisingEdge(dut.clk)
            if not aw and dut.s_axil_awready.value:
                aw = True
                dut.s_axil_awvalid.value = 0
            if not w and dut.s_axil_wready.value:
                w = True
                dut.s_axil_wvalid.value = 0
            if aw and w:
                break
        assert aw and w, f"AXI-Lite write to 0x{addr:x} was never accepted"
        for _ in range(timeout):
            await RisingEdge(dut.clk)
            if dut.s_axil_bvalid.value:
                return
        raise AssertionError(f"no write response for 0x{addr:x}")

    async def configure(self, q, base_addr, log_size, eqn, enable=True):
        await self.axil_write(cq_reg_addr(q, 0), base_addr & 0xFFFFFFFF)
        await self.axil_write(cq_reg_addr(q, 1), (base_addr >> 32) & 0xFFFFFFFF)
        await self.axil_write(cq_reg_addr(q, 2), CMD_SET_SIZE | log_size)
        await self.axil_write(cq_reg_addr(q, 2), CMD_SET_EQN | eqn)
        if enable:
            await self.axil_write(cq_reg_addr(q, 2), CMD_SET_ENABLE | 1)

    async def set_arm(self, q, armed):
        await self.axil_write(cq_reg_addr(q, 2), CMD_SET_ARM | (1 if armed else 0))

    async def set_cons_ptr(self, q, ptr, arm=False):
        cmd = CMD_SET_CONS_PTR_ARM if arm else CMD_SET_CONS_PTR
        await self.axil_write(cq_reg_addr(q, 2), cmd | ptr)

    async def enqueue(self, q, tag, timeout=400):
        dut = self.dut
        await RisingEdge(dut.clk)
        dut.s_axis_enqueue_req_queue.value = q
        dut.s_axis_enqueue_req_tag.value = tag
        dut.s_axis_enqueue_req_valid.value = 1
        dut.m_axis_enqueue_resp_ready.value = 1
        for _ in range(timeout):
            await RisingEdge(dut.clk)
            if dut.s_axis_enqueue_req_ready.value:
                break
        else:
            raise AssertionError(f"enqueue request for cq {q} never accepted")
        dut.s_axis_enqueue_req_valid.value = 0

        for _ in range(timeout):
            await RisingEdge(dut.clk)
            if dut.m_axis_enqueue_resp_valid.value:
                return dict(
                    queue=int(dut.m_axis_enqueue_resp_queue.value),
                    ptr=int(dut.m_axis_enqueue_resp_ptr.value),
                    addr=int(dut.m_axis_enqueue_resp_addr.value),
                    event=int(dut.m_axis_enqueue_resp_event.value),
                    tag=int(dut.m_axis_enqueue_resp_tag.value),
                    op_tag=int(dut.m_axis_enqueue_resp_op_tag.value),
                    full=int(dut.m_axis_enqueue_resp_full.value),
                    error=int(dut.m_axis_enqueue_resp_error.value),
                )
        raise AssertionError(
            f"no enqueue response for cq {q} tag {tag} - a dropped request "
            "stalls the completion write path forever")

    async def _event_monitor(self):
        """Sample m_axis_event EVERY cycle, forever.

        The event is emitted from the commit-FINISH path
        (cpl_queue_manager.v:394), which is gated on the op table draining and
        so does not land a fixed number of cycles after anything the test does.
        Sampling in windows around the stimulus missed it entirely and looked
        like a DUT that never fired. A monitor cannot miss what it is not
        looking for, because it is always looking.
        """
        dut = self.dut
        while True:
            await RisingEdge(dut.clk)
            if dut.m_axis_event_valid.value and dut.m_axis_event_ready.value:
                self.events.append((int(dut.m_axis_event.value),
                                    int(dut.m_axis_event_source.value)))

    async def commit(self, op_tag, timeout=200):
        dut = self.dut
        await RisingEdge(dut.clk)
        dut.s_axis_enqueue_commit_op_tag.value = op_tag
        dut.s_axis_enqueue_commit_valid.value = 1
        for _ in range(timeout):
            await RisingEdge(dut.clk)
            if dut.s_axis_enqueue_commit_ready.value:
                dut.s_axis_enqueue_commit_valid.value = 0
                for _ in range(30):        # let the op table drain and fire
                    await RisingEdge(dut.clk)
                return
        raise AssertionError(f"commit of op_tag {op_tag} never accepted")


async def bringup(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    for sig in ("s_axil_awaddr", "s_axil_awprot", "s_axil_awvalid", "s_axil_wdata",
                "s_axil_wstrb", "s_axil_wvalid", "s_axil_araddr", "s_axil_arprot",
                "s_axil_arvalid", "s_axis_enqueue_req_queue",
                "s_axis_enqueue_req_tag", "s_axis_enqueue_req_valid",
                "s_axis_enqueue_commit_op_tag", "s_axis_enqueue_commit_valid"):
        try:
            getattr(dut, sig).value = 0
        except AttributeError:
            pass
    dut.s_axil_bready.value = 1
    dut.s_axil_rready.value = 1
    dut.m_axis_enqueue_resp_ready.value = 1
    try:
        dut.m_axis_event_ready.value = 1
    except AttributeError:
        pass
    dut.rst.value = 1
    for _ in range(16):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    for _ in range(8):
        await RisingEdge(dut.clk)
    try:
        dut.enable.value = 1
    except AttributeError:
        pass
    for _ in range(4):
        await RisingEdge(dut.clk)
    cq = Cqm(dut)
    cocotb.start_soon(cq._event_monitor())
    return cq


# ---------------------------------------------------------------------------
# t1a_cq_reset
# ---------------------------------------------------------------------------
@cocotb.test()
async def cqm_reset(dut):
    await bringup(dut)
    for _ in range(60):
        await RisingEdge(dut.clk)
        assert not dut.m_axis_enqueue_resp_valid.value, (
            "enqueue response with no request outstanding")
        assert not dut.m_axis_event_valid.value, (
            "event emitted with no queue configured")
    dut._log.info("idle after reset: no responses, no events")


# ---------------------------------------------------------------------------
# t1a_cq_enqueue_basic - slots are handed out in order and the ring fills.
# ---------------------------------------------------------------------------
@cocotb.test()
async def cqm_enqueue_basic(dut):
    cq = await bringup(dut)
    Q, LOG = 4, 2                       # 4 entries
    await cq.configure(Q, base_addr=0x8000_0000, log_size=LOG, eqn=0)

    ptrs = []
    for i in range(1 << LOG):
        r = await cq.enqueue(Q, tag=0x10 + i)
        assert r["tag"] == 0x10 + i, f"tag mismatch on enqueue {i}"
        assert not r["full"], f"enqueue {i} reported full on an empty ring"
        assert not r["error"], f"enqueue {i} reported error"
        ptrs.append(r["ptr"])
        await cq.commit(r["op_tag"])

    assert ptrs == [0, 1, 2, 3], f"slots came back {ptrs}, expected [0,1,2,3]"

    # The consumer has read nothing, so the ring is now full. Handing out a
    # fifth slot would overwrite a completion the host has not seen.
    r = await cq.enqueue(Q, tag=0x1F)
    assert r["full"], f"5th enqueue on a 4-deep ring returned slot {r['ptr']}"

    # Advancing the consumer pointer frees space again.
    await cq.set_cons_ptr(Q, 2)
    r = await cq.enqueue(Q, tag=0x2A)
    assert not r["full"], "ring still full after the consumer advanced by 2"
    dut._log.info(f"slots {ptrs} in order, full at 4, recovered after cons_ptr=2")


# ---------------------------------------------------------------------------
# t1a_cq_arm_event - an armed queue emits ONE event and disarms.
#
# The one-shot behaviour is the point. A queue that stayed armed would emit an
# event per completion and storm the event path; one that never re-armed would
# silently stop interrupting the host.
# ---------------------------------------------------------------------------
@cocotb.test()
async def cqm_arm_event(dut):
    cq = await bringup(dut)
    Q, EQN = 6, 3
    await cq.configure(Q, base_addr=0x9000_0000, log_size=3, eqn=EQN)

    # Not armed: enqueue must NOT produce an event.
    r = await cq.enqueue(Q, tag=1)
    await cq.commit(r["op_tag"])
    assert cq.events == [], f"unarmed queue emitted events {cq.events}"

    # Armed: exactly one event, carrying the configured EQN.
    await cq.set_arm(Q, True)
    cq.events.clear()
    r = await cq.enqueue(Q, tag=2)
    await cq.commit(r["op_tag"])
    assert len(cq.events) == 1, (
        f"armed queue emitted {len(cq.events)} event(s), expected exactly 1")
    ev, src = cq.events[0]
    assert ev == EQN, f"event carried {ev}, configured EQN {EQN}"
    assert src == Q, f"event source {src}, expected queue {Q}"

    # And it disarmed itself - a second enqueue is silent.
    cq.events.clear()
    r = await cq.enqueue(Q, tag=3)
    await cq.commit(r["op_tag"])
    assert cq.events == [], (
        f"queue emitted {cq.events} after firing - it did not disarm, and would "
        "storm the event path")
    dut._log.info(f"armed queue fired once on EQN {EQN} and disarmed")


# ---------------------------------------------------------------------------
# t1a_cq_tag_echo - several completion queues, responses matched by tag.
# ---------------------------------------------------------------------------
@cocotb.test()
async def cqm_tag_echo(dut):
    cq = await bringup(dut)
    queues = [0, 1, 3, 7, 15, 31]
    for i, q in enumerate(queues):
        await cq.configure(q, base_addr=0x1_0000 * (i + 1), log_size=3, eqn=i)
    for i, q in enumerate(queues):
        tag = 0x70 + i
        r = await cq.enqueue(q, tag=tag)
        assert r["tag"] == tag, f"cq {q}: tag {r['tag']:#x} != {tag:#x}"
        assert r["queue"] == q, f"cq {r['queue']} echoed, sent {q}"
        assert not r["full"], f"cq {q} full on first enqueue"
        await cq.commit(r["op_tag"])
    dut._log.info(f"{len(queues)} completion queues, every response matched")


# ---------------------------------------------------------------------------
# t1a_cq_unconfigured - an unknown queue answers rather than stalling.
# ---------------------------------------------------------------------------
@cocotb.test()
async def cqm_unconfigured(dut):
    cq = await bringup(dut)
    r = await cq.enqueue(200, tag=0x5A)
    assert r["tag"] == 0x5A
    assert r["error"] or r["full"], (
        f"unconfigured cq answered error=0 full=0 ptr={r['ptr']} - it handed "
        "out a slot in a queue that does not exist")
    dut._log.info("unconfigured completion queue answers without stalling")

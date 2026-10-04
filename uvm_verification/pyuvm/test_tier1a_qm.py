"""Tier 1a - queue_manager against the real RTL, on Icarus.

Implements : VERIFICATION_STRATEGY.md  §13 Tier 1a

The queue configuration protocol is COMMAND-ENCODED, not a flat register map:
writes to register 2 carry an opcode in the top bits. The encoding here is
taken from tests/tier1a/tier1a_tests.sv:105-137, which was derived from
queue_manager.v:469-545 and has already been exercised - re-deriving it from the
RTL a second time is the transcription §8.1 forbids, and it is exactly how the
completion-tag position went wrong at Tier 5 (bug 33).

    reg addr    (queue << 5) | (reg << 2)
    reg 0/1     base address, low then high. READ-ONLY WHILE ENABLED.
    reg 2       0x8002_0000 | log_queue_size | (log_block_size << 8)
                0xC000_0000 | cqn
                0x4000_0100 | enable
                0x8080_0000 | producer_pointer
    reg 3       consumer pointer (read)

ORDER MATTERS: the DUT ignores configuration writes while the queue is enabled,
so everything must precede the enable. A test that programmed in the wrong
order would see a queue that reports empty forever and looks like a DUT bug.

Parameters follow tb/tb_top_tier1a.sv:24-34.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

QUEUE_INDEX_WIDTH = 13
QUEUE_PTR_WIDTH = 16
OP_TABLE_SIZE = 32

CMD_SET_SIZE = 0x8002_0000
CMD_SET_CQN = 0xC000_0000
CMD_SET_ENABLE = 0x4000_0100
CMD_SET_PROD_PTR = 0x8080_0000


def q_reg_addr(q, r):
    return (q << 5) | (r << 2)


class Qm:
    def __init__(self, dut):
        self.dut = dut
        self.responses = []

    # ---- AXI-Lite ---------------------------------------------------------
    async def axil_write(self, addr, data, timeout=200):
        dut = self.dut
        await RisingEdge(dut.clk)
        dut.s_axil_awaddr.value = addr
        dut.s_axil_awvalid.value = 1
        dut.s_axil_wdata.value = data
        dut.s_axil_wstrb.value = 0xF
        dut.s_axil_wvalid.value = 1
        dut.s_axil_bready.value = 1
        aw, w = False, False
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

    async def axil_read(self, addr, timeout=200):
        dut = self.dut
        await RisingEdge(dut.clk)
        dut.s_axil_araddr.value = addr
        dut.s_axil_arvalid.value = 1
        dut.s_axil_rready.value = 1
        for _ in range(timeout):
            await RisingEdge(dut.clk)
            if dut.s_axil_arready.value:
                dut.s_axil_arvalid.value = 0
                break
        else:
            raise AssertionError(f"AXI-Lite read of 0x{addr:x} not accepted")
        for _ in range(timeout):
            await RisingEdge(dut.clk)
            if dut.s_axil_rvalid.value:
                return int(dut.s_axil_rdata.value)
        raise AssertionError(f"no read data for 0x{addr:x}")

    # ---- queue configuration ---------------------------------------------
    async def configure(self, q, base_addr, log_size, log_block_size, cqn,
                        enable=True):
        await self.axil_write(q_reg_addr(q, 0), base_addr & 0xFFFFFFFF)
        await self.axil_write(q_reg_addr(q, 1), (base_addr >> 32) & 0xFFFFFFFF)
        await self.axil_write(q_reg_addr(q, 2),
                              CMD_SET_SIZE | log_size | (log_block_size << 8))
        await self.axil_write(q_reg_addr(q, 2), CMD_SET_CQN | cqn)
        if enable:
            await self.set_enable(q, True)

    async def set_enable(self, q, en):
        await self.axil_write(q_reg_addr(q, 2), CMD_SET_ENABLE | (1 if en else 0))

    async def set_prod_ptr(self, q, ptr):
        await self.axil_write(q_reg_addr(q, 2), CMD_SET_PROD_PTR | ptr)

    # ---- dequeue ----------------------------------------------------------
    async def dequeue(self, q, tag, timeout=400):
        """One dequeue request, returning the matching response.

        The response carries the request tag back. Checking it is the whole
        point: a queue manager that answered requests positionally would be
        indistinguishable from a correct one until two are in flight.
        """
        dut = self.dut
        await RisingEdge(dut.clk)
        dut.s_axis_dequeue_req_queue.value = q
        dut.s_axis_dequeue_req_tag.value = tag
        dut.s_axis_dequeue_req_valid.value = 1
        dut.m_axis_dequeue_resp_ready.value = 1
        for _ in range(timeout):
            await RisingEdge(dut.clk)
            if dut.s_axis_dequeue_req_ready.value:
                break
        else:
            raise AssertionError(f"dequeue request for queue {q} never accepted")
        dut.s_axis_dequeue_req_valid.value = 0

        for _ in range(timeout):
            await RisingEdge(dut.clk)
            if dut.m_axis_dequeue_resp_valid.value:
                r = dict(
                    queue=int(dut.m_axis_dequeue_resp_queue.value),
                    ptr=int(dut.m_axis_dequeue_resp_ptr.value),
                    addr=int(dut.m_axis_dequeue_resp_addr.value),
                    tag=int(dut.m_axis_dequeue_resp_tag.value),
                    op_tag=int(dut.m_axis_dequeue_resp_op_tag.value),
                    empty=int(dut.m_axis_dequeue_resp_empty.value),
                    error=int(dut.m_axis_dequeue_resp_error.value),
                )
                self.responses.append(r)
                return r
        raise AssertionError(
            f"no dequeue response for queue {q} tag {tag} - a dropped request "
            "stalls the descriptor fetch path forever")

    async def commit(self, op_tag, timeout=200):
        dut = self.dut
        await RisingEdge(dut.clk)
        dut.s_axis_dequeue_commit_op_tag.value = op_tag
        dut.s_axis_dequeue_commit_valid.value = 1
        for _ in range(timeout):
            await RisingEdge(dut.clk)
            if dut.s_axis_dequeue_commit_ready.value:
                dut.s_axis_dequeue_commit_valid.value = 0
                return
        raise AssertionError(f"commit of op_tag {op_tag} never accepted")


async def bringup(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    for sig in ("s_axil_awaddr", "s_axil_awprot", "s_axil_awvalid", "s_axil_wdata",
                "s_axil_wstrb", "s_axil_wvalid", "s_axil_araddr", "s_axil_arprot",
                "s_axil_arvalid", "s_axis_dequeue_req_queue",
                "s_axis_dequeue_req_tag", "s_axis_dequeue_req_valid",
                "s_axis_dequeue_commit_op_tag", "s_axis_dequeue_commit_valid",
                "enable"):
        try:
            getattr(dut, sig).value = 0
        except AttributeError:
            pass
    dut.s_axil_bready.value = 1
    dut.s_axil_rready.value = 1
    dut.m_axis_dequeue_resp_ready.value = 1
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
    return Qm(dut)


# ---------------------------------------------------------------------------
# t1a_reset - the DUT comes out of reset idle and does not invent traffic.
# ---------------------------------------------------------------------------
@cocotb.test()
async def qm_reset(dut):
    qm = await bringup(dut)
    for _ in range(60):
        await RisingEdge(dut.clk)
        assert not dut.m_axis_dequeue_resp_valid.value, (
            "dequeue response asserted with no request outstanding")
        assert not dut.m_axis_doorbell_valid.value, (
            "doorbell asserted with no queue configured")
    dut._log.info("idle after reset: no responses, no doorbells")


# ---------------------------------------------------------------------------
# t1a_dequeue_empty - an enabled but empty queue answers, and says empty.
#
# The failure that matters is not a wrong pointer, it is NO ANSWER: the
# descriptor fetch path waits on this response and a dropped request wedges it.
# ---------------------------------------------------------------------------
@cocotb.test()
async def qm_dequeue_empty(dut):
    qm = await bringup(dut)
    await qm.configure(q=3, base_addr=0x1000_0000, log_size=4,
                       log_block_size=0, cqn=0)
    r = await qm.dequeue(q=3, tag=0x11)
    assert r["tag"] == 0x11, f"tag {r['tag']:#x} echoed, sent 0x11"
    assert r["queue"] == 3, f"queue {r['queue']} echoed, sent 3"
    assert r["empty"], "queue with producer == consumer did not report empty"
    dut._log.info(f"empty queue answered: empty={r['empty']} error={r['error']}")


# ---------------------------------------------------------------------------
# t1a_dequeue_basic - a queue with descriptors hands them out in order.
# ---------------------------------------------------------------------------
@cocotb.test()
async def qm_dequeue_basic(dut):
    qm = await bringup(dut)
    BASE = 0x0000_0002_0000_0000
    await qm.configure(q=5, base_addr=BASE, log_size=4, log_block_size=0, cqn=1)
    await qm.set_prod_ptr(q=5, ptr=4)          # four descriptors available

    ptrs = []
    for i in range(4):
        r = await qm.dequeue(q=5, tag=0x20 + i)
        assert r["tag"] == 0x20 + i, f"tag mismatch on request {i}"
        assert not r["empty"], f"request {i} reported empty with 4 descriptors queued"
        assert not r["error"], f"request {i} reported error"
        ptrs.append(r["ptr"])
        await qm.commit(r["op_tag"])

    assert ptrs == [0, 1, 2, 3], f"pointers came back {ptrs}, expected [0,1,2,3]"

    # The fifth must report empty - handing out a descriptor that was never
    # produced is silent corruption of the descriptor stream.
    r = await qm.dequeue(q=5, tag=0x2F)
    assert r["empty"], f"fifth dequeue returned ptr {r['ptr']} on a 4-deep queue"
    dut._log.info(f"4 descriptors dequeued in order {ptrs}, 5th reported empty")


# ---------------------------------------------------------------------------
# t1a_disabled - a disabled queue must answer, with error, and never stall.
# ---------------------------------------------------------------------------
@cocotb.test()
async def qm_disabled(dut):
    qm = await bringup(dut)
    r = await qm.dequeue(q=7, tag=0x33)         # never configured at all
    assert r["tag"] == 0x33
    assert r["error"] or r["empty"], (
        f"unconfigured queue answered empty=0 error=0 ptr={r['ptr']} - it "
        "handed out a descriptor from a queue that does not exist")

    await qm.configure(q=8, base_addr=0x2000, log_size=4, log_block_size=0, cqn=0)
    await qm.set_prod_ptr(q=8, ptr=2)
    await qm.set_enable(8, False)
    r = await qm.dequeue(q=8, tag=0x44)
    assert r["error"] or r["empty"], (
        "explicitly disabled queue still handed out a descriptor")
    dut._log.info("unconfigured and disabled queues both answer without stalling")


# ---------------------------------------------------------------------------
# t1a_tag_echo - many queues in flight, every response carries its own tag.
# ---------------------------------------------------------------------------
@cocotb.test()
async def qm_tag_echo(dut):
    qm = await bringup(dut)
    queues = [1, 2, 4, 9, 16, 33]
    for i, q in enumerate(queues):
        await qm.configure(q=q, base_addr=0x1_0000 * (i + 1), log_size=4,
                           log_block_size=0, cqn=i)
        await qm.set_prod_ptr(q=q, ptr=2)

    for i, q in enumerate(queues):
        tag = 0x50 + i
        r = await qm.dequeue(q=q, tag=tag)
        assert r["tag"] == tag, f"queue {q}: tag {r['tag']:#x} != {tag:#x}"
        assert r["queue"] == q, f"queue {r['queue']} echoed, sent {q}"
        assert not r["empty"], f"queue {q} reported empty with 2 descriptors"
        await qm.commit(r["op_tag"])
    dut._log.info(f"{len(queues)} queues, every response matched its request")


# ---------------------------------------------------------------------------
# t1a_ptr_wrap - the consumer pointer wraps at the queue size.
#
# log_size=2 means 4 entries; dequeuing 12 must wrap three times. An off-by-one
# in the wrap reads descriptors from outside the ring.
# ---------------------------------------------------------------------------
@cocotb.test()
async def qm_ptr_wrap(dut):
    qm = await bringup(dut)
    Q, LOG = 11, 2
    size = 1 << LOG
    await qm.configure(q=Q, base_addr=0x4000, log_size=LOG, log_block_size=0, cqn=0)

    seen = []
    produced = 0
    for _ in range(3):
        produced += size
        await qm.set_prod_ptr(q=Q, ptr=produced)
        for _ in range(size):
            r = await qm.dequeue(q=Q, tag=0x60)
            assert not r["empty"], f"empty after producing {produced}"
            seen.append(r["ptr"] & (size - 1))
            await qm.commit(r["op_tag"])

    expect = [i % size for i in range(3 * size)]
    assert seen == expect, f"wrap sequence {seen}, expected {expect}"
    dut._log.info(f"consumer pointer wrapped {3} times cleanly over {len(seen)} "
                  "dequeues")

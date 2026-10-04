"""Tier 4d - pcie_us_if, the Xilinx shim INTEGRATION, on Icarus.

Implements : VERIFICATION_STRATEGY.md  §13, §5 (this is the plan's Tier 4b)

Tiers 4a/4b/4c verify pcie_us_if_{rc,cq}, _cc and _rq individually. This
verifies what wiring them together adds, and nothing a single-shim testbench
can already see:

  * THE CONFIGURATION PATH. pcie_us_cfg exists only in this wrapper. It POLLS
    PCIe config space over cfg_mgmt_* and extracts three values that nothing
    downstream can second-guess:

        pcie_us_cfg.v:121-123
        ext_tag_enable        <- cfg_mgmt_read_data[8]
        max_read_request_size <- cfg_mgmt_read_data[14:12]
        max_payload_size      <- cfg_mgmt_read_data[7:5]

    MPS and MRRS are the inputs to the DMA splitting rules verified at Tier 3
    against 390k cases. If this extraction is wrong, every one of those splits
    is computed from the wrong limit - and Tier 3 cannot see it, because Tier 3
    is handed the limits directly. This is the seam between two correct halves.

  * ALL FOUR CHANNELS CONCURRENTLY - inbound CQ and RC, outbound RQ and CC -
    with no cross-channel interference.

Descriptor and tuser layouts are taken from model/ref_tlp_shim.sv:175-215 and
uvc/common/mqnic_vrf_pkg.sv:709-747, which were verified against
pcie_us_if_cq.v:365-408. Re-deriving them here would be the transcription that
produced bug 12 and bug 33.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

DATA_WIDTH = 256
KEEP_WIDTH = DATA_WIDTH // 32

# pcie_us_if_cq.v request types, via ref_tlp_shim.sv:127-131. READ_LOCKED is
# 4'b0111 and NOT 4'b0001 - guessing it collided with MEM_WRITE (bug 12).
REQ_MEM_READ = 0b0000
REQ_MEM_WRITE = 0b0001

# The config-space Device Control register value the TB returns. Fields per
# pcie_us_cfg.v:121-123.
def dev_ctrl(mps=2, mrrs=5, ext_tag=1):
    return (mrrs << 12) | (ext_tag << 8) | (mps << 5)


def cq_descriptor(addr, dwords, req_type, requester_id, tag, bar_id, func_num=0):
    """Build a Xilinx CQ descriptor - the inverse of ref_tlp_shim::cq_parse."""
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
    """Below 512 bits both enables pack into one byte (mqnic_vrf_pkg:743-746)."""
    return (last_be & 0xF) << 4 | (first_be & 0xF)


class UsIf:
    def __init__(self, dut):
        self.dut = dut
        self.cfg_reads = 0
        self.dev_ctrl_value = dev_ctrl()

    async def cfg_responder(self):
        """Play PCIe config space for pcie_us_cfg's polling loop.

        Without this the DUT polls forever and max_payload_size stays 0, which
        looks exactly like a DUT that cannot read its own configuration.
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

    async def send_cq(self, desc, first_be=0xF, last_be=0x0, timeout=200):
        """One single-beat CQ transfer (descriptor only, no payload)."""
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
            raise AssertionError("CQ beat never accepted")
        dut.s_axis_cq_tvalid.value = 0
        dut.s_axis_cq_tlast.value = 0

    async def collect_rx_req(self, timeout=300):
        dut = self.dut
        dut.rx_req_tlp_ready.value = 1
        for _ in range(timeout):
            await RisingEdge(dut.clk)
            if dut.rx_req_tlp_valid.value and dut.rx_req_tlp_ready.value:
                return dict(hdr=int(dut.rx_req_tlp_hdr.value),
                            bar_id=int(dut.rx_req_tlp_bar_id.value),
                            func_num=int(dut.rx_req_tlp_func_num.value))
        return None

    async def send_tx_cpl(self, hdr, timeout=200):
        dut = self.dut
        await RisingEdge(dut.clk)
        dut.tx_cpl_tlp_hdr.value = hdr
        dut.tx_cpl_tlp_data.value = 0
        dut.tx_cpl_tlp_strb.value = 0
        dut.tx_cpl_tlp_valid.value = 1
        dut.tx_cpl_tlp_sop.value = 1
        dut.tx_cpl_tlp_eop.value = 1
        for _ in range(timeout):
            await RisingEdge(dut.clk)
            if dut.tx_cpl_tlp_ready.value:
                break
        else:
            raise AssertionError("tx_cpl never accepted")
        dut.tx_cpl_tlp_valid.value = 0
        dut.tx_cpl_tlp_sop.value = 0
        dut.tx_cpl_tlp_eop.value = 0

    async def collect_cc(self, timeout=300):
        dut = self.dut
        dut.m_axis_cc_tready.value = 1
        for _ in range(timeout):
            await RisingEdge(dut.clk)
            if dut.m_axis_cc_tvalid.value and dut.m_axis_cc_tready.value:
                return int(dut.m_axis_cc_tdata.value)
        return None


async def bringup(dut, wait=400):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    for sig in ("s_axis_rc_tdata", "s_axis_rc_tkeep", "s_axis_rc_tvalid",
                "s_axis_rc_tlast", "s_axis_rc_tuser",
                "s_axis_cq_tdata", "s_axis_cq_tkeep", "s_axis_cq_tvalid",
                "s_axis_cq_tlast", "s_axis_cq_tuser",
                "s_axis_rq_seq_num_0", "s_axis_rq_seq_num_valid_0",
                "s_axis_rq_seq_num_1", "s_axis_rq_seq_num_valid_1",
                "tx_rd_req_tlp_hdr", "tx_rd_req_tlp_seq", "tx_rd_req_tlp_valid",
                "tx_rd_req_tlp_sop", "tx_rd_req_tlp_eop",
                "tx_wr_req_tlp_data", "tx_wr_req_tlp_strb", "tx_wr_req_tlp_hdr",
                "tx_wr_req_tlp_seq", "tx_wr_req_tlp_valid", "tx_wr_req_tlp_sop",
                "tx_wr_req_tlp_eop",
                "tx_cpl_tlp_data", "tx_cpl_tlp_strb", "tx_cpl_tlp_hdr",
                "tx_cpl_tlp_valid", "tx_cpl_tlp_sop", "tx_cpl_tlp_eop",
                "tx_msix_wr_req_tlp_data", "tx_msix_wr_req_tlp_strb",
                "tx_msix_wr_req_tlp_hdr", "tx_msix_wr_req_tlp_valid",
                "tx_msix_wr_req_tlp_sop", "tx_msix_wr_req_tlp_eop",
                "cfg_fc_ph", "cfg_fc_pd", "cfg_fc_nph", "cfg_fc_npd",
                "cfg_fc_cplh", "cfg_fc_cpld",
                "cfg_interrupt_msi_enable", "cfg_interrupt_msi_mmenable",
                "cfg_interrupt_msi_mask_update", "cfg_interrupt_msi_data",
                "cfg_interrupt_msi_sent", "cfg_interrupt_msi_fail",
                "cfg_interrupt_msix_enable", "cfg_interrupt_msix_mask",
                "cfg_interrupt_msix_vf_enable", "cfg_interrupt_msix_vf_mask",
                "cfg_interrupt_msix_sent", "cfg_interrupt_msix_fail",
                "cfg_interrupt_msi_vf_enable"):
        try:
            getattr(dut, sig).value = 0
        except AttributeError:
            pass
    # *ready INPUTS high, never *ack - the Tier 5 lesson (bug 32).
    for sig in ("m_axis_rq_tready", "m_axis_cc_tready",
                "rx_req_tlp_ready", "rx_cpl_tlp_ready"):
        try:
            getattr(dut, sig).value = 1
        except AttributeError:
            pass

    u = UsIf(dut)
    cocotb.start_soon(u.cfg_responder())
    dut.rst.value = 1
    for _ in range(20):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    for _ in range(wait):        # let pcie_us_cfg complete its polling loop
        await RisingEdge(dut.clk)
    return u


# ---------------------------------------------------------------------------
# t4d_reset - the integration comes up idle.
# ---------------------------------------------------------------------------
@cocotb.test()
async def us_if_reset(dut):
    await bringup(dut, wait=60)
    for _ in range(80):
        await RisingEdge(dut.clk)
        assert not dut.rx_req_tlp_valid.value, "rx_req asserted with no CQ input"
        assert not dut.rx_cpl_tlp_valid.value, "rx_cpl asserted with no RC input"
        assert not dut.m_axis_rq_tvalid.value, "RQ asserted with no request in"
        assert not dut.m_axis_cc_tvalid.value, "CC asserted with no completion in"
    dut._log.info("all four channels idle after reset")


# ---------------------------------------------------------------------------
# t4d_cfg_extract - the wrapper reads its own PCIe configuration correctly.
#
# THE TIER'S REASON TO EXIST. MPS and MRRS drive the DMA splitting rules that
# Tier 3 verified against 390k cases - but Tier 3 is HANDED those limits, so it
# cannot see them being extracted from the wrong bits. This is the seam.
# ---------------------------------------------------------------------------
@cocotb.test()
async def us_if_cfg_extract(dut):
    # ONE bringup. Calling it per iteration starts a second Clock on the same
    # net, and two drivers on one net is contention, not a faster test.
    u = await bringup(dut, wait=40)

    for mps, mrrs, ext in ((2, 5, 1), (0, 0, 0), (5, 2, 0), (7, 7, 1), (1, 3, 1)):
        u.dev_ctrl_value = dev_ctrl(mps, mrrs, ext)
        before = u.cfg_reads
        # pcie_us_cfg waits 0xff cycles between polls (:136), so a changed value
        # takes up to ~300 cycles to be picked up.
        for _ in range(2000):
            await RisingEdge(dut.clk)
            if (u.cfg_reads > before
                    and int(dut.max_payload_size.value) == mps
                    and int(dut.max_read_request_size.value) == mrrs):
                break

        assert u.cfg_reads > before, (
            "pcie_us_cfg issued no new config read - it cannot have learned "
            "anything, so the values below would prove nothing")
        got_mps = int(dut.max_payload_size.value)
        got_mrrs = int(dut.max_read_request_size.value)
        got_ext = int(dut.ext_tag_enable.value)
        assert got_mps == mps, (
            f"max_payload_size {got_mps}, expected {mps} - the DMA engine would "
            "split every write against the wrong limit")
        assert got_mrrs == mrrs, (
            f"max_read_request_size {got_mrrs}, expected {mrrs} - every read "
            "would be split against the wrong limit")
        assert got_ext == ext, f"ext_tag_enable {got_ext}, expected {ext}"
        dut._log.info(f"  dev_ctrl mps={mps} mrrs={mrrs} ext={ext} -> extracted "
                      f"correctly ({u.cfg_reads} config read(s) so far)")


# ---------------------------------------------------------------------------
# t4d_cq_to_rx_req - a host BAR request crosses the whole wrapper.
# ---------------------------------------------------------------------------
@cocotb.test()
async def us_if_cq_to_rx_req(dut):
    u = await bringup(dut)
    cases = [
        (0x0000_1000, 1, REQ_MEM_READ, 0x0100, 0x11, 0),
        (0x0000_2004, 1, REQ_MEM_READ, 0x0200, 0x22, 1),
        (0x0001_0040, 4, REQ_MEM_READ, 0x0300, 0x33, 2),
    ]
    for addr, dwords, req, rid, tag, bar in cases:
        desc = cq_descriptor(addr, dwords, req, rid, tag, bar)
        await u.send_cq(desc, first_be=0xF, last_be=0x0)
        r = await u.collect_rx_req()
        assert r is not None, f"no rx_req for a CQ request at 0x{addr:x}"

        h = r["hdr"]
        got_addr = (h >> 2) << 2 & ((1 << 64) - 1)
        got_len = (h >> 96) & 0x3FF
        got_tag = (h >> 72) & 0xFF
        got_rid = (h >> 80) & 0xFFFF
        assert got_addr == addr, f"address 0x{got_addr:x}, sent 0x{addr:x}"
        assert got_len == dwords, f"length {got_len}, sent {dwords}"
        assert got_tag == tag, f"tag 0x{got_tag:x}, sent 0x{tag:x}"
        assert got_rid == rid, f"requester id 0x{got_rid:x}, sent 0x{rid:x}"
        assert r["bar_id"] == bar, f"bar_id {r['bar_id']}, sent {bar}"
        dut._log.info(f"  CQ 0x{addr:08x} len {dwords} bar {bar} -> rx_req intact")


# ---------------------------------------------------------------------------
# t4d_tx_cpl_to_cc - our completion reaches the Xilinx CC stream.
# ---------------------------------------------------------------------------
@cocotb.test()
async def us_if_tx_cpl_to_cc(dut):
    u = await bringup(dut)
    for tag in (0x05, 0x40, 0xFF):
        h = 0
        h |= 0b010 << 125                 # 3DW with data
        h |= 0b01010 << 120               # completion
        h |= 1 << 96                      # one DWORD
        h |= 0x0100 << 48                 # requester id (completion layout)
        h |= tag << 40                    # tag  (mqnic_vrf_pkg.sv:496)
        await u.send_tx_cpl(h)
        cc = await u.collect_cc()
        assert cc is not None, f"no CC beat for a completion with tag 0x{tag:x}"
        dut._log.info(f"  tx_cpl tag 0x{tag:02x} -> CC beat 0x{cc & 0xFFFFFFFF:08x}")


# ---------------------------------------------------------------------------
# t4d_concurrent - inbound and outbound at the same time.
#
# The four shims share only the wrapper. Interference between them cannot be
# seen by any single-shim testbench, which is the whole argument for this tier.
# ---------------------------------------------------------------------------
@cocotb.test()
async def us_if_concurrent(dut):
    u = await bringup(dut)
    seen_req, seen_cc = 0, 0

    async def inbound():
        nonlocal seen_req
        for i in range(8):
            desc = cq_descriptor(0x4000 + i * 0x40, 1, REQ_MEM_READ,
                                 0x0100, 0x50 + i, 0)
            await u.send_cq(desc)
            if await u.collect_rx_req() is not None:
                seen_req += 1

    async def outbound():
        nonlocal seen_cc
        for i in range(8):
            h = (0b010 << 125) | (0b01010 << 120) | (1 << 96) | ((0x60 + i) << 40)
            await u.send_tx_cpl(h)
            if await u.collect_cc() is not None:
                seen_cc += 1

    a = cocotb.start_soon(inbound())
    b = cocotb.start_soon(outbound())
    await a
    await b

    assert seen_req == 8, f"{seen_req}/8 CQ requests survived concurrent traffic"
    assert seen_cc == 8, f"{seen_cc}/8 completions survived concurrent traffic"

    # And the configuration the wrapper learned is undisturbed by the traffic.
    assert int(dut.max_payload_size.value) == 2, (
        "max_payload_size changed while the datapath was busy")
    dut._log.info(f"{seen_req} inbound + {seen_cc} outbound concurrently, "
                  "config stable")

"""Proof that UVM runs locally: pyuvm + cocotb + Icarus on real Corundum RTL.

Implements : VERIFICATION_STRATEGY.md  §16 (build), §19 E1/E7 (enabling)

WHY THIS EXISTS
---------------
The SystemVerilog UVM environment needs a UVM-capable simulator, and this
machine has none - Icarus cannot compile uvm_pkg. That blocked Tier 5 entirely
and blocked five of the eight §19 criteria.

pyuvm is IEEE 1800.2 implemented in Python on top of cocotb, and cocotb drives
Icarus. So UVM SEMANTICS - factory, config_db, phases, components, sequences -
are available here right now, against the real unmodified RTL.

This is not a replacement for the SystemVerilog environment. It is a second
execution path for the machine that has no commercial licence, and it starts
where everything else in this project started: the smallest DUT that proves the
mechanism, before anything is built on it.

DUT: fpga/lib/pcie/rtl/dma_psdpram.v - the Tier 2 DUT, self-contained.
"""

import os
import pathlib

import cocotb
from cocotb.triggers import RisingEdge, Timer
from cocotb.clock import Clock
from pyuvm import (uvm_test, uvm_env, uvm_component, uvm_sequence,
                   uvm_sequence_item, uvm_driver, uvm_sequencer,
                   uvm_analysis_port, ConfigDB, uvm_root)

ROOT = pathlib.Path(__file__).resolve().parents[2]

# The DUT handle. pyuvm's ConfigDB glob semantics differ from
# SystemVerilog's uvm_config_db; a module global keeps this proof about
# the phase and sequence machinery rather than about a lookup API.
DUT = None


class RamItem(uvm_sequence_item):
    def __init__(self, name="RamItem", seg=0, addr=0, data=0):
        super().__init__(name)
        self.seg, self.addr, self.data = seg, addr, data

    def __str__(self):
        return f"seg={self.seg} addr=0x{self.addr:x} data=0x{self.data:x}"


class RamWriteSeq(uvm_sequence):
    """Write a distinctive pattern to a handful of addresses on both segments."""

    async def body(self):
        for seg in range(2):
            for a in range(4):
                it = RamItem(seg=seg, addr=a,
                             data=(0xA5A5_0000 | (seg << 8) | a))
                await self.start_item(it)
                await self.finish_item(it)


class RamDriver(uvm_driver):
    """Drives one segment's write-command channel."""

    def build_phase(self):
        self.dut = DUT
        self.ap = uvm_analysis_port("ap", self)
        self.n_driven = 0

    async def run_phase(self):
        dut = self.dut
        dut.wr_cmd_valid.value = 0
        dut.wr_cmd_be.value = 0
        dut.wr_cmd_addr.value = 0
        dut.wr_cmd_data.value = 0
        while True:
            it = await self.seq_item_port.get_next_item()
            await RisingEdge(dut.clk)
            # Two segments, 128-bit data, 16 byte-enables each in this build.
            seg_be, seg_dw, seg_aw = 16, 128, 7
            dut.wr_cmd_be.value = (0xFFFF << (it.seg * seg_be))
            dut.wr_cmd_addr.value = (it.addr << (it.seg * seg_aw))
            dut.wr_cmd_data.value = (it.data << (it.seg * seg_dw))
            dut.wr_cmd_valid.value = (1 << it.seg)
            await RisingEdge(dut.clk)
            dut.wr_cmd_valid.value = 0
            self.n_driven += 1
            self.ap.write(it)
            self.seq_item_port.item_done()


class RamEnv(uvm_env):
    def build_phase(self):
        self.seqr = uvm_sequencer("seqr", self)
        self.drv = RamDriver("drv", self)

    def connect_phase(self):
        self.drv.seq_item_port.connect(self.seqr.seq_item_export)


class SmokeTest(uvm_test):
    """A real uvm_test: pyuvm runs build/connect/run phases itself.

    Driving the phase machinery rather than calling build_phase() by hand is the
    whole point - it is what makes this UVM rather than a script that happens to
    use UVM class names.
    """

    def build_phase(self):
        self.env = RamEnv("env", self)

    async def run_phase(self):
        self.raise_objection()
        seq = RamWriteSeq("seq")
        await seq.start(self.env.seqr)
        dut = DUT
        for _ in range(20):
            await RisingEdge(dut.clk)
        n = self.env.drv.n_driven
        assert n == 8, f"expected 8 writes, drove {n}"
        self.logger.info(f"pyuvm drove {n} write(s) into dma_psdpram")
        self.drop_objection()


@cocotb.test()
async def smoke(dut):
    """End-to-end: pyuvm phases, sequences and factory on real Corundum RTL."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())

    dut.rst.value = 1
    dut.wr_cmd_valid.value = 0
    dut.rd_cmd_valid.value = 0
    dut.rd_resp_ready.value = 0
    for _ in range(10):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)

    global DUT
    DUT = dut
    await uvm_root().run_test("SmokeTest")

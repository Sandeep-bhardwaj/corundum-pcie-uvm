"""tiers.py - one table describing every tier's DUT, shared by the runner and
the Icarus elaboration check.

WHY A TABLE RATHER THAN A DICT PER SCRIPT
-----------------------------------------
This project has been bitten twice by inventories maintained in more than one
place: check_filelists.py silently stopped checking a renamed tier (bug 20), and
the regression lists drifted from the test sources until gen_regress_lists.py
started deriving them. A second copy of "which tier has which top" would go the
same way, so there is exactly one.

THE PARAMETERS ARE PART OF THE IDENTITY
---------------------------------------
Every entry carries the parameter overrides its SystemVerilog top uses. A DUT
elaborated with DEFAULT parameters is a different design from the same DUT as
configured, and the difference is not cosmetic: pcie_tlp_demux defaults to
FIFO_ENABLE=1 and instantiates pcie_tlp_fifo, so checking Tier 1b with defaults
reports a missing module that Tier 1b does not use. Anything that elaborates a
tier must elaborate the CONFIGURED tier.
"""

import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
FILELISTS = ROOT / "sim" / "filelists"


class Tier:
    def __init__(self, name, filelist, top, params=None, test_module=None):
        self.name = name
        self.filelist = filelist
        self.top = top
        self.params = params or {}
        self.test_module = test_module

    def sources(self):
        """Resolve a project filelist to (sources, include_dirs)."""
        fl = FILELISTS / self.filelist
        srcs, incs = [], []
        for line in fl.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            if line.startswith("+incdir+"):
                incs.append((fl.parent / line[len("+incdir+"):]).resolve())
            elif not line.startswith("+"):
                srcs.append((fl.parent / line).resolve())
        return srcs, incs


# Tops match tb/tb_top_<tier>.sv; parameters match what those tops pass.
TIERS = [
    # tb/tb_top_tier1a.sv:24-34
    Tier("1a-qm", "rtl_tier1a.f", "queue_manager",
         {"ADDR_WIDTH": 64, "REQ_TAG_WIDTH": 8, "OP_TABLE_SIZE": 32,
          "OP_TAG_WIDTH": 8, "QUEUE_INDEX_WIDTH": 13, "CPL_INDEX_WIDTH": 8,
          "QUEUE_PTR_WIDTH": 16, "LOG_BLOCK_SIZE_WIDTH": 2,
          # These three match the RTL defaults today. Stated anyway: relying on
          # a default and an override happening to coincide is how the Tier 1b
          # BAR_STRIDE mistake survived, and check_tier_params.py flags it.
          "LOG_QUEUE_SIZE_WIDTH": 4, "DESC_SIZE": 16, "PIPELINE": 2,
          "AXIL_DATA_WIDTH": 32, "AXIL_ADDR_WIDTH": 18, "AXIL_STRB_WIDTH": 4},
         test_module="test_tier1a_qm"),
    # tb/tb_top_tier1a.sv:51-55 and its cpl_queue_manager instantiation.
    Tier("1a", "rtl_tier1a.f", "cpl_queue_manager",
         {"ADDR_WIDTH": 64, "REQ_TAG_WIDTH": 8, "OP_TABLE_SIZE": 32,
          "OP_TAG_WIDTH": 8, "QUEUE_INDEX_WIDTH": 8, "EVENT_WIDTH": 8,
          "QUEUE_PTR_WIDTH": 16, "CPL_SIZE": 32, "PIPELINE": 2,
          "AXIL_DATA_WIDTH": 32, "AXIL_ADDR_WIDTH": 12, "AXIL_STRB_WIDTH": 4},
         test_module="test_tier1a_cqm"),
    # tb/tb_top_tier1b.sv:43-48 and its pcie_tlp_demux_bar instantiation.
    # BAR_STRIDE is the one that matters: at the default of 1 the ports match
    # BAR 0 and 1, at 2 they match BAR 0 and 2. Carrying only FIFO_ENABLE here
    # produced a test that failed against a DIFFERENTLY CONFIGURED DUT and
    # looked like a routing bug.
    Tier("1b", "rtl_tier1b.f", "pcie_tlp_demux_bar",
         {"PORTS": 2, "TLP_DATA_WIDTH": 256, "TLP_STRB_WIDTH": 8,
          "TLP_HDR_WIDTH": 128, "SEQ_NUM_WIDTH": 6,
          "IN_TLP_SEG_COUNT": 1, "OUT_TLP_SEG_COUNT": 1,
          "FIFO_ENABLE": 0, "BAR_BASE": 0, "BAR_STRIDE": 2, "BAR_IDS": 0},
         test_module="test_tier1b_demux"),
    Tier("1c", "rtl_tier1c.f", "rx_checksum",
         test_module="test_tier1c_csum"),
    Tier("2", "rtl_tier2.f", "dma_psdpram",
         test_module="test_smoke_psdpram"),
    Tier("3a", "rtl_tier3.f", "dma_if_pcie_rd"),
    Tier("3b", "rtl_tier3b.f", "dma_if_pcie_wr"),
    Tier("3c", "rtl_tier3c.f", "dma_if_pcie"),
    Tier("4a", "rtl_tier4a.f", "pcie_us_if_rc"),
    Tier("4b", "rtl_tier4b.f", "pcie_us_if_cc"),
    Tier("4c", "rtl_tier4c.f", "pcie_us_if_rq"),
    # The plan's Tier 4b - the shim INTEGRATION. Named 4d here because this
    # environment had already taken the label "4b" for pcie_us_if_cc; see
    # sim/filelists/rtl_tier4d.f for why it was not renumbered.
    Tier("4d", "rtl_tier4d.f", "pcie_us_if",
         # tb/tb_top_tier4d.sv:49-75, resolved at AXIS_PCIE_DATA_WIDTH = 256.
         # Every one of these is stated even though most match the RTL default,
         # because "the default happens to agree" is not a property anyone
         # checks when the RTL changes.
         {"AXIS_PCIE_DATA_WIDTH": 256, "AXIS_PCIE_KEEP_WIDTH": 8,
          "AXIS_PCIE_RC_USER_WIDTH": 75, "AXIS_PCIE_RQ_USER_WIDTH": 60,
          "AXIS_PCIE_CQ_USER_WIDTH": 85, "AXIS_PCIE_CC_USER_WIDTH": 33,
          "RC_STRADDLE": 1, "RQ_STRADDLE": 0,
          "CQ_STRADDLE": 0, "CC_STRADDLE": 0,
          "RQ_SEQ_NUM_WIDTH": 4,
          "TLP_DATA_WIDTH": 256, "TLP_STRB_WIDTH": 8,
          "TLP_HDR_WIDTH": 128, "TLP_SEG_COUNT": 1,
          "TX_SEQ_NUM_COUNT": 1, "TX_SEQ_NUM_WIDTH": 3,
          "PF_COUNT": 1, "VF_COUNT": 0, "F_COUNT": 1,
          "READ_EXT_TAG_ENABLE": 1, "READ_MAX_READ_REQ_SIZE": 1,
          "READ_MAX_PAYLOAD_SIZE": 1,
          "MSIX_ENABLE": 1, "MSI_ENABLE": 0, "MSI_COUNT": 32},
         test_module="test_tier4d_us_if"),
    Tier("5", "rtl_tier5.f", "mqnic_core_pcie",
         test_module="test_tier5_csr"),
    # THE STRATEGY'S TOP DUT (§3.1). Parameters come from the RTL defaults here:
    # there is no tb_top_tier6.sv overriding them, which check_tier_params.py
    # confirms by finding nothing to compare against.
    Tier("6", "rtl_tier6.f", "mqnic_core_pcie_us",
         test_module="test_tier6_regwalk"),
]

BY_NAME = {t.name: t for t in TIERS}
RUNNABLE = [t for t in TIERS if t.test_module]

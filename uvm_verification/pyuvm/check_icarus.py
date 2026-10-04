"""check_icarus.py - can Icarus elaborate each tier's DUT?

Elaborating under a SECOND front end is worth doing on its own: slang and
Icarus disagreeing is how three of the four RTL defects in this project were
found. But the immediate purpose is to find out which tiers can run locally at
all before writing tests for them.
"""
import pathlib, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = pathlib.Path(__file__).parent / "sim_build_check"

# (tier, filelist, top, parameter overrides)
#
# The overrides are NOT optional. Elaborating a DUT with its DEFAULT parameters
# is not the same as elaborating it AS CONFIGURED, and the difference is not
# academic: pcie_tlp_demux defaults to FIFO_ENABLE=1 and instantiates
# pcie_tlp_fifo (:168), which Tier 1b's filelist correctly does not carry
# because tb_top_tier1b.sv passes FIFO_ENABLE(0). Checking with defaults
# reported a missing module that is not missing.
TIERS = [
    ("1a-qm",  "rtl_tier1a.f", "queue_manager"),
    ("1a-cqm", "rtl_tier1a.f", "cpl_queue_manager"),
    ("1",      "rtl_tier1.f",  "cpl_queue_manager"),
    ("1b",     "rtl_tier1b.f", "pcie_tlp_demux_bar", {"FIFO_ENABLE": 0}),
    ("1c",     "rtl_tier1c.f", "rx_checksum"),
    ("2",      "rtl_tier2.f",  "dma_psdpram"),
    ("3a",     "rtl_tier3.f",  "dma_if_pcie_rd"),
    ("3b",     "rtl_tier3b.f", "dma_if_pcie_wr"),
    ("3c",     "rtl_tier3c.f", "dma_if_pcie"),
    ("4a",     "rtl_tier4a.f", "pcie_us_if_rc"),
    ("4b",     "rtl_tier4b.f", "pcie_us_if_cc"),
    ("4c",     "rtl_tier4c.f", "pcie_us_if_rq"),
    ("5",      "rtl_tier5.f",  "mqnic_core_pcie"),
    ("4d",     "rtl_tier4d.f", "pcie_us_if"),
    ("6",      "rtl_tier6.f",  "mqnic_core_pcie_us"),
]


def sources(name):
    fl = ROOT / "sim" / "filelists" / name
    out, incs = [], []
    for line in fl.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        if line.startswith("+incdir+"):
            incs.append(str((fl.parent / line[8:]).resolve()))
            continue
        if line.startswith("+"):
            continue
        out.append(str((fl.parent / line).resolve()))
    return out, incs


def main():
    OUT.mkdir(exist_ok=True)
    rows = []
    for row in TIERS:
        tier, fl, top = row[0], row[1], row[2]
        params = row[3] if len(row) > 3 else {}
        srcs, incs = sources(fl)
        cmd = ["iverilog", "-g2012", "-s", top,
               "-o", str(OUT / f"{tier}.vvp")]
        cmd += [f"-P{top}.{k}={v}" for k, v in params.items()]
        cmd += [f"-I{i}" for i in incs] + srcs
        r = subprocess.run(cmd, capture_output=True, text=True)
        errs = [l for l in r.stderr.splitlines() if ": error" in l.lower()]
        rows.append((tier, top, r.returncode, len(errs), errs[:3]))
    print(f"{'tier':<7} {'top':<22} {'rc':>3} {'errors':>7}")
    print("-" * 46)
    bad = 0
    for tier, top, rc, n, errs in rows:
        print(f"{tier:<7} {top:<22} {rc:>3} {n:>7}")
        if rc:
            bad += 1
            for e in errs:
                print(f"        {e}")
    print("-" * 46)
    print(f"{len(rows)-bad}/{len(rows)} elaborate under Icarus")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

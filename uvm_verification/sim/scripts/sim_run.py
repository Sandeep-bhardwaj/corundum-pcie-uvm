#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause-Views
"""
sim_run.py - single source of truth for simulator invocation.

Implements : VERIFICATION_STRATEGY.md  §16.2 (compile notes), §16.3 (targets)
Introduced : Step 0 (infrastructure)

The Makefile is a thin wrapper around this script so the flow works identically
with or without GNU make (make is not present on a stock Windows host, and this
project is developed on Windows).

Supported simulators: vcs, questa, xcelium. Selected with --sim or $MQNIC_SIM.

Compile notes carried from STRATEGY §16.2:
  * RTL is Verilog-2001 and uses `default_nettype none / `resetall. RTL and TB
    are compiled as separate units where the simulator allows, so TB defines
    cannot leak into RTL.
  * timescale is forced to 1ns/1ps for both.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

TB_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = TB_ROOT.parent
SIM_DIR = TB_ROOT / "sim"
FILELIST_DIR = SIM_DIR / "filelists"
RESULTS_DIR = TB_ROOT / "results"

TIMESCALE = "1ns/1ps"

# Top module per tier. Step 0 uses the smoke top; Step 1 onward each tier gets
# its own tb_top_tier<N>.sv (STRATEGY §6).
TIER_TOPS = {
    "smoke": "tb_top_smoke",
    "1a": "tb_top_tier1a",
    "1b": "tb_top_tier1b",
    "1c": "tb_top_tier1c",
    "2":  "tb_top_tier2",
    "3":  "tb_top_tier3",
    "4":  "tb_top_tier4a",
    "5":  "tb_top_tier5",
    "6":  "tb_top_tier6",
}


def filelists_for(tier: str) -> list[Path]:
    """RTL filelist for the tier plus the common TB filelist."""
    rtl = FILELIST_DIR / f"rtl_tier{tier}.f"
    common = FILELIST_DIR / "tb_common.f"
    out = []
    if rtl.exists():
        out.append(rtl)
    out.append(common)
    return out


def build_commands(args) -> list[list[str]]:
    top = TIER_TOPS.get(args.tier, f"tb_top_tier{args.tier}")
    outdir = RESULTS_DIR / f"tier{args.tier}" / args.test / f"seed{args.seed}"
    outdir.mkdir(parents=True, exist_ok=True)

    flists: list[str] = []
    for f in filelists_for(args.tier):
        flists += ["-f", str(f)]

    uvm_home = args.uvm_home or os.environ.get("UVM_HOME", "")

    plusargs = [
        f"+UVM_TESTNAME={args.test}",
        f"+UVM_VERBOSITY={args.verbosity}",
    ]
    if args.timeout_ns:
        plusargs.append(f"+MQNIC_TIMEOUT_NS={args.timeout_ns}")
    if args.waves:
        plusargs.append("+WAVES")
    plusargs += args.plusarg

    if args.sim == "vcs":
        compile_cmd = [
            "vcs", "-full64", "-sverilog", "-timescale=" + TIMESCALE,
            "-ntb_opts", "uvm", "-debug_access+all",
            "-l", str(outdir / "compile.log"),
            "-o", str(outdir / "simv"),
            "-top", top,
        ] + flists
        if args.coverage:
            compile_cmd += ["-cm", "line+cond+fsm+tgl+branch",
                            "-cm_dir", str(outdir / "cov")]
        run_cmd = [str(outdir / "simv"),
                   f"+ntb_random_seed={args.seed}",
                   "-l", str(outdir / "sim.log")] + plusargs
        if args.coverage:
            run_cmd += ["-cm", "line+cond+fsm+tgl+branch",
                        "-cm_dir", str(outdir / "cov")]

    elif args.sim == "questa":
        compile_cmd = [
            "vlog", "-sv", "-timescale", TIMESCALE,
            "-l", str(outdir / "compile.log"),
        ]
        if uvm_home:
            compile_cmd += ["+incdir+" + str(Path(uvm_home) / "src")]
        compile_cmd += ["-mfcu"] + flists
        if args.coverage:
            compile_cmd += ["+cover=bcefsx"]
        run_cmd = [
            "vsim", "-c", "-do", "run -all; quit -f",
            "-sv_seed", str(args.seed),
            "-l", str(outdir / "sim.log"),
            top,
        ] + plusargs
        if args.coverage:
            run_cmd += ["-coverage", "-coverstore", str(outdir / "cov")]

    elif args.sim == "xcelium":
        compile_cmd = [
            "xrun", "-64bit", "-sv", "-timescale", TIMESCALE,
            "-uvm", "-access", "+rwc",
            "-l", str(outdir / "compile.log"),
            "-top", top,
            "-elaborate",
        ] + flists
        run_cmd = [
            "xrun", "-64bit", "-R",
            "-svseed", str(args.seed),
            "-l", str(outdir / "sim.log"),
        ] + plusargs
        if args.coverage:
            compile_cmd += ["-coverage", "all", "-covoverwrite",
                            "-covworkdir", str(outdir / "cov")]
            run_cmd += ["-coverage", "all", "-covworkdir", str(outdir / "cov")]

    else:
        raise SystemExit(f"unsupported simulator: {args.sim}")

    return [compile_cmd, run_cmd]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sim", default=os.environ.get("MQNIC_SIM", "questa"),
                    choices=["vcs", "questa", "xcelium"])
    ap.add_argument("--tier", default="smoke")
    ap.add_argument("--test", default="mqnic_base_test")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--verbosity", default="UVM_MEDIUM")
    ap.add_argument("--timeout-ns", type=int, default=0)
    ap.add_argument("--waves", action="store_true")
    ap.add_argument("--coverage", action="store_true")
    ap.add_argument("--uvm-home", default="")
    ap.add_argument("--plusarg", action="append", default=[])
    ap.add_argument("--dry-run", action="store_true",
                    help="print the commands without executing them")
    args = ap.parse_args()

    cmds = build_commands(args)

    if args.dry_run:
        for c in cmds:
            print(" ".join(c))
        return 0

    tool = cmds[0][0]
    if shutil.which(tool) is None:
        sys.stderr.write(
            f"error: '{tool}' not found on PATH.\n"
            f"       UVM requires a commercial simulator (VCS / Questa / Xcelium).\n"
            f"       For static checking without a simulator use:\n"
            f"         python {Path(__file__).with_name('slang_check.py')} "
            f"--mode elab -f {FILELIST_DIR / 'tb_common.f'}\n"
        )
        return 127

    for c in cmds:
        print("+", " ".join(c))
        rc = subprocess.call(c, cwd=str(TB_ROOT))
        if rc != 0:
            return rc
    return 0


if __name__ == "__main__":
    sys.exit(main())

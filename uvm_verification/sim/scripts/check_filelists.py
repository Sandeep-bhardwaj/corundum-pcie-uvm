#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause-Views
"""
check_filelists.py - guard against tb/rtl filelist mismatches.

Implements : VERIFICATION_STRATEGY.md  §16.1
Introduced : after VCS bug 7

A DUT wrapper instantiates an RTL module; an SVA file `bind`s to one. If the
testbench filelist names either but the matching RTL filelist does not supply
that module, the build gets a stray top-level module and VCS rejects the bind
with SVA-COBMMI. That is invisible to slang, which is happy to elaborate an
unbound wrapper.

Naming convention this relies on:
    tb/dut_wrapper_<mod>.sv   ->  requires <mod>.v
    sva/sva_<mod>.sv          ->  requires <mod>.v   (verified against the
                                  actual `bind` target, not just the filename)
"""
from __future__ import annotations
import pathlib
import re
import sys

TB_ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from slang_check import parse_filelist  # noqa: E402

PAIRS = [("1", "tb_tier1"), ("1a", "tb_common"), ("1b", "tb_tier1b"),
         ("1c", "tb_tier1c"), ("2", "tb_tier2"), ("3", "tb_tier3"), ("3b", "tb_tier3b"), ("3c", "tb_tier3c"), ("4a", "tb_tier4a"), ("4b", "tb_tier4b"), ("4c", "tb_tier4c"), ("4d", "tb_tier4d"), ("5", "tb_tier5"), ("6", "tb_tier6")]

BIND_RE = re.compile(r"^\s*bind\s+(\w+)\s", re.M)

def main() -> int:
    fl = TB_ROOT / "sim" / "filelists"
    bad = 0
    # ---- every filelist must be covered by PAIRS -------------------------
    #
    # PAIRS is hand-maintained, and a rename that misses it makes this script
    # skip a tier SILENTLY while still printing OK for the rest. That happened
    # on the tier4 -> tier4a rename: the guard quietly stopped checking the one
    # tier that had just changed.
    #
    # A checker that can be bypassed by forgetting to update it is not a
    # checker, so it now audits its own table.
    known_rtl = {f"rtl_tier{t}.f" for t, _ in PAIRS}
    known_tb  = {f"{tb}.f"        for _, tb in PAIRS}
    orphans = []
    for f in sorted(fl.glob("*.f")):
        if f.name in known_rtl or f.name in known_tb:
            continue
        # tb_common.f is Tier 1a's tb, already paired above under a different
        # name. rtl_smoke.f is the Step 0 standalone smoke list with no tb pair
        # and no wrappers or binds, so there is nothing for this script to
        # check - exempt deliberately rather than by omission.
        if f.name in ("tb_common.f", "rtl_smoke.f"):
            continue
        orphans.append(f.name)
    if orphans:
        for o in orphans:
            print(f"UNCHECKED: {o} is not covered by PAIRS in this script")
        bad += len(orphans)

    for tier, tb in PAIRS:
        rtl_f = fl / f"rtl_tier{tier}.f"
        tb_f  = fl / f"{tb}.f"
        if not rtl_f.is_file() or not tb_f.is_file():
            continue
        rtl_files, _, _ = parse_filelist(rtl_f)
        tb_files,  _, _ = parse_filelist(tb_f)
        rtl_mods = {f.stem for f in rtl_files}

        need: dict[str, str] = {}
        for f in tb_files:
            if f.name.startswith("dut_wrapper_"):
                need[f.name[len("dut_wrapper_"):-3]] = f.name
            elif f.name.startswith("sva_") and f.is_file():
                for m in BIND_RE.findall(f.read_text(encoding="utf-8", errors="replace")):
                    need[m] = f.name

        missing = {m: src for m, src in need.items() if m not in rtl_mods}
        if missing:
            bad += 1
            print(f"tier{tier}: {tb}.f needs RTL not in rtl_tier{tier}.f")
            for m, src in sorted(missing.items()):
                print(f"    {src} requires module '{m}'")
        else:
            print(f"tier{tier:<3}: OK ({len(need)} wrapper/bind dependency(ies) satisfied)")
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""check_strategy_duts.py - is every DUT the strategy names actually built?

    python check_strategy_duts.py            # report
    python check_strategy_duts.py --check    # exit 1 if a DUT is unbuilt

WHY (bug 36)
------------
VERIFICATION_STRATEGY.md §5 is a table of tiers and the DUTs each one covers.
Nothing compared it against what the environment actually contains, and the
environment quietly diverged:

  * §5 assigns Tier 4a = all four pcie_us_if_* shims, Tier 4b = pcie_us_if.
  * This environment split the shims across ITS OWN tiers 4a/4b/4c - taking over
    the label "4b" that the plan had given to the integration.
  * "Tier 4b exists" stayed true while meaning something else, and pcie_us_if
    was never built at all. It went unnoticed through every other guard, because
    every other guard checks internal consistency: the filelists agreed with the
    tests, the tests agreed with the regression lists, and all of them agreed
    with each other about a set that was missing a DUT.
  * pcie_tlp_mux, named at Tier 1b, is in no filelist either.

A set of cross-checks that only compare the environment to itself cannot find a
DUT that was never added. This one compares it to the PLAN.

HOW IT DECIDES
--------------
A DUT counts as built if some rtl_tier*.f names <dut>.v. That is deliberately
weak - it does not prove the DUT is instantiated, driven or checked - but it is
strong enough to catch the failure that actually happened, which is a module
nobody ever wrote a tier for. Anything it cannot parse out of the strategy is
REPORTED, never skipped: a checker that silently narrows its own scope is the
bug it exists to prevent (see bug 20).
"""

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
STRATEGY = ROOT / "VERIFICATION_STRATEGY.md"
FILELISTS = ROOT / "sim" / "filelists"

# Named in §1.3 as out of scope, so absence is correct rather than a gap.
OUT_OF_SCOPE = {
    "fpga", "fpga_core", "pcie4_uscale_plus_0", "ddr4_0", "cmac_usplus",
    "pcie_s10_if", "pcie_ptile_if",
    "mqnic_core_pcie_ptile", "mqnic_core_pcie_s10", "mqnic_core_axi",
}

# §5's tier table rows look like:  | **4a** | `a`, `b` | ... |
ROW = re.compile(r"^\|\s*\*\*([0-9][a-z]?)\*\*\s*\|([^|]*)\|")
TICK = re.compile(r"`([a-z0-9_]+)`")


def parse_tier_plan():
    """Return {tier: [dut, ...]} from the §5 table."""
    text = STRATEGY.read_text(encoding="utf-8")
    out = {}
    for line in text.splitlines():
        m = ROW.match(line)
        if not m:
            continue
        tier, cell = m.group(1), m.group(2)
        duts = []
        for name in TICK.findall(cell):
            # `pcie_us_if_{cq,cc,rq,rc}` style braces are expanded by the caller
            duts.append(name)
        # Expand brace groups, which TICK cannot see because of the braces.
        for grp in re.findall(r"`([a-z0-9_]+)\{([a-z,_]+)\}`", cell):
            duts += [grp[0] + s for s in grp[1].split(",")]
        if duts:
            out[tier] = sorted(set(duts))
    return out


def built_modules():
    """Every <module>.v named by any rtl_tier*.f, with the tiers naming it."""
    found = {}
    for fl in sorted(FILELISTS.glob("rtl_tier*.f")):
        tier = fl.stem.replace("rtl_tier", "")
        for line in fl.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith(("//", "+")):
                continue
            found.setdefault(pathlib.Path(line).stem, set()).add(tier)
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    if not STRATEGY.is_file():
        print(f"cannot find {STRATEGY}")
        return 2

    plan = parse_tier_plan()
    built = built_modules()
    if not plan:
        print("parsed NO tiers out of the strategy - the table format has "
              "changed and this check is no longer checking anything")
        return 1

    missing, ok = [], 0
    for tier, duts in plan.items():
        for dut in duts:
            if dut in OUT_OF_SCOPE:
                continue
            if dut in built:
                ok += 1
            else:
                missing.append((tier, dut))

    for tier, dut in missing:
        print(f"  UNBUILT: strategy Tier {tier} names `{dut}`, which appears in "
              "no rtl_tier*.f")
    print(f"{ok} DUT(s) from the strategy tier plan are built, "
          f"{len(missing)} missing, across {len(plan)} tier(s)")

    if args.check and missing:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

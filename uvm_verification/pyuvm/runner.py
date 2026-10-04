"""cocotb runner: build and run a pyuvm/cocotb test on Corundum RTL with Icarus.

    python runner.py            # list what is runnable
    python runner.py 1c         # one tier
    python runner.py all        # every tier that has a test, non-zero on failure

The tier table lives in tiers.py so the runner and the Icarus elaboration check
cannot disagree about which top or which parameters a tier uses.

WHY THIS EXISTS
---------------
The SystemVerilog flow needs a UVM-capable simulator, which this machine does
not have, and Tier 5 exceeds EDA Playground's size cap outright. Icarus plus
cocotb runs the REAL RTL - the same filelists, the same parameters - so a tier
can go from "elaborates" to "passes" without a licence.
"""

import pathlib
import sys

from cocotb_tools.runner import get_runner

from tiers import BY_NAME, RUNNABLE, TIERS

ROOT = pathlib.Path(__file__).resolve().parents[1]


def build_and_run(tier):
    srcs, incs = tier.sources()
    r = get_runner("icarus")
    r.build(verilog_sources=srcs,
            includes=[str(i) for i in incs],
            hdl_toplevel=tier.top,
            parameters=tier.params,
            build_args=["-g2012"],
            build_dir=f"sim_build/{tier.name}",
            always=True)
    r.test(hdl_toplevel=tier.top,
           test_module=tier.test_module,
           build_dir=f"sim_build/{tier.name}")


def main():
    if len(sys.argv) < 2:
        print("runnable tiers:")
        for t in RUNNABLE:
            print(f"  {t.name:<7} {t.top:<22} {t.test_module}")
        pending = [t.name for t in TIERS if not t.test_module]
        if pending:
            print("\nelaborate but have no local test yet: " + ", ".join(pending))
        return 0

    which = sys.argv[1]
    if which != "all":
        if which not in BY_NAME:
            print(f"unknown tier {which!r}; known: {', '.join(BY_NAME)}")
            return 2
        tier = BY_NAME[which]
        if not tier.test_module:
            print(f"tier {which} has no local test module yet")
            return 2
        build_and_run(tier)
        return 0

    failed = []
    for tier in RUNNABLE:
        print("=" * 60)
        print(f"tier {tier.name}: {tier.top}")
        print("=" * 60)
        try:
            build_and_run(tier)
        except SystemExit as e:
            if e.code:
                failed.append(tier.name)
        except Exception as e:
            print(f"{tier.name}: {type(e).__name__}: {e}")
            failed.append(tier.name)
    print("=" * 60)
    if failed:
        print(f"FAILED: {', '.join(failed)}")
        return 1
    print(f"all {len(RUNNABLE)} tier(s) passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

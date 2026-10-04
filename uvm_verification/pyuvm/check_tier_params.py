"""check_tier_params.py - do tiers.py's parameters match the SystemVerilog tops?

    python check_tier_params.py            # report
    python check_tier_params.py --check    # exit 1 on any mismatch

WHY (bug 35)
------------
The cocotb path re-states each DUT's parameters in tiers.py because Icarus is
handed the module directly, with no SystemVerilog top to carry the overrides.
That is a SECOND COPY of something the tb files already say, and this project
has been bitten by second copies three times now: check_filelists.py silently
stopped covering a renamed tier (bug 20), the regression lists drifted from the
test sources, and the RAL would have drifted from mqnic_hw.h.

It happened again immediately. tiers.py carried only FIFO_ENABLE for Tier 1b, so
BAR_STRIDE took its default of 1 instead of the tb's 2, and the demux matched
BAR 0/1 instead of BAR 0/2. Four tests failed with what looked exactly like a
routing bug in the RTL.

A DUT run with the wrong parameters is a DIFFERENT DESIGN. It will usually still
elaborate, often still pass, and the tests that fail will accuse the RTL. So the
two copies are compared here rather than trusted.

WHAT THIS DOES NOT DO
---------------------
It resolves only simple localparam expressions - integer literals and the
arithmetic actually used in these tops. A parameter whose value it cannot
resolve is REPORTED AS UNRESOLVED, never silently skipped, because a check that
quietly stops checking is the failure it exists to prevent.
"""

import argparse
import ast
import pathlib
import re
import sys

from tiers import TIERS

ROOT = pathlib.Path(__file__).resolve().parents[1]
TB = ROOT / "tb"

LOCALPARAM = re.compile(
    r"^\s*localparam\s+(?:int\s+|integer\s+)?(?:unsigned\s+)?(\w+)\s*=\s*([^;]+);",
    re.M)
# A module header's own `parameter int NAME = expr,` defaults.
# The value may itself contain parentheses - $clog2(QUEUE_PTR_WIDTH) - so the
# character class has to allow a balanced pair rather than stopping at the
# first ')'. Truncating there yields "$clog2(QUEUE_PTR_WIDTH", which does not
# evaluate, and the parameter is then reported unresolved.
MODPARAM = re.compile(
    r"^\s*parameter\s+(?:int\s+|integer\s+)?(?:unsigned\s+)?(\w+)\s*=\s*"
    r"((?:[^,()]|\([^()]*\))+?)\s*[,)]?\s*$",
    re.M)


def parse_localparams(text, seed=None):
    """Resolve localparams (and module-header parameter defaults) in order.

    `seed` pre-populates the environment, which is how a WRAPPER is handled:
    dut_wrapper_queue_manager passes its own parameters straight through to
    queue_manager, so resolving `.ADDR_WIDTH(ADDR_WIDTH)` needs the wrapper's
    parameter list - and the values the tb top overrode them with.
    """
    seed = seed or {}
    env = {}
    # Module-header parameters first, IN ORDER, because later ones reference
    # earlier ones ($clog2(QUEUE_PTR_WIDTH)). An OVERRIDE from the instantiating
    # top wins over the header default - getting that precedence backwards would
    # silently resolve to the default and defeat the whole check.
    for name, expr in MODPARAM.findall(text):
        if name in seed:
            env[name] = seed[name]
            continue
        v = resolve(expr, env)
        if v is not None:
            env[name] = v
    for name, v in seed.items():
        env.setdefault(name, v)
    # ONE evaluator, not two. This loop used to carry its own copy of the
    # literal-stripping and eval, and when resolve() learned about the ?:
    # ternary this copy did not - so every width localparam in tb_top_tier4d.sv
    # stayed unresolved while the instantiation side resolved fine. A second
    # copy of an evaluator drifts exactly like a second copy of an inventory.
    for name, expr in LOCALPARAM.findall(text):
        v = resolve(expr, env)
        if v is not None:
            env[name] = v
    return env


def parse_instance(text, module):
    """Return {param: expr} for the first `module #( ... ) name (` instantiation."""
    m = re.search(rf"^\s*{re.escape(module)}\s*#\s*\(", text, re.M)
    if not m:
        return None
    i = text.index("(", m.start())
    depth, j = 0, i
    while j < len(text):
        if text[j] == "(":
            depth += 1
        elif text[j] == ")":
            depth -= 1
            if depth == 0:
                break
        j += 1
    body = text[i + 1:j]
    return dict(re.findall(r"\.(\w+)\s*\(\s*([^,()]*(?:\([^()]*\))?[^,()]*?)\s*\)", body))


TERNARY = re.compile(r"^(?P<cond>[^?]+)\?(?P<yes>[^:?]+):(?P<no>.+)$")


def resolve(expr, env):
    """Evaluate a SystemVerilog constant expression.

    Handles the forms these tops actually use: sized literals, $clog2, and the
    ?: ternary that every width in pcie_us_if is written with -

        AXIS_PCIE_RC_USER_WIDTH = AXIS_PCIE_DATA_WIDTH < 512 ? 75 : 161

    Python has no ?:, so without the rewrite below all seven of Tier 4d's width
    parameters come back UNRESOLVED. The caller reports rather than skips those,
    which is the right failure mode, but seven parameters reported as
    unverifiable is barely better than not checking them at all.
    """
    e = expr.strip()
    e = re.sub(r"\b\d+'([dhbo])([0-9a-fA-F_]+)",
               lambda m: str(int(m.group(2).replace("_", ""),
                                 {"d": 10, "h": 16, "b": 2, "o": 8}[m.group(1)])), e)
    e = e.replace("$clog2", "clog2")

    m = TERNARY.match(e)
    if m:
        e = f"(({m.group('yes')}) if ({m.group('cond')}) else ({m.group('no')}))"

    try:
        v = eval(e, {"clog2": lambda x: max(0, (int(x) - 1).bit_length()),
                     "__builtins__": {}}, dict(env))
    except Exception:
        return None
    # A bare comparison (RC_STRADDLE = DATA_WIDTH >= 256) is a bool in Python
    # and a 1-bit value in Verilog.
    return int(v) if isinstance(v, bool) else v


def tb_for(tier):
    """Find the tb file that instantiates this tier's DUT.

    Searching beats guessing the filename: queue_manager is instantiated in
    dut_wrapper_queue_manager.sv, not in tb_top_tier1a.sv, and a name-based
    lookup would have reported it as missing and been "fixed" by an exception.
    """
    base = tier.name.split("-")[0]
    preferred = TB / f"tb_top_tier{base}.sv"
    cands = ([preferred] if preferred.is_file() else []) + sorted(TB.glob("*.sv"))
    pat = re.compile(rf"^\s*{re.escape(tier.top)}\s*#\s*\(", re.M)
    for c in cands:
        if pat.search(c.read_text(encoding="utf-8")):
            return c
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    problems, checked = [], 0
    for tier in TIERS:
        if not tier.params:
            continue
        tb = tb_for(tier)
        if tb is None:
            problems.append(f"{tier.name}: no tb_top file found")
            continue
        text = tb.read_text(encoding="utf-8")
        seed = {}
        # If the DUT sits inside a wrapper, resolve the wrapper's parameters
        # from wherever the wrapper itself is instantiated.
        mod = re.search(r"^module\s+(\w+)", text, re.M)
        if mod and not mod.group(1).startswith("tb_top"):
            for other in sorted(TB.glob("tb_top*.sv")):
                otext = other.read_text(encoding="utf-8")
                outer = parse_instance(otext, mod.group(1))
                if outer:
                    oenv = parse_localparams(otext)
                    seed = {k: resolve(v, oenv) for k, v in outer.items()}
                    seed = {k: v for k, v in seed.items() if v is not None}
                    break
        env = parse_localparams(text, seed)
        inst = parse_instance(text, tier.top)
        if inst is None:
            problems.append(f"{tier.name}: {tier.top} not instantiated in {tb.name}")
            continue

        for k, want in tier.params.items():
            if k not in inst:
                problems.append(
                    f"{tier.name}: tiers.py sets {k}={want} but {tb.name} does not "
                    f"override it (the DUT would use its own default)")
                continue
            got = resolve(inst[k], env)
            if got is None:
                problems.append(
                    f"{tier.name}: {k} = {inst[k]!r} in {tb.name} could not be "
                    "resolved - check it by hand rather than assuming it matches")
                continue
            checked += 1
            if got != want:
                problems.append(
                    f"{tier.name}: {k} is {want} in tiers.py but {got} in "
                    f"{tb.name} - the local run uses a DIFFERENTLY CONFIGURED DUT")

        for k in inst:
            if k not in tier.params:
                problems.append(
                    f"{tier.name}: {tb.name} overrides {k}={inst[k]} but tiers.py "
                    "does not - the local run takes the RTL default")

    for p in problems:
        print("  " + p)
    print(f"{checked} parameter(s) verified against the SystemVerilog tops, "
          f"{len(problems)} problem(s)")
    if args.check and problems:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

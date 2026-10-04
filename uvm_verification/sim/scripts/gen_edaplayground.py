#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause-Views
"""
gen_edaplayground.py - bundle the testbench into EDA Playground's two panes.

Implements : VERIFICATION_STRATEGY.md  §16 (build infrastructure)
Introduced : Step 1 (to obtain a real simulation run without a local licence)

EDA Playground gives you a Design pane and a Testbench pane. It supplies UVM
itself (pick the UVM version in the UI), so the bundle must NOT contain UVM
sources - only `import uvm_pkg::*` and `include "uvm_macros.svh"`, which resolve
against the include path EDA Playground sets up.

The problem this script solves: our packages pull their classes in with
`include "foo.sv"`, and those files do not exist in the browser. So every local
`include is INLINED here, recursively, while `include "uvm_macros.svh" is left
alone. Compile order comes from the filelists, which are the same ones a real
simulator uses - so the bundle cannot drift from the repository.

Usage
-----
  python gen_edaplayground.py                    # Tier 1a (default)
  python gen_edaplayground.py --tier 1a --out edaplayground/tier1a
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

TB_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = TB_ROOT.parent

sys.path.insert(0, str(Path(__file__).parent))
from slang_check import parse_filelist  # noqa: E402

INCLUDE_RE = re.compile(r'^\s*`include\s+"([^"]+)"\s*$')

# Left untouched - provided by the simulator, not by us.
EXTERNAL_INCLUDES = {"uvm_macros.svh", "uvm_pkg.sv"}

BANNER = """// ============================================================================
// {title}
// ----------------------------------------------------------------------------
// GENERATED FILE - do not edit. Produced by sim/scripts/gen_edaplayground.py
// from {sources}
//
// Source of truth is the repository at uvm_verification/. Regenerate after any
// change rather than editing here.
// ============================================================================

"""


def inline_includes(path: Path, incdirs: list[Path], seen: set[Path],
                    depth: int = 0) -> str:
    """Return the file's text with local `include directives expanded."""
    if depth > 32:
        raise RuntimeError(f"`include nesting too deep at {path}")

    out: list[str] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = INCLUDE_RE.match(line)
        if not m:
            out.append(line)
            continue

        name = m.group(1)
        if name in EXTERNAL_INCLUDES:
            out.append(line)          # simulator-provided
            continue

        target = resolve(name, path.parent, incdirs)
        if target is None:
            out.append(f"// [gen] UNRESOLVED `include \"{name}\" - left as-is")
            out.append(line)
            continue

        if target in seen:
            out.append(f"// [gen] `include \"{name}\" already inlined; skipped")
            continue

        seen.add(target)
        out.append(f"// ---- begin inlined: {rel(target)} ----")
        out.append(inline_includes(target, incdirs, seen, depth + 1))
        out.append(f"// ---- end inlined: {rel(target)} ----")

    return "\n".join(out)


def resolve(name: str, local_dir: Path, incdirs: list[Path]) -> Path | None:
    cand = local_dir / name
    if cand.is_file():
        return cand.resolve()
    for d in incdirs:
        cand = d / name
        if cand.is_file():
            return cand.resolve()
    return None


def rel(p: Path) -> str:
    for root in (TB_ROOT, REPO_ROOT):
        try:
            return str(p.relative_to(root)).replace("\\", "/")
        except ValueError:
            continue
    return str(p)


def build(files: list[Path], incdirs: list[Path], title: str,
          sources: str) -> str:
    seen: set[Path] = set()
    chunks = [BANNER.format(title=title, sources=sources)]
    for f in files:
        if not f.is_file():
            print(f"warning: missing {f}", file=sys.stderr)
            continue
        seen.add(f.resolve())
        chunks.append(f"\n// ============ {rel(f)} ============\n")
        chunks.append(inline_includes(f, incdirs, seen))
    return "\n".join(chunks) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tier", default="1a")
    ap.add_argument("--out", default="")
    args = ap.parse_args()

    fl_dir = TB_ROOT / "sim" / "filelists"
    rtl_f = fl_dir / f"rtl_tier{args.tier}.f"
    tb_f = fl_dir / "tb_common.f"

    if not rtl_f.is_file():
        ap.error(f"no RTL filelist for tier {args.tier}: {rtl_f}")

    rtl_files, rtl_inc, _ = parse_filelist(rtl_f)
    tb_files, tb_inc, _ = parse_filelist(tb_f)

    outdir = Path(args.out) if args.out else (TB_ROOT / "edaplayground" / f"tier{args.tier}")
    outdir.mkdir(parents=True, exist_ok=True)

    design = build(rtl_files, rtl_inc,
                   f"Corundum Tier {args.tier} - DESIGN pane",
                   rel(rtl_f))
    (outdir / "design.sv").write_text(design, encoding="utf-8")

    tb = build(tb_files, tb_inc + [TB_ROOT / "tests" / "tier1a"],
               f"Corundum Tier {args.tier} UVM testbench - TESTBENCH pane",
               rel(tb_f))
    (outdir / "testbench.sv").write_text(tb, encoding="utf-8")

    print(f"design.sv     {len(design.splitlines()):6d} lines  "
          f"({len(rtl_files)} RTL file(s))")
    print(f"testbench.sv  {len(tb.splitlines()):6d} lines  "
          f"({len(tb_files)} TB file(s), local `includes inlined)")
    print(f"written to {outdir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

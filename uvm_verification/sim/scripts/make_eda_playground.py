#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause-Views
"""
make_eda_playground.py - multi-file (tabbed) EDA Playground export.

Implements : VERIFICATION_STRATEGY.md  §16 (build infrastructure)
Introduced : Step 1


Layout follows the tabbed convention used for UVM on Playground:

  * every source stays its OWN file, pasted as a named tab in Playground
  * design.sv    - a MANIFEST that `include's the RTL
  * testbench.sv - a MANIFEST that `include's interfaces -> packages -> SVA
                   -> tb top, in strict order, with numbered sections
  * class fragments (files pulled in by a package) are exported as .svh
  * EDA_PLAYGROUND_RUN.md - settings, tab list, expected output

Contrast with gen_edaplayground.py, which concatenates everything into two
large files. Both are generated from the same filelists; the tabbed layout is
easier to debug (errors carry real file names and line numbers) at the cost of
pasting ~30 tabs.

Usage:
  python make_eda_playground.py --tier 1a
"""

from __future__ import annotations

# EDA Playground's two hard limits. Neither is documented anywhere in the
# tool; both were found by hitting them.
PLAYGROUND_TOTAL_LIMIT = 1_000_000   # across ALL tabs
PLAYGROUND_PER_TAB     = 100_000     # any single tab

import argparse
import re
import shutil
import sys
from pathlib import Path

TB_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = TB_ROOT.parent

sys.path.insert(0, str(Path(__file__).parent))
from slang_check import parse_filelist  # noqa: E402

# Test class names contain DIGITS as well as letters - t3_4k_boundary,
# t3_rcb_64_128, t3_addr_3dw. A [a-z_]+ class silently dropped all three from
# the generated run doc, which is worse than an error: the tabs were correct and
# the documentation quietly under-reported what the tier could run.
TEST_RE_TMPL = r"uvm_component_utils\((t%s_[a-z0-9_]+)\)"
INCLUDE_RE = re.compile(r'^(\s*`include\s+")([^"]+)("\s*)$')
EXTERNAL_INCLUDES = {"uvm_macros.svh", "uvm_pkg.sv"}

# Manifest sections for testbench.sv, matched against exported file names.
SECTIONS = [
    ("1) Common package - types, constants, pure functions (no UVM dependency)",
     ["mqnic_vrf_pkg.sv"]),
    ("2) Interfaces - virtual handles to these are typed in the packages below",
     ["mqnic_reset_if.sv", "axil_if.sv", "queue_op_if.sv", "axis_if.sv",
      "csum_cmd_if.sv", "pcie_tlp_if.sv"]),
    ("3) Sequence bases - UVC sequence libraries extend mqnic_base_seq",
     ["seq_pkg.sv"]),
    ("4) UVC packages - each imports mqnic_vrf_pkg and mqnic_seq_pkg",
     ["axil_pkg.sv", "queue_op_pkg.sv", "axis_pkg.sv", "csum_cmd_pkg.sv",
      "pcie_tlp_pkg.sv"]),
    ("5) Reference models",
     ["model_pkg.sv"]),
    ("6) Environment package - imports every UVC plus the models",
     ["env_pkg.sv"]),
    ("7) Test package - imports the environment",
     ["test_pkg.sv"]),
    ("8) Assertions + bind - skipped by +define+MQNIC_NO_SVA on first bring-up",
     ["sva_queue_manager.sv"]),
    ("9) DUT wrappers - bind tier parameters onto the Verilog-2001 RTL",
     ["dut_wrapper_queue_manager.sv"]),
    ("10) TB top: clock/reset, interfaces, DUT, config_db, run_test()",
     ["tb_top_tier1.sv", "tb_top_tier1a.sv", "tb_top_tier1b.sv",
      "tb_top_tier1c.sv"]),
]



def names_last(sections, title, exported):
    """Last file of `title` that is present in `exported`, for spacing."""
    for t, names in sections:
        if t == title:
            present = [n for n in names if n in exported]
            return present[-1] if present else None
    return None


def collect_fragments(path: Path, incdirs: list[Path],
                      out: dict[Path, str], depth: int = 0) -> None:
    """Recursively find files pulled in by `include and record them."""
    if depth > 32:
        raise RuntimeError(f"`include nesting too deep at {path}")
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = INCLUDE_RE.match(line)
        if not m:
            continue
        name = m.group(2)
        if name in EXTERNAL_INCLUDES:
            continue
        target = resolve(name, path.parent, incdirs)
        if target is None:
            print(f"warning: unresolved `include \"{name}\" in {path.name}",
                  file=sys.stderr)
            continue
        if target not in out:
            out[target] = Path(name).stem + ".svh"
            collect_fragments(target, incdirs, out, depth + 1)


def resolve(name: str, local_dir: Path, incdirs: list[Path]) -> Path | None:
    c = local_dir / name
    if c.is_file():
        return c.resolve()
    for d in incdirs:
        c = d / name
        if c.is_file():
            return c.resolve()
    return None


def rewrite_includes(text: str, rename: dict[str, str]) -> str:
    """Point `include directives at the exported .svh names."""
    out = []
    for line in text.splitlines():
        m = INCLUDE_RE.match(line)
        if m and m.group(2) not in EXTERNAL_INCLUDES:
            base = m.group(2)
            if base in rename:
                line = f"{m.group(1)}{rename[base]}{m.group(3)}"
        out.append(line)
    return "\n".join(out) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tier", default="1a")
    ap.add_argument("--out", default="")
    ap.add_argument("--top", default="")
    ap.add_argument("--test", default="")
    args = ap.parse_args()

    if not args.top:  args.top  = f"tb_top_tier{args.tier}"
    if not args.test: args.test = {"1a": "t1a_dequeue_basic",
                                   "1b": "t1b_bar_route",
                                   "1c": "t1c_hash_known_vectors",
                                   "1":  "t1a_reset",
                                   "2":  "t2_wr_rd_single_seg",
                                   "3":  "t3_read_basic",
                                   "3b": "t3b_write_basic",
                                   "3c": "t3c_loopback",
                                   "4a": "t4a_rc_straddle",
                                   "4b": "t4b_cpl_basic",
                                   "4c": "t4c_both_streams",
                                   "4d": "t4d_cfg_extract",
                                   "5":  "t5_rb_walk",
                                   "6":  "t6_rb_walk"}.get(args.tier, "")

    fl_dir = TB_ROOT / "sim" / "filelists"
    rtl_f = fl_dir / f"rtl_tier{args.tier}.f"
    tb_f = fl_dir / f"tb_tier{args.tier}.f"
    if not tb_f.is_file():
        tb_f = fl_dir / "tb_common.f"

    rtl_files, _, _ = parse_filelist(rtl_f)
    tb_files, tb_inc, _ = parse_filelist(tb_f)

    outdir = Path(args.out) if args.out else (TB_ROOT / "edaplayground" /
                                              f"tier{args.tier}_multifile")
    # Clear stale output without removing the directory itself: an editor with a
    # file open holds a lock on the folder on Windows, and rmtree then fails.
    outdir.mkdir(parents=True, exist_ok=True)
    for old in outdir.iterdir():
        if old.is_file() and old.suffix in (".sv", ".svh", ".v"):
            try:
                old.unlink()
            except OSError as e:
                print(f"warning: could not remove stale {old.name}: {e}",
                      file=sys.stderr)

    # Discover class fragments reachable from the manifest files.
    frag: dict[Path, str] = {}
    for f in tb_files:
        collect_fragments(f, tb_inc, frag)

    rename = {p.name: newname for p, newname in frag.items()}

    # ---- export RTL, verbatim (splitting only if a tab would be too big) ----
    #
    # EDA Playground rejects any tab over 100,000 characters, and two Corundum
    # files exceed it (mqnic_core.v at 217 KB, mqnic_interface.v at 142 KB).
    #
    # The split is PURELY TEXTUAL: the file is cut at line boundaries into
    # <stem>_pN.vh fragments, and the tab that keeps the original name becomes
    # nothing but `include directives in order. `include is preprocessor
    # concatenation, so what the compiler sees is BYTE-IDENTICAL to the original
    # file - the split cannot change behaviour, and it is verified below rather
    # than assumed.
    #
    # This affects the EXPORT ONLY. sim/filelists/*.f still point at the real
    # files, so a batch simulator compiles the originals and never sees a
    # fragment. The Playground copy is a build artifact, not a second source.
    PLAYGROUND_TAB_LIMIT = 100_000
    SPLIT_TARGET = 80_000            # margin, so a tab is never near the cap

    split_report = []
    for f in rtl_files:
        raw = f.read_bytes()
        if len(raw) <= PLAYGROUND_TAB_LIMIT:
            shutil.copyfile(f, outdir / f.name)
            continue

        # BYTES, not text. read_text/write_text translate line endings, which
        # on Windows turns every LF into CRLF and makes the rebuilt file larger
        # than the original. That is functionally harmless in Verilog - but a
        # verification step that compares AFTER translation reports "identical"
        # while the bytes differ, which is worse than not checking.
        lines = raw.splitlines(keepends=True)
        parts, cur, cur_len = [], [], 0
        for ln in lines:
            if cur_len + len(ln) > SPLIT_TARGET and cur:
                parts.append(b"".join(cur))
                cur, cur_len = [], 0
            cur.append(ln)
            cur_len += len(ln)
        if cur:
            parts.append(b"".join(cur))

        names = []
        for i, chunk in enumerate(parts, 1):
            nm = f"{f.stem}_p{i}.vh"
            (outdir / nm).write_bytes(chunk)
            names.append(nm)

        stub = [
            "// SPDX-License-Identifier: BSD-2-Clause-Views",
            "//" + "-" * 73,
            f"// {f.name} - SPLIT FOR EDA PLAYGROUND, content unchanged",
            "//" + "-" * 73,
            "// GENERATED by sim/scripts/make_eda_playground.py.",
            "//",
            f"// The original is {len(raw):,} characters and Playground rejects any tab",
            "// over 100,000. It is cut at line boundaries into the fragments below;",
            "// `include is preprocessor concatenation, so the compiler sees exactly the",
            "// original BYTES - verified byte-for-byte after writing, without any line",
            "// ending translation.",
            "//",
            "// THE REAL FILE IS NOT MODIFIED. sim/filelists/*.f point at the original in",
            "// fpga/, so a batch simulator compiles that and never sees these fragments.",
            "// Paste each fragment as its own Playground tab, named exactly as below.",
            "//" + "-" * 73,
            "",
        ]
        stub += [f'`include "{n}"' for n in names]
        (outdir / f.name).write_bytes((chr(10).join(stub) + chr(10)).encode("utf-8"))

        # Byte-for-byte, against the ORIGINAL on disk.
        rebuilt = b"".join((outdir / n).read_bytes() for n in names)
        if rebuilt != raw:
            print(f"ERROR: split of {f.name} is not byte-identical "
                  f"({len(raw)} -> {len(rebuilt)})", file=sys.stderr)
            return 1
        split_report.append((f.name, len(raw), len(names)))

    # ---- export manifest-listed TB files, with include rewrites ------------
    for f in tb_files:
        txt = f.read_text(encoding="utf-8", errors="replace")
        (outdir / f.name).write_text(rewrite_includes(txt, rename), encoding="utf-8")

    # ---- export class fragments as .svh ------------------------------------
    #
    # ONLY THE TIERS THIS EXPORT NEEDS.
    #
    # Playground caps the TOTAL across all files at 1,000,000 characters, and
    # every export was compiling all eleven tiers' environments and tests -
    # ~900 KB, roughly 90% of the budget, for code the tier never instantiates.
    # Three exports were already over the cap and the rest were one test away
    # from it.
    #
    # A tier-specific file is one whose name carries a tier number. Anything
    # without one is shared infrastructure (scoreboard base, models, UVCs,
    # coverage) and is always kept - guessing at those dependencies would be
    # fragile, and they are small.
    tier_tag = f"tier{args.tier}"

    def tier_specific(name: str):
        """Return the tier a file belongs to, or None if it is shared.

        The suffix class is [a-z], not [a-c]. It was [a-c] when the deepest
        suffix in the project was 4c, and when Tier 4d arrived tier4d_env.sv and
        tier4d_tests.sv silently reclassified as SHARED - so every export
        started carrying a tier it does not instantiate. That is budget spent on
        nothing, on exports that are already close to the cap.
        """
        m = re.match(r"^(tier\d[a-z]?)_", name)
        return m.group(1) if m else None

    def wanted(name: str) -> bool:
        t = tier_specific(name)
        return (t is None) or (t == tier_tag)

    dropped = []
    for src, newname in frag.items():
        if not wanted(src.name):
            dropped.append(newname)
            continue
        txt = src.read_text(encoding="utf-8", errors="replace")
        (outdir / newname).write_text(rewrite_includes(txt, rename), encoding="utf-8")

    # The packages that `include them must lose those lines too, or the compile
    # fails on a missing file rather than simply being smaller.
    dropped_set = set(dropped)
    for pkg in ("env_pkg.sv", "test_pkg.sv"):
        q = outdir / pkg
        if not q.is_file():
            continue
        keep = []
        for line in q.read_text(encoding="utf-8").splitlines():
            m = re.search(r'`include\s+"([^"]+)"', line)
            if m and m.group(1) in dropped_set:
                keep.append(f"// [export] omitted, not used by {tier_tag}: {m.group(1)}")
            else:
                keep.append(line)
        q.write_text(chr(10).join(keep) + chr(10), encoding="utf-8")

    # ---- design.sv manifest -------------------------------------------------
    design = [
        "// SPDX-License-Identifier: BSD-2-Clause-Views",
        "//-------------------------------------------------------------------------",
        "// design.sv - EDA Playground DESIGN pane",
        "//-------------------------------------------------------------------------",
        "// GENERATED by sim/scripts/make_eda_playground.py - do not edit.",
        "//",
        f"// DUT for Tier {args.tier}: {', '.join(f.stem for f in rtl_files)}.",
        "//",
        ("// NOTE: files from rtl_patched/ carry a ONE-LINE change each; their"
         if any("rtl_patched" in str(f) for f in rtl_files) else "//"),
        ("// headers say exactly what and why (bug 13). Everything else is"
         if any("rtl_patched" in str(f) for f in rtl_files) else "//"),
        ("// UNMODIFIED Corundum RTL, copied verbatim - no"
         if any("rtl_patched" in str(f) for f in rtl_files)
         else "// UNMODIFIED Corundum RTL, copied verbatim from the repository - no"),
        "// testbench code lives in this pane. Verify with the byte-comparison in",
        "// EDA_PLAYGROUND_RUN.md if a tab is ever edited by hand.",
        "//",
        "// No module below instantiates a vendor primitive, which is what makes",
        "// this tier runnable on Playground with no unisim/secureip library.",
        "//-------------------------------------------------------------------------",
        "",
    ]
    for f in rtl_files:
        design.append(f'`include "{f.name}"')
    (outdir / "design.sv").write_text("\n".join(design) + "\n", encoding="utf-8")

    # ---- testbench.sv manifest ---------------------------------------------
    exported = [f.name for f in tb_files]
    tb = [
        "// SPDX-License-Identifier: BSD-2-Clause-Views",
        "//-------------------------------------------------------------------------",
        "// testbench.sv - EDA Playground TESTBENCH pane (the compile manifest)",
        "//-------------------------------------------------------------------------",
        "// GENERATED by sim/scripts/make_eda_playground.py - do not edit.",
        f"// Include order is taken from sim/filelists/{tb_f.name} so this manifest",
        "// cannot drift out of step with the real filelist.",
        "//",
        "// This is the ONLY file the Testbench pane compiles. Every other .sv and",
        "// .svh below must exist as a named tab, spelled exactly.",
        "//",
        "// ORDER IS STRICT: VCS/Questa/Xcelium resolve package imports in compile",
        "// order. A package must precede anything that imports it.",
        "//",
        "// Settings (left sidebar):",
        "//   Language/UVM : SystemVerilog/Verilog + UVM 1.2",
        "//   Simulator    : Synopsys VCS  (Aldec Riviera-PRO also works; NOT Icarus)",
        f"//   Top module   : {args.top}",
        f"//   Run options  : +UVM_TESTNAME={args.test}",
        "//   First bring-up: add +define+MQNIC_NO_SVA to drop the interface assertions",
        "//",
        "// See EDA_PLAYGROUND_RUN.md for the tab list and expected output.",
        "//-------------------------------------------------------------------------",
        "",
        "`timescale 1ns/1ps",
        "",
    ]
    # -------------------------------------------------------------------------
    # EMIT IN FILELIST ORDER. The sections below only add comments - they must
    # never reorder.
    #
    # The previous version grouped by section and appended anything unrecognised
    # at the end, which silently moved dma_ram_if/dma_ram_pkg AFTER env_pkg and
    # broke a VCS compile ("dma_ram_cfg should be a valid type"). The filelist is
    # the single source of truth for compile order - documented as such in
    # tb_common.f - so the manifest must follow it, not impose its own.
    # -------------------------------------------------------------------------
    section_of: dict[str, str] = {}
    for title, names in SECTIONS:
        for n in names:
            section_of[n] = title

    emitted_section = None
    unlabelled_open = False
    for n in exported:
        title = section_of.get(n)
        if title is not None and title != emitted_section:
            tb.append(f"// {title}")
            emitted_section = title
            unlabelled_open = False
        elif title is None and not unlabelled_open:
            tb.append("// (no section assigned - emitted in filelist order)")
            emitted_section = None
            unlabelled_open = True
        tb.append(f'`include "{n}"')
        if title is not None:
            tb.append("") if n == names_last(SECTIONS, title, exported) else None

    tb.append("")

    (outdir / "testbench.sv").write_text("\n".join(tb), encoding="utf-8")

    # ---- EDA_PLAYGROUND_RUN.md ---------------------------------------------
    # Generated, not hand-written: a hand-written tab list goes stale the moment
    # a file is added, and a wrong tab list is worse than none.
    tab_names = sorted(f.name for f in outdir.iterdir()
                       if f.is_file() and f.suffix in (".sv", ".svh", ".v")
                       and f.name not in ("design.sv", "testbench.sv"))
    rtl_names = sorted(f.name for f in rtl_files)
    iface     = [n for n in tab_names if n.endswith("_if.sv")]
    pkgs      = [n for n in tab_names if n.endswith("_pkg.sv")]
    frags     = [n for n in tab_names if n.endswith(".svh")]
    other     = [n for n in tab_names if n not in rtl_names + iface + pkgs + frags]

    joined = chr(10).join((outdir / f).read_text(encoding="utf-8",
                                                 errors="replace")
                          for f in frags)
    # The unified tier-1 export carries every t1a/t1b/t1c test.
    tier_pat = "1[abc]" if args.tier == "1" else args.tier
    tests = sorted(set(re.findall(TEST_RE_TMPL % tier_pat, joined)))

    def block(title, names):
        if not names:
            return ""
        nl = chr(10)
        return "### " + title + nl + "```" + nl + nl.join(names) + nl + "```" + nl + nl

    run_md = f"""# Running Corundum Tier {args.tier} on EDA Playground

GENERATED by `sim/scripts/make_eda_playground.py` - regenerate rather than
editing in place:

```
python sim/scripts/make_eda_playground.py --tier {args.tier}
```

The RTL in the Design pane is **unmodified Corundum source**, copied verbatim
from the repository. No testbench code lives in that pane.

---

## Settings (left sidebar)

- **Languages & Libraries:** SystemVerilog/Verilog - **UVM 1.2**
- **Tools & Simulators:** **Synopsys VCS** (Aldec Riviera-PRO also works).
  **Not Icarus** - Icarus has no UVM.
- **Top module:** `{args.top}`
- **Run options:** `+UVM_TESTNAME={args.test}`
- **First bring-up:** add `+define+MQNIC_NO_SVA` to skip the interface
  assertions, get one test green, then remove it.
- *Open EPWave after run*: tick, and add `+WAVES` to Run options.

---

## Panes and tabs

- **Design pane:** paste `design.sv` - it `include`s the RTL below.
- **Testbench pane:** paste `testbench.sv` - the compile manifest.
- **Add all {len(tab_names)} files below as tabs**, exact filenames. Panel order
  does not matter; the manifests' `include order does.

{block("RTL - the DUTs (pulled in by design.sv)", rtl_names)}{block("Interfaces", iface)}{block("Packages (entry points included by the manifest)", pkgs)}{block("Other manifest files", other)}{block("Class fragments (pulled in by the packages - must exist as tabs)", frags)}---

## Tests in this tier

Set one as `+UVM_TESTNAME=`:

```
{chr(10).join(tests) if tests else args.test}
```

Verdict format, printed by `mqnic_base_test.report_phase`:

```
=========================================================
 test      : <name>
 errors    : 0
 fatals    : 0
 warnings  : 0
 TEST PASSED
=========================================================
```

Anything else is a failure - **including a run that prints no verdict at all**,
which means the test never reached `report_phase`.

---

## Useful run options

```
+UVM_VERBOSITY=UVM_HIGH      transaction-level logging from every monitor
+MQNIC_TIMEOUT_NS=200000     shorten the watchdog while triaging a hang
+MQNIC_NO_AUTO_RESET         skip the automatic power-on reset
+WAVES                       dump.vcd for EPWave
+define+MQNIC_NO_SVA         compile out every assertion
+MQNIC_NO_LIVENESS           disable the "eventually answered" properties;
                             REQUIRED by t3_cpl_dropped, which withholds
                             completions on purpose
```

## Note on the shared tab set

Every tier export shares an identical set of {len(frags)} `.svh` fragment
tabs. Only `design.sv`, `testbench.sv`, the TB top and the RTL tabs differ, so
the fragments can be pasted once and reused across tiers.
"""
    (outdir / "EDA_PLAYGROUND_RUN.md").write_text(run_md, encoding="utf-8")

    n_tabs = len(tab_names)
    print(f"exported to {outdir}")
    print(f"  RTL files      : {len(rtl_files)}")
    print(f"  manifest files : {len(tb_files)}")
    print(f"  class fragments: {len(frag)} (exported as .svh)")
    print(f"  tabs to paste  : {n_tabs}")
    for nm, sz, k in split_report:
        print(f"  split          : {nm} ({sz:,} chars) -> {k} fragment(s), verified identical")

    # ---- does it actually fit? ---------------------------------------------
    #
    # Playground caps the TOTAL across every tab at 1,000,000 characters. Until
    # now nothing checked it, so an over-budget tier produced a complete-looking
    # export that cannot be run - the failure only shows up as a validation
    # error in the browser, long after the export looks finished.
    #
    # Tier 5 is 171% of the budget in the DESIGN pane alone and Tier 6 is 193%.
    # Neither can ever be exported: mqnic_core.v is 216,760 characters on its
    # own, twice the PER-FILE cap, and it cannot be split because a module has
    # to be one file. Those tiers run locally under Icarus instead
    # (pyuvm/runner.py), which is why that path exists.
    total = sum(len(p.read_text(encoding="utf-8", errors="replace"))
                for p in sorted(outdir.iterdir()) if p.is_file())
    pct = total / PLAYGROUND_TOTAL_LIMIT * 100
    print(f"  total size     : {total:,} chars ({pct:.0f}% of the "
          f"{PLAYGROUND_TOTAL_LIMIT:,} budget)")
    if total > PLAYGROUND_TOTAL_LIMIT:
        print()
        print(f"  OVER BUDGET by {total - PLAYGROUND_TOTAL_LIMIT:,} characters. "
              "This export CANNOT run on EDA Playground.")
        print("  Run this tier locally instead:  python pyuvm/runner.py "
              f"{args.tier}")

        # The directory now looks like a finished export and its run doc gives
        # step-by-step instructions for pasting it in. Say so IN THE DOC, not
        # only on a console line nobody will see again. A complete-looking
        # artifact that silently cannot work is the failure mode this project
        # has fixed four times elsewhere.
        doc = outdir / "EDA_PLAYGROUND_RUN.md"
        banner = (
            f"> ## THIS EXPORT CANNOT RUN ON EDA PLAYGROUND\n"
            f">\n"
            f"> It is **{total:,} characters**, "
            f"{total / PLAYGROUND_TOTAL_LIMIT:.0%} of the "
            f"{PLAYGROUND_TOTAL_LIMIT:,}-character total budget - "
            f"{total - PLAYGROUND_TOTAL_LIMIT:,} over.\n"
            f">\n"
            f"> Nothing can be split to fix it: `mqnic_core.v` alone is 216,760\n"
            f"> characters, twice the 100,000 per-tab cap, and a module has to be\n"
            f"> one file.\n"
            f">\n"
            f"> **Run this tier locally instead:**\n"
            f">\n"
            f">     python pyuvm/runner.py {args.tier}\n"
            f">\n"
            f"> That path exists precisely because of this limit - real UVM\n"
            f"> phases and sequences on the real RTL, under Icarus, with no\n"
            f"> licence. The instructions below are kept only for reference.\n\n"
            "---\n\n")
        doc.write_text(banner + doc.read_text(encoding="utf-8"), encoding="utf-8")
        print(f"  marked {doc.name} as NOT RUNNABLE")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

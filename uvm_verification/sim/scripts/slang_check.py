#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause-Views
"""
slang_check.py - static syntax / semantic check for the mqnic UVM testbench.

Implements : VERIFICATION_STRATEGY.md  §16 (build infrastructure)
Introduced : Step 0 (infrastructure)

Uses pyslang to check SystemVerilog sources without a commercial simulator.
This is the fast inner-loop check: it catches syntax errors, undeclared
identifiers, type mismatches, port-connection errors and signedness bugs long
before a simulator licence is involved.

Two modes:

  --mode syntax   Parse only. No elaboration, no name resolution. Works on every
                  file including UVM-dependent ones even when UVM sources are
                  absent.

  --mode elab     Full elaboration. Resolves imports, types and hierarchy.
                  Requires UVM sources on the include path for any file that
                  imports uvm_pkg (see --uvm-home).

Examples
--------
  python slang_check.py --mode syntax uvc/common/mqnic_vrf_pkg.sv
  python slang_check.py --mode elab -f sim/filelists/tb_common.f
  python slang_check.py --mode elab --uvm-home /opt/uvm-1.2 -f sim/filelists/tb_common.f
  python slang_check.py --mode syntax --all          # every .sv under the TB root
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

try:
    import pyslang
    from pyslang.syntax import SyntaxTree
    from pyslang.ast import Compilation
except ImportError:  # pragma: no cover
    sys.stderr.write(
        "error: pyslang is not installed.\n"
        "       pip install pyslang\n"
    )
    sys.exit(2)


# Repository layout ----------------------------------------------------------

TB_ROOT = Path(__file__).resolve().parents[2]          # uvm_verification/
REPO_ROOT = TB_ROOT.parent                             # Corundum_PCIe/

RTL_INCDIRS = [
    REPO_ROOT / "fpga" / "common" / "rtl",
    REPO_ROOT / "fpga" / "lib" / "pcie" / "rtl",
    REPO_ROOT / "fpga" / "lib" / "eth" / "rtl",
    REPO_ROOT / "fpga" / "lib" / "axi" / "rtl",
    REPO_ROOT / "fpga" / "lib" / "axis" / "rtl",
]


# Filelist parsing -----------------------------------------------------------

def parse_filelist(path: Path, seen: set[Path] | None = None) -> tuple[list[Path], list[Path], list[str]]:
    """Parse a .f filelist. Returns (sources, incdirs, defines).

    Supports: // and # comments, +incdir+, +define+, -f/-F nesting,
    ${VAR} and $VAR expansion, blank lines.
    """
    if seen is None:
        seen = set()
    path = path.resolve()
    if path in seen:
        return [], [], []
    seen.add(path)

    sources: list[Path] = []
    incdirs: list[Path] = []
    defines: list[str] = []

    base = path.parent
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("//")[0].strip()
        if not line or line.startswith("#"):
            continue
        line = os.path.expandvars(line)

        if line.startswith("+incdir+"):
            for d in line[len("+incdir+"):].split("+"):
                if d:
                    incdirs.append((base / d).resolve())
        elif line.startswith("+define+"):
            for d in line[len("+define+"):].split("+"):
                if d:
                    defines.append(d)
        elif line.startswith(("-f", "-F")):
            nested = line.split(None, 1)
            if len(nested) == 2:
                s, i, d = parse_filelist((base / nested[1]).resolve(), seen)
                sources += s
                incdirs += i
                defines += d
        elif line.startswith("-"):
            continue  # unrecognised switch; ignore
        else:
            sources.append((base / line).resolve())

    return sources, incdirs, defines


# Diagnostics ----------------------------------------------------------------

class Report:
    def __init__(self) -> None:
        self.errors = 0
        self.warnings = 0
        self.text: list[str] = []

    def add(self, s: str) -> None:
        if s:
            self.text.append(s)

    def tally(self, rendered: str) -> None:
        for line in rendered.splitlines():
            if ": error:" in line:
                self.errors += 1
            elif ": warning:" in line:
                self.warnings += 1


def _block_is_tb(block: str) -> bool:
    """True when a rendered diagnostic block points at a testbench file.

    Diagnostics are rendered as '<path>:<line>:<col>: severity: text'. Anything
    that resolves under the testbench root is ours; everything else is DUT RTL.
    """
    head = block.strip().split(":", 1)[0].strip()
    if not head:
        return False
    try:
        p = (Path.cwd() / head).resolve()
    except (OSError, ValueError):
        return False
    try:
        p.relative_to(TB_ROOT)
    except ValueError:
        return False
    # ext/ holds third-party sources (UVM). Diagnostics there are not ours and
    # must not be reported under the testbench scope, or they mask real ones.
    try:
        p.relative_to(TB_ROOT / "ext")
        return False
    except ValueError:
        return True


def render(compilation: Compilation, diags, suppress: list[str],
           scope: str = "all") -> str:
    engine = pyslang.DiagnosticEngine(compilation.sourceManager)
    client = pyslang.TextDiagnosticClient()
    engine.addClient(client)
    for d in diags:
        engine.issue(d)
    out = client.getString()

    if suppress or scope != "all":
        kept = []
        for block in out.split("\n\n"):
            if not block.strip():
                continue
            if suppress and any(s in block for s in suppress):
                continue
            if scope == "tb" and not _block_is_tb(block):
                continue
            if scope == "rtl" and _block_is_tb(block):
                continue
            kept.append(block)
        out = "\n\n".join(kept)
    return out


# Checks ---------------------------------------------------------------------

def check_syntax(files: list[Path], incdirs: list[Path], defines: list[str],
                 suppress: list[str], verbose: bool, scope: str = "all") -> Report:
    rep = Report()
    sm = make_source_manager(incdirs, defines)

    for f in files:
        if not f.exists():
            rep.text.append(f"error: no such file: {f}")
            rep.errors += 1
            continue
        tree = SyntaxTree.fromFile(str(f), sm)
        diags = tree.diagnostics
        if len(diags) == 0:
            if verbose:
                rep.text.append(f"ok (syntax): {rel(f)}")
            continue
        comp = Compilation()
        comp.addSyntaxTree(tree)
        out = render(comp, diags, suppress, scope)
        rep.add(out)
        rep.tally(out)
    return rep


def check_elab(files: list[Path], incdirs: list[Path], defines: list[str],
               suppress: list[str], verbose: bool, scope: str = "all") -> Report:
    rep = Report()
    sm = make_source_manager(incdirs, defines)

    comp = Compilation()
    missing = False
    for f in files:
        if not f.exists():
            rep.text.append(f"error: no such file: {f}")
            rep.errors += 1
            missing = True
            continue
        tree = SyntaxTree.fromFile(str(f), sm)
        comp.addSyntaxTree(tree)
    if missing:
        return rep

    diags = comp.getAllDiagnostics()
    out = render(comp, diags, suppress, scope)
    rep.add(out)
    rep.tally(out)
    if verbose and not out.strip():
        rep.text.append(f"ok (elab): {len(files)} file(s)")
    return rep


def make_source_manager(incdirs: list[Path], defines: list[str]):
    """Build a SourceManager carrying the include search path.

    pyslang 11 does not expose PreprocessorOptions, so `+incdir+` is applied
    through SourceManager.addUserDirectories() and `+define+` is not currently
    supported. The testbench uses no compile-time defines; if that changes,
    generate a header and `include it rather than relying on +define+.
    """
    sm = pyslang.SourceManager()
    dirs = [str(d) for d in incdirs if d.is_dir()]
    if dirs:
        try:
            sm.addUserDirectories(dirs)
        except TypeError:
            for d in dirs:
                sm.addUserDirectories(d)
    if defines:
        sys.stderr.write(
            "warning: +define+ is not supported by this pyslang build; "
            f"ignoring {len(defines)} define(s)\n"
        )
    return sm


def rel(p: Path) -> str:
    try:
        return str(p.relative_to(TB_ROOT))
    except ValueError:
        try:
            return str(p.relative_to(REPO_ROOT))
        except ValueError:
            return str(p)



# Portability and convention lint ---------------------------------------------

import re as _re
IFACE_DECL_RE = _re.compile(r"^\s*interface\s+([A-Za-z_]\w*)", _re.M)


def with_includes(files: list[Path], incdirs: list[Path]) -> list[Path]:
    """The given files plus every file they `include, transitively.

    The portability rules are TEXT rules, so they only see what they are given.
    Fed the filelist alone, they never saw a class body: env/, tests/ and
    model/ are all `include`d into packages. A cast in a while condition in
    env/us_host.sv sailed through rule 6 and turned a 20000-cycle timeout into
    a 20-cycle one on xsim.
    """
    import re
    inc_re = re.compile(r'^\s*`include\s+"([^"]+)"', re.M)
    seen: list[Path] = []
    todo = list(files)
    while todo:
        f = todo.pop(0)
        if f in seen or not f.is_file():
            continue
        seen.append(f)
        if "ext" in f.parts:
            continue
        for name in inc_re.findall(f.read_text(encoding="utf-8", errors="replace")):
            for d in [f.parent] + list(incdirs):
                c = (d / name).resolve()
                if c.is_file():
                    if "ext" not in c.parts:
                        todo.append(c)
                    break
    return seen


def portability_lint(files: list[Path],
                     all_files: list[Path] | None = None) -> tuple[list[str], int]:
    """Catch constructs slang accepts but commercial simulators reject.

    Currently one rule, learned the hard way on VCS:

      interface_name::PARAM   is ILLEGAL SystemVerilog. The :: scope-resolution
      operator applies to packages and classes only, never to an interface
      definition. slang resolves it happily; VCS rejects it with
      SV-LCM-PND "Package not defined", Questa and Xcelium likewise.

      Fix: restate the constant locally, or read it hierarchically through the
      interface INSTANCE in a procedural (non-constant) context.

    Rule 2 - IFACE_ARRAY: a procedural `for (int p ...)` loop indexing an
      interface ARRAY, e.g. some_vif[p].sig. The index must be an
      elaboration-time constant; VCS rejects it with IIXMR. Use a genvar
      generate block instead.

    Rule 4 - TLP_GATING (a CONVENTION rule, not a portability one): every
      pcie_tlp_if instance in a testbench top must state explicitly whether its
      producer gates sop/eop with valid, by assigning sop_eop_gated. Leaving it
      to the default is how a_sop_implies_valid fired twice on producers that
      were behaving correctly - dma_if_pcie_rd ties the framing bits high,
      dma_if_pcie_wr latches them, and both leave sop set while valid is low.
      Neither is a violation; assuming otherwise cost two simulation rounds.
      One line per instance forces the question to be answered on purpose.

    Rule 3 - CAST_METHOD: a method call applied directly to a cast expression,
      e.g. `my_enum_e'(x).name()`. slang accepts it; VCS rejects it with a bare
      "Syntax error ... token is '.'" that points at the macro expansion rather
      than the source line, which makes it needlessly hard to find. Assign the
      cast to a variable and call the method on that.

    Rules 5-7 - learned on Vivado xsim 2026.1 (docs/bringup_log.md, "Vivado xsim"):
      5 DEFAULT_DISABLE: `default disable iff` - XSIM 43-3980, not simulatable.
        Write `disable iff (...)` on each assertion instead; same meaning.
      6 WHILE_CAST: a cast inside a `while (...)` condition. xsim ACCEPTS it and
        mis-evaluates it - `while (c < int'(n))` runs zero times - so this one is
        silent wrong behaviour, not an error. `for` loops are unaffected.
      7 CONCAT_SELECT: a part-select applied to a concatenation, `{a, b}[3:0]` -
        XSIM 43-3980 "Indexed Expression".
    """
    import re

    ifaces: set[str] = set()
    texts: dict[Path, str] = {}
    for f in files:
        if not f.is_file():
            continue
        t = f.read_text(encoding="utf-8", errors="replace")
        texts[f] = t
        ifaces.update(IFACE_DECL_RE.findall(t))

    msgs: list[str] = []
    n = 0
    if not ifaces:
        return msgs, 0

    pat = re.compile("(?<![A-Za-z0-9_])(" + "|".join(sorted(re.escape(i) for i in ifaces)) + ")[ \t]*::")
    for f, t in texts.items():
        for ln, line in enumerate(t.splitlines(), 1):
            if line.lstrip().startswith("//"):
                continue
            m = pat.search(line)
            if m:
                n += 1
                msgs.append(
                    f"{rel(f)}:{ln}: error: '{m.group(1)}::' - :: is package/class "
                    f"scope resolution and cannot address an interface; VCS rejects "
                    f"this (SV-LCM-PND)\n    {line.strip()}")

    # ---- rule 2: procedural loop variable indexing an interface ARRAY -------
    # `for (int p ...) ... some_vif[p].sig` is an illegal cross-module reference:
    # the index must be an elaboration-time constant. VCS rejects it with IIXMR
    # "index is not constant"; slang accepts it. The fix is a genvar block.
    for f, t in texts.items():
        lines = t.splitlines()
        for ln, line in enumerate(lines, 1):
            m_for = re.search(r"\bfor\s*\(\s*int\s+(\w+)\s*=", line)
            if not m_for:
                continue
            var = m_for.group(1)
            body = lines[ln:ln + 25]
            hit = re.compile(r"\w+\[\s*" + re.escape(var) + r"\s*\]\s*\.")
            for off, bl in enumerate(body):
                if bl.lstrip().startswith("//"):
                    continue
                mh = hit.search(bl)
                if mh:
                    n += 1
                    msgs.append(
                        f"{rel(f)}:{ln + off + 1}: error: interface array indexed by "
                        f"procedural loop variable '{var}' - illegal cross-module "
                        f"reference, VCS rejects with IIXMR; use a genvar block"
                        + chr(10) + "    " + bl.strip())
                    break

    # ---- rule 3: method call directly on a cast expression -----------------
    # `some_enum_e'(expr).name()` parses in slang but not in VCS, which reports
    # it as a syntax error inside whatever macro happened to contain it.
    cast_method = re.compile(r"'\s*\([^()]*(?:\([^()]*\)[^()]*)*\)\s*\.\s*[A-Za-z_]\w*\s*\(")
    for f, t in texts.items():
        for ln, line in enumerate(t.splitlines(), 1):
            stripped = line.lstrip()
            if stripped.startswith("//"):
                continue
            m = cast_method.search(line)
            if m:
                n += 1
                msgs.append(
                    f"{rel(f)}:{ln}: error: method call applied directly to a cast "
                    f"expression - VCS rejects this (SE, token is '.'); assign the "
                    f"cast to a variable first"
                    + chr(10) + "    " + stripped)

    # ---- rule 4: pcie_tlp_if instances must declare their framing gating ---
    # See the docstring. Only checked in files that instantiate the interface,
    # i.e. testbench tops.
    inst_re = re.compile(r"^\s*pcie_tlp_if\s+(\w+)\s*\(", re.M)
    for f, t in texts.items():
        insts = inst_re.findall(t)
        if not insts:
            continue
        for name in insts:
            if not re.search(re.escape(name) + r"\s*\.\s*sop_eop_gated\s*=", t):
                n += 1
                msgs.append(
                    f"{rel(f)}: error: pcie_tlp_if instance '{name}' does not set "
                    f"sop_eop_gated - state it explicitly (1 if the producer gates "
                    f"sop/eop with valid, 0 if it ties or latches them)")

    # ---- rules 5-7: constructs Vivado xsim rejects or mis-simulates ---------
    xsim_rules = [
        (re.compile(r"^\s*default\s+disable\s+iff\b"),
         "`default disable iff` - xsim cannot simulate it (XSIM 43-3980); put "
         "`disable iff (...)` on each assertion"),
        (re.compile(r"\bwhile\s*\(.*\w'\s*\("),
         "cast inside a while condition - xsim mis-evaluates it silently (the "
         "loop runs 0 times); hoist the cast into a variable or use a for loop"),
        (re.compile(r"\}\s*\[[^\]]*\]"),
         "part-select on a concatenation - xsim rejects it (XSIM 43-3980 "
         "'Indexed Expression'); select from a named signal instead"),
        # Rule 9: small/medium/large are charge-strength keywords. slang
        # accepts them as identifiers (a covergroup bin named `medium`); xsim
        # rejects them (VRFC 10-8549), and took six tiers' compiles down with it.
        (re.compile(r"\b(?:small|medium|large)\b"),
         "`small`/`medium`/`large` are SystemVerilog keywords (charge strength) - "
         "xsim rejects them as identifiers (VRFC 10-8549)"),
        # Rule 8: `before` is a keyword (solve ... before). slang accepts it as
        # an identifier; xsim rejects it (VRFC 10-8549). Written twice.
        (re.compile(r"^(?!.*\bsolve\b).*\bbefore\b"),
         "`before` used as an identifier - it is a SystemVerilog keyword "
         "(solve ... before); xsim rejects it (VRFC 10-8549)"),
    ]
    # Rules 5-8 are line-local, so they are safe on class code and run on the
    # included files too (see with_includes). Rules 1-4 are tuned for
    # testbench tops and stay on the filelist.
    xtexts = dict(texts)
    for f in (all_files or []):
        if f not in xtexts and f.is_file():
            xtexts[f] = f.read_text(encoding="utf-8", errors="replace")
    for f, t in xtexts.items():
        for ln, line in enumerate(t.splitlines(), 1):
            code = line.split("//", 1)[0]
            code = re.sub(r'"(?:[^"\\]|\\.)*"', '""', code)   # ignore string contents
            if not code.strip():
                continue
            for rx, why in xsim_rules:
                if rx.search(code):
                    n += 1
                    msgs.append(f"{rel(f)}:{ln}: error: {why}" + chr(10)
                                + "    " + line.strip())

    return msgs, n


# CLI ------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*", help="SystemVerilog source files")
    ap.add_argument("-f", "--filelist", action="append", default=[],
                    help="filelist (.f); may be given multiple times")
    ap.add_argument("--mode", choices=["syntax", "elab"], default="syntax",
                    help="syntax = parse only (default); elab = full elaboration")
    ap.add_argument("--all", action="store_true",
                    help="check every .sv under the testbench root")
    ap.add_argument("--incdir", action="append", default=[],
                    help="additional include directory")
    ap.add_argument("--define", action="append", default=[],
                    help="additional +define+ macro")
    ap.add_argument("--uvm-home", default=os.environ.get("UVM_HOME", ""),
                    help="UVM source root; adds <root>/src to include path and "
                         "compiles uvm_pkg.sv first (elab mode)")
    ap.add_argument("--scope", choices=["all", "tb", "rtl"], default="all",
                    help="restrict diagnostics to testbench files (tb), DUT RTL "
                         "(rtl), or show everything (all, default)")
    ap.add_argument("--suppress", action="append", default=[],
                    help="drop diagnostics whose text contains this substring")
    ap.add_argument("--werror", action="store_true",
                    help="treat warnings as errors in the exit status")
    ap.add_argument("--no-portability", action="store_true",
                    help="skip the portability lint (constructs slang accepts "
                         "but VCS/Questa/Xcelium reject)")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    files: list[Path] = [Path(f).resolve() for f in args.files]
    incdirs: list[Path] = [Path(d).resolve() for d in args.incdir] + RTL_INCDIRS
    defines: list[str] = list(args.define)

    for fl in args.filelist:
        s, i, d = parse_filelist(Path(fl).resolve())
        files += s
        incdirs += i
        defines += d

    if args.all:
        files += sorted(
            p.resolve() for p in TB_ROOT.rglob("*.sv")
            if "results" not in p.parts
        )

    # de-duplicate, preserve order
    seen: set[Path] = set()
    files = [f for f in files if not (f in seen or seen.add(f))]

    if not files:
        ap.error("no input files (give files, -f FILELIST, or --all)")

    if args.uvm_home:
        uvm_src = Path(args.uvm_home) / "src"
        if uvm_src.is_dir():
            incdirs.insert(0, uvm_src)
            if args.mode == "elab":
                files.insert(0, uvm_src / "uvm_pkg.sv")
        else:
            sys.stderr.write(f"warning: --uvm-home {args.uvm_home} has no src/ dir\n")

    if args.mode == "syntax":
        rep = check_syntax(files, incdirs, defines, args.suppress, args.verbose, args.scope)
    else:
        rep = check_elab(files, incdirs, defines, args.suppress, args.verbose, args.scope)

    # Portability lint. slang is permissive about a few constructs that every
    # commercial simulator rejects, so this text-level pass runs alongside.
    if not args.no_portability:
        own = [f for f in files if "ext" not in f.parts]
        pmsgs, pn = portability_lint(own, with_includes(own, incdirs))
        if pmsgs:
            rep.text.extend(pmsgs)
            rep.errors += pn

    body = "\n".join(t for t in rep.text if t.strip())
    if body:
        print(body)

    print(f"\n[slang_check] mode={args.mode}  files={len(files)}  "
          f"errors={rep.errors}  warnings={rep.warnings}")

    if rep.errors:
        return 1
    if args.werror and rep.warnings:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

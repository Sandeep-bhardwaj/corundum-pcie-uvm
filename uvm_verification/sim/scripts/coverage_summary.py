#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause-Views
"""
coverage_summary.py - regression statistics from xsim_run.py work directories.

    python sim/scripts/coverage_summary.py                # every results/xsim/tier*/
    python sim/scripts/coverage_summary.py --md out.md    # also write Markdown

Per tier it reports:
  * runs: pass / total over every <test>_seed<N>.log present
  * functional coverage: xcrg's merged score and each covergroup's score
  * code coverage of the DUT ONLY, from the instrumented tier<N>_cc/ build
    (files under fpga/ or rtl_patched/):
    statement, branch, condition, toggle-bit - summed over files, so a large
    file weighs more than a small one. Testbench and UVM files are excluded;
    counting them is what made the unfiltered dashboard read 4% branch.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

TB_ROOT = Path(__file__).resolve().parents[2]
WORK_ROOT = TB_ROOT / "results" / "xsim"
ORDER = ["1a", "1b", "1c", "2", "3", "3b", "3c", "4a", "4b", "4c", "4d", "5", "6", "1"]
DUT_PATH = re.compile(r"/(fpga|rtl_patched)/", re.I)


def classify(text: str) -> str:
    counts = {k: int(v) for k, v in re.findall(r"^(UVM_ERROR|UVM_FATAL)\s*:\s*(\d+)", text, re.M)}
    if "TEST PASSED" in text and not counts.get("UVM_ERROR") and not counts.get("UVM_FATAL"):
        return "PASS"
    return "FAIL" if counts else "NO-SUMMARY"


def runs(work: Path) -> dict:
    out = {}
    for log in sorted(work.glob("*_seed*.log")):
        m = re.match(r"(.+)_seed(\d+)\.log$", log.name)
        if m:
            out[(m.group(1), int(m.group(2)))] = classify(log.read_text(errors="replace"))
    return out


def functional(work: Path):
    rpt = work / "cov_report" / "functionalCoverageReport" / "xcrg_func_cov_report.txt"
    if not rpt.exists():
        return None, {}
    text = rpt.read_text(errors="replace")
    # xcrg APPENDS reports to an existing file: use only the LAST one.
    last = text.rfind("Total Summary")
    if last > 0:
        text = text[text.rfind("\n", 0, last - 200) if last > 200 else 0:]
    # Score the NAMED instances only (set_inst_name -> uvm_test_top.*). xsim
    # also keeps each covergroup's construction-time auto-named instance
    # (cg_response_5), never sampled, and xcrg's type and total scores average
    # those empty instances in - Tier 2 read 49.5% with every real instance at
    # 100%. Fall back to xcrg's score for a report with no named instances.
    insts = {}
    for name, sc in re.findall(r"^\s+(uvm_test_top\S+)\s*,\s*([\d.]+)\s*,", text, re.M):
        insts.setdefault(name, float(sc))
    if insts:
        return sum(insts.values()) / len(insts), insts
    score = re.search(r"Coverage Score\s*:,\s*([\d.]+)", text)
    groups = {}
    for name, sc, ninst in re.findall(
            r"^\s+(\S+::\S+)\s*,\s*([-\w.()]+)\s*,\s*(\d+)\s*,", text, re.M):
        if name not in groups and int(ninst) > 0:     # instantiated in this tier
            groups[name] = float(sc)
    return (float(score.group(1)) if score else None), groups


SUMMARY_ROW = re.compile(r"^\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*([\d.]+)\s*\|", re.M)
TOGGLE_BITS = re.compile(r"Total Bits\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|")


def code(work: Path) -> dict:
    """Sum DUT-file totals per metric: {metric: (covered, total)}."""
    acc = {m: [0, 0] for m in ("statement", "branch", "condition", "toggle")}
    rdir = work / "cov_report" / "codeCoverageReport"
    if not rdir.is_dir():
        return {}
    seen = set()
    for f in rdir.glob("file*.txt"):
        text = f.read_text(errors="replace")
        m = re.search(r"Coverage of File \d+ : (\S+)", text)
        if not m or not DUT_PATH.search(m.group(1)) or m.group(1) in seen:
            continue
        seen.add(m.group(1))
        for metric, head in (("statement", "Statement Coverage Summary for File"),
                             ("branch", "Branch Coverage Summary for File"),
                             ("condition", "Condition Coverage Summary for File")):
            i = text.rfind(head)          # last report, in case xcrg appended
            if i >= 0:
                r = SUMMARY_ROW.search(text, i)
                if r:
                    acc[metric][0] += int(r.group(2))
                    acc[metric][1] += int(r.group(1))
        i = text.rfind("Toggle Coverage Summary for File")
        if i >= 0:
            t = TOGGLE_BITS.search(text, i)
            if t:
                acc["toggle"][0] += int(t.group(2))
                acc["toggle"][1] += int(t.group(1))
    acc["files"] = [len(seen), 0]
    return acc


def pct(c, t):
    return f"{100.0 * c / t:5.1f}%" if t else "   - "


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--md", help="also write a Markdown report here")
    ap.add_argument("--seeds", default="",
                    help="comma list: count only these seeds (ignores stale logs)")
    a = ap.parse_args()
    keep = {int(s) for s in a.seeds.split(",") if s}

    rows, md = [], []
    tot_pass = tot_runs = 0
    fails = []
    for tier in ORDER:
        work = WORK_ROOT / f"tier{tier}"
        if not work.is_dir():
            continue
        r = runs(work)
        if keep:
            r = {k: v for k, v in r.items() if k[1] in keep}
        if not r:
            continue
        npass = sum(v == "PASS" for v in r.values())
        tot_pass += npass
        tot_runs += len(r)
        fails += [f"tier {tier}: {t} seed {s} -> {v}" for (t, s), v in sorted(r.items()) if v != "PASS"]
        tests = len({t for t, _ in r})
        seeds = sorted({s for _, s in r})
        fscore, groups = functional(work)
        # Code coverage comes from the separate instrumented build (tier<N>_cc);
        # verdicts never do - see xsim_run.py --code-coverage.
        c = code(WORK_ROOT / f"tier{tier}_cc")
        rows.append((tier, tests, len(seeds), npass, len(r), fscore, groups, c))

    hdr = (f"{'tier':<5} {'tests':>5} {'seeds':>5} {'runs pass':>11}  {'func cov':>8}  "
           f"{'stmt':>6} {'branch':>6} {'cond':>6} {'toggle':>6}  DUT files")
    print(hdr)
    print("-" * len(hdr))
    md += ["| tier | tests | seeds | runs passed | functional | statement | branch | condition | toggle | DUT files |",
           "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for tier, tests, ns, npass, nr, fscore, groups, c in rows:
        f = f"{fscore:6.1f}%" if fscore is not None else "     - "
        cc = [pct(*c[m]) if c else "   - " for m in ("statement", "branch", "condition", "toggle")]
        nfiles = c["files"][0] if c else 0
        print(f"{tier:<5} {tests:>5} {ns:>5} {npass:>5}/{nr:<5}  {f:>8}  "
              f"{cc[0]:>6} {cc[1]:>6} {cc[2]:>6} {cc[3]:>6}  {nfiles}")
        md.append(f"| {tier} | {tests} | {ns} | {npass}/{nr} | {f.strip()} | "
                  + " | ".join(x.strip() for x in cc) + f" | {nfiles} |")
    print("-" * len(hdr))
    print(f"TOTAL runs: {tot_pass}/{tot_runs} passed")
    md += ["", f"**Total: {tot_pass}/{tot_runs} runs passed.**"]

    print("\nCovergroup instances (merged over every run of the tier; func cov is their mean):")
    md += ["", "### Covergroups", "", "| tier | covergroup | score |", "|---|---|---:|"]
    for tier, *_, groups, _c in rows:
        for g, s in groups.items():
            print(f"  tier {tier:<3} {g:<60} {s:6.1f}%")
            md.append(f"| {tier} | `{g}` | {s:.1f}% |")

    if fails:
        print("\nNon-passing runs:")
        md += ["", "### Non-passing runs", ""]
        for f in fails:
            print("  " + f)
            md.append(f"- {f}")

    if a.md:
        Path(a.md).write_text("\n".join(md) + "\n", encoding="utf-8")
        print(f"\nMarkdown written to {a.md}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""List every uncovered bin in an xcrg functional coverage text report.

Usage: cov_holes.py <tier> [--all-instances]

xcrg's summary table only gives a count of uncovered bins per coverpoint; the
bin names are in the per-table "Uncovered bins" sections further down. This
prints them grouped by table, which is what writing a closure test needs.
By default only instances named under uvm_test_top (set_inst_name) are shown,
so stale databases from before the naming fix do not add noise.
"""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def holes(report: Path, all_inst: bool):
    table, mode, out = None, None, {}
    for line in report.read_text(errors="replace").splitlines():
        m = re.match(r"\s*(?:Cross )?Cover Point Table for Inst : (.*?), Variable :, (\S+)", line)
        if m:
            table, mode = f"{m.group(1)} :: {m.group(2)}", None
            continue
        s = line.strip()
        if s.endswith("Uncovered bins"):
            mode = "unc"
            continue
        if s.endswith("Covered bins") or s.startswith("Cover Group") or s.startswith("Summary"):
            mode = None
            continue
        if mode != "unc" or not table or not s or s.startswith("Name,") or "Hit Count" in s:
            continue
        if not all_inst and "uvm_test_top" not in table:
            continue
        fields = [f.strip() for f in s.split(",") if f.strip()]
        # bins: name,0,1   cross bins: a,b[,c...],0,1
        b = " x ".join(fields[:-2])
        if b not in out.setdefault(table, []):     # xcrg repeats cross tables
            out[table].append(b)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tier")
    ap.add_argument("--all-instances", action="store_true")
    a = ap.parse_args()
    rep = (ROOT / "results/xsim" / f"tier{a.tier}" / "cov_report"
           / "functionalCoverageReport" / "xcrg_func_cov_report.txt")
    if not rep.exists():
        sys.exit(f"no report: {rep}")
    h = holes(rep, a.all_instances)
    # xcrg prints the FIRST cross's bin table under every cross of a
    # covergroup, so a later cross's holes can be missing from h. The summary
    # rows (name, tag, expected, uncovered, ...) are always right: list any
    # coverpoint/cross with uncovered > 0 that the bin tables did not show.
    text = rep.read_text(errors="replace")
    for name, tag, exp, unc in re.findall(
            r"^\s+((?:cp_|x_)\w+)\s*,(\S+?),(\d+)\s*,(\d+)\s*,", text, re.M):
        if int(unc) == 0 or (not a.all_instances and "uvm_test_top" not in tag):
            continue
        inst = tag.split("uvm_test_top", 1)[-1]
        key = next((t for t in h if t.endswith(f":: {name}") and inst.split("_" + name)[0] in "uvm_test_top" + t), None)
        if key is None:
            h[f"uvm_test_top{inst.rsplit('_' + name, 1)[0]} :: {name}"] = [
                f"{unc}/{exp} uncovered (bin names not available: xcrg table quirk)"]
    if not h:
        print(f"tier {a.tier}: no uncovered bins")
    for t, bins in h.items():
        print(f"{t}  ({len(bins)} uncovered)")
        for b in bins:
            print(f"    {b}")


if __name__ == "__main__":
    main()

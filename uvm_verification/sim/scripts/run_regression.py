#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause-Views
"""
run_regression.py - parallel regression driver.

Implements : VERIFICATION_STRATEGY.md  §16.4 (regression runner),
                                       §19 E1/E7 (multi-seed, nightly)
Introduced : Step 0 (infrastructure)

Reads a .list file, launches runs in parallel through sim_run.py, scrapes the
verdict printed by mqnic_base_test.report_phase, and emits a JUnit XML plus an
HTML summary.

List file format, one run per line:
    <tier> <test> [seed ...]
Blank lines and '#' comments ignored. When no seed is given, --seeds applies.

Failure policy (STRATEGY §16.5): a failing run is automatically re-run once with
waveforms enabled and the identical seed, so a triage waveform always exists.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import html
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

TB_ROOT = Path(__file__).resolve().parents[2]
SIM_RUN = Path(__file__).with_name("sim_run.py")
RESULTS_DIR = TB_ROOT / "results"

PASS_TOKEN = "TEST PASSED"
FAIL_TOKEN = "TEST FAILED"


@dataclass
class Run:
    tier: str
    test: str
    seed: int
    passed: bool = False
    duration: float = 0.0
    log: Path | None = None
    reason: str = ""
    stdout: str = field(default="", repr=False)

    @property
    def name(self) -> str:
        return f"{self.test}.seed{self.seed}"


def parse_list(path: Path, default_seeds: list[int]) -> list[Run]:
    runs: list[Run] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#")[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 2:
            sys.stderr.write(f"warning: skipping malformed line: {raw!r}\n")
            continue
        tier, test = parts[0], parts[1]
        seeds = [int(s) for s in parts[2:]] or default_seeds
        for s in seeds:
            runs.append(Run(tier=tier, test=test, seed=s))
    return runs


def execute(run: Run, sim: str, coverage: bool, timeout: int, waves: bool) -> Run:
    cmd = [
        sys.executable, str(SIM_RUN),
        "--sim", sim,
        "--tier", run.tier,
        "--test", run.test,
        "--seed", str(run.seed),
    ]
    if coverage:
        cmd.append("--coverage")
    if waves:
        cmd.append("--waves")

    t0 = time.time()
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True,
                              timeout=timeout, cwd=str(TB_ROOT))
        out = (proc.stdout or "") + (proc.stderr or "")
        rc = proc.returncode
    except subprocess.TimeoutExpired:
        run.duration = time.time() - t0
        run.passed = False
        run.reason = f"harness timeout after {timeout}s"
        return run

    run.duration = time.time() - t0
    run.stdout = out
    run.log = RESULTS_DIR / f"tier{run.tier}" / run.test / f"seed{run.seed}" / "sim.log"

    log_text = out
    if run.log and run.log.exists():
        log_text += run.log.read_text(encoding="utf-8", errors="replace")

    if FAIL_TOKEN in log_text:
        run.passed = False
        run.reason = "verdict: TEST FAILED"
    elif PASS_TOKEN in log_text:
        run.passed = True
    elif rc == 127:
        run.passed = False
        run.reason = "simulator not found on PATH"
    elif rc != 0:
        run.passed = False
        run.reason = f"exit status {rc}"
    else:
        # No verdict printed at all. This is a failure, not a pass: it means the
        # test never reached report_phase. STRATEGY §19 E8.
        run.passed = False
        run.reason = "no verdict token in log (test did not reach report_phase)"
    return run


def write_junit(runs: list[Run], path: Path) -> None:
    suite = ET.Element("testsuite", {
        "name": "mqnic_uvm",
        "tests": str(len(runs)),
        "failures": str(sum(1 for r in runs if not r.passed)),
        "time": f"{sum(r.duration for r in runs):.2f}",
    })
    for r in runs:
        case = ET.SubElement(suite, "testcase", {
            "classname": f"tier{r.tier}",
            "name": r.name,
            "time": f"{r.duration:.2f}",
        })
        if not r.passed:
            fail = ET.SubElement(case, "failure", {"message": r.reason or "failed"})
            fail.text = r.stdout[-4000:]
    path.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(suite).write(path, encoding="utf-8", xml_declaration=True)


def write_html(runs: list[Run], path: Path) -> None:
    n_pass = sum(1 for r in runs if r.passed)
    rows = []
    for r in sorted(runs, key=lambda x: (x.passed, x.tier, x.test, x.seed)):
        colour = "#1a7f37" if r.passed else "#cf222e"
        verdict = "PASS" if r.passed else "FAIL"
        log = html.escape(str(r.log)) if r.log else ""
        rows.append(
            f"<tr><td>{html.escape(r.tier)}</td><td>{html.escape(r.test)}</td>"
            f"<td>{r.seed}</td>"
            f"<td style='color:{colour};font-weight:600'>{verdict}</td>"
            f"<td>{r.duration:.1f}s</td>"
            f"<td>{html.escape(r.reason)}</td><td><code>{log}</code></td></tr>"
        )
    doc = f"""<!doctype html><meta charset="utf-8">
<title>mqnic UVM regression</title>
<style>
 body{{font:14px/1.5 system-ui,sans-serif;margin:2rem;max-width:1200px}}
 table{{border-collapse:collapse;width:100%}}
 th,td{{border:1px solid #d0d7de;padding:.4rem .6rem;text-align:left}}
 th{{background:#f6f8fa}} code{{font-size:12px;color:#57606a}}
</style>
<h1>mqnic UVM regression</h1>
<p><strong>{n_pass}/{len(runs)}</strong> passed &middot; {time.strftime('%Y-%m-%d %H:%M:%S')}</p>
<table><tr><th>Tier</th><th>Test</th><th>Seed</th><th>Verdict</th>
<th>Time</th><th>Reason</th><th>Log</th></tr>
{''.join(rows)}
</table>"""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(doc, encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("listfile", help="regression list, e.g. sim/regress/tier1.list")
    ap.add_argument("--sim", default="questa", choices=["vcs", "questa", "xcelium"])
    ap.add_argument("-j", "--jobs", type=int, default=8)
    ap.add_argument("--seeds", default="1",
                    help="comma-separated default seeds for lines without one")
    ap.add_argument("--coverage", action="store_true")
    ap.add_argument("--timeout", type=int, default=7200,
                    help="per-run wall-clock limit in seconds")
    ap.add_argument("--no-retry", action="store_true",
                    help="do not re-run failures with waves")
    args = ap.parse_args()

    default_seeds = [int(s) for s in args.seeds.split(",") if s.strip()]
    runs = parse_list(Path(args.listfile), default_seeds)
    if not runs:
        sys.stderr.write("error: regression list produced no runs\n")
        return 2

    print(f"[regress] {len(runs)} run(s), sim={args.sim}, jobs={args.jobs}")
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(execute, r, args.sim, args.coverage,
                               args.timeout, False) for r in runs]
        done = [f.result() for f in concurrent.futures.as_completed(futures)]

    failures = [r for r in done if not r.passed]

    # STRATEGY §16.5 - always leave a triage waveform behind.
    if failures and not args.no_retry:
        print(f"[regress] re-running {len(failures)} failure(s) with waves")
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
            list(pool.map(lambda r: execute(r, args.sim, False,
                                            args.timeout, True), failures))

    stamp = time.strftime("%Y%m%d_%H%M%S")
    write_junit(done, RESULTS_DIR / "regress" / f"junit_{stamp}.xml")
    write_html(done, RESULTS_DIR / "regress" / f"summary_{stamp}.html")

    n_pass = sum(1 for r in done if r.passed)
    print(f"\n[regress] {n_pass}/{len(done)} passed")
    for r in sorted(failures, key=lambda x: (x.tier, x.test, x.seed)):
        print(f"  FAIL tier{r.tier} {r.name}: {r.reason}")
    print(f"[regress] reports in {RESULTS_DIR / 'regress'}")

    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause-Views
"""
xsim_run.py - compile and run a tier's SystemVerilog UVM tests on Vivado xsim.

    python sim/scripts/xsim_run.py 6                   # every test in tier6.list
    python sim/scripts/xsim_run.py 1a t1a_reset        # named tests only
    python sim/scripts/xsim_run.py 6 --no-compile      # reuse the last snapshot

Vivado is found through $XILINX_VIVADO, else the default install path below.
UVM is xsim's bundled UVM 1.2 (-L uvm); the environment also elaborates clean
against 1800.2 under slang, so both are exercised.

Work goes to results/xsim/tier<N>/ (gitignored): xvlog.log, xelab.log and one
<test>_seed<N>.log per test. Exit status is non-zero unless every test passes.

xsim-specific handling, each found by running this environment on 2026.1:
  * sim/xsim/xsim_vif_anchor.sv is elaborated as a second top - xsim only
    generates an interface's tasks/functions when that interface is
    instantiated, and every tier compiles classes that call them.
  * xsim.bat splits arguments on '=', so run options go through a -f file.
  * A freshly linked xsimk.exe is sometimes briefly unlaunchable ("child exe
    not found", most likely an antivirus scan); the run is retried.
  * pcie_tlp_fifo{,_raw}.v and mqnic_rx_queue_map.v are taken from fpga/, NOT
    rtl_patched/. xsim accepts the shipped zero-width construct, and the patched
    FIFO's 1-bit out_seg_offset leaves pcie_us_if_cc's [-1:0] wire at Z, which
    silently swallows every completion. --patched-rtl restores the filelist.
    mqnic_interface_{rx,tx}.v stay patched: xsim rejects the shipped files.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

TB_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = TB_ROOT.parent
FL_DIR = TB_ROOT / "sim" / "filelists"
REG_DIR = TB_ROOT / "sim" / "regress"
WORK_ROOT = TB_ROOT / "results" / "xsim"
ANCHOR = TB_ROOT / "sim" / "xsim" / "xsim_vif_anchor.sv"

DEFAULT_VIVADO = Path(r"D:\AMDDesignTools\2026.1\Vivado")

# rtl_patched/ file -> directory of its shipped original, for files xsim accepts
# unpatched. See the module docstring for why mqnic_interface_{rx,tx} are absent.
SHIPPED = {
    "pcie_tlp_fifo_raw.v": "fpga/lib/pcie/rtl",
    "pcie_tlp_fifo.v": "fpga/lib/pcie/rtl",
    "mqnic_rx_queue_map.v": "fpga/common/rtl",
}


def vivado_bin() -> Path:
    root = Path(os.environ.get("XILINX_VIVADO", DEFAULT_VIVADO))
    b = root / "bin"
    if not (b / "xvlog.bat").exists() and not (b / "xvlog").exists():
        raise SystemExit(f"Vivado not found at {root}; set XILINX_VIVADO")
    return b


def tool(name: str) -> Path:
    b = vivado_bin()
    return b / (f"{name}.bat" if os.name == "nt" else name)


def parse_filelist(path: Path, incdirs: list, files: list, defines: list) -> None:
    """Resolve a .f file whose paths are relative to its own directory."""
    base = path.parent
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = re.sub(r"//.*$", "", raw).strip()
        if not line or line.startswith("#"):
            continue
        for tok in line.split():
            if tok.startswith("+incdir+"):
                for d in tok[len("+incdir+"):].split("+"):
                    p = (base / d).resolve()
                    if d and p not in incdirs:
                        incdirs.append(p)
            elif tok.startswith("+define+"):
                defines.extend(x for x in tok[len("+define+"):].split("+") if x)
            elif tok.startswith("-"):
                raise SystemExit(f"{path}: unsupported option {tok}")
            else:
                p = (base / tok).resolve()
                if p not in files:
                    files.append(p)


def tb_filelist(tier: str) -> Path:
    cand = FL_DIR / f"tb_tier{tier}.f"
    return cand if cand.exists() else FL_DIR / "tb_common.f"


class WallTimeout(Exception):
    pass


class Wedged(Exception):
    pass


def _kill_tree(p: subprocess.Popen) -> None:
    # xsim.bat -> xsim.exe -> xsimk.exe: kill the whole tree, or the
    # simulator outlives the wrapper and keeps holding the run's slot.
    if os.name == "nt":
        subprocess.call(["taskkill", "/T", "/F", "/PID", str(p.pid)],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        p.kill()
    p.wait()


# PARALLEL LAUNCHES CROSS ARGUMENTS. Two xsim front ends started close together
# on the same snapshot can hand their kernels each other's arguments: the log
# lands at the requested path but the kernel ran the OTHER run's test, seed,
# wdb and tclbatch. An audit of 2,499 logs found 206 (8%) labelled with a test
# or seed they did not run. So launches are serialised until the kernel has
# demonstrably started (UVM's "Running test" line, process exit, or
# LAUNCH_HOLD_S), and run_test() checks every log header afterwards.
LAUNCH_LOCK = threading.Lock()
LAUNCH_HOLD_S = 180


def _hold_until_started(p: subprocess.Popen, log: Path) -> None:
    end = time.monotonic() + LAUNCH_HOLD_S
    while time.monotonic() < end and p.poll() is None:
        try:
            if log.exists() and "[RNTST]" in log.read_text(errors="replace"):
                return
        except OSError:
            pass
        time.sleep(0.5)


def run(cmd: list, cwd: Path, quiet: bool = False, timeout: float | None = None,
        wedge_log: Path | None = None, launch_log: Path | None = None) -> int:
    """Run to completion. With wedge_log, a failed coverage write in that log
    (after which xsim never exits) kills the run and raises Wedged. With
    launch_log, the launch is serialised against other runs until that log
    shows the simulation started (see LAUNCH_LOCK)."""
    if not quiet:
        print("+", " ".join(str(c) for c in cmd), flush=True)
    if launch_log is not None:
        with LAUNCH_LOCK:
            try:
                launch_log.unlink()      # never mistake the last run's log
            except OSError:
                pass
            p = subprocess.Popen([str(c) for c in cmd], cwd=str(cwd),
                                 stdout=subprocess.DEVNULL if quiet else None,
                                 stderr=subprocess.DEVNULL if quiet else None)
            _hold_until_started(p, launch_log)
    else:
        p = subprocess.Popen([str(c) for c in cmd], cwd=str(cwd),
                             stdout=subprocess.DEVNULL if quiet else None,
                             stderr=subprocess.DEVNULL if quiet else None)
    start = time.monotonic()
    seen_wedge = None
    last_size, last_change = -1, start
    while True:
        try:
            return p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        if timeout is not None and time.monotonic() - start > timeout:
            _kill_tree(p)
            raise WallTimeout(" ".join(str(c) for c in cmd))
        if wedge_log is not None and wedge_log.exists():
            try:
                text = wedge_log.read_text(errors="replace")
            except OSError:
                continue
            # Startup stall: the log froze with no message past time 0. Seen on
            # t4b_random_stress s16/s17 and t4d_random_stress s12/s13, whose
            # retries then passed; the 90-min wall timeout cost ~10 h overnight.
            # Slow tests are not caught: they all log at non-zero times.
            if len(text) != last_size:
                last_size, last_change = len(text), time.monotonic()
            elif (time.monotonic() - last_change > STARTUP_STALL_S
                  and not re.search(r"@ [1-9]\d*:", text)):
                # Only meaningful because every test logs once simulated time
                # passes 1 us (mqnic_base_test heartbeat); before that, a test
                # that is silent until its watchdog (t3_cpl_timeout) was killed
                # here on a loaded machine and reported NO-SUMMARY, not FAIL.
                _kill_tree(p)
                raise Wedged(f"startup stall: {wedge_log}")
            if "coverage write attempt" in text:
                # Give xsim 30 s to recover through the Tcl retry; it never
                # has, but the grace costs little.
                seen_wedge = seen_wedge or time.monotonic()
                if time.monotonic() - seen_wedge > 30:
                    _kill_tree(p)
                    raise Wedged(str(wedge_log))


# Code coverage (statement/branch/condition/toggle) is instrumented only where
# a run takes seconds: STRATEGY risk R6 says to close coverage at Tiers 1-4.
# Tiers 5/6 collect functional coverage only.
# Wall-clock cap per simulation. The slowest test (t3_cpl_dropped) needs ~30 min
# on a shared 2-core host; a stalled launch otherwise blocks a slot forever.
WALL_TIMEOUT_S = 90 * 60
# A run whose log has not moved past simulation time 0 for this long is stalled.
STARTUP_STALL_S = 5 * 60

CODE_COV_TIERS = {"1", "1a", "1b", "1c", "2", "3", "3b", "3c", "4a", "4b", "4c", "4d"}


def compile_tier(tier: str, work: Path, patched: bool, code_cov: bool = False) -> int:
    incdirs, files, defines = [], [], []
    parse_filelist(FL_DIR / f"rtl_tier{tier}.f", incdirs, files, defines)
    parse_filelist(tb_filelist(tier), incdirs, files, defines)
    if not patched:
        pdir = TB_ROOT / "rtl_patched"
        files = [REPO_ROOT / SHIPPED[f.name] / f.name
                 if f.parent == pdir and f.name in SHIPPED else f for f in files]
    files.append(ANCHOR)

    prj = work / "files.f"
    lines = [f'-i "{d.as_posix()}"' for d in incdirs]
    lines += [f"-d {d}" for d in defines]
    lines += [f'"{f.as_posix()}"' for f in files]
    prj.write_text("\n".join(lines) + "\n", encoding="utf-8")

    rc = run([tool("xvlog"), "--sv", "-L", "uvm", "-f", prj,
              "--log", work / "xvlog.log"], work)
    if rc:
        return rc
    # RELATIVE path (cwd is the work dir): xelab pastes this string into
    # generated C, so Windows backslashes become escape sequences and the C
    # compile fails (XSIM 43-3409).
    cov = ["--cov_db_dir", "cov", "--cov_db_name", "elab"]
    if code_cov:
        cov += ["--cc_type", "sbct"]
    xelab = [tool("xelab"), f"tb_top_tier{tier}", "xsim_vif_anchor",
             "-L", "uvm", "--relax", "--timescale", "1ns/1ps",
             "--override_timeunit", "--override_timeprecision",
             "-s", "snap", "--log", work / "xelab.log"] + cov
    for attempt in range(3):
        rc = run(xelab, work)
        if rc == 0:
            return 0
        log = (work / "xelab.log").read_text(errors="replace")
        if re.search(r"^ERROR:", log, re.M):
            return rc               # a real elaboration error: do not retry
        # Died with no ERROR line (Tier 4b and Tier 5 stopped mid "Compiling
        # package uvm.uvm_pkg" with <1 GB RAM free): the process was killed,
        # most likely for memory. Wait for the host to free some, then retry.
        print(f"xelab died without an error (attempt {attempt + 1}); retrying", flush=True)
        time.sleep(120)
    return rc


def tests_for(tier: str) -> list[str]:
    out = []
    for line in (REG_DIR / f"tier{tier}.list").read_text().splitlines():
        f = line.split("#")[0].split()
        if len(f) >= 2:
            out.append(f[1])
    return out


def classify(log: Path) -> str:
    text = log.read_text(errors="replace") if log.exists() else ""
    counts = {k: int(v) for k, v in re.findall(
        r"^(UVM_ERROR|UVM_FATAL)\s*:\s*(\d+)", text, re.M)}
    if "TEST PASSED" in text and not counts.get("UVM_ERROR") and not counts.get("UVM_FATAL"):
        return "PASS"
    if not counts:
        return "NO-SUMMARY"
    return (f"FAIL (errors={counts.get('UVM_ERROR', '?')}, "
            f"fatals={counts.get('UVM_FATAL', '?')})")


def launched_as(text: str):
    """(test, seed) the kernel actually ran, from its command-line echo."""
    m = re.search(r"UVM_TESTNAME=(\S+).*?-sv_seed (\d+)", text[:8000], re.S)
    return (m.group(1), int(m.group(2))) if m else None


def run_test(test: str, seed: int, verbosity: str, plusargs: list, work: Path,
             coverage: bool = False, quiet: bool = False) -> str:
    log = work / f"{test}_seed{seed}.log"
    opts = work / f"{test}_seed{seed}.opts"
    # A waveform database per run: parallel runs must not share snap.wdb.
    wdb = work / "wdb" / f"{test}_seed{seed}.wdb"
    wdb.parent.mkdir(exist_ok=True)
    extra = [f'--wdb "{wdb.as_posix()}"']
    run_mode = ["--runall"]
    if coverage:
        # Written EXPLICITLY after $finish, under a per-run name. Relying on the
        # exit-time write lost 7 of 24 databases when runs were parallel.
        tcl = work / f"{test}_seed{seed}.cov.tcl"
        # catch{}: an uncaught Tcl error drops xsim to its interactive prompt,
        # which then waits on stdin forever (t3_reset seed 4 hung 2 h that way,
        # after its test had passed).
        # Retried: the FIRST run of a tier failed "Unable to create output
        # directory" (t3c_reset s1, t4a_reset s1) while the next seeds, seconds
        # later, did not - a transient lock on the new directory. After a failed
        # write xsim also hung on quit, so the retry is what prevents the hang.
        # PER-RUN directory: the "Unable to create output directory" failures
        # recurred with a pre-created shared parent (t1a_reset s6, alongside
        # s7 starting at the same instant), and after one xsim wedges rather
        # than reaching the retry. A directory no other run touches removes the
        # race instead of retrying into it.
        run_dir = f"cov_runs/{test}_s{seed}"
        # Start empty: a run whose write fails would otherwise leave the
        # PREVIOUS run's database behind, built from an older coverage model,
        # and xcrg reports it as a second same-named instance.
        shutil.rmtree(work / run_dir, ignore_errors=True)
        (work / run_dir).mkdir(parents=True, exist_ok=True)
        tcl.write_text("run all\n"
                       "set ok 0\n"
                       "for {set i 0} {$i < 5 && !$ok} {incr i} {\n"
                       f"    if {{[catch {{write_xsim_coverage -cov_db_dir {run_dir} "
                       f"-cov_db_name {test}_s{seed}}} err]}} {{\n"
                       "        puts \"xsim_run: coverage write attempt $i failed: $err\"\n"
                       "        after 3000\n"
                       "    } else { set ok 1 }\n"
                       "}\n"
                       "if {!$ok} { puts \"xsim_run: COVERAGE WRITE FAILED\" }\n"
                       "quit\n", encoding="utf-8")
        run_mode = ["--onfinish stop", f'--tclbatch "{tcl.as_posix()}"']
    opts.write_text("\n".join(
        run_mode + ["--onerror quit", f"--sv_seed {seed}",
         f"--testplusarg UVM_TESTNAME={test}",
         f"--testplusarg UVM_VERBOSITY={verbosity}"]
        + [f"--testplusarg {p.lstrip('+')}" for p in plusargs]
        + extra
        + [f'--log "{log.as_posix()}"']) + "\n", encoding="utf-8")
    mislaunched = False
    for attempt in range(4):
        try:
            run([tool("xsim"), "snap", "-f", opts], work, quiet, WALL_TIMEOUT_S,
                wedge_log=log if coverage else None, launch_log=log)
        except Wedged as w:
            # xsim failed to create its coverage directory and then hung. It
            # happens when two SHORT runs (*_reset, <1 us) finish within the
            # same second, even into separate directories - an xsim-internal
            # conflict. Rerunning the test has always succeeded.
            print(f"xsim_run: {test} seed {seed} attempt {attempt + 1} killed: {w}", flush=True)
            time.sleep(3 + attempt * 5)
            if attempt < 3:
                continue
            break
        except WallTimeout:
            # A launch can stall with xsimk idle at 0% CPU (seen once in ~500
            # runs); the simulation's own watchdog never fires because
            # simulated time never advances. Retry the run.
            if attempt < 3:
                continue
            log.write_text(f"xsim_run: WALL TIMEOUT after {WALL_TIMEOUT_S}s on every attempt\n")
            break
        text = log.read_text(errors="replace") if log.exists() else ""
        ran = launched_as(text)
        mislaunched = ran is not None and ran != (test, seed)
        if mislaunched:
            print(f"xsim_run: {test} seed {seed} ran {ran[0]} seed {ran[1]} - "
                  f"crossed launch, rerunning", flush=True)
            time.sleep(2)
            continue
        if "child exe not found" not in text:
            break
        time.sleep(5 * (attempt + 1))
    if mislaunched:
        log.write_text(f"xsim_run: MISLAUNCH - never ran {test} seed {seed}\n")
    try:
        wdb.unlink()                    # waves are never logged; the file is noise
    except OSError:
        pass
    return classify(log)


def coverage_report(work: Path, runs: list[str]) -> None:
    """Merge the named runs' databases and write text reports under work/cov_report.

    xcrg must be TOLD which databases to merge (-file): given only a directory
    it reported "No Functional Coverage Databases have been found".
    """
    lst = work / "cov_dbs.txt"
    dbs = []
    for kind in ("xsim.covdb", "xsim.codeCov"):
        for r in runs:
            # Current layout: cov_runs/<run>/; older runs: shared cov/.
            for base in (f"cov_runs/{r}", "cov"):
                if (work / base / kind / r).is_dir():
                    dbs.append(f"{base}/{kind}/{r}\n")
                    break
    if (work / "cov" / "xsim.codeCov" / "elab").is_dir():
        dbs.append("cov/xsim.codeCov/elab\n")   # runs also accumulate here
    lst.write_text("".join(dbs), encoding="utf-8")
    # xcrg APPENDS to an existing report file; the summary then read the first
    # (oldest) report and showed stale numbers. Start from an empty directory.
    shutil.rmtree(work / "cov_report", ignore_errors=True)
    run([tool("xcrg"), "-file", "cov_dbs.txt", "-report_format", "text",
         "-report_dir", "cov_report", "-log", "xcrg.log"], work)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tier")
    ap.add_argument("tests", nargs="*", help="default: every test in sim/regress/tier<N>.list")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--seeds", default="",
                    help="comma list, e.g. 1,2,3,4,5 - overrides --seed")
    ap.add_argument("--jobs", type=int, default=1,
                    help="parallel simulations (each is one xsim process)")
    ap.add_argument("--coverage", action="store_true",
                    help="collect and report FUNCTIONAL coverage (covergroups); "
                         "safe for pass/fail")
    ap.add_argument("--code-coverage", action="store_true",
                    help="separate INSTRUMENTED build in tier<N>_cc/ for statement/"
                         "branch/condition/toggle coverage. Its verdicts are NOT "
                         "trustworthy (the instrumented build mis-simulated "
                         "t2_seg_independent_backpressure) and parallel runs lost "
                         "databases, so use --jobs 1 and take verdicts from a "
                         "normal run")
    ap.add_argument("--verbosity", default="UVM_LOW")
    ap.add_argument("--plusarg", action="append", default=[])
    ap.add_argument("--no-compile", action="store_true")
    ap.add_argument("--patched-rtl", action="store_true",
                    help="compile rtl_patched/ exactly as the filelist says")
    a = ap.parse_args()

    seeds = [int(s) for s in a.seeds.split(",") if s] or [a.seed]
    if a.code_coverage and a.tier not in CODE_COV_TIERS:
        print(f"code coverage is limited to tiers {sorted(CODE_COV_TIERS)} (STRATEGY R6)")
        return 2
    if a.code_coverage:
        a.coverage = True
    work = WORK_ROOT / (f"tier{a.tier}" + ("_patched" if a.patched_rtl else "")
                        + ("_cc" if a.code_coverage else ""))
    work.mkdir(parents=True, exist_ok=True)
    if not a.no_compile:
        rc = compile_tier(a.tier, work, a.patched_rtl, a.code_coverage)
        if rc:
            print(f"COMPILE FAILED rc={rc}; see {work}")
            return rc

    tests = a.tests or tests_for(a.tier)
    jobs = [(t, s) for t in tests for s in seeds]
    if a.coverage:
        # Create the parent BEFORE any run: xsim creates only the leaf, and two
        # parallel first runs racing on cov/xsim.covdb failed with "Unable to
        # create output directory" - after which xsim hung on quit.
        (work / "cov" / "xsim.covdb").mkdir(parents=True, exist_ok=True)
    quiet = a.jobs > 1
    with ThreadPoolExecutor(max_workers=max(1, a.jobs)) as pool:
        futs = {pool.submit(run_test, t, s, a.verbosity, a.plusarg, work,
                            a.coverage, quiet): (t, s) for t, s in jobs}
        results = {futs[f]: f.result() for f in futs}

    print(f"\n==== summary tier {a.tier} (seeds {','.join(map(str, seeds))}) ====")
    for t in tests:
        rs = [results[(t, s)] for s in seeds]
        ok = sum(r == "PASS" for r in rs)
        bad = [f"s{s}:{r}" for s, r in zip(seeds, rs) if r != "PASS"]
        print(f"  {ok}/{len(seeds)} PASS  {t}" + (f"   {'; '.join(bad)}" if bad else ""))
    n_pass = sum(r == "PASS" for r in results.values())
    print(f"  {n_pass}/{len(results)} runs passed; logs in {work}")

    if a.coverage:
        coverage_report(work, [f"{t}_s{s}" for t, s in jobs])
        print(f"  coverage report: {work / 'cov_report'}")
    return 0 if n_pass == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""gen_tb_ports.py - emit a testbench port map from a Verilog module header.

Implements : VERIFICATION_STRATEGY.md  §18 (build), §4.3
Introduced : Step 7 (Tier 5)

WHY GENERATE THIS
-----------------
mqnic_core_pcie has 250 ports and 162 parameters. Every Tier 3 and Tier 4
testbench top was hand-written, and that was fine at 30-50 ports; at 250 it is
a transcription exercise, and this project has already paid for transcription
three times (bug 9 header fields, bug 12 request-type constants, bug 15 framing
assumptions).

The difference here is that a mis-wired port usually does NOT fail to compile.
It connects the wrong signal, or leaves an input floating, and the failure shows
up as inexplicable behaviour many hours later.

So the port map is derived from the RTL and the DIRECTION of every port is taken
from the source rather than remembered:

  * inputs  the DUT reads   -> the testbench must DRIVE  (tie off if unused)
  * outputs the DUT drives  -> the testbench must SINK   (leave open if unused)

Getting that backwards is the single most common way a large top goes wrong.

This emits a SKELETON. The connections that matter - the PCIe BAR path, clocks,
resets - are written by hand on top; everything else is tied off explicitly so
that "unconnected" is a decision rather than an omission.

Usage:
    python gen_tb_ports.py <rtl_file> <module_name> [--inst u_dut]
"""

import argparse
import pathlib
import re
import sys

PORT_RE = re.compile(
    r"^\s*(input|output|inout)\s+(?:wire|reg|logic)?\s*"
    r"(\[[^\]]*\]\s*)?([A-Za-z_]\w*)\s*[,)]?\s*(?://.*)?$")
PARAM_RE = re.compile(r"^\s*parameter\s+([A-Za-z_]\w*)\s*=\s*(.+?)\s*,?\s*$")


def parse(path: pathlib.Path, module: str):
    text = path.read_text(encoding="utf-8", errors="replace")
    m = re.search(rf"^module\s+{re.escape(module)}\b", text, re.M)
    if not m:
        print(f"module {module} not found in {path}", file=sys.stderr)
        sys.exit(2)
    body = text[m.start():]
    # Header ends at the ");" that closes the port list.
    end = body.find("\n);")
    if end < 0:
        end = len(body)
    header = body[:end]

    params, ports = [], []
    for line in header.splitlines():
        pm = PARAM_RE.match(line)
        if pm and "(" not in pm.group(1):
            params.append((pm.group(1), pm.group(2).rstrip(",")))
            continue
        po = PORT_RE.match(line)
        if po:
            direction, width, name = po.group(1), (po.group(2) or "").strip(), po.group(3)
            ports.append((direction, width, name))
    return params, ports



# ---------------------------------------------------------------------------
# TIE-OFF POLICY, BY PORT FAMILY
#
# Defaulting every unused input to '0' is right for a genuinely unused input and
# WRONG wherever the DUT is the MASTER of an interface. There, the inputs are
# the far side's handshake, and a permanently-low ready or ack means the DUT
# stalls forever waiting for a peer the testbench never provides.
#
# That stall does not appear where it is caused. On mqnic_core_pcie a tied-low
# m_axil_csr_arready wedged an AXI-Lite crossbar three levels away, and the
# visible symptom was "a PCIe register read returns no completion". It cost
# three rounds of probing, twice.
#
# So:
#   *_ready          -> 1   the peer always accepts
#   everything else  -> 0   quiescent, INCLUDING *_ack
#
# *ack is NOT in the same family as *ready, though the first version of this
# function treated it that way (bug 32). *ready is flow control: "I will accept
# whatever you send", which is the right thing to say on behalf of a peer that
# is not there. *ack means "a slave has ANSWERED THIS TRANSACTION", and it
# travels with a data bus:
#
#     mqnic_core.v:754
#     assign ctrl_reg_rd_ack_int  = ctrl_reg_rd_ack  | ctrl_reg_rd_ack_reg | ...
#     assign ctrl_reg_rd_data_int = ctrl_reg_rd_data | ctrl_reg_rd_data_reg | ...
#
# Tie ctrl_reg_rd_ack high and the absent application register block answers
# every read instantly, with its tied-off data of 0, beating the core's own
# register file. Reads then SUCCEED AND RETURN THE WRONG VALUE - which is worse
# than the stall the tie-off was introduced to prevent, because nothing looks
# broken. axil_reg_if has a 4-cycle timeout, so tying *ack low cannot hang.
#
# This is a BRING-UP tie-off, not a model. It unblocks the design so real
# behaviour can be reached; an interface that matters to a test gets a proper
# responder (see the axil UVC's MODE_ACTIVE_SLAVE).
# ---------------------------------------------------------------------------
def tie_off(name: str):
    n = name.lower()
    if n.endswith("ready"):
        return "1'b1", "   // peer always ready - see tie_off()"
    return "'0", ""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rtl")
    ap.add_argument("module")
    ap.add_argument("--inst", default="u_dut")
    args = ap.parse_args()

    params, ports = parse(pathlib.Path(args.rtl), args.module)
    ins = [p for p in ports if p[0] == "input"]
    outs = [p for p in ports if p[0] == "output"]

    print(f"// GENERATED by sim/scripts/gen_tb_ports.py from {args.rtl}")
    print(f"// {args.module}: {len(params)} parameter(s), {len(ports)} port(s) "
          f"({len(ins)} in, {len(outs)} out)")
    print("//")
    print("// Every port appears EXACTLY ONCE. Inputs are tied off, outputs are left")
    print("// open; replace the ones the test actually uses. An explicit tie-off is a")
    print("// decision - a missing port is an omission that usually still compiles.")
    print()
    print(f"    {args.module} #(")
    for i, (n, v) in enumerate(params):
        comma = "," if i < len(params) - 1 else ""
        print(f"        .{n}({n}){comma}")
    print(f"    ) {args.inst} (")
    n = len(ports)
    for i, (d, w, name) in enumerate(ports):
        comma = "," if i < n - 1 else ""
        if d == "input":
            tie, why = tie_off(name)
            print(f"        .{name:<38}({tie}){comma}      // input  {w}{why}")
        else:
            print(f"        .{name:<38}(){comma}        // output {w}")
    print("    );")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Measure what the codec transport costs the DSP, per codec frame.

The LA32 profiles bracket a render loop, so they exclude everything the
transport does around it: the SSI transmit interrupt that feeds the codec,
the host-port receive of a period, the replies, the boundary wait and the
handoff. This probe arms Hatari's DSP profiler at the Nth refill of the
self-test's host-fed stream and saves it `--periods` refills later, so the
window covers whole periods with every cycle the DSP spends, and then sorts
those cycles by what the DSP was doing:

* the SSI transmit interrupt, two fast interrupts per stereo frame;
* the host receive interrupt, one peripheral-to-memory move and one NOP;
* foreground clock accounting, commands and handoffs;
* receive waits, which a future live synth can fill with rendering;
* the commands, replies and the handoff, which happen once per period;
* the handoff's transmitter drain, which is SSI-paced idle;
* the boundary spin and the command wait, which is the DSP idle because it
  has nothing else to do in the scaffold.

The first two and the once-per-period work are the transport's fixed cost.
Host words now arrive through a fast interrupt. The report checks the
actual interrupt count and measures its cost; foreground waits are the
places a live renderer can use for synthesis.

`prepare` writes the debugger scripts, `report` reads the saved profile.
"""

from __future__ import annotations

import argparse
import bisect
import re
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from profile_dsp import parse_listing, parse_profile, require_symbol  # noqa: E402

SAMPLE_RATE = 32779.9479166667
FRAMES_PER_PERIOD = 512
WORDS_PER_PERIOD = 1024
INTERRUPTS_PER_FRAME = 2

# A `jclr`/`jset` whose target is itself: a pure wait on a peripheral bit.
SELF_LOOP_RE = re.compile(
    r"^\s*\d+\s+P:([0-9A-F]{4})\s+[0-9A-F]{6}\s+j(?:clr|set)\s+\S+,\*", re.M
)

ENTRY = "command_refill_stream"


def write_debugger_scripts(listing: Path, output_dir: Path, skip: int, periods: int) -> None:
    symbols = parse_listing(listing)
    entry = require_symbol(symbols, "P", ENTRY)
    output_dir.mkdir(parents=True, exist_ok=True)
    arm = (output_dir / "arm.ini").resolve()
    end = (output_dir / "end.ini").resolve()
    profile = (output_dir / "profile.txt").resolve()
    (output_dir / "start.ini").write_text(
        f"db pc = ${entry:04x} :{skip} :once :trace :file {arm}\n"
    )
    # The arm script runs on a matching refill entry and Hatari's counter
    # for the new breakpoint includes that hit, so N whole entry-to-entry
    # periods need the (N+1)th match. The report normalizes by the entries
    # it actually finds in the window rather than trusting this arithmetic.
    arm.write_text(
        "dp on\n"
        f"db pc = ${entry:04x} :{periods + 1} :once :trace :file {end}\n"
    )
    end.write_text(f"dp save {profile}\ndp off\n")


def classify(listing: Path, symbols: dict, rows: list) -> tuple[dict, int, dict]:
    """Account actual interrupt receives separately from schedulable waits."""
    labels = sorted((address, name) for (space, name), address in symbols.items() if space == "P")
    addresses = [address for address, _ in labels]
    entry = require_symbol(symbols, "P", ENTRY)
    stream = require_symbol(symbols, "P", "stream_loop")
    self_loops = {int(m.group(1), 16) for m in SELF_LOOP_RE.finditer(listing.read_text())}
    periods = sum(i for pc, i, _c, _p in rows if pc == entry)
    received = sum(i for pc, i, _c, _p in rows if pc == 0x20)
    if not periods or received != periods * WORDS_PER_PERIOD:
        raise SystemExit(f"error: {periods} refills but {received} interrupt receive words")
    cycles: defaultdict[str, float] = defaultdict(float)
    other: defaultdict[str, float] = defaultdict(float)
    for pc, _instructions, oscillator_cycles, _percent in rows:
        cost = oscillator_cycles / 2.0
        index = bisect.bisect_right(addresses, pc) - 1
        name = labels[index][1] if index >= 0 else ""
        if 0x10 <= pc <= 0x11:
            category = "SSI transmit interrupt"
        elif 0x20 <= pc <= 0x21:
            category = "host receive interrupt"
        elif 0x12 <= pc <= 0x13 or name == "ssi_tx_exception":
            category = "SSI underrun recovery"
        elif name in {"ssi_poll_time", "ssi_poll_done"}:
            category = "clock poll (idle)"
        elif name in {"ssi_update_time", "ssi_update_done"}:
            category = "clock accounting"
        elif name == "receive_period_wait":
            category = "receive wait (idle)"
        elif name in {"ssi_wait_boundary", "ssi_wait_boundary_loop"}:
            category = "boundary wait (idle)"
        elif name == "send_reply_wait":
            category = "reply wait (idle)"
        elif pc in (stream, stream + 2):
            category = "command wait (idle)"
        elif name in {"ssi_perform_handoff", "ssi_handoff_even"}:
            category = "transmitter drain (idle)" if pc in self_loops else "handoff"
        elif name in {"receive_period", "receive_period_done", "send_reply", "send_reply_ready",
                      "stream_loop", "command_refill_stream", "stream_query_time", "stream_query_periods"}:
            category = "commands and replies"
        else:
            category = "other"
            other[name or f"p_${pc:04x}"] += cost
        cycles[category] += cost
    return dict(cycles), periods, dict(other)


def summarize(listing: Path, profile: Path, output: Path | None, nominal_periods: int) -> None:
    symbols = parse_listing(listing)
    hz, oscillator_cycles, rows = parse_profile(profile)
    cycles, periods, other = classify(listing, symbols, rows)
    frames = periods * FRAMES_PER_PERIOD
    budget = hz / 2.0 / SAMPLE_RATE
    idle = sum(value for name, value in cycles.items() if name.endswith("(idle)"))
    work = oscillator_cycles / 2.0 - idle
    lines = [
        "DSP56001 codec transport profile (host-fed stream, interrupt receive)",
        f"  profiled periods: {periods} ({nominal_periods} requested)",
        f"  codec frames: {frames:,}",
        f"  interrupt-received host words: {periods * WORDS_PER_PERIOD:,}",
        f"  real-time budget: {budget:.2f} instruction cycles per frame",
        f"  transport work: {work / frames:.2f} cycles per frame ({100 * work / (budget * frames):.1f}%)",
        f"  foreground waits: {idle / frames:.2f} cycles per frame",
        "  Receive waits can run synthesis once the live renderer is integrated.",
        "  These are measured ISR costs, not a projection from the SSI vector.",
        "",
        "Categories (instruction cycles per frame):",
    ]
    for name, value in sorted(cycles.items(), key=lambda item: item[1], reverse=True):
        lines.append(f"  {value / frames:8.2f}  {name}")
    if cycles.get("SSI underrun recovery") or other:
        raise SystemExit(f"error: unexpected transport work: underrun={cycles.get('SSI underrun recovery', 0)}, other={other}")
    report = "\n".join(lines) + "\n"
    print(report, end="")
    if output:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(report)


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare = subparsers.add_parser("prepare", help="write Hatari debugger scripts")
    prepare.add_argument("--listing", type=Path, required=True)
    prepare.add_argument("--output-dir", type=Path, required=True)
    prepare.add_argument("--skip", type=int, default=4, help="refills to let pass before arming")
    prepare.add_argument("--periods", type=int, default=24, help="refills to profile")

    report = subparsers.add_parser("report", help="summarize a saved Hatari profile")
    report.add_argument("--listing", type=Path, required=True)
    report.add_argument("--profile", type=Path, required=True)
    report.add_argument("--output", type=Path)
    report.add_argument("--periods", type=int, default=24)

    arguments = parser.parse_args()
    if arguments.command == "prepare":
        write_debugger_scripts(
            arguments.listing, arguments.output_dir, arguments.skip, arguments.periods
        )
    else:
        summarize(arguments.listing, arguments.profile, arguments.output, arguments.periods)


if __name__ == "__main__":
    main()

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
* the receive loop's own instructions, one poll, one read and one store per
  word, which is the DSP-side cost of taking a word from the host port;
* extra turns of the receive poll, which is the DSP stalled on the 68030
  delivering the next word;
* the commands, replies and the handoff, which happen once per period;
* the handoff's transmitter drain, which is SSI-paced idle;
* the boundary spin and the command wait, which is the DSP idle because it
  has nothing else to do in the scaffold.

The first two and the once-per-period work are the transport's fixed cost.
The stall is a property of the polled receive, not of the port: a receive
by host interrupt costs the same per word as the SSI interrupt costs per
sample, because it is the same two-instruction fast interrupt, and the
report says so in numbers.

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
    """Return (instruction cycles by category, periods in the window, other blocks)."""
    text = listing.read_text(errors="replace")
    self_loops = {int(m.group(1), 16) for m in SELF_LOOP_RE.finditer(text)}

    def sym(name: str) -> int:
        return require_symbol(symbols, "P", name)

    entry = sym(ENTRY)
    receive = sym("receive_period")
    receive_done = sym("receive_period_done")
    receive_end = sym("ssi_configure")
    stream_loop = sym("stream_loop")
    boundary = sym("ssi_wait_boundary")
    handoff = sym("ssi_perform_handoff")
    handoff_end = sym("command_stop_audio")
    reply = sym("send_reply")
    reply_end = sym("mt32_reset")
    exception = sym("ssi_tx_exception")

    receive_polls = sorted(pc for pc in self_loops if receive <= pc < receive_done)
    if len(receive_polls) != 1:
        raise SystemExit("error: expected exactly one self-looping poll in receive_period")
    receive_poll = receive_polls[0]

    periods = sum(instructions for pc, instructions, _c, _p in rows if pc == entry)
    if not periods:
        raise SystemExit("error: the profile window holds no refill; was the stream running?")
    words = periods * WORDS_PER_PERIOD

    p_labels = sorted(
        (address, name) for (space, name), address in symbols.items() if space == "P"
    )
    label_addresses = [item[0] for item in p_labels]

    cycles: defaultdict[str, float] = defaultdict(float)
    other: defaultdict[str, float] = defaultdict(float)
    for pc, instructions, oscillator_cycles, _percent in rows:
        c = oscillator_cycles / 2.0
        if 0x10 <= pc <= 0x11:
            cycles["ssi interrupt"] += c
        elif 0x12 <= pc <= 0x13 or exception <= pc < reply:
            cycles["ssi underrun recovery"] += c
        elif pc == receive_poll:
            # One turn per word is the receive's own poll; the rest is the
            # DSP waiting for the 68030 to deliver the next word.
            turns = max(instructions, 1)
            cycles["receive"] += c * min(words, turns) / turns
            cycles["receive stall"] += c * max(turns - words, 0) / turns
        elif receive_poll < pc <= receive_done:
            cycles["receive"] += c
        elif receive <= pc < receive_end:
            cycles["commands and replies"] += c
        elif reply <= pc < reply_end:
            cycles["reply stall" if pc in self_loops else "commands and replies"] += c
        elif pc == stream_loop:
            cycles["command wait"] += c
        elif stream_loop <= pc < receive:
            cycles["commands and replies"] += c
        elif boundary <= pc < handoff:
            cycles["boundary wait"] += c
        elif handoff <= pc < handoff_end:
            cycles["transmitter drain" if pc in self_loops else "handoff"] += c
        else:
            index = bisect.bisect_right(label_addresses, pc) - 1
            name = p_labels[index][1] if index >= 0 else f"p_${pc:04x}"
            other[name] += c
            cycles["other"] += c
    return dict(cycles), periods, dict(other)


def summarize(listing: Path, profile: Path, output: Path | None, nominal_periods: int) -> None:
    symbols = parse_listing(listing)
    hz, oscillator_cycles, rows = parse_profile(profile)
    cycles, periods, other = classify(listing, symbols, rows)
    total = oscillator_cycles / 2.0
    frames = periods * FRAMES_PER_PERIOD
    words = periods * WORDS_PER_PERIOD
    instruction_hz = hz / 2.0
    budget = instruction_hz / SAMPLE_RATE

    isr = cycles.get("ssi interrupt", 0.0)
    receive = cycles.get("receive", 0.0)
    stall = cycles.get("receive stall", 0.0)
    per_period = cycles.get("commands and replies", 0.0) + cycles.get("handoff", 0.0)
    fixed = isr + receive + per_period
    waiting = stall + cycles.get("reply stall", 0.0)
    idle = (
        cycles.get("boundary wait", 0.0)
        + cycles.get("command wait", 0.0)
        + cycles.get("transmitter drain", 0.0)
    )
    isr_count = sum(i for pc, i, _c, _p in rows if pc == 0x10)
    per_interrupt = isr / isr_count if isr_count else 0.0
    receive_time = receive + stall
    host_cycles_per_word = receive_time / words
    host_us_per_word = host_cycles_per_word / instruction_hz * 1e6
    handoffs = periods
    drain = cycles.get("transmitter drain", 0.0)

    def per_frame(value: float) -> str:
        return f"{value / frames:8.2f}"

    lines = [
        "DSP56001 codec transport profile (host-fed stream, polled receive)",
        f"  profiled periods:            {periods} ({nominal_periods} requested)",
        f"  codec frames:                {frames:,}",
        f"  host words received:         {words:,}",
        f"  Hatari DSP oscillator:       {hz:,} Hz",
        f"  measured instruction cycles: {total:,.0f}",
        f"  real-time budget for window: {budget * frames:,.0f}",
        f"  window / real time:          {total / (budget * frames):.3f}x",
        "",
        f"  instruction cycles per codec frame (budget {budget:,.2f}):",
        f"    SSI transmit interrupt:    {per_frame(isr)}   "
        f"{per_interrupt:.2f} per interrupt, {INTERRUPTS_PER_FRAME} per frame",
        f"    host-port receive:         {per_frame(receive)}   "
        f"{receive / words:.2f} per word, {WORDS_PER_PERIOD // FRAMES_PER_PERIOD} per frame",
        f"    commands, replies, handoff:{per_frame(per_period)}   "
        f"{per_period / periods:,.0f} per period",
        f"    = transport, DSP work:     {per_frame(fixed)}   "
        f"{100.0 * fixed / (budget * frames):5.1f}% of budget",
        "",
        f"    stalled on the host port:  {per_frame(waiting)}   "
        f"the 68030 delivers a word every {host_cycles_per_word:.2f} cycles "
        f"({host_us_per_word:.2f} us)",
        f"    transmitter drain:         {per_frame(drain)}   "
        f"{drain / handoffs:,.0f} per handoff, SSI-paced",
        f"    idle:                      {per_frame(idle - drain)}   "
        f"boundary spin and command wait",
        "",
        f"  polled transport, work and stall: {(fixed + waiting) / frames:,.2f} per frame, "
        f"{100.0 * (fixed + waiting) / (budget * frames):.1f}% of budget",
        f"  receive by host interrupt instead: {per_interrupt:.2f} per word, "
        f"{per_interrupt * WORDS_PER_PERIOD / FRAMES_PER_PERIOD:.2f} per frame, "
        f"the SSI interrupt's measured cost",
        f"  transport with interrupt receive:  "
        f"{(isr + per_interrupt * words + per_period) / frames:,.2f} per frame",
    ]
    if cycles.get("ssi underrun recovery"):
        lines.append(f"  WARNING: SSI underrun recovery ran: {cycles['ssi underrun recovery']:,.0f} cycles")
    if other:
        lines.append("")
        lines.append("Cycles outside the transport (per frame):")
        for name, value in sorted(other.items(), key=lambda item: item[1], reverse=True):
            lines.append(f"  {value / frames:8.2f}  {name}")
    lines.append("")
    lines.append("Categories (instruction cycles per frame):")
    for name, value in sorted(cycles.items(), key=lambda item: item[1], reverse=True):
        lines.append(f"  {value / frames:8.2f}  {name}")

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

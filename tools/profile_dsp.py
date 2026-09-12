#!/usr/bin/env python3
"""Prepare and summarize a deterministic Hatari DSP render profile."""

from __future__ import annotations

import argparse
import bisect
import re
from collections import defaultdict
from pathlib import Path


LABEL_RE = re.compile(r"^\s*\d+\s+(?:[PXY]:[0-9A-F]+\s+)?\s*([A-Za-z_][A-Za-z0-9_]*):\s*$")
ADDRESS_RE = re.compile(r"^\s*\d+\s+([PXYL]):([0-9A-F]+)\b")
# Hatari prints the instruction percentage through the host's locale, so a
# German Windows host writes "0,01%" where a C-locale host writes "0.01%".
# Accept either separator; the counts beside it are plain integers.
PROFILE_RE = re.compile(
    r"^p:([0-9a-f]+).*?\s([0-9]+[.,][0-9]+)% \((\d+), (\d+), (\d+)\)$"
)


def parse_listing(path: Path) -> dict[tuple[str, str], int]:
    symbols: dict[tuple[str, str], int] = {}
    pending: list[str] = []
    for line in path.read_text(errors="replace").splitlines():
        label = LABEL_RE.match(line)
        if label:
            pending.append(label.group(1))
            continue
        address = ADDRESS_RE.match(line)
        if not address or not pending:
            continue
        space = address.group(1).upper()
        value = int(address.group(2), 16)
        # An l-memory word is the X:Y pair at one address, so record both.
        spaces = ("X", "Y") if space == "L" else (space,)
        for name in pending:
            for resolved_space in spaces:
                symbols[(resolved_space, name)] = value
        pending.clear()
    return symbols


def require_symbol(symbols: dict[tuple[str, str], int], space: str, name: str) -> int:
    key = (space, name)
    if key not in symbols:
        raise SystemExit(f"error: {space}:{name} was not found in the DSP listing")
    return symbols[key]


def write_debugger_scripts(
    listing: Path,
    output_dir: Path,
    marker: int,
    start_symbol: str,
    end_symbol: str,
    dumps: list[tuple[str, int, int]] | None = None,
    marker_space: str = "X",
    dump_symbol: str | None = None,
) -> None:
    dumps = dumps or []
    symbols = parse_listing(listing)
    command_ping = require_symbol(symbols, "P", "command_ping")
    profile_start = require_symbol(symbols, "P", start_symbol)
    profile_end = require_symbol(symbols, "P", end_symbol)
    last_command = require_symbol(symbols, marker_space.upper(), "last_command")
    dump_at = require_symbol(symbols, "P", dump_symbol) if dump_symbol else None

    output_dir.mkdir(parents=True, exist_ok=True)
    arm = (output_dir / "arm.ini").resolve()
    begin = (output_dir / "begin.ini").resolve()
    end = (output_dir / "end.ini").resolve()
    profile = (output_dir / "profile.txt").resolve()

    (output_dir / "start.ini").write_text(
        f"db pc = ${command_ping:04x} && (${last_command:04x}).{marker_space.lower()} "
        f"= ${marker:06x} :once :trace :file {arm}\n"
    )
    arm.write_text(f"db pc = ${profile_start:04x} :once :trace :file {begin}\n")
    begin.write_text(
        "dp on\n"
        f"db pc = ${profile_end:04x} :once :trace :file {end}\n"
    )
    # The end breakpoint may also dump DSP memory, so one run both profiles
    # a render and hands its output buffer to the oracle comparison; with a
    # dump symbol the dump waits for a later point, past work that follows
    # the profiled window but precedes the buffer's final form.
    dump_lines = [f"dm {space} ${first:x}-${last:x}" for space, first, last in dumps]
    end_lines = [f"dp save {profile}", "dp off"]
    if dump_at is None:
        end_lines += dump_lines
    else:
        dump = (output_dir / "dump.ini").resolve()
        end_lines.append(f"db pc = ${dump_at:04x} :once :trace :file {dump}")
        dump.write_text("\n".join(dump_lines) + "\n")
    end.write_text("\n".join(end_lines) + "\n")


def parse_profile(path: Path) -> tuple[int, int, list[tuple[int, int, int, float]]]:
    cycles_per_second = 0
    rows: list[tuple[int, int, int, float]] = []
    for line in path.read_text(errors="replace").splitlines():
        if line.startswith("Cycles/second:"):
            cycles_per_second = int(line.split(":", 1)[1])
            continue
        match = PROFILE_RE.match(line)
        if not match:
            continue
        pc = int(match.group(1), 16)
        percent = float(match.group(2).replace(",", "."))
        instructions = int(match.group(3))
        cycles = int(match.group(4))
        rows.append((pc, instructions, cycles, percent))
    if not cycles_per_second or not rows:
        raise SystemExit(f"error: {path} is not a complete Hatari DSP profile")
    return cycles_per_second, sum(row[2] for row in rows), rows


def summarize_profile(
    listing: Path,
    profile: Path,
    output: Path | None,
    samples: int,
    sample_rate: float,
    title: str,
    unit_label: str,
    projection_factor: float,
    projection_label: str,
) -> None:
    symbols = parse_listing(listing)
    p_labels = sorted(
        (address, name) for (space, name), address in symbols.items() if space == "P"
    )
    label_addresses = [item[0] for item in p_labels]

    cycles_per_second, oscillator_cycles, rows = parse_profile(profile)
    executed_instructions = sum(row[1] for row in rows)
    instruction_cycles = oscillator_cycles / 2.0
    instructions_per_sample = executed_instructions / samples
    measured_per_sample = instruction_cycles / samples
    projected_per_sample = measured_per_sample * projection_factor
    budget_per_sample = cycles_per_second / 2.0 / sample_rate
    required_speedup = projected_per_sample / budget_per_sample
    measured_ms = oscillator_cycles * 1000.0 / cycles_per_second
    projected_ms = measured_ms * projection_factor
    period_ms = samples * 1000.0 / sample_rate

    blocks: defaultdict[str, list[int]] = defaultdict(lambda: [0, 0])
    for pc, instructions, cycles, _percent in rows:
        index = bisect.bisect_right(label_addresses, pc) - 1
        if index < 0:
            label = f"p_${pc:04x}"
        else:
            _address, name = p_labels[index]
            label = name
        blocks[label][0] += instructions
        blocks[label][1] += cycles

    lines = [
        title,
        f"  {unit_label}s:             {samples}",
        f"  Hatari DSP oscillator:      {cycles_per_second:,} Hz",
        f"  executed instructions:      {executed_instructions:,}",
        f"  measured oscillator cycles: {oscillator_cycles:,}",
        f"  measured instruction cycles: {instruction_cycles:,.0f}",
        f"  executed instructions/{unit_label}: {instructions_per_sample:,.2f}",
        f"  instruction cycles/{unit_label}:  {measured_per_sample:,.2f}",
    ]
    if projection_factor != 1.0:
        lines.extend(
            [
                f"  {projection_label}: {projection_factor:g}x",
                f"  projected cycles/{unit_label}:    {projected_per_sample:,.2f}",
            ]
        )
    lines.extend(
        [
        f"  real-time budget/{unit_label}:     {budget_per_sample:,.2f}",
        f"  measured block time:         {measured_ms:,.2f} ms",
        *(
            [f"  projected workload time:     {projected_ms:,.2f} ms"]
            if projection_factor != 1.0
            else []
        ),
        f"  real-time block period:      {period_ms:,.2f} ms",
        f"  required speedup:            {required_speedup:,.2f}x",
        "",
        "Largest labeled basic blocks:",
        ]
    )
    for label, (instructions, cycles) in sorted(
        blocks.items(), key=lambda item: item[1][1], reverse=True
    )[:12]:
        share = cycles * 100.0 / oscillator_cycles
        lines.append(
            f"  {share:6.2f}%  {cycles:10,d} cycles  {instructions:9,d} instructions  {label}"
        )

    report = "\n".join(lines) + "\n"
    print(report, end="")
    if output:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(report)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare = subparsers.add_parser("prepare", help="write Hatari debugger scripts")
    prepare.add_argument("--listing", type=Path, required=True)
    prepare.add_argument("--output-dir", type=Path, required=True)
    prepare.add_argument("--marker", type=lambda value: int(value, 0), required=True)
    prepare.add_argument("--start-symbol", default="command_start_audio")
    prepare.add_argument("--end-symbol", default="ssi_start_buffered")
    prepare.add_argument(
        "--dump",
        action="append",
        default=[],
        metavar="SPACE:FIRST-LAST",
        help="also dump this DSP memory range when the end breakpoint fires, "
        "e.g. x:0x1000-0x1fff; repeatable",
    )
    prepare.add_argument(
        "--marker-space",
        default="X",
        choices=["X", "Y", "x", "y"],
        help="memory space holding last_command, where the marker is watched",
    )
    prepare.add_argument(
        "--dump-symbol",
        help="P label at which to dump memory instead of the end breakpoint",
    )

    report = subparsers.add_parser("report", help="summarize a saved Hatari profile")
    report.add_argument("--listing", type=Path, required=True)
    report.add_argument("--profile", type=Path, required=True)
    report.add_argument("--output", type=Path)
    report.add_argument("--samples", "--native-samples", dest="samples", type=int, default=1280)
    report.add_argument("--sample-rate", type=float, default=62500.0)
    report.add_argument(
        "--title",
        default="DSP56001 eight-channel full-load render profile (no PM)",
    )
    report.add_argument("--unit-label", default="native sample")
    report.add_argument("--projection-factor", type=float, default=1.0)
    report.add_argument("--projection-label", default="linear workload projection")

    arguments = parser.parse_args()
    if arguments.command == "prepare":
        dumps = []
        for spec in arguments.dump:
            space, _, span = spec.partition(":")
            first, _, last = span.partition("-")
            dumps.append((space.lower(), int(first, 0), int(last, 0)))
        write_debugger_scripts(
            arguments.listing,
            arguments.output_dir,
            arguments.marker,
            arguments.start_symbol,
            arguments.end_symbol,
            dumps,
            arguments.marker_space,
            arguments.dump_symbol,
        )
    else:
        summarize_profile(
            arguments.listing,
            arguments.profile,
            arguments.output,
            arguments.samples,
            arguments.sample_rate,
            arguments.title,
            arguments.unit_label,
            arguments.projection_factor,
            arguments.projection_label,
        )


if __name__ == "__main__":
    main()

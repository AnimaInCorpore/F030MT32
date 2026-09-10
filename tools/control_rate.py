#!/usr/bin/env python3
"""The control rate: how often a block-rate LA32 kernel must update its controls.

Munt hands its LA32 wave generator a fresh amp, pitch and cutoff every
sample. The amp and the cutoff come from LA32Ramp, the chip's own linear
ramp toward a target; the pitch is re-evaluated by the MT-32's MCU timer
every eight samples or so. The DSP kernels hold all three constant across a
block and derive their table constants once per block, so two questions
decide the design: how long a block may be before the held controls become
audible against the per-sample model, and what the per-block derivation
costs the DSP.

This tool answers the first with the oracle alone and the second on the DSP:

* `sweep` renders each scenario with the oracle's `control` mode per sample
  and with the controls held per block of 2 to 128 frames, in several
  modes - hold everything, hold pitch and cutoff but ramp the amp linearly
  across the block, hold one control at a time - and grades every render
  against the per-sample one with the perceptual bounds;
* `tables` emits the host's payloads for the DSP runs: the static kernel
  constants, the block length and count, and one record of (amp >> 10,
  pitch, cutoff >> 3) per block, sampled from the oracle's per-sample
  controls - the words a host running the envelopes would send per block;
* the Makefile's `profile-control` runs one scenario on the DSP with a
  block length, where `la32_block_derive` turns each record into the
  kernel's constants - only what the record changed - compares the output
  with the oracle's held render, and reports the cycles per frame; the
  `summarize` command splits the profile into the kernel's cost per frame
  and the derivation's, the position install's and the loop's per block.

The scenarios are the MT-32's envelope vocabulary at its extremes: the
fastest TVA and TVF attack the ROM can ask for, a slow string swell with
vibrato, a brass sweep, a fast release, and - to measure the derivation's
cheap paths - a settled sustain and a vibrato over settled amp and cutoff.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from la32_partial import (  # noqa: E402
    CONFIG_WORDS, Config, Run, Tables, WORD_MASK, config_words, grade, key_pitch,
)

FRAMES = 2048
CONTROL_RATE = 16                          # frames between the host's looks at a partial
BLOCK_LENGTHS = [8, 16, 32, 64, "adaptive"]  # the DSP runs: N codes 0..4
SWEEP_BLOCKS = [2, 4, 8, 16, 32, 64, 128]
SWEEP_MODES = [
    ("APC", "hold amp, pitch and cutoff"),
    ("PCR", "hold pitch and cutoff, ramp the amp across the block"),
    ("PC", "hold pitch and cutoff, amp per sample"),
    ("A", "hold the amp only"),
    ("P", "hold the pitch only"),
    ("C", "hold the cutoff only"),
]
MARKER = 0x01C300
RECORD_WORDS = 4                          # frames held, amp >> 10, pitch, cutoff >> 3
HEADER_WORDS = CONFIG_WORDS + 2 + 2       # constants, epw and ras, nominal block length and record count
FASTEST = 127
IMMEDIATE = 0x80 | 127                     # descending at the top rate: lands at once


@dataclass(frozen=True)
class Scenario:
    name: str
    sawtooth: bool
    pulse_width: int
    resonance: int
    pan: int
    base_pitch: int
    base_cutoff: int              # TVF base cutoff, 0..255: cutoff = base << 18 + ramp
    lfo_depth: int                # pitch units, 4096 per octave
    lfo_period: int               # frames
    amp: tuple                    # (target, increment) ramps, TVA::startRamp arguments
    cutoff: tuple                 # the same for the TVF's cutoff modifier

    @property
    def epw(self) -> int:
        return (self.pulse_width - 128) << 6 if self.pulse_width > 128 else 0

    @property
    def ras(self) -> int:
        return (32 - self.resonance) << 10


SCENARIOS = [
    # The fastest attack the ROM can ask for, on amp and cutoff at once, then
    # a quick decay: the LA32Ramp moves one level per sample at increment 127.
    Scenario("pluck", False, 128, 12, 6, key_pitch(60, False), 150, 0, 0,
             ((150, IMMEDIATE), (250, FASTEST), (200, 0x80 | 72), (200, 0)),
             ((0, IMMEDIATE), (70, FASTEST), (20, 0x80 | 68), (20, 0))),
    # A slow swell with vibrato: 50 ms attack, a 6 Hz triangle of 14 cents.
    Scenario("string", True, 100, 8, 6, key_pitch(55, True), 120, 48, 5461,
             ((120, IMMEDIATE), (235, 88), (235, 0)),
             ((0, IMMEDIATE), (40, 70), (40, 0))),
    # A brass sweep: 12 ms attack, a strong filter envelope, a wide 8 Hz LFO.
    Scenario("brass", True, 128, 22, 8, key_pitch(62, True), 130, 120, 4096,
             ((140, IMMEDIATE), (245, 104), (215, 0x80 | 76), (215, 0)),
             ((0, IMMEDIATE), (90, 100), (35, 0x80 | 80), (35, 0))),
    # A note that starts loud and releases quickly on both controls.
    Scenario("release", False, 160, 4, 6, key_pitch(48, False), 200, 0, 0,
             ((230, IMMEDIATE), (0, 0x80 | 118), (0, 0)),
             ((60, IMMEDIATE), (0, 0x80 | 100), (0, 0))),
    # Every control settled from the first frame: the sustain of a note,
    # where a derivation that skips what did not change earns its keep.
    Scenario("sustain", True, 128, 16, 6, key_pitch(64, True), 140, 0, 0,
             ((220, IMMEDIATE), (220, 0)),
             ((30, IMMEDIATE), (30, 0))),
    # Settled amp and cutoff under a 6 Hz vibrato of 18 cents: only the
    # pitch moves, so only the step is derived.
    Scenario("vibrato", True, 110, 10, 8, key_pitch(69, True), 150, 60, 5461,
             ((225, IMMEDIATE), (225, 0)),
             ((25, IMMEDIATE), (25, 0))),
]
KERNELS = ["exact", "perceptual"]


@dataclass(frozen=True)
class ControlRun:
    scenario: Scenario
    kernel: str

    @property
    def name(self) -> str:
        return f"{self.scenario.name}/{self.kernel}"


RUNS = [ControlRun(scenario, kernel) for kernel in KERNELS for scenario in SCENARIOS]


def segments_text(scenario: Scenario, schedule: list | None = None) -> str:
    lines = [f"a {t} {i}" for t, i in scenario.amp] + [f"c {t} {i}" for t, i in scenario.cutoff]
    if schedule:
        lines += [f"h {start} {ampt} {pitch} {cutoff3}" for start, ampt, pitch, cutoff3 in schedule]
    return "\n".join(lines) + "\n"


def records(controls: list[list[int]], ncode: int) -> list[tuple[int, int, int, int]]:
    """The records the host sends: (start frame, amp >> 10, pitch, cutoff >> 3).

    A fixed block length sends one every N frames. The adaptive stream is
    what a host that looks at each partial every CONTROL_RATE frames sends:
    a record only when one of the three words moved since the last one, so
    an attack costs a record per look and a sustain costs none.
    """
    block = BLOCK_LENGTHS[ncode]
    if block != "adaptive":
        return [(t, *controls[t]) for t in range(0, FRAMES, block)]
    out = []
    for t in range(0, FRAMES, CONTROL_RATE):
        if not out or list(out[-1][1:]) != controls[t]:
            out.append((t, *controls[t]))
    return out


def record_lengths(schedule: list[tuple[int, int, int, int]]) -> list[int]:
    starts = [start for start, *_ in schedule] + [FRAMES]
    return [b - a for a, b in zip(starts, starts[1:])]


def block_name(ncode: int) -> str:
    block = BLOCK_LENGTHS[ncode]
    return "adaptive" if block == "adaptive" else f"N{block}"


def oracle_args(scenario: Scenario, block: int, mode: str, pan_left: int, pan_right: int) -> list[str]:
    return [
        "control", str(int(scenario.sawtooth)), str(scenario.pulse_width), str(scenario.resonance),
        str(pan_left), str(pan_right), str(FRAMES), str(block), mode,
        str(scenario.base_pitch), str(scenario.base_cutoff), str(scenario.lfo_depth), str(scenario.lfo_period),
    ]


def run_oracle(oracle: Path, scenario: Scenario, block: int, mode: str, pan_left: int, pan_right: int) -> list[list[int]]:
    # An absolute path: a native Windows Python does not search a relative
    # one with forward slashes.
    result = subprocess.run(
        [str(Path(oracle).resolve())] + oracle_args(scenario, block, mode, pan_left, pan_right),
        input=segments_text(scenario), capture_output=True, text=True, check=True,
    )
    return [[int(v) for v in line.split()] for line in result.stdout.splitlines() if line.strip()]


def scenario_config(scenario: Scenario, controls: list[list[int]]) -> Config:
    """A Config carrying the first frame's controls: the static words come from it."""
    ampt, pitch, cutoff3 = controls[0]
    return Config(scenario.name, scenario.sawtooth, scenario.pulse_width, scenario.resonance,
                  ampt << 10, pitch, cutoff3 << 3, scenario.pan)


def pans(scenario: Scenario) -> tuple[int, int]:
    config = Config(scenario.name, scenario.sawtooth, scenario.pulse_width, scenario.resonance, 0, 0, 0, scenario.pan)
    return config.pan_left, config.pan_right


def payload(tables: Tables, run: ControlRun, controls: list[list[int]], ncode: int) -> list[int]:
    config = scenario_config(run.scenario, controls)
    words = config_words(tables, Run(config, run.kernel))
    schedule = records(controls, ncode)
    block = BLOCK_LENGTHS[ncode]
    words += [run.scenario.epw, run.scenario.ras, CONTROL_RATE if block == "adaptive" else block, len(schedule)]
    for (start, ampt, pitch, cutoff3), length in zip(schedule, record_lengths(schedule)):
        words += [length, ampt, pitch, cutoff3]
    assert len(words) == HEADER_WORDS + RECORD_WORDS * len(schedule)
    if RECORD_WORDS * len(schedule) > 1024:
        raise SystemExit(f"error: {run.name}: {len(schedule)} records overflow the DSP's record area")
    for word in words:
        if not 0 <= word <= WORD_MASK:
            raise SystemExit(f"error: {run.name}: payload word {word:#x} exceeds 24 bits")
    return words


def emit_tables(tables: Tables, oracle: Path) -> str:
    lines = [
        "; generated by tools/control_rate.py - do not edit",
        ";",
        "; Payloads for MT32_CMD_CONTROL_RUN, one per run and block-length code:",
        "; the kernel's static constants, the pulse-width and resonance terms",
        "; the per-block derivation needs, the nominal block length and the",
        "; record count, then one record per block of the frames it holds for,",
        "; amp >> 10, pitch and cutoff >> 3. The last code is the adaptive",
        "; stream, a record only where a word moved. The table at the end holds",
        f"; (pointer, word count) per run * {len(BLOCK_LENGTHS)} + code.",
        "",
    ]
    table = []
    for r, run in enumerate(RUNS):
        left, right = pans(run.scenario)
        controls = run_oracle(oracle, run.scenario, 1, "D", left, right)
        if len(controls) != FRAMES:
            raise SystemExit(f"error: the oracle dumped {len(controls)} control rows for {run.name}")
        for n in range(len(BLOCK_LENGTHS)):
            words = payload(tables, run, controls, n)
            label = f"ctrl_run{r}_n{n}"
            table.append((label, len(words)))
            lines.append(f"{label}:        ; {run.name}, {block_name(n)}, {len(records(controls, n))} records")
            for i in range(0, len(words), 6):
                lines.append("        dc.l    " + ",".join(f"${w:08x}" for w in words[i:i + 6]))
    lines.append("ctrl_payload_table:")
    for label, count in table:
        lines.append(f"        dc.l    {label},{count}")
    return "\n".join(lines) + "\n"


def grade_channels(got: list[list[int]], ref: list[list[int]]) -> tuple[list[str], bool, int, float, float, float]:
    ok = True
    lines = []
    worst = 0
    worst_db = -999.0
    correlation = 1.0
    spectral = 1.0
    for channel, column in (("left", 1), ("right", 2)):
        g = [row[column] for row in got]
        r = [row[column] for row in ref]
        text, channel_ok = grade(g, r)
        lines.append(f"  {channel}:")
        lines += text
        ok = ok and channel_ok
        worst = max(worst, max(abs(a - b) for a, b in zip(g, r)))
        for line in text:
            if "dB of full scale" in line:
                worst_db = max(worst_db, float(line.split()[2]))
            elif line.strip().startswith("correlation"):
                correlation = min(correlation, float(line.split()[1]))
            elif line.strip().startswith("spectral cosine"):
                spectral = min(spectral, float(line.split()[2]))
    return lines, ok, worst, worst_db, correlation, spectral


def sweep(oracle: Path, output: Path | None) -> None:
    lines = [
        "Control rate sweep: held controls against Munt's per-sample controls",
        f"  {FRAMES} frames per render. Per mode and block length, the first line is",
        "  the max abs error in words (full scale 16384) and the RMS error in dB of",
        "  full scale - the perceptual gate's two absolute bounds are 64 words and",
        "  -72 dB, * marks a render inside every bound - and the second line the",
        "  correlation and the spectral cosine, which is blind to the phase lag a",
        "  held pitch leaves on a steep wave.",
        "",
    ]
    for scenario in SCENARIOS:
        left, right = pans(scenario)
        ref = run_oracle(oracle, scenario, 1, "", left, right)
        peak = max(abs(row[0]) for row in ref)
        lines.append(f"{scenario.name}: {'sawtooth' if scenario.sawtooth else 'square'}, "
                     f"peak sample {peak}")
        header = "  mode  " + "".join(f"{f'N={n}':>14}" for n in SWEEP_BLOCKS)
        lines.append(header)
        for mode, doc in SWEEP_MODES:
            cells = []
            shapes = []
            for block in SWEEP_BLOCKS:
                got = run_oracle(oracle, scenario, block, mode, left, right)
                _text, ok, worst, worst_db, correlation, spectral = grade_channels(got, ref)
                cells.append(f"{worst:5d} {worst_db:6.1f}{'*' if ok else ' '}")
                shapes.append(f"{correlation:.4f}/{spectral:.4f}")
            lines.append(f"  {mode:5s} " + "".join(f"{c:>14}" for c in cells) + f"   {doc}")
            lines.append("        " + "".join(f"{c:>14}" for c in shapes))
        lines.append("")
    lines.append("  * = within the perceptual bounds")
    text = "\n".join(lines) + "\n"
    print(text, end="")
    if output:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(text)


def compare(dump: Path, oracle_frames: Path, run_index: int) -> int:
    from la32_partial import compare as compare_dump
    return compare_dump(dump, oracle_frames, RUNS[run_index])


KERNEL_LOOPS = {"la32_square_loop", "la32_saw_loop", "la32_psquare_loop", "la32_psaw_loop"}
KERNEL_ENTRIES = {
    "la32_square_run", "la32_saw_run", "la32_psquare_run", "la32_psaw_run",
    "la32_square_done", "la32_saw_done", "la32_psquare_done", "la32_psaw_done",
}
POSITION_LABELS = {"la32_block_positions", "la32_positions_perceptual"}
LOOP_LABELS = {"la32_control_loop", "la32_control_steady", "la32_control_next"}


def summarize(listing: Path, profile: Path, blocks: int, label: str, output: Path | None) -> None:
    """Instruction cycles per frame for the kernel and per record for the rest."""
    import bisect
    from profile_dsp import parse_listing as parse, parse_profile
    symbols = parse(listing)
    labels = sorted((address, name) for (space, name), address in symbols.items() if space == "P")
    addresses = [address for address, _ in labels]
    _hz, _total, rows = parse_profile(profile)
    groups: dict[str, float] = {"kernel": 0.0, "derivation": 0.0, "positions": 0.0,
                                "loop": 0.0, "entry and exit": 0.0, "other": 0.0}
    for pc, _instructions, cycles, _percent in rows:
        index = bisect.bisect_right(addresses, pc) - 1
        name = labels[index][1] if index >= 0 else ""
        c = cycles / 2.0
        if name in KERNEL_LOOPS:
            groups["kernel"] += c
        elif name.startswith("la32_derive") or name == "la32_block_derive":
            groups["derivation"] += c
        elif name in POSITION_LABELS:
            groups["positions"] += c
        elif name in LOOP_LABELS:
            groups["loop"] += c
        elif name in KERNEL_ENTRIES:
            groups["entry and exit"] += c
        else:
            groups["other"] += c
    per_block = sum(v for k, v in groups.items() if k != "kernel")
    lines = [
        f"  {label}, {blocks} records: kernel {groups['kernel'] / FRAMES:6.2f} cycles per frame; per record: "
        f"derivation {groups['derivation'] / blocks:6.1f}, positions {groups['positions'] / blocks:5.1f}, "
        f"loop {groups['loop'] / blocks:5.1f}, entry and exit {groups['entry and exit'] / blocks:5.1f}, "
        f"other {groups['other'] / blocks:5.1f} = {per_block / blocks:6.1f} "
        f"({per_block / FRAMES:5.2f} per frame)",
    ]
    text = "\n".join(lines) + "\n"
    print(text, end="")
    if output:
        output.write_text(text)


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("tables", help="emit the host's control payload include")
    p.add_argument("--tables", type=Path, required=True)
    p.add_argument("--oracle", type=Path, required=True)
    p = sub.add_parser("sweep", help="grade held controls against per-sample ones with the oracle")
    p.add_argument("--oracle", type=Path, required=True)
    p.add_argument("--output", type=Path)
    for name, doc in (
        ("segments", "print the scenario's ramp segments for the oracle, with the adaptive schedule for its code"),
        ("oracle-args", "print the oracle command line for the run's held render at --ncode"),
        ("name", "print the run's name"),
        ("kernel", "print exact or perceptual"),
        ("marker", "print the profiler marker for the run at --ncode"),
        ("cfg", "print the PROFILE.CFG text for the run at --ncode"),
        ("block", "print the block length of --ncode"),
    ):
        p = sub.add_parser(name, help=doc)
        p.add_argument("run", type=int)
        p.add_argument("--ncode", type=int, default=0)
        p.add_argument("--oracle", type=Path, help="the oracle binary, for the adaptive schedule")
    p = sub.add_parser("compare", help="check the DSP dump against the oracle's held render")
    p.add_argument("--dump", type=Path, required=True)
    p.add_argument("--oracle", type=Path, required=True)
    p.add_argument("run", type=int)
    p = sub.add_parser("summarize", help="split a control run's DSP profile into kernel and per-record costs")
    p.add_argument("--listing", type=Path, required=True)
    p.add_argument("--profile", type=Path, required=True)
    p.add_argument("--oracle", type=Path, required=True)
    p.add_argument("--output", type=Path)
    p.add_argument("run", type=int)
    p.add_argument("--ncode", type=int, default=0)
    sub.add_parser("count")
    args = parser.parse_args()

    if args.command == "count":
        print(len(RUNS))
        return
    if args.command == "tables":
        sys.stdout.write(emit_tables(Tables(args.tables), args.oracle))
        return
    if args.command == "sweep":
        sweep(args.oracle, args.output)
        return
    if args.command == "compare":
        sys.exit(compare(args.dump, args.oracle, args.run))
    run = RUNS[args.run]
    adaptive = BLOCK_LENGTHS[args.ncode] == "adaptive"

    def schedule():
        if args.oracle is None:
            raise SystemExit("error: the adaptive schedule needs --oracle")
        left, right = pans(run.scenario)
        return records(run_oracle(args.oracle, run.scenario, 1, "D", left, right), args.ncode)

    if args.command == "segments":
        sys.stdout.write(segments_text(run.scenario, schedule() if adaptive else None))
    elif args.command == "oracle-args":
        left, right = pans(run.scenario)
        if adaptive:
            print(" ".join(oracle_args(run.scenario, 1, "S", left, right)))
        else:
            print(" ".join(oracle_args(run.scenario, BLOCK_LENGTHS[args.ncode], "APC", left, right)))
    elif args.command == "name":
        print(f"{run.name}/{block_name(args.ncode)}")
    elif args.command == "kernel":
        print(run.kernel)
    elif args.command == "marker":
        print(f"{MARKER | (args.run << 4) | args.ncode:#08x}")
    elif args.command == "cfg":
        print(f"C{args.run:02d}{args.ncode}")
    elif args.command == "block":
        print(BLOCK_LENGTHS[args.ncode])
    elif args.command == "summarize":
        summarize(args.listing, args.profile, len(schedule()), block_name(args.ncode), args.output)


if __name__ == "__main__":
    main()

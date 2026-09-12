#!/usr/bin/env python3
"""One PCM partial on the 68030: runs, tables, oracle glue, comparison, profile.

The MT-32's PCM partials cannot live on the Falcon DSP, whose 32K words of
SRAM cannot hold a 262,144-sample ROM, so the plan renders them on the
68030 (docs/architecture.md). This tool measures what that costs. It
defines a handful of runs - two synthetic waves in the PCM ROM's own word
format, a pitch, an amp and a pan each, rendered by an exact 68030 kernel
that reproduces Munt's integer model word for word and by a perceptual one
that keeps the wave linear and applies the amp and pan as one multiply -
and provides everything around them:

* `tables` emits the host's assembler include: the interpolateExp table the
  exact unlog is built from, both waves as the words a production host would
  convert the ROM into, and one configuration record per run;
* `wave` and `oracle-args` feed Munt's LA32IntPartialPair the same wave and
  parameters through tools/la32_partial_oracle.cpp;
* `prepare` writes the Hatari debugger scripts that bracket the timed render
  between two host-port markers and save the CPU profile;
* `compare` checks the file the 68030 wrote against the oracle, word for word
  for the exact kernel and against the perceptual bounds otherwise;
* `report` turns the CPU profile and the program's own 200 Hz tick count
  into cycles and milliseconds per period, and into partials per period.

The ROM word format, from Synth::loadPCMROM and pcmSampleToLogSample: bit 15
is the sign and the low fifteen bits hold 32787 - log/2, where log is the
LA32's 16-bit log value with twelve fractional bits, so louder samples have
larger words. A production host would convert the ROM once into the form
the exact kernel reads: the sign kept in bit 15 and the low bits holding
min(32787 - m, 32767), the half-log itself. Twenty words per wave with m
below 20 lose their top bit in that clamp; every one of them is a sample
below one LSB, and unlogs to zero either way.
"""

from __future__ import annotations

import argparse
import math
import re
import struct
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from la32_partial import Tables, amp_for_level, grade, pan_factor  # noqa: E402
from profile_dsp import parse_listing, require_symbol  # noqa: E402

FRAMES = 2048                 # frames rendered for the comparison
TIMING_PERIODS = 128          # periods rendered inside the profile window
FRAMES_PER_PERIOD = 512
SAMPLE_RATE = 32779.9479166667
PERIOD_MS = FRAMES_PER_PERIOD * 1000.0 / SAMPLE_RATE
CPU_HZ = 16042494.0           # Falcon PAL 68030: the 32,084,988 Hz oscillator halved
HZ200_MS = 5.0
TRANSPORT_MS = 2.33           # feeding the DSP a stereo period, docs/la32-budget.md
MARKER_BEGIN = 0x01C100
MARKER_END = 0x01C200
CONFIG_LONGS = 10
CONFIG_BYTES = 4 * CONFIG_LONGS
HEADER = struct.Struct(">4sIIII")   # magic, frames, timing periods, 200 Hz ticks, run
MAGIC = b"PCM1"
ROM_TOS = 0xE00000

WAVE_LOOP = 0
WAVE_SHOT = 1
WAVES = [
    ("loop", 2048, True),     # the ROM's shortest wave length, looped
    ("shot", 4096, False),    # one-shot: the partial ends inside the run
]


def lcg(seed: int):
    while True:
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        yield seed


def linear_to_rom(value: int) -> int:
    """A linear sample as the 16-bit word Synth::loadPCMROM leaves in pcmROMData."""
    magnitude = abs(value)
    if magnitude == 0:
        m = 0
    else:
        log = (13.0 - math.log2(magnitude)) * 4096.0
        m = max(0, min(32767, 32787 - int(round(log / 2.0))))
    return (0x8000 if value < 0 else 0) | m


def rom_to_host(word: int) -> int:
    """The word the exact kernel reads: sign in bit 15, half-log clamped to 15 bits."""
    return (word & 0x8000) | min(32787 - (word & 0x7FFF), 32767)


def wave_samples(index: int) -> list[int]:
    """Deterministic linear samples for a wave; the same on every platform."""
    _name, length, looped = WAVES[index]
    noise = lcg(0x4D543332 + index)
    samples = []
    if looped:
        # Eight harmonics at 1/k with fixed phases plus a little noise: a
        # bright, periodic wave whose neighbours differ, so the interpolation
        # matters everywhere.
        for n in range(length):
            t = 2.0 * math.pi * n / length
            value = sum(math.sin(k * t + 0.7 * k) / k for k in range(1, 9))
            value += 0.05 * ((next(noise) / 0x7FFFFFFF) * 2.0 - 1.0)
            samples.append(int(round(4400.0 * value)))
    else:
        # A decaying noise burst, the shape of the drum and attack waves.
        for n in range(length):
            value = ((next(noise) / 0x7FFFFFFF) * 2.0 - 1.0) * math.exp(-n / 1200.0)
            samples.append(int(round(7800.0 * value)))
    peak = max(abs(s) for s in samples)
    if peak > 8191:
        raise SystemExit(f"wave {index} peaks at {peak}, above the LA32's 8191")
    return samples


def wave_rom_words(index: int) -> list[int]:
    return [linear_to_rom(s) for s in wave_samples(index)]


@dataclass(frozen=True)
class PCMConfig:
    name: str
    wave: int
    pitch: int      # step in samples per frame is 2^(pitch/4096 - 5)
    level: int      # TVA ramp target; amp_for_level turns it into the amp
    pan: int        # PatchTemp panpot 0..14
    # Partial.cpp negates both pan factors of partials 4-7 in every eight
    # unless nice partial mixing is on, which the renderer turns off.
    inverted: bool = False

    @property
    def polarity(self) -> int:
        return -1 if self.inverted else 1

    @property
    def amp(self) -> int:
        return amp_for_level(self.level)

    @property
    def ampt(self) -> int:
        return self.amp >> 10

    @property
    def pan_left(self) -> int:
        return self.polarity * pan_factor(self.pan)

    @property
    def pan_right(self) -> int:
        return self.polarity * pan_factor(14 - self.pan)

    @property
    def length(self) -> int:
        return WAVES[self.wave][1]

    @property
    def looped(self) -> bool:
        return WAVES[self.wave][2]


CONFIGS = [
    # step 0.75: most frames read the pair the previous frame read
    PCMConfig("pcm-loop-slow", WAVE_LOOP, 18780, 250, 6),
    # step 1.5: every frame a new pair, some frames skip a sample
    PCMConfig("pcm-loop-fast", WAVE_LOOP, 22876, 236, 4),
    # step 2.25 through a one-shot wave: it ends after about 1,820 frames
    PCMConfig("pcm-shot-end", WAVE_SHOT, 25272, 246, 10),
    # step 0.31: each pair lasts three frames, the ladder at its coarsest
    PCMConfig("pcm-loop-deep", WAVE_LOOP, 13557, 240, 6),
    # step 1.5 with the pan pair negated, as Munt mixes partials 4-7 of eight
    PCMConfig("pcm-loop-inverted", WAVE_LOOP, 22876, 236, 2, True),
]
KERNELS = ["exact", "perceptual", "mono"]


@dataclass(frozen=True)
class PCMRun:
    config: PCMConfig
    kernel: str

    @property
    def name(self) -> str:
        return f"{self.config.name}/{self.kernel}"


RUNS = [PCMRun(config, kernel) for kernel in KERNELS for config in CONFIGS]


def pcm_step(tables: Tables, pitch: int) -> int:
    """LA32WaveGenerator::generateNextPCMWaveLogSamples: the position step, 8 fractional bits."""
    step = tables.interpolate_exp((~pitch) & 4095) << (pitch >> 12)
    return step >> 9


def gain_pan(tables: Tables, ampt: int, pan: int) -> int:
    """The perceptual kernel's one factor: unlog(ampt) in Q13 times the pan factor, Q13."""
    return (tables.unlog(ampt) * pan) >> 13


def config_longs(tables: Tables, run: PCMRun) -> list[int]:
    c = run.config
    if run.kernel == "exact" and c.pan_left + c.pan_right != 8192 * c.polarity:
        raise ValueError("exact PCM requires a complementary MT-32 pan pair of one polarity")
    # The mono kernel carries the gain alone where the perceptual one carries
    # gain times pan: a DSP that pans and mixes the stream takes the pan.
    if run.kernel == "mono":
        factors = [tables.unlog(c.ampt), 0]
    else:
        factors = [gain_pan(tables, c.ampt, c.pan_left), gain_pan(tables, c.ampt, c.pan_right)]
    return [
        c.wave, c.length, int(c.looped), pcm_step(tables, c.pitch), c.ampt,
        c.pan_left, c.pan_right, KERNELS.index(run.kernel),
    ] + factors


def dc_lines(directive: str, values: list[int], width: int) -> list[str]:
    lines = []
    for i in range(0, len(values), width):
        chunk = values[i:i + width]
        lines.append(f"        {directive}    " + ",".join(f"${v:0{4 if directive == 'dc.w' else 8}x}" for v in chunk))
    return lines


def emit_tables(tables: Tables) -> str:
    lines = [
        "; generated by tools/pcm_partial.py - do not edit",
        ";",
        "; The 68030 PCM partial spike's data: LA32Utilites::interpolateExp for",
        "; every fraction, the two waves as the words a host converts the PCM",
        "; ROM into (sign in bit 15, the half-log below), and one record of",
        f"; {CONFIG_LONGS} longs per run: wave, length, looped, step, amp term, pan",
        "; factors, kernel, and the perceptual kernel's gain-times-pan factors.",
        "",
        "pcm_unlog_image:",
    ]
    lines += dc_lines("dc.w", [tables.interpolate_exp(f) for f in range(4096)], 8)
    for index, (name, _length, _looped) in enumerate(WAVES):
        lines.append(f"pcm_wave_{name}_image:")
        words = wave_rom_words(index)
        # The second interpolation word is always addressable. Loop to the
        # first sample, or supply a ROM-format zero for a one-shot wave.
        words.append(words[0] if _looped else linear_to_rom(0))
        lines += dc_lines("dc.w", [rom_to_host(w) for w in words], 8)
    lines.append("pcm_cfg_image:")
    for run in RUNS:
        lines.append(f"        ; {run.name}")
        lines += dc_lines("dc.l", [v & 0xFFFFFFFF for v in config_longs(tables, run)], 5)
    return "\n".join(lines) + "\n"


def oracle_args(run: PCMRun) -> str:
    c = run.config
    return " ".join(str(v) for v in (
        "pcm", c.length, int(c.looped), c.amp, c.pitch, FRAMES, c.pan_left, c.pan_right,
    ))


def write_debugger_scripts(listing: Path, output_dir: Path, run_index: int) -> None:
    symbols = parse_listing(listing)
    command_ping = require_symbol(symbols, "P", "command_ping")
    last_command = require_symbol(symbols, "Y", "last_command")
    output_dir.mkdir(parents=True, exist_ok=True)
    arm = (output_dir / "arm.ini").resolve()
    end = (output_dir / "end.ini").resolve()
    profile = (output_dir / "profile.txt").resolve()
    (output_dir / "start.ini").write_text(
        f"db pc = ${command_ping:04x} && (${last_command:04x}).y = ${MARKER_BEGIN | run_index:06x} "
        f":once :trace :file {arm}\n"
    )
    arm.write_text(
        "profile on\n"
        f"db pc = ${command_ping:04x} && (${last_command:04x}).y = ${MARKER_END | run_index:06x} "
        f":once :trace :file {end}\n"
    )
    end.write_text(f"profile save {profile}\nprofile off\n")


def read_output(path: Path) -> tuple[dict, list[int], list[int]]:
    data = path.read_bytes()
    if len(data) < HEADER.size:
        raise SystemExit(f"error: {path} is too short to be the 68030's output")
    magic, frames, periods, ticks, run = HEADER.unpack_from(data)
    if magic != MAGIC:
        raise SystemExit(f"error: {path} does not start with {MAGIC!r}")
    expected = HEADER.size + 8 * frames
    if len(data) != expected:
        raise SystemExit(f"error: {path} holds {len(data)} bytes, expected {expected}")
    words = struct.unpack_from(f">{2 * frames}i", data, HEADER.size)
    header = {"frames": frames, "periods": periods, "ticks": ticks, "run": run}
    return header, list(words[0::2]), list(words[1::2])


def read_oracle(path: Path) -> list[tuple[int, int, int]]:
    rows = []
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) == 3:
            rows.append((int(parts[0]), int(parts[1]), int(parts[2])))
    return rows


def compare(output: Path, oracle: Path, run_index: int) -> int:
    run = RUNS[run_index]
    header, left, right = read_output(output)
    rows = read_oracle(oracle)
    if header["frames"] != FRAMES or len(rows) != FRAMES:
        raise SystemExit(
            f"error: {output} has {header['frames']} frames and {oracle} {len(rows)}, expected {FRAMES}"
        )
    if header["run"] != run_index:
        raise SystemExit(f"error: {output} was written by run {header['run']}, not {run_index}")
    ref_left = [l for _s, l, _r in rows]
    ref_right = [r for _s, _l, r in rows]
    print(f"{run.name}: {FRAMES} frames from the 68030 against the Munt integer model")
    if run.kernel == "exact":
        mismatches = [
            i for i in range(FRAMES) if left[i] != ref_left[i] or right[i] != ref_right[i]
        ]
        if mismatches:
            i = mismatches[0]
            print(
                f"  FAIL: {len(mismatches)} of {FRAMES} frames differ; first at frame {i}: "
                f"68030 {left[i]}/{right[i]} vs oracle {ref_left[i]}/{ref_right[i]} "
                f"(oracle sample {rows[i][0]})"
            )
            return 1
        print("  PASS: every left and right word equals the Munt integer model")
        return 0
    ok = True
    if run.kernel == "mono":
        # The mono kernel's word is the partial's sample before the pan.
        channels = (("mono", left, [s for s, _l, _r in rows]),)
    else:
        channels = (("left", left, ref_left), ("right", right, ref_right))
    for channel, got, ref in channels:
        lines, channel_ok = grade(got, ref)
        print(f"  {channel}:")
        print("\n".join(lines))
        ok = ok and channel_ok
    print("  PASS: within the perceptual bounds" if ok else "  FAIL: outside the perceptual bounds")
    return 0 if ok else 1


PROFILE_RE = re.compile(r"^\$?([0-9A-Fa-f]+) .*% \(([^)]*)\)$")


def parse_cpu_profile(path: Path) -> list[tuple[int, int, int, int, int]]:
    rows = []
    for line in path.read_text(errors="replace").splitlines():
        match = PROFILE_RE.match(line)
        if not match:
            continue
        fields = [int(v.strip()) for v in match.group(2).split(",")]
        if len(fields) < 2:
            continue
        while len(fields) < 4:
            fields.append(0)
        rows.append((int(match.group(1), 16), fields[0], fields[1], fields[2], fields[3]))
    if not rows:
        raise SystemExit(f"error: {path} holds no CPU profile rows")
    return rows


def report(profile: Path, output: Path, report_path: Path | None, run_index: int) -> None:
    run = RUNS[run_index]
    header, _left, _right = read_output(output)
    rows = parse_cpu_profile(profile)
    frames = header["periods"] * FRAMES_PER_PERIOD
    ram = [r for r in rows if r[0] < ROM_TOS]
    rom = [r for r in rows if r[0] >= ROM_TOS]
    ram_cycles = sum(r[2] for r in ram)
    rom_cycles = sum(r[2] for r in rom)
    ram_instructions = sum(r[1] for r in ram)
    i_misses = sum(r[3] for r in ram)
    d_hits = sum(r[4] for r in ram)
    per_frame = ram_cycles / frames
    per_period = per_frame * FRAMES_PER_PERIOD
    ms_per_period = per_period * 1000.0 / CPU_HZ
    tick_ms = header["ticks"] * HZ200_MS
    tick_ms_per_period = tick_ms / header["periods"] if header["periods"] else 0.0
    host_left = PERIOD_MS - TRANSPORT_MS
    lines = [
        f"68030 PCM partial profile: run {run_index} ({run.name})",
        f"  timed frames:                {frames:,} ({header['periods']} periods)",
        f"  68030 clock:                 {CPU_HZ:,.0f} Hz",
        f"  program cycles in window:    {ram_cycles:,}",
        f"  program instructions:        {ram_instructions:,}",
        f"  ROM cycles in window:        {rom_cycles:,} (the two marker exchanges)",
        f"  i-cache misses / d-cache hits: {i_misses:,} / {d_hits:,}",
        "",
        f"  cycles per codec frame:      {per_frame:8.2f}",
        f"  instructions per frame:      {ram_instructions / frames:8.2f}",
        f"  cycles per 512-frame period: {per_period:,.0f}",
        f"  time per period:             {ms_per_period:6.2f} ms of {PERIOD_MS:.2f} "
        f"({100.0 * ms_per_period / PERIOD_MS:.1f}% of the period)",
        f"  after the DSP transport:     {100.0 * ms_per_period / host_left:.1f}% of the "
        f"{host_left:.2f} ms left",
        f"  partials per period:         {host_left / ms_per_period:.2f}",
        "",
        f"  200 Hz ticks over the timed render: {header['ticks']} = {tick_ms:.0f} ms, "
        f"{tick_ms_per_period:.2f} ms per period (5 ms resolution)",
    ]
    text = "\n".join(lines) + "\n"
    print(text, end="")
    if report_path:
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(text)


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("tables", help="emit the host's assembler include")
    p.add_argument("--tables", type=Path, required=True, help="oracle --dump-tables output")
    for name, doc in (
        ("wave", "print the run's wave as the ROM words the oracle reads"),
        ("oracle-args", "print the oracle command line for a run"),
        ("name", "print the run's name"),
        ("kernel", "print exact or perceptual"),
        ("cfg", "print the PROFILE.CFG text that selects the run"),
    ):
        p = sub.add_parser(name, help=doc)
        p.add_argument("run", type=int)
    p = sub.add_parser("prepare", help="write the Hatari debugger scripts")
    p.add_argument("--listing", type=Path, required=True)
    p.add_argument("--output-dir", type=Path, required=True)
    p.add_argument("run", type=int)
    p = sub.add_parser("compare", help="check the 68030's output against the oracle")
    p.add_argument("--output", type=Path, required=True, help="PCMOUT.BIN from the run")
    p.add_argument("--oracle", type=Path, required=True)
    p.add_argument("run", type=int)
    p = sub.add_parser("report", help="summarize the CPU profile and the tick count")
    p.add_argument("--profile", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True, help="PCMOUT.BIN from the run")
    p.add_argument("--report", type=Path)
    p.add_argument("run", type=int)
    sub.add_parser("count")
    args = parser.parse_args()

    if args.command == "count":
        print(len(RUNS))
    elif args.command == "tables":
        sys.stdout.write(emit_tables(Tables(args.tables)))
    elif args.command == "wave":
        for word in wave_rom_words(RUNS[args.run].config.wave):
            print(word - 65536 if word & 0x8000 else word)
    elif args.command == "oracle-args":
        print(oracle_args(RUNS[args.run]))
    elif args.command == "name":
        print(RUNS[args.run].name)
    elif args.command == "kernel":
        print(RUNS[args.run].kernel)
    elif args.command == "cfg":
        print(f"P{args.run:02d}")
    elif args.command == "prepare":
        write_debugger_scripts(args.listing, args.output_dir, args.run)
    elif args.command == "compare":
        sys.exit(compare(args.output, args.oracle, args.run))
    elif args.command == "report":
        report(args.profile, args.output, args.report, args.run)


if __name__ == "__main__":
    main()

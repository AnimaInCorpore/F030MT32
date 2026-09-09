#!/usr/bin/env python3
"""LA32 synth-partial profile spike: configurations, DSP tables, comparison.

One source of truth for the feasibility measurement in docs/la32-budget.md:

- ``tables``        emits the DSP56001 P-memory image of every lookup table
                    the kernel needs plus the per-configuration block
                    constants, derived from the exp9/logsin9 tables the Munt
                    oracle dumps;
- ``oracle-args N`` prints the oracle command line for configuration N;
- ``constants N``   prints the derived block constants for inspection;
- ``compare``       checks a Hatari ``dm x`` dump of the DSP output buffer
                    against the oracle's frames, word for word, and prints
                    the buffer checksum the DSP replies with.

The arithmetic mirrors Munt's LA32WaveGenerator.cpp with amp, pitch and
cutoff held constant. Every derived value is documented next to the C++
it comes from, so a disagreement is a diff rather than an opinion.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

SINE_SEGMENT_RELATIVE_LENGTH = 1 << 18
MIDDLE_CUTOFF_VALUE = 128 << 18
RESONANCE_DECAY_THRESHOLD_CUTOFF_VALUE = 144 << 18
MAX_CUTOFF_VALUE = 240 << 18
WORD_MASK = 0xFFFFFF

PROFILE_FRAMES = 2048
OUTPUT_BASE = 0x1000
OUTPUT_WORDS = 2 * PROFILE_FRAMES

# DSP memory homes of the tables and their P-memory image addresses. Falcon
# external P aliases the 32K SRAM directly, external Y the same lower 16K
# word for word, and external X the upper 16K at phys = addr + $4000; so a
# P section at $3000 lands in Y:$3000 and one at $6000 lands in X:$2000,
# and the stage-two loader delivers X/Y tables it was never taught about.
SQUARE_VALUE_X = 0x3000        # X:$3000-$35FF  <- P:$7000
SQUARE_WINDOW_Y = 0x3000       # Y:$3000-$35FF  <- P:$3000
SHIFT_Y = 0x3600               # Y:$3600-$3A3F  <- P:$3600
RESONANCE_Y = 0x3C00           # Y:$3C00-$3FFF  <- P:$3C00
UNLOG_X = 0x0000               # X:$0000-$0FFF  <- P:$4000 (first page copied at boot)
X_ALIAS = 0x4000
CONST_IMAGE_P = 0x0700
CONFIG_IMAGE_P = 0x0740
CONFIG_WORDS = 16

# The shift table maps an unlog integer part n to 2^(15-n): a zero guard for
# n = -1, sixteen powers, then zeros up to the largest n any configuration
# can produce, so an out-of-range log unlogs to zero without a clamp - which
# is what Munt's clamp to 65535 amounts to. Its base entry is the one for
# n = 0, so la_shtab points one past the guard word.
SHIFT_GUARD = 1
SHIFT_ENTRIES = 1088

# Fixed internal-Y constants, in the order src/dsp/la32.asm lays them out
# from la_wphmask upwards; the kernel copies this image at boot.
FIXED_CONSTANTS = [
    ("la_wphmask", 0x7FF800),
    ("la_sh5", 1 << 18),
    ("la_m511", 511),
    ("la_m7fe0", 0x7FE0),
    ("la_sh12", 1 << 11),
    ("la_m4095", 4095),
    ("la_2p14", 1 << 14),
    ("la_pos21", 1 << 21),
    ("la_2p22", 1 << 22),
    ("la_mcos", 0x3FF800),
    ("la_rec1", 0x2F),
    ("la_sh7", 1 << 7),
    ("la_sgnbit", 0x800000),
    ("la_shtab", SHIFT_Y + SHIFT_GUARD),
    ("la_rtab", RESONANCE_Y),
]

# TVP.cpp keyToPitchTable: keys below 60 use -table[60 - key].
KEY_TO_PITCH = [
    0, 341, 683, 1024, 1365, 1707, 2048, 2389,
    2731, 3072, 3413, 3755, 4096, 4437, 4779, 5120,
    5461, 5803, 6144, 6485, 6827, 7168, 7509, 7851,
    8192, 8533, 8875, 9216, 9557, 9899, 10240, 10581,
    10923, 11264, 11605, 11947, 12288, 12629, 12971, 13312,
    13653, 13995, 14336, 14677, 15019, 15360, 15701, 16043,
    16384, 16725, 17067, 17408, 17749, 18091, 18432, 18773,
    19115, 19456, 19797, 20139, 20480, 20821, 21163, 21504,
    21845, 22187, 22528, 22869,
]


def key_pitch(key: int, sawtooth: bool) -> int:
    """TVP::calcBasePitch for a plain key: no keyfollow tweaks, no bend."""
    delta = KEY_TO_PITCH[abs(key - 60)]
    base = -delta if key < 60 else delta
    return base + (33037 if sawtooth else 37133)


def amp_for_level(level: int) -> int:
    """Partial::getAmpValue: 67117056 - ampRamp, ramp target << 18."""
    return 67117056 - (level << 18)


def pan_factor(setting: int) -> int:
    """Partial.cpp getPanFactor: PAN_FACTORS[i] = int(0.5 + i * 8192 / 14)."""
    return int(0.5 + setting * 8192.0 / 14.0) if setting else 0


@dataclass(frozen=True)
class Config:
    name: str
    sawtooth: bool
    pulse_width: int      # processed 0..255 value handed to initSynth
    resonance: int        # 1..31 as handed to initSynth
    amp: int
    pitch: int
    cutoff: int           # cutoffVal before the 240<<18 clamp
    pan: int              # PatchTemp panpot 0..14 (left factor index)

    @property
    def pan_left(self) -> int:
        return pan_factor(self.pan)

    @property
    def pan_right(self) -> int:
        return pan_factor(14 - self.pan)


CONFIGS = [
    # Cutoff below the middle point: no linear segments, the "sine" square.
    Config("square-lowcut", False, 128, 1, amp_for_level(155), key_pitch(60, False), 100 << 18, 6),
    # Asymmetric pulse, strong resonance, cutoff well above the middle.
    Config("square-pw-res", False, 200, 20, amp_for_level(200), key_pitch(67, False), 220 << 18, 6),
    # Sawtooth at the cutoff ceiling with maximum resonance, two octaves up.
    Config("saw-maxres", True, 128, 31, amp_for_level(180), key_pitch(84, True), 240 << 18, 6),
    # Sawtooth inside the sinusoidal resonance-decay band, one octave down.
    Config("saw-sinedecay", True, 90, 8, amp_for_level(120), key_pitch(48, True), 136 << 18, 6),
]


class Tables:
    def __init__(self, path: Path) -> None:
        rows: dict[str, list[int]] = {}
        for line in path.read_text().splitlines():
            parts = line.split()
            if parts:
                rows[parts[0]] = [int(value) for value in parts[1:]]
        self.exp9 = rows["exp9"]
        self.logsin9 = rows["logsin9"]
        self.decay = rows["resAmpDecayFactors"]
        if len(self.exp9) != 512 or len(self.logsin9) != 512 or len(self.decay) != 8:
            raise SystemExit(f"error: {path} is not a complete oracle table dump")

    def interpolate_exp(self, fract: int) -> int:
        """LA32Utilites::interpolateExp."""
        index = fract >> 3
        extra = (~fract) & 7
        entry2 = 8191 - self.exp9[index]
        entry1 = 8191 if index == 0 else 8191 - self.exp9[index - 1]
        return entry2 + (((entry1 - entry2) * extra) >> 3)


@dataclass
class Derived:
    step: int
    rwlf: int
    high_linear: int
    low_linear: int
    ampt: int
    rbase: int
    radf: int


def derive(tables: Tables, config: Config) -> Derived:
    cutoff = min(config.cutoff, MAX_CUTOFF_VALUE)
    pitch = config.pitch
    # getSampleStep
    step = tables.interpolate_exp(~pitch & 4095)
    step <<= pitch >> 12
    step >>= 8
    step &= ~1
    # advancePosition: effectiveCutoffValue, resonanceWaveLengthFactor
    ecv = (cutoff - MIDDLE_CUTOFF_VALUE) >> 10 if cutoff > MIDDLE_CUTOFF_VALUE else 0
    rwlf = tables.interpolate_exp(~ecv & 4095) << (ecv >> 12)
    # getHighLinearLength
    epw = (config.pulse_width - 128) << 6 if config.pulse_width > 128 else 0
    high_linear = 0
    if epw < ecv:
        arg = ecv - epw
        high_linear = tables.interpolate_exp(~arg & 4095)
        high_linear <<= 7 + (arg >> 12)
        high_linear -= 2 * SINE_SEGMENT_RELATIVE_LENGTH
    low_linear = (rwlf << 8) - 4 * SINE_SEGMENT_RELATIVE_LENGTH - high_linear
    if high_linear % 16 or low_linear % 16 or low_linear < 0:
        raise SystemExit(f"error: {config.name}: segment lengths break the S4 = SQ>>4 model")
    # generateNextSquareWaveLogSample constants
    ampt = config.amp >> 10
    if cutoff < MIDDLE_CUTOFF_VALUE:
        ampt += (MIDDLE_CUTOFF_VALUE - cutoff) >> 9
    # generateNextResonanceWaveLogSample constants
    ras = (32 - config.resonance) << 10
    radf = tables.decay[config.resonance >> 2] << 2
    cut = 0
    if cutoff < MIDDLE_CUTOFF_VALUE:
        cut = 31743 + ((MIDDLE_CUTOFF_VALUE - cutoff) >> 9)
    elif cutoff < RESONANCE_DECAY_THRESHOLD_CUTOFF_VALUE:
        cut = tables.logsin9[(cutoff - MIDDLE_CUTOFF_VALUE) >> 13] << 2
    rbase = (config.amp >> 10) + ras + cut - 4096
    return Derived(step, rwlf, high_linear, low_linear, ampt, rbase, radf)


CONFIG_FIELDS = [
    "step3", "k7", "b3", "ampt", "rbase", "panl9", "panr9", "saw",
    "h0.resbase", "h0.linear", "h0.df15", "h0.sgn",
    "h1.resbase", "h1.linear", "h1.df15", "h1.sgn",
]


def max_log(tables: Tables, config: Config, d: Derived) -> int:
    """Upper bound of any log value the kernel can form for this configuration.

    The resonance log has no clamp on the DSP; its integer part must stay
    inside the zero-padded shift table. R4 never exceeds the longer half of
    the wave, the sine and window terms are bounded by the table maxima and
    the sawtooth cosine adds at most another sine value.
    """
    total = (d.rwlf << 4)
    b3 = (2 * SINE_SEGMENT_RELATIVE_LENGTH + d.high_linear) >> 4
    r4_max = max(b3, total - b3)
    sine_max = max(tables.logsin9) << 2
    log = sine_max + ((r4_max * (d.radf + 1)) >> 8) + d.rbase + (sine_max << 1)
    if config.sawtooth:
        log += sine_max
    return max(log, d.ampt + sine_max + (sine_max if config.sawtooth else 0))


def config_words(tables: Tables, config: Config) -> list[int]:
    d = derive(tables, config)
    if d.rbase < -4096:
        raise SystemExit(f"error: {config.name}: rbase {d.rbase} needs a deeper shift-table guard")
    if (max_log(tables, config, d) >> 12) + SHIFT_GUARD >= SHIFT_ENTRIES:
        raise SystemExit(f"error: {config.name}: a log integer part exceeds the shift table")
    words = [
        d.step << 3,                                              # la_step3
        (d.rwlf >> 4) << 7,                                       # la_k7
        (2 * SINE_SEGMENT_RELATIVE_LENGTH + d.high_linear) >> 4,  # la_b3
        d.ampt,                                                   # la_ampt
        d.rbase & WORD_MASK,                                      # la_rbase
        config.pan_left << 9,                                     # la_panl9
        config.pan_right << 9,                                    # la_panr9
        1 if config.sawtooth else 0,                              # la_saw
        # half 0: sign base, linear length (S4 units), decay << 15, square sign
        0x400000,
        d.high_linear >> 4,
        d.radf << 15,
        0x400000,
        # half 1
        0xC00000,
        d.low_linear >> 4,
        (d.radf + 1) << 15,
        0xC00000,
    ]
    assert len(words) == CONFIG_WORDS
    for word in words:
        if not 0 <= word <= WORD_MASK:
            raise SystemExit(f"error: {config.name}: constant {word:#x} exceeds 24 bits")
    return words


def dc_lines(words: list[int], width: int = 8) -> list[str]:
    lines = []
    for offset in range(0, len(words), width):
        chunk = words[offset:offset + width]
        lines.append("        dc      " + ",".join(f"${word & WORD_MASK:06x}" for word in chunk))
    return lines


def emit_tables(tables: Tables) -> str:
    ls = tables.logsin9
    forward = [v << 2 for v in ls]
    zero = [0] * 512
    reverse_value = [ls[511 - i] << 2 for i in range(512)]
    reverse_window = [ls[511 - i] << 3 for i in range(512)]
    resonance = [ls[i] << 2 for i in range(512)] + [ls[1023 - i] << 2 for i in range(512, 1024)]
    unlog = [tables.interpolate_exp(fract) << 8 for fract in range(4096)]
    shift = [0] * SHIFT_GUARD + [1 << (15 - n) for n in range(16)]
    shift += [0] * (SHIFT_ENTRIES - len(shift))

    lines = [
        "; Generated by tools/la32_partial.py; do not edit.",
        "; Every section is P-memory data delivered by the stage-two loader; the",
        "; large ones sit at the P alias of their X/Y home (see the tool's notes).",
        "",
        f"        org     p:${CONST_IMAGE_P:04x}",
        "la32_const_image:",
        *dc_lines([value for _name, value in FIXED_CONSTANTS]),
        "",
        f"        org     p:${CONFIG_IMAGE_P:04x}",
        "la32_cfg_image:",
    ]
    for config in CONFIGS:
        lines.append(f"; {config.name}")
        lines.extend(dc_lines(config_words(tables, config)))
    lines += [
        "",
        f"        org     p:${SQUARE_WINDOW_Y:04x}      ; Y:${SQUARE_WINDOW_Y:04x} window part: FWD, ZERO, REV",
        "la32_square_window_image:",
        *dc_lines(forward + zero + reverse_window),
        "",
        f"        org     p:${SHIFT_Y:04x}      ; Y:${SHIFT_Y:04x} guard, 2^(15-n), zeros",
        "la32_shift_image:",
        *dc_lines(shift),
        "",
        f"        org     p:${RESONANCE_Y:04x}      ; Y:${RESONANCE_Y:04x} resonance/cosine, reversed upper half",
        "la32_resonance_image:",
        *dc_lines(resonance),
        "",
        f"        org     p:${UNLOG_X + X_ALIAS:04x}      ; X:${UNLOG_X:04x} interpolateExp(frac) << 8",
        "la32_unlog_image:",
        *dc_lines(unlog),
        "",
        f"        org     p:${SQUARE_VALUE_X + X_ALIAS:04x}      ; X:${SQUARE_VALUE_X:04x} value part: FWD, ZERO, REV",
        "la32_square_value_image:",
        *dc_lines(forward + zero + reverse_value),
        "",
    ]
    return "\n".join(lines) + "\n"


def oracle_args(config: Config) -> str:
    return " ".join(str(v) for v in (
        "render", int(config.sawtooth), config.pulse_width, config.resonance,
        config.amp, config.pitch, config.cutoff, PROFILE_FRAMES,
        config.pan_left, config.pan_right,
    ))


def checksum(words: list[int]) -> int:
    """The DSP folds its output buffer as h = (2h + word) mod 2^24."""
    h = 0
    for word in words:
        h = ((h << 1) + (word & WORD_MASK)) & WORD_MASK
    return h


def to_word(value: int) -> int:
    return value & WORD_MASK


def from_word(word: int) -> int:
    return word - (1 << 24) if word & 0x800000 else word


DUMP_RE = re.compile(r"^X:([0-9a-fA-F]+) \(P:[0-9a-fA-F]+\): ([0-9a-fA-F]{6})")


def parse_dump(path: Path) -> dict[int, int]:
    words: dict[int, int] = {}
    for line in path.read_text(errors="replace").splitlines():
        match = DUMP_RE.match(line)
        if match:
            words[int(match.group(1), 16)] = int(match.group(2), 16)
    return words


def read_oracle(path: Path) -> list[tuple[int, int, int]]:
    rows = []
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) == 3:
            rows.append((int(parts[0]), int(parts[1]), int(parts[2])))
    return rows


def expected_words(rows: list[tuple[int, int, int]]) -> list[int]:
    words = []
    for _sample, left, right in rows:
        words.append(to_word(left))
        words.append(to_word(right))
    return words


def compare(dump: Path, oracle: Path, config: Config) -> int:
    words = parse_dump(dump)
    rows = read_oracle(oracle)
    if len(rows) != PROFILE_FRAMES:
        raise SystemExit(f"error: {oracle} has {len(rows)} frames, expected {PROFILE_FRAMES}")
    missing = [a for a in range(OUTPUT_BASE, OUTPUT_BASE + OUTPUT_WORDS) if a not in words]
    if missing:
        raise SystemExit(
            f"error: {dump} lacks {len(missing)} words of X:${OUTPUT_BASE:04x}.. "
            f"(first ${missing[0]:04x}); did the end breakpoint dump the buffer?"
        )
    buffer = [words[OUTPUT_BASE + i] for i in range(OUTPUT_WORDS)]
    expected = expected_words(rows)
    mismatches = [i for i in range(OUTPUT_WORDS) if buffer[i] != expected[i]]
    print(
        f"{config.name}: {PROFILE_FRAMES} frames, DSP checksum ${checksum(buffer):06x}, "
        f"oracle checksum ${checksum(expected):06x}"
    )
    if mismatches:
        i = mismatches[0]
        frame, channel = divmod(i, 2)
        print(
            f"  FAIL: {len(mismatches)} of {OUTPUT_WORDS} words differ; first at frame {frame} "
            f"{'LR'[channel]}: DSP {from_word(buffer[i])} vs oracle {from_word(expected[i])} "
            f"(oracle sample {rows[frame][0]})"
        )
        return 1
    print("  PASS: every left and right word equals the Munt integer model")
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("tables")
    p.add_argument("--tables", type=Path, required=True, help="oracle --dump-tables output")
    p = sub.add_parser("oracle-args")
    p.add_argument("config", type=int)
    p = sub.add_parser("loop", help="print square or saw: the DSP loop this configuration runs")
    p.add_argument("config", type=int)
    p = sub.add_parser("name")
    p.add_argument("config", type=int)
    p = sub.add_parser("constants")
    p.add_argument("--tables", type=Path, required=True)
    p.add_argument("config", type=int)
    p = sub.add_parser("expected-checksum")
    p.add_argument("--oracle", type=Path, required=True)
    p = sub.add_parser("compare")
    p.add_argument("--dump", type=Path, required=True, help="Hatari debug log holding the dm x dump")
    p.add_argument("--oracle", type=Path, required=True)
    p.add_argument("config", type=int)
    sub.add_parser("count")
    args = parser.parse_args()

    if args.command == "count":
        print(len(CONFIGS))
        return
    if args.command == "tables":
        sys.stdout.write(emit_tables(Tables(args.tables)))
        return
    if args.command == "expected-checksum":
        print(f"{checksum(expected_words(read_oracle(args.oracle))):06x}")
        return
    config = CONFIGS[args.config]
    if args.command == "oracle-args":
        print(oracle_args(config))
    elif args.command == "loop":
        print("saw" if config.sawtooth else "square")
    elif args.command == "name":
        print(config.name)
    elif args.command == "constants":
        tables = Tables(args.tables)
        print(config)
        print(derive(tables, config))
        for name, word in zip(CONFIG_FIELDS, config_words(tables, config)):
            print(f"  {name:12s} ${word:06x} {from_word(word)}")
    elif args.command == "compare":
        sys.exit(compare(args.dump, args.oracle, config))


if __name__ == "__main__":
    main()

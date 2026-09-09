#!/usr/bin/env python3
"""LA32 synth-partial profile spike: configurations, DSP tables, comparison.

One source of truth for the feasibility measurement in docs/la32-budget.md:

- ``tables``        emits the DSP56001 P-memory image of every lookup table
                    the two kernels need plus the per-run block constants,
                    derived from the exp9/logsin9 tables the Munt oracle dumps;
- ``oracle-args N`` prints the oracle command line for run N;
- ``constants N``   prints the derived block constants for inspection;
- ``compare``       checks a Hatari ``dm x`` dump of the DSP output buffer
                    against the oracle's frames: word for word for the exact
                    kernel, against error bounds for the perceptual one.

A run is a configuration (wave, pulse width, resonance, amp, pitch, cutoff)
rendered by one of two kernels: ``exact`` reproduces Munt's integer
LA32WaveGenerator bit for bit; ``perceptual`` keeps its positions and log
sums but leaves the log domain through single-table lookups. The arithmetic
mirrors Munt's LA32WaveGenerator.cpp with amp, pitch and cutoff held
constant, and every derived value is documented next to the C++ it comes
from, so a disagreement is a diff rather than an opinion.
"""

from __future__ import annotations

import argparse
import cmath
import math
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
# P section at $2000 lands in Y:$2000 and one at $6000 lands in X:$2000,
# and the stage-two loader delivers X/Y tables it was never taught about.
X_ALIAS = 0x4000
UNLOG_X = 0x0000          # exact: interpolateExp(frac)<<8, 4096; first page copied at boot
SQUARE_EXACT = 0x2000     # exact: X sine<<2 (log), Y window; FWD, ZERO, REV
SQUARE_PERC = 0x2600      # perceptual: X linear sine*4, Y window copy
COSINE_X = 0x2C00         # perceptual: +/-cosine*1024, 2048, sign in bit 10
SHIFT_X = 0x3400          # exact: guard, 2^(15-n), zeros
GAIN_Y = 0x0900           # perceptual: 2^(-(16j+8)/4096)*2^21 for j = -guard..4095
GAIN_GUARD = 192
RESONANCE_Y = 0x1A00      # exact: sine<<2 (log), reversed upper half, 1024
SINE_Y = 0x2C00           # perceptual: +/-linear sine*4, 2048, twice
CONST_IMAGE_P = 0x0700
CONFIG_IMAGE_P = 0x0740
CONFIG_WORDS = 18

# The exact kernel's shift table maps an unlog integer part n to 2^(15-n):
# a zero guard for n = -1, sixteen powers, then zeros up to the largest n any
# configuration can produce, so an out-of-range log unlogs to zero without a
# clamp - which is what Munt's clamp to 65535 amounts to. Its base entry is
# the one for n = 0, so la_shtab points one past the guard word.
SHIFT_GUARD = 1
SHIFT_ENTRIES = 1088

# Internal Y layout, mirrored by src/dsp/la32.asm: la_wp3 at $10, these
# fixed words from $11, three scratch words, then the CONFIG_WORDS block.
LA_REC1 = 0x37
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
    ("la_rec1", LA_REC1),
    ("la_sh7", 1 << 7),
    ("la_sgnbit", 0x800000),
    ("la_shtab", SHIFT_X + SHIFT_GUARD),
    ("la_rtab", RESONANCE_Y),
    ("la_mffe0", 0xFFE0),
    ("la_sh4", 1 << 19),
    ("la_m65535", 65535),
    ("la_gtab", GAIN_Y + GAIN_GUARD),
    ("la_ctab", COSINE_X),
    ("la_mcos11", 0x7FF000),
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


# The amp levels are TVA ramp targets near the loud end of the range: the
# LA32 attenuates by an octave per 4096 log units, so a cutoff eight points
# below the middle already costs 6 dB and a target of 155 would leave the
# first configuration at a few LSB, where nothing but rounding is measurable.
CONFIGS = [
    # Cutoff below the middle point: no linear segments, the "sine" square.
    Config("square-lowcut", False, 128, 1, amp_for_level(240), key_pitch(60, False), 120 << 18, 6),
    # Asymmetric pulse, strong resonance, cutoff well above the middle.
    Config("square-pw-res", False, 200, 20, amp_for_level(200), key_pitch(67, False), 220 << 18, 6),
    # Sawtooth at the cutoff ceiling with maximum resonance, two octaves up.
    Config("saw-maxres", True, 128, 31, amp_for_level(230), key_pitch(84, True), 240 << 18, 6),
    # Sawtooth inside the sinusoidal resonance-decay band, one octave down.
    Config("saw-sinedecay", True, 90, 8, amp_for_level(235), key_pitch(48, True), 136 << 18, 6),
]

KERNELS = ["exact", "perceptual"]


@dataclass(frozen=True)
class Run:
    config: Config
    kernel: str

    @property
    def name(self) -> str:
        return f"{self.config.name}/{self.kernel}"

    @property
    def loop(self) -> str:
        wave = "saw" if self.config.sawtooth else "square"
        return wave if self.kernel == "exact" else "p" + wave

    image = "partial"


# Boss reverb, the MT-32 model's room mode: BReverbModel.cpp getMT32Settings,
# REVERB_MODE_0. Three allpasses, an entrance delay with a low-pass filter
# and three combs; the output taps read the combs at fixed distances behind
# the write position. Time selects the combs' feedback, level the wet amp.
REVERB_ALLPASSES = [994, 729, 78]
REVERB_COMBS = [575 + 1, 2040, 2752, 3629]        # + PROCESS_DELAY on the entrance
REVERB_OUT_L = [2040, 687, 1814]
REVERB_OUT_R = [1019, 2072, 1]
REVERB_COMB_FACTORS = [0xB0, 0x60, 0x60, 0x60]
REVERB_FEEDBACK = (
    [0x00] * 8
    + [0x28, 0x48, 0x60, 0x70, 0x78, 0x80, 0x90, 0x98]
    + [0x28, 0x48, 0x60, 0x78, 0x80, 0x88, 0x90, 0x98]
    + [0x28, 0x48, 0x60, 0x78, 0x80, 0x88, 0x90, 0x98]
)
REVERB_DRY_AMP = [0x80] * 8
REVERB_WET_AMP = [0x10, 0x20, 0x30, 0x40, 0x50, 0x70, 0xA0, 0xE0]
REVERB_LPF_AMP = 0x80

# Delay-line homes in Y for the reverb image. The DSP56001 wraps a modulo
# pointer only inside a block aligned to the power of two above the line's
# length, so the bases are chosen for that and the assembly mirrors them.
REVERB_LINES = {
    "entrance": (REVERB_COMBS[0], 0x0C00),
    "allpass0": (REVERB_ALLPASSES[0], 0x3800),
    "allpass1": (REVERB_ALLPASSES[1], 0x3C00),
    "allpass2": (REVERB_ALLPASSES[2], 0x0F00),
    "comb1": (REVERB_COMBS[1], 0x3000),
    "comb2": (REVERB_COMBS[2], 0x2000),
    "comb3": (REVERB_COMBS[3], 0x1000),
}
REVERB_INPUT_IMAGE_P = OUTPUT_BASE + X_ALIAS


@dataclass(frozen=True)
class ReverbRun:
    time: int
    level: int
    input_run: int        # index of the partial run whose oracle output is the input

    kernel = "reverb"
    loop = "reverb"
    image = "reverb"

    @property
    def name(self) -> str:
        return f"reverb-room-t{self.time}-l{self.level}"


# Runs 0-7 render the partial with the exact and perceptual kernels; runs 8
# and 9 feed run 1's frames through the reverb at the MT-32's power-on
# setting and at the longest, loudest one.
RUNS: list = [Run(config, kernel) for kernel in KERNELS for config in CONFIGS]
RUNS += [ReverbRun(5, 3, 1), ReverbRun(7, 7, 1)]


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

    def unlog(self, value: int) -> int:
        """LA32Utilites::unlog magnitude for a clamped 16-bit log value."""
        value = min(max(value, 0), 65535)
        return self.interpolate_exp(value & 4095) >> (value >> 12)


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
    "step3", "k7", "b3", "ampt", "rbase", "panl", "panr", "saw", "kernel", "sqbase",
    "h0.f0", "h0.f1", "h0.df15", "h0.f3",
    "h1.f0", "h1.f1", "h1.df15", "h1.f3",
]


def max_log(tables: Tables, config: Config, d: Derived) -> int:
    """Upper bound of any log value the exact kernel can form.

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


def square_gain(ampt: int) -> int:
    """Perceptual square amplitude: 2^(-AMPT/4096) as a Q21 fraction."""
    return int(round(2.0 ** (-ampt / 4096.0) * (1 << 21)))


def reverb_words(run: ReverbRun) -> list[int]:
    """The reverb image's per-run constants, in the order src/dsp/la32.asm
    lays its rv_* block out; word 8 doubles as the kernel selector."""
    feedback = [REVERB_FEEDBACK[(comb << 3) + run.time] for comb in (1, 2, 3)]
    dry, wet = REVERB_DRY_AMP[run.level], REVERB_WET_AMP[run.level]
    if run.time == 0 and run.level == 0:
        dry = wet = 0
    words = [
        run.input_run,
        feedback[0] << 15, feedback[1] << 15, feedback[2] << 15,
        dry << 15, wet << 15,
        REVERB_COMB_FACTORS[0] << 15,          # entrance low-pass factor
        REVERB_LPF_AMP << 15,                  # entrance output amp
        2,                                     # kernel: reverb
        REVERB_COMB_FACTORS[1] << 15,          # comb filter factor
        (-REVERB_OUT_L[1]) & WORD_MASK,        # comb 2 left tap offset
        (-REVERB_OUT_R[1]) & WORD_MASK,        # comb 2 right tap offset
        32767, (-32768) & WORD_MASK,           # clipSampleEx bounds
        1 << 21, 1 << 22,                      # quarter and half
        0, 0,
    ]
    assert len(words) == CONFIG_WORDS
    return words


def config_words(tables: Tables, run) -> list[int]:
    if isinstance(run, ReverbRun):
        return reverb_words(run)
    config = run.config
    d = derive(tables, config)
    if d.rbase < -4096:
        raise SystemExit(f"error: {config.name}: rbase {d.rbase} needs a deeper guard zone")
    if (max_log(tables, config, d) >> 12) + SHIFT_GUARD >= SHIFT_ENTRIES:
        raise SystemExit(f"error: {config.name}: a log integer part exceeds the shift table")
    if -d.rbase >= GAIN_GUARD * 16:
        raise SystemExit(f"error: {config.name}: rbase {d.rbase} exceeds the gain table guard")
    common = [
        d.step << 3,                                              # la_step3
        (d.rwlf >> 4) << 7,                                       # la_k7
        (2 * SINE_SEGMENT_RELATIVE_LENGTH + d.high_linear) >> 4,  # la_b3
        d.ampt,                                                   # la_ampt
        d.rbase & WORD_MASK,                                      # la_rbase
    ]
    if run.kernel == "exact":
        words = common + [
            config.pan_left << 9,                                 # la_panl
            config.pan_right << 9,                                # la_panr
            1 if config.sawtooth else 0,                          # la_saw
            0,                                                    # la_kernel
            SQUARE_EXACT,                                         # la_sqbase
            # half 0: sign base, linear length (S4 units), decay << 15, square sign
            0x400000, d.high_linear >> 4, d.radf << 15, 0x400000,
            # half 1
            0xC00000, d.low_linear >> 4, (d.radf + 1) << 15, 0xC00000,
        ]
    else:
        gain = square_gain(d.ampt)
        words = common + [
            min(config.pan_left, 8191) << 10,                     # la_panl
            min(config.pan_right, 8191) << 10,                    # la_panr
            1 if config.sawtooth else 0,                          # la_saw
            1,                                                    # la_kernel
            SQUARE_PERC,                                          # la_sqbase
            # half 0: linear length, sine table base, decay << 15, +/-square gain
            d.high_linear >> 4, SINE_Y, d.radf << 15, gain,
            # half 1: the sine table copy 1024 words up flips the sign bit
            d.low_linear >> 4, SINE_Y + 1024, (d.radf + 1) << 15, (-gain) & WORD_MASK,
        ]
    assert len(words) == CONFIG_WORDS
    for word in words:
        if not 0 <= word <= WORD_MASK:
            raise SystemExit(f"error: {run.name}: constant {word:#x} exceeds 24 bits")
    return words


def dc_lines(words: list[int], width: int = 8) -> list[str]:
    lines = []
    for offset in range(0, len(words), width):
        chunk = words[offset:offset + width]
        lines.append("        dc      " + ",".join(f"${word & WORD_MASK:06x}" for word in chunk))
    return lines


def section(address: int, label: str, comment: str, words: list[int]) -> list[str]:
    return ["", f"        org     p:${address:04x}      ; {comment}", f"{label}:", *dc_lines(words)]


def emit_tables(tables: Tables) -> str:
    ls = tables.logsin9
    # exact kernel
    forward = [v << 2 for v in ls]
    zero = [0] * 512
    reverse_value = [ls[511 - i] << 2 for i in range(512)]
    reverse_window = [ls[511 - i] << 3 for i in range(512)]
    window = forward + zero + reverse_window
    resonance = [ls[i] << 2 for i in range(512)] + [ls[1023 - i] << 2 for i in range(512, 1024)]
    unlog = [tables.interpolate_exp(fract) << 8 for fract in range(4096)]
    shift = [0] * SHIFT_GUARD + [1 << (15 - n) for n in range(16)]
    shift += [0] * (SHIFT_ENTRIES - len(shift))
    # perceptual kernel: the same sine shapes, unlogged once and for all
    linear = [tables.unlog(v << 2) for v in ls]                 # 8189 at the peak
    full_scale = tables.unlog(0)
    linear_square = ([v * 4 for v in linear] + [full_scale * 4] * 512
                     + [linear[511 - i] * 4 for i in range(512)])
    signed_sine = []
    for i in range(2048):
        k = i & 1023
        value = linear[k] if k < 512 else linear[1023 - k]
        signed_sine.append((-value if i & 1024 else value) * 4)
    cosine = []
    for i in range(2048):
        k = i & 1023
        value = min(linear[k] if k < 512 else linear[1023 - k], 8191)
        cosine.append((-value if i & 1024 else value) * 1024)
    gain = [int(round(2.0 ** (-(16 * j + 8) / 4096.0) * (1 << 21)))
            for j in range(-GAIN_GUARD, 4096)]

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
    for run in RUNS:
        lines.append(f"; {run.name}")
        lines.extend(dc_lines(config_words(tables, run)))
    lines += section(GAIN_Y, "la32_gain_image",
                     f"Y:${GAIN_Y:04x} perceptual gain 2^(-(16j+8)/4096) * 2^21, {GAIN_GUARD} guard words first", gain)
    lines += section(RESONANCE_Y, "la32_resonance_image",
                     f"Y:${RESONANCE_Y:04x} exact resonance/cosine log sine, reversed upper half", resonance)
    lines += section(SQUARE_EXACT, "la32_square_window_image",
                     f"Y:${SQUARE_EXACT:04x} window part: FWD, ZERO, REV", window)
    lines += section(SQUARE_PERC, "la32_square_window_copy_image",
                     f"Y:${SQUARE_PERC:04x} the same window beside the linear values", window)
    lines += section(SINE_Y, "la32_sine_image",
                     f"Y:${SINE_Y:04x} perceptual signed linear sine * 4, sign in bit 10, twice", signed_sine + signed_sine)
    lines += section(UNLOG_X + X_ALIAS, "la32_unlog_image",
                     f"X:${UNLOG_X:04x} exact interpolateExp(frac) << 8", unlog)
    lines += section(SQUARE_EXACT + X_ALIAS, "la32_square_value_image",
                     f"X:${SQUARE_EXACT:04x} exact log value part: FWD, ZERO, REV", forward + zero + reverse_value)
    lines += section(SQUARE_PERC + X_ALIAS, "la32_square_linear_image",
                     f"X:${SQUARE_PERC:04x} perceptual linear value part * 4: FWD, ZERO, REV", linear_square)
    lines += section(COSINE_X + X_ALIAS, "la32_cosine_image",
                     f"X:${COSINE_X:04x} perceptual signed cosine * 1024, sign in bit 10", cosine)
    lines += section(SHIFT_X + X_ALIAS, "la32_shift_image",
                     f"X:${SHIFT_X:04x} exact guard, 2^(15-n), zeros", shift)
    lines.append("")
    return "\n".join(lines) + "\n"


def emit_reverb_tables(input_frames: Path) -> str:
    """The reverb image: every run's constants plus the input frames, placed
    at the P alias of X:$1000 so the loader lands them where the loop reads
    and overwrites them in place."""
    rows = read_oracle(input_frames)
    if len(rows) != PROFILE_FRAMES:
        raise SystemExit(f"error: {input_frames} has {len(rows)} frames, expected {PROFILE_FRAMES}")
    for name, (size, base) in REVERB_LINES.items():
        block = 1
        while block < size:
            block <<= 1
        if base % block:
            raise SystemExit(f"error: reverb line {name} at ${base:04x} is not {block}-aligned")
    lines = [
        "; Generated by tools/la32_partial.py; do not edit.",
        "; Reverb image data: run constants and the input frames at the P alias",
        "; of the in-place X buffer.",
        "",
        f"        org     p:${CONFIG_IMAGE_P:04x}",
        "la32_cfg_image:",
    ]
    for run in RUNS:
        lines.append(f"; {run.name}")
        lines.extend(dc_lines(reverb_words(run) if isinstance(run, ReverbRun) else [0] * CONFIG_WORDS))
    lines += section(REVERB_INPUT_IMAGE_P, "la32_reverb_input_image",
                     f"X:${OUTPUT_BASE:04x} input frames, left and right interleaved",
                     expected_words(rows))
    lines.append("")
    return "\n".join(lines) + "\n"


def oracle_args(run) -> str:
    if isinstance(run, ReverbRun):
        return f"reverb {run.time} {run.level}"
    config = run.config
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


def fft(values: list[float]) -> list[complex]:
    """Iterative radix-2 FFT; the frame count is a power of two."""
    n = len(values)
    data = [complex(v) for v in values]
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j |= bit
        if i < j:
            data[i], data[j] = data[j], data[i]
    length = 2
    while length <= n:
        step = cmath.exp(-2j * math.pi / length)
        for start in range(0, n, length):
            w = 1 + 0j
            for k in range(length // 2):
                u = data[start + k]
                v = data[start + k + length // 2] * w
                data[start + k] = u + v
                data[start + k + length // 2] = u - v
                w *= step
        length *= 2
    return data


# Perceptual acceptance bounds, in the 16-bit output domain of one partial
# (Munt's two components sum to at most 16382, the full scale below). The
# absolute bounds always apply; the shape bounds - error relative to the
# signal, correlation, spectral cosine - only once the signal is loud enough
# for them to measure the waveform rather than its rounding. The values sit
# at several times the deviation the kernel showed when they were
# introduced, so a regression is caught while table rounding is not; see
# docs/la32-budget.md.
FULL_SCALE = 16384.0
PERCEPTUAL_MAX_ABS = 64            # any single word
PERCEPTUAL_RMS_FULL_SCALE_DB = -72.0  # RMS error relative to full scale: about 4 words
PERCEPTUAL_SHAPE_MIN_RMS = 0.01 * FULL_SCALE
PERCEPTUAL_RMS_DB = -40.0          # RMS error relative to the RMS signal
PERCEPTUAL_CORRELATION = 0.9999
PERCEPTUAL_SPECTRAL_COSINE = 0.9999


def grade(dsp: list[int], ref: list[int]) -> tuple[list[str], bool]:
    n = len(ref)
    errors = [d - r for d, r in zip(dsp, ref)]
    max_abs = max(abs(e) for e in errors)
    signal_rms = math.sqrt(sum(r * r for r in ref) / n)
    error_rms = math.sqrt(sum(e * e for e in errors) / n)
    full_scale_db = 20 * math.log10(error_rms / FULL_SCALE) if error_rms > 0 else -999.0
    rms_db = 20 * math.log10(error_rms / signal_rms) if error_rms > 0 and signal_rms > 0 else -999.0
    mean_d = sum(dsp) / n
    mean_r = sum(ref) / n
    cov = sum((d - mean_d) * (r - mean_r) for d, r in zip(dsp, ref))
    var_d = sum((d - mean_d) ** 2 for d in dsp)
    var_r = sum((r - mean_r) ** 2 for r in ref)
    correlation = cov / math.sqrt(var_d * var_r) if var_d > 0 and var_r > 0 else 0.0
    spec_d = [abs(v) for v in fft([float(v) for v in dsp])][: n // 2]
    spec_r = [abs(v) for v in fft([float(v) for v in ref])][: n // 2]
    dot = sum(a * b for a, b in zip(spec_d, spec_r))
    norm = math.sqrt(sum(a * a for a in spec_d) * sum(b * b for b in spec_r))
    spectral = dot / norm if norm > 0 else 0.0
    shape = signal_rms >= PERCEPTUAL_SHAPE_MIN_RMS
    lines = [
        f"  signal rms         {signal_rms:8.1f} words"
        + ("" if shape else " (below the shape threshold: absolute bounds only)"),
        f"  max abs error      {max_abs:6d} words (bound {PERCEPTUAL_MAX_ABS})",
        f"  rms error          {full_scale_db:6.1f} dB of full scale (bound {PERCEPTUAL_RMS_FULL_SCALE_DB:.0f})",
        f"  rms error          {rms_db:6.1f} dB of the signal (bound {PERCEPTUAL_RMS_DB:.0f})",
        f"  correlation        {correlation:.6f} (bound {PERCEPTUAL_CORRELATION})",
        f"  spectral cosine    {spectral:.6f} (bound {PERCEPTUAL_SPECTRAL_COSINE})",
    ]
    ok = max_abs <= PERCEPTUAL_MAX_ABS and full_scale_db <= PERCEPTUAL_RMS_FULL_SCALE_DB
    if shape:
        ok = ok and (rms_db <= PERCEPTUAL_RMS_DB and correlation >= PERCEPTUAL_CORRELATION
                     and spectral >= PERCEPTUAL_SPECTRAL_COSINE)
    return lines, ok


def compare(dump: Path, oracle: Path, run) -> int:
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
    print(
        f"{run.name}: {PROFILE_FRAMES} frames, DSP checksum ${checksum(buffer):06x}, "
        f"oracle checksum ${checksum(expected):06x}"
    )
    if run.kernel != "perceptual":
        mismatches = [i for i in range(OUTPUT_WORDS) if buffer[i] != expected[i]]
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
    dsp_left = [from_word(buffer[i]) for i in range(0, OUTPUT_WORDS, 2)]
    dsp_right = [from_word(buffer[i]) for i in range(1, OUTPUT_WORDS, 2)]
    ref_left = [left for _s, left, _r in rows]
    ref_right = [right for _s, _l, right in rows]
    ok = True
    for channel, dsp, ref in (("left", dsp_left, ref_left), ("right", dsp_right, ref_right)):
        lines, channel_ok = grade(dsp, ref)
        print(f"  {channel}:")
        print("\n".join(lines))
        ok = ok and channel_ok
    print("  PASS: within the perceptual bounds" if ok else "  FAIL: outside the perceptual bounds")
    return 0 if ok else 1


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("tables")
    p.add_argument("--tables", type=Path, required=True, help="oracle --dump-tables output")
    p = sub.add_parser("reverb-tables", help="emit the reverb image's constants and input frames")
    p.add_argument("--input", type=Path, required=True, help="oracle frames of the input run")
    for name, doc in (
        ("oracle-args", "print the oracle command line for a run"),
        ("oracle-stdin", "print the file the oracle reads for a run, /dev/null for a partial"),
        ("loop", "print the DSP loop a run uses: square, saw, psquare, psaw or reverb"),
        ("kernel", "print exact, perceptual or reverb"),
        ("image", "print the DSP image a run needs: partial or reverb"),
        ("listing", "print the assembler listing the run's image comes from"),
        ("name", "print the run's name"),
    ):
        p = sub.add_parser(name, help=doc)
        p.add_argument("run", type=int)
    p = sub.add_parser("constants")
    p.add_argument("--tables", type=Path, required=True)
    p.add_argument("run", type=int)
    p = sub.add_parser("expected-checksum")
    p.add_argument("--oracle", type=Path, required=True)
    p = sub.add_parser("compare")
    p.add_argument("--dump", type=Path, required=True, help="Hatari debug log holding the dm x dump")
    p.add_argument("--oracle", type=Path, required=True)
    p.add_argument("run", type=int)
    sub.add_parser("count")
    args = parser.parse_args()

    if args.command == "count":
        print(len(RUNS))
        return
    if args.command == "tables":
        sys.stdout.write(emit_tables(Tables(args.tables)))
        return
    if args.command == "reverb-tables":
        sys.stdout.write(emit_reverb_tables(args.input))
        return
    if args.command == "expected-checksum":
        print(f"{checksum(expected_words(read_oracle(args.oracle))):06x}")
        return
    run = RUNS[args.run]
    if args.command == "oracle-args":
        print(oracle_args(run))
    elif args.command == "oracle-stdin":
        print(f"build/reference/la32-partial-{run.input_run}.txt" if isinstance(run, ReverbRun) else "/dev/null")
    elif args.command == "loop":
        print(run.loop)
    elif args.command == "kernel":
        print(run.kernel)
    elif args.command == "image":
        print(run.image)
    elif args.command == "listing":
        print("REVERB.LST" if run.image == "reverb" else "LA32.LST")
    elif args.command == "name":
        print(run.name)
    elif args.command == "constants":
        tables = Tables(args.tables)
        print(run)
        if not isinstance(run, ReverbRun):
            print(derive(tables, run.config))
        for name, word in zip(CONFIG_FIELDS, config_words(tables, run)):
            print(f"  {name:12s} ${word:06x} {from_word(word)}")
    elif args.command == "compare":
        sys.exit(compare(args.dump, args.oracle, run))


if __name__ == "__main__":
    main()

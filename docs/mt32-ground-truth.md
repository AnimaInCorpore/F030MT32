# MT-32 ground truth

Every fact on this page is either read out of the vendored Munt source under
`third_party/munt` — with the file that carries it named — or marked as
unverified. Recollection is not evidence; if a number here has no source
beside it, it has not been checked.

## What the machine is

The Roland MT-32 (1987) is an eight-part multitimbral module with a rhythm
part, built from:

- an Intel 8095 microcontroller running the control firmware;
- the Roland LA32 wave generator;
- a Boss BU3905 mixer providing per-part panning; and
- a Boss digital reverb.

"LA" is Linear Arithmetic: partials are either short PCM attack transients from
ROM or synthesized waves, and a timbre combines up to four of them.

The family shares the architecture: the CM-32L / CM-64 / LAPC-I add a second
512 KiB of PCM ROM carrying sound effects. Which model this port targets is an
open decision; the MT-32 is the smaller problem and the natural first target.

## ROMs

The port cannot ship these and neither can this repository. Supply your own
dump in `roms/`, which is ignored.

| Image | Size | Source |
| --- | --- | --- |
| MT-32 control v1.04–v1.07, BlueRidge | 65,536 bytes | `ROMInfo.cpp` |
| MT-32 control v2.03–v2.07 | 131,072 bytes | `ROMInfo.cpp` |
| MT-32 PCM | 524,288 bytes | `ROMInfo.cpp` |
| CM-32L / LAPC-I control v1.00, v1.02 | 65,536 bytes | `ROMInfo.cpp` |
| CM-32L / CM-64 / LAPC-I PCM | 1,048,576 bytes | `ROMInfo.cpp` |

Control ROMs also exist as 32,768-byte mux halves that Munt recombines; the
PCM ROM exists as two 262,144-byte halves.

The control ROM is not only firmware. It carries the data tables the control
half needs, and Munt indexes them through a per-version `ControlROMMap`
(`Synth.cpp`): a PCM wave table, two 128-entry timbre maps for groups A and B,
a rhythm timbre map, rhythm settings, reserve/pan/program defaults, parameter
maximum tables, sound-group names, and the startup message. A port that
reimplements the firmware still has to read those tables, so **the control ROM
is a runtime dependency even though the 8095 is not emulated**.

## Synthesis

| Quantity | Value | Source |
| --- | --- | --- |
| Sample rate | 32,000 Hz | `globals.h`, `MT32EMU_SAMPLE_RATE` |
| Partials | 32 | `globals.h`, `MT32EMU_DEFAULT_MAX_PARTIALS` |
| Parts | 9 (eight melodic plus rhythm) | `Synth.h`, `Part *parts[9]` |
| PCM waves | 128 on MT-32, 256 on CM-32L | `Synth.cpp`, `ControlROMMaps` |
| PCM samples in ROM | 262,144 16-bit logarithmic | `Synth.cpp`, `loadPCMROM` |

The PCM ROM's bytes are not sample values in order: `Synth::loadPCMROM`
de-shuffles a 16-entry bit permutation out of each byte pair before the
logarithmic sample appears. Any host-side PCM voice has to reproduce that
permutation, and it is cheap to get subtly wrong.

Each wave-table entry (`Synth::initPCMList`) gives a start at `pos * 0x800`, a
length of `0x800 << ((len & 0x70) >> 4)` samples, and a loop flag in `len` bit
7. So the shortest wave is 2048 samples and lengths are powers of two above
that.

### Why the LA32 is a good fit for a DSP56001

From `LA32WaveGenerator.h`, which is worth reading in full before any kernel
work starts:

> LA32 performs wave generation in the log-space that allows replacing
> multiplications by cheap additions.

The synthesized wave is not a filtered oscillator. It is a square built from
rising and falling cosine segments joined by linear high and low segments —
phase distortion — optionally multiplied by a synchronous cosine to make a
sawtooth. Resonance is not an IIR filter either: it is a decaying sine added in,
windowed by a cosine at both ends.

That matters for this port in three ways:

- there is no filter state to carry per partial, so partials are independent
  and cheap to schedule;
- the arithmetic is dominated by table lookups and adds in the log domain,
  which suits a 24-bit fixed-point DSP with fast table addressing; and
- the tables are small. Munt's whole constant set is `exp9[512]`,
  `logsin9[512]`, three ≤256-entry byte tables and a resonance decay table
  (`Tables.h`) — on the order of 1,500 DSP words, which is not a memory problem
  at all. The memory problem is the PCM ROM; see
  [`architecture.md`](architecture.md#the-pcm-rom-problem).

None of this says the partial *fits* the cycle budget. It says the shape of the
work is right for the machine. The budget is a measurement nobody has taken;
see [`la32-budget.md`](la32-budget.md).

### Reverb

Munt's `BReverbModel` implements the Boss chip as three allpasses and four
combs per mode, with per-mode delay lengths (`BReverbModel.cpp`). Mode 0 on the
CM-32L, for instance, uses allpasses of 994, 729 and 78 samples and combs of
705, 2349, 2839 and 3632 — about 11,300 samples of delay line in total, plus
per-comb feedback factors and separate left and right output taps.

Two consequences worth recording early:

- 11,300 words is affordable in the Falcon's 32K DSP SRAM, and comb/allpass
  delay lines are exactly what the DSP56001's modulo addressing is for.
- The delays are specified in samples at 32,000 Hz. Running them unchanged at
  the codec rate shortens every delay by 2.4 %, which is the cheap and correct
  choice for a reverb.

## Executable oracle

`third_party/munt` is pinned as the reference implementation. Munt is the
product of long hardware analysis and is the only practical ground truth
available; its `mt32emu` library is LGPL-2.1 and is used here **at build time
only**. No Munt code goes near the Falcon binary.

Nothing is built against it yet. When it is, it should follow the shape
F030MXDRV uses against MAME/ymfm:

1. a native oracle binary that plays a tracked fixture and emits per-sample
   vectors;
2. sample-exact agreement at selected checkpoints for whatever subset of the
   chip the DSP kernel claims to implement exactly; and
3. a separate, explicitly thresholded perceptual gate for the production
   renderer, which will differ from the oracle by construction — different
   sample rate, block-rate control updates, and a reduced partial count.

Keeping those two contracts apart is what lets a deliberately approximate
production kernel still be gated rather than merely auditioned.

Two Munt-specific details the harness will have to settle before it can compare
anything:

- **Renderer choice.** Munt ships both a bit-accurate integer LA32 model and a
  float model (`LA32WaveGenerator` and `LA32FloatWaveGenerator`). The integer
  one is the oracle; the float one is not.
- **Analog output mode.** `Synth::getStereoOutputSampleRate` shows the analog
  emulation can resample to 1×, 1.5× or 3× the synth rate. Comparisons must be
  taken at the synth rate with the analog stage's contribution accounted for
  explicitly, or the rate difference this port already has will be confounded
  with a second one.

## Open questions

These are the things a first measurement session should settle, in roughly this
order:

1. What does one synth partial cost per sample on a DSP56001, and what does one
   PCM partial cost on the 68030?
2. At what control rate can the TVA, TVF and TVP envelopes and the LFOs be
   updated before it is audible? Munt steps them per sample; F030MXDRV's
   equivalent decision — block-rate envelopes and LFO at 32 frames — is what
   made its YM2151 fit, and the same lever is available here.
3. How many partials must be supported for real MT-32 material to sound right,
   as opposed to the hardware's 32? Partial *allocation* under a lower ceiling
   is a control-half behaviour Munt already models (`PartialManager`), so the
   reduced machine can still be a well-defined one.
4. MT-32 or CM-32L as the target, and which control ROM version.

# Feasibility: what fits on the Falcon DSP

The point of this page is to keep the project honest about the one question
that decides whether it is possible: **an MT-32 has 32 partials at 32 kHz, and
the Falcon DSP has 489 instruction cycles per output frame.** The experiments
listed at the bottom have started, and their numbers are the headline:

> **One LA32 synth partial costs 77 DSP56001 instruction cycles per codec
> frame as a square wave and 100 as a sawtooth when it reproduces Munt's
> integer model bit for bit, and 53 and 64 when it leaves the log domain
> through single-table lookups within one or two output words of that model**,
> measured under the DSP-calibrated Hatari on 2026-09-09
> (`make profile-partials`).

Everything below the measurement section is arithmetic that follows from it.
F030MXDRV remains the cautionary precedent: its first feasibility guess was an
8.6× miss inferred from a throughput test; the measurement that replaced it
said 47.81×, and the response was not optimization but a different renderer.

## The budget

| Quantity | Value |
| --- | --- |
| Falcon DSP oscillator | 32,084,988 Hz (Hatari's figure; see caveat below) |
| Instruction cycle | two oscillator clocks |
| Instruction rate | 16,042,494 cycles/s |
| Codec rate (prescale 2) | 32,779.947916 Hz |
| **Cycles per output frame** | **489.40** |
| Cycles per 512-frame period | 250,572 |

The oscillator figure is Hatari's, and F030MXDRV records that the physical
Falcon's DSP clock is about 0.27 % lower, which scales every budget here
proportionally. It also records that *stock* Hatari delivers those cycles at
twice the correct rate, so any real-time measurement must come from the
DSP-calibrated build; see [`hatari-timing.md`](hatari-timing.md). Bracketed
cycle profiles like the ones below are the same on either build.

## The measurement

### What was measured

`src/dsp/la32.asm` carries `MT32_CMD_PROFILE_PARTIAL`: two DSP56001 kernels
for one synth partial with amp, pitch and cutoff held constant, which is
exactly how a block-rate production kernel would present them between control
updates. Each renders 2,048 frames into X:$1000, pan-mixed into an interleaved
stereo accumulation buffer the way `Partial::produceAndMixSample` does, and
Hatari's DSP profiler brackets the render loop between its first and last
instruction.

The output is checked, not auditioned. `tools/la32_partial_oracle.cpp` drives
Munt's own `LA32IntPartialPair` with the same parameters, and
`tools/la32_partial.py compare` grades the DSP buffer the emulator's debugger
dumps at the end breakpoint against the oracle's frames. Four configurations
are rendered by both kernels, eight runs in all:

| # | Wave | Pulse width | Resonance | Cutoff | Note | TVA target |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | square | 128 | 1 | 120 (below the middle: pure sine segments) | C4 | 240 |
| 1 | square | 200 | 20 | 220 (long linear segments) | G4 | 200 |
| 2 | sawtooth | 128 | 31 | 240 (the clamp) | C6 | 230 |
| 3 | sawtooth | 90 | 8 | 136 (sinusoidal resonance decay band) | C3 | 235 |

### The exact kernel

A port of `LA32WaveGenerator` that carries the square-wave position as
`SQ >> 4` so it fits 24 bits, selects the wave half and the segment with
`Tcc` chains instead of branches, reads the square's sine value and window
term with one L move, and unlogs each component through an exponent table
indexed by the fraction of its log and a power-of-two table indexed by the
integer part. Munt's clamps to 65,535 are gone without loss: a log at or above
65,536 unlogs to zero, and so does the zero-padded power table, which also
carries a guard word for the one negative value the resonance can reach.

Every left and right word of all four runs equals the oracle's, so these
cycle counts describe a partial that *is* the LA32 model:

| Run | Cycles/frame | Instructions/frame |
| --- | ---: | ---: |
| square (runs 0 and 1) | 77.00 | 75 |
| sawtooth (runs 2 and 3) | 100.00 | 98 |

The loops are branch-free, so the cost does not depend on the parameters.
Every instruction is a single cycle except the L read of the square's sine
value and window through indexed addressing, which costs three: on the
DSP56001 an `(Rn+Nn)` operand costs an extra cycle and external SRAM costs
nothing (`hatari-timing.md`, the bus probe), so every other table is
addressed directly by its index.

Per frame, square wave; the sawtooth adds 23 cycles for the cosine lookup,
its two log additions and the sign flips.

| Stage | Cycles | What it is |
| --- | ---: | --- |
| Phase advance and square-wave position | 7 | 20-bit position, one multiply for `(WP>>8)*(RWLF>>4)` |
| Half selection | 4 | one compare, `Tcc` selects the half's record |
| Resonance sign | 5 | bit 15 of the resonance position against the half |
| Segment selection | 7 | two compares, `Tcc` selects rising, linear or falling table |
| Table addresses | 9 | square sine index and resonance sine address |
| Square log sample | 6 | sine value and window term in one L read, plus the amp term |
| Resonance log sample | 5 | decay multiply-accumulate, sine, window |
| Unlog, resonance | 12 | exp table by the fraction, power table by the integer part, sign |
| Unlog, square | 13 | the same, accumulated into the sum |
| Pan and accumulate | 9 | two multiply-accumulates into the stereo buffer |

The two unlogs are a third of the frame. That is the LA32's own structure:
every partial produces two log-domain components, square and resonance, and
each leaves the log domain separately.

### The perceptual kernel

The same positions, segments, window and decay arithmetic, but each component
is factored instead of unlogged:

- the square is a *linear* sine table entry (the exact unlog of the sine's
  log, so the linear segments read full scale) times a per-block gain
  `2^(-AMPT/4096)` that carries the half's sign;
- the resonance is a signed linear sine entry — the sign of bit 15 of its
  position sits in bit 10 of the index, the half's sign in the choice of a
  second table copy 1,024 words up — times a gain read from one 4,096-entry
  table by the top twelve bits of the rest of its log, clamped to 65,535;
- the sawtooth cosine multiplies their sum once, where the exact kernel adds
  its log to both components.

That is one lookup and one multiply per component where the exact kernel
needs two lookups, a multiply-accumulate and a sign multiply, and no sign
arithmetic at all.

| Run | Cycles/frame | Instructions/frame | Max error | RMS error, full scale | RMS error, signal | Correlation |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 4 square-lowcut | 53.00 | 51 | 1 word | -90 dB | -62 dB | 1.000000 |
| 5 square-pw-res | 53.00 | 51 | 2 words | -92 dB | -59 dB | 0.999999 |
| 6 saw-maxres | 64.00 | 62 | 5 words | -87 dB | -63 dB | 1.000000 |
| 7 saw-sinedecay | 64.00 | 62 | 2 words | -89 dB | -62 dB | 1.000000 |

Full scale is 16,384, the sum of two full-amplitude components; the worse of
the two channels is listed. The gate that `make profile-partial` applies
allows 64 words of error, -72 dB of full scale, and above one percent of full
scale demands -40 dB of the signal, a correlation and a spectral cosine of
0.9999; the measured deviation is a decade inside every bound, so the bounds
catch a broken kernel without tripping on table rounding. Two things the
gate does not cover: the gain table quantizes its argument to sixteen log
units, a ±0.14 % amplitude step that the resonance's decay walks through
continuously, and Munt silences the resonance when its log sum underflows —
a TVA target of 250 or more with maximum resonance — which the factored
kernel does not reproduce. Neither configuration here reaches that corner.

Per frame, square wave; the sawtooth adds 11 for the cosine lookup and its
multiply.

| Stage | Cycles | What it is |
| --- | ---: | --- |
| Phase advance and square-wave position | 7 | as the exact kernel |
| Half selection | 4 | |
| Segment selection | 7 | |
| Table addresses | 9 | square sine index, signed resonance sine address |
| Square component | 5 | L read of sine and window, one multiply by the signed gain |
| Resonance component | 14 | decay multiply-accumulate, window, clamp, gain lookup, multiply-accumulate |
| Pan and accumulate | 7 | |

Twenty-seven of the 53 cycles are the position, half and segment logic that
gives the LA32 wave its shape. Anything cheaper than this stops being an LA32
partial and becomes a wavetable, which cannot follow a cutoff ramp.

The perceptual kernel needs more table memory than the exact one, 13,504
words against 9,280, most of it the doubled signed sine table and the
192-word guard the gain table carries for negative arguments; a single sine
copy costs one `eor` per frame and would give 2,048 words back.

## The arithmetic that follows

489.40 cycles per frame, divided by the per-partial cost, with nothing else
running; and nothing else running is not an option:

| Fixed cost per frame | Cycles | Basis |
| --- | ---: | --- |
| SSI interrupt and transport | about 15 | F030MXDRV, measured on production material |
| Boss reverb, one mode | about 60 | three allpasses and four combs, one read, MAC and write per tap |
| Per-block control, amortized | about 20 | envelope, ramp and pitch updates every 32 frames |
| **Left for partials** | **about 395** | |

| Kernel | Square | Sawtooth |
| --- | ---: | ---: |
| exact, of 489 | 6.3 | 4.9 |
| exact, of 395 | 5.1 | 3.9 |
| perceptual, of 489 | 9.2 | 7.6 |
| perceptual, of 395 | 7.4 | 6.2 |

That is **six or seven perceptual partials, five or four exact ones**, and
the MT-32's factory timbres lean on sawtooth partials for most sustained
sounds. A Falcon MT-32 built from this kernel is a six-partial machine before
the 68030's PCM partials are counted — a few timbres at a time, not a
nine-part module. The threshold this page named before any measurement,
"more than about 60 cycles per partial makes it a four-partial machine", is
met by the exact kernel and only just escaped by the perceptual one.

## The levers, in the order they should be tried

The measurements change the order. Fewer partials is no longer a lever but
the starting condition, and the partial itself is close to its floor.

1. **Block-rate control** is assumed by both kernels already: amp, pitch and
   cutoff are constants inside the loop. The cost of *updating* them once
   per 32-frame block is the "about 20" above and has not been measured;
   `TVA`, `TVF` and `TVP` do a few dozen integer operations each per event,
   so it is unlikely to matter next to the partial itself.
2. **Move work to the 68030.** PCM partials have to move anyway — see
   [`architecture.md`](architecture.md#the-pcm-rom-problem) — and the
   measurement makes the 68030 the more important half: the number of PCM
   partials it can carry now decides more of the machine than the DSP does.
3. **A lower internal rate.** Prescale 3 gives 24,584.96 Hz and 652.5
   cycles per frame, one third more partials for the top octave. Last
   resort, and it interacts badly with comparing against an oracle.

## What is affordable

**The reverb.** Munt's `BReverbModel` is three allpasses and four combs; the
mode-0 CM-32L delay lengths sum to 11,326 samples, the hall mode to 13,954.
Comb and allpass delay lines are what the DSP56001's modulo addressing exists
for, and each tap is a read, a MAC and a write. About 60 cycles per frame
and a comfortable fraction of the 32K SRAM, though modulo buffers must sit at
power-of-two boundaries, which costs placement care. It is not the problem.

**The tables.** Either kernel's tables are affordable next to the reverb;
the two together with the period buffers and the program take most of the
SRAM, and the spike's image, which carries both kernels, is 24K words. All of
it is delivered by the stage-two loader at the P alias of its X and Y homes,
so nothing copies at run time except the exact kernel's first exponent page,
which lives in internal X.

**The PCM ROM is the problem**, and it is not a budget question but an
absolute one: 262,144 samples against 32,768 words of SRAM.

## The experiments that would settle this

Each of these is small. They are listed in dependency order; the first two
are done.

1. ~~**Cost one synth partial.**~~ Done: 77 and 100 cycles per frame,
   bit-exact. `make profile-partial CFG=0..3` reproduces it.
2. ~~**Cost the perceptual partial.**~~ Done: 53 and 64 cycles per frame,
   within one to five words of Munt. `make profile-partial CFG=4..7`
   reproduces it, with the graded gate described above.
3. **Cost the reverb.** Same method, one mode, real delay lengths. Confirms
   or refutes the paragraph above.
4. **Cost the transport.** The scaffold already runs; bracketing
   `receive_period` and the handoff gives the fixed overhead that comes off
   the top of the budget before any synthesis.
5. **Cost a 68030 PCM partial.** Resample-and-amp one looping ROM wave into a
   512-frame period and time it against the 15.62 ms budget. This decides how
   many PCM partials the host half can carry, which after these measurements
   is the larger of the two ceilings.
6. **Find the control rate.** With one partial working, hold its envelopes
   and LFO across 1, 8, 32 and 64 frames and compare against the oracle.

## What would make the project not worth doing

Written down before the measurement, so it is a conclusion rather than a
disappointment:

- if one synth partial costs more than about 60 cycles per frame, then even
  eight partials plus reverb plus transport exceeds the budget, and a Falcon
  MT-32 would be a four-partial machine — roughly one timbre at a time;
- if the 68030 cannot carry enough PCM partials, then the port loses precisely
  the sounds the MT-32 is remembered for, since its characteristic attacks are
  PCM.

The first condition is met by the exact model and skirted by the perceptual
one: 53 to 64 cycles buys six or seven partials, not eight. The project is
therefore only worth continuing as a deliberately reduced machine — the
perceptual partial, a handful of DSP partials, and as many 68030 PCM
partials as the host budget allows — and the second condition, still
unmeasured, decides whether even that is worth having.

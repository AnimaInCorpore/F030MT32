# Feasibility: what fits on the Falcon DSP

The point of this page is to keep the project honest about the one question
that decides whether it is possible: **an MT-32 has 32 partials at 32 kHz, and
the Falcon DSP has 489 instruction cycles per output frame.** The first of the
experiments listed at the bottom has now been run, and its number is the
headline of this page:

> **One LA32 synth partial, rendered bit-exact against Munt's integer model
> with its controls held per block, costs 77 instruction cycles per codec
> frame as a square wave and 100 as a sawtooth**, measured under the
> DSP-calibrated Hatari on 2026-09-09 (`make profile-partials`).

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
cycle profiles like the one below are the same on either build.

## The measurement

### What was measured

`src/dsp/la32.asm` carries `MT32_CMD_PROFILE_PARTIAL`: a DSP56001 port of
Munt's `LA32WaveGenerator` for one synth partial with amp, pitch and cutoff
held constant, which is exactly how a block-rate production kernel would
present them between control updates. It renders 2,048 frames into X:$1000,
pan-mixed into an interleaved stereo accumulation buffer the way
`Partial::produceAndMixSample` does, and Hatari's DSP profiler brackets the
render loop between its first and last instruction.

The output is checked, not auditioned. `tools/la32_partial_oracle.cpp` drives
Munt's own `LA32IntPartialPair` with the same parameters, and
`tools/la32_partial.py compare` requires every left and right word of the
DSP buffer, dumped by the emulator's debugger at the end breakpoint, to equal
the oracle's. All four configurations pass that comparison word for word, so
the cycle counts describe a partial that *is* the LA32 model, not an
approximation of it. The four configurations:

| # | Wave | Pulse width | Resonance | Cutoff | Note | Cycles/frame |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | square | 128 | 1 | 100 (below the middle: pure sine segments) | C4 | 77.00 |
| 1 | square | 200 | 20 | 220 (long linear segments) | G4 | 77.00 |
| 2 | sawtooth | 128 | 31 | 240 (the clamp) | C6 | 100.00 |
| 3 | sawtooth | 90 | 8 | 136 (sinusoidal resonance decay band) | C3 | 100.00 |

The loops are branch-free, so the cost does not depend on the parameters:
75 instructions per frame for the square and 98 for the sawtooth, every one a
single cycle except the L-memory read of the square's sine value and window
term through indexed addressing, which costs three. Instruction fetches come
from internal P; every table read but that one uses direct register
addressing, because on the DSP56001 an `(Rn+Nn)` operand costs an extra
cycle and external SRAM costs nothing (`hatari-timing.md`, the bus probe).

### Where the cycles go

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
every partial produces two log-domain components, square and resonance,
and each leaves the log domain through a 4,096-entry exponent table indexed
by the fraction and a power-of-two table indexed by the integer part, then
takes its sign. The clamps Munt applies to log values are gone without loss:
a log at or above 65,536 unlogs to zero, and so does the zero-padded power
table, which also carries a guard word for the one negative value the
resonance can reach.

### The first version

The first bit-exact version measured 98 and 128 cycles. The 21-28 cycle
difference came from: direct instead of indexed table addressing (the unlog
tables moved to X:$0000 and Y:$3600 so the index *is* the address), the
zero-padded power table replacing three clamps, `mac` folding the table base
and the resonance amp base into the multiplies, `Tcc` from the accumulator
instead of a copied register, and the mix accumulating with `mac` instead of
load, add, store. The remaining loop has no instruction that can be removed
without changing what it computes.

## The arithmetic that follows

489.40 cycles per frame, divided by 77, is **6.3 square partials** with
nothing else running; divided by 100, **4.9 sawtooth partials**. Nothing else
running is not an option:

| Fixed cost per frame | Cycles | Basis |
| --- | ---: | --- |
| SSI interrupt and transport | about 15 | F030MXDRV, measured on production material |
| Boss reverb, one mode | about 60 | three allpasses and four combs, one read, MAC and write per tap |
| Per-block control, amortized | about 20 | envelope, ramp and pitch updates every 32 frames |
| **Left for partials** | **about 395** | |

That is **five square partials or four sawtooth partials** of the exact
model, and the MT-32's factory timbres lean on sawtooth partials for most
sustained sounds. A Falcon MT-32 built from this kernel is a four-to-five
partial machine before the 68030's PCM partials are counted — one or two
timbres at a time, not a nine-part module. The threshold this page named
before the measurement, "more than about 60 cycles per partial makes it a
four-partial machine", has been crossed, and not by a little.

## The levers, in the order they should be tried

The measurement changes the order. Fewer partials is no longer a lever but
the starting condition; the levers are what makes each partial cheaper.

1. **Leave the exact model for a perceptual one.** The unlog is the place
   to start: one 4,096-entry table indexed by the top twelve bits of the
   16-bit log, four integer and eight fraction bits, replaces the two-table
   unlog with a single read and an error below 0.4 % — five to six cycles
   per unlog, saving twelve to fourteen per frame. The clamps are already
   gone. Together with keeping the sign in the table this brings a partial
   to about 60 cycles, still a six-partial machine, and it needs the same
   Hatari-plus-oracle harness, now with a perceptual gate in place of the
   word-for-word one, exactly as F030MXDRV graded its 256-step sine.
2. **Block-rate control** is assumed by this kernel already: amp, pitch and
   cutoff are constants inside the loop. The cost of *updating* them once
   per 32-frame block is the "about 20" above and has not been measured;
   `TVA`, `TVF` and `TVP` do a few dozen integer operations each per event,
   so it is unlikely to matter next to the partial itself.
3. **Move work to the 68030.** PCM partials have to move anyway — see
   [`architecture.md`](architecture.md#the-pcm-rom-problem) — and the
   measurement makes the 68030 the more important half: the number of PCM
   partials it can carry now decides more of the machine than the DSP does.
4. **A lower internal rate.** Prescale 3 gives 24,584.96 Hz and 652.5
   cycles per frame, one third more partials for the top octave. Last
   resort, and it interacts badly with comparing against an oracle.

## What is affordable

**The reverb.** Munt's `BReverbModel` is three allpasses and four combs; the
mode-0 CM-32L delay lengths sum to 11,326 samples, the hall mode to 13,954.
Comb and allpass delay lines are what the DSP56001's modulo addressing exists
for, and each tap is a read, a MAC and a write. About 60 cycles per frame
and a comfortable fraction of the 32K SRAM, though modulo buffers must sit at
power-of-two boundaries, which costs placement care. It is not the problem.

**The tables.** The exact partial uses 4,096 words of exponent table, 1,088
of power table, 1,536 L-words of square sine and window, and 1,024 of
resonance sine — 9,280 words, delivered by the stage-two loader at the P
alias of their X and Y homes so nothing copies them at run time except the
first page of the exponent table, which lives in internal X. Affordable next
to the reverb, but the two together take most of the SRAM the period buffers
and the program leave.

**The PCM ROM is the problem**, and it is not a budget question but an
absolute one: 262,144 samples against 32,768 words of SRAM.

## The experiments that would settle this

Each of these is small. They are listed in dependency order; the first is
done.

1. ~~**Cost one synth partial.**~~ Done: 77 and 100 cycles per frame,
   bit-exact. `make profile-partial CFG=n` reproduces it; the DSP source,
   the oracle and the comparison are in `src/dsp/la32.asm`,
   `tools/la32_partial_oracle.cpp` and `tools/la32_partial.py`.
2. **Cost the perceptual partial.** Lever 1 above, with the perceptual gate
   that makes it a measurement rather than a guess.
3. **Cost the reverb.** Same method, one mode, real delay lengths. Confirms
   or refutes the paragraph above.
4. **Cost the transport.** The scaffold already runs; bracketing
   `receive_period` and the handoff gives the fixed overhead that comes off
   the top of the budget before any synthesis.
5. **Cost a 68030 PCM partial.** Resample-and-amp one looping ROM wave into a
   512-frame period and time it against the 15.62 ms budget. This decides how
   many PCM partials the host half can carry, which after this measurement
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

The first condition is now met for the exact model. The project is therefore
only worth continuing as a deliberately reduced machine — a perceptual
partial at around 60 cycles, a handful of DSP partials, and as many 68030 PCM
partials as the host budget allows — and the second condition, still
unmeasured, decides whether even that is worth having.

# Feasibility: what fits on the Falcon DSP

The point of this page is to keep the project honest about the one question
that decides whether it is possible: **an MT-32 has 32 partials at 32 kHz, and
the Falcon DSP has 489 instruction cycles per output frame.** Nothing here is
measured yet. What is written down is the arithmetic that is certain, the
estimate that follows from it, and the experiments that would replace the
estimate with a number.

F030MXDRV is the cautionary precedent. Its first feasibility guess was an 8.6×
miss inferred from a throughput test; the measurement that replaced it said
47.81×, and the response was not optimization but a different renderer. That
project's exact YM2151 kernel still costs 12,271.21 cycles per native sample
and is kept only as a test oracle. Assume the same outcome here until measured
otherwise.

## The budget

| Quantity | Value |
| --- | --- |
| Falcon DSP oscillator | 32,084,988 Hz (Hatari's figure; see caveat below) |
| Instruction cycle | two oscillator clocks |
| Instruction rate | 16,042,494 cycles/s |
| Codec rate (prescale 2) | 32,779.947916 Hz |
| **Cycles per output frame** | **489.40** |
| Cycles per 512-frame period | 250,572 |

The oscillator figure is Hatari's, and F030MXDRV records that a small
difference on real hardware scales every budget here proportionally. It also
records that *stock* Hatari delivers those cycles at twice the correct rate, so
any real-time measurement must come from the DSP-calibrated build; see
[`hatari-timing.md`](hatari-timing.md).

## The arithmetic that is certain

489.40 cycles per frame, divided by 32 partials, is **15.29 cycles per partial
per frame** — and that is before the SSI service, the host port, the mixer, the
reverb, and the per-frame accumulation.

15 cycles is a phase advance, a table read and a store. It is not a
log-domain LA32 partial: the wave generator has to choose among rising cosine,
high, falling cosine and low segments, apply pulse width and resonance, add the
windowed resonance sine, optionally multiply by the synchronous cosine, add the
amp, and leave the log domain through `exp9`. Whatever that costs, it is not
15 cycles.

So the honest statement is: **a full 32-partial MT-32 at codec rate does not
fit, by a factor nobody has measured yet.** The project's real question is not
whether to compromise but which compromise, and that cannot be chosen from an
armchair.

## The levers, in the order they should be tried

1. **Fewer partials.** The most direct, and it is a *modelled* reduction rather
   than a hack: Munt already supports a lower partial ceiling
   (`Synth::open(..., usePartialCount, ...)`) and its `PartialManager`
   implements the MT-32's own priority and stealing rules under that ceiling.
   A 16- or 8-partial Falcon MT-32 is therefore a well-defined machine that the
   oracle can also be told to be, which keeps it gateable.
2. **Block-rate control.** Munt steps TVA, TVF, TVP and the LFOs every sample.
   Holding them across a 32-frame block is exactly the lever that made
   F030MXDRV's YM2151 fit, and its perceptual gate is the model for proving the
   result is still acceptable. The saving is large because envelope and LFO
   work is per-partial and per-sample today.
3. **Move work to the 68030.** PCM partials have to move anyway — see
   [`architecture.md`](architecture.md#the-pcm-rom-problem) — so the split is
   forced there and only the amount is a choice.
4. **A lower internal rate.** The codec's next step down is 24,584.96 Hz
   (prescale 3), which buys 33 % more cycles per frame and costs the top
   octave. Last resort, and it interacts badly with comparing against an oracle.

## What is affordable

Not everything is in doubt. Two components can be sized now.

**The reverb.** Munt's `BReverbModel` is three allpasses and four combs; the
mode-0 CM-32L delay lengths sum to 11,326 samples. Comb and allpass delay
lines are what the DSP56001's modulo addressing exists for, and each tap is a
read, a MAC and a write. This is a small fraction of the frame budget and a
comfortable fraction of the 32K SRAM. It is not the problem.

**The tables.** `exp9[512]`, `logsin9[512]`, three tables of at most 256 bytes
and a resonance decay table — order 1,500 DSP words (`Tables.h`). Also not the
problem.

**The PCM ROM is the problem**, and it is not a budget question but an absolute
one: 262,144 samples against 32,768 words of SRAM.

## The experiments that would settle this

Each of these is small, and none of them requires the synthesizer to exist.
They are listed in dependency order.

1. **Cost one synth partial.** Write the LA32 wave generator for a single
   partial, at codec rate, from `LA32WaveGenerator.cpp`, and bracket it between
   host-port markers the way F030MXDRV's `make profile-dsp-rt*` targets do.
   The answer divides 489.40 and gives the partial ceiling directly. This is
   the one measurement everything else waits on.
2. **Cost the reverb.** Same method, one mode, real delay lengths. Confirms or
   refutes the paragraph above.
3. **Cost the transport.** The scaffold already runs; bracketing
   `receive_period` and the handoff gives the fixed overhead that comes off the
   top of the budget before any synthesis.
4. **Cost a 68030 PCM partial.** Resample-and-amp one looping ROM wave into a
   512-frame period and time it against the 15.62 ms budget. This decides how
   many PCM partials the host half can carry, which is a separate ceiling from
   the DSP's.
5. **Find the control rate.** With one partial working, hold its envelopes and
   LFO across 1, 8, 32 and 64 frames and compare against the oracle. This is
   what turns lever 2 from a hope into a number.

Only after 1 and 4 is it possible to say what a Falcon MT-32 is: how many
partials, how many of them PCM, and at what control rate. Choosing the
architecture before then would be choosing it blind.

## What would make the project not worth doing

Worth writing down in advance, so it is a conclusion rather than a
disappointment:

- if one synth partial costs more than about 60 cycles per frame, then even
  eight partials plus reverb plus transport exceeds the budget, and a Falcon
  MT-32 would be a four-partial machine — roughly one timbre at a time;
- if the 68030 cannot carry enough PCM partials, then the port loses precisely
  the sounds the MT-32 is remembered for, since its characteristic attacks are
  PCM.

Neither is known. Both are cheap to find out.

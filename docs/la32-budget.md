# Feasibility: what fits on the Falcon DSP

The point of this page is to keep the project honest about the one question
that decides whether it is possible: **an MT-32 has 32 partials at 32 kHz, and
the Falcon DSP has 489 instruction cycles per output frame.** The experiments
listed at the bottom have started, and their numbers are the headline:

> **Current measured costs (2026-09-11):** 79/102 cycles per codec frame
> for an exact square/saw partial, 58/69 for the approximate partials,
> 152 for corrected room reverb, and 14.81 for interrupt-driven transport.
> Control updates add up to about 22 cycles per partial per frame while
> filters move. The resulting real-time ceiling is 2�4 exact synth partials
> on the DSP and at most 2 exact PCM partials on the 68030, before completing
> and measuring the live controller and combined DSP image. This is roughly
> 1�3 typical multi-partial notes, not 32 notes or a demonstrated voice count.
>
> The separate [offline renderer](falcon-renderer.md) retains Munt's full
> 32-partial pool by rendering to disk before playback. Its short integer
> render is byte-exact between the workstation and emulated Falcon.

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

`src/dsp/la32.asm` carries `MT32_CMD_PROFILE_PARTIAL`, which renders one of
ten runs into X:$1000 while Hatari's DSP profiler brackets the render loop
between its first and last instruction: two kernels for one synth partial
with amp, pitch and cutoff held constant, which is exactly how a block-rate
production kernel would present them between control updates, and the Boss
reverb over one partial's output. Each partial kernel pan-mixes into an
interleaved stereo accumulation buffer the way `Partial::produceAndMixSample`
does; the reverb processes the buffer in place. A fourth probe profiles the
transport itself: whole periods of the self-test's host-fed stream, with
every cycle sorted by what the DSP was doing (`make profile-transport`).
The fifth leaves the DSP: the 68030 renders one PCM partial, the kind of
partial the DSP can never hold, and Hatari's CPU profiler brackets it
(`make profile-pcms`). The sixth lets the controls move: the oracle renders
envelopes and vibrato per sample and held per block (`make control-sweep`),
and the DSP renders the same runs block by block, deriving its constants
from each block's amp, pitch and cutoff (`make profile-controls`).

The output is checked, not auditioned. `tools/la32_partial_oracle.cpp` drives
Munt's own `LA32IntPartialPair` and `BReverbModel` with the same parameters,
and `tools/la32_partial.py compare` grades the DSP buffer the emulator's
debugger dumps at the end breakpoint against the oracle's frames. Four
configurations are rendered by both partial kernels, then the reverb runs at
two settings over the second configuration:

| # | Wave | Pulse width | Resonance | Cutoff | Note | TVA target |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | square | 128 | 1 | 120 (below the middle: pure sine segments) | C4 | 240 |
| 1 | square | 200 | 20 | 220 (long linear segments) | G4 | 200 |
| 2 | sawtooth | 128 | 31 | 240 (the clamp) | C6 | 230 |
| 3 | sawtooth | 90 | 8 | 136 (sinusoidal resonance decay band) | C3 | 235 |

Runs 0-3 are the exact kernel, 4-7 the perceptual one, 8 and 9 the reverb at
the MT-32's power-on setting (room, time 5, level 3) and at its longest and
loudest (time 7, level 7).

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
| square (runs 0 and 1) | 79.00 | 77 |
| sawtooth (runs 2 and 3) | 102.00 | 100 |

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
| Amp ramp | 2 | present even when its slope is zero |

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
| 4 square-lowcut | 58.00 | 56 | 1 word | -90 dB | -62 dB | 1.000000 |
| 5 square-pw-res | 58.00 | 56 | 2 words | -92 dB | -59 dB | 0.999999 |
| 6 saw-maxres | 69.00 | 67 | 5 words | -87 dB | -63 dB | 1.000000 |
| 7 saw-sinedecay | 69.00 | 67 | 2 words | -89 dB | -62 dB | 1.000000 |

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
| Amp ramp | 5 | present even when its slope is zero |

Twenty-seven of the 58 cycles are the position, half and segment logic that
gives the LA32 wave its shape. Anything cheaper than this stops being an LA32
partial and becomes a wavetable, which cannot follow a cutoff ramp.

The perceptual kernel needs more table memory than the exact one, 13,504
words against 9,280, most of it the doubled signed sine table and the
192-word guard the gain table carries for negative arguments; a single sine
copy costs one `eor` per frame and would give 2,048 words back.

### The reverb

A port of `BReverbModel` in the MT-32's room mode and Munt's default
non-precise integer form: a 576-word entrance delay with a low-pass filter,
three allpasses of 994, 729 and 78 words, three combs of 2,040, 2,752 and
3,629 words with six output taps, the 1.5-weighted comb mix, its clip to
sixteen bits and the wet level. Every delay line is a modulo pointer, so a
line costs one read and one write per frame and no address arithmetic; the
taps step a comb's pointer forward by the tap distance and back with
post-update moves that ride on the mix's transfers, so they cost nothing
beyond the read. `weirdMul` is a fractional multiply by the factor shifted
into a Q23 fraction, halving one by 2^22, both exact floors, and the clip is
two compares with `Tcc`.

Both runs equal Munt's output word for word:

| Run | Cycles/frame | Instructions/frame |
| --- | ---: | ---: |
| 8 room, time 5, level 3 | 152.00 | 152 |
| 9 room, time 7, level 7 | 152.00 | 152 |

The cost does not depend on time or level, which only change factors, and
the hall and plate modes have the same instruction count with longer lines.
The first version measured 106; folding the constant loads into free
parallel slots, passing the link between allpasses in an accumulator, and
forming the 1.5-weighted taps with `mac` took it to 92. That version failed
on long, full-scale input: Munt narrows allpass links and comb inputs/stores
to signed 16 bits, while the DSP kept 24 bits. Wrapping those intermediate
assignments adds 60 cycles. `make check-reverb` compares all 6,144 frames of
full-scale square, seeded noise and impulse input at both settings, including
the first square-wave mismatch that previously occurred at frame 5,464.
The corrected kernel passes all six cases. Per frame:

| Stage | Cycles | What it is |
| --- | ---: | --- |
| Dry input | 9 | two quarter-scale multiplies, the sum, the dry amp |
| Entrance delay | 5 | low-pass, amp, store, link out |
| Allpasses | 52 | original 22 plus six signed-16-bit wraps |
| Combs | 54 | original 24 plus six signed-16-bit wraps |
| Left output | 15 | three taps, two 1.5 sums, clip, wet, store |
| Right output | 17 | the same, with comb 2's second tap offset swapped in and out |

The wraps use `(value & 0xffff) ^ 0x8000`, followed by subtracting
0x8000. Masks live in short-addressed internal Y memory so each wrap costs
five instructions. Saturating only the final mixer does not reproduce the
intermediate 16-bit overflow behaviour.

The room mode's 10,798 words of delay line take 13,440 words of address
space, because a modulo pointer wraps only inside a block aligned to the
power of two above its line's length; the spike places them in Y between the
code alias and the top of the SRAM. The hall mode's 4,519-word comb needs an
8,192-aligned block, and its seven lines do not fit in Y alone: they would
have to spread across X and Y, or the longest lines would have to give up
modulo addressing for a compare-and-wrap of about three cycles per line.
The tap-delay mode is one 16,003-word line and cheaper to run, but needs a
16,384-aligned block, which only X:$0000 offers.

### The transport

`make profile-transport` arms the profiler at the fourth refill of the
self-test's host-fed stream and saves it 24 refills later, so the window is
24 whole periods, 12,288 frames, with every cycle the DSP spent in them
sorted by what it was doing. The window measures exactly its own real time,
1.000 times the codec budget, which is the check that the profiler saw all
of it. Unlike the bracketed profiles above, this one depends on the
calibrated build: the stall and the idle are paced by the 68030 and the
codec.

| Per codec frame | Cycles | What it is |
| --- | ---: | --- |
| SSI transmit interrupt | 7.99 | two MOVEP/LUA fast interrupts per stereo frame |
| Host receive interrupt | 6.00 | one MOVEP/NOP per uploaded word |
| Clock extension | 0.62 | amortised word-to-frame accounting |
| Commands, replies and handoff | 0.20 | once-per-period work |
| **Transport work** | **14.81** | **3.0% of the budget** |
| Foreground waits | 474.58 | clock polling, receive, command and boundary waits |

These are measurements of the implemented receiver, including 24,576 actual
receive interrupts across 24 periods. The previous implementation spent about
79 cycles per frame receiving and waiting. Those waits can now be used by a
future renderer because reception happens in the interrupt. The foreground
still spins in the current player, which has no synthesis to schedule.

The host still spends about 2.33 ms uploading a stereo period. The protocol
enables the receiver before RDY and disables it before the acknowledgement;
the paced host sender waits for that acknowledgement before sending commands.
SSI owns r6 and a condition-code-preserving r7 word counter. Foreground code
extends it even while the host is stalled or the active period repeats. The
smoke gate tests a host stall longer than a 16-bit word-counter wrap.

The new frame counter adds one instruction to each normal SSI interrupt.
The earlier 12.1-cycle transport figure was a projection without that counter;
it was not a measurement of the implemented interrupt path.

### A PCM partial on the 68030

The PCM ROM's 262,144 samples can never sit in the DSP's 32K words, so the
plan renders PCM partials on the 68030 and streams their mix to the DSP
once per period ([`architecture.md`](architecture.md#the-pcm-rom-problem)).
`src/m68k/pcm_partial.s` is that renderer, twice: an exact kernel that
reproduces Munt's integer PCM model word for word, and a perceptual one.
Both hold amp, pitch and pan constant, render into the interleaved stereo
buffer of zero-padded 24-bit words the paced blast sends, and are driven
by `tools/pcm_partial.py`, which also feeds Munt's `LA32IntPartialPair`
the same wave through the oracle and grades the file the program writes.

The waves are synthetic, in the PCM ROM's own word format: a looped
2,048-sample wave of eight harmonics with a little noise, the ROM's shortest
length, and a 4,096-sample one-shot burst that ends inside the run. Four
configurations cover steps of 0.75, 1.5, 2.25 and 0.31 samples per frame,
so most frames reuse a pair, every frame takes a new pair, the one-shot
wave ends after 1,820 frames, and each pair lasts three frames.

The exact model per frame, from `generateNextPCMWaveLogSamples` and
`unlogAndMixWGOutput`: the ROM word becomes a log value by arithmetic, the
amp term is added and the sum clamped, the neighbouring word likewise, both
leave the log domain, and the pair is interpolated in the linear domain by
the seven-bit fraction of the position before the pan factors mix it. The
68030 kernel does the two unlogs through one signed 131,072-word table
indexed by sign and log, built once at start, so a table read replaces the
shift and the sign test; the ROM is stored with its half-log clamped to
fifteen bits, which loses nothing an unlog can see. The perceptual kernel
keeps each wave in linear form, built once through the same table, and
applies amp and pan together as one Q13 factor per channel, so the amp's
log-domain rounding is traded for the multiply's.

Every run of the exact kernel equals the oracle word for word, and every
perceptual run stays within one or two words of it, an RMS error of -87
to -93 dB of full scale:

| Kernel | Cycles/frame | Instructions/frame | Per period | Of the 15.62 ms |
| --- | ---: | ---: | ---: | ---: |
| exact | 146.4 | 36 | 4.67 ms | 29.9 % |
| perceptual | 122.0 | 26 | 3.89 ms | 24.9 % |

The cost is the same for every configuration to within half a cycle: the
kernels are branch-poor and the wave, step and amp only change which
words they read. The program also counts the 200 Hz system tick around
its timed render and prints it, so the same run measures itself on
hardware; under Hatari the ticks give 4.69 and 3.91 ms per period.

Per frame, exact kernel, as Hatari attributes the cycles:

| Stage | Cycles | What it is |
| --- | ---: | --- |
| Position, sample index, two ROM words | 17 | |
| Log, amp term, clamp, two unlog reads | 20 | |
| Interpolation | 32 | factor, one word multiply, shift, add |
| Advance and wrap | 6 | |
| Pan | 49 | two word multiplies and shifts |
| Two stores to ST-RAM | 19 | |
| Loop | 3 | |

The perceptual kernel drops the twenty cycles of log arithmetic and
unlogging and keeps everything else, because everything else is the
floor: three word multiplies at about 22 cycles each are 66 of its 122
cycles, and the two long stores to ST-RAM another 19. A 16 MHz 68030 is a
poor resampler, and the interpolation and the pan are what a PCM partial
is. Mixing all of a part's PCM partials on one bus before panning would
save the two pan multiplies per partial beyond the first of a part, which
is the only lever left in the loop.

Two things the emulator cannot settle. Hatari charges a word multiply 22
cycles where the 68030 manual's cache case says 28, and the reads and
stores depend on the Falcon's ST-RAM timing and the Videl's bus slots,
which the calibrated build models rather than measures; the hardware
figure is probably five to ten percent higher, and the printed tick count
is how to find out. And the measurement is of the kernel alone: a host
that also parses MIDI, runs every partial's envelopes and allocation, and
updates the DSP's controls each block spends part of its period on that
before any PCM partial is rendered.

A third kernel measures what the host would keep if the DSP panned and
mixed its PCM partials: the perceptual kernel without the pan, one gain
multiply and one word per frame, the stream a DSP would take by interrupt.
It costs 92 cycles per frame, 2.94 ms per period, within two words of
Munt's sample. What that buys is worked out under the levers.

### The control rate

Every measurement above holds amp, pitch and cutoff for the whole run.
Munt hands its wave generator a fresh value of each every sample: amp and
cutoff come from `LA32Ramp`, the chip's own linear ramp toward a target
that moves up to one level of 256 per sample at the fastest envelope
setting, and the pitch is re-evaluated by the MT-32's MCU timer every
eight samples or so. A block-rate kernel holds them across a block and
derives its table constants once per block, so two things had to be
measured: how long the block may be, and what the derivation costs.

The first is measured with the oracle alone (`make control-sweep`,
`tools/control_rate.py`). Six scenarios drive Munt's own ramps with the
MT-32's envelope vocabulary at its extremes — a pluck with the fastest TVA
and TVF attack the ROM can ask for, a string swell with vibrato, a brass
filter sweep with a wide fast LFO, a fast release, a settled sustain, and
a vibrato over settled amp and cutoff — rendered per sample and then with
the controls held per block of 2 to 128 frames, in several modes, each
graded against the per-sample render with the perceptual gate. The block
length each mode survives:

| Scenario | Hold all three | Hold pitch and cutoff, ramp the amp | Hold the cutoff only | Hold the pitch only |
| --- | ---: | ---: | ---: | ---: |
| pluck | fails at 2 | 2 | 16 | any |
| string | 4 | 32 | 32 | 64 |
| brass | 2 | 2 | 2 | 8 |
| release | 2 | 8 | any | any |
| sustain | any | any | any | any |
| vibrato | 16 | 16 | any | 16 |

Three findings, one per control. **The amp cannot be held at all**: the
fastest attack changes the amplitude by four percent per sample, and one
frame of lag is already outside the bounds. Ramped linearly across the
block it is exact wherever the ramp is straight, which is the whole ramp
except the frame where it reaches its target and the frame where the next
segment starts; those corners are what fails the pluck at four frames.
The kernels ramp it now, and the host ends a record wherever a ramp
bends, which it knows because it runs the envelopes: the exact kernels add
each record's slope to their two amp words every frame, two cycles, and
the perceptual ones multiply the sum by a factor that a per-frame
multiplier of 2^(∓slope/4096) carries from one end of the record to the
other, five cycles; the last line of every scenario below is what that
buys. **The cutoff is the control that sets the block length**: a
TVF attack at the fastest setting moves 32 levels in 32 frames, which held
per block is a staircase of a quarter of the range, and re-deriving the
constants per frame costs what the whole partial costs. Sixteen frames
keep even that attack inside the bounds; 32 keep the slower sweeps of the
string and the release. **The pitch is already block-rate**: Munt updates
it every eight samples, so eight is exact, and what fails the brass at
sixteen and beyond is a phase lag of a fraction of a sample on a sawtooth,
which the bounds count word for word — its correlation stays above 0.999
and its spectral cosine at 1.000 through 32 frames, the string passes 64
outright, and a plain vibrato of 18 cents passes 16.

So the control rate is **sixteen frames**, 0.49 ms, with the amp ramped
per frame inside the block; 32 frames serve when no filter envelope is in
its attack. That is twice the rate the MT-32's own MCU uses for pitch and
about the rate its envelopes need.

The second is measured on the DSP (`make profile-control CFG=n NCODE=m`).
The host hands the DSP a run's static constants and one record per block
of the frames it holds for, amp >> 10, the amp's slope per frame, pitch
and cutoff >> 3 — the words a host running the envelopes would send — and
the DSP derives the kernel's constants from each record before rendering
its frames: `la32_block_derive` reproduces
`getSampleStep`, the effective cutoff, the resonance wave-length factor,
the segment lengths and the two log bases from the same exponent table the
unlog reads. It derives only what the record changed — the step when the
pitch moved, everything the cutoff feeds when the cutoff moved, the amp's
two words and the perceptual gain always, since the amp moves in every
envelope phase — with the data-dependent right shifts as multiplies by a
power of two from a table and the block's kernel entered through a stored
address, and for the amp ramp the exact kernels' two amp words one slope
before the record's first frame, the perceptual kernels' factor and its
per-frame multiplier from a 1,024-word table of 2^(±s/4096), and the
perceptual gain itself from the gain table the resonance reads, at the
bin the amp term's top twelve bits name — one read, with a quantization
of a sixteenth of a percent the resonance already carries. Every one of
the 60 runs — six scenarios, both kernels, blocks of 8, 16, 32 and 64 and
the adaptive stream below — matches the oracle following the same record
schedule, the exact kernel word for word; one detail of Munt's order had
to be copied for that, namely that a sample's pitch and cutoff reach the
wave position one sample after its amp, so a record's position constants
are installed after its first frame, and a record whose position
constants did not change is rendered in one call. The ramp costs the
kernels 2 cycles per frame in the exact ones, 77 and 100 becoming 79 and
102, and 5 in the perceptual ones, 53 and 64 becoming 58 and 69. Per
record, at sixteen frames:

| Per record, one partial | Filter moving (pluck, string, brass) | Vibrato only | Settled |
| --- | ---: | ---: | ---: |
| Derivation, exact kernel | 191 – 221 | 81 | 58 |
| Installing the position constants | 20 | 14 | 0 |
| Record loop, kernel entry and exit | 44 | 36 | 20 |
| **Total, exact kernel** | **255 – 285** | **131** | **78** |
| **Total, perceptual kernel** | **296 – 330** | **171** | **118** |

The perceptual kernel's extra is its gain, its ramp's factor and the
factor's start, three table reads and the arithmetic around them; a first
version took the gain and the start from the exponent table and cost 60
cycles more. The first version of the derivation cost 303 cycles per
block whatever the record did; deriving on change and trading the `rep`
shifts for multiplies took the worst case down by a fifth and the settled
note by three quarters. What the worst case keeps is the arithmetic of the
cutoff: two exponent lookups with their shifts, the segment lengths, the
two log terms, about 130 cycles of it, and no note spends long there — a
filter attack lasts tens of milliseconds, a sustain the rest of the note.

The rest of the saving is the host's. It looks at each partial every
sixteen frames, at every start of a ramp segment and at every bend of a
ramp, and sends a record — with the frames it holds for and the amp's
slope — only where the pitch or the cutoff moved, a segment starts or
bends, or the amp left the line the last slope predicts; the DSP renders
those frames in one call and never derives anything for a partial whose
controls stand still. Against fixed sixteen-frame blocks, per frame and
partial:

| Scenario | Records, of 128 looks | Fixed blocks of 16, exact | Records on change, exact | perceptual |
| --- | ---: | ---: | ---: | ---: |
| pluck, filter attack and decay | 137 | 16.0 | 16.9 | 19.6 |
| string, slow swell with vibrato | 131 | 16.6 | 17.0 | 20.7 |
| brass, filter sweep with a wide LFO | 138 | 17.8 | 19.1 | 22.0 |
| release, both controls settling | 31 | 6.2 | 3.0 | 3.6 |
| sustain, everything settled | 2 | 4.9 | 0.17 | 0.21 |
| vibrato over settled amp and cutoff | 91 | 8.2 | 6.8 | 8.6 |

A moving control costs what it cost, and a filter attack or a swell moves
every look; a settled note costs the kernel and nothing else. Six
perceptual partials at the sixteen-frame rate therefore cost about 125
cycles per frame while their filters move, 50 under vibrato, and one
settled. "About 20" was the right guess for a note's sustain and wrong by
a factor of six for its attack, and what a real note costs is the
attack's share of its length.

What the design is worth against Munt's per-sample controls is the last
line of each scenario in the sweep: the records on change with their
ramps leave the pluck 10 words and -88 dB from the per-sample render, the
release 1 word, the sustain none, the string 28 words and the vibrato 25,
all inside the bounds; the brass stays at 360 words and -57 dB with a
correlation of 0.9997 and a spectral cosine of 0.9999, which is the phase
lag of a wide, fast vibrato held for sixteen frames on a sawtooth, the
pitch's doing and not the amp's.

## The arithmetic that follows

The total is 489.40 cycles per codec frame. Corrected room reverb and
transport consume 152 + 14.81 = 166.81, leaving **322.59** before partial
rendering and controls. Charging controls to each active partial gives:

| Kernel | Settled square | Settled saw | Moving square (+22) | Moving saw (+22) |
| --- | ---: | ---: | ---: | ---: |
| Exact | 4 | 3 | 3 | 2 |
| Approximate | 5 | 4 | 4 | 3 |

These are floored homogeneous partial counts, not complete-note polyphony.
The 68030 has a separate limit: uploading the mixed period takes 2.33 ms,
leaving at most 13.29 ms before MIDI and control work. Exact PCM takes
4.67 ms per partial, so only **two** fit; approximate PCM at 3.89 ms permits
three before controller overhead.

A faithful live implementation therefore targets **2�4 synth partials plus
up to 2 PCM partials**, depending on waveform and envelope activity. A partial
slot in one pool cannot pay for a partial in the other. Many factory patches
use two to four partials, so **roughly 1�3 typical notes** is a planning range.
One-partial square patches can exceed that; a four-saw patch exceeds the
attack budget even for one complete note. Ring modulation, combined memory
layout and the live controller still need implementation and measurement.

The offline renderer has no per-frame deadline and can retain the normal
MT-32 **32 partials**, or 8�32 notes according to patch structure. Its ability
to render does not establish real-time feasibility.

## Earlier optimisation analysis (historical budgets)

The numerical examples in this section predate the reverb overflow fix and
SSI clock correction. Use the current budget above for capacity planning.
Fewer partials is no longer a lever but
the starting condition, and the partial itself is close to its floor.

1. **Cheaper control.** Done: deriving only what changed and replacing the
   `rep` shifts took a filter attack's record from 303 cycles to 250 – 280
   in the exact kernel, the host sending a record only where a control
   moved took a settled partial from 4.4 cycles per frame to 0.17, and the
   amp ramps inside the record for 2 cycles per frame in the exact kernels
   and 5 in the perceptual ones, and the perceptual kernel's gain and its
   ramp's start come from the gain table's bins, one read each, which took
   its records from 60 cycles over the exact kernel's to 40. What is left
   is about 40 cycles of the attack path in long-addressed loads and
   two-word immediates that a tighter register allocation could shave.
2. **Move work between the halves.** The DSP is the busier chip in the
   planned configuration, at about 95 % with six partials and the reverb,
   and the host at about 90 % with three PCM partials and the transport,
   before MIDI, envelopes and allocation; neither has idle time to give
   the other. The one exchange that pays is the PCM partials' pan and mix:
   rendered mono on the host they cost 2.94 ms instead of 3.89, and a DSP
   that takes each partial as its own 512-word stream pans and mixes it for
   6 cycles per frame — the 3 of the receive interrupt, a read and two
   multiply-accumulates — where the host paid 47 for two multiplies and 9
   for a store. The host pays the stream instead, 1.16 ms per partial and
   period with the paced blast, about 0.8 with blind writes, which TOS's
   own block transfer already relies on:

   | Design | Host time for N PCM partials | N that fits 15.62 ms | DSP cycles per frame |
   | --- | --- | ---: | ---: |
   | stereo mix on the host | 2.33 + 3.89 N | 3.4 | 0 |
   | mono streams, DSP pans, paced | 4.10 N | 3.8 | 6 N |
   | mono streams, DSP pans, blind | 3.71 N | 4.2 | 6 N |
   | one mono bus per part, DSP pans, blind | 2.94 N + 0.77 parts | 4.4 at three parts | 6 parts |

   One PCM partial more on the host for about a quarter of a synth
   partial on the DSP, which is worth it only because the PCM side is the
   tighter one. Everything else stays where it is: the interpolation needs
   the ROM, the envelopes need the timbre and the note, and the polled
   receive's 59 cycles of waiting are not idle time to spend but a cost the
   interrupt receive removes.
3. **A cheaper reverb.** The reverb is now the largest single item after the
   partials themselves. Its clip, its dry and wet scalings and its exact
   floors are the price of matching Munt word for word; a perceptual reverb
   with the same delay lines could drop the clip and merge the scalings for
   perhaps ten to fifteen cycles, and running it at half rate is worth an
   experiment against the oracle before it is ruled out.
4. **A lower internal rate.** Prescale 3 gives 24,584.96 Hz and 652.5
   cycles per frame, one third more partials for the top octave. Last
   resort, and it interacts badly with comparing against an oracle.

## What is affordable

**The tables.** Either partial kernel's tables are affordable next to the
reverb; the two together with the period buffers and the program take most
of the SRAM, and the partial spike's image, which carries both kernels, is
24K words. The reverb spike's image is 5K words plus its delay lines. All of
it is delivered by the stage-two loader at the P alias of its X and Y homes,
so nothing copies at run time except the exact kernel's first exponent page,
which lives in internal X.

**The PCM ROM is the problem**, and it is not a budget question but an
absolute one: 262,144 samples against 32,768 words of SRAM.

## Reproducible gates and remaining integration

- `make profile-partials`: exact 79/102, approximate 58/69, room reverb 152.
- `make check-reverb`: six long overflow regressions against Munt.
- `make profile-transport`: 14.81 cycles/frame, verified interrupt word count.
- `make profile-pcms`: 4.67 ms exact and 3.89 ms approximate PCM per period.
- `make control-sweep` and `make profile-controls`: held-control error and
  per-record cost, with per-sample amp ramps.
- `make check-rom-renderer`: complete short ROM/MIDI renders on a 4 MiB
  FPU-less Falcon, compared with the workstation.
- `make check-player`: every file sample uploaded correctly, cache refills,
  final-period draining, and invalid-file rejection.

The live synth still needs a combined memory layout, scheduling, ring-pair
integration, control delivery and MIDI reception. The current full-fidelity
execution path is offline rendering followed by DSP file playback. A real
Falcon is still needed to verify sound routing, disk latency and hardware
timing; Hatari results alone do not close those checks.

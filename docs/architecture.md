# Architecture

Everything below the "Implemented" heading is a **proposal**. The transport is
built and gated; the synthesizer is not started. Where a claim rests on
evidence, the evidence is named; where it does not, it says so.

## Ownership

| Side | Owns |
| --- | --- |
| 68030 | MIDI reception, SysEx, the MT-32 control surface, part/timbre/patch state, partial allocation, and PCM partial rendering |
| DSP56001 | LA32 synth partial generation, the BU3905 mixer, the Boss reverb, saturation, and SSI transport |

This is the same seam F030MXDRV uses, where the 68030 runs an MXDRV-compatible
sequencer and the DSP is the YM2151. The reason it transfers is that the MT-32
has the same shape: a microcontroller running control firmware in front of a
dedicated sound chip. Munt already draws the line in that place — it
reimplements the 8095 firmware's behaviour in C++ rather than emulating the
8095, and reads the control ROM only for its data tables. The port should do
the same on the 68030. An 8095 interpreter at 16 MHz would be a second budget
problem on top of the one that already matters.

The one place the analogy breaks is PCM, and it breaks hard. See
[The PCM ROM problem](#the-pcm-rom-problem).

## Rates and the resampling decision

The Falcon codec runs at 25,175,000 / 256 / (prescale+1). Prescale 2 gives
**32,779.947916 Hz**, the closest available rate to the MT-32's 32,000 Hz.

Native and codec time are related by an exact small ratio:

```text
32000 : 25175000/768  =  24576 : 25175      (coprime)
```

So one codec frame is exactly 24576/25175 native samples, and a 25175-frame
DDA period is drift-free forever.

There are two ways to use that, and the choice matters:

- **Render at 32,000 Hz and resample.** Faithful to the hardware rate, but
  costs a resampler on the hottest path and buys a 2.4 % rate difference that
  nothing audible depends on.
- **Render at codec rate with pitch scaled by 24576/25175, and use the DDA only
  for control timing.** No resampler, exact long-term pitch, exact long-term
  envelope and LFO timing. This is what F030MXDRV's production kernel does, and
  it is the recommended choice here.

The second option is not free of consequences and they should be written down
before anyone is surprised by them:

- Everything derived per output sample runs 2.44 % more often, so the cycle
  budget per *native* sample is 2.44 % smaller than the naive figure.
- The reverb's delay lines are specified in samples. Running the same lengths
  at codec rate shortens every delay by 2.4 %. That is inaudible for a reverb
  and is the cheap choice; resampling the reverb alone is not worth it.
- Anything compared sample-for-sample against Munt has to account for the rate
  difference explicitly. That belongs in the oracle harness, not in the kernel.

## One transport period

| Quantity | Value |
| --- | --- |
| Codec rate | 32,779.947916 Hz |
| Period | 512 stereo frames = 15.62 ms |
| Buffer | 1024 interleaved 24-bit words, 1024-word aligned |
| Buffers | two, in external DSP X memory at `x:$1000` and `x:$1400` |

The SSI transmit interrupt walks the active buffer with `r6` modulo 1023, so
the active period **repeats** until something replaces it. A renderer that
misses its deadline therefore costs one repeated period and never a torn one.
The swap happens only at a stereo-frame boundary: `ssi_perform_handoff` masks
the interrupt, drains the transmitter, emits the right-channel word if the
pointer stopped on an odd slot, and only then re-points `r6`.

Samples are 16-bit signed values left-justified in the 24-bit word, because the
SSI is configured for a 16-bit word length (`CRA = $4100`) and transmits the
top 16 bits. Both the DSP tone table and the host's period builder produce
words in that position, so neither path shifts in its inner loop.

## Host/DSP protocol v1

Every transport unit is one 24-bit word whose upper byte is an opcode. The
canonical list is `src/dsp/protocol.inc`, mirrored byte for byte in
`src/m68k/protocol.i`; `make check` diffs them.

| Word | Meaning | Reply |
| --- | --- | --- |
| `01 00 00` | ping / protocol query | `4d 54 01` (`MT`, version 1) |
| `02 00 00` | reset transport state | `00 00 00` |
| `03 ss ss` | set the test-tone phase step | `00 00 00` |
| `04 00 00` | start the DSP-generated tone | `00 00 00` |
| `05 00 00` | start host-fed playback | `52 44 59`, then `00 00 00` |
| `06 00 00` | supply one more host period | `52 44 59`, then `00 00 00` |
| `07 00 00` | stop the codec | `00 00 00` |
| `08 00 00` | query codec frames emitted | count, modulo 2^24 |
| `09 00 00` | query completed period handoffs | count |

`52 44 59` (`RDY`) is a parked-receiver token and is load-bearing, not
decoration: TOS 4.02's `Dsp_BlkUnpacked` polls TXDE only before the first word
of a block and writes the rest blind, so a DSP receive loop that starts late
silently loses a word — after which the host waits for a reply that never
comes. Every multi-word upload is gated on that token, and the host paces each
word on TXDE itself (`dsp_blast_paced`) rather than trusting the XBIOS call.
F030MXDRV lost real hardware time to this; Hatari does not reproduce it,
because its DSP has no host-port wait states.

Opcode `0a` is the LA32 profile spike (`MT32_CMD_PROFILE_PARTIAL`, see
[`la32-budget.md`](la32-budget.md)); `0b` upwards are unallocated and are
where the synthesizer goes.

## Boot

`Dsp_ExecBoot` installs at most 512 words in internal P RAM, and the
converted-LOD path TOS offers has an 8 KiB ceiling that an LA32 kernel will not
fit under. So the executable embeds a small first-stage loader and the complete
sparse program image:

1. `Dsp_ExecBoot` resets the DSP and installs `stage2_loader.asm`, whose reset
   vector jumps to `P:$0040`.
2. The loader reads magic `$4d544c` (`MTL`), a section count, then
   address/count/data records, writing each into P memory.
3. It replies `$4c4f41` (`LOA`) and jumps through `P:$0000`, which the final
   program has by then replaced.

The final program therefore starts at `P:$0080`, leaving `P:$0040-$007f` for
the transient loader. `tools/generate_dsp_stage2.py` enforces all of that at
build time and refuses overlapping sections, a bootstrap above the 512-word
limit, non-P sections, and sections outside 16-bit P memory.

## DSP memory map

| Space | Range | Contents |
| --- | --- | --- |
| P | `$0000-$003f` | reset and interrupt vectors |
| P | `$0040-$007f` | reserved for the transient stage-two loader |
| P | `$0080-$01ff` | internal: the four LA32 partial render loops |
| P | `$0200-$05ff` | external: command loop, transport, profile command |
| P | `$0700-$07ff` | LA32 constant and run configuration images |
| P | `$0800-$08ff` | test-tone table image, aliased to `Y:$0800` |
| P | `$0900-$3bff` | LA32 Y tables — gain, resonance, windows, signed sine — aliased to the same Y addresses |
| P | `$4000-$4fff`, `$6000-$783f` | LA32 X tables — exponent, square values, cosine, power — aliased to `X:$0000` and `X:$2000` upwards |
| X | `$0000-$00ff` | internal: first page of the exponent table, copied from P at boot |
| Y | `$0000-$003f` | internal: scalar transport state, LA32 constants and configuration |
| X | `$1000-$13ff` | external: period buffer A, and the profile spike's output |
| X | `$1400-$17ff` | external: period buffer B |

Two Falcon facts shape this and both are carried over from F030MXDRV rather
than rediscovered here:

- **Initialized data can only be shipped in P.** The stage-two loader
  transports P sections; there is no X or Y record type. Anything that has to
  start with a value either lives in P and is copied at boot (as the LA32
  constants are), or is uploaded at runtime over the protocol (as F030MXDRV
  uploads its ymfm tables), or — the way every large LA32 table and the tone
  table arrive — is assembled at the P address that aliases its X or Y home,
  so the loader delivers it in place. Uninitialized state uses `ds`, which
  emits nothing.
- **External P, X and Y alias one 32K SRAM.** External P maps to the SRAM
  directly, external Y onto the same lower 16K word for word, and external X
  onto the upper 16K at `phys = addr + $4000`. Placing code and data in the
  same physical word is a silent corruption, not a build error, so the
  generator's overlap check is the only thing standing between a grown kernel
  and a corrupted table. F030MXDRV's bus probe confirmed the decode on a
  physical Falcon on 2026-09-02 (`F030MXDRV/docs/hatari-timing.md`), which
  is what makes the alias delivery above safe to rely on.

## The PCM ROM problem

This is the one structural difference from F030MXDRV, and it is not a detail.

An MT-32 timbre is up to four partials arranged in two structure pairs, and a
partial is either a synthesized wave or one of the ROM's PCM waves. From the
vendored Munt source:

- the PCM ROM is 512 KiB holding **262,144 16-bit logarithmic samples**
  (`Synth::loadPCMROM`, `ROMInfo.cpp`);
- there are **128 PCM waves** on the MT-32 and 256 on the CM-32L
  (`ControlROMMaps`);
- each wave starts at `pos * 0x800` and is `0x800 << lenExp` samples long, so
  the shortest is 2048 samples, and waves may loop
  (`Synth::initPCMList`).

The Falcon's DSP has 32,768 words of SRAM in total, shared between P, X and Y.
Even with no program and no buffers, under an eighth of the PCM ROM could be
resident. Caching per timbre change does not rescue it either: 32 partials can
reference 32 distinct waves, and one wave alone can be larger than the whole
SRAM.

So a DSP-side PCM voice is impossible on this machine, and the port needs a
different seam for exactly one part of the chip. Two candidates:

- **Stream the ROM windows.** The 68030 pushes the source samples each PCM
  partial will need next period and the DSP interpolates. Bandwidth scales with
  the pitch ratio and the active partial count — roughly 1024 words per partial
  per period at the top of the range — which is implausible against the
  measured host-port cost. Not recommended.
- **Render PCM partials on the 68030** and push their mixed contribution as one
  stream per period, the way F030MXDRV decodes MSM6258 ADPCM on the 68030 and
  hands the DSP planar PCM. The ROM stays in 68030 RAM where 512 KiB is
  unremarkable, the link carries a fixed 512 frames per period regardless of
  how many PCM partials are sounding, and the DSP spends its cycles on the
  synth partials it can actually afford.

The second is the recommendation. It has a cost that must be stated: PCM
partials then run through 68030 code rather than the LA32 model, so their TVA
and pitch behaviour has to be made to agree with Munt separately from the synth
partials, and the structure pairs that ring-modulate a PCM partial with a synth
partial straddle the split. Those two cases are the reason this is a proposal
and not a decision.

## Producer/consumer pipelining

The scaffold's host loop is synchronous: `command_refill_stream` receives a
period, acknowledges it, waits for the boundary, hands off, and only then
returns to the stream loop, so the 68030 blocks on the codec. That is correct
and it is enough to gate the transport, but it leaves the 68030 idle for most
of every period and gives a late renderer no slack at all.

F030MXDRV's production path solves this and the solution transfers directly:
the host keeps one completed payload *announced* to the DSP (its command word
parked in the receive register) and one more *queued* behind it while it
prepares a third, and delivers from sequencer seams and from a timer interrupt.
The DSP, in turn, receives the next parked payload during the previous period's
boundary wait. A period whose preparation overruns its slot then borrows idle
time from two neighbours instead of pushing finished audio past the render
deadline.

Adopting it here is deferred until there is something to pipeline. It is the
first thing to port once synthesis exists, not an optimization to leave for
later: F030MXDRV's measurements show the receive moving into the boundary wait
changes where the cycles are *counted*, not just when they are spent, and every
occupancy figure depends on which model is in force.

## Implemented

Only this much runs:

- two-stage DSP boot and the v1 handshake;
- the codec transport described above, both buffers, and the handoff;
- a DSP-side 256-entry sine and a host-side square wave, as sources;
- frame and period counters, readable while audio is running;
- Falcon sound-matrix setup and restoration on every exit path;
- a Hatari smoke gate that scores the whole sequence from the emulator's own
  host-port and XBIOS traces;
- one LA32 synth partial with block-held controls in two kernels, one
  bit-exact against Munt and one perceptual within a few output words of it,
  rendered on command into a buffer for the profiler and the oracle
  comparison — a measurement, not a voice: it has no envelopes, no pitch
  updates, no allocation, and it never reaches the codec.

No MIDI, no ROM handling, no envelopes, and no oracle beyond the wave
generator.

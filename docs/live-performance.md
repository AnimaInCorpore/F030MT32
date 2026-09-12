# Live performance and SSI DMA assessment — 2026-09-12

**30 faithful live partials are not supported by the stock Falcon budget.**
The changes here reduce exact PCM rendering by about 14% and the exact DSP
saw kernel by 3 cycles per sample. SSI DMA can remove the host-port audio
upload, but it does not remove waveform generation, interpolation, envelopes,
or reverb. Live scheduling, MIDI reception, ring pairs and a combined DSP
image are still unfinished. These are component measurements, not a working
MIDI MT-32 replacement or a demonstrated live polyphony count.

## Sound-preserving changes

The baseline is the existing working tree, including its earlier uncommitted
optimizations, built separately from other running benchmarks. Both before
and after use the DSP-calibrated Hatari build at a 16 MHz 68030, 4 MiB for
PCM, and the same Munt oracle fixtures.

| Exact kernel | Before | After | Improvement |
| --- | ---: | ---: | ---: |
| PCM, slow loop, CPU cycles/frame | 145.41 | 122.37 | 15.8% less CPU |
| PCM, same run, ms/512-frame period | 4.64 | 3.91 | 0.73 ms saved |
| DSP saw, instruction cycles/frame | 95 | 92 | 3.2% less DSP |

The four exact PCM runs with a positive pan pair cost 122.26–123.24 CPU
cycles/frame, 3.90–3.93 ms per period; the negated pair's own copy of the
loop costs 126.57 and 4.04 ms. An intermediate version of this work, before
the second copy moved the loop's alignment, measured 124.25–124.66. Every
exact run equals Munt word for word. The other
current profile results are 72 cycles for exact square, 44/53 for approximate
square/saw (before their pan pass), and 83 for exact room reverb. The latter
improvements were already present in the baseline; this change does not
claim them as new savings. These results supersede the older numbers in
[the feasibility history](la32-budget.md).

The PCM kernels now read a guard sample immediately after each wave: the
first sample for a loop, silence for a one-shot. This removes the neighbour
boundary check per frame. Phase wrap and Munt's rule that the frame ending
a one-shot is already silent remain unchanged. The two ROM fixtures and
their linear copies grow by eight bytes in total.

Exact PCM uses the MT-32's complementary pan factors, whose sum is 8192 at
all 15 pan positions. After the left multiplication, it forms the right
**product** as `(sample << 13) - left_product`, then floors both products
independently. Subtracting an already-rounded left sample would be wrong.
Munt also negates both factors of the pair for partials 4-7 in every eight
when its nice partial mixing is off, which is how the renderer runs it;
that pair sums to -8192, and a second copy of the loop negates the shifted
sample for it, one `neg.l` per frame more. The generator rejects any other
pair; the arithmetic check covers all 1,966,080 combinations of signed
16-bit sample, MT-32 pan and polarity, including silence, negative values
and hard pans, and a fifth fixture renders the negated pair through the
oracle gate.

The exact saw kernel overlaps existing sign and log transfers with ALU work.
It keeps the same arithmetic, tables, precision, phase, sample rate and
control schedule. The complete partial profiles and two moving-control
saw scenarios still match the oracle exactly.

## What SSI DMA input buys

Atari's [Falcon developer documentation](https://www.atarimania.com/documents/Atari-Falcon030-Developer-Support-Package.pdf)
describes four stereo DMA playback tracks and the DMA-playback-to-DSP-receive
crossbar route. Individual 16-bit PCM partials can occupy the slots. The
CPU writes ST-RAM and the DMA feeds SSI; commands can continue to use the
host port. This is sound DMA into SSI, not a DMA controller in the DSP.

For the current stereo upload, removing the paced host-port transfer would
recover approximately **2.33 ms of each 15.62 ms period**, about 15% of the
68030's time. This is a projection using the existing transport measurement:
the probe below supplies a fixed buffer, so it does not measure live buffer
refills, packing, DMA bus contention during synthesis, or control overhead.

Using 3.91 ms as the measured exact PCM cost:

| PCM partials | CPU time with stereo host-port upload | Without that upload | Time left without upload |
| --- | ---: | ---: | ---: |
| 2 | 10.15 ms | 7.82 ms | 7.80 ms |
| 3 | 14.06 ms | 11.73 ms | 3.89 ms |
| 4 | 17.97 ms | 15.64 ms | does not fit |

Thus DMA principally gives **three exact PCM partials room for controller
work** in this model. Four would also need a cheaper renderer/output format.
Writing packed 16-bit words directly, or sending individual mono partials
and panning on the DSP, could help further, but neither is implemented by
these changes. Preserve the per-partial rounding, clipping and reverb-send
order when integrating those paths.

DMA reception still costs DSP cycles. The standalone probe keeps separate
receive and transmit word counters; each fast interrupt costs 4 instruction
cycles per word. It also measures the transmit side because the tested
multi-track configuration clocks additional output slots, even though only
the first stereo pair reaches the DAC. Counting receive alone understates
this implementation's cost.

| Slots/frame | RX + TX DSP cycles/frame | DMA payload at 32.78 kHz | Integrity result |
| --- | ---: | ---: | --- |
| 2 | 16.00 | 131,120 bytes/s | passes full stream and capture |
| 4 | 32.00 | 262,240 bytes/s | sample loss in calibrated Hatari |
| 6 | 47.99 | 393,359 bytes/s | sample loss in calibrated Hatari |
| 8 | 63.99 | 524,479 bytes/s | sample loss in calibrated Hatari |

The stereo run checks more than 104,000 received words while transmitting
silence through SSI to the DAC. For higher slot counts, the trace finds
skipped samples and displaced ring contents. These configurations are
**not qualified for integration**. This is not evidence of a physical
Falcon channel limit: the hardware, emulator scheduling and startup/stream
handling still need diagnosis under a real synthesis workload.

The calibrated Hatari source's `dsp_core_ssi_Receive_SC0()` maps receive
exceptions to ordinary receive interrupts. All runs report zero exception
counters, even when samples disappear. The gate therefore checks the entire
RX trace and the captured ring, not just status flags. It excludes debugger
reads of RX after the receiver is disabled. The program exits with failure
if any requested slot count fails sample integrity, while retaining reports
for every completed case.

The probe has its own DSP and host images and uses Vsync on the CPU. It does
not add DMA to the player or prove concurrent synthesis: its register owners
and period handoff still have to be integrated with the synthesis kernels.
The 4-cycle receive count includes a word counter; a bare MOVEP/NOP receiver
could cost 3, but then production code must obtain its timing elsewhere.

## Why this still does not reach 30

The DSP has **489.40 instruction cycles per codec frame**. Reserving the
measured 83-cycle room reverb and the stereo DMA probe's 16 cycles leaves
390.40. Thirty DSP partials would have only **13.01 cycles each**, before
controls and mixing. The exact kernels need 72/92; even the approximate
kernels need 44/53 before panning. DMA is not a five- to seven-fold synthesis
speedup.

With the existing 14.81-cycle host transport, the current exact cost-only
ceilings are five settled square or four settled saw partials; charging
22 cycles per moving partial reduces those to four or three. These are
homogeneous DSP partial counts. PCM has its own CPU limit, and the partials
used by a note cannot be reassigned freely between the two processors.
Extra DMA tracks also spend more DSP time. A 30-partial target would need a
substantially different, separately validated synthesis strategy or faster
hardware; reducing fidelity is not presented as an optimization here.

## Reproduce

- `make check-pcm-math`: exhaustive complementary-pan arithmetic.
- `make profile-pcms`: all fifteen exact/approximate/mono PCM oracle gates,
  one configuration at the negated pan polarity.
- `make profile-partials`: all ten synth/reverb oracle and quality gates.
- `make profile-control CFG=2 NCODE=4` and `CFG=5 NCODE=4`: adaptive brass
  and vibrato through the changed exact saw loop.
- `make smoke`: unchanged boot, SSI output and host receive transport.
- `make profile-ssi-dma SSI_DMA_CHANNELS=2`: passing stereo DMA capture.
- `make profile-ssi-dma`: diagnose all four track counts; currently fails
  sample integrity above stereo on the tested calibrated Hatari build.

DMA reports are written to `build/ssi-dma-profile/results.txt`, with separate
assembler, trace and profile logs per slot count. The binary stays under
`build/`; it is an emulator feasibility probe, not a hardware release.

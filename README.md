# F030MT32

F030MT32 aims to emulate a Roland MT-32 on an Atari Falcon030. The 68030 is to
run the control half — MIDI reception, part and timbre state, partial
allocation, and the PCM partial voices — while the Falcon DSP56001 runs the
LA32 wave generator, the mixer, the Boss reverb, and the SSI transport to the
codec.

The split, the two-stage DSP loader, the host/DSP word protocol, the
double-buffered 512-frame period transport and the build system are taken from
[`F030MXDRV`](../F030MXDRV), which plays Sharp X68000 MDX/PDX music by
emulating a YM2151 on the same DSP. That project is finished enough to be a
template; this one is not started.

## Project status

**This is a scaffold with one measured partial, not a synthesizer.** What
exists is the skeleton the synthesizer will be built inside, plus the
feasibility spike that decides how much of one fits:

- a DSP program that boots through the embedded two-stage loader, answers the
  v1 protocol, and drives the codec from two 512-frame stereo periods with a
  boundary-safe handoff;
- two audio sources for bring-up — a DSP-generated sine that needs no host
  data path at all, and a host-supplied square wave that exercises the block
  transfer — so the Falcon audio chain can be validated before any LA32 code
  exists;
- a 68030 program that boots the DSP, runs both sources, reports the codec
  frame and period counters, and restores the sound system on every exit path;
- the build system, the Hatari smoke gate, and the documented contracts;
- one LA32 synth partial on the DSP in two kernels — one bit-exact against
  Munt's integer model with its controls held per block, one perceptual —
  and the Boss reverb, bit-exact, in a second DSP image, with the native
  oracle and the Hatari profiling harness that measure all of them
  (`make profile-partials`), and a transport profile that sorts whole
  host-fed periods by what the DSP was doing (`make profile-transport`);
- one PCM partial on the 68030, in an exact, a perceptual and a mono
  kernel, checked against Munt from the file the program writes and timed
  by Hatari's CPU profiler and by the program's own tick count
  (`make profile-pcms`);
- the control rate: envelopes and vibrato rendered per sample and held per
  block by the oracle (`make control-sweep`), and rendered block by block
  on the DSP, which derives its constants from each block's amp, pitch and
  cutoff (`make profile-controls`).

Of the three questions that decide whether the project is possible, the first
two are answered and the answers are hard:

1. **One LA32 partial costs 77 DSP cycles per codec frame as a square wave
   and 100 as a sawtooth when it reproduces Munt bit for bit, and 53 and 64
   when it leaves the log domain through single-table lookups within a few
   output words of Munt; the reverb costs 92, the transport 12, and the
   controls, which must move every 16 frames, 15 per partial while its
   filter moves and nothing once the note has settled**, against a budget
   of 489.40 per frame. After the transport, the reverb and the control
   take their share, that is five to seven perceptual partials on the DSP
   — a few timbres at a time, not a nine-part module — and nothing that
   keeps the LA32's wave shape can reach the 15 cycles that thirty-two
   partials would need. See [`docs/la32-budget.md`](docs/la32-budget.md).
2. **The PCM ROM does not fit and never will, and the 68030 carries three
   PCM partials.** The ROM is 262,144 samples against 32,768 words of
   Falcon DSP SRAM, so the 68030 renders PCM partials and streams the
   result, exactly as F030MXDRV streams decoded PDX ADPCM. Measured, one
   such partial costs 4.67 ms of every 15.62 ms period bit for bit and
   3.89 ms perceptually, and feeding the DSP costs 2.33 ms more, so the
   host holds three of them before it parses a byte of MIDI. Together with
   the DSP's six synth partials that is the machine: a few timbres at a
   time.
3. **The oracle harness exists for the wave generator only.** Munt is
   vendored under `third_party/munt`; `tools/la32_partial_oracle.cpp` drives
   its LA32 model and `tools/la32_partial.py` compares the DSP's output with
   it word for word. Nothing compares envelopes, allocation or MIDI yet.

Treat every architectural statement in `docs/` as a proposal with its
evidence named, not as a description of working code.

## Legal position on the ROMs

The MT-32 needs Roland's control ROM (64 KiB) and PCM ROM (512 KiB). Those are
copyrighted firmware and are **not** part of this repository and must not be
committed to it. `roms/` is ignored, the way `corpus/` is in F030MXDRV; supply
your own dump from hardware you own.

`third_party/munt` is the Munt project. Its `mt32emu` library is LGPL-2.1;
this repository uses it as a build-time reference oracle only, and no Munt
code is linked into anything that runs on the Falcon.

## Build

The supported build flow expects a POSIX shell plus:

- Git with access to the two pinned submodules;
- Python 3, `make`, `tar`, `file`, and `rg`;
- a C++17 compiler for the Munt LA32 oracle, whose table dump the DSP
  build derives its lookup tables from;
- DOSBox Staging or DOSBox for Motorola's DSP assembler; and
- Hatari for the emulator gates — the DSP-calibrated build described in
  [`docs/hatari-timing.md`](docs/hatari-timing.md), because stock Hatari runs
  the Falcon DSP at twice its hardware speed.

On Windows that POSIX shell is MSYS2, and the build must run in its **UCRT64**
environment rather than MINGW64: `rg` and the C++17 compiler are packaged
there, and the two environments ship incompatible `libstdc++`/`libgcc`
runtimes.

Native GCC also resolves its temporary directory through `GetTempPath()`, which
reads `TMP` and `TEMP` and ignores `TMPDIR`. Recipes that inherit neither fall
back to the unwritable Windows directory, so export both to a writable
Windows-style path:

```sh
export PATH="/c/msys64/ucrt64/bin:/c/msys64/usr/bin:$PATH"
make --eval='export TMP := C:\Users\you\AppData\Local\Temp' \
     --eval='export TEMP := C:\Users\you\AppData\Local\Temp' check
```

DOSBox is needed only to run Motorola's DOS `ASM56000` binary, which lives in
the `f030dsp3d` submodule together with the archived vasm/vlink sources and the
TOS 4.02 image the emulator gates boot.

Initialize the dependencies and build:

```sh
git submodule update --init --recursive
make check
```

`make help` lists every target.

| Target | Purpose | Extra input |
| --- | --- | --- |
| `make all` | build the Falcon executable and the DSP image | DOSBox |
| `make check` | build everything and validate the generated artefacts | DOSBox |
| `make smoke` | score boot and transport under Hatari | Hatari |
| `make oracle` | build the native Munt LA32 partial oracle | C++17 |
| `make profile-partial CFG=n` | render run `n` on the DSP and report its cycle cost: runs 0-3 are the exact LA32 partial, checked word for word against the oracle, runs 4-7 the perceptual kernel on the same configurations, checked against error bounds, runs 8-9 the Boss reverb over run 1, word for word | Hatari |
| `make profile-partials` | the same for every run | Hatari |
| `make profile-transport` | profile 24 whole host-fed periods of the self-test and sort every DSP cycle into the SSI interrupt, the receive, the once-per-period work and the waits | Hatari |
| `make profile-pcm CFG=n` | render one PCM partial on the 68030, check it against the oracle and report its cost per period: runs 0-3 the exact kernel, 4-7 the perceptual one, 8-11 the mono one | Hatari |
| `make profile-pcms` | the same for every PCM run | Hatari |
| `make control-sweep` | grade held controls against Munt's per-sample controls with the oracle alone, for block lengths of 2 to 128 frames | C++17 |
| `make profile-control CFG=n NCODE=m` | render control run `n` (0-11: six scenarios, exact then perceptual) on the DSP with blocks of 8, 16, 32 or 64 frames (`m` = 0..3) or with records sent only where a control moved (`m` = 4), deriving the kernel constants per record, check it against the oracle's held render and report the kernel and per-record costs | Hatari |
| `make profile-controls` | the same for every run and block length | Hatari |
| `make verbose` | build the traced bring-up executable | DOSBox |
| `make run` | launch the self-test executable in Hatari | Hatari |

The outputs are:

```text
release/f030mt32.tos  self-test, bring-up and profile program
release/f030mt32.ttp  the same program with a Desktop command-line entry
release/mt32verb.tos  the traced build, from `make verbose`
release/la32.lod      readable DSP assembler artifact, the partial image
release/reverb.lod    the same source assembled as the reverb image
```

`make clean` removes only generated `build/` and `release/` content. `roms/`
is ignored and is never removed by that target.

## Run on a Falcon or in Hatari

With no command tail the program runs a fixed, non-interactive self-test: it
boots the DSP, plays the DSP-generated tone for forty vertical blanks, reports
the codec frame and period counters, then feeds thirty-two host-supplied
periods through the same transport and reports again.

```text
F030MT32.TTP           scored self-test, exits on its own
F030MT32.TTP TONE      hold the DSP tone until a keypress
F030MT32.TTP STREAM    hold the host-fed square wave until a keypress
```

Only the first letter of the tail is examined, so `T` and `tone` also work and
anything else falls back to the self-test. A `PROFILE.CFG` beside the program
selects a profile spike instead, which is how the profile targets drive it,
because Hatari's autostart carries no command tail: one digit runs that
LA32 configuration on the DSP, `P` and two digits render that PCM run on
the 68030, write its frames to `PCMOUT.BIN` and print how many 200 Hz
ticks the timed render took — on a real Falcon as well as under Hatari —
and `C`, a run digit and a block-length digit render that control run on
the DSP.

Counters that stay at zero mean the SSI never clocked — the failure mode
F030MXDRV chased onto real hardware and eventually traced to Port C pins left
in GPIO mode. Both sources restore MFP state, DSP SSI, crossbar routing, codec
attenuation and sound-lock ownership on every exit path, including the failure
ones.

## Architecture

The 68030 will own MIDI input, the MT-32 control surface, part and timbre
state, partial allocation, and PCM partial rendering. The DSP will own the
LA32 wave generator, the mixer, the reverb, and SSI transport. A small command
transport is the only coupling between them.

Protocol v1 uses 24-bit host words with an opcode in the upper byte. One
transport period is 512 stereo frames — 15.62 ms at the Falcon's
32,779.947916 Hz codec rate — held in two 1024-word buffers in external DSP X
memory, with the SSI output pointer running modulo one buffer so a late
renderer costs a repeated period rather than a discontinuity.

See [`docs/architecture.md`](docs/architecture.md) for the protocol, the memory
layout, and the reasoning behind the split.

## Verification model

The intended contracts, in the order they have to be established:

1. **Transport.** Boot, handshake, codec cadence, and period handoff, scored
   under Hatari by `make smoke`.
2. **Feasibility.** Measured DSP cycles for one LA32 partial, the reverb, and
   the transport against the 489.40-cycle frame budget, before any synthesis
   is committed to. The partial and the reverb are measured:
   `make profile-partials` renders four configurations with each partial
   kernel and the reverb at two settings, requires the exact kernels to
   equal Munt's output word for word and the perceptual one to stay within
   its error bounds, and reports 77 and 100 cycles per frame for the exact
   partial, 53 and 64 for the perceptual one, 92 for the reverb.
   `make profile-transport` measures the transport across whole host-fed
   periods: 20 cycles per frame of DSP work with the scaffold's polled
   receive, 12 with a receive by interrupt, and 59 more stalled on the
   68030 as long as the receive polls. `make profile-pcms` measures the
   host's half: 4.67 ms per period for an exact PCM partial, 3.89 for a
   perceptual one, 2.94 for one left unpanned for the DSP, all checked
   against Munt from the file the program writes. `make control-sweep`
   finds the control rate against Munt's per-sample envelopes, and
   `make profile-controls` measures the DSP deriving its constants per
   record, only what the record changed, from a host that sends one only
   where a control moved: 240 to 270 cycles per record and partial while
   the filter moves, none once the note has settled, bit-exact.
3. **Conformance.** Sample-level agreement with Munt at selected checkpoints
   for whatever subset the budget admits, then a perceptual gate for the
   production renderer — the same two-tier split F030MXDRV uses against
   MAME/ymfm. Both tiers exist for the wave generator alone; see the bounds
   in `tools/la32_partial.py`.

## Repository map

- `src/dsp/la32.asm`: scaffold DSP kernel — protocol, codec transport, test
  tone, the exact and perceptual LA32 partials behind the profile spike, and
  the Boss reverb; `src/dsp/reverb.asm` assembles the same source as the
  reverb image.
- `src/dsp/stage2_loader.asm`: sparse embedded P-memory loader.
- `src/dsp/protocol.inc`, `src/m68k/protocol.i`: the one host/DSP contract in two syntaxes.
- `src/m68k/main.s`: Falcon bootstrap, sound matrix, self-test, bring-up and profile modes.
- `src/m68k/dsp_link.s`: paced host/DSP transfer.
- `src/m68k/pcm_partial.s`: the exact and perceptual PCM partial kernels
  behind the 68030 spike.
- `tools/la32_partial_oracle.cpp`, `tools/la32_partial.py`: the Munt LA32
  oracle, the DSP table and configuration generator, and the word-for-word
  comparison; `tools/pcm_partial.py` does the same for the 68030 PCM runs
  and reads their CPU profile; `tools/control_rate.py` defines the control
  scenarios, grades held against per-sample controls and builds the DSP
  runs' payloads; `tools/profile_dsp.py` drives Hatari's DSP profiler and
  `tools/profile_transport.py` sorts a whole-period profile of the
  transport into work, stall and idle.
- `tools/`: also the DSP build driver, stage-two image generator and
  tone-table generator.
- `docs/`: architecture, MT-32 and MIDI ground truth, DSP and emulator notes.
- `tests/traces/`: fixture format for future MIDI conformance traces.

The pinned references under `third_party/` are not modified by the build.

# F030MT32

F030MT32 develops a Roland MT-32 emulator for the Atari Falcon030.

**Faithful MIDI file rendering and DSP playback now work as separate passes.**
`MT32REND.TTP` runs Munt on the 68030 with the supplied control and PCM ROMs,
all 32 partials, MIDI/SysEx, envelopes, allocation and reverb. It renders to
`MT32.PCM`; `F030MT32.TTP W` plays that file through the DSP and codec.
Rendering is much slower than real time on a stock Falcon. The same renderer
can run on the workstation to prepare files for Falcon playback.

See [the renderer guide](docs/falcon-renderer.md) for building, ROM filenames,
command lines, supported MIDI files and validation. A real Falcon has not
been tested yet; the current gates use calibrated Hatari with 4 MiB and no FPU.

## Real-time synthesis status

The assembly code remains a set of measured synthesis kernels and a working
transport. Live MIDI reception and real-time voice scheduling are unfinished.
The synth-partial and reverb kernels currently occupy separate DSP images.

The faithful real-time estimate is **2�4 synth partials on the DSP plus up to
2 exact PCM partials on the 68030**, depending on waveform and control activity.
That usually means roughly **1�3 complete multi-partial notes**, with some
four-partial patches exceeding a resource pool even for one note. These are
budget estimates, not a demonstrated live polyphony count.

Current measurements per codec frame are 79/102 DSP cycles for an exact
square/saw partial, 58/69 for the approximate kernels, 152 for corrected room
reverb, and 14.81 for interrupt-driven transport. Changing controls adds up
to about 22 cycles per partial. The total budget is 489.40. A PCM partial
costs 4.67 ms of a 15.62 ms period bit-exact, plus 2.33 ms per mixed stereo
upload. [The budget](docs/la32-budget.md) explains the limits and assumptions.

The hardware MT-32 has 32 **partials**, with one to four used per note, hence
8�32 simultaneous notes. MIDI's 16 channels do not specify a polyphony limit.
The offline renderer retains the full 32-partial pool because it does not
have a real-time deadline.

## ROMs and third-party code

ROM images are external inputs and are never embedded in an executable or
tracked in Git. `roms/`, generated output, and the supplied ROM archive are
ignored. The selected MT-32 1.07 control and PCM images match Munt's SHA-1
catalogue; the [renderer guide](docs/falcon-renderer.md) records their hashes.

`third_party/munt/mt32emu` is LGPL-2.1-or-later. The assembly player uses it
only as a build-time oracle; the separate `MT32REND.TTP` offline renderer
statically links it. Its source and licence notices remain in the pinned
submodule, and the Makefile retains the objects needed for relinking.

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
| `make renderer` | build the full native ROM/MIDI renderer | C++17 |
| `make falcon-renderer` | build the offline 68030 renderer | m68k-atari-mintelf-g++ |
| `make check-midi` | test SMF timing, merging and error handling | C++17 |
| `make check-player` | verify file decoding, all sample uploads and final draining | Hatari |
| `make check-rom-renderer` | compare complete short Falcon renders with native output | ROMs, cross C++, Hatari |
| `make check-reverb` | six long overflow regressions against Munt | Hatari |
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
release/f030mt32.ttp  the same program; W plays a rendered MT32.PCM file
release/mt32rend.ttp  full offline MIDI renderer, from make falcon-renderer
release/mt32verb.tos  the traced build, from `make verbose`
release/la32.lod      readable DSP assembler artifact, the partial image
release/reverb.lod    the same source assembled as the reverb image
```

`make clean` removes only generated `build/` and `release/` content. `roms/`
is ignored and is never removed by that target.

## Run on a Falcon or in Hatari

With no command tail the program runs a fixed, non-interactive self-test: it
boots the DSP, plays the DSP-generated tone for forty vertical blanks, reports
the codec frame and period counters, then checks continued codec timing through an 80-VBL host stall and feeds thirty-two host-supplied
periods through the same transport and reports again.

```text
F030MT32.TTP           scored self-test, exits on its own
F030MT32.TTP TONE      hold the DSP tone until a keypress
F030MT32.TTP STREAM    hold the host-fed square wave until a keypress
F030MT32.TTP W         play MT32.PCM from the offline renderer
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
   where a control moved, with the amp ramped every frame inside the
   record: 250 to 330 cycles per record and partial while the filter
   moves, none once the note has settled, bit-exact.
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

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

**This is a scaffold, not a synthesizer.** Nothing of the MT-32 is implemented.
What exists is the skeleton the synthesizer will be built inside:

- a DSP program that boots through the embedded two-stage loader, answers the
  v1 protocol, and drives the codec from two 512-frame stereo periods with a
  boundary-safe handoff;
- two audio sources for bring-up — a DSP-generated sine that needs no host
  data path at all, and a host-supplied square wave that exercises the block
  transfer — so the Falcon audio chain can be validated before any LA32 code
  exists;
- a 68030 program that boots the DSP, runs both sources, reports the codec
  frame and period counters, and restores the sound system on every exit path;
- the build system, the Hatari smoke gate, and the documented contracts.

The parts that decide whether the project is possible at all have not been
done. In order:

1. **The cycle budget is not established.** The Falcon DSP has 489.40
   instruction cycles per codec frame and the MT-32 has 32 partials. Nobody
   has yet measured what one LA32 partial costs on a DSP56001, so nobody knows
   what fraction of an MT-32 fits. See
   [`docs/la32-budget.md`](docs/la32-budget.md).
2. **The PCM ROM does not fit and never will.** It is 262,144 samples against
   32,768 words of Falcon DSP SRAM. The proposed answer — the 68030 renders
   PCM partials and streams the result, exactly as F030MXDRV streams decoded
   PDX ADPCM — is written down but not built or measured.
3. **No oracle harness exists.** Munt is vendored under `third_party/munt`
   as the intended reference implementation, but nothing compares against it
   yet.

Until those are answered, treat every architectural statement in `docs/` as a
proposal with its evidence named, not as a description of working code.

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
- a C++17 compiler once the Munt oracle harness exists;
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
| `make verbose` | build the traced bring-up executable | DOSBox |
| `make run` | launch the self-test executable in Hatari | Hatari |

The outputs are:

```text
release/f030mt32.tos  self-test and bring-up program
release/f030mt32.ttp  the same program with a Desktop command-line entry
release/mt32verb.tos  the traced build, from `make verbose`
release/la32.lod      readable DSP assembler artifact
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
anything else falls back to the self-test.

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
   under Hatari by `make smoke`. This is the only contract the scaffold
   currently exercises.
2. **Feasibility.** Measured DSP cycles for one LA32 partial, the reverb, and
   the transport against the 489.40-cycle frame budget, before any synthesis
   is committed to.
3. **Conformance.** Sample-level agreement with Munt at selected checkpoints
   for whatever subset the budget admits, then a perceptual gate for the
   production renderer — the same two-tier split F030MXDRV uses against
   MAME/ymfm.

## Repository map

- `src/dsp/la32.asm`: scaffold DSP kernel — protocol, codec transport, test tone.
- `src/dsp/stage2_loader.asm`: sparse embedded P-memory loader.
- `src/dsp/protocol.inc`, `src/m68k/protocol.i`: the one host/DSP contract in two syntaxes.
- `src/m68k/main.s`: Falcon bootstrap, sound matrix, self-test and bring-up modes.
- `src/m68k/dsp_link.s`: paced host/DSP transfer.
- `tools/`: DSP build driver, stage-two image generator, tone-table generator.
- `docs/`: architecture, MT-32 and MIDI ground truth, DSP and emulator notes.
- `tests/traces/`: fixture format for future MIDI conformance traces.

The pinned references under `third_party/` are not modified by the build.

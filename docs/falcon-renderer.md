# Faithful MIDI file rendering and Falcon playback

`MT32REND.TTP` runs the full ROM-backed Munt integer synthesizer on the
Falcon's 68030, writes the finished audio to disk, and exits. `F030MT32.TTP W`
plays that file through the DSP and Falcon codec. Rendering and playback are
separate passes. **Live MIDI synthesis is not implemented.**

The renderer retains all 32 MT-32 partials by default: 8 to 32 simultaneous
notes depending on the timbre's use of one to four partials. It supports the
Munt MIDI/SysEx control model, ROM presets, rhythm, ring modulation,
envelopes, voice allocation and all Munt reverb modes. This does not imply
that 32 partials can run in real time on a Falcon.

## Build and run

Build the DSP player with the normal tools, and the renderer with the
`m68k-atari-mintelf-g++` cross compiler:

```sh
make check check-midi
make falcon-renderer
```

Put these files together on the Falcon:

| File | Source |
| --- | --- |
| `MT32REND.TTP` | `release/mt32rend.ttp` |
| `F030MT32.TTP` | `release/f030mt32.ttp` |
| `MT32CTRL.ROM` | your full control ROM; tested with MT-32 1.07 |
| `MT32PCM.ROM` | your full MT-32 PCM ROM |
| `SONG.MID` | an MT-32 MIDI file |

Run `MT32REND.TTP` with an empty command tail. It renders `SONG.MID` into
`MT32.PCM`, with four seconds of release/reverb tail. Then run
`F030MT32.TTP` with `W` as the command tail. Any key stops playback. A
`PROFILE.CFG` containing `W` also selects playback, for unattended runs.

The renderer also accepts four paths:

```text
MT32REND.TTP CTRL.ROM PCM.ROM MUSIC.MID MT32.PCM
```

It refuses existing output files. Delete an old render deliberately or use
a new output name. The player currently opens `MT32.PCM` in its working
directory, so rename an alternate output before playback.

For practical turnaround, the identical renderer can run on the workstation:

```sh
make renderer
build/native/mt32rend.exe roms/mt32_ctrl_1_07.rom roms/mt32_pcm.rom song.mid MT32.PCM
```

Copy that finished file to the Falcon for playback. The output takes about
7.9 MB per minute of audio. The Falcon renderer uses disk output and bounded
audio buffers; it does not retain the whole rendered song in RAM. The test
configuration is 4 MiB ST-RAM with no FPU. Large MIDI event lists can still
exhaust that RAM and are reported as an allocation failure.

## Fidelity and limits

The synth runs at the original 32,000 Hz. Normal output uses Munt's accurate
analogue model, the appropriate generation of DAC bit ordering, and its
best-quality internal resampler to exactly 25,175,000/768 Hz. Enhanced amp
ramps, panning and partial mixing are disabled. MIDI cable delay is enabled
for both short messages and SysEx. These settings prioritise the hardware
model over speed.

The software floating-point resampler is very slow on a stock 68030. In the
short Hatari gate, a 341-frame codec render took 80.30 emulated seconds
including ROM loading and setup. This is a correctness path and a source of
reference audio for DSP development, not a real-time performance claim.
Rendering on the workstation avoids that wait.

Options before the paths:

| Option | Meaning |
| --- | --- |
| `--partials 1..32` | Set Munt's partial pool; default 32 |
| `--tail 0..30` | Fixed tail after the last track ends; default 4 seconds |
| `--digital` | Write 32 kHz stereo WAV from the pure digital DAC input, bypassing analogue processing and resampling; for comparison, not Falcon playback |

Supported MIDI files are SMF format 0 and 1, with PPQN tempo changes or SMPTE
timing, channel running status, and complete or split SysEx. Track ties are
ordered by track number. Format 2, multiple MIDI ports and standalone F7
escape events are rejected explicitly. Limits are 4 MiB of input, 65,536
events, 256 tracks, 32 KiB per SysEx and 30 minutes of MIDI time. The fixed
tail can truncate a sustained note or a particularly long release; choose a
longer tail when required. MIDI IN and real-time DSP voice scheduling remain
unimplemented.

Munt randomises the MCU pitch timer through the C library's `rand()`. The
small `src/host/munt_tvp.cpp` adapter supplies the same seeded sequence on
both targets, retaining that jitter while making comparisons repeatable.
The vendored source is unchanged.

## Validation

```sh
make check-midi             # does not need ROMs
make check-player          # Hatari, generated full-range PCM fixture
make check-reverb          # six long DSP/Munt overflow regressions
make check-rom-renderer    # ROMs, native C++, cross C++, Hatari
```

The ROM gate loads and renders with a 4 MiB, FPU-less Falcon configuration,
requires successful program exit, and compares complete output files. The
666-frame digital render matches byte for byte; the 341-frame codec render
is required to agree within one 16-bit LSB. These are short conformance
tests, not coverage of every patch or a substitute for real-hardware tests.

The player gate checks every host-port sample in an 8,705-frame fixture,
across three disk-cache reads, including negative samples, final padding,
and a silence handoff that lets the final period finish. It also rejects
truncated and incorrectly clocked files before starting audio. Disk latency
and the physical sound path still need a real Falcon test.

`F32P` file format: 16-byte header, then signed 16-bit interleaved L/R PCM.
All fields and samples are big-endian. Header fields are the four ASCII
bytes `F32P`, a u32 clock numerator (25175000), a u32 denominator (768), and
a u32 stereo-frame count. The player checks the exact rate and file size.

## ROMs and third-party code

The supplied archive contains 26 images whose SHA-1 hashes match Munt's ROM
catalogue. The selected full images in ignored `roms/` are:

| Image | Size | SHA-1 |
| --- | ---: | --- |
| `mt32_ctrl_1_07.rom` | 65,536 | `b083518fffb7f66b03c23b7eb4f868e62dc5a987` |
| `mt32_pcm.rom` | 524,288 | `f6b1eebc4b2d200ec6d3d21d51325d5b48c60252` |

ROMs and the supplied archive are excluded from Git. The renderer checks
full-image hashes through Munt and rejects incompatible control/PCM pairs.
CM-32L ROM pairs can be identified by Munt but have not been tested in the
Falcon gate.

Unlike the assembly DSP player, `MT32REND.TTP` statically links Munt's
LGPL-2.1-or-later library. Its copyright and licence texts are in
`third_party/munt/mt32emu/COPYING.txt` and `COPYING.LESSER.txt`. Keep these
notices and the corresponding source/build instructions with any
distribution. The Makefile retains separate objects in `build/falcon-render/`
and links against software-float base libraries, allowing Munt to be rebuilt
and relinked. No ROM data is embedded in either executable.

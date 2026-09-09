# MIDI: the surface the 68030 half has to implement

Two halves, and they are independent problems: **getting bytes off the Falcon**
and **doing what an MT-32 does with them**. The second is read out of the
vendored Munt source; the first is Atari hardware and is marked where it needs
confirming against the hardware manual rather than against this page.

Nothing on this page is implemented.

## Getting bytes off the Falcon

The Falcon inherits the ST's MIDI hardware: a 6850 ACIA at 31,250 baud, which
is the MIDI rate exactly, sharing an MFP interrupt with the keyboard ACIA.

| Register | Address |
| --- | --- |
| MIDI ACIA control / status | `$fffffc04` |
| MIDI ACIA data | `$fffffc06` |

There are two routes in, and the choice is the same trade F030MXDRV made for
its Timer-A tick:

- **Hook the OS.** `Kbdvbase()` (XBIOS 34) returns a vector table whose first
  entry, `midivec`, TOS calls for each received MIDI byte. Cheap, well-behaved,
  and it leaves the keyboard working. **Confirm the structure layout and the
  register convention against the hardware manual before relying on it.**
- **Take the ACIA directly.** More control over latency and over what happens
  when the synthesizer is busy, at the cost of owning the shared keyboard/MIDI
  interrupt and having to restore it on every exit path — including the failure
  ones, which is the part that is easy to get wrong.

Start with the OS hook. Move only if a measurement says the latency matters.

**A file player is the more useful first target regardless.** A Standard MIDI
File played from the 68030 needs no MIDI hardware, is deterministic, and can
therefore be gated under Hatari the way F030MXDRV gates MDX playback. Live MIDI
IN is the more impressive demo; the file player is the one that makes the
project testable. Build the file player first and treat live input as a second
source feeding the same event queue.

## What an MT-32 does with them

### Channel messages

Munt's `Synth::playMsg` handles these (`Synth.cpp`):

| Status | Message |
| --- | --- |
| `8n` | note off |
| `9n` | note on (velocity 0 is a note off) |
| `Bn 01` | modulation |
| `Bn 06` | data entry |
| `Bn 07` | volume |
| `Bn 0A` | pan |
| `Bn 0B` | expression |
| `Bn 40` | hold pedal |
| `Bn 62`, `63`, `64`, `65` | NRPN / RPN select |
| `Bn 79` | reset all controllers |
| `Bn 7B` | all notes off |
| `Bn 7C`–`7F` | mode messages |
| `Cn` | program change |
| `En` | pitch bend |

Parts are assigned to MIDI channels through the system area, not fixed; the
rhythm part is the ninth.

### SysEx

Roland's address-mapped protocol, with these bytes (`Synth.h`):

| Field | Value |
| --- | --- |
| Manufacturer | `$41` (Roland) |
| Device | `$10`, or the configured device ID |
| Model | `$16` (MT-32) |
| Command | `$11` request (RQ1), `$12` data set (DT1) |

`WSD`, `DAT`, `EOD` and `RQD` also appear in Munt's dispatcher and are refused
while partials are active. A message carries a three-byte address, the data,
and a checksum; Munt rejects a bad checksum outright.

The address map, from `MemoryRegion.h`:

| Address | Region | Entries |
| --- | --- | --- |
| `$030000` | patch temp | 9 |
| `$030110` | rhythm setup temp | 85 |
| `$040000` | timbre temp | 8 |
| `$050000` | patch memory | 128 |
| `$080000` | timbre memory | 64 |
| `$100000` | system area | 1 |
| `$200000` | display | — |
| `$7f0000` | reset | — |

The display region is not cosmetic. Games write to it, and an MT-32 that
silently drops those writes is detectably not an MT-32.

### Timing

This is the part most likely to be got wrong, because it is a behaviour rather
than a feature. Munt models the MT-32's own MIDI byte rate explicitly:

```c
static const double MIDI_DATA_TRANSFER_RATE = double(SAMPLE_RATE) / 31250.0 * 8.0;
```

The real machine takes real time to receive a SysEx block and real time to act
on it, and software written for it depends on that — the widely known "MT-32
needs a delay after SysEx" folklore is this behaviour seen from outside. A port
that applies parameter changes instantly is not more correct, it is differently
wrong, and the difference is audible in timbre uploads during playback.

Model the delay from the start rather than adding it after something sounds
wrong.

## Fixture format

`tests/traces/` holds timestamped MIDI byte streams, in the same plain-text
shape F030MXDRV uses for its YM2151 register traces: a comment header, then one
event per line as a native sample timestamp followed by MIDI bytes in hex.

```text
# native sample   midi bytes
0                 c0 00
0                 90 3c 64
32000             80 3c 40
```

Timestamps are in native 32,000 Hz samples so a fixture means the same thing to
the Munt oracle and to the Falcon, which runs at a different output rate; see
[`architecture.md`](architecture.md#rates-and-the-resampling-decision).

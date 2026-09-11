#!/usr/bin/env python3
"""Compare short ROM-backed renders on a 4 MiB, FPU-less Falcon with the host.

ROM inputs remain external and all copies/results stay under ignored build/.
The codec-rate resampler uses floating point, so that comparison permits one
16-bit output LSB. The digital integer render must match byte for byte.
"""
import argparse
import os
from pathlib import Path
import shutil
import struct
import subprocess
import wave

from check_midi import ROOT, smf


def run(command, cwd, log, timeout=120):
    with log.open("w") as output:
        subprocess.run([str(x) for x in command], cwd=cwd, stdout=output,
                       stderr=subprocess.STDOUT, timeout=timeout, check=True,
                       env=dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy"))


def launcher(directory, tail):
    source = f'''        include "xbios.i"
        text
start:
        movea.l 4(sp),a0
        lea wrapper_stack_end,sp
        move.l 12(a0),d0
        add.l 20(a0),d0
        add.l 28(a0),d0
        addi.l #256,d0
        move.l d0,-(sp)
        move.l a0,-(sp)
        clr.w -(sp)
        move.w #74,-(sp)
        trap #1
        lea 12(sp),sp
        Supexec ticks
        move.l d0,result+4
        clr.l -(sp)
        pea tail
        pea name
        clr.w -(sp)
        move.w #75,-(sp)
        trap #1
        lea 16(sp),sp
        move.l d0,result
        Supexec ticks
        move.l d0,result+8
        Fcreate result_name,#0
        move.w d0,d7
        Fwrite d7,#12,result
        Fclose d7
        Pterm0
ticks:  move.l $4ba.w,d0
        rts
        data
name:   dc.b 'MT32REND.TTP',0
tail:   dc.b {len(tail)},'{tail}',0
result_name: dc.b 'RESULT.BIN',0
        even
        bss
result: ds.l 3
wrapper_stack: ds.b 4096
wrapper_stack_end:
        end
'''
    (directory / "launch.s").write_text(source)
    run([ROOT / "build/tools/vasm/vasmm68k_mot", "launch.s", "-quiet", "-Felf", "-m68030",
         f"-I{ROOT / 'src/m68k'}", "-o", "launch.o"], directory, directory / "vasm.log")
    run([ROOT / "build/tools/vlink/vlink", "launch.o", "-b", "ataritos", "-s", "-e", "start",
         "-o", "RENDER.TOS"], directory, directory / "vlink.log")


def hatari(args, directory, program, trace="gemdos", vbls=50000):
    (directory / "quit.ini").write_text("quit\n")
    (directory / "start.ini").write_text(
        f"b GemdosOpcode = 0x00 :once :trace :file {directory / 'quit.ini'}\n")
    run([args.hatari, "--machine", "falcon", "--memsize", "4", "--fpu", "none",
         "--dsp", "emu", "--tos", args.tos, "--patch-tos", "true", "--fast-boot", "true",
         "--fast-forward", "true", "--sound", "off", "--confirm-quit", "false",
         "--run-vbls", str(vbls), "--trace", trace, "--parse", directory / "start.ini", program],
        directory, directory / "hatari.log")


def check(args):
    root = ROOT / "build/rom-renderer-check"
    root.mkdir(exist_ok=True)
    reports = []
    for digital in (True, False):
        directory = root / ("digital" if digital else "codec")
        directory.mkdir(exist_ok=True)
        for source, name in ((args.control, "MT32CTRL.ROM"), (args.pcm, "MT32PCM.ROM"),
                             (ROOT / "release/mt32rend.ttp", "MT32REND.TTP")):
            shutil.copyfile(source, directory / name)
        # One PCM+synth piano note, bend, sustain, and note-off. A short codec
        # case bounds the very slow software-float resampler on a stock 030.
        track = bytes.fromhex("00 c1 00 00 91 3c 64 01 e1 00 48 01 b1 40 7f 01 81 3c 40 01 b1 40 00 00 ff 2f 00")
        (directory / "SONG.MID").write_bytes(smf(track, division=96 if digital else 192))
        suffix = "WAV" if digital else "PCM"
        actual, expected = directory / f"MT32.{suffix}", directory / f"HOST.{suffix}"
        for output in (actual, expected, directory / "RESULT.BIN"):
            output.unlink(missing_ok=True)
        options = (["--digital"] if digital else []) + ["--tail", "0"]
        run([ROOT / "build/native/mt32rend.exe", *options, "MT32CTRL.ROM", "MT32PCM.ROM",
             "SONG.MID", f"HOST.{suffix}"], directory, directory / "host.log")
        launcher(directory, " ".join(options))
        hatari(args, directory, "RENDER.TOS")
        status, start, end = struct.unpack(">iII", (directory / "RESULT.BIN").read_bytes())
        assert status == 0, f"Falcon renderer returned {status}; {directory / 'hatari.log'}"
        if digital:
            assert actual.read_bytes() == expected.read_bytes(), "Digital output differs between 68030 and host"
            with wave.open(str(actual), "rb") as wav:
                count = wav.getnframes()
                samples = struct.unpack("<" + "h" * count * 2, wav.readframes(count))
        else:
            a, e = actual.read_bytes(), expected.read_bytes()
            assert a[:16] == e[:16] and len(a) == len(e), "Codec header/length differs"
            count = struct.unpack(">I", a[12:16])[0]
            samples = struct.unpack(">" + "h" * count * 2, a[16:])
            host = struct.unpack(">" + "h" * count * 2, e[16:])
            assert max(abs(x - y) for x, y in zip(samples, host)) <= 1, "Codec output exceeds one LSB error"
        assert any(samples), "Render is silent"
        seconds = ((end - start) & 0xffffffff) / 200
        report = f"PASS {'digital (byte-exact)' if digital else 'codec (within one LSB)'}: {count} frames; Falcon elapsed {seconds:.2f} s including startup"
        print(report, flush=True)
        reports.append(report)
    (root / "results.txt").write_text("\n".join(reports) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hatari", type=Path, required=True)
    parser.add_argument("--tos", type=Path, required=True)
    parser.add_argument("--control", type=Path, required=True)
    parser.add_argument("--pcm", type=Path, required=True)
    options = parser.parse_args()
    for name in ("hatari", "tos", "control", "pcm"):
        setattr(options, name, getattr(options, name).resolve())
    check(options)

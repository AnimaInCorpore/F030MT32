#!/usr/bin/env python3
"""Build an isolated long reverb image and compare it with Munt under Hatari.

The normal 2048-frame profiles do not reach the longest feedback delay.
These 6144-frame fixtures also exercise 16-bit overflow. Only the frame count
and input data differ from the production reverb; the arithmetic is identical.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import random
import shutil
import subprocess

from generate_dsp_stage2 import emit_include
from la32_partial import emit_reverb_tables, expected_words, from_word, parse_dump, read_oracle
from profile_dsp import write_debugger_scripts

FRAMES = 6144
ROOT = Path(__file__).resolve().parent.parent


def run(args: list[str | Path], *, cwd: Path, log: Path, env: dict | None = None) -> None:
    with log.open("w") as output:
        subprocess.run([str(arg) for arg in args], cwd=cwd, env=env,
                       stdout=output, stderr=subprocess.STDOUT, check=True, timeout=120)


def check(args: argparse.Namespace) -> None:
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    for name in ("ASM56000.EXE", "CLDLOD.EXE", "DOS4GW.EXE", "ioequ.inc"):
        shutil.copyfile(ROOT / "build/dsp" / name, output / name)
    shutil.copyfile(ROOT / "src/dsp/la32.asm", output / "LA32.ASM")
    shutil.copyfile(ROOT / "src/dsp/protocol.inc", output / "protocol.inc")
    shutil.copyfile(ROOT / "build/generated/tone_table.inc", output / "tonetabs.inc")
    (output / "REVERB.ASM").write_text(
        "LA32_REVERB_STRESS equ 1\n" + (ROOT / "src/dsp/reverb.asm").read_text())
    (output / "BUILD.BAT").write_text(
        "@ECHO OFF\n"
        "ASM56000.EXE -q -a -bREVERB.CLD -z -lREVERB.LST REVERB.ASM\n"
        "IF ERRORLEVEL 1 EXIT 1\n"
        "CLDLOD.EXE REVERB.CLD > REVERB.LOD\n"
        "EXIT\n")
    rng = random.Random(56001)
    fixtures = {
        "square": [(32767 if (i // 2048) & 1 else -32768,) * 2 for i in range(FRAMES)],
        "noise": [(rng.randrange(-32768, 32768), rng.randrange(-32768, 32768))
                  for _ in range(FRAMES)],
        "impulse": [(32767, -32768)] + [(0, 0)] * (FRAMES - 1),
    }
    results = []
    env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
    for name, samples in fixtures.items():
        case = output / name
        case.mkdir(exist_ok=True)
        source = case / "input.txt"
        source.write_text("".join(f"0 {l} {r}\n" for l, r in samples))
        (output / "la32rvb.inc").write_text(emit_reverb_tables(source, FRAMES))
        # Refuse stale assembler output if DOSBox fails before assembling.
        for filename in ("REVERB.LOD", "REVERB.LST", "REVERB.CLD"):
            (output / filename).unlink(missing_ok=True)
        run([args.dosbox, "--noprimaryconf", "--set", "output=texture", output / "BUILD.BAT"],
            cwd=ROOT, log=case / "assembler.log")
        listing = output / "REVERB.LST"
        listing_text = listing.read_text()
        if "0    Errors" not in listing_text or "0    Warnings" not in listing_text:
            raise SystemExit(f"Assembler failed: {listing}")
        (output / "dsp_reverb_image.i").write_text(emit_include(
            ROOT / "build/dsp/LA32BOOT.LOD", output / "REVERB.LOD", prefix="dsp_reverb"))
        run([ROOT / "build/tools/vasm/vasmm68k_mot", ROOT / "src/m68k/main.s",
             "-quiet", "-Felf", "-m68030", f"-I{ROOT / 'src/m68k'}", f"-I{output}",
             f"-I{ROOT / 'build/generated'}", "-o", output / "main.o"],
            cwd=ROOT, log=case / "vasm.log")
        run([ROOT / "build/tools/vlink/vlink", output / "main.o",
             ROOT / "build/m68k/dsp_link.o", ROOT / "build/m68k/pcm_partial.o",
             ROOT / "build/m68k/pcm_file.o",
             "-b", "ataritos", "-s", "-e", "start", "-o", case / "stress.tos"],
            cwd=ROOT, log=case / "vlink.log")
        for cfg, time, level in ((8, 5, 3), (9, 7, 7)):
            capture = case / str(cfg)
            capture.mkdir(exist_ok=True)
            with source.open() as stdin, (capture / "oracle.txt").open("w") as stdout:
                subprocess.run([str(ROOT / "build/native/la32_partial_oracle.exe"),
                                "reverb", str(time), str(level)],
                               stdin=stdin, stdout=stdout, check=True, timeout=30)
            write_debugger_scripts(listing, capture, 0x01C000 + cfg,
                                   "la32_reverb_loop", "la32_reverb_done",
                                   [("x", 0x1000, 0x3FFF)], "Y")
            (case / "PROFILE.CFG").write_text(str(cfg))
            run([args.hatari, "--machine", "falcon", "--dsp", "emu", "--tos", args.tos,
                 "--patch-tos", "true", "--fast-boot", "true", "--fast-forward", "true",
                 "--sound", "off", "--confirm-quit", "false", "--run-vbls", "1200",
                 "--parse", capture / "start.ini", "stress.tos"],
                cwd=case, log=capture / "debug.log", env=env)
            actual = parse_dump(capture / "debug.log")
            expected = expected_words(read_oracle(capture / "oracle.txt"))
            for i, wanted in enumerate(expected):
                value = actual.get(0x1000 + i)
                if value != wanted:
                    observed = "missing" if value is None else str(from_word(value))
                    raise SystemExit(f"FAIL {name}/{cfg}, frame {i // 2} {'LR'[i % 2]}: "
                                     f"DSP {observed}, Munt {from_word(wanted)}; {capture}")
            result = f"PASS {name}/time{time}/level{level}: {FRAMES} frames equal Munt"
            print(result, flush=True)
            results.append(result)
    (output / "results.txt").write_text("\n".join(results) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dosbox", type=Path, required=True)
    parser.add_argument("--hatari", type=Path, required=True)
    parser.add_argument("--tos", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "build/reverb-regression")
    options = parser.parse_args()
    options.dosbox = options.dosbox.resolve()
    options.hatari = options.hatari.resolve()
    options.tos = options.tos.resolve()
    check(options)

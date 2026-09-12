#!/usr/bin/env python3
"""Measure DMA -> SSI capture alongside SSI output, at 2, 4, 6 and 8 slots/frame.

Uses its own images and GEMDOS directories; never changes the player or its
PROFILE.CFG. Checks every captured 16-bit sample and counts both normal and
exception interrupts. The CPU sleeps on Vsync: synthesis and buffer refills
are deliberately outside this transport feasibility measurement.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess

from generate_dsp_stage2 import make_boot_image
from la32_partial import parse_dump
from profile_dsp import parse_listing, parse_profile, require_symbol

ROOT = Path(__file__).resolve().parent.parent
RATE = 25175000 / 768


def run(command, cwd, log, env=None):
    with log.open('w') as stream:
        subprocess.run([str(x) for x in command], cwd=cwd, env=env,
                       stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=60)


def check(args):
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    reports = []
    failures = []
    for channels in args.channels:
        case = output / str(channels)
        case.mkdir(exist_ok=True)
        for name in ('ASM56000.EXE', 'CLDLOD.EXE', 'DOS4GW.EXE', 'ioequ.inc'):
            shutil.copyfile(ROOT / 'third_party/f030dsp3d/tools/asm56k' / name, case / name)
        shutil.copyfile(ROOT / 'src/dsp/ssi_dma.asm', case / 'DMA.ASM')
        words = 512 * channels
        (case / 'dmacfg.inc').write_text(f'DMA_CHANNELS equ {channels}\nDMA_WORDS equ {words}\n')
        (case / 'BUILD.BAT').write_text(
            '@ECHO OFF\nASM56000.EXE -q -a -bDMA.CLD -z -lDMA.LST DMA.ASM\n'
            'IF ERRORLEVEL 1 EXIT 1\nCLDLOD.EXE DMA.CLD > DMA.LOD\nEXIT\n')
        for name in ('DMA.LOD', 'DMA.LST', 'DMA.CLD'):
            (case / name).unlink(missing_ok=True)
        run([args.dosbox, '--noprimaryconf', '--set', 'output=texture', case / 'BUILD.BAT'],
            ROOT, case / 'assembler.log')
        listing = case / 'DMA.LST'
        if not all(re.search(rf'^0 +{s}$', listing.read_text(), re.M) for s in ('Errors', 'Warnings')):
            raise SystemExit(f'Assembler failed: {listing}')
        boot = make_boot_image(case / 'DMA.LOD', limit=512, purpose='SSI DMA probe')
        (case / 'dmaimage.i').write_text('dma_boot:\n' + ''.join(
            f'        dc.b ${(w >> 16) & 255:02x},${(w >> 8) & 255:02x},${w & 255:02x}\n'
            for w in boot) + '        even\n')
        (case / 'dmacfg.i').write_text(f'DMA_CHANNELS equ {channels}\nDMA_BOOT_WORDS equ {len(boot)}\n')
        # Nonzero, slot-distinct, signed pattern, with explicit full-scale edges.
        samples = [((i * 7919 + 12345) & 65535) for i in range(65536)]
        for i, edge in enumerate((0x8000, 0x7fff, 0, 0xffff)):
            j = samples.index(edge)
            samples[i], samples[j] = samples[j], samples[i]
        samples = samples[:words]  # retain uniqueness for discontinuity diagnosis
        (case / 'dmainput.i').write_text('dma_input:\n' + ''.join(
            '        dc.w ' + ','.join(f'${s:04x}' for s in samples[i:i+8]) + '\n'
            for i in range(0, words, 8)) + 'dma_input_end:\n')
        run([ROOT / 'build/tools/vasm/vasmm68k_mot', ROOT / 'src/m68k/ssi_dma.s',
             '-quiet', '-Felf', '-m68030', f'-I{ROOT / "src/m68k"}', f'-I{case}',
             '-o', case / 'dma.o'], ROOT, case / 'vasm.log')
        run([ROOT / 'build/tools/vlink/vlink', case / 'dma.o', '-b', 'ataritos', '-s',
             '-e', 'start', '-o', case / 'DMA.TOS'], ROOT, case / 'vlink.log')
        symbols = parse_listing(listing)
        sym = lambda name: require_symbol(symbols, 'P', name)
        (case / 'start.ini').write_text(
            f'db pc = ${sym("capture_begin"):04x} :once :trace :file {case / "begin.ini"}\n')
        (case / 'begin.ini').write_text(
            f'dp on\ndb pc = ${sym("capture_done"):04x} :once :trace :file {case / "end.ini"}\n')
        (case / 'end.ini').write_text(
            f'dp save {case / "profile.txt"}\ndp off\n'
            f'dm x $1000-${0x1000 + words - 1:x}\ndm y $0-$7\n')
        env = dict(os.environ, SDL_VIDEODRIVER='dummy', SDL_AUDIODRIVER='dummy')
        (case / 'profile.txt').unlink(missing_ok=True)
        run([args.hatari, '--machine', 'falcon', '--dsp', 'emu', '--memsize', '4',
             '--tos', args.tos, '--patch-tos', 'true', '--fast-boot', 'true',
             '--fast-forward', 'true', '--sound', 'off', '--confirm-quit', 'false',
             '--run-vbls', '900', '--trace', 'gemdos,xbios,dsp_host_ssi', '--trace-file', case / 'trace.txt',
             '--parse', case / 'start.ini', 'DMA.TOS'], case, case / 'debug.log', env)
        dump = parse_dump(case / 'debug.log')
        state = {int(a, 16): int(v, 16) for a, v in re.findall(
            r"^Y ram:([0-9a-fA-F]+)\s+([0-9a-fA-F]{6})", (case / 'debug.log').read_text(), re.M)}
        hz, total, rows = parse_profile(case / 'profile.txt')
        counts = {pc: n for pc, n, cyc, pct in rows}
        rx, tx = counts.get(sym('ssi_rx'), 0), counts.get(sym('ssi_tx'), 0)
        if rx < 4 * words or abs(rx - tx) > 64 * channels:
            raise SystemExit(f'FAIL {channels} slots: insufficient/unbalanced RX/TX {rx}/{tx}')
        if state.get(0) != (rx & 65535):
            raise SystemExit(f'FAIL {channels} slots: receive counter and profile disagree')
        trace = (case / 'trace.txt').read_text()
        # Exclude debugger disassembly reads of RX after the receiver stops.
        active = trace.split('Dsp SSI CRB write: 0x00f800', 1)[1].split(
            'Dsp SSI CRB write: 0x000000', 1)[0]
        received = [int(v, 16) for v in re.findall(r'Dsp read RX register: 0x([0-9a-f]+)', active)]
        if len(received) != rx:
            raise SystemExit(f'FAIL {channels} slots: RX trace/profile counts disagree {len(received)}/{rx}')
        reference = [v << 8 for v in samples]
        inverse = {v: i for i, v in enumerate(reference)}
        transitions = sum(value != reference[(inverse.get(previous, -2) + 1) % words]
                          for previous, value in zip(received, received[1:]))
        stream_bad = sum(value != reference[i % words] for i, value in enumerate(received))
        ring_bad = sum(dump.get(0x1000 + i) != value for i, value in enumerate(reference))
        ok = not (stream_bad or ring_bad or state.get(2) != 0 or state.get(3) != 0)
        if not ok:
            failures.append(channels)
        # Use receive words to normalize by actual DMA frames, including partial periods.
        frames = rx / channels
        rx_cycles = sum(c for pc, n, c, pct in rows if sym('ssi_rx') <= pc < sym('ssi_rx') + 2) / 2
        tx_cycles = sum(c for pc, n, c, pct in rows if sym('ssi_tx') <= pc < sym('ssi_tx') + 2) / 2
        if 'Pterm0' not in trace or 'Pterm(1)' in trace:
            raise SystemExit(f'FAIL {channels} slots: host did not exit successfully')
        report = (f'{"PASS" if ok else "FAIL"} {channels} slots/frame: {rx} received words checked; {words} ring words checked\n'
                  f'  sequence discontinuities: {transitions}; misaligned stream/ring words: {stream_bad}/{ring_bad}\n'
                  f'  RX/TX exception counters: {state.get(2)}/{state.get(3)} (Hatari does not fully model RX overrun)\n'
                  f'  RX/TX words: {rx}/{tx}; DMA frames: {frames:.1f}\n'
                  f'  RX cycles/word: {rx_cycles/rx:.2f}; TX cycles/word: {tx_cycles/tx:.2f}\n'
                  f'  RX + TX cycles/codec frame: {(rx_cycles+tx_cycles)/frames:.2f}\n'
                  f'  DMA payload: {channels*RATE*2:,.0f} bytes/s; ring: {words*2} CPU bytes\n'
                  f'  oscillator: {hz}; profiled interval: {total/hz*1000:.2f} ms\n')
        print(report, flush=True)
        (case / 'report.txt').write_text(report)
        reports.append(report)
    (output / 'results.txt').write_text('\n'.join(reports))
    if failures:
        raise SystemExit(f'Unqualified slot counts (sample integrity failed): {failures}; see {output / "results.txt"}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dosbox', type=Path, required=True)
    parser.add_argument('--hatari', type=Path, required=True)
    parser.add_argument('--tos', type=Path, required=True)
    parser.add_argument('--channels', type=int, choices=(2, 4, 6, 8), nargs='+', default=[2, 4, 6, 8])
    parser.add_argument('--output', type=Path, default=ROOT / 'build/ssi-dma-profile')
    args = parser.parse_args()
    args.dosbox, args.hatari, args.tos = args.dosbox.resolve(), args.hatari.resolve(), args.tos.resolve()
    check(args)

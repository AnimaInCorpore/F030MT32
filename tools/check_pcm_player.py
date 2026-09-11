#!/usr/bin/env python3
"""Exercise file decoding, cache refills and the final period under Hatari."""
import argparse
from pathlib import Path
import re
import shutil
import struct

from check_rom_renderer import ROOT, hatari


def check(args):
    root = ROOT / "build/pcm-player-check"
    root.mkdir(exist_ok=True)
    frames = 8705  # three disk-cache reads and a one-frame final period
    samples = [((i * 7919 + 32768) & 65535) - 32768 for i in range(frames * 2)]
    data = b"F32P" + struct.pack(">III", 25175000, 768, frames) + struct.pack(">" + "h" * len(samples), *samples)
    cases = {"valid": data, "truncated": data[:-1], "wrong-rate": data[:8] + struct.pack(">I", 767) + data[12:]}
    for name, content in cases.items():
        directory = root / name
        directory.mkdir(exist_ok=True)
        shutil.copyfile(ROOT / "release/f030mt32.tos", directory / "PLAYER.TOS")
        (directory / "PROFILE.CFG").write_text("W")
        (directory / "MT32.PCM").write_bytes(content)
        hatari(args, directory, "PLAYER.TOS", "gemdos,dsp_host_interface,xbios", vbls=1000)
        trace = (directory / "hatari.log").read_text(errors="replace")
        # Start after the DSP's HELLO reply. Audio samples and the boot image
        # can contain any 24-bit value, including the PING command itself.
        payload_trace = trace.split("(DSP->Host): Transfer 0x4d5401", 1)[1]
        words = [int(x, 16) for x in re.findall(r"Direct Transfer 0x([0-9a-fA-F]+)", payload_trace)]
        if name != "valid":
            assert "Pterm(1)" in trace and 0x050000 not in words, name
        else:
            assert "Pterm(1)" not in trace and "condition(s) matched 1 times" in trace, "Player failed"
            expected = []
            padded = [(s & 65535) << 8 for s in samples]
            padded += [0] * (-len(padded) % 1024)
            # Extra silence period drains the complete final audio period.
            padded += [0] * 1024
            for offset in range(0, len(padded), 1024):
                expected += [0x050000 if offset == 0 else 0x060000] + padded[offset:offset + 1024]
            expected += [0x070000]
            assert words == expected, f"Player sample/command mismatch ({len(words)} vs {len(expected)} words)"
        print(f"PASS PCM player {name}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hatari", type=Path, required=True)
    parser.add_argument("--tos", type=Path, required=True)
    options = parser.parse_args()
    options.hatari = options.hatari.resolve()
    options.tos = options.tos.resolve()
    check(options)

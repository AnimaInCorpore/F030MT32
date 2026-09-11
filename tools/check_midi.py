#!/usr/bin/env python3
"""ROM-free SMF timing, track merge and malformed-input checks."""
import struct
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def smf(*tracks, division=96):
    return b"MThd" + struct.pack(">IHHH", 6, int(len(tracks) > 1), len(tracks), division) + b"".join(
        b"MTrk" + struct.pack(">I", len(t)) + t for t in tracks)


def check():
    cases = [
        ("running status", smf(bytes.fromhex("00 91 3c 64 60 3c 00 00 ff 2f 00")),
         "0 91 3c 64\n16000 91 3c 00\nend 16000\n"),
        ("tempo and track merge", smf(bytes.fromhex("60 ff 51 03 03 d0 90 60 ff 2f 00"),
                                      bytes.fromhex("00 c1 00 60 91 3c 64 60 81 3c 40 00 ff 2f 00")),
         "0 c1 00\n16000 91 3c 64\n24000 81 3c 40\nend 24000\n"),
        ("fractional time carry", smf(bytes.fromhex("01 91 3c 64 01 3d 64 01 3e 64 00 ff 2f 00"), division=3),
         "5333 91 3c 64\n10666 91 3d 64\n16000 91 3e 64\nend 16000\n"),
        ("SMPTE", smf(bytes.fromhex("00 91 3c 64 19 81 3c 00 00 ff 2f 00"), division=0xe701),
         "0 91 3c 64\n32000 81 3c 00\nend 32000\n"),
        ("drop frame SMPTE", smf(bytes.fromhex("00 91 3c 64 1e 81 3c 00 00 ff 2f 00"), division=0xe301),
         "0 91 3c 64\n32032 81 3c 00\nend 32032\n"),
        ("split SysEx", smf(bytes.fromhex("00 f0 03 41 10 16 60 f7 02 12 f7 00 ff 2f 00")),
         "16000 f0 41 10 16 12 f7\nend 16000\n"),
    ]
    malformed = {
        "missing status": "00 3c 64 00 ff 2f 00",
        "status in data": "00 91 3c 91 00 ff 2f 00",
        "unterminated sysex": "00 f0 02 41 10 00 ff 2f 00",
        "unbounded sysex length": "00 f0 7f 41",
        "tempo zero": "00 ff 51 03 00 00 00 00 ff 2f 00",
        "bad tempo size": "00 ff 51 01 07 00 ff 2f 00",
        "missing EOT": "00 91 3c 64",
        "long VLQ": "81 81 81 81 00 91 3c 64 00 ff 2f 00",
        "meta clears running status": "00 91 3c 64 00 ff 01 00 00 3c 00 00 ff 2f 00",
        "trailing track bytes": "00 ff 2f 00 00",
    }
    cases += [(name, smf(bytes.fromhex(data)), None) for name, data in malformed.items()]
    cases += [("truncated chunk", smf(bytes.fromhex("00 ff 2f 00"))[:-1], None)]
    with tempfile.TemporaryDirectory(dir=ROOT / "build", prefix="midi-check-") as directory:
        path = Path(directory) / "test.mid"
        for name, content, expected in cases:
            path.write_bytes(content)
            result = subprocess.run([ROOT / "build/native/smf_dump.exe", path], capture_output=True,
                                    text=True, timeout=10)
            if expected is None:
                assert result.returncode == 1 and result.stderr, (name, result)
            else:
                assert result.returncode == 0 and result.stdout == expected, (name, result)
            print(f"PASS {name}")


if __name__ == "__main__":
    check()

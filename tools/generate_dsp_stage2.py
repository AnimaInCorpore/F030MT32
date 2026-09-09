#!/usr/bin/env python3
"""Convert DSP56001 LOD files into an embedded two-stage loader image."""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path


DATA_RE = re.compile(r"^_DATA\s+([PXY])\s+([0-9A-Fa-f]+)\s*$")
END_RE = re.compile(r"^_END\s+([0-9A-Fa-f]+)\s*$")
WORD_RE = re.compile(r"^[0-9A-Fa-f]{6}$")

STAGE2_MAGIC = 0x4D544C  # "MTL"
STAGE2_REPLY_OK = 0x4C4F41  # "LOA"
LOADER_FIRST = 0x0040
LOADER_LIMIT = 0x0080
BOOT_LIMIT = 512


@dataclass
class Section:
    space: str
    address: int
    words: list[int]

    @property
    def limit(self) -> int:
        return self.address + len(self.words)


def parse_lod(path: Path) -> tuple[list[Section], int]:
    sections: list[Section] = []
    current: Section | None = None
    entry: int | None = None

    for line_number, raw_line in enumerate(
        path.read_text(errors="strict").splitlines(), start=1
    ):
        line = raw_line.strip()
        if not line:
            continue
        data_match = DATA_RE.match(line)
        if data_match:
            current = Section(
                data_match.group(1).upper(), int(data_match.group(2), 16), []
            )
            sections.append(current)
            continue
        end_match = END_RE.match(line)
        if end_match:
            entry = int(end_match.group(1), 16)
            current = None
            continue
        if current is None:
            raise SystemExit(f"error: {path}:{line_number}: data outside a section")
        for token in line.split():
            if not WORD_RE.fullmatch(token):
                raise SystemExit(
                    f"error: {path}:{line_number}: invalid DSP word {token!r}"
                )
            current.words.append(int(token, 16))

    if entry is None or not sections:
        raise SystemExit(f"error: {path} is not a complete DSP LOD file")
    if any(not section.words for section in sections):
        raise SystemExit(f"error: {path} contains an empty data section")
    return sections, entry


def merge_sections(sections: list[Section]) -> list[Section]:
    merged: list[Section] = []
    for section in sections:
        if merged and section.space == merged[-1].space and section.address == merged[-1].limit:
            merged[-1].words.extend(section.words)
        else:
            merged.append(Section(section.space, section.address, section.words.copy()))
    return merged


def make_boot_image(
    path: Path, limit: int = LOADER_LIMIT, purpose: str = "bootstrap"
) -> list[int]:
    sections, entry = parse_lod(path)
    if entry != 0:
        raise SystemExit(f"error: {purpose} entry must be P:$0000, got ${entry:04x}")
    if any(section.space != "P" for section in sections):
        raise SystemExit(f"error: {purpose} may initialize only P memory")

    image: dict[int, int] = {}
    for section in sections:
        for offset, word in enumerate(section.words):
            address = section.address + offset
            if address in image:
                raise SystemExit(
                    f"error: overlapping {purpose} word P:${address:04x}"
                )
            image[address] = word
    if not image or min(image) != 0:
        raise SystemExit(f"error: {purpose} must begin at P:$0000")
    words = [image.get(address, 0) for address in range(max(image) + 1)]
    if len(words) > BOOT_LIMIT:
        raise SystemExit(
            f"error: {purpose} is {len(words)} words ({BOOT_LIMIT} maximum)"
        )
    if len(words) > limit:
        raise SystemExit(
            f"error: {purpose} overlaps the final program above reserved "
            f"P:${limit - 1:04x}"
        )
    return words


def make_program_stream(
    path: Path,
    program_limit: int | None = None,
    islands: list[tuple[int, int]] | None = None,
) -> tuple[list[int], int, int]:
    islands = islands or []
    sections, entry = parse_lod(path)
    sections = merge_sections(sections)
    if entry != 0:
        raise SystemExit(f"error: stage-two entry must be P:$0000, got ${entry:04x}")
    if any(section.space != "P" for section in sections):
        raise SystemExit("error: stage-two loader currently accepts P-memory sections only")
    if len(sections) > 0xFFFF:
        raise SystemExit("error: stage-two stream has too many sections")

    # The assembler accepts a section grown past the next hardcoded org
    # without complaint, and the loader would then silently clobber the
    # later section's words; fail the build with both ranges instead.
    ordered = sorted(sections, key=lambda section: section.address)
    for lower, upper in zip(ordered, ordered[1:]):
        if lower.limit > upper.address:
            raise SystemExit(
                f"error: P sections ${lower.address:04x}-${lower.limit - 1:04x} "
                f"and ${upper.address:04x}-${upper.limit - 1:04x} overlap; the "
                "loader would silently clobber the overlapping words"
            )

    for section in sections:
        if section.address > 0xFFFF or section.limit > 0x10000:
            raise SystemExit("error: stage-two section lies outside 16-bit P memory")
        if len(section.words) > 0xFFFF:
            raise SystemExit("error: stage-two section exceeds the hardware-loop limit")
        if section.address < LOADER_LIMIT and section.limit > LOADER_FIRST:
            raise SystemExit(
                "error: final program overlaps reserved loader gap "
                f"P:${LOADER_FIRST:04x}-P:${LOADER_LIMIT - 1:04x}"
            )
        # A section must either stay below the Y-aliased table boundary or sit
        # entirely inside the declared free island above the external-Y
        # reservation; Falcon external P aliases external Y word for word.
        below_tables = program_limit is None or section.limit <= program_limit
        inside_island = any(
            section.address >= start and section.limit <= limit
            for start, limit in islands
        )
        if not (below_tables or inside_island):
            described = ", ".join(
                f"P:${start:04x}-${limit - 1:04x}" for start, limit in islands
            )
            raise SystemExit(
                f"error: final program section P:${section.address:04x}-"
                f"${section.limit - 1:04x} overlaps the reserved table region "
                f"at P:${program_limit:04x} and lies outside the free islands"
                + (f" {described}" if islands else "")
            )

    stream = [STAGE2_MAGIC, len(sections)]
    for section in sections:
        stream.extend((section.address, len(section.words)))
        stream.extend(section.words)
    initialized_words = sum(len(section.words) for section in sections)
    return stream, len(sections), initialized_words


def format_values(directive: str, values: list[int], digits: int, width: int) -> list[str]:
    lines: list[str] = []
    for offset in range(0, len(values), width):
        chunk = values[offset : offset + width]
        rendered = ",".join(f"${value:0{digits}x}" for value in chunk)
        lines.append(f"        {directive}    {rendered}")
    return lines


def emit_standalone(program: Path, prefix: str) -> str:
    """One self-contained Dsp_ExecBoot image with no stage-two stream."""
    words = make_boot_image(program, limit=BOOT_LIMIT, purpose="standalone program")

    boot_bytes: list[int] = []
    for word in words:
        boot_bytes.extend(((word >> 16) & 0xFF, (word >> 8) & 0xFF, word & 0xFF))

    lines = [
        "; Generated by tools/generate_dsp_stage2.py; do not edit.",
        f"{prefix.upper()}_BOOT_WORDS equ {len(words)}",
        "",
        f"{prefix}_boot_image:",
    ]
    lines.extend(format_values("dc.b", boot_bytes, 2, 12))
    lines.append("        even")
    lines.append("")
    return "\n".join(lines)


def emit_include(
    bootstrap: Path,
    program: Path,
    program_limit: int | None = None,
    islands: list[tuple[int, int]] | None = None,
) -> str:
    boot_words = make_boot_image(bootstrap)
    stream, section_count, initialized_words = make_program_stream(
        program, program_limit, islands
    )

    boot_bytes: list[int] = []
    for word in boot_words:
        boot_bytes.extend(((word >> 16) & 0xFF, (word >> 8) & 0xFF, word & 0xFF))

    lines = [
        "; Generated by tools/generate_dsp_stage2.py; do not edit.",
        f"DSP_BOOT_WORDS equ {len(boot_words)}",
        f"DSP_STAGE2_TRANSFER_WORDS equ {len(stream)}",
        f"DSP_STAGE2_SECTION_COUNT equ {section_count}",
        f"DSP_STAGE2_PROGRAM_WORDS equ {initialized_words}",
        f"DSP_STAGE2_REPLY_OK equ ${STAGE2_REPLY_OK:06x}",
        "",
        "dsp_bootstrap_image:",
    ]
    lines.extend(format_values("dc.b", boot_bytes, 2, 12))
    lines.extend(["        even", "", "dsp_program_image:"])
    lines.extend(format_values("dc.l", stream, 8, 4))
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bootstrap", type=Path)
    parser.add_argument("--program", type=Path)
    parser.add_argument("--program-limit", type=lambda value: int(value, 0))
    parser.add_argument(
        "--island",
        nargs=2,
        action="append",
        type=lambda value: int(value, 0),
        metavar=("START", "LIMIT"),
        help="allow P sections inside [START, LIMIT), a physically free "
        "window above the external-Y reservation; repeatable",
    )
    parser.add_argument(
        "--standalone",
        type=Path,
        help="emit one self-contained Dsp_ExecBoot image for this LOD "
        "instead of a bootstrap plus stage-two stream",
    )
    parser.add_argument(
        "--prefix",
        default="dsp",
        help="symbol prefix for the --standalone image (default: dsp)",
    )
    arguments = parser.parse_args()
    islands = [tuple(pair) for pair in arguments.island or []]
    if arguments.standalone:
        if (
            arguments.bootstrap
            or arguments.program
            or arguments.program_limit
            or islands
        ):
            raise SystemExit("error: --standalone excludes the stage-two options")
        print(emit_standalone(arguments.standalone, arguments.prefix), end="")
        return
    if not arguments.bootstrap or not arguments.program:
        raise SystemExit(
            "error: --bootstrap and --program are required without --standalone"
        )
    print(
        emit_include(
            arguments.bootstrap,
            arguments.program,
            arguments.program_limit,
            islands,
        ),
        end="",
    )


if __name__ == "__main__":
    main()

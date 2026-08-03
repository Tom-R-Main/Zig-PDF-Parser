#!/usr/bin/env python3
"""Generate compact Zig tables from Adobe's BSD-licensed CMap resources.

The source repositories are intentionally kept under the ignored benchmark
cache. Only this deterministic generator, the resulting Zig tables, and the
upstream license notice belong in the repository.
"""

from __future__ import annotations

import argparse
import dataclasses
import pathlib
import re
import struct
import subprocess
from collections.abc import Iterable


COLLECTIONS = (
    ("adobe_cns1", "Adobe-CNS1-7", "Adobe-CNS1-UCS2"),
    ("adobe_gb1", "Adobe-GB1-6", "Adobe-GB1-UCS2"),
    ("adobe_japan1", "Adobe-Japan1-7", "Adobe-Japan1-UCS2"),
    ("adobe_korea1", "Adobe-Korea1-2", "Adobe-Korea1-UCS2"),
)

CMAP_SOURCE = "https://github.com/adobe-type-tools/cmap-resources"
CMAP_REVISION = "f5cf3bca7fdfeaceb77aa82847e974f2306c20b4"
MAPPING_SOURCE = "https://github.com/adobe-type-tools/mapping-resources-pdf"
MAPPING_REVISION = "2dd5e53fb74a01718b9dfd448a0d1cce6fff2aa5"

HEX = r"<([0-9A-Fa-f]+)>"


@dataclasses.dataclass(frozen=True, order=True)
class CodeSpace:
    low: int
    high: int
    byte_count: int


@dataclasses.dataclass(frozen=True, order=True)
class Single:
    source: int
    destination: int


@dataclasses.dataclass(frozen=True, order=True)
class Range:
    source_start: int
    source_end: int
    destination_start: int


@dataclasses.dataclass(frozen=True, order=True)
class UnicodeSequence:
    source: int
    utf8: bytes


@dataclasses.dataclass
class CMap:
    name: str
    usecmap_name: str | None
    wmode: int
    codespaces: list[CodeSpace]
    singles: list[Single]
    ranges: list[Range]
    notdef_singles: list[Single]
    notdef_ranges: list[Range]


def parse_hex(value: str) -> tuple[int, int]:
    if len(value) % 2:
        raise ValueError(f"odd-length hexadecimal token: {value}")
    return int(value, 16), len(value) // 2


def parse_cmap(path: pathlib.Path) -> CMap:
    text = path.read_text(encoding="ascii")
    name_match = re.search(r"/CMapName\s+/([^\s]+)\s+def", text)
    if not name_match:
        raise ValueError(f"missing CMapName in {path}")
    usecmap_match = re.search(r"/([^\s]+)\s+usecmap", text)
    wmode_match = re.search(r"/WMode\s+(\d+)\s+def", text)

    cmap = CMap(
        name=name_match.group(1),
        usecmap_name=usecmap_match.group(1) if usecmap_match else None,
        wmode=int(wmode_match.group(1)) if wmode_match else 0,
        codespaces=[],
        singles=[],
        ranges=[],
        notdef_singles=[],
        notdef_ranges=[],
    )

    section: str | None = None
    for raw_line in text.splitlines():
        line = raw_line.split("%", 1)[0].strip()
        if not line:
            continue
        begin = re.fullmatch(
            r"\d+\s+(begincodespacerange|begincidchar|begincidrange|beginnotdefchar|beginnotdefrange)",
            line,
        )
        if begin:
            section = begin.group(1)
            continue
        if line.startswith("end"):
            section = None
            continue
        if section == "begincodespacerange":
            match = re.fullmatch(rf"{HEX}\s+{HEX}", line)
            if not match:
                raise ValueError(f"invalid codespace entry in {path}: {line}")
            low, low_bytes = parse_hex(match.group(1))
            high, high_bytes = parse_hex(match.group(2))
            if low_bytes != high_bytes:
                raise ValueError(f"mismatched codespace widths in {path}: {line}")
            cmap.codespaces.append(CodeSpace(low, high, low_bytes))
        elif section in ("begincidchar", "beginnotdefchar"):
            match = re.fullmatch(rf"{HEX}\s+(\d+)", line)
            if not match:
                raise ValueError(f"invalid CID char entry in {path}: {line}")
            source, _ = parse_hex(match.group(1))
            target = cmap.notdef_singles if section == "beginnotdefchar" else cmap.singles
            target.append(Single(source, int(match.group(2))))
        elif section in ("begincidrange", "beginnotdefrange"):
            match = re.fullmatch(rf"{HEX}\s+{HEX}\s+(\d+)", line)
            if not match:
                raise ValueError(f"invalid CID range entry in {path}: {line}")
            source_start, _ = parse_hex(match.group(1))
            source_end, _ = parse_hex(match.group(2))
            target = cmap.notdef_ranges if section == "beginnotdefrange" else cmap.ranges
            target.append(Range(source_start, source_end, int(match.group(3))))

    cmap.codespaces.sort()
    cmap.singles.sort()
    cmap.ranges.sort()
    cmap.notdef_singles.sort()
    cmap.notdef_ranges.sort()
    return cmap


def decode_utf16be(value: str) -> str | None:
    data = bytes.fromhex(value)
    try:
        return data.decode("utf-16-be")
    except UnicodeDecodeError:
        return None


def record_unicode_mapping(
    source: int,
    decoded: str | None,
    scalars: dict[int, int],
    sequences: dict[int, bytes],
) -> None:
    if not decoded:
        raise ValueError(f"invalid UTF-16BE destination for CID {source}")
    if len(decoded) == 1:
        scalar = ord(decoded)
        if 0xD800 <= scalar <= 0xDFFF:
            raise ValueError(f"invalid surrogate destination for CID {source}")
        scalars[source] = scalar
        sequences.pop(source, None)
        return
    sequences[source] = decoded.encode("utf-8")
    scalars.pop(source, None)


def parse_collection_unicode(path: pathlib.Path) -> tuple[list[Range], list[UnicodeSequence]]:
    text = path.read_text(encoding="ascii")
    scalars: dict[int, int] = {}
    sequences: dict[int, bytes] = {}
    section: str | None = None
    for raw_line in text.splitlines():
        line = raw_line.split("%", 1)[0].strip()
        if not line:
            continue
        begin = re.fullmatch(r"\d+\s+(beginbfchar|beginbfrange)", line)
        if begin:
            section = begin.group(1)
            continue
        if line.startswith("end"):
            section = None
            continue
        if section == "beginbfchar":
            match = re.fullmatch(rf"{HEX}\s+{HEX}", line)
            if not match:
                raise ValueError(f"invalid bfchar entry in {path}: {line}")
            source, _ = parse_hex(match.group(1))
            record_unicode_mapping(
                source,
                decode_utf16be(match.group(2)),
                scalars,
                sequences,
            )
        elif section == "beginbfrange":
            match = re.fullmatch(rf"{HEX}\s+{HEX}\s+{HEX}", line)
            if not match:
                # These Adobe PDF mapping resources do not currently use array
                # destinations. Reject any future shape rather than generating
                # silently incomplete tables.
                raise ValueError(f"unsupported bfrange entry in {path}: {line}")
            source_start, _ = parse_hex(match.group(1))
            source_end, _ = parse_hex(match.group(2))
            destination = bytes.fromhex(match.group(3))
            for offset, source in enumerate(range(source_start, source_end + 1)):
                encoded = (int.from_bytes(destination, "big") + offset).to_bytes(len(destination), "big")
                record_unicode_mapping(
                    source,
                    decode_utf16be(encoded.hex()),
                    scalars,
                    sequences,
                )

    return (
        compact_values(scalars),
        [UnicodeSequence(source, value) for source, value in sorted(sequences.items())],
    )


def compact_values(values: dict[int, int]) -> list[Range]:
    ranges: list[Range] = []
    for source, destination in sorted(values.items()):
        if ranges:
            previous = ranges[-1]
            expected_source = previous.source_end + 1
            expected_destination = previous.destination_start + (expected_source - previous.source_start)
            if source == expected_source and destination == expected_destination:
                ranges[-1] = Range(previous.source_start, source, previous.destination_start)
                continue
        ranges.append(Range(source, source, destination))
    return ranges


def supplement_maxima(cmaps: Iterable[CMap], collection_prefix: str) -> list[int]:
    maxima: dict[int, int] = {}
    pattern = re.compile(rf"{re.escape(collection_prefix)}-(\d+)$")
    for cmap in cmaps:
        match = pattern.fullmatch(cmap.name)
        if not match:
            continue
        maximum = 0
        for single in cmap.singles:
            maximum = max(maximum, single.destination)
        for item in cmap.ranges:
            maximum = max(maximum, item.destination_start + item.source_end - item.source_start)
        maxima[int(match.group(1))] = maximum
    if not maxima:
        raise ValueError(f"no identity CMaps found for {collection_prefix}")
    latest = max(maxima)
    return [maxima[index] for index in range(latest + 1)]


@dataclasses.dataclass(frozen=True)
class Slice:
    offset: int
    count: int


@dataclasses.dataclass(frozen=True)
class PackedSlice:
    short: Slice
    long: Slice


def append_codespaces(blob: bytearray, items: Iterable[CodeSpace]) -> Slice:
    values = list(items)
    offset = len(blob)
    for item in values:
        blob.extend(struct.pack(">IIB", item.low, item.high, item.byte_count))
    return Slice(offset, len(values))


def append_singles(blob: bytearray, items: Iterable[Single]) -> Slice:
    values = list(items)
    offset = len(blob)
    for item in values:
        blob.extend(struct.pack(">II", item.source, item.destination))
    return Slice(offset, len(values))


def append_packed_singles(blob: bytearray, items: Iterable[Single]) -> PackedSlice:
    values = list(items)
    is_short = lambda item: item.source <= 0xFFFF and item.destination <= 0xFFFF
    short_values = [item for item in values if is_short(item)]
    long_values = [item for item in values if not is_short(item)]
    short_offset = len(blob)
    for item in short_values:
        blob.extend(struct.pack(">HH", item.source, item.destination))
    short = Slice(short_offset, len(short_values))
    return PackedSlice(short, append_singles(blob, long_values))


def append_ranges(blob: bytearray, items: Iterable[Range]) -> Slice:
    values = list(items)
    offset = len(blob)
    for item in values:
        blob.extend(struct.pack(">III", item.source_start, item.source_end, item.destination_start))
    return Slice(offset, len(values))


def append_packed_ranges(blob: bytearray, items: Iterable[Range]) -> PackedSlice:
    values = list(items)
    is_short = lambda item: (
        item.source_end <= 0xFFFF
        and item.destination_start + item.source_end - item.source_start <= 0xFFFF
    )
    short_values = [item for item in values if is_short(item)]
    long_values = [item for item in values if not is_short(item)]
    short_offset = len(blob)
    for item in short_values:
        blob.extend(struct.pack(">HHH", item.source_start, item.source_end, item.destination_start))
    short = Slice(short_offset, len(short_values))
    return PackedSlice(short, append_ranges(blob, long_values))


def append_sequences(blob: bytearray, items: Iterable[UnicodeSequence]) -> Slice:
    values = list(items)
    payloads: list[tuple[int, int, int]] = []
    for item in values:
        payload_offset = len(blob)
        blob.extend(item.utf8)
        payloads.append((item.source, payload_offset, len(item.utf8)))
    offset = len(blob)
    for source, payload_offset, payload_length in payloads:
        if payload_length > 0xFFFF:
            raise ValueError(f"Unicode sequence is too long for CID {source}")
        blob.extend(struct.pack(">IIH", source, payload_offset, payload_length))
    return Slice(offset, len(values))


def verify_revision(root: pathlib.Path, expected: str, label: str) -> None:
    result = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "HEAD"],
        check=False,
        capture_output=True,
        text=True,
    )
    actual = result.stdout.strip() if result.returncode == 0 else ""
    if actual != expected:
        detail = actual or result.stderr.strip() or "not a Git checkout"
        raise ValueError(f"{label} revision mismatch: expected {expected}, got {detail}")


def render_slice(value: Slice) -> str:
    return f".{{ .offset = {value.offset}, .count = {value.count} }}"


def render_packed_slice(value: PackedSlice) -> str:
    return f".{{ .short = {render_slice(value.short)}, .long = {render_slice(value.long)} }}"


def generate(cmap_root: pathlib.Path, mapping_root: pathlib.Path) -> tuple[str, bytes]:
    verify_revision(cmap_root, CMAP_REVISION, "CMap source")
    verify_revision(mapping_root, MAPPING_REVISION, "CID mapping source")

    cmaps: list[CMap] = []
    collection_unicode: dict[str, list[Range]] = {}
    collection_sequences: dict[str, list[UnicodeSequence]] = {}
    collection_maxima: dict[str, list[int]] = {}

    for kind, directory, unicode_name in COLLECTIONS:
        collection_maps = [parse_cmap(path) for path in sorted((cmap_root / directory / "CMap").iterdir()) if path.is_file()]
        cmaps.extend(collection_maps)
        unicode_ranges, unicode_sequences = parse_collection_unicode(mapping_root / "pdf2unicode" / unicode_name)
        collection_unicode[kind] = unicode_ranges
        collection_sequences[kind] = unicode_sequences
        collection_prefix = directory.rsplit("-", 1)[0]
        collection_maxima[kind] = supplement_maxima(collection_maps, collection_prefix)

    cmaps.sort(key=lambda cmap: cmap.name)
    names = [cmap.name for cmap in cmaps]
    if len(names) != len(set(names)):
        raise ValueError("duplicate predefined CMap names across collections")

    blob = bytearray()
    map_slices: dict[str, tuple[Slice, PackedSlice, PackedSlice, PackedSlice, PackedSlice]] = {}
    for cmap in cmaps:
        map_slices[cmap.name] = (
            append_codespaces(blob, cmap.codespaces),
            append_packed_singles(blob, cmap.singles),
            append_packed_ranges(blob, cmap.ranges),
            append_packed_singles(blob, cmap.notdef_singles),
            append_packed_ranges(blob, cmap.notdef_ranges),
        )

    collection_slices = {
        kind: append_ranges(blob, ranges) for kind, ranges in collection_unicode.items()
    }
    collection_sequence_slices = {
        kind: append_sequences(blob, sequences) for kind, sequences in collection_sequences.items()
    }

    output = [
        "//! Generated from Adobe's BSD-3-Clause CMap and PDF mapping resources.",
        f"//! CMaps: {CMAP_SOURCE} @ {CMAP_REVISION}",
        f"//! CID to Unicode: {MAPPING_SOURCE} @ {MAPPING_REVISION}",
        "//! Regenerate with benchmark/eval/generate_cmap_resources.py; do not edit.",
        "",
        "const std = @import(\"std\");",
        "const blob = @embedFile(\"cmap_resources.bin\");",
        "",
        "const Slice = struct { offset: u32, count: u32 };",
        "const PackedSlice = struct { short: Slice, long: Slice };",
        "pub const CharCode = struct { value: u32, bytes_consumed: u8 };",
        "pub const UnicodeMapping = union(enum) { scalar: u21, sequence: []const u8 };",
        "",
        "pub const PredefinedCMap = struct {",
        "    name: []const u8,",
        "    usecmap_name: ?[]const u8,",
        "    codespaces: Slice,",
        "    singles: PackedSlice,",
        "    ranges: PackedSlice,",
        "    notdef_singles: PackedSlice,",
        "    notdef_ranges: PackedSlice,",
        "    bytes_per_char: u8,",
        "    wmode: u8,",
        "};",
        "",
        "pub const CollectionKind = enum { adobe_cns1, adobe_gb1, adobe_japan1, adobe_korea1 };",
        "",
    ]

    output.append("pub const predefined_cmaps = [_]PredefinedCMap{")
    for cmap in cmaps:
        parent = f'\"{cmap.usecmap_name}\"' if cmap.usecmap_name else "null"
        bytes_per_char = max((space.byte_count for space in cmap.codespaces), default=2)
        codespaces, singles, ranges, notdef_singles, notdef_ranges = map_slices[cmap.name]
        output.extend(
            [
                "    .{",
                f'        .name = "{cmap.name}",',
                f"        .usecmap_name = {parent},",
                f"        .codespaces = {render_slice(codespaces)},",
                f"        .singles = {render_packed_slice(singles)},",
                f"        .ranges = {render_packed_slice(ranges)},",
                f"        .notdef_singles = {render_packed_slice(notdef_singles)},",
                f"        .notdef_ranges = {render_packed_slice(notdef_ranges)},",
                f"        .bytes_per_char = {bytes_per_char},",
                f"        .wmode = {cmap.wmode},",
                "    },",
            ]
        )
    output.extend(["};", ""])

    for kind in collection_unicode:
        output.append(f"const {kind}_unicode: Slice = {render_slice(collection_slices[kind])};")
        output.append(f"const {kind}_sequences: Slice = {render_slice(collection_sequence_slices[kind])};")
        maxima = ", ".join(str(value) for value in collection_maxima[kind])
        output.append(f"const {kind}_supplement_max = [_]u32{{ {maxima} }};")
        output.append("")

    output.extend(
        [
            "pub fn findPredefined(name: []const u8) ?*const PredefinedCMap {",
            "    var low: usize = 0;",
            "    var high: usize = predefined_cmaps.len;",
            "    while (low < high) {",
            "        const middle = low + (high - low) / 2;",
            "        switch (std.mem.order(u8, name, predefined_cmaps[middle].name)) {",
            "            .lt => high = middle,",
            "            .gt => low = middle + 1,",
            "            .eq => return &predefined_cmaps[middle],",
            "        }",
            "    }",
            "    return null;",
            "}",
            "",
            "pub fn lookupCode(cmap: *const PredefinedCMap, code: u32) ?u32 {",
            "    return lookupCodeDepth(cmap, code, 0);",
            "}",
            "",
            "fn lookupCodeDepth(cmap: *const PredefinedCMap, code: u32, depth: u8) ?u32 {",
            "    if (depth >= 8) return null;",
            "    if (lookupPackedSingle(cmap.singles, code)) |value| return value;",
            "    if (lookupPackedRange(cmap.ranges, code)) |value| return value;",
            "    if (lookupPackedSingle(cmap.notdef_singles, code)) |value| return value;",
            "    if (lookupPackedRange(cmap.notdef_ranges, code)) |value| return value;",
            "    const parent_name = cmap.usecmap_name orelse return null;",
            "    const parent = findPredefined(parent_name) orelse return null;",
            "    return lookupCodeDepth(parent, code, depth + 1);",
            "}",
            "",
            "pub fn readCharCode(cmap: *const PredefinedCMap, data: []const u8) ?CharCode {",
            "    return readCharCodeDepth(cmap, data, 0);",
            "}",
            "",
            "fn readCharCodeDepth(cmap: *const PredefinedCMap, data: []const u8, depth: u8) ?CharCode {",
            "    if (data.len == 0 or depth >= 8) return null;",
            "    if (cmap.codespaces.count > 0) {",
            "        var byte_count: u8 = 1;",
            "        while (byte_count <= 4 and byte_count <= data.len) : (byte_count += 1) {",
            "            const code = readCodeBE(data[0..byte_count]);",
            "            var index: u32 = 0;",
            "            while (index < cmap.codespaces.count) : (index += 1) {",
            "                const offset = cmap.codespaces.offset + index * 9;",
            "                const low = readU32(offset);",
            "                const high = readU32(offset + 4);",
            "                const width = blob[offset + 8];",
            "                if (width == byte_count and code >= low and code <= high) {",
            "                    return .{ .value = code, .bytes_consumed = byte_count };",
            "                }",
            "            }",
            "        }",
            "        return null;",
            "    }",
            "    if (cmap.usecmap_name) |parent_name| {",
            "        if (findPredefined(parent_name)) |parent| return readCharCodeDepth(parent, data, depth + 1);",
            "    }",
            "    if (cmap.bytes_per_char > 1 and data.len >= cmap.bytes_per_char) {",
            "        return .{ .value = readCodeBE(data[0..cmap.bytes_per_char]), .bytes_consumed = cmap.bytes_per_char };",
            "    }",
            "    return .{ .value = data[0], .bytes_consumed = 1 };",
            "}",
            "",
            "pub fn lookupCollection(kind: CollectionKind, supplement: i32, cid: u32) ?UnicodeMapping {",
            "    return switch (kind) {",
            "        .adobe_cns1 => lookupCollectionTable(adobe_cns1_unicode, adobe_cns1_sequences, &adobe_cns1_supplement_max, supplement, cid),",
            "        .adobe_gb1 => lookupCollectionTable(adobe_gb1_unicode, adobe_gb1_sequences, &adobe_gb1_supplement_max, supplement, cid),",
            "        .adobe_japan1 => lookupCollectionTable(adobe_japan1_unicode, adobe_japan1_sequences, &adobe_japan1_supplement_max, supplement, cid),",
            "        .adobe_korea1 => lookupCollectionTable(adobe_korea1_unicode, adobe_korea1_sequences, &adobe_korea1_supplement_max, supplement, cid),",
            "    };",
            "}",
            "",
            "fn lookupCollectionTable(ranges: Slice, sequences: Slice, supplement_max: []const u32, supplement: i32, cid: u32) ?UnicodeMapping {",
            "    if (supplement < 0) return null;",
            "    const supplement_index: usize = @intCast(supplement);",
            "    if (supplement_index >= supplement_max.len or cid > supplement_max[supplement_index]) return null;",
            "    if (lookupSequence(sequences, cid)) |value| return .{ .sequence = value };",
            "    const value = lookupRange(ranges, cid) orelse return null;",
            "    if (value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) return null;",
            "    return .{ .scalar = @intCast(value) };",
            "}",
            "",
            "fn lookupSequence(items: Slice, source: u32) ?[]const u8 {",
            "    var low: u32 = 0;",
            "    var high: u32 = items.count;",
            "    while (low < high) {",
            "        const middle = low + (high - low) / 2;",
            "        const offset = items.offset + middle * 10;",
            "        const item_source = readU32(offset);",
            "        if (source < item_source) {",
            "            high = middle;",
            "        } else if (source > item_source) {",
            "            low = middle + 1;",
            "        } else {",
            "            const payload_offset = readU32(offset + 4);",
            "            const payload_length = readU16(offset + 8);",
            "            return blob[payload_offset..][0..payload_length];",
            "        }",
            "    }",
            "    return null;",
            "}",
            "",
            "fn lookupSingle(items: Slice, source: u32) ?u32 {",
            "    var low: u32 = 0;",
            "    var high: u32 = items.count;",
            "    while (low < high) {",
            "        const middle = low + (high - low) / 2;",
            "        const offset = items.offset + middle * 8;",
            "        const item_source = readU32(offset);",
            "        if (source < item_source) high = middle else if (source > item_source) low = middle + 1 else return readU32(offset + 4);",
            "    }",
            "    return null;",
            "}",
            "",
            "fn lookupPackedSingle(items: PackedSlice, source: u32) ?u32 {",
            "    if (lookupSingle16(items.short, source)) |value| return value;",
            "    return lookupSingle(items.long, source);",
            "}",
            "",
            "fn lookupSingle16(items: Slice, source: u32) ?u32 {",
            "    if (source > 0xffff) return null;",
            "    var low: u32 = 0;",
            "    var high: u32 = items.count;",
            "    while (low < high) {",
            "        const middle = low + (high - low) / 2;",
            "        const offset = items.offset + middle * 4;",
            "        const item_source = readU16(offset);",
            "        if (source < item_source) high = middle else if (source > item_source) low = middle + 1 else return readU16(offset + 2);",
            "    }",
            "    return null;",
            "}",
            "",
            "fn lookupRange(items: Slice, source: u32) ?u32 {",
            "    var low: u32 = 0;",
            "    var high: u32 = items.count;",
            "    while (low < high) {",
            "        const middle = low + (high - low) / 2;",
            "        const offset = items.offset + middle * 12;",
            "        const source_start = readU32(offset);",
            "        const source_end = readU32(offset + 4);",
            "        if (source < source_start) high = middle else if (source > source_end) low = middle + 1 else return readU32(offset + 8) + (source - source_start);",
            "    }",
            "    return null;",
            "}",
            "",
            "fn lookupPackedRange(items: PackedSlice, source: u32) ?u32 {",
            "    if (lookupRange16(items.short, source)) |value| return value;",
            "    return lookupRange(items.long, source);",
            "}",
            "",
            "fn lookupRange16(items: Slice, source: u32) ?u32 {",
            "    if (source > 0xffff) return null;",
            "    var low: u32 = 0;",
            "    var high: u32 = items.count;",
            "    while (low < high) {",
            "        const middle = low + (high - low) / 2;",
            "        const offset = items.offset + middle * 6;",
            "        const source_start = readU16(offset);",
            "        const source_end = readU16(offset + 2);",
            "        if (source < source_start) high = middle else if (source > source_end) low = middle + 1 else return readU16(offset + 4) + (source - source_start);",
            "    }",
            "    return null;",
            "}",
            "",
            "fn readU32(offset: u32) u32 {",
            "    return std.mem.readInt(u32, blob[offset..][0..4], .big);",
            "}",
            "",
            "fn readU16(offset: u32) u16 {",
            "    return std.mem.readInt(u16, blob[offset..][0..2], .big);",
            "}",
            "",
            "fn readCodeBE(data: []const u8) u32 {",
            "    var value: u32 = 0;",
            "    for (data) |byte| value = (value << 8) | byte;",
            "    return value;",
            "}",
            "",
            "test \"predefined map registry and inherited lookup\" {",
            "    const horizontal = findPredefined(\"90ms-RKSJ-H\") orelse return error.TestUnexpectedResult;",
            "    try std.testing.expectEqual(@as(?u32, 633), lookupCode(horizontal, 0x8140));",
            "    const vertical = findPredefined(\"90ms-RKSJ-V\") orelse return error.TestUnexpectedResult;",
            "    try std.testing.expectEqual(@as(?u32, 633), lookupCode(vertical, 0x8140));",
            "    try std.testing.expectEqual(@as(?u32, 7887), lookupCode(vertical, 0x8141));",
            "    const long_range = findPredefined(\"CNS-EUC-H\") orelse return error.TestUnexpectedResult;",
            "    try std.testing.expectEqual(@as(?u32, 99), lookupCode(long_range, 0x8ea1a1a1));",
            "    const long_single = findPredefined(\"UniCNS-UTF16-H\") orelse return error.TestUnexpectedResult;",
            "    try std.testing.expectEqual(@as(?u32, 15861), lookupCode(long_single, 0xd840dc21));",
            "}",
            "",
            "test \"collection lookup respects supplement bounds\" {",
            "    try std.testing.expectEqual(@as(u21, 0x20), lookupCollection(.adobe_japan1, 7, 1).?.scalar);",
            "    try std.testing.expectEqualStrings(\"0\\xef\\xb8\\x80\", lookupCollection(.adobe_japan1, 7, 0x00e6).?.sequence);",
            "    try std.testing.expectEqualStrings(\"((\", lookupCollection(.adobe_korea1, 2, 0x200f).?.sequence);",
            "    try std.testing.expect(lookupCollection(.adobe_japan1, 0, 23059) == null);",
            "}",
            "",
        ]
    )
    return "\n".join(output), bytes(blob)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cmap-root", type=pathlib.Path, required=True)
    parser.add_argument("--mapping-root", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--binary-output", type=pathlib.Path)
    parser.add_argument("--check", action="store_true", help="fail when generated outputs are stale")
    args = parser.parse_args()

    rendered, binary = generate(args.cmap_root, args.mapping_root)
    binary_output = args.binary_output or args.output.with_suffix(".bin")
    if args.check:
        if not args.output.is_file() or args.output.read_text(encoding="utf-8") != rendered:
            raise SystemExit(f"stale generated CMap metadata: {args.output}")
        if not binary_output.is_file() or binary_output.read_bytes() != binary:
            raise SystemExit(f"stale generated CMap binary: {binary_output}")
        return

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(rendered, encoding="utf-8")
    binary_output.parent.mkdir(parents=True, exist_ok=True)
    binary_output.write_bytes(binary)


if __name__ == "__main__":
    main()

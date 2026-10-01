"""Godot 3 PCK tooling. Always build a new archive; never mutate the source."""
from __future__ import annotations

import hashlib
import struct
from pathlib import Path

HEADER = struct.Struct('<4s21I')
TAIL = struct.Struct('<QQ16s')


def archive_index(path: Path) -> tuple[list, dict]:
    with path.open('rb') as stream:
        header = list(HEADER.unpack(stream.read(HEADER.size)))
        if header[0] != b'GDPC' or header[1] != 1:
            raise ValueError('Expected a Godot 3 format-1 PCK')
        entries = {}
        for _ in range(header[-1]):
            length, = struct.unpack('<I', stream.read(4))
            name = stream.read(length).rstrip(b'\0').decode('utf-8')
            offset, size, digest = TAIL.unpack(stream.read(TAIL.size))
            if name in entries or offset + size > path.stat().st_size:
                raise ValueError(f'Invalid PCK entry: {name}')
            entries[name] = (offset, size, digest)
    return header, entries


def read_entry(path: Path, name: str) -> bytes:
    _, entries = archive_index(path)
    offset, size, digest = entries[name]
    with path.open('rb') as stream:
        stream.seek(offset)
        value = stream.read(size)
    if hashlib.md5(value).digest() != digest:
        raise ValueError(f'PCK checksum mismatch: {name}')
    return value


def build_archive(source: Path, destination: Path, replacements: dict[str, bytes], remove=()) -> None:
    if source.resolve() == destination.resolve():
        raise ValueError('Refusing to overwrite the input archive')
    header, entries = archive_index(source)
    names = sorted((set(entries) | set(replacements)) - set(remove))
    encoded = {name: name.encode() + b'\0' * (-len(name.encode()) % 4) for name in names}
    offset = HEADER.size + sum(4 + len(encoded[name]) + TAIL.size for name in names)
    offset = (offset + 15) // 16 * 16
    destination.parent.mkdir(parents=True, exist_ok=True)
    temp = destination.with_suffix(destination.suffix + '.building')
    table = []
    with source.open('rb') as src, temp.open('w+b') as dst:
        dst.seek(offset)
        for name in names:
            if name in replacements:
                value = replacements[name]
            else:
                start, size, expected = entries[name]
                src.seek(start)
                value = src.read(size)
                if hashlib.md5(value).digest() != expected:
                    raise ValueError(f'Source checksum mismatch: {name}')
            table.append((name, dst.tell(), len(value), hashlib.md5(value).digest()))
            dst.write(value)
            dst.write(b'\0' * (-dst.tell() % 16))
        dst.seek(0)
        header[-1] = len(names)
        dst.write(HEADER.pack(*header))
        for name, start, size, digest in table:
            dst.write(struct.pack('<I', len(encoded[name])))
            dst.write(encoded[name])
            dst.write(TAIL.pack(start, size, digest))
    temp.replace(destination)


def project_entries(data: bytes) -> dict[str, bytes]:
    if data[:4] != b'ECFG':
        raise ValueError('Expected Godot project.binary')
    count, = struct.unpack_from('<I', data, 4)
    result, pos = {}, 8
    for _ in range(count):
        length, = struct.unpack_from('<I', data, pos)
        pos += 4
        name = data[pos:pos + length].decode()
        pos += length
        length, = struct.unpack_from('<I', data, pos)
        pos += 4
        result[name] = data[pos:pos + length]
        pos += length
    if pos != len(data):
        raise ValueError('Unexpected project settings trailer')
    return result


def variant(value) -> bytes:
    if isinstance(value, str):
        encoded = value.encode()
        return struct.pack('<II', 4, len(encoded)) + encoded + b'\0' * (-len(encoded) % 4)
    if isinstance(value, bool):
        return struct.pack('<II', 1, int(value))
    if isinstance(value, int):
        return struct.pack('<Ii', 2, value)
    raise TypeError(type(value).__name__)


def encode_project(entries: dict[str, bytes]) -> bytes:
    result = bytearray(b'ECFG' + struct.pack('<I', len(entries)))
    for name, value in entries.items():
        encoded = name.encode()
        result += struct.pack('<I', len(encoded)) + encoded
        result += struct.pack('<I', len(value)) + value
    return bytes(result)

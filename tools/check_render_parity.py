#!/usr/bin/env python3
"""Opt-in framebuffer/CPU parity for the three non-spherical worlds.

Uses project-generated RGBA8, unfiltered PNG captures. This checks execution,
frame packing, and presentation, not an independent algebra implementation.
"""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib


def decode_capture(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("Invalid PNG signature")
    offset = 8
    compressed = bytearray()
    width = height = 0
    complete = False
    srgb = None
    while offset < len(data):
        length = struct.unpack_from(">I", data, offset)[0]
        tag = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        checksum = struct.unpack_from(">I", data, offset + 8 + length)[0]
        if zlib.crc32(tag + payload) != checksum:
            raise ValueError("Invalid PNG checksum")
        if tag == b"IHDR":
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            if (depth, color, compression, filtering, interlace) != (8, 6, 0, 0, 0):
                raise ValueError("Expected non-interlaced RGBA8 capture")
        elif tag == b"sRGB":
            if payload != b"\0":
                raise ValueError("Unsupported sRGB rendering intent")
            srgb = True
        elif tag == b"gAMA":
            if payload != struct.pack(">I", 100000):
                raise ValueError("Unsupported capture gamma")
            srgb = False
        elif tag == b"IDAT":
            compressed.extend(payload)
        elif tag == b"IEND":
            if payload or offset + length + 12 != len(data):
                raise ValueError("Invalid PNG end chunk")
            complete = True
            break
        offset += length + 12
    if not complete or srgb is None:
        raise ValueError("Missing PNG end chunk or color encoding")
    rows = zlib.decompress(compressed)
    stride = width * 4 + 1
    if not width or not height or len(rows) != stride * height:
        raise ValueError("Invalid capture dimensions")
    if any(rows[y * stride] != 0 for y in range(height)):
        raise ValueError("Expected project capture's unfiltered rows")
    return width, height, b"".join(rows[y * stride + 1:(y + 1) * stride] for y in range(height)), srgb


def color_byte(value, srgb):
    value = max(0, min(1, value))
    if srgb:
        value = 12.92 * value if value <= 0.0031308 else 1.055 * value ** (1 / 2.4) - 0.055
    return int(value * 255 + 0.5)


def compare_samples(width, height, pixels, samples, srgb):
    if not samples:
        raise ValueError("Empty reference sample set")
    mismatches = []
    for sample in samples:
        x, y = sample["x"], sample["y"]
        if not (0 <= x < width and 0 <= y < height):
            raise ValueError("Reference sample outside framebuffer")
        offset = (y * width + x) * 4
        actual = list(pixels[offset:offset + 3])
        expected = [color_byte(value, srgb) for value in sample["rgb"]]
        if max(abs(a - b) for a, b in zip(actual, expected)) > 1:
            mismatches.append({**sample, "actual": actual})
    return mismatches


def self_test():
    def chunk(tag, payload):
        return struct.pack(">I", len(payload)) + tag + payload + struct.pack(">I", zlib.crc32(tag + payload))
    data = (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
            + chunk(b"gAMA", struct.pack(">I", 100000))
            + chunk(b"IDAT", zlib.compress(b"\0\x0a\x14\x1e\xff"))
            + chunk(b"IEND", b""))
    width, height, pixels, srgb = decode_capture(data)
    if srgb or color_byte(0, True) != 0 or color_byte(1, True) != 255 or color_byte(0.5, True) != 188 or color_byte(0.003, True) != 10:
        raise AssertionError("Capture transfer function mismatch")
    srgb_data = data.replace(chunk(b"gAMA", struct.pack(">I", 100000)), chunk(b"sRGB", b"\0"))
    if not decode_capture(srgb_data)[3]:
        raise AssertionError("sRGB metadata was not recognized")
    sample = {"x": 0, "y": 0, "rgb": [10 / 255, 20 / 255, 31 / 255], "surface": "cube"}
    if compare_samples(width, height, pixels, [sample], srgb):
        raise AssertionError("One-byte quantization tolerance rejected")
    sample["rgb"][2] = 32 / 255
    if len(compare_samples(width, height, pixels, [sample], srgb)) != 1:
        raise AssertionError("Injected color mismatch was not detected")
    for invalid in [data[:20], data[:-1], data[:50] + b"\xff" + data[51:]]:
        try:
            decode_capture(invalid)
        except (ValueError, struct.error, zlib.error):
            continue
        raise AssertionError("Invalid capture accepted")
    print("render parity decoder/comparator self-check passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worlds", type=Path)
    parser.add_argument("--reference", type=Path)
    parser.add_argument("--self-test", action="store_true")
    arguments = parser.parse_args()
    if arguments.self_test:
        self_test()
        return
    if arguments.worlds is None or arguments.reference is None:
        parser.error("--worlds and --reference are required")
    root = Path(__file__).resolve().parent.parent
    if not (root / "assets/spherical/world.s3obj.json").is_file():
        parser.error("GPU demos are checkout-only; canonical asset is missing")
    environment = os.environ.copy()
    # Isolate controlled poses from optional interactive/capture settings.
    for key in ("ZMATH_DEMO_WALK", "ZMATH_DEMO_PITCH", "ZMATH_DEMO_WORLD", "ZMATH_DEMO_FRAMES"):
        environment.pop(key, None)
    with tempfile.TemporaryDirectory(prefix="zmath-render-parity-") as directory:
        for world in ("euclidean", "isometric", "hyperbolic"):
            surfaces = set()
            for index, pose in enumerate(((0, 0, 0), (1, 0.15, 0.2))):
                capture = Path(directory) / f"{world}-{index}.png"
                environment["ZMATH_DEMO_CAPTURE"] = str(capture)
                subprocess.run([str(arguments.worlds.resolve()), "--world", world, "--pose", *map(str, pose)],
                               cwd=root, env=environment, check=True, timeout=60)
                width, height, pixels, srgb = decode_capture(capture.read_bytes())
                reference = subprocess.run([str(arguments.reference.resolve()), world, str(width), str(height), *map(str, pose)],
                                           cwd=root, capture_output=True, text=True, check=True, timeout=30)
                samples = json.loads(reference.stdout)
                surfaces.update(sample["surface"] for sample in samples)
                mismatches = compare_samples(width, height, pixels, samples, srgb)
                if mismatches:
                    raise RuntimeError(f"{world} pose {pose}: {len(mismatches)}/{len(samples)} mismatches; first={mismatches[0]}")
                print(f"{world} pose {pose}: {len(samples)} samples within one RGB byte")
            if not {"cube", "ground"} <= surfaces:
                raise RuntimeError(f"{world}: insufficient scene coverage, surfaces={sorted(surfaces)}")


if __name__ == "__main__":
    main()

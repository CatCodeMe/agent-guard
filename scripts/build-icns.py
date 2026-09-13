#!/usr/bin/env python3
"""Pack the generated PNG variants into a small, standards-compatible ICNS file."""

from __future__ import annotations

import struct
import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: build-icns.py ICONSET_DIR OUTPUT_ICNS")

    iconset = Path(sys.argv[1])
    output = Path(sys.argv[2])
    variants = [
        (b"icp4", "icon_16x16.png"),
        (b"icp5", "icon_32x32.png"),
        (b"ic07", "icon_128x128.png"),
        (b"ic08", "icon_256x256.png"),
        (b"ic09", "icon_512x512.png"),
        (b"ic10", "icon_512x512@2x.png"),
    ]

    entries = []
    for kind, name in variants:
        data = (iconset / name).read_bytes()
        entries.append(kind + struct.pack(">I", len(data) + 8) + data)

    payload = b"".join(entries)
    output.write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)


if __name__ == "__main__":
    main()

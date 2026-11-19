#!/usr/bin/env python3
"""Rend fixe la taille du segment 0 d'un conteneur LUKS2 (« size »: "dynamic" → nombre d'octets), pour les
tests du redimensionnement (phase 18) : cryptsetup luksFormat ne sait pas créer un segment de taille fixe.

Usage : luks2_segment_fixe.py <image> <taille en octets>
Les deux en-têtes sont réécrits avec leur somme SHA-256 recalculée."""
import hashlib
import json
import struct
import sys


def main():
    path, size = sys.argv[1], int(sys.argv[2])
    with open(path, "r+b") as f:
        hdr = f.read(4096)
        if hdr[:6] != b"LUKS\xba\xbe":
            sys.exit("pas un en-tête LUKS2")
        hs = struct.unpack(">Q", hdr[8:16])[0]
        for off in (0, hs):
            f.seek(off)
            h = bytearray(f.read(hs))
            area = bytes(h[4096:hs])
            meta = json.loads(area.split(b"\0", 1)[0])
            meta["segments"]["0"]["size"] = str(size)
            txt = json.dumps(meta, separators=(",", ":")).encode()
            if len(txt) >= hs - 4096:
                sys.exit("JSON trop grand")
            h[4096:hs] = txt + b"\0" * (hs - 4096 - len(txt))
            h[448:512] = b"\0" * 64
            h[448:480] = hashlib.sha256(bytes(h)).digest()
            f.seek(off)
            f.write(h)


if __name__ == "__main__":
    main()

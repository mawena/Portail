#!/usr/bin/env python3
"""Juge indépendant des ZIP chiffrés (phase 14) : WinZip AES (AE-1 / AE-2, 128 à 256 bits) et ancien
chiffrement ZIP (« ZipCrypto »).

Écrit d'après la note de WinZip « AES Encryption Information » et l'APPNOTE de PKWARE, sans le code du
moteur ni libarchive : PBKDF2-HMAC-SHA1 (1000 tours), AES-CTR à compteur petit-boutiste commençant à 1,
HMAC-SHA1 tronqué à 10 octets (module `cryptography`), deflate brut par zlib.

  zipaesjuge.py read <archive.zip> <mot de passe>
      relit tout ; imprime « nom|taille|sha256 » par fichier, « nom/|dossier » par dossier, puis « aes N »
      (entrées AES) et « zipcrypto N ».
  zipaesjuge.py write <dossier> <archive.zip> <mot de passe> [--zipcrypto]
      écrit un ZIP chiffré (AES-256 AE-2 par défaut), noms UTF-8 (bit 11), deflate niveau 6.

Codes de sortie : 0 succès, 2 mot de passe faux, 3 archive abîmée ou non conforme, 1 usage.
"""
import hashlib
import hmac
import os
import struct
import sys
import time
import zipfile
import zlib

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC


class Abime(Exception):
    pass


class MauvaisMotDePasse(Exception):
    pass


KEYLEN = {1: 16, 2: 24, 3: 32}


def derive(pw, salt, keylen):
    k = PBKDF2HMAC(algorithm=hashes.SHA1(), length=2 * keylen + 2, salt=salt, iterations=1000).derive(pw)
    return k[:keylen], k[keylen:2 * keylen], k[2 * keylen:]


def aes_ctr(key, data):
    """AES-CTR de WinZip : bloc compteur = entier petit-boutiste sur 16 octets, à partir de 1."""
    enc = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
    out = bytearray(len(data))
    for i in range(0, len(data), 16):
        ks = enc.update((i // 16 + 1).to_bytes(16, "little"))
        blk = data[i:i + 16]
        out[i:i + len(blk)] = bytes(a ^ b for a, b in zip(blk, ks))
    return bytes(out)


# --- ZipCrypto (APPNOTE § 6.1) --------------------------------------------------------------------------
_T = []
for _n in range(256):
    _c = _n
    for _ in range(8):
        _c = (_c >> 1) ^ 0xEDB88320 if _c & 1 else _c >> 1
    _T.append(_c)


def _crc_tab(crc, b):
    return (crc >> 8) ^ _T[(crc ^ b) & 0xFF]


class ZipCrypto:
    def __init__(self, pw):
        self.k = [0x12345678, 0x23456789, 0x34567890]
        for c in pw:
            self.update(c)

    def update(self, c):
        k = self.k
        k[0] = _crc_tab(k[0], c)
        k[1] = ((k[1] + (k[0] & 0xFF)) * 134775813 + 1) & 0xFFFFFFFF
        k[2] = _crc_tab(k[2], (k[1] >> 24) & 0xFF)

    def byte(self):
        t = (self.k[2] | 2) & 0xFFFF
        return ((t * (t ^ 1)) >> 8) & 0xFF

    def decrypt(self, data):
        out = bytearray()
        for c in data:
            p = c ^ self.byte()
            self.update(p)
            out.append(p)
        return bytes(out)

    def encrypt(self, data):
        out = bytearray()
        for p in data:
            out.append(p ^ self.byte())
            self.update(p)
        return bytes(out)


# --- Lecture ------------------------------------------------------------------------------------------
def read(path, pw):
    z = zipfile.ZipFile(path)
    f = open(path, "rb")
    lines = []
    n_aes = n_zc = 0
    for info in z.infolist():
        f.seek(info.header_offset)
        lh = f.read(30)
        if lh[:4] != b"PK\x03\x04":
            raise Abime("en-tête local")
        nlen, xlen = struct.unpack("<HH", lh[26:30])
        f.seek(nlen + xlen, 1)
        data = f.read(info.compress_size)
        method = info.compress_type
        if info.flag_bits & 1:
            if method == 99:
                n_aes += 1
                ex = info.extra
                i = 0
                aes = None
                while i + 4 <= len(ex):
                    hid, sz = struct.unpack("<HH", ex[i:i + 4])
                    if hid == 0x9901:
                        aes = ex[i + 4:i + 4 + sz]
                    i += 4 + sz
                if aes is None or len(aes) != 7 or aes[2:4] != b"AE":
                    raise Abime("champ AES")
                vendor, strength, method = struct.unpack("<H", aes[0:2])[0], aes[4], struct.unpack("<H", aes[5:7])[0]
                kl = KEYLEN[strength]
                salt, pwv, body, mac = data[:kl // 2], data[kl // 2:kl // 2 + 2], data[kl // 2 + 2:-10], data[-10:]
                ek, ak, v = derive(pw, salt, kl)
                if v != pwv:
                    raise MauvaisMotDePasse()
                if not hmac.compare_digest(hmac.new(ak, body, hashlib.sha1).digest()[:10], mac):
                    raise Abime("HMAC de %s" % info.filename)
                data = aes_ctr(ek, body)
                check_crc = vendor == 1
            else:
                n_zc += 1
                zc = ZipCrypto(pw)
                hdr = zc.decrypt(data[:12])
                chk = (info.CRC >> 24) & 0xFF if not (info.flag_bits & 8) else (info._raw_time >> 8) & 0xFF
                if hdr[11] != chk:
                    raise MauvaisMotDePasse()
                data = zc.decrypt(data[12:])
                check_crc = True
        else:
            check_crc = True
        if method == 8:
            data = zlib.decompress(data, -15)
        elif method != 0:
            raise Abime("méthode %d" % method)
        if len(data) != info.file_size:
            raise Abime("taille de %s" % info.filename)
        if check_crc and zlib.crc32(data) != info.CRC:
            raise Abime("CRC de %s" % info.filename)
        if info.is_dir():
            lines.append("%s|dossier" % info.filename)
        else:
            lines.append("%s|%d|%s" % (info.filename, len(data), hashlib.sha256(data).hexdigest()))
    lines.append("aes %d" % n_aes)
    lines.append("zipcrypto %d" % n_zc)
    return lines


# --- Écriture -----------------------------------------------------------------------------------------
def dos_time(t):
    lt = time.localtime(t)
    return ((lt.tm_hour << 11) | (lt.tm_min << 5) | (lt.tm_sec // 2),
            ((lt.tm_year - 1980) << 9) | (lt.tm_mon << 5) | lt.tm_mday)


def write(src, path, pw, zipcrypto=False):
    entries = []
    for root, dirs, files in os.walk(src):
        dirs.sort()
        rel = os.path.relpath(root, src)
        if rel != ".":
            entries.append((rel.replace(os.sep, "/") + "/", None))
        for fn in sorted(files):
            p = os.path.join(root, fn)
            entries.append((os.path.relpath(p, src).replace(os.sep, "/"), p))
    out = bytearray()
    central = bytearray()
    for name, p in entries:
        nb = name.encode("utf-8")
        tm, dt = dos_time(time.time())
        if p is None:
            flags, method, crc, csize, usize, extra, data = 0x800, 0, 0, 0, 0, b"", b""
            ver = 20
        else:
            raw = open(p, "rb").read()
            co = zlib.compressobj(6, zlib.DEFLATED, -15)
            comp = co.compress(raw) + co.flush()
            crc = zlib.crc32(raw)
            usize = len(raw)
            if zipcrypto:
                zc = ZipCrypto(pw)
                hdr = os.urandom(11) + bytes([(crc >> 24) & 0xFF])
                data = zc.encrypt(hdr + comp)
                flags, method, extra, ver = 0x801, 8, b"", 20
            else:
                salt = os.urandom(16)
                ek, ak, pwv = derive(pw, salt, 32)
                body = aes_ctr(ek, comp)
                data = salt + pwv + body + hmac.new(ak, body, hashlib.sha1).digest()[:10]
                flags, method, ver = 0x801, 99, 51
                extra = struct.pack("<HHH2sBH", 0x9901, 7, 2, b"AE", 3, 8)
                crc = 0  # AE-2
            csize = len(data)
        off = len(out)
        out += struct.pack("<IHHHHHIIIHH", 0x04034B50, ver, flags, method, tm, dt, crc, csize, usize, len(nb), len(extra))
        out += nb + extra + data
        attr = (0o40755 << 16) | 0x10 if p is None else (0o100644 << 16)
        central += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 0x031E, ver, flags, method, tm, dt, crc, csize, usize,
                               len(nb), len(extra), 0, 0, 0, attr, off)
        central += nb + extra
    cd_off = len(out)
    out += central
    out += struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(entries), len(entries), len(central), cd_off, 0)
    open(path, "wb").write(out)


def main(argv):
    try:
        if len(argv) >= 3 and argv[0] == "read":
            for l in read(argv[1], argv[2].encode()):
                print(l)
            return 0
        if len(argv) >= 4 and argv[0] == "write":
            write(argv[1], argv[2], argv[3].encode(), "--zipcrypto" in argv[4:])
            print("ok")
            return 0
    except MauvaisMotDePasse:
        print("mot de passe faux")
        return 2
    except (Abime, zipfile.BadZipFile, zlib.error, KeyError) as e:
        print("abîmé :", e)
        return 3
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Juge indépendant du format age v1 (destinataire scrypt), phase 14.

Écrit d'après la spécification age (https://age-encryption.org/v1, C2SP), sans le code du moteur :
scrypt, ChaCha20-Poly1305, HKDF-SHA256 et HMAC-SHA256 viennent du module `cryptography` de Python.

  agejuge.py decrypt <entrée.age> <sortie> <mot de passe>
  agejuge.py encrypt <entrée> <sortie.age> <mot de passe> <log2 N> [--empty-last]

`--empty-last` fabrique un fichier NON conforme (un morceau vide marqué « dernier » après des morceaux
pleins) pour vérifier que le moteur le refuse. Codes de sortie : 0 succès, 2 mot de passe faux,
3 fichier abîmé ou non conforme, 1 usage.
"""
import base64
import hashlib
import hmac
import os
import sys

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt
from cryptography.exceptions import InvalidTag

INTRO = b"age-encryption.org/v1"
LABEL = b"age-encryption.org/v1/scrypt"
CHUNK = 64 * 1024


class Abime(Exception):
    pass


class MauvaisMotDePasse(Exception):
    pass


def b64e(b):
    return base64.b64encode(b).rstrip(b"=")


def b64d(s):
    if b"=" in s or b"\r" in s or b"\n" in s:
        raise Abime("base64 avec remplissage ou retour")
    pad = b"=" * (-len(s) % 4)
    out = base64.b64decode(s + pad, validate=True)
    if b64e(out) != s:
        raise Abime("base64 non canonique")
    return out


def hkdf(ikm, salt, info):
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=info).derive(ikm)


def scrypt_key(pw, salt, log2n):
    return Scrypt(salt=LABEL + salt, length=32, n=1 << log2n, r=8, p=1).derive(pw)


def chunk_nonce(i, last):
    return i.to_bytes(11, "big") + (b"\x01" if last else b"\x00")


def encrypt(data, pw, log2n, empty_last=False):
    file_key = os.urandom(16)
    salt = os.urandom(16)
    body = ChaCha20Poly1305(scrypt_key(pw, salt, log2n)).encrypt(b"\x00" * 12, file_key, None)
    hdr = INTRO + b"\n-> scrypt " + b64e(salt) + b" " + str(log2n).encode() + b"\n" + b64e(body) + b"\n---"
    mac = hmac.new(hkdf(file_key, b"", b"header"), hdr, hashlib.sha256).digest()
    out = bytearray(hdr + b" " + b64e(mac) + b"\n")
    nonce = os.urandom(16)
    out += nonce
    aead = ChaCha20Poly1305(hkdf(file_key, nonce, b"payload"))
    chunks = [data[i:i + CHUNK] for i in range(0, len(data), CHUNK)] or [b""]
    if empty_last:
        chunks = [c for c in chunks if c] + [b""]
    for i, c in enumerate(chunks):
        out += aead.encrypt(chunk_nonce(i, i == len(chunks) - 1), c, None)
    return bytes(out)


def parse_header(blob):
    lines = []
    pos = 0
    while True:
        nl = blob.find(b"\n", pos)
        if nl < 0:
            raise Abime("en-tête tronqué")
        line = blob[pos:nl]
        lines.append(line)
        pos = nl + 1
        if line.startswith(b"---"):
            break
    if lines[0] != INTRO:
        raise Abime("pas un fichier age v1")
    stanzas = []
    i = 1
    while not lines[i].startswith(b"---"):
        if not lines[i].startswith(b"-> "):
            raise Abime("ligne de destinataire attendue")
        args = lines[i][3:].split(b" ")
        i += 1
        body = b""
        while True:
            if lines[i].startswith(b"---"):
                raise Abime("corps sans fin")
            body += lines[i]
            done = len(lines[i]) < 64
            i += 1
            if done:
                break
        stanzas.append((args, b64d(body)))
    mac_line = lines[i]
    if not mac_line.startswith(b"--- "):
        raise Abime("ligne du MAC")
    mac = b64d(mac_line[4:])
    hdr_for_mac = blob[:pos - len(mac_line) - 1] + b"---"
    return stanzas, mac, hdr_for_mac, pos


def decrypt(blob, pw):
    stanzas, mac, hdr_for_mac, pos = parse_header(blob)
    if len(stanzas) != 1 or stanzas[0][0][0] != b"scrypt":
        raise Abime("un seul destinataire scrypt attendu")
    args, body = stanzas[0]
    if len(args) != 3 or len(body) != 32:
        raise Abime("destinataire scrypt mal formé")
    salt = b64d(args[1])
    if len(salt) != 16 or not args[2].isdigit() or args[2].startswith(b"0"):
        raise Abime("sel ou facteur")
    log2n = int(args[2])
    if not 1 <= log2n <= 22:
        raise Abime("facteur hors bornes")
    try:
        file_key = ChaCha20Poly1305(scrypt_key(pw, salt, log2n)).decrypt(b"\x00" * 12, body, None)
    except InvalidTag:
        raise MauvaisMotDePasse()
    if not hmac.compare_digest(hmac.new(hkdf(file_key, b"", b"header"), hdr_for_mac, hashlib.sha256).digest(), mac):
        raise Abime("MAC de l'en-tête")
    nonce = blob[pos:pos + 16]
    if len(nonce) != 16:
        raise Abime("nonce tronqué")
    aead = ChaCha20Poly1305(hkdf(file_key, nonce, b"payload"))
    payload = blob[pos + 16:]
    out = bytearray()
    full = CHUNK + 16
    n = max(1, -(-len(payload) // full))
    for i in range(n):
        c = payload[i * full:(i + 1) * full]
        last = i == n - 1
        if len(c) < 16 or (last and len(c) == 16 and i > 0):
            raise Abime("morceau trop court ou dernier morceau vide")
        try:
            out += aead.decrypt(chunk_nonce(i, last), c, None)
        except InvalidTag:
            raise Abime("morceau %d" % i)
    return bytes(out)


def main(argv):
    if len(argv) >= 4 and argv[0] == "decrypt":
        blob = open(argv[1], "rb").read()
        try:
            data = decrypt(blob, argv[3].encode())
        except MauvaisMotDePasse:
            print("mot de passe faux")
            return 2
        except Abime as e:
            print("abîmé :", e)
            return 3
        open(argv[2], "wb").write(data)
        print("ok", len(data), hashlib.sha256(data).hexdigest())
        return 0
    if len(argv) >= 5 and argv[0] == "encrypt":
        data = open(argv[1], "rb").read()
        blob = encrypt(data, argv[3].encode(), int(argv[4]), "--empty-last" in argv[5:])
        open(argv[2], "wb").write(blob)
        print("ok", len(blob))
        return 0
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

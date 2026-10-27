#!/usr/bin/env python3
"""Serveur IA d'essai de Portail (phase 15) : joue le contrat d'API (docs/ia/contrat-api.md) pour le développement et
les essais sur le téléphone. Bibliothèque standard de Python seulement.

    python3 tools/ia/serveur-essai.py                       # http://127.0.0.1:8765, clé essai-portail
    python3 tools/ia/serveur-essai.py --port 9000
    ADB_SERIAL=192.168.0.104:5555 python3 tools/ia/serveur-essai.py --reverse   # adb reverse, retiré à l'arrêt
    python3 tools/ia/serveur-essai.py --comme-ollama        # sans /health et sans clé, comme Ollama

Modèles :
  essai-court   réponse courte en Markdown (bloc de code compris), en quelques morceaux ;
  essai-long    flux de 2 000 morceaux numérotés « 0001 » à « 2000 » (pertes et doublons se voient) ;
  essai-erreur  quelques morceaux, puis une erreur au milieu du flux (data: {"error": …}) ;
  essai-lent    pause de 70 s avant le premier octet (délai sans octet de Portail : 60 s).

Le journal (sortie d'erreur) ne garde que méthode, chemin, code et durée : ni clé, ni contenu.
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CLE = "essai-portail"
VERSION = "essai-0.1.0"
MODELES = ["essai-court", "essai-long", "essai-erreur", "essai-lent"]
REPONSE_COURTE = (
    "Bonjour ! Voici une **réponse d'essai** de Portail.\n\n"
    "- un élément de liste ;\n- un autre, avec `du code en ligne`.\n\n"
    "```kotlin\nval message = \"Bonjour\"\nprintln(message)\n```\n"
)
MORCEAUX_LONGS = 2000
PAUSE_LENTE = 70


def morceaux_courts():
    # coupé n'importe où, accents compris : le client doit recoller sans perte
    pas = 7
    return [REPONSE_COURTE[i:i + pas] for i in range(0, len(REPONSE_COURTE), pas)]


class Gestionnaire(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "PortailEssai/" + VERSION
    sys_version = ""

    # --- utilitaires

    def log_message(self, fmt, *args):  # journal sans contenu : remplacé par _journal
        pass

    def _journal(self, code):
        duree = (time.monotonic() - self._debut) * 1000
        sys.stderr.write(f"{time.strftime('%H:%M:%S')}  {self.command} {self.path.split('?')[0]} → {code} "
                         f"({duree:.0f} ms)\n")

    def _json(self, code, objet):
        corps = json.dumps(objet, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(corps)))
        self.end_headers()
        self.wfile.write(corps)
        self._journal(code)

    def _erreur(self, code, message, type_, code_erreur=None):
        self._json(code, {"error": {"message": message, "type": type_, "code": code_erreur}})

    def _autorise(self):
        if self.server.sans_cle:
            return True
        if self.headers.get("Authorization", "") == "Bearer " + CLE:
            return True
        manque = "Authorization" not in self.headers
        self._erreur(401, "Aucune clé API fournie." if manque else "Clé API invalide.", "auth_error", "invalid_api_key")
        return False

    def _corps(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return None

    # --- routes

    def do_GET(self):
        self._debut = time.monotonic()
        chemin = self.path.split("?")[0]
        if chemin == "/health" and not self.server.sans_sante:
            # publique, comme celle d'atelier.mawena.cloud
            self._json(200, {"status": "ok", "version": VERSION})
        elif chemin == "/v1/models":
            if self._autorise():
                self._json(200, {"object": "list", "data": [
                    {"id": m, "object": "model", "owned_by": "portail-essai"} for m in MODELES]})
        else:
            self._erreur(404, "Route inconnue.", "not_found")

    def do_POST(self):
        self._debut = time.monotonic()
        chemin = self.path.split("?")[0]
        if chemin not in ("/v1/chat/completions", "/v1/embeddings"):
            self._erreur(404, "Route inconnue.", "not_found")
            return
        if not self._autorise():
            return
        corps = self._corps()
        if not isinstance(corps, dict):
            self._erreur(400, "Corps JSON invalide.", "invalid_request_error")
            return
        if chemin == "/v1/embeddings":
            self._embeddings(corps)
        else:
            self._chat(corps)

    def _embeddings(self, corps):
        entree = corps.get("input")
        if isinstance(entree, str):
            entree = [entree]
        if not isinstance(entree, list) or not all(isinstance(t, str) for t in entree):
            self._erreur(400, "« input » doit être un texte ou une liste de textes.", "invalid_request_error")
            return
        data = []
        for i, t in enumerate(entree):
            h = hashlib.sha256(t.encode()).digest()
            data.append({"object": "embedding", "index": i, "embedding": [round(b / 255.0, 4) for b in h[:8]]})
        self._json(200, {"object": "list", "data": data, "model": corps.get("model")})

    def _chat(self, corps):
        modele = corps.get("model")
        messages = corps.get("messages")
        if not isinstance(messages, list) or not messages or not all(
                isinstance(m, dict) and m.get("role") in ("system", "user", "assistant")
                and isinstance(m.get("content"), str) for m in messages):
            self._erreur(400, "« messages » invalide.", "invalid_request_error")
            return
        if modele not in MODELES:
            self._erreur(404, f"Le modèle « {modele} » n'existe pas.", "invalid_request_error", "model_not_found")
            return
        if modele == "essai-lent":
            time.sleep(PAUSE_LENTE)
        if modele == "essai-long":
            morceaux = [f"{i:04d} " for i in range(1, MORCEAUX_LONGS + 1)]
        elif modele == "essai-erreur":
            morceaux = morceaux_courts()[:4]
        else:
            morceaux = morceaux_courts()
        if not corps.get("stream"):
            if modele == "essai-erreur":
                self._erreur(500, "Erreur d'essai du modèle.", "server_error")
                return
            texte = "".join(morceaux)
            self._json(200, {
                "id": "essai", "object": "chat.completion", "created": int(time.time()), "model": modele,
                "choices": [{"index": 0, "message": {"role": "assistant", "content": texte}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": sum(len(m["content"]) for m in messages) // 4,
                          "completion_tokens": len(texte) // 4, "total_tokens": 0},
            })
            return
        self._flux(modele, morceaux)

    def _flux(self, modele, morceaux):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

        def evenement(objet):
            self.wfile.write(b"data: " + json.dumps(objet, ensure_ascii=False).encode() + b"\n\n")
            self.wfile.flush()

        base = {"id": "essai", "object": "chat.completion.chunk", "created": int(time.time()), "model": modele}
        try:
            evenement({**base, "choices": [{"index": 0, "delta": {"role": "assistant"}, "finish_reason": None}]})
            self.wfile.write(": commentaire d'essai, à ignorer\n\n".encode())
            for t in morceaux:
                evenement({**base, "choices": [{"index": 0, "delta": {"content": t}, "finish_reason": None}]})
                if modele != "essai-long":
                    time.sleep(0.05)
            if modele == "essai-erreur":
                evenement({"error": {"message": "Erreur d'essai au milieu du flux.", "type": "server_error"}})
                self._journal("200, erreur en flux")
                return
            evenement({**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            self._journal(200)
        except (BrokenPipeError, ConnectionResetError):
            self._journal("200, coupé par le client")


def main():
    p = argparse.ArgumentParser(description="Serveur IA d'essai de Portail (contrat compatible OpenAI).")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--hote", default="127.0.0.1", help="adresse d'écoute (127.0.0.1 par défaut)")
    p.add_argument("--reverse", action="store_true", help="adb reverse du port vers le téléphone (ADB_SERIAL)")
    p.add_argument("--comme-ollama", action="store_true", help="sans /health et sans clé, comme Ollama")
    a = p.parse_args()

    serveur = ThreadingHTTPServer((a.hote, a.port), Gestionnaire)
    serveur.daemon_threads = True
    serveur.sans_cle = a.comme_ollama
    serveur.sans_sante = a.comme_ollama
    adb = None
    if a.reverse:
        adb = [os.environ.get("ADB", "adb")] + (["-s", os.environ["ADB_SERIAL"]] if os.environ.get("ADB_SERIAL") else [])
        subprocess.run(adb + ["reverse", f"tcp:{a.port}", f"tcp:{a.port}"], check=True)
    cle = "aucune" if a.comme_ollama else CLE
    print(f"Serveur IA d'essai sur http://{a.hote}:{a.port} (clé : {cle}) ; Ctrl+C pour arrêter.", flush=True)
    try:
        serveur.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        serveur.server_close()
        if adb:
            subprocess.run(adb + ["reverse", "--remove", f"tcp:{a.port}"], check=False)


if __name__ == "__main__":
    main()

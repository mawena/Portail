#!/usr/bin/env python3
"""Vérifie un serveur IA contre le contrat d'API de Portail (docs/ia/contrat-api.md), phase 15.

    python3 tools/ia/contrat_test.py http://127.0.0.1:8765 essai-portail     # serveur d'essai
    python3 tools/ia/contrat_test.py http://127.0.0.1:11434                  # Ollama, sans clé
    python3 tools/ia/contrat_test.py https://atelier.mawena.cloud            # sans clé : santé et 401 seulement

Chaque vérification affiche OK, ÉCHEC, ABSENT (route facultative absente) ou SAUTÉ. Code de sortie 0 si aucune
ÉCHEC. Bibliothèque standard seulement. N'affiche jamais la clé, et des réponses du modèle seulement leur longueur.
"""

import argparse
import json
import sys
import urllib.error
import urllib.request

MAUVAISE_CLE = "mauvaise-cle-portail"


class Resultats:
    def __init__(self):
        self.echecs = 0
        self.absents = []

    def ok(self, nom, detail=""):
        print(f"OK      {nom}{' : ' + detail if detail else ''}")

    def echec(self, nom, detail):
        self.echecs += 1
        print(f"ÉCHEC   {nom} : {detail}")

    def absent(self, nom, detail):
        self.absents.append(nom)
        print(f"ABSENT  {nom} : {detail}")

    def saute(self, nom, detail):
        print(f"SAUTÉ   {nom} : {detail}")


def requete(base, methode, chemin, cle, corps=None, delai=30):
    """Rend (code, en-têtes, octets) ; une erreur HTTP est une réponse comme une autre."""
    donnees = json.dumps(corps).encode() if corps is not None else None
    r = urllib.request.Request(base + chemin, data=donnees, method=methode)
    if cle:
        r.add_header("Authorization", "Bearer " + cle)
    if donnees is not None:
        r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=delai) as rep:
            return rep.status, rep.headers, rep.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()


def erreur_conforme(octets):
    """Corps d'erreur du contrat : {"error": {"message": "…", "type"?, "code"?}} ; rend le message ou None."""
    try:
        o = json.loads(octets)
    except ValueError:
        return None
    e = o.get("error") if isinstance(o, dict) else None
    if isinstance(e, dict) and isinstance(e.get("message"), str):
        return e["message"]
    return None


def flux(base, cle, corps, delai=60):
    """Lit un flux SSE : rend (code, morceaux de texte, fini par [DONE], erreur en cours de flux)."""
    r = urllib.request.Request(base + "/v1/chat/completions", data=json.dumps(corps).encode(), method="POST")
    r.add_header("Content-Type", "application/json")
    r.add_header("Accept", "text/event-stream")
    if cle:
        r.add_header("Authorization", "Bearer " + cle)
    morceaux, fini, erreur = [], False, None
    try:
        rep = urllib.request.urlopen(r, timeout=delai)
    except urllib.error.HTTPError as e:
        return e.code, morceaux, fini, erreur_conforme(e.read())
    with rep:
        type_ = rep.headers.get("Content-Type", "")
        if not type_.startswith("text/event-stream"):
            return rep.status, morceaux, fini, f"type de contenu « {type_} »"
        for brute in rep:
            ligne = brute.decode("utf-8").rstrip("\r\n")
            if not ligne.startswith("data:"):
                continue
            charge = ligne[5:].strip()
            if charge == "[DONE]":
                fini = True
                break
            o = json.loads(charge)
            if "error" in o:
                erreur = (o["error"] or {}).get("message", "")
                break
            for c in o.get("choices") or []:
                t = (c.get("delta") or {}).get("content")
                if t:
                    morceaux.append(t)
    return rep.status, morceaux, fini, erreur


def verifier(base, cle, modele, res):
    base = base.rstrip("/")

    # santé : facultative (Ollama n'en a pas) ; l'état se déduit alors de /v1/models
    code, _, corps = requete(base, "GET", "/health", cle, delai=5)
    if code == 404:
        res.absent("GET /health", "404, l'état se déduira de /v1/models")
    elif code == 200:
        try:
            o = json.loads(corps)
            if o.get("status") == "ok":
                res.ok("GET /health", f"version {o.get('version', '?')}")
            else:
                res.echec("GET /health", f"status « {o.get('status')} »")
        except ValueError:
            res.ok("GET /health", "200 sans JSON (vLLM) : en ligne, version inconnue")
    else:
        res.echec("GET /health", f"code {code}")

    code, _, corps = requete(base, "GET", "/v1/models", cle)
    if code == 401 and not cle:
        message = erreur_conforme(corps)
        if message is None:
            res.echec("GET /v1/models sans clé", "401 hors du format d'erreur du contrat")
        else:
            res.ok("GET /v1/models sans clé", f"401 au format du contrat (« {message} »)")
        res.saute("chat, flux, embeddings", "clé nécessaire")
        return
    if code != 200:
        res.echec("GET /v1/models", f"code {code}")
        return
    try:
        o = json.loads(corps)
        ids = [m["id"] for m in o["data"]]
        assert o.get("object") == "list"
        assert all(m.get("object") == "model" for m in o["data"])
    except (ValueError, KeyError, TypeError, AssertionError):
        res.echec("GET /v1/models", "liste hors du format du contrat")
        return
    res.ok("GET /v1/models", f"{len(ids)} modèle(s)")
    if not ids:
        res.saute("chat, flux", "aucun modèle")
        return
    m = modele or ("essai-court" if "essai-court" in ids else ids[0])
    messages = [{"role": "system", "content": "Réponds en une phrase."}, {"role": "user", "content": "Bonjour"}]

    code, _, corps = requete(base, "POST", "/v1/chat/completions", cle,
                             {"model": m, "messages": messages, "stream": False}, delai=120)
    try:
        o = json.loads(corps)
        texte = o["choices"][0]["message"]["content"]
        assert code == 200 and isinstance(texte, str) and o["choices"][0]["message"]["role"] == "assistant"
        res.ok("POST /v1/chat/completions", f"{m}, {len(texte)} caractère(s), fin « {o['choices'][0].get('finish_reason')} »")
    except (ValueError, KeyError, IndexError, TypeError, AssertionError):
        res.echec("POST /v1/chat/completions", f"code {code}, réponse hors du contrat")

    code, morceaux, fini, erreur = flux(base, cle, {"model": m, "messages": messages, "stream": True})
    if code != 200 or erreur is not None or not fini:
        res.echec("POST /v1/chat/completions (flux)", f"code {code}, [DONE] {'reçu' if fini else 'absent'}, erreur {erreur!r}")
    else:
        res.ok("POST /v1/chat/completions (flux)", f"{len(morceaux)} morceau(x), [DONE] reçu")

    code, _, corps = requete(base, "POST", "/v1/chat/completions", cle,
                             {"model": "modele-qui-n-existe-pas", "messages": messages, "stream": False})
    if code in (400, 404) and erreur_conforme(corps) is not None:
        res.ok("modèle inconnu", f"{code} au format du contrat")
    else:
        res.echec("modèle inconnu", f"code {code}, attendu 404 (ou 400) au format du contrat")

    code, _, corps = requete(base, "POST", "/v1/embeddings", cle, {"model": m, "input": ["Bonjour"]})
    if code in (404, 405, 501):
        res.absent("POST /v1/embeddings", f"{code} (facultatif)")
    else:
        try:
            v = json.loads(corps)["data"][0]["embedding"]
            assert code == 200 and len(v) > 0 and all(isinstance(x, (int, float)) for x in v)
            res.ok("POST /v1/embeddings", f"dimension {len(v)}")
        except (ValueError, KeyError, IndexError, TypeError, AssertionError):
            res.absent("POST /v1/embeddings", f"code {code}, pas d'embeddings pour {m} (facultatif)")

    if not cle:
        res.saute("mauvaise clé", "serveur sans clé")
        return
    for methode, chemin, corps in (
        ("GET", "/v1/models", None),
        ("POST", "/v1/chat/completions", {"model": m, "messages": messages, "stream": False}),
        ("POST", "/v1/chat/completions", {"model": m, "messages": messages, "stream": True}),
        ("POST", "/v1/embeddings", {"model": m, "input": ["Bonjour"]}),
    ):
        code, _, rep = requete(base, methode, chemin, MAUVAISE_CLE, corps)
        nom = f"mauvaise clé {methode} {chemin}{' (flux)' if corps and corps.get('stream') else ''}"
        if code == 401 and erreur_conforme(rep) is not None:
            res.ok(nom, "401 au format du contrat")
        else:
            res.echec(nom, f"code {code}, attendu 401 au format du contrat")


def main():
    p = argparse.ArgumentParser(description="Vérifie un serveur IA contre le contrat d'API de Portail.")
    p.add_argument("url", help="URL de base, par exemple http://127.0.0.1:8765")
    p.add_argument("cle", nargs="?", default=None, help="clé API (facultative)")
    p.add_argument("--modele", default=None, help="modèle à essayer (par défaut essai-court ou le premier)")
    a = p.parse_args()
    res = Resultats()
    try:
        verifier(a.url, a.cle, a.modele, res)
    except (urllib.error.URLError, OSError) as e:
        res.echec("connexion", str(getattr(e, "reason", e)))
    print()
    if res.echecs:
        print(f"Contrat NON respecté : {res.echecs} échec(s).")
        return 1
    absents = f" (absent : {', '.join(res.absents)})" if res.absents else ""
    print(f"Contrat respecté{absents}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env bash
# Serveur SSH d'essai de la phase 13 (T12) : MINA SSHD sur 127.0.0.1:2222 et écho TCP sur 127.0.0.1:2223, comptes et
# clé jetables. Le téléphone le joint par adb reverse ; Ctrl+C l'arrête et efface son dossier temporaire.
#   tools/ssh/serveur-essai.sh            # serveur seul
#   ADB_SERIAL=192.168.0.104:5555 tools/ssh/serveur-essai.sh --reverse   # avec adb reverse (retiré à l'arrêt)
set -euo pipefail
cd "$(dirname "$0")/../../android"
if [[ "${1:-}" == "--reverse" ]]; then
  ADB="${ADB:-adb}"
  S=(); [[ -n "${ADB_SERIAL:-}" ]] && S=(-s "$ADB_SERIAL")
  "$ADB" "${S[@]}" reverse tcp:2222 tcp:2222
  "$ADB" "${S[@]}" reverse tcp:2223 tcp:2223
  trap '"$ADB" "${S[@]}" reverse --remove tcp:2222; "$ADB" "${S[@]}" reverse --remove tcp:2223' EXIT
fi
./gradlew -q --offline :app:runSshTestServer

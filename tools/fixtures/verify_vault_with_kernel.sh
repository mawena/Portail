#!/usr/bin/env bash
# Vérifie par le noyau Linux les coffres créés par Portail (phase 14). À lancer par l'utilisateur, avec
# sudo (loop, dm-crypt, montage) ; jamais par un agent.
#
# Préparation (sans root) :
#   FL_KEEP=1 ctest --test-dir build/native -R '^test_vault$'
#   -> build/native/tmp/coffre-<exfat|ext4>.luks et coffre-<exfat|ext4>.sha256
# Usage :
#   sudo tools/fixtures/verify_vault_with_kernel.sh [build/native/tmp]
#
# Pour chaque coffre : le fichier est ouvert tel quel par dm-crypt (cryptsetup open sur le fichier : pas de
# table de partitions), l'outil de référence le juge en lecture seule (fsck.exfat -n, e2fsck -fn), le
# système de fichiers est monté en lecture seule par le pilote du noyau (exfat, ext4) et son contenu
# comparé au manifeste écrit par test_vault (sha256sum -c).
set -uo pipefail
DIR="${1:-build/native/tmp}"
[ "$(id -u)" = 0 ] || { echo "à lancer avec sudo" >&2; exit 2; }
shopt -s nullglob
COFFRES=("$DIR"/coffre-exfat.luks "$DIR"/coffre-ext4.luks)
[ ${#COFFRES[@]} -gt 0 ] || { echo "aucun coffre dans $DIR (FL_KEEP=1 ctest -R '^test_vault\$')" >&2; exit 2; }

PASS="phrase de passe du coffre"
MAP=portail-coffre-verif
MNT="$(mktemp -d)"
nettoyer() {
  umount "$MNT" 2>/dev/null || true
  cryptsetup close "$MAP" 2>/dev/null || true
}
trap 'nettoyer; rmdir "$MNT"' EXIT

echecs=0
for coffre in "${COFFRES[@]}"; do
  nom="$(basename "$coffre" .luks)"     # coffre-<fs>
  fs="${nom#coffre-}"
  man="$(realpath -m "$DIR/$nom.sha256")"
  err() { echo "ÉCHEC $nom : $*"; echecs=$((echecs + 1)); nettoyer; }
  [ -f "$man" ] || { err "manifeste $man absent"; continue; }
  printf '%s' "$PASS" | cryptsetup open --readonly --key-file - "$coffre" "$MAP" || { err "cryptsetup open"; continue; }
  dev="/dev/mapper/$MAP"
  case "$fs" in
    exfat) type=exfat; juge=(fsck.exfat -n) ;;
    ext4)  type=ext4;  juge=(e2fsck -fn) ;;
    *) err "système inconnu $fs"; continue ;;
  esac
  sortie="$("${juge[@]}" "$dev" 2>&1)" || { err "${juge[0]} :"; echo "$sortie"; continue; }
  mount -o ro -t "$type" "$dev" "$MNT" || { err "montage $type"; continue; }
  sortie="$(cd "$MNT" && sha256sum -c "$man" 2>&1)" || { err "contenu :"; echo "$sortie"; continue; }
  etiquette="$(blkid -p -o value -s LABEL "$dev")"
  nettoyer
  echo "OK     $nom (étiquette « $etiquette »)"
done
echo "${#COFFRES[@]} coffre(s), $echecs échec(s)"
exit $((echecs > 0))

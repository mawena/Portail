#!/usr/bin/env bash
# Vérifie par le noyau Linux les partitions créées (partops-*) ou redimensionnées (redim-*) par Portail
# (phase 18). À lancer par l'utilisateur, avec sudo (loop, dm-crypt, montage) ; jamais par un agent.
#
# Préparation (sans root) :
#   FL_KEEP=1 ctest --test-dir build/native -R '^test_part(ops|_resize)$'
#   -> build/native/tmp/partops-<fs>-<clair|luks>-<gpt|mbr>.img (partition 3, entre les voisines 1 et 2)
#   -> build/native/tmp/redim-<fs>-<clair|luks…>-<agrandie|reduite>.img (partition 1, voisine 2)
# Usage :
#   sudo tools/fixtures/verify_partitions_with_kernel.sh [build/native/tmp]
#
# Pour chaque image : périphérique loop avec ses partitions (losetup -P) ; les partitions 1 et 2 (voisines,
# remplies d'octets 0x5A) doivent exister ; la partition 3, créée par Portail entre elles, est ouverte par
# dm-crypt si chiffrée (phrase « phrase de test »), montée en écriture par le pilote du noyau (vfat, exfat,
# ext4, ntfs3), un fichier y est écrit, puis l'outil de référence repasse (fsck.fat, fsck.exfat, e2fsck,
# ntfsfix) : aucune erreur.
set -uo pipefail
DIR="${1:-build/native/tmp}"
[ "$(id -u)" = 0 ] || { echo "à lancer avec sudo" >&2; exit 2; }
shopt -s nullglob
IMAGES=("$DIR"/partops-*.img "$DIR"/redim-*.img)
[ ${#IMAGES[@]} -gt 0 ] || { echo "aucune image dans $DIR (FL_KEEP=1 ctest -R '^test_part(ops|_resize)\$')" >&2; exit 2; }

PASS="phrase de test"
MAP=portail-verif
MNT="$(mktemp -d)"
LOOP=""
nettoyer() {
  umount "$MNT" 2>/dev/null || true
  cryptsetup close "$MAP" 2>/dev/null || true
  [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
  LOOP=""
}
trap 'nettoyer; rmdir "$MNT"' EXIT

echecs=0
for img in "${IMAGES[@]}"; do
  nom="$(basename "$img" .img)"           # partops-<fs>-<clair|luks>-<gpt|mbr> ou redim-<fs>-<mode>-<sens>
  IFS=- read -r genre fs mode _ <<<"$nom"
  if [ "$genre" = redim ]; then cible=1 voisines=(2); else cible=3 voisines=(1 2); fi
  err() { echo "ÉCHEC $nom : $*"; echecs=$((echecs + 1)); nettoyer; }

  LOOP="$(losetup -f -P --show "$img")" || { err "losetup"; continue; }
  udevadm settle 2>/dev/null || sleep 1
  manque=0
  for v in "${voisines[@]}"; do [ -b "${LOOP}p$v" ] || manque=1; done
  [ "$manque" = 0 ] || { err "partitions voisines absentes"; continue; }
  part="${LOOP}p$cible"
  [ -b "$part" ] || { err "partition $cible absente"; continue; }
  dev="$part"
  if [ "$mode" != clair ]; then
    printf '%s' "$PASS" | cryptsetup open --key-file - "$part" "$MAP" || { err "cryptsetup open"; continue; }
    dev="/dev/mapper/$MAP"
  fi
  case "$fs" in
    fat32) type=vfat;  juge=(fsck.fat -n) ;;
    exfat) type=exfat; juge=(fsck.exfat -n) ;;
    ext4)  type=ext4;  juge=(e2fsck -fn) ;;
    ntfs)  type=ntfs3; juge=(ntfsfix -n) ;;
    *) err "système inconnu $fs"; continue ;;
  esac
  mount -t "$type" "$dev" "$MNT" || { err "montage $type"; continue; }
  echo "écrit par le noyau" >"$MNT/noyau.txt" && sync || { err "écriture"; continue; }
  umount "$MNT" || { err "démontage"; continue; }
  sortie="$("${juge[@]}" "$dev" 2>&1)" || { err "${juge[0]} :"; echo "$sortie"; continue; }
  etiquette="$(blkid -p -o value -s LABEL "$dev")"
  nettoyer
  echo "OK     $nom (étiquette « $etiquette »)"
done
echo "${#IMAGES[@]} image(s), $echecs échec(s)"
exit $((echecs > 0))

#ifndef FLULUKS_JNI_HANDLES_H
#define FLULUKS_JNI_HANDLES_H

/* Moteur à poignées du pont JNI (sans jni.h : compilé aussi dans les tests PC).
 *
 * Poignées : entiers 64 bits > 0, (génération << 16) | indice, dans une table de FJ_MAX entrées typées
 * (disque, volume, fichier, archive, écrivain et lecteur age). Parents : un volume appartient à un disque, un
 * fichier à un volume ; une archive, un flux age ou un disque de coffre posé sur un fichier du moteur
 * appartiennent à ce fichier (fermer le fichier, démonter son volume ou fermer son disque les ferme d'abord ;
 * un coffre est alors démonté de force, synchronisé).
 *
 * Phrases de passe (phase 14) : toute fonction qui en reçoit une la copie d'abord en mémoire sécurisée et
 * efface cette copie avant de rendre la main, succès comme échec ; l'appelant efface la sienne. Une poignée périmée, inconnue, négative ou d'un autre type → FL_EINVAL,
 * sans jamais déréférencer l'objet. Toute valeur < 0 renvoyée est un code fl_err.
 *
 * Fils d'exécution : tout est sûr entre fils. La table est protégée par un mutex, jamais tenu pendant
 * une opération longue (déverrouillage Argon2, lecture USB). Chaque opération prend une référence sur
 * l'objet visé ; une fermeture marque l'entrée « en fermeture » (plus aucune nouvelle opération ne
 * l'atteint, FL_EINVAL), attend la fin des opérations en cours, puis libère l'objet. Fermer un disque
 * démonte d'abord de force ses volumes ; démonter de force ferme d'abord les fichiers du volume. */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "json_out.h"

#ifdef __cplusplus
extern "C" {
#endif

#define FJ_MAX 1024u
/* Plus grande lecture servie par un seul fj_pread (au-delà : lecture partielle). */
#define FJ_PREAD_MAX (4u * 1024u * 1024u)
/* Nombre maximal d'entrées rendues par fj_list (au-delà : FL_ENOMEM). */
#define FJ_LIST_MAX 262144u

/* Image disque (secteurs de 512 octets), avec le cache 64 Kio × 256 par-dessus ; read_only = false
 * pour les tests d'écriture. */
int64_t fj_open_image(const char *path, bool read_only);
/* Disque USB (usbdevfs, LUN 0) ouvert en lecture-écriture (MODE SENSE décide de la protection) + cache
 * 64 Kio × 256. Le fd reste à l'appelant. FL_ENOTSUP hors Linux/Android. */
int64_t fj_open_usb(int fd, int iface, int ep_in, int ep_out);
/* Coffre (phase 14) sur un fichier du téléphone : le descripteur appartient au disque dès l'appel (fermé avec
 * lui, ou tout de suite en cas d'échec). Sans cache (le noyau en a un). */
int64_t fj_open_disk_fd(int fd, bool read_only);
/* Coffre sur le fichier `file` (fj_open_file, en écriture ou non) d'un volume du moteur, de `size` octets
 * (FL_EINVAL : pas en secteurs de 512 octets, ou plus grand que le fichier ; FL_EFBIG au-delà de 4 Gio − 1 octet
 * sur FAT32). Disque enfant du fichier, qui lui appartient dès l'appel : fj_close_disk le ferme ensuite (et le
 * synchronise) ; un échec le ferme tout de suite. Sans cache : un cache à chargement partagé entre fils se
 * bloquerait sous le verrou des systèmes de fichiers. */
int64_t fj_open_disk_file(int64_t file, int64_t size);
/* Démonte de force les volumes du disque, puis ferme toute la pile (transport USB en dernier) ; un coffre sur un
 * fichier du moteur ferme ensuite ce fichier. */
int fj_close_disk(int64_t disk);

/* JSON du disque dans *out (voir task-6-brief) ; renvoie FL_OK, ou un fl_err (out non défini). */
int fj_scan(int64_t disk, fl_json *out);
/* Ouvre la partition d'indice part_index : tranche, fl_probe, déverrouillage LUKS si besoin
 * (pass peut être NULL pour un volume en clair), puis ext4, en écriture si want_rw et si le système de
 * fichiers le permet (sinon lecture seule, raison dans fj_statfs ; want_rw = false → RO_USER, disque
 * protégé → RO_WP). Poignée volume ou fl_err. */
int64_t fj_mount(int64_t disk, uint32_t part_index, const void *pass, size_t passlen, bool want_rw);
/* fj_mount avec le seul emplacement de clé `slot` (−1 : tous ; FL_ENOENT s'il n'existe pas). */
int64_t fj_mount_slot(int64_t disk, uint32_t part_index, int slot, const void *pass, size_t passlen, bool want_rw);
/* Sans force : FL_EBUSY si un fichier est ouvert, ou si le disque parent est en cours de fermeture
 * (c'est lui qui démontera le volume). Un enregistrement d'enfant (fj_mount, fj_open_file) sous un
 * parent en cours de fermeture rend aussi FL_EBUSY. Avec force : ferme les fichiers (en attendant les
 * lectures en cours) puis démonte. Un volume en écriture est synchronisé puis démonté (journal arrêté,
 * SYNCHRONIZE CACHE) ; disque mort : tout est libéré quand même et l'erreur est rendue.
 * Contrat d'erreur (sans force) : seul FL_EBUSY laisse le volume intact et utilisable (on peut réessayer).
 * Toute autre erreur (EIO…) est rendue APRÈS destruction du volume : système de fichiers libéré, clé
 * effacée, poignée invalide (un second appel rend FL_EINVAL). L'appelant doit alors oublier le volume ;
 * des données ont pu ne pas être écrites. */
int fj_unmount(int64_t vol, bool force);

int fj_statfs(int64_t vol, fl_json *out);
/* {"name", "type", "size", "mtime", "mode", "uid", "gid"} ; fj_list rend les mêmes objets. */
int fj_stat(int64_t vol, const char *path, fl_json *out);
/* Tableau trié par nom (ordre des octets). */
int fj_list(int64_t vol, const char *path, fl_json *out);

/* flags : FL_O_* (fs.h). */
int64_t fj_open_file(int64_t vol, const char *path, int flags);
/* Octets lus (<= min(len, FJ_PREAD_MAX)), 0 = fin, < 0 = fl_err. */
int64_t fj_pread(int64_t file, void *buf, size_t len, uint64_t off);
/* Octets écrits (= len, len <= FJ_PREAD_MAX sinon FL_EINVAL) ou fl_err. */
int64_t fj_pwrite(int64_t file, const void *buf, size_t len, uint64_t off);
int fj_truncate(int64_t file, uint64_t size);
/* Un fichier écrit est synchronisé à la fermeture (code rendu). */
int fj_close_file(int64_t file);
int fj_mkdir(int64_t vol, const char *path);
int fj_unlink(int64_t vol, const char *path);
int fj_rmdir(int64_t vol, const char *path);
int fj_rename(int64_t vol, const char *from, const char *to);
int fj_sync(int64_t vol);

/* Formate tout le disque (phase 8). json : {"fs": "fat32"|"exfat"|"ext4"|"ntfs", "encrypted": bool,
 * "label": texte, "kdf_mem_kib": Kio d'Argon2 (1 Gio par défaut), "uid"/"gid": propriétaire de la racine
 * ext4 (1000 par défaut), "table": "none" pour un coffre (pas de table de partitions, phase 14)}. FL_EBUSY si un volume du disque est ouvert ou en cours d'ouverture (et,
 * pendant le formatage, fj_mount sur ce disque rend FL_EBUSY), FL_EROFS si le disque est en lecture seule,
 * FL_EINVAL pour des options invalides ; sinon le code de fl_format. progress (facultatif) : pourcentage
 * croissant, depuis ce fil. */
int fj_format(int64_t disk, const char *json, const void *pass, size_t passlen, void (*progress)(int pct, void *arg),
              void *arg);

/* Archives (phase 9). Une poignée d'archive lit (fj_arc_*) ou écrit un ZIP (fj_arcw_*) sur un descripteur, ou
 * sur un fichier du moteur ouvert par fj_open_file. La source appartient à la poignée dès l'appel, même en
 * cas d'échec : le descripteur est fermé, le fichier aussi (synchronisé) par la fermeture de l'archive.
 * Une archive sur un fichier est fermée sans commit avec lui (fj_close_file, démontage, fj_close_disk). */
/* size : taille du fichier (fj_stat). FL_ENOTSUP : pas une archive reconnue.
 * mode (phase 14) : NULL ou "plain", "aes" (ZIP protégé par mot de passe), "age" (archive dans un flux age,
 * FL_EBADPASS dès l'ouverture si la phrase est fausse). pass : NULL en "plain" (accepté pour lire un ZIP protégé
 * reçu d'ailleurs), obligatoire sinon (FL_EINVAL). */
int64_t fj_arc_open_fd(int fd, const char *mode, const void *pass, size_t passlen);
int64_t fj_arc_open_file(int64_t file, int64_t size, const char *mode, const void *pass, size_t passlen);
/* 1 : entrée suivante dans *out, {"name": base64 des octets bruts du nom, "type": "f"|"d"|"l"|"h"|"o",
 * "size": octets (-1 inconnue), "mtime", "encrypted", "raw": flux compressé seul (.gz, .xz) dont le nom n'est
 * pas celui du fichier} ; 0 : fin de l'archive ; < 0 : fl_err. */
int fj_arc_next(int64_t arc, fl_json *out);
/* Données de l'entrée courante : octets lus (<= FJ_PREAD_MAX), 0 à la fin de l'entrée, ou fl_err. */
int64_t fj_arc_read(int64_t arc, void *buf, size_t len);
int fj_arc_close(int64_t arc);
/* mode : NULL ou "plain", "aes" (ZIP AES-256), "age" (ZIP dans un flux age, log2 N = 18). */
int64_t fj_arcw_open_fd(int fd, const char *mode, const void *pass, size_t passlen);
int64_t fj_arcw_open_file(int64_t file, const char *mode, const void *pass, size_t passlen);
/* json : {"name": chemin UTF-8 relatif, "type": "f"|"d", "size", "mtime", "store": stockage sans compression}. */
int fj_arcw_add(int64_t arc, const char *json);
int fj_arcw_write(int64_t arc, const void *buf, size_t len);
/* commit : termine le ZIP ; sinon abandon. Ferme la destination dans les deux cas. */
int fj_arcw_close(int64_t arc, bool commit);

/* Fichiers age (phase 14), mêmes règles de propriété que les archives : la source ou la destination appartient
 * à la poignée dès l'appel (fermée aussi en cas d'échec) ; sur un fichier du moteur, la poignée est son enfant. */
int64_t fj_agew_open_fd(int fd, const void *pass, size_t passlen, uint8_t log2n);
int64_t fj_agew_open_file(int64_t file, const void *pass, size_t passlen, uint8_t log2n);
int fj_agew_write(int64_t w, const void *buf, size_t len);
/* commit : dernier morceau marqué ; sinon abandon (la destination est incomplète, donc illisible). */
int fj_agew_close(int64_t w, bool commit);
/* Lecteur à accès aléatoire. log2 N accepté : jusqu'à 20 si 0,8 × la mémoire disponible le permet (FL_ENOMEM
 * sinon). */
int64_t fj_ager_open_fd(int fd, const void *pass, size_t passlen);
int64_t fj_ager_open_file(int64_t file, int64_t size, const void *pass, size_t passlen);
/* Taille en clair. */
int64_t fj_ager_size(int64_t r);
/* Octets lus (<= FJ_PREAD_MAX), 0 à la fin, ou fl_err. */
int64_t fj_ager_pread(int64_t r, void *buf, size_t len, uint64_t off);
int fj_ager_close(int64_t r);
/* log2 N d'un fichier age scrypt (sans phrase), 0 si ce n'en est pas un, ou fl_err. Ne prend ni le descripteur
 * ni le fichier. */
int fj_age_peek_fd(int fd);
int fj_age_peek_file(int64_t file, int64_t size);
/* Nouvelle phrase d'un fichier age (même clé de fichier, charge utile recopiée sans être déchiffrée, puis
 * vérifiée). Source : in_fd >= 0, sinon in_file (de in_size octets) ; destination : out_fd >= 0, sinon out_file.
 * Les deux appartiennent à l'appel et sont fermées (la destination synchronisée). */
int fj_age_rewrap(int in_fd, int64_t in_file, int64_t in_size, int out_fd, int64_t out_file, const void *old,
                  size_t oldlen, const void *nw, size_t nwlen, uint8_t log2n);

/* Emplacements de clé d'un coffre (disque LUKS2 sans table, phase 14) : FL_ENOTSUP pour un disque avec une
 * table. {"version": 1|2, "slots": [numéros]}. */
int fj_luks_slots(int64_t disk, fl_json *out);
/* fl_luks2_slot_set / fl_luks2_slot_remove ; FL_EBUSY si un volume du disque est monté ou en cours de
 * montage (et, pendant l'opération, fj_mount et fj_format sur ce disque rendent FL_EBUSY). */
int fj_luks_slot_set(int64_t disk, int slot, const void *auth, size_t authlen, const void *nw, size_t nwlen,
                     uint32_t kdf_mem_kib, uint32_t kdf_time);
int fj_luks_slot_remove(int64_t disk, int slot, const void *auth, size_t authlen);

/* Références et état « en fermeture » d'une entrée (tests) ; FL_EINVAL si la poignée est invalide. */
int fj_debug_slot(int64_t h, unsigned *refs, bool *closing);
/* Tests : fn(arg) est appelée par fj_mount, référence du disque tenue, juste avant d'enregistrer le
 * volume. NULL retire le crochet. À poser avant de lancer des fils, à retirer après leur fin. */
void fj_debug_set_mount_hook(void (*fn)(void *), void *arg);
/* Nombre d'entrées occupées (tests). */
unsigned fj_debug_used(void);
/* Vidages (fl_bdev_flush) reçus par le disque sous son cache, ou fl_err (tests). */
int64_t fj_debug_flushes(int64_t disk);

#ifdef __cplusplus
}
#endif

#endif

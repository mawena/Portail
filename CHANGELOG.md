# Journal des versions

Les versions suivent la [gestion sémantique de version](https://semver.org/lang/fr/). Chaque version publiée
porte une étiquette `vX.Y.Z` sur `main`. Le détail de chaque phase est dans la
[feuille de route](docs/superpowers/plans/2026-10-17-fluluks-feuille-de-route.md).

## À venir

- **1.7.0** : chiffrement de fichiers et de dossiers (age, ZIP AES-256), coffres de fichiers, chacun avec son mot
  de passe.
- **1.8.0** : intégration IA avec des serveurs auto-hébergés compatibles OpenAI.
- **1.9.0** : gestion des partitions (créer, supprimer, redimensionner).
- **1.10.0** : vérification et réparation des disques.

## 1.6.1 — 2026-10-25

### Corrigé

- Les dossiers distants SFTP et FTP, le terminal et les tunnels SSH marchent de nouveau dans la version de
  publication. La permission Internet manquait dans le manifeste de publication.

## 1.6.0 — 2026-10-24

### Ajouté

- Terminal SSH compatible xterm sur les serveurs SFTP enregistrés, avec barre de touches.
- Sessions gardées en arrière-plan.
- Trousseau de clés, installation d'une clé sur le serveur.
- Commandes enregistrées et tunnels.

## 1.5.0 — 2026-10-23

### Ajouté

- Lecteur vidéo en portrait par défaut, rotation selon Android, boutons Tourner et cadenas.
- Choix des pistes audio et des sous-titres.
- Gestes comme dans VLC : glisser et toucher deux fois pour avancer ou reculer.

## 1.4.0 — 2026-10-23

### Ajouté

- Thèmes clair et sombre.
- Accessibilité et TalkBack en français.
- Grands écrans, liste ou grille partout.
- Recherche dans tous les stockages.
- Aide, à propos et licences des bibliothèques.

## 1.3.0 — 2026-10-23

### Ajouté

- Lecteurs intégrés : photos, musique en arrière-plan, vidéo avec sous-titres, éditeur de texte.
- Dossiers distants FTP et SFTP.

## 1.2.0 — 2026-10-23

### Ajouté

- Compression et décompression : ZIP, 7z, RAR, TAR, GZ, XZ.
- Corbeille et analyse de l'espace.
- Propriétés et SHA-256.
- Renommage par lot et raccourcis de l'accueil.

## 1.1.0 — 2026-10-22

### Ajouté

- Formatage des disques USB en FAT32, exFAT, ext4 ou NTFS, en clair ou chiffrés LUKS2.

## 1.0.0 — 2026-10-22

### Amélioré

- Robustesse : verrouillage automatique, débranchement inattendu.
- Performances.
- Écriture ext4 essayée sur un vrai disque.

## 0.5.0 — 2026-10-22

### Ajouté

- Nouveau nom, Portail (anciennement FluLuks), et logo.
- Gestionnaire de fichiers : téléphone, carte SD et disques USB.

## 0.4.0 — 2026-10-20

### Ajouté

- NTFS en lecture et écriture.

## 0.3.0 — 2026-10-19

### Ajouté

- FAT12, FAT16, FAT32 et exFAT en lecture et écriture.

## 0.2.1 — 2026-10-18

### Corrigé

- Écriture ext4 différée par fichier, une transaction par 4 Mio.

## 0.2.0 — 2026-10-18

### Ajouté

- Écriture ext4 sur les disques USB LUKS : créer, modifier, renommer, déplacer, copier, supprimer.
- Journal compatible avec Ubuntu.

## 0.1.0 — 2026-10-18

### Ajouté

- Lecture seule des disques USB LUKS1 et LUKS2 avec ext4, sans root.
- Contenu visible dans l'application Fichiers d'Android.

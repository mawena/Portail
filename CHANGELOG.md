# Journal des versions

Les versions suivent la [gestion sémantique de version](https://semver.org/lang/fr/). Chaque version publiée
porte une étiquette `vX.Y.Z` sur `main`. Le détail de chaque phase est dans la
[feuille de route](ROADMAP.md).

## À venir

- **1.11.0** : gestion des partitions (créer, supprimer, redimensionner).
- **1.12.0** : vérification et réparation des disques.
- **1.13.0** : voix de narration (sa propre voix clonée avec consentement vérifié, fichiers audio marqués comme synthétiques).

## 1.10.0 — 2026-11-12

### Ajouté

- Onglets dans le module Fichiers : plusieurs dossiers ouverts à la fois, huit au plus. Chaque onglet garde son
  dossier, sa sélection, sa position dans la liste et ce qu'on y a ouvert (un coffre, une recherche).
- Ouvrir dans un nouvel onglet depuis le menu d'un dossier, le menu de l'explorateur, les résultats de recherche et le
  module Coffres ; barre d'onglets dès deux onglets, avec l'icône du stockage, le nom du dossier, une croix, **+** et un
  appui long pour fermer l'onglet ou les autres.
- Retour remonte dans l'onglet, puis le ferme à son accueil et montre celui d'avant ; le presse-papiers est commun aux
  onglets (copier ou couper dans l'un, coller dans l'autre).
- Un disque débranché ou un coffre fermé ramène à son accueil chaque onglet qui l'affichait, avec un seul message.

## 1.9.0 — 2026-10-27

### Ajouté

- Analyseur de stockage, comme celui d'Ubuntu : place réellement occupée (liens physiques comptés une fois, fichiers
  creux), anneaux concentriques ou carte proportionnelle synchronisés avec l'arbre, plus gros fichiers.
- Analyse du téléphone, des cartes SD, des disques USB, des coffres et des dossiers distants, avec progression,
  annulation et résultats au fur et à mesure ; analyses de la session gardées.
- Menu d'un élément : afficher dans l'explorateur, copier le chemin, propriétés, corbeille, exclure des analyses.
- Barre de navigation entre les modules Fichiers, Coffres, Analyseur, Distants et IA ; rail sur grand écran.

## 1.8.0 — 2026-10-27

### Ajouté

- Serveurs IA auto-hébergés compatibles OpenAI : clé API scellée, serveur par défaut, Tester la connexion.
- Chat en flux : Markdown, blocs de code, arrêter, régénérer, serveur, modèle et prompt système par conversation.
- Automatisations : modèles de prompt à variables, lancement à la demande ou planifié, historique des exécutions.
- Certificats auto-signés de confiance, conversations masquées dans les captures.

### Corrigé

- Les automatisations planifiées s'exécutent aussi sur un Wi-Fi sans accès à Internet, pour un serveur de la maison.

## 1.7.0 — 2026-10-25

### Ajouté

- Chiffrement de fichiers et de dossiers au format age, et archives ZIP protégées en AES-256.
- Coffres de fichiers LUKS2, ouverts comme un stockage.
- Mot de passe et clé de secours d'un coffre, déverrouillage biométrique.
- Coffres fermés à l'écran éteint et masqués dans les captures, sur réglage.

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

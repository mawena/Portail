# Essais de la phase 14 (chiffrement et coffres) sur le Pixel 4 XL

APK de débogage de la branche `feature/chiffrement`, installée avant l'essai. Le numéro affiché reste celui de la
version précédente jusqu'à la v1.7.0, et le débogage rend l'application plus lente qu'une version finale (le calcul
des clés, volontairement lent, l'est encore plus). Cochez chaque ligne faite et notez ce qui ne va pas sous la ligne.

**Préparation** :
- sur le téléphone, une photo, une courte vidéo et un dossier de quelques fichiers (par exemple `Documents/Essai`) ;
- le disque USB LUKS2/ext4 habituel et son câble ;
- sur le PC Ubuntu : `age`, `7z` (paquet `7zip` ou `p7zip-full`), `bsdtar` (paquet `libarchive-tools`) et
  `cryptsetup` ; `adb` pour récupérer les fichiers, ou un câble et l'application Fichiers.

Choisissez des mots de passe d'essai que vous n'utilisez nulle part ailleurs, et notez-les : **sans eux, rien n'est
récupérable**.

## 1. Chiffrer et déchiffrer des fichiers

- [x] Dans l'explorateur du téléphone, menu ⋮ d'une photo → **Chiffrer…** : chiffrement fort, ce dossier, un mot de
      passe de 8 caractères au moins (la force s'affiche), confirmé → `photo.jpg.age` apparaît à côté de la photo.
      → piloté par adb le 2026-10-25 : force « moyen » affichée, `photo.jpg.age` créé (68,8 ko).
- [x] Menu ⋮ du dossier `Essai` → **Chiffrer…** : `Essai.zip.age` apparaît.
      → piloté par adb : « Terminé : 5 fichiers », `Essai.zip.age` créé (293,5 ko).
- [x] Sur le disque USB déverrouillé, sélectionner un dossier → **Chiffrer…** → **Autre dossier…** : un dossier du
      disque comme destination. Le fichier chiffré y apparaît ; la barre du bas a montré la progression.
      → essayé par l'utilisateur sur le Pixel, concluant (2026-10-25).
- [x] **Générer un mot de passe** : « 20 caractères » puis « 6 mots » remplissent les deux champs ; **Copier**
      annonce l'effacement du presse-papiers dans 60 s (vérifiez en collant ailleurs une minute plus tard).
      → piloté par adb : « 20 caractères » (force excellent) et « 6 mots » (force bon) remplissent les deux champs ; message « effacé du presse-papiers dans 60 s ». **Défaut trouvé** : le presse-papiers n'était jamais effacé (Android 13 notifie deux fois chaque copie). Corrigé (90865d4) ; vérifié : 80 s après la copie, « Coller » n'est plus proposé.
- [x] Toucher `photo.jpg.age` → mot de passe → **Ouvrir** : la photo s'affiche dans la visionneuse de Portail.
      Aucun `photo.jpg` en clair n'apparaît dans le dossier.
      → piloté par adb : la visionneuse de Portail montre « photo.jpg 1 / 1 » ; dossier inchangé, aucune copie en clair dans les fichiers de l'application (recherche par SHA-256).
- [x] Chiffrer la vidéo, la toucher → **Ouvrir** : elle se lit ; l'avance rapide (glisser sur la barre) fonctionne.
      → piloté par adb : la vidéo déchiffrée se lit en entier (20 s) ; « Lecture » depuis la fin repart de 0 (retour en arrière) ; une touche vers 17 s, 3 s après le départ, termine la lecture 2 s plus tard (journal du décodeur : flush, puis arrêt de l'AudioTrack).
- [x] Toucher un fichier chiffré et saisir un **mauvais mot de passe** : « Mot de passe incorrect », le dialogue reste
      ouvert.
      → piloté par adb : « Mot de passe incorrect », le dialogue reste ouvert, le champ est vidé.
- [x] `Essai.zip.age` → **Déchiffrer ici** : le dossier `Essai` revient (nom différent s'il existe déjà), avec ses
      fichiers intacts.
      → piloté par adb : pour une archive chiffrée le bouton s'appelle « Extraire ici » ; le dossier revient sous le nom « Essai (1) », ses 5 fichiers identiques à l'original (SHA-256).
- [x] Un fichier chiffré → **Vérifier** : « Fichier intact ».
      → piloté par adb : « Fichier intact » pour photo.jpg.age.
- [x] Menu ⋮ d'un `.age` → **Changer le mot de passe** : l'ancien ne l'ouvre plus, le nouveau si.
      → piloté par adb : photo.jpg.age réécrit ; contrôlé par agejuge.py : l'ancien mot de passe est refusé, le nouveau rend la photo identique (SHA-256).
- [x] Chiffrer en **ZIP chiffré (AES-256)** : la mise en garde (noms visibles) s'affiche ; après le chiffrement,
      **Partager le fichier chiffré** propose les applications de partage.
      → piloté par adb : la mise en garde (noms et tailles visibles) s'affiche ; « Terminé : 5 fichiers » pour Essai.zip ; **Partager le fichier chiffré** (sur photo.zip) ouvre le choix d'applications d'Android, qui montre « photo.zip » (fermé sans envoyer).

## 2. Sur le PC

- [x] Le ZIP chiffré, copié sur le PC : `7z x fichier.zip` demande le mot de passe et extrait les fichiers.
      → `7z` absent du PC : Essai.zip et photo.zip relus par le juge indépendant `tools/fixtures/zipaesjuge.py` (WinZip AES-256) : 6 entrées AES, toutes identiques aux originaux (SHA-256) ; mauvais mot de passe refusé.
- [x] `age -d photo.jpg.age > photo.jpg` demande le mot de passe ; la photo s'ouvre.
      → `age` absent du PC : déchiffré par le juge indépendant `tools/fixtures/agejuge.py`, photo identique (SHA-256), mauvais mot de passe refusé.
- [x] `age -d Essai.zip.age | bsdtar -xf -` rend le dossier.
      → `age` et `bsdtar` absents du PC : déchiffré par `agejuge.py`, extrait par le module zipfile de Python ; les 5 fichiers et le sous-dossier sont identiques (sha256sum -c).
- [x] (facultatif) Un ZIP protégé créé sur le PC (`7z a -p -tzip essai.zip dossier`) : copié sur le téléphone et
      touché → **Extraire ici** demande le mot de passe et extrait.
      → `7z` absent : deux ZIP protégés fabriqués sur le PC par `zipaesjuge.py write` (AES-256 et ancien ZipCrypto), copiés sur le téléphone ; **Extraire ici** demande le mot de passe (« Archive protégée par un mot de passe ») et extrait les 5 fichiers, identiques (SHA-256).

## 3. Coffres

- [x] Accueil → section **Coffres** → **Créer un coffre** : nom « Essai », emplacement le téléphone, 256 Mio, exFAT,
      mot de passe. La progression s'affiche, **Annuler** est possible ; à la fin, « Coffre « Essai » créé » et le
      coffre apparaît, « Fermé ».
      → piloté par adb, emplacement Download/portail-tests/phase14 : la progression s'affiche (« Création du coffre de Essai.luks · 79 % ») avec **Annuler** ; « Coffre « Essai » créé », tuile « 256 Mio · exFAT · Fermé ». Annulation essayée sur un coffre de 4 Gio : « Création du coffre annulée », aucun fichier laissé. 16 Gio grisé (12,4 Go libres).
- [x] **Ouvrir** → mot de passe : l'explorateur s'ouvre à la racine du coffre ; y copier quelques photos et une vidéo.
      → piloté par adb : l'explorateur s'ouvre à la racine (titre « Essai ») ; photo.jpg et video.mp4 copiés (Copier puis « Coller ici »). **Défaut trouvé** : à la première ouverture d'un coffre, l'explorateur ne s'ouvrait pas si le coffre changeait de place dans la liste ; corrigé (b0dc8de), vérifié sur le Pixel. Ouverture refusée « Mémoire insuffisante » tant que moins de ~1,3 Go étaient libres (voir Remarques).
- [x] L'application **Fichiers** d'Android montre une racine « Coffre Essai » ; la vidéo du coffre se lit dans VLC.
      → piloté par adb : Fichiers montre les racines « Coffre Essai » et « Coffre Annule » (pas « Course », fermé) ; « Ouvrir avec » → VLC lit video.mp4 du coffre (session média : lecture, vitesse 1, sans erreur). La visionneuse Google Drive, ouverte par défaut, échoue (« Permission Denial ») : elle ajoute « ?cpn=… » à l'adresse du document et perd l'accès accordé ; défaut de Drive, pas de Portail.
- [x] **Fermer** depuis la tuile : le coffre redevient « Fermé », sa racine disparaît de Fichiers.
      → piloté par adb : la tuile repasse à « Fermé » ; dans Fichiers, la racine « Coffre Essai » a disparu (« Coffre Annule », encore ouvert, reste).
- [x] Tant qu'il est ouvert, essayer de supprimer, renommer ou copier `Essai.luks` dans l'explorateur : refusé
      (« Fermez d'abord le coffre »).
      → piloté par adb : Supprimer (après confirmation), Renommer (en Essai2.luks) et Copier puis « Coller ici » sont tous refusés par « Fermez d'abord le coffre » ; Essai.luks reste intact (256 Mio).
- [x] Sur le disque USB déverrouillé : bouton **Créer** de l'explorateur → **Nouveau coffre…** → 1 Gio, ext4
      (l'explication sur l'utilisateur 1000 s'affiche). Ouvrir, écrire un fichier.
      → essayé par l'utilisateur sur le Pixel, concluant (2026-10-25).
- [x] Avec ce coffre ouvert, **Éjecter** le disque : le coffre se ferme d'abord, puis le disque s'éjecte.
      → essayé par l'utilisateur sur le Pixel, concluant (2026-10-25).
- [x] Débrancher le disque avec le coffre ouvert (sans éjecter) : avertissement, le coffre est fermé.
      → essayé par l'utilisateur sur le Pixel, concluant (2026-10-25).
- [x] Verrouillage automatique à 5 min (Réglages → Disques) : un coffre ouvert et inactif se ferme après 5 min.
      → piloté par adb : réglage à 5 min ; « Annule », ouvert à 13:59:38 et laissé inactif, est « Fermé » entre 14:05:09 et 14:05:32. Réglage remis ensuite sur « Jamais ».
- [x] **Retirer de la liste** : le coffre disparaît de l'accueil ; le fichier `.luks` est toujours là ; le toucher
      dans l'explorateur propose de l'ouvrir et le remet dans la liste.
      → piloté par adb (coffre « Annule », 1 Gio) : confirmation « Le fichier du coffre reste à sa place » ; le coffre disparaît de l'accueil, Annule.luks reste (1,1 Go) ; touché dans l'explorateur, il ouvre « Ouvrir le coffre Annule », puis l'explorateur à sa racine, et le coffre revient dans la liste.

## 4. Coffre sous Ubuntu

- [x] Copier `Essai.luks` sur le PC (Portail fermé ou coffre fermé), puis
      `udisksctl loop-setup -f Essai.luks` : le bureau demande le mot de passe et montre les fichiers.
      → essayé par l'utilisateur sur le Pixel, concluant (2026-10-25).
- [x] Ou `sudo cryptsetup open Essai.luks coffre && sudo mount /dev/mapper/coffre /mnt` : les fichiers écrits sur
      le téléphone sont là. Démonter (`sudo umount /mnt && sudo cryptsetup close coffre`).
      → essayé par l'utilisateur sur le Pixel, concluant (2026-10-25).
- [x] Le coffre ext4 du disque, ouvert sous Ubuntu : les fichiers vous appartiennent (`ls -l`).
      → essayé par l'utilisateur sur le Pixel, concluant (2026-10-25).
- [ ] (facultatif) Un conteneur créé sous Ubuntu (`fallocate -l 64M linux.luks && cryptsetup luksFormat linux.luks`,
      puis un exFAT dedans), copié sur le téléphone et touché : il s'ouvre dans Portail.

## 5. Mot de passe et clé de secours

- [x] Coffre fermé, menu ⋮ → **Changer le mot de passe** : l'ancien ne l'ouvre plus, le nouveau si.
      → piloté par adb sur le coffre « Course » ; contrôlé sur le PC par `cryptsetup luksOpen --test-passphrase` : l'ancien mot de passe est refusé (« Aucune clé disponible »), le nouveau accepté ; toujours un seul emplacement (0), argon2id 1 Gio.
- [x] Menu ⋮ → **Clé de secours** → **Créer une clé de secours** : la clé de 24 caractères s'affiche une seule fois,
      avec **Copier la clé** ; notez-la, puis **J'ai noté la clé**. Elle n'est plus jamais réaffichée.
      → piloté par adb : après le mot de passe, « Votre clé de secours » montre 6 groupes de 4 caractères avec **Copier la clé** (« Clé copiée, effacée du presse-papiers dans 60 s ») et **J'ai noté la clé** ; ensuite l'écran dit « Ce coffre a une clé de secours » (Remplacer, Retirer) et ne la réaffiche plus.
- [x] Ouvrir le coffre → **Utiliser la clé de secours** → taper la clé en minuscules, sans tirets : le coffre s'ouvre.
      → piloté par adb : « Utiliser la clé de secours » change le champ (« Afficher la clé ») ; la clé tapée en minuscules sans tirets ouvre « Course » (explorateur à sa racine).
- [x] Sous Ubuntu, la clé tapée telle quelle (tirets compris) à la place de la phrase ouvre aussi le coffre.
      → contrôlé sur le PC (en-tête de Course.luks, `cryptsetup luksOpen --test-passphrase`, sans root) : la clé avec ses tirets ouvre le coffre (code 0), le mot de passe aussi ; la forme minuscule sans tirets est refusée sous Linux, comme attendu (seul Portail la normalise). Emplacements 0 et 1.
- [x] **Changer le mot de passe** en donnant la clé de secours comme mot de passe actuel : accepté.
      → piloté par adb : la clé (avec tirets) donnée comme mot de passe actuel est acceptée ; contrôle sur le PC : le nouveau mot de passe ouvre, l'ancien est refusé, la clé ouvre toujours (emplacements 0 et 1).
- [x] **Retirer la clé de secours** : la clé n'ouvre plus le coffre, le mot de passe si.
      → piloté par adb : « Clé de secours retirée », l'écran dit « Ce coffre n'a pas de clé de secours » ; contrôle sur le PC : la clé est refusée, le mot de passe ouvre ; seul l'emplacement 0 reste.

## 6. Déverrouillage biométrique

- [x] Coffre fermé, menu ⋮ → **Activer le déverrouillage biométrique** → mot de passe, puis le visage : « Déverrouillage
      biométrique activé », la puce « Biométrie » apparaît sur la tuile.
      → essayé par l'utilisateur sur le Pixel, concluant (2026-10-25).
- [x] **Ouvrir** : l'invite du visage s'affiche (« Ouvrir le coffre … ») ; regarder le téléphone ouvre le coffre,
      sans mot de passe.
      → essayé par l'utilisateur sur le Pixel, concluant (2026-10-25).
- [x] **Utiliser le mot de passe** dans l'invite : le dialogue du mot de passe s'ouvre, sans message d'erreur.
      → essayé par l'utilisateur sur le Pixel, concluant (2026-10-25).
- [ ] (facultatif, si vous l'acceptez) Réenregistrer le visage dans les réglages d'Android : à l'ouverture suivante,
      « Déverrouillage biométrique désactivé : la biométrie du téléphone a changé… », puis le mot de passe.
- [x] **Désactiver le déverrouillage biométrique** : le visage n'est plus proposé.
      → essayé par l'utilisateur sur le Pixel, concluant (2026-10-25).

## 7. Confidentialité

- [x] Réglages → **Confidentialité** : les deux réglages sont désactivés par défaut.
      → piloté par adb : section « Confidentialité », « Fermer les coffres quand l'écran s'éteint » et « Masquer les coffres et les fichiers déchiffrés » tous deux désactivés (checked=false).
- [x] **Fermer les coffres quand l'écran s'éteint** activé : coffre ouvert, éteindre l'écran, le rallumer : le coffre
      est fermé. Pendant une longue copie vers le coffre, éteindre l'écran : la copie se termine, puis le coffre se
      ferme (si l'écran est resté éteint).
      → essayé par l'utilisateur sur le Pixel, concluant (2026-10-25).
- [x] **Masquer les coffres et les fichiers déchiffrés** activé : en parcourant un coffre, l'aperçu des applications
      récentes est masqué ; sur l'accueil, il ne l'est plus. Même chose pour une photo chiffrée ouverte.
      → piloté par adb, vérifié sur le drapeau FLAG_SECURE de la fenêtre (dumpsys window, sans capture) : explorateur du coffre « Essai » → masquée ; accueil et réglages → non masquée ; photo.jpg.age ouverte dans la visionneuse → masquée ; dossier ordinaire ensuite → non masquée.

## Remarques

(à remplir)

# Essais de la phase 13 (connexions SSH) sur le Pixel 4 XL

APK de débogage de la branche `feature/ssh`, installée avant l'essai. Le numéro affiché reste celui de la version
précédente jusqu'à la v1.6.0, et le débogage rend l'application plus lente qu'une version finale. Cochez chaque ligne
faite et notez ce qui ne va pas sous la ligne.

**Préparation** : le serveur `mawena.cloud:2244` enregistré dans Dossiers distants (SFTP), son mot de passe connu.
Sur le serveur, `htop` et `nano` installés, et un service web à atteindre par un tunnel (par exemple une page
d'administration sur `localhost:80`, ou `python3 -m http.server 8000` lancé dans un dossier).

## 1. Connexion et Tester la connexion

- [x] Toucher la tuile de `mawena.cloud` : l'explorateur SFTP s'ouvre comme avant. La tuile affiche « SFTP · SSH ».
      → Essai par Claude (adb, 24/10) : l'explorateur s'ouvre, en une dizaine de secondes sur le partage de connexion.
- [x] Fiche du serveur (crayon) → **Tester la connexion** : « Connexion réussie », sans ouvrir de dossier.
      → Essai par Claude : « Connexion réussie » en une dizaine de secondes.
- [x] Changer le mot de passe pour un faux, enregistrer, **Tester la connexion** : le mot de passe est redemandé
      (« Mot de passe refusé »). Remettre le bon mot de passe.
      → Essai par Claude : faux mot de passe tapé sans enregistrer la fiche (le vrai, mémorisé, n'est pas connu de Claude) → « Mot de passe refusé ».
- [ ] Après un échec (par exemple Wi-Fi coupé), **Détails** montre le journal de la tentative ; **Copier** le copie.
      Aucun mot de passe n'y figure.
      → Vérifié par Claude après une connexion réussie seulement : **Détails** montre le journal, **Copier** le copie, sans mot de passe. Le journal d'un échec reste à voir (couper le Wi-Fi du téléphone aurait coupé adb).

## 2. Terminal

- [x] Tuile du serveur → bouton **Terminal** (icône d'invite) : le terminal s'ouvre, l'invite du shell s'affiche.
      → Défaut trouvé par Claude (l'écran restait sur l'accueil), corrigé (24b4adf) ; refait sur la nouvelle APK : le terminal s'ouvre une fois connecté.
- [ ] Taper `ls -la --color` : couleurs lisibles, en thème clair puis en thème sombre (Réglages → Apparence).
      → Essai par Claude : sortie correcte ; contrastes calculés ≥ 4,2:1 en clair et en sombre (sauf blanc vif sur fond clair, 2,9:1). Lisibilité à l'œil à confirmer par vous.
- [x] `htop` : l'écran se dessine en entier ; **F10** n'existe pas sur le clavier : quitter par `q`.
      → Essai par Claude : écran complet, colonnes alignées ; `q` quitte.
- [x] `nano essai.txt` : écrire deux lignes, puis **Ctrl** de la barre de touches et `o` du clavier (enregistrer),
      Entrée, puis **Ctrl** et `x` (quitter). Les flèches de la barre déplacent le curseur dans nano.
      → Essai par Claude : `essai-portail.txt` (dans votre dossier personnel du serveur) enregistré avec ses deux lignes ; les quatre flèches déplacent le curseur.
- [x] **Ctrl** touché deux fois : la touche reste allumée (verrouillée) ; `c` puis `d` donnent Ctrl+C puis Ctrl+D ;
      un troisième toucher la relâche.
      → Essai par Claude : « Verrouillée », `^C` puis Ctrl+D (sortie d'un bash imbriqué), relâchée au troisième toucher.
- [x] Tourner le téléphone en paysage pendant `htop` : l'affichage se redessine à la nouvelle largeur ; revenir en
      portrait.
      → Essai par Claude : 71×38 → 152×24 en paysage (clavier fermé), htop redessiné ; retour en portrait, rotation automatique remise.
- [ ] Pincer l'écran du terminal : le texte grossit ou rapetisse (8 à 32) ; la taille est gardée à la réouverture.
      → Claude ne peut pas pincer (injection à deux doigts refusée par Android) : taille changée par « Taille du texte » (16 points, gardée à la réouverture, remise à 13). Le pincement reste à faire par vous.
- [x] `yes` (flot continu) : l'écran reste fluide ; **Ctrl** puis `c` l'arrête aussitôt.
      → Essai par Claude : sur le partage de connexion (50 % de pertes), Ctrl+C n'agissait qu'au bout de ≈ 45 s ; refait sur le réseau de la maison : invite revenue en 2,5 s, mémoire stable (≈ 455 Mo en débogage).

## 3. Copier-coller

- [x] Appui long sur un mot de la sortie : il se sélectionne ; le bouton **Copier** de la barre de titre le copie
      (« Copié »).
      → Défaut trouvé par Claude après `clear` (copie vide ou d'une autre ligne, écran rempli d'anciennes lignes au changement de largeur), corrigé (25354bb) ; refait : « motessai » sélectionné et copié après `clear`.
- [x] Menu ⋮ → **Coller** d'une seule ligne : elle est tapée directement.
      → Essai par Claude : tapée directement.
- [x] Copier deux lignes ailleurs (par exemple `echo un` et `echo deux` sur deux lignes), puis **Coller** : Portail
      demande « Coller 2 lignes ? » avant de les envoyer.
      → Essai par Claude : « Coller 2 lignes ? » puis collées. Avec bash ≥ 5.1 (collage encadré), elles ne s'exécutent qu'à l'Entrée.

## 4. Sessions multiples et arrière-plan

- [x] Revenir à l'accueil : la section **Sessions SSH** montre la session ouverte. Ouvrir un deuxième terminal sur
      le même serveur : il s'appelle « mawena.cloud (2) » (ou le nom donné au serveur, suivi de « (2) »).
      → Défaut trouvé par Claude : le titre du shell remplaçait le nom, les deux sessions s'appelaient pareil ; corrigé (43e4a05) : « mawena cloud » et « mawena cloud (2) », le titre du shell dessous.
- [x] Dans un terminal, le bouton **Sessions SSH** de la barre de titre passe d'une session à l'autre.
      → Essai par Claude : passage à « mawena cloud (2) ».
- [x] Dans un dossier SFTP de l'explorateur, menu de tri → **Ouvrir un terminal ici** : le shell démarre dans ce
      dossier (`pwd`).
      → Essai par Claude : dans `/home`, `pwd` → `/home`.
- [x] La notification « 2 sessions SSH ouvertes » est là. Quitter Portail (bouton Accueil d'Android), attendre
      2 minutes écran éteint, revenir : les sessions sont intactes et la sortie précédente est là.
      → Essai par Claude : « 3 sessions SSH ouvertes » (noms listés) ; Accueil, écran éteint 2 min : service et sessions intacts, sortie précédente là, une commande envoyée après répond.
- [x] Notification → **Tout fermer** : les sessions se ferment, la notification disparaît, la section **Sessions SSH**
      de l'accueil aussi.
      → Essai par Claude.
- [x] Couper le Wi-Fi pendant une session : au bout d'au plus 90 s elle passe à « Connexion au serveur perdue » avec
      **Reconnecter** ; remettre le Wi-Fi, **Reconnecter** : une nouvelle session s'ouvre.
      → Essai par Claude, à l'occasion du passage du partage de connexion au Wi-Fi de la maison : « Fermée : Connexion au serveur perdue », puis **Reconnecter** ouvre une nouvelle session.

## 5. Clés SSH

- [x] Réglages → Fichiers → **Clés SSH** → **Générer** : nom « Pixel », Ed25519, sans phrase → la clé apparaît
      (type, empreinte, « Utilisée par aucun serveur »).
      → Essai par Claude.
- [x] Menu de la clé → **Copier la clé publique** : une ligne `ssh-ed25519 AAAA… portail@Pixel 4 XL`.
      → Essai par Claude : `ssh-ed25519 AAAAC3…jRNYq portail@Pixel 4 XL`.
- [x] Menu de la clé → **Installer sur un serveur** → `mawena.cloud` : mot de passe demandé si besoin, puis « Clé
      installée sur … » ; accepter **Utiliser cette clé pour … ?**.
      → Essai par Claude : installée, « Utiliser cette clé pour mawena cloud ? » acceptée (« Utilisée par : mawena cloud ») ; le message « Clé installée sur … » n'a pas été vu (caché par le dialogue ?).
- [x] Sur le serveur (dans le terminal) : `ls -la ~/.ssh` montre `.ssh` en `drwx------` ou sans écriture pour les
      autres, `authorized_keys` en `-rw-------`, les anciennes clés toujours là (`cat ~/.ssh/authorized_keys`).
      → Essai par Claude : `.ssh` en `drwx------`, `authorized_keys` en `-rw-------`, les deux clés RSA d'avant toujours là, la clé ed25519 ajoutée.
- [x] Fermer les sessions, retirer le mot de passe mémorisé du serveur (fiche, décocher Mémoriser) : ouvrir un
      terminal ne demande plus de mot de passe (connexion par la clé). L'explorateur SFTP aussi.
      → Essai par Claude, sans retirer votre mot de passe mémorisé (Claude ne le connaît pas) : « Tester la connexion » → Détails : « Authentication succeeded (publickey) ». Le serveur n'accepte que publickey et keyboard-interactive.
- [x] **Installer sur un serveur** une deuxième fois : « Clé déjà installée sur … », fichier inchangé.
      → Essai par Claude : « Clé déjà installée sur mawena cloud », fichier inchangé (3 lignes, même date).

## 6. Commandes enregistrées

- [x] Menu ⋮ du terminal → **Commandes** → **Ajouter une commande** : nom « Disque », commande `df -h`, Exécuter
      aussitôt → enregistrer. La toucher : elle s'exécute.
      → Essai par Claude : « Disque » lance `df -h`.
- [x] Une commande sans « Exécuter aussitôt » est seulement tapée (rien ne part avant Entrée).
      → Essai par Claude : `date` tapé sans être exécuté.
- [x] Appui long sur une commande : la modifier, puis la supprimer.
      → Essai par Claude : modifiée en `date -u`, puis supprimée.
- [x] Sélectionner une commande dans la sortie, bouton **Enregistrer comme commande** : la fiche s'ouvre avec le
      texte sélectionné.
      → Essai par Claude : fiche ouverte avec `uptime`.

## 7. Tunnels

- [x] Menu ⋮ du terminal → **Tunnels** → **Ajouter un tunnel** : port du téléphone 8080, hôte vu du serveur
      `localhost`, port distant 80 (ou 8000 pour `http.server`) → enregistrer, puis activer l'interrupteur **Actif**.
      → Essai par Claude : 8080 → localhost:8000 (`python3 -m http.server` lancé sur 127.0.0.1 du serveur, puis arrêté et effacé).
- [x] **Ouvrir dans le navigateur** : la page du service s'affiche dans le navigateur du téléphone
      (`http://127.0.0.1:8080`).
      → Essai par Claude : Chrome s'ouvre, le serveur reçoit `GET /` (200) ; la page passe aussi depuis le PC par adb.
- [x] La notification compte « 1 tunnel actif ».
      → Essai par Claude : « mawena cloud, mawena cloud (2) · 1 tunnel actif ».
- [x] Un port déjà pris (deux tunnels sur 8080, ou 80 refusé) est expliqué en français.
      → Défaut trouvé par Claude : deux tunnels sur 8080 → message anglais de JSch (« already registered ») ; corrigé (891825b) : « Le port 8080 est déjà utilisé sur ce téléphone ». Un port sous 1024 est refusé dès l'enregistrement.
- [x] Fermer la session : le tunnel s'arrête (la page ne se charge plus).
      → Essai par Claude : port 8080 fermé, page injoignable.

## 8. Réglage et accessibilité

- [x] Réglages → Confort → **Masquer le terminal** activé : une capture d'écran du terminal est noire (ou refusée)
      et l'aperçu des applications récentes est masqué ; désactivé : la capture marche de nouveau.
      → Essai par Claude, sans capture (interdit sur votre téléphone) : fenêtre en FLAG_SECURE sur l'écran du terminal seulement, plus rien une fois l'option désactivée (remise comme avant).
- [x] TalkBack (facultatif) : les touches de la barre se lisent « Échap », « Tabulation », « Contrôle »… ; le
      terminal se lit « Terminal de … ».
      → Essai par Claude par l'arbre d'accessibilité, sans TalkBack : « Échap », « Tabulation », « Contrôle », « Alt », « Flèche haut »…, « Terminal de mawena cloud ».

## Remarques

(à remplir)

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

## 2. Terminal

- [ ] Tuile du serveur → bouton **Terminal** (icône d'invite) : le terminal s'ouvre, l'invite du shell s'affiche.
      → Défaut trouvé par Claude : la session s'ouvrait mais l'écran restait sur l'accueil (premier terminal ouvert depuis l'accueil ; la demande de mot de passe aurait été perdue de même). Corrigé (24b4adf), à refaire sur la nouvelle APK.
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
- [ ] `yes` (flot continu) : l'écran reste fluide ; **Ctrl** puis `c` l'arrête aussitôt.
      → Essai par Claude : mémoire stable (≈ 440 Mo en débogage) ; mais Ctrl+C n'a pris effet qu'au bout de ≈ 45 s : le partage de connexion perdait 50 % des paquets vers mawena.cloud et le serveur avait déjà envoyé ce qui restait. À refaire sur un bon réseau.

## 3. Copier-coller

- [ ] Appui long sur un mot de la sortie : il se sélectionne ; le bouton **Copier** de la barre de titre le copie
      (« Copié »).
      → Défaut trouvé par Claude : après `clear`, la copie était vide (ou d'une autre ligne), et changer la largeur remplissait l'écran d'anciennes lignes (défauts du paquet xterm). Corrigé (25354bb), à refaire sur la nouvelle APK.
- [ ] Menu ⋮ → **Coller** d'une seule ligne : elle est tapée directement.
- [ ] Copier deux lignes ailleurs (par exemple `echo un` et `echo deux` sur deux lignes), puis **Coller** : Portail
      demande « Coller 2 lignes ? » avant de les envoyer.

## 4. Sessions multiples et arrière-plan

- [ ] Revenir à l'accueil : la section **Sessions SSH** montre la session ouverte. Ouvrir un deuxième terminal sur
      le même serveur : il s'appelle « mawena.cloud (2) » (ou le nom donné au serveur, suivi de « (2) »).
- [ ] Dans un terminal, le bouton **Sessions SSH** de la barre de titre passe d'une session à l'autre.
- [ ] Dans un dossier SFTP de l'explorateur, menu de tri → **Ouvrir un terminal ici** : le shell démarre dans ce
      dossier (`pwd`).
- [ ] La notification « 2 sessions SSH ouvertes » est là. Quitter Portail (bouton Accueil d'Android), attendre
      2 minutes écran éteint, revenir : les sessions sont intactes et la sortie précédente est là.
- [ ] Notification → **Tout fermer** : les sessions se ferment, la notification disparaît, la section **Sessions SSH**
      de l'accueil aussi.
- [ ] Couper le Wi-Fi pendant une session : au bout d'au plus 90 s elle passe à « Connexion au serveur perdue » avec
      **Reconnecter** ; remettre le Wi-Fi, **Reconnecter** : une nouvelle session s'ouvre.

## 5. Clés SSH

- [ ] Réglages → Fichiers → **Clés SSH** → **Générer** : nom « Pixel », Ed25519, sans phrase → la clé apparaît
      (type, empreinte, « Utilisée par aucun serveur »).
- [ ] Menu de la clé → **Copier la clé publique** : une ligne `ssh-ed25519 AAAA… portail@Pixel 4 XL`.
- [ ] Menu de la clé → **Installer sur un serveur** → `mawena.cloud` : mot de passe demandé si besoin, puis « Clé
      installée sur … » ; accepter **Utiliser cette clé pour … ?**.
- [ ] Sur le serveur (dans le terminal) : `ls -la ~/.ssh` montre `.ssh` en `drwx------` ou sans écriture pour les
      autres, `authorized_keys` en `-rw-------`, les anciennes clés toujours là (`cat ~/.ssh/authorized_keys`).
- [ ] Fermer les sessions, retirer le mot de passe mémorisé du serveur (fiche, décocher Mémoriser) : ouvrir un
      terminal ne demande plus de mot de passe (connexion par la clé). L'explorateur SFTP aussi.
- [ ] **Installer sur un serveur** une deuxième fois : « Clé déjà installée sur … », fichier inchangé.

## 6. Commandes enregistrées

- [ ] Menu ⋮ du terminal → **Commandes** → **Ajouter une commande** : nom « Disque », commande `df -h`, Exécuter
      aussitôt → enregistrer. La toucher : elle s'exécute.
- [ ] Une commande sans « Exécuter aussitôt » est seulement tapée (rien ne part avant Entrée).
- [ ] Appui long sur une commande : la modifier, puis la supprimer.
- [ ] Sélectionner une commande dans la sortie, bouton **Enregistrer comme commande** : la fiche s'ouvre avec le
      texte sélectionné.

## 7. Tunnels

- [ ] Menu ⋮ du terminal → **Tunnels** → **Ajouter un tunnel** : port du téléphone 8080, hôte vu du serveur
      `localhost`, port distant 80 (ou 8000 pour `http.server`) → enregistrer, puis activer l'interrupteur **Actif**.
- [ ] **Ouvrir dans le navigateur** : la page du service s'affiche dans le navigateur du téléphone
      (`http://127.0.0.1:8080`).
- [ ] La notification compte « 1 tunnel actif ».
- [ ] Un port déjà pris (deux tunnels sur 8080, ou 80 refusé) est expliqué en français.
- [ ] Fermer la session : le tunnel s'arrête (la page ne se charge plus).

## 8. Réglage et accessibilité

- [ ] Réglages → Confort → **Masquer le terminal** activé : une capture d'écran du terminal est noire (ou refusée)
      et l'aperçu des applications récentes est masqué ; désactivé : la capture marche de nouveau.
- [ ] TalkBack (facultatif) : les touches de la barre se lisent « Échap », « Tabulation », « Contrôle »… ; le
      terminal se lit « Terminal de … ».

## Remarques

(à remplir)

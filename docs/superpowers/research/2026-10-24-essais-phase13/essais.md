# Essais de la phase 13 (connexions SSH) sur le Pixel 4 XL

APK de débogage de la branche `feature/ssh`, installée avant l'essai. Le numéro affiché reste celui de la version
précédente jusqu'à la v1.6.0, et le débogage rend l'application plus lente qu'une version finale. Cochez chaque ligne
faite et notez ce qui ne va pas sous la ligne.

**Préparation** : le serveur `mawena.cloud:2244` enregistré dans Dossiers distants (SFTP), son mot de passe connu.
Sur le serveur, `htop` et `nano` installés, et un service web à atteindre par un tunnel (par exemple une page
d'administration sur `localhost:80`, ou `python3 -m http.server 8000` lancé dans un dossier).

## 1. Connexion et Tester la connexion

- [ ] Toucher la tuile de `mawena.cloud` : l'explorateur SFTP s'ouvre comme avant. La tuile affiche « SFTP · SSH ».
- [ ] Fiche du serveur (crayon) → **Tester la connexion** : « Connexion réussie », sans ouvrir de dossier.
- [ ] Changer le mot de passe pour un faux, enregistrer, **Tester la connexion** : le mot de passe est redemandé
      (« Mot de passe refusé »). Remettre le bon mot de passe.
- [ ] Après un échec (par exemple Wi-Fi coupé), **Détails** montre le journal de la tentative ; **Copier** le copie.
      Aucun mot de passe n'y figure.

## 2. Terminal

- [ ] Tuile du serveur → bouton **Terminal** (icône d'invite) : le terminal s'ouvre, l'invite du shell s'affiche.
- [ ] Taper `ls -la --color` : couleurs lisibles, en thème clair puis en thème sombre (Réglages → Apparence).
- [ ] `htop` : l'écran se dessine en entier ; **F10** n'existe pas sur le clavier : quitter par `q`.
- [ ] `nano essai.txt` : écrire deux lignes, puis **Ctrl** de la barre de touches et `o` du clavier (enregistrer),
      Entrée, puis **Ctrl** et `x` (quitter). Les flèches de la barre déplacent le curseur dans nano.
- [ ] **Ctrl** touché deux fois : la touche reste allumée (verrouillée) ; `c` puis `d` donnent Ctrl+C puis Ctrl+D ;
      un troisième toucher la relâche.
- [ ] Tourner le téléphone en paysage pendant `htop` : l'affichage se redessine à la nouvelle largeur ; revenir en
      portrait.
- [ ] Pincer l'écran du terminal : le texte grossit ou rapetisse (8 à 32) ; la taille est gardée à la réouverture.
- [ ] `yes` (flot continu) : l'écran reste fluide ; **Ctrl** puis `c` l'arrête aussitôt.

## 3. Copier-coller

- [ ] Appui long sur un mot de la sortie : il se sélectionne ; le bouton **Copier** de la barre de titre le copie
      (« Copié »).
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

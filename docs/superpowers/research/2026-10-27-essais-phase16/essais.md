# Essais de la phase 16 (analyseur de stockage, barre de navigation) sur le Pixel 4 XL

APK de débogage de la branche `feature/analyseur`, installée avant l'essai. Le numéro affiché reste celui de la version
précédente jusqu'à la v1.9.0. Cochez chaque ligne faite et notez ce qui ne va pas sous la ligne.

**Préparation** :
- le disque USB LUKS2/ext4 de tous les jours, et un PC sous Ubuntu avec l'**Analyseur d'utilisation des disques**
  (Baobab) ;
- un coffre créé dans Portail, avec quelques fichiers ;
- un dossier distant SFTP enregistré (le PC, par exemple) ;
- l'accès à tous les fichiers accordé à Portail ;
- une montre, pour la durée des analyses.

## 1. Barre de navigation

- [x] Au démarrage, la barre en bas montre **Fichiers**, **Coffres**, **Analyseur**, **Distants** et **IA** ;
      Fichiers est choisi et montre l'accueil habituel, sans section Coffres.
      *Essai du 2026-10-27 : démarrage à froid : Fichiers, Coffres, Analyseur, Distants, IA ; Fichiers choisi, accueil habituel (Raccourcis, Stockage, Disques USB), sans section Coffres*
- [x] Passez d'un module à l'autre : chacun montre sa page (Coffres : les coffres et **Créer un coffre** ; Analyseur :
      les emplacements ; Distants : dossiers distants, SSH, tunnels, clés ; IA : chat, automatisations, serveurs).
      *Essai du 2026-10-27 : Coffres : coffres et Créer un coffre ; Analyseur : Emplacements (Téléphone) et Analyser un dossier… ; Distants : dossiers distants, SSH, Tunnels, Clés SSH ; IA : Chat IA, Automatisations, Serveurs IA*
- [x] Dans Fichiers, entrez dans `Download/` ; passez à IA puis revenez : vous êtes toujours dans `Download/`.
      Touchez **Fichiers** de nouveau : retour à l'accueil.
      *Essai du 2026-10-27 : Téléphone › Download gardé après un passage par IA ; toucher Fichiers de nouveau ramène à l'accueil*
- [x] Retour : dépile le module, puis ramène à Fichiers, puis quitte Portail.
      *Essai du 2026-10-27 : depuis IA › Chat IA : Retour → IA, → Fichiers (Download), → Téléphone, → accueil de Fichiers, → Portail quitté*
- [x] Réglages, Aide et À propos sont dans la barre de titre de chaque module ; l'Aide a les deux nouvelles questions
      sur l'analyseur.
      *Essai du 2026-10-27 : dans les cinq modules : Réglages et ⋮ (Aide, À propos) dans la barre de titre ; l'Aide a « Qu'est-ce qui remplit mon téléphone ? » et « Pourquoi l'analyse ne compte pas tout ? », qui s'ouvrent*
- [x] Le lecteur de musique réduit et une copie en cours s'affichent au-dessus de la barre, pas dessous.
      *Essai du 2026-10-27 : lecteur réduit (morceau-1-Aube.mp3, Pause, Arrêter) puis copie de 2 Go (« Copie de gros-essai.bin — 1 sur 1 · 9 % », Annuler, barre de progression) au-dessus de la barre ; copie terminée à 68 Mo/s*
- [x] Paysage : la barre devient un rail à gauche ; tous les modules restent accessibles.
      *Essai du 2026-10-27 : rail à gauche, les cinq modules s'ouvrent. Défaut trouvé : en paysage, le rail n'était pas dans l'arbre d'accessibilité (TalkBack ne pouvait pas l'atteindre) : la barrière des pages du module le masquait ; corrigé (1c636cc, test railDestinationsReadByTalkBack), vérifié sur le Pixel : « Fichiers, onglet 1 sur 5 »…*
- [x] Texte à 200 % (Paramètres → Affichage → Taille de la police) : les cinq libellés de la barre restent lisibles,
      sans chevauchement.
      *Essai du 2026-10-27 : police d'Android à 200 % : Fichiers, Coffres, Analyseur, Distants, IA lisibles en entier, sans chevauchement (taille des libellés plafonnée par la barre)*
- [ ] TalkBack sur la barre : « Fichiers, onglet 1 sur 5 », etc. ; le module choisi est annoncé comme sélectionné.
      *Essai du 2026-10-27 : arbre d'accessibilité lu par uiautomator : « Fichiers, onglet 1 sur 5 »… « IA, onglet 5 sur 5 », le module choisi marqué sélectionné ; écoute réelle avec TalkBack à faire par l'utilisateur*

## 2. Accueil de l'analyseur

- [ ] Module **Analyseur** : le téléphone, la carte SD s'il y en a une, les volumes ouverts du disque USB et les
      coffres ouverts, avec leur jauge d'occupation ; **Analyser un dossier…** en dessous.
- [x] Menu ⋮ du téléphone sur l'accueil de Fichiers → **Analyser le stockage** : l'analyse s'ouvre dans le module
      Analyseur.
      *Essai du 2026-10-27 : Options de Téléphone → Analyser le stockage : l'analyse de Téléphone s'ouvre, module Analyseur sélectionné dans la barre*
- [x] Explorateur, dans `DCIM/` → menu ⋮ → **Analyser ce dossier** : l'analyse porte sur `DCIM` seul.
      *Essai du 2026-10-27 : analyse de DCIM seul : 3,7 Go, 641 éléments (Camera 3,4 Go, Snapchat 314,7 Mo, .Immich 24,8 Mo), comme DCIM dans l'analyse du téléphone. Remarque : le bouton ⋮ de l'explorateur a pour libellé d'accessibilité « Trier par » alors qu'il contient aussi « Afficher les fichiers cachés » et « Analyser ce dossier »*
- [x] **Analyser un dossier…** : le sélecteur montre aussi les dossiers en lecture seule ; l'analyse du dossier
      choisi démarre.
      *Essai du 2026-10-27 : le sélecteur montre Téléphone et ses dossiers, dont Android/data et Android/obb (protégés) ; Music choisi → analyse de Music (36,6 Mo, 12 éléments). Aucun volume en lecture seule disponible (ni disque USB ni coffre ouvert) : à revoir avec le disque*
- [x] Après plusieurs analyses : elles sont listées sous **Analyses de la session** (taille, nombre de fichiers,
      date) ; toucher en rouvre une sans tout relire ; menu → **Réanalyser**, puis **Oublier**.
      *Essai du 2026-10-27 : Téléphone, DCIM, Music listés (taille, fichiers, heure) ; toucher DCIM la rouvre aussitôt sans relire ; Oublier retire l'analyse ; trois analyses gardées au plus. Défaut trouvé : Réanalyser ajoutait une seconde entrée du même dossier et chassait l'analyse du téléphone ; corrigé (6c4a6ec, test rescanReplacesSameLocation), vérifié sur le Pixel : une seule entrée DCIM, Téléphone gardé. Remarque : la liste donne 11,3 Go pour le téléphone (place vue) quand l'en-tête de l'analyse donne 46,9 Go (avec la part « Applications, système et dossiers protégés »)*

## 3. Analyse du téléphone

- [ ] Touchez **Téléphone** : la progression (fichiers comptés, place vue, pourcentage) avance et les premiers
      dossiers apparaissent avant la fin. Notez la durée.
- [ ] Total de l'analyse, part « Applications, système et dossiers protégés » comprise, comparé à Paramètres →
      Stockage d'Android : notez les deux.
- [ ] `Android/data` et `Android/obb` apparaissent « Accès refusé par Android ».
- [ ] Quittez l'écran pendant une analyse : le point d'activité est sur **Analyseur** ; l'accueil de l'analyseur
      montre l'analyse en cours, toucher la rouvre.
- [ ] **Annuler** pendant une analyse : « Résultats partiels », ce qui a été vu reste affiché.
- [ ] Lancez une autre analyse pendant qu'une tourne : Portail demande d'arrêter la première.

## 4. Graphiques et arbre

- [ ] Anneaux : toucher un dossier y entre ; le centre, le fil d'Ariane, **Dossier parent** et Retour remontent.
- [ ] Glisser le doigt sur le graphique : le nom, la taille et la part de l'élément dessous s'affichent.
- [ ] Carte proportionnelle : mêmes gestes ; **Sans graphique** ne garde que l'arbre.
- [ ] Moins de niveaux, plus de niveaux : de 2 à 8 ; le réglage est gardé à l'analyse suivante.
- [ ] Arbre : trié par taille, puis par nom, nombre d'éléments et date ; dossiers dépliés ; « Autres » pour ce qui
      est résumé.
- [ ] Onglet **Plus gros fichiers** : les plus gros fichiers de l'analyse.

## 5. Actions sur un élément

- [ ] Appui long sur un dossier → **Afficher dans l'explorateur** : l'explorateur s'ouvre dans ce dossier.
- [ ] **Copier le chemin**, puis collez-le ailleurs : le chemin est juste.
- [ ] **Propriétés** : taille sur le disque et taille des données.
- [ ] **Mettre à la corbeille** un fichier de test : l'arbre est mis à jour sans réanalyse, et le message dit que la
      place sera libérée au vidage de la corbeille.
- [ ] **Exclure des analyses** un dossier, puis **Réanalyser** : il apparaît « Exclu des analyses ». Réglages →
      **Analyseur de stockage** → **Emplacements exclus de l'analyse** : il y est ; **Ne plus exclure** le retire.

## 6. Disque USB, coffre et dossier distant

- [ ] Volume ouvert du disque USB LUKS analysé : notez la durée et les cinq plus gros dossiers.
- [ ] Le même disque sous Ubuntu, analysé par Baobab : les totaux des cinq plus gros dossiers sont égaux à 1 % près.
- [ ] Éjectez le disque pendant une analyse : l'analyse s'arrête proprement, sans plantage.
- [ ] Coffre ouvert : analysé depuis le module Coffres (menu du coffre → **Analyser le stockage**) ou l'accueil de
      l'analyseur.
- [ ] Dossier distant SFTP : menu ⋮ de l'explorateur → **Analyser ce dossier** : avertissement d'abord, puis
      « Dossier distant : tailles annoncées par le serveur ».

## 7. Accessibilité et apparence

- [ ] TalkBack sur l'arbre : chaque ligne lit son nom, son type, sa taille, sa part du parent, son contenu et sa date.
- [ ] TalkBack sur le graphique : une description est lue.
- [ ] Thème sombre : couleurs des graphiques lisibles, contrastées.
- [ ] Paysage : graphique et arbre côte à côte.
- [ ] Texte à 200 % : l'écran de l'analyse et l'accueil de l'analyseur ne débordent pas.

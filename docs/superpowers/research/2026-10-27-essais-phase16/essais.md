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
- [x] TalkBack sur la barre : « Fichiers, onglet 1 sur 5 », etc. ; le module choisi est annoncé comme sélectionné.
      *Essai du 2026-10-27 : arbre d'accessibilité lu par uiautomator : « Fichiers, onglet 1 sur 5 »… « IA, onglet 5 sur 5 », le module choisi marqué sélectionné ; écoute réelle avec TalkBack à faire par l'utilisateur*
      *Essai du 2026-10-27 : fait par l'utilisateur, concluant*

## 2. Accueil de l'analyseur

- [x] Module **Analyseur** : le téléphone, la carte SD s'il y en a une, les volumes ouverts du disque USB et les
      coffres ouverts, avec leur jauge d'occupation ; **Analyser un dossier…** en dessous.
      *Essai du 2026-10-27 : Emplacements : Téléphone (6,4 Go libres sur 53,7 Go, 88 %) et le coffre ouvert Analyse16 (214,0 Mo libres sur 250,6 Mo, 15 %), chacun avec sa jauge ; Analyser un dossier… dessous. Pas de carte SD dans le Pixel ; disque USB à voir avec lui*
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

- [x] Touchez **Téléphone** : la progression (fichiers comptés, place vue, pourcentage) avance et les premiers
      dossiers apparaissent avant la fin. Notez la durée.
      *Essai du 2026-10-27 : l'analyse du téléphone finit en moins de 2 s (4108 fichiers, 11,5 Go vus ; 503 ms mesurés par l'essai instrumenté), trop vite pour voir la progression par uiautomator ; progression vue sur l'analyse lente de /usr en SFTP : dossier en cours, fichiers comptés et place vue avancent, premiers dossiers dans le graphique avant la fin*
- [x] Total de l'analyse, part « Applications, système et dossiers protégés » comprise, comparé à Paramètres →
      Stockage d'Android : notez les deux.
      *Essai du 2026-10-27 : Portail : 47,1 Go sur 53,7 Go (dont « Applications, système et dossiers protégés » 35,6 Go) ; accueil de Fichiers : 6,4 Go libres sur 53,7 Go, soit 47,3 Go utilisés. Paramètres → Stockage d'Android : 58 Go utilisés sur 64 Go (Applis 24 Go, Système 23 Go, Jeux 4,4 Go, Vidéos 2,4 Go, Images 1,5 Go, Documents et autres 2,8 Go) : Android compte aussi la partition système, hors de la partition de données que voit Portail*
- [x] `Android/data` et `Android/obb` apparaissent « Accès refusé par Android ».
      *Essai du 2026-10-27 : Android → data et obb : « accès refusé par android », 0 octet ; media 321,9 Mo*
- [x] Quittez l'écran pendant une analyse : le point d'activité est sur **Analyseur** ; l'accueil de l'analyseur
      montre l'analyse en cours, toucher la rouvre.
      *Essai du 2026-10-27 : pendant l'analyse SFTP de /usr : point rouge sur Analyseur (TalkBack : « Analyseur, activité en cours ») ; accueil de l'analyseur : « Analyse en cours · usr (mawena cloud) · 2527 fichiers · 759,4 Mo » avec Annuler ; toucher la rouvre*
- [x] **Annuler** pendant une analyse : « Résultats partiels », ce qui a été vu reste affiché.
      *Essai du 2026-10-27 : « Résultats partiels : analyse arrêtée », Réanalyser ; usr — 765,1 Mo — 3422 éléments restent affichés (bin, include)*
- [x] Lancez une autre analyse pendant qu'une tourne : Portail demande d'arrêter la première.
      *Essai du 2026-10-27 : Téléphone touché pendant l'analyse de /usr : « Arrêter l'analyse de usr (mawena cloud) ? Ses résultats partiels restent dans les analyses de la session. » Annuler / Analyser ; Annuler la laisse tourner*

## 4. Graphiques et arbre

- [x] Anneaux : toucher un dossier y entre ; le centre, le fil d'Ariane, **Dossier parent** et Retour remontent.
      *Essai du 2026-10-27 : toucher Download y entre (6,2 Go) ; le centre, Dossier parent, Retour et le fil d'Ariane (Téléphone › Download › portail-tests → Téléphone) remontent*
- [x] Glisser le doigt sur le graphique : le nom, la taille et la part de l'élément dessous s'affichent.
      *Essai du 2026-10-27 : doigt posé sur Download : « Download — 6,2 Go — 13 % de Téléphone — 2093 éléments » dans la bande sous le graphique*
- [x] Carte proportionnelle : mêmes gestes ; **Sans graphique** ne garde que l'arbre.
      *Essai du 2026-10-27 : toucher DCIM y entre, glisser montre « Autres — 1,7 Go — 47 % de DCIM — 441 éléments », Dossier parent remonte ; Sans graphique ne garde que l'en-tête et l'arbre*
- [x] Moins de niveaux, plus de niveaux : de 2 à 8 ; le réglage est gardé à l'analyse suivante.
      *Essai du 2026-10-27 : de 4 (défaut) à 2 : Moins de niveaux se désactive ; de 2 à 8 en six pas : Plus de niveaux se désactive ; 8 gardé pour l'analyse suivante (coffre Analyse16) ; remis à 4*
- [x] Arbre : trié par taille, puis par nom, nombre d'éléments et date ; dossiers dépliés ; « Autres » pour ce qui
      est résumé.
      *Essai du 2026-10-27 : tris Taille (Download, DCIM, iphone…), Nom (.$recycle_bin$, .trash-storage…), Éléments (Download 2093, Android 773, DCIM 641, Pictures 574), Date ; le chevron déplie Download dans l'arbre ; « Autres, contenu résumé, 1,7 Go, 51 % de Camera, 441 éléments » dans DCIM/Camera. Remarque : le chevron n'a pas de nœud d'accessibilité à lui (TalkBack ne peut que toucher la ligne, qui entre dans le dossier)*
- [x] Onglet **Plus gros fichiers** : les plus gros fichiers de l'analyse.
      *Essai du 2026-10-27 : gros-essai.bin (2,1 Go, deux fois), Annule.luks 1,1 Go, Mawena.luks 1,1 Go, PXL_….mp4 373,3 Mo, avec leur dossier*

## 5. Actions sur un élément

- [x] Appui long sur un dossier → **Afficher dans l'explorateur** : l'explorateur s'ouvre dans ce dossier.
      *Essai du 2026-10-27 : appui long sur DCIM : Ouvrir, Afficher dans l'explorateur, Copier le chemin, Propriétés, Exclure des analyses, Supprimer ; Afficher dans l'explorateur ouvre Fichiers dans Téléphone › DCIM*
- [x] **Copier le chemin**, puis collez-le ailleurs : le chemin est juste.
      *Essai du 2026-10-27 : « Chemin copié » ; collé dans la recherche de l'explorateur : « /DCIM »*
- [x] **Propriétés** : taille sur le disque et taille des données.
      *Essai du 2026-10-27 : Défaut trouvé : seule la taille des données était montrée (feuille de l'explorateur). Corrigé (e7dcdbe, test menuActions) : DCIM → « Taille : 3,7 Go — 629 fichiers, 12 dossiers » et « Sur le disque : 3,7 Go »*
- [x] **Mettre à la corbeille** un fichier de test : l'arbre est mis à jour sans réanalyse, et le message dit que la
      place sera libérée au vidage de la corbeille.
      *Essai du 2026-10-27 : gros-essai.bin (2,1 Go, fichier d'essai) : appui long → Supprimer → « Les éléments restent 30 jours dans la corbeille de ce stockage » → Supprimer : « Mis à la corbeille : la place sera libérée quand la corbeille sera vidée », Ouvrir la corbeille ; phase16 passe de 2,4 Go à 268,7 Mo sans réanalyse ; fichier dans .Portail-corbeille. Remarque : la liste Plus gros fichiers n'a pas d'appui long (toucher ouvre l'explorateur)*
- [x] **Exclure des analyses** un dossier, puis **Réanalyser** : il apparaît « Exclu des analyses ». Réglages →
      **Analyseur de stockage** → **Emplacements exclus de l'analyse** : il y est ; **Ne plus exclure** le retire.
      *Essai du 2026-10-27 : Movies : « Exclu des analyses suivantes de ce stockage » ; Réanalyser → « Movies, exclu des analyses, 0 octet » ; Réglages → Emplacements exclus de l'analyse : « /Movies · Téléphone » ; Ne plus exclure → « Aucun emplacement exclu »*

## 6. Disque USB, coffre et dossier distant

- [x] Volume ouvert du disque USB LUKS analysé : notez la durée et les cinq plus gros dossiers.
      *Essai du 2026-10-27 : fait par l'utilisateur, concluant*
- [x] Le même disque sous Ubuntu, analysé par Baobab : les totaux des cinq plus gros dossiers sont égaux à 1 % près.
      *Essai du 2026-10-27 : fait par l'utilisateur, concluant*
- [x] Éjectez le disque pendant une analyse : l'analyse s'arrête proprement, sans plantage.
      *Essai du 2026-10-27 : fait par l'utilisateur, concluant*
- [x] Coffre ouvert : analysé depuis le module Coffres (menu du coffre → **Analyser le stockage**) ou l'accueil de
      l'analyseur.
      *Essai du 2026-10-27 : coffre d'essai Analyse16 (256 Mio, exFAT, dossier Music copié dedans) : menu du coffre → Analyser le stockage → 36,6 Mo, 13 éléments, module Analyseur sélectionné ; le coffre figure aussi dans les emplacements de l'accueil de l'analyseur*
- [x] Dossier distant SFTP : menu ⋮ de l'explorateur → **Analyser ce dossier** : avertissement d'abord, puis
      « Dossier distant : tailles annoncées par le serveur ».
      *Essai du 2026-10-27 : mawena cloud, /usr : « Analyser un dossier distant ? L'analyse lit chaque dossier par le réseau : elle peut être longue. Les tailles sont celles annoncées par le serveur. » puis « Dossier distant : tailles annoncées par le serveur » sous la progression. Remarque : le dossier distant s'ouvre dans le module Fichiers (onglet Fichiers sélectionné)*

## 7. Accessibilité et apparence

- [x] TalkBack sur l'arbre : chaque ligne lit son nom, son type, sa taille, sa part du parent, son contenu et sa date.
      *Essai du 2026-10-27 : arbre d'accessibilité lu par uiautomator : « DCIM, dossier, 3,7 Go, 8 % de Téléphone, 641 éléments, modifié 25 octobre, 14:24 » ; « Autres, contenu résumé… » ; « data, accès refusé par android… ». Écoute réelle avec TalkBack à faire par l'utilisateur*
      *Essai du 2026-10-27 : fait par l'utilisateur, concluant*
- [x] TalkBack sur le graphique : une description est lue.
      *Essai du 2026-10-27 : description présente : « Graphique en anneaux de Téléphone : Applications, système et dossiers protégés, 35,6 Go, 76 % ; Download… » (et « Carte proportionnelle de … »). Écoute réelle à faire par l'utilisateur*
      *Essai du 2026-10-27 : fait par l'utilisateur, concluant*
- [x] Thème sombre : couleurs des graphiques lisibles, contrastées.
      *Essai du 2026-10-27 : thème Sombre de Portail : anneaux et carte proportionnelle contrastés sur fond sombre, libellés lisibles (« Autres » en sombre sur brun clair), arbre et barres lisibles ; thème remis sur Clair*
- [x] Paysage : graphique et arbre côte à côte.
      *Essai du 2026-10-27 : graphique à gauche, onglets Contenu / Plus gros fichiers et arbre à droite, rail des modules à gauche*
- [x] Texte à 200 % : l'écran de l'analyse et l'accueil de l'analyseur ne débordent pas.
      *Essai du 2026-10-27 : accueil de l'analyseur et écran d'analyse sans débordement. Défaut trouvé : l'onglet « Plus gros fichiers » était coupé au bord (portrait et paysage) ; corrigé (1102dd3, test tabLabelsFitAt200Percent, libellé réduit s'il ne tient pas), vérifié sur le Pixel en portrait : libellé entier*

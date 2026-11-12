# Essais de la phase 17 (onglets du module Fichiers) sur le Pixel 4 XL

APK de débogage de la branche `feature/onglets`, installée avant l'essai. Le numéro affiché reste celui de la version
précédente jusqu'à la v1.10.0. Cochez chaque ligne faite et notez ce qui ne va pas sous la ligne.

**Préparation** :
- le disque USB LUKS2/ext4 de tous les jours (ou une clé USB) ;
- un coffre créé dans Portail, avec quelques fichiers ;
- quelques fichiers sans importance dans `Download/` du téléphone, à copier.

## 1. Ouvrir et fermer des onglets

- [ ] Avec un seul onglet, l'écran est celui d'avant : aucune barre d'onglets en haut.
- [ ] Dans l'explorateur du téléphone, menu ⋮ d'un dossier (`DCIM`) → **Ouvrir dans un nouvel onglet** : une barre
      d'onglets apparaît en haut, au-dessus de la barre de titre, avec deux onglets ; le nouveau (`DCIM`) est affiché.
- [ ] Le menu ⋮ d'un fichier ne propose pas d'onglet.
- [ ] Menu de l'explorateur (⋮ en haut) → **Nouvel onglet** : un troisième onglet s'ouvre sur l'accueil de Fichiers,
      nommé « Fichiers ».
- [ ] Bouton **+** de la barre : même chose. À 8 onglets, **+** est grisé ; « Nouvel onglet » dit qu'il y a 8 onglets
      au plus.
- [ ] Croix d'un onglet : il se ferme ; fermer l'onglet affiché montre celui qui l'était juste avant. Au dernier onglet,
      la barre disparaît.
- [ ] Appui long sur un onglet : **Fermer l'onglet**, **Fermer les autres onglets**.

## 2. Chaque onglet garde sa place

- [ ] Onglet 1 dans `Download/`, avec deux fichiers sélectionnés ; onglet 2 sur le disque USB, dans un dossier : en
      passant d'un onglet à l'autre, chacun retrouve son dossier, sa sélection et sa position dans la liste, sans
      recharger.
- [ ] Le nom de l'onglet suit le dossier ouvert (nom du stockage à sa racine) ; l'icône est celle du stockage.
- [ ] Ouvrez un coffre dans un onglet (depuis l'explorateur du disque ou du téléphone) : l'onglet prend le nom du
      coffre ; Retour ferme le coffre et l'onglet reprend le nom du dossier d'avant.
- [ ] Retour dans un onglet : remonte d'un dossier, puis jusqu'à l'accueil ; à l'accueil, Retour ferme l'onglet (s'il
      en reste d'autres) et montre celui d'avant. Avec un seul onglet, Retour quitte Portail comme avant.
- [ ] Toucher **Fichiers** dans la barre du bas ramène l'onglet affiché à l'accueil, sans toucher aux autres.
- [ ] Passez à un autre module (Analyseur, IA) puis revenez à Fichiers : les onglets sont toujours là.

## 3. Copier d'un onglet à l'autre

- [ ] Onglet 1 : `Download/`, sélectionnez des fichiers, **Copier** ; onglet 2 : un dossier du disque USB,
      **Coller ici** : la copie se fait, l'onglet 2 se met à jour.
- [ ] Même chose avec **Couper** (déplacement) : les fichiers disparaissent de l'onglet 1 quand vous y revenez.

## 4. Autres points d'entrée

- [ ] Recherche dans l'explorateur, menu d'un dossier trouvé → **Ouvrir dans un nouvel onglet** ; menu d'un fichier
      trouvé → **Ouvrir le dossier dans un nouvel onglet** (le dossier qui le contient).
- [ ] Depuis le module **Coffres**, un coffre ouvert : menu d'un dossier → **Ouvrir dans un nouvel onglet** : Portail
      passe à Fichiers, sur le nouvel onglet.
- [ ] Analyseur → menu d'un élément → **Afficher dans l'explorateur** : s'ouvre dans l'onglet affiché de Fichiers.

## 5. Stockage qui disparaît

- [ ] Deux onglets ouverts sur le disque USB (deux dossiers différents), un sur le téléphone ; débranchez le disque :
      les deux onglets du disque reviennent à l'accueil, un seul message « volume fermé », l'onglet du téléphone ne
      bouge pas.
- [ ] Une photo du disque ouverte en plein écran depuis un onglet, débranchez : la visionneuse se ferme.
- [ ] Un coffre ouvert dans un onglet, fermez-le depuis le module Coffres : l'onglet revient à son accueil.

## 6. Accessibilité, grand texte, paysage

- [ ] TalkBack : chaque onglet est lu « Onglet 2 sur 3, Download », sélectionné ou non ; la croix « Fermer l'onglet
      Download » ; **+** « Nouvel onglet ». Double-tap affiche l'onglet, appui long ouvre son menu.
- [ ] Texte à 200 % (Réglages Android) : les noms d'onglets sont coupés par des points de suspension, rien ne déborde ;
      la barre défile quand les onglets ne tiennent pas.
- [ ] Paysage (rail à gauche) : la barre d'onglets est au-dessus des pages, à droite du rail.
- [ ] Thème sombre : la barre est lisible, l'onglet affiché se distingue.

# Essais de la phase 15 (intégration IA) sur le Pixel 4 XL

APK de débogage de la branche `feature/ia`, installée avant l'essai. Le numéro affiché reste celui de la version
précédente jusqu'à la v1.8.0. Cochez chaque ligne faite et notez ce qui ne va pas sous la ligne.

**Préparation** :
- le serveur IA réel, `https://atelier.mawena.cloud`, et sa clé API ;
- sur le PC, le serveur d'essai, joignable depuis le téléphone par `adb reverse` :
  `ADB_SERIAL=192.168.0.104:5555 python3 tools/ia/serveur-essai.py --reverse` (adresse `http://127.0.0.1:8765`,
  clé `essai-portail` ; ses modèles répondent par un texte fabriqué : `essai-court` (Markdown, bloc de code compris),
  `essai-long` (2 000 morceaux numérotés de « 0001 » à « 2000 »), `essai-erreur` (erreur au milieu de la réponse) et
  `essai-lent` (70 s sans rien envoyer) ;
- le téléphone connecté au réseau, notifications de Portail autorisées.

## 1. Serveurs IA

- [ ] Réglages → **Serveurs IA** : écran vide qui explique quoi faire ; **Ajouter un serveur IA** : nom « Atelier »,
      adresse `https://atelier.mawena.cloud`, la clé API → **Enregistrer**. Le serveur apparaît, avec son état.
- [ ] Fiche du serveur → **Tester la connexion** : « Connexion réussie (version …, N modèles) » ; **Détails** montre
      le journal du test, sans la clé.
- [ ] Touchez un modèle : il devient le modèle par défaut du serveur (coché).
- [ ] Modifiez la clé en une fausse clé, **Tester la connexion** : « Clé API refusée… » avec le message du serveur
      dessous ; l'état passe à **Clé refusée**. Remettez la bonne clé.
- [ ] Ajoutez le serveur d'essai : « PC », `http://127.0.0.1:8765`, clé `essai-portail`. Comme l'adresse est locale,
      aucun avertissement « en clair » ; **Tester la connexion** réussit (4 modèles).
- [ ] Tapez une adresse `http://` publique (par exemple `http://203.0.113.5:8000`) sans enregistrer :
      l'avertissement « La clé et les conversations passent en clair sur Internet » s'affiche.
- [ ] Faites de « PC » le serveur par défaut, puis de nouveau « Atelier ».

## 2. Chat

- [ ] Accueil → section **IA** → **Chat IA** → **Nouvelle conversation** : sous le titre, « Atelier · <modèle> ».
      Posez une question qui demande une longue réponse : le texte s'affiche au fur et à mesure, la vue suit.
- [ ] Pendant une longue réponse, remontez dans la conversation : la vue ne vous ramène pas en bas.
- [ ] **Arrêter** pendant une réponse : le texte reçu reste, marqué « Arrêtée ».
- [ ] **Régénérer** la dernière réponse : une nouvelle réponse la remplace. **Copier** : la réponse est collable
      ailleurs.
- [ ] Une réponse avec un bloc de code (demandez « un script bash qui liste les fichiers ») : le bloc défile
      horizontalement, en chasse fixe, et son bouton **Copier le code** copie le code seul.
- [ ] Une réponse avec un lien : le toucher montre l'adresse et ne l'ouvre qu'après **Ouvrir**.
- [ ] Menu ⋮ → **Prompt système** : « Réponds en une phrase. » → la réponse suivante tient en une phrase.
- [ ] Touchez « Atelier · <modèle> » sous le titre : choisissez « PC » → `essai-long` ; la réponse suivante vient
      du serveur d'essai : les 2 000 morceaux, de « 0001 » à « 2000 », sans trou ni doublon.
- [ ] Modèle `essai-erreur` : la réponse s'arrête avec un message français, le texte déjà reçu reste.
- [ ] Modèle `essai-lent` : au bout d'une minute environ, un message français de délai dépassé, avec **Réessayer**.
- [ ] Liste des conversations : titre automatique tiré du premier message ; appui long → **Renommer**, puis
      **Supprimer** (confirmation).
- [ ] Fermez l'écran pendant une réponse longue puis rouvrez la conversation : le texte reçu entre-temps est là et la
      réponse continue.
- [ ] Coupez le serveur d'essai (Ctrl+C sur le PC) pendant une réponse de « PC » : la réponse s'arrête avec un message
      français et **Réessayer** ; relancez le serveur, **Réessayer** répond.
- [ ] Fermez Portail (balayez-le des applications récentes) pendant une réponse, puis rouvrez la conversation : la
      réponse est marquée « Interrompue », avec **Réessayer**.

## 3. Automatisations

- [ ] Accueil → **Automatisations** → **Nouvelle automatisation** : nom « Météo », modèle
      « Quel temps fera-t-il à {{ville}} le {{date}} ? » ; le champ « Valeur par défaut de {{ville}} » apparaît
      pendant la saisie (pas de champ pour {{date}}) ; défaut « Lomé », À la demande → **Enregistrer**.
- [ ] Fiche de « Météo » → **Lancer** : la ville est proposée (Lomé), changez-la en « Kara » → le résultat s'affiche
      en flux, en Markdown ; le prompt envoyé montre « Kara » et la date du jour. **Copier** et **Partager**.
- [ ] **Arrêter** un lancement en cours : l'exécution est « Arrêtée », avec le texte reçu.
- [ ] Historique de la fiche : les exécutions, avec leur état, leur date et leur durée ; touchez-en une pour son
      détail. Menu ⋮ → **Effacer l'historique**.
- [ ] Menu ⋮ → **Dupliquer** : « Météo (copie) » apparaît, désactivée ; **Modifier** puis **Supprimer** la copie.
- [ ] Nouvelle automatisation **Planifiée** toutes les 15 min sur « PC », avec une valeur par défaut pour chaque
      variable : l'interrupteur est activé dans la liste. Après 15 à 30 minutes (écran éteint, réseau actif), une
      notification « Automatisation « … » terminée » sans le résultat ; l'historique montre une exécution
      « Planifiée ».
- [ ] Coupez le serveur d'essai, attendez une exécution planifiée : elle est notée en échec avec la raison, sans
      exécutions en rafale ensuite.
- [ ] Désactivez l'interrupteur : plus aucune exécution. Supprimez le serveur « PC » : ses automatisations se
      désactivent.

## 4. Confidentialité et certificats

- [ ] Réglages → Confidentialité → **Masquer les conversations avec les modèles** : une capture d'écran d'une
      conversation est refusée (ou noire), la vignette des applications récentes est masquée. Désactivez-le :
      les captures redeviennent possibles.
- [ ] *(facultatif, si un serveur à certificat auto-signé est disponible)* **Tester la connexion** : « Certificat non
      reconnu » et son empreinte SHA-256 ; **Annuler** n'enregistre rien ; comparez l'empreinte à celle du serveur
      (`openssl x509 -in cert.pem -noout -fingerprint -sha256`), puis **Faire confiance** : la connexion réussit.

## 5. Accessibilité et grand texte

- [ ] Texte à 200 % (Paramètres d'Android → Affichage) : chat, automatisations et serveurs restent lisibles, sans
      texte coupé ; les boutons Envoyer, Arrêter et Lancer restent atteignables.
- [ ] Thème sombre : conversation, blocs de code et résultats d'automatisation lisibles.

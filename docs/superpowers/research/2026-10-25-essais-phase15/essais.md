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

- [x] Réglages → **Serveurs IA** : écran vide qui explique quoi faire ; **Ajouter un serveur IA** : nom « Atelier »,
      adresse `https://atelier.mawena.cloud`, la clé API → **Enregistrer**. Le serveur apparaît, avec son état.
      *Essai du 2026-10-27 : faite avec « PC » (Atelier était déjà enregistré, écran vide non revu) ; le serveur apparaît avec son état (En ligne)*
- [x] Fiche du serveur → **Tester la connexion** : « Connexion réussie (version …, N modèles) » ; **Détails** montre
      le journal du test, sans la clé.
      *Essai du 2026-10-27 : sur « PC » : « Connexion réussie (version essai-0.1.0, 4 modèles) », Détails montre le journal (GET /health, /v1/models) sans la clé. Atelier : « Serveur introuvable », le téléphone n'a pas Internet sur le Wi-Fi du travail ; à refaire avec Internet*
      *Essai du 2026-10-27 : sur Atelier, Wi-Fi avec Internet : « Connexion réussie (version 0.1.0, 5 modèles) » ; Détails : GET /health → 200 puis GET /v1/models → 200, sans la clé. Le message disparaît après quelques secondes (barre en bas).*
- [x] Touchez un modèle : il devient le modèle par défaut du serveur (coché).
      *Essai du 2026-10-27 : essai-lent puis essai-court cochés comme modèle par défaut de « PC »*
- [x] Modifiez la clé en une fausse clé, **Tester la connexion** : « Clé API refusée… » avec le message du serveur
      dessous ; l'état passe à **Clé refusée**. Remettez la bonne clé.
      *Essai du 2026-10-27 : sur « PC » (Atelier injoignable) : « Clé API refusée : vérifiez la clé enregistrée pour ce serveur », état « Clé refusée » dans la liste ; le message du serveur (« Clé API invalide. ») ne s'affiche pas sous le message ; le test porte sur la clé enregistrée, il faut donc Enregistrer avant de tester*
- [x] Ajoutez le serveur d'essai : « PC », `http://127.0.0.1:8765`, clé `essai-portail`. Comme l'adresse est locale,
      aucun avertissement « en clair » ; **Tester la connexion** réussit (4 modèles).
      *Essai du 2026-10-27 : aucun avertissement pour 127.0.0.1, test réussi, 4 modèles*
- [x] Tapez une adresse `http://` publique (par exemple `http://203.0.113.5:8000`) sans enregistrer :
      l'avertissement « La clé et les conversations passent en clair sur Internet » s'affiche.
      *Essai du 2026-10-27 : l'avertissement s'affiche pour http://203.0.113.5:8000*
- [x] Faites de « PC » le serveur par défaut, puis de nouveau « Atelier ».
      *Essai du 2026-10-27 : « PC » puis « Atelier » par défaut depuis leur fiche (Serveur par défaut → Enregistrer) : la liste ne montre « Par défaut » que sur un serveur à la fois.*

## 2. Chat

- [x] Accueil → section **IA** → **Chat IA** → **Nouvelle conversation** : sous le titre, « Atelier · <modèle> ».
      Posez une question qui demande une longue réponse : le texte s'affiche au fur et à mesure, la vue suit.
      *Essai du 2026-10-27 : onglet IA → Chat IA → Nouvelle conversation : « PC · essai-court » (PC par défaut, Atelier injoignable) ; réponse en flux affichée*
- [x] Pendant une longue réponse, remontez dans la conversation : la vue ne vous ramène pas en bas.
      *Essai du 2026-10-27 : pas vérifiable avec le serveur d'essai : essai-long finit en 2 s environ*
      *Essai du 2026-10-27 : en attente : Atelier ne génère plus rien (aucun octet en 150 s avec « default », 100 s avec « llama3.2:3b », même depuis le PC), serveur trop faible pour le moment ; Portail affiche bien « Le serveur ne répond plus » et Réessayer au bout de 60 s. À refaire quand Atelier tiendra la charge*
      *Essai du 2026-10-27 : fait par l'utilisateur, concluant*
- [x] **Arrêter** pendant une réponse : le texte reçu reste, marqué « Arrêtée ».
      *Essai du 2026-10-27 : sur essai-lent : réponse marquée « Arrêtée », Régénérer proposé*
- [x] **Régénérer** la dernière réponse : une nouvelle réponse la remplace. **Copier** : la réponse est collable
      ailleurs.
      *Essai du 2026-10-27 : Régénérer remplace la réponse (une seule réponse ensuite) ; Réessayer après le délai répond ; Copier la réponse copie le texte Markdown (aperçu du presse-papiers)*
- [x] Une réponse avec un bloc de code (demandez « un script bash qui liste les fichiers ») : le bloc défile
      horizontalement, en chasse fixe, et son bouton **Copier le code** copie le code seul.
      *Essai du 2026-10-27 : « Copier le code » copie le code seul (aperçu du presse-papiers d'Android) ; défilement horizontal non vu, le bloc d'essai est court*
- [x] Une réponse avec un lien : le toucher montre l'adresse et ne l'ouvre qu'après **Ouvrir**.
      *Essai du 2026-10-27 : pas faisable avec le serveur d'essai (aucun lien dans ses réponses) ; à faire avec Atelier*
      *Essai du 2026-10-27 : en attente : Atelier ne génère plus rien (aucun octet en 150 s avec « default », 100 s avec « llama3.2:3b », même depuis le PC), serveur trop faible pour le moment ; Portail affiche bien « Le serveur ne répond plus » et Réessayer au bout de 60 s. À refaire quand Atelier tiendra la charge*
      *Essai du 2026-10-27 : fait par l'utilisateur, concluant*
- [ ] Menu ⋮ → **Prompt système** : « Réponds en une phrase. » → la réponse suivante tient en une phrase.
      *Essai du 2026-10-27 : le dialogue s'ouvre et enregistre « Reponds en une phrase. » ; l'effet sur la réponse demande un vrai modèle (Atelier injoignable)*
      *Essai du 2026-10-27 : en attente : Atelier ne génère plus rien (aucun octet en 150 s avec « default », 100 s avec « llama3.2:3b », même depuis le PC), serveur trop faible pour le moment ; Portail affiche bien « Le serveur ne répond plus » et Réessayer au bout de 60 s. À refaire quand Atelier tiendra la charge*
- [x] Touchez « Atelier · <modèle> » sous le titre : choisissez « PC » → `essai-long` ; la réponse suivante vient
      du serveur d'essai : les 2 000 morceaux, de « 0001 » à « 2000 », sans trou ni doublon.
      *Essai du 2026-10-27 : les 2 000 morceaux de 0001 à 2000, dans l'ordre, sans trou ni doublon (texte relu par uiautomator)*
- [x] Modèle `essai-erreur` : la réponse s'arrête avec un message français, le texte déjà reçu reste.
      *Essai du 2026-10-27 : « Le serveur a signalé une erreur pendant la réponse », texte déjà reçu gardé, Réessayer*
- [x] Modèle `essai-lent` : au bout d'une minute environ, un message français de délai dépassé, avec **Réessayer**.
      *Essai du 2026-10-27 : « Le serveur ne répond plus » au bout d'environ 70 s, avec Réessayer*
- [x] Liste des conversations : titre automatique tiré du premier message ; appui long → **Renommer**, puis
      **Supprimer** (confirmation).
      *Essai du 2026-10-27 : titre tiré du premier message ; appui long → Renommer (« Essais du PC », visible dans la liste), puis Supprimer avec confirmation « Supprimer la conversation ? » ; liste vide ensuite*
- [x] Fermez l'écran pendant une réponse longue puis rouvrez la conversation : le texte reçu entre-temps est là et la
      réponse continue.
      *Essai du 2026-10-27 : faite avec essai-lent (rien reçu encore) : en rouvrant, « Réponse en cours » et Arrêter, la réponse continue ; point « IA, activité en cours » sur l'onglet IA pendant ce temps*
- [x] Coupez le serveur d'essai (Ctrl+C sur le PC) pendant une réponse de « PC » : la réponse s'arrête avec un message
      français et **Réessayer** ; relancez le serveur, **Réessayer** répond.
      *Essai du 2026-10-27 : « La réponse a été interrompue » avec Réessayer ; serveur relancé, Réessayer répond*
- [x] Fermez Portail (balayez-le des applications récentes) pendant une réponse, puis rouvrez la conversation : la
      réponse est marquée « Interrompue », avec **Réessayer**.
      *Essai du 2026-10-27 : balayée des récentes pendant essai-lent (processus arrêté) ; au retour : « Interrompue : Portail a été fermé pendant la réponse » avec Réessayer*

## 3. Automatisations

- [x] Accueil → **Automatisations** → **Nouvelle automatisation** : nom « Météo », modèle
      « Quel temps fera-t-il à {{ville}} le {{date}} ? » ; le champ « Valeur par défaut de {{ville}} » apparaît
      pendant la saisie (pas de champ pour {{date}}) ; défaut « Lomé », À la demande → **Enregistrer**.
      *Essai du 2026-10-27 : « Meteo » et « Lome » sans accents (saisie par adb) ; le champ « Valeur par défaut de {{ville}} » apparaît pendant la saisie, aucun pour {{date}} ; enregistrée « À la demande · Jamais lancée ». À noter : l'aide du prompt système de l'automatisation parle de « cette conversation »*
- [x] Fiche de « Météo » → **Lancer** : la ville est proposée (Lomé), changez-la en « Kara » → le résultat s'affiche
      en flux, en Markdown ; le prompt envoyé montre « Kara » et la date du jour. **Copier** et **Partager**.
      *Essai du 2026-10-27 : Lome proposée, changée en Kara ; prompt envoyé « Quel temps fera-t-il a Kara le 27/10/2026 ? » ; résultat en Markdown ; Copier (aperçu du presse-papiers) et Partager (feuille de partage d'Android, fermée sans envoyer)*
- [x] **Arrêter** un lancement en cours : l'exécution est « Arrêtée », avec le texte reçu.
      *Essai du 2026-10-27 : sur essai-lent : « Arrêtée · 13 s », résultat « Exécution arrêtée » (rien n'était encore reçu)*
- [x] Historique de la fiche : les exécutions, avec leur état, leur date et leur durée ; touchez-en une pour son
      détail. Menu ⋮ → **Effacer l'historique**.
      *Essai du 2026-10-27 : « Arrêtée » et « Terminée » avec date, durée et « À la main » ; une exécution touchée montre son prompt et son résultat ; Effacer l'historique (confirmation) → « Aucune exécution »*
- [x] Menu ⋮ → **Dupliquer** : « Météo (copie) » apparaît, désactivée ; **Modifier** puis **Supprimer** la copie.
      *Essai du 2026-10-27 : « Meteo (copie) » apparaît (à la demande, donc sans interrupteur) ; Modifier (renommée, enregistrée) puis Supprimer avec confirmation*
- [x] Nouvelle automatisation **Planifiée** toutes les 15 min sur « PC », avec une valeur par défaut pour chaque
      variable : l'interrupteur est activé dans la liste. Après 15 à 30 minutes (écran éteint, réseau actif), une
      notification « Automatisation « … » terminée » sans le résultat ; l'historique montre une exécution
      « Planifiée ».
      *Essai du 2026-10-27 : aucune exécution de 9 h 54 à 15 h : WorkManager exigeait un réseau validé (Internet), absent du Wi-Fi du travail ; corrigé (46ade42), « Planif » s'est exécutée à 15 h 11, notée « Planifiée », notification « Automatisation « Planif » terminée » sans le résultat ; exécution écran éteint en cours d'observation*
      *Essai du 2026-10-27 : après correction, exécutions planifiées à 15 h 27 et 15 h 43 écran éteint (journal du serveur d'essai, environ toutes les 16 min) ; notification « Automatisation « Planif » terminée » à 15 h 43, sans le résultat*
- [x] Coupez le serveur d'essai, attendez une exécution planifiée : elle est notée en échec avec la raison, sans
      exécutions en rafale ensuite.
      *Essai du 2026-10-27 : serveur coupé après 15 h 43, exécutions planifiées en échec à 15 h 58, 16 h 13 et 16 h 34 (une par période, pas de rafale), raison notée dans l'historique : « Le serveur a fermé la connexion : réessayez », notification « Automatisation « Planif » en échec ».*
- [x] Désactivez l'interrupteur : plus aucune exécution. Supprimez le serveur « PC » : ses automatisations se
      désactivent.
      *Essai du 2026-10-27 : « Planif » désactivée à 16 h 52 : travail retiré de JobScheduler, aucune exécution de 16 h 49 à 17 h 48. Réactivée à 17 h 49 : une exécution part aussitôt (première période de WorkManager, sans délai initial ; en échec, serveur d'essai arrêté), puis la suivante 15 min plus tard. Serveur « PC » supprimé : « Planif » désactivée (interrupteur décoché, travail retiré), « Planif » et « Meteo » affichent « Serveur supprimé ». Remarques : la confirmation de suppression ne dit pas que les automatisations du serveur seront désactivées ; l'interrupteur a pour libellé d'accessibilité « Activée » quel que soit son état (TalkBack : « Activée, désactivé »).*

## 4. Confidentialité et certificats

- [x] Réglages → Confidentialité → **Masquer les conversations avec les modèles** : une capture d'écran d'une
      conversation est refusée (ou noire), la vignette des applications récentes est masquée. Désactivez-le :
      les captures redeviennent possibles.
      *Essai du 2026-10-27 : option activée : capture d'écran refusée (fichier vide), vignette noire dans les récentes ; désactivée : la capture de la conversation revient*
- [ ] *(facultatif, si un serveur à certificat auto-signé est disponible)* **Tester la connexion** : « Certificat non
      reconnu » et son empreinte SHA-256 ; **Annuler** n'enregistre rien ; comparez l'empreinte à celle du serveur
      (`openssl x509 -in cert.pem -noout -fingerprint -sha256`), puis **Faire confiance** : la connexion réussit.
      *Essai du 2026-10-27 : non fait : aucun serveur à certificat auto-signé sous la main*

## 5. Accessibilité et grand texte

- [x] Texte à 200 % (Paramètres d'Android → Affichage) : chat, automatisations et serveurs restent lisibles, sans
      texte coupé ; les boutons Envoyer, Arrêter et Lancer restent atteignables.
      *Essai du 2026-10-27 : conversation, fiche d'automatisation (Lancer visible) et fiche du serveur lisibles, rien de coupé ; Envoyer reste atteignable. Défaut mineur : le titre de la conversation et sa ligne « PC · essai-court » touchent presque la barre d'état. Taille du texte remise à 0,85*
- [x] Thème sombre : conversation, blocs de code et résultats d'automatisation lisibles.
      *Essai du 2026-10-27 : conversation, bloc de code et résultat d'automatisation lisibles ; thème remis à Clair (réglage d'origine)*

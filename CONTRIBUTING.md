# Contribuer à Portail

Merci de votre intérêt ! Les tickets, les idées et les demandes de fusion sont bienvenus.

## Avant de commencer

- Pour une faille de sécurité, suivez [SECURITY.md](SECURITY.md) : pas de ticket public.
- Pour un bogue ou une idée, ouvrez un ticket avec le modèle qui convient.
- Pour un changement important, ouvrez d'abord un ticket pour en discuter.

## Préparer l'environnement

Les outils sont listés dans la section [Développement du README](README.md#développement).

```sh
git clone --recurse-submodules git@github.com:mawena/Portail.git
cd Portail
flutter pub get
```

## Branches

Le dépôt suit git flow :

- partez de `develop` ;
- nommez la branche `feature/<sujet>`, ou `hotfix/<sujet>` pour corriger une version publiée ;
- la demande de fusion vise `develop`, ou `main` pour un correctif de version.

## Commits

Les messages suivent les [Conventional Commits](https://www.conventionalcommits.org/fr/), **en français** :

```
feat(ext4): écriture différée par fichier
fix(sftp): reprise après une coupure du réseau
docs(readme): installation depuis les sources
```

Types : `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `chore`. La portée nomme la partie touchée.

## Code

- Le texte de l'interface, les commentaires et la documentation sont en français.
- **Ne lancez pas `dart format`** sur `lib/` ou `test/` : le code n'est pas formaté par cet outil. Suivez le style
  du fichier modifié.
- Le moteur natif est en C11. Tout ce qui vient d'un disque est traité comme hostile et vérifié avant usage.
- Après une modification de `pigeons/fluluks_api.dart`, régénérez le pont avec
  `dart run pigeon --input pigeons/fluluks_api.dart` et committez les fichiers générés.
- Une bibliothèque ajoutée doit avoir une licence compatible avec la GPL version 3, et sa licence doit être
  ajoutée à l'écran « Licences des bibliothèques ».

## Tests

Chaque changement vient avec ses tests. Avant de proposer une fusion :

```sh
flutter analyze
flutter test
(cd android && ./gradlew testDebugUnitTest)
# si le moteur natif change :
cmake --build build/native && ctest --test-dir build/native --output-on-failure -LE lent
```

Les autres suites (téléphone, noyau Linux, batteries longues) sont décrites dans le [README](README.md#tests).

**Attention aux essais instrumentés sur un téléphone :** `flutter drive` sans `--keep-app-running` et la tâche
Gradle `connectedAndroidTest` désinstallent l'application, avec toutes ses données. Sur un téléphone qui sert
vraiment, installez l'APK de test avec `adb install -r -t` et lancez-le avec `adb shell am instrument`.

**Ne testez jamais l'écriture sur un disque qui contient des données importantes.** Les tests natifs travaillent
sur des images générées.

## Licence

En proposant une contribution, vous acceptez qu'elle soit distribuée sous la
[GPL version 3 ou ultérieure](LICENSE), comme le reste de Portail.

## Ce qui change

<!-- Résumé du changement et ticket lié (« Corrige #12 »). -->

## Comment c'est vérifié

- [ ] `flutter analyze` sans remarque
- [ ] `flutter test`
- [ ] `(cd android && ./gradlew testDebugUnitTest)`
- [ ] Moteur natif modifié : `ctest --test-dir build/native --output-on-failure -LE lent`
- [ ] Essayé sur un téléphone (modèle et version d'Android) :

## À vérifier

- [ ] Messages de commit en Conventional Commits, en français
- [ ] Textes de l'interface et documentation en français
- [ ] Nouvelle bibliothèque : licence compatible GPL 3 et ajoutée aux licences de l'application

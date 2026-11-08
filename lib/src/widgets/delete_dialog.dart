import 'package:flutter/material.dart';

import '../strings_fr.dart';

/// Confirmation d'une suppression (explorateur, analyseur) : null si annulée, vrai pour une suppression définitive,
/// faux pour la corbeille. Sans [trashOffered] (dans la corbeille, dossier distant), le bouton principal supprime
/// définitivement.
Future<bool?> confirmDelete(BuildContext context, {required String title, required String body, required bool trashOffered}) =>
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text(Fr.cancel)),
          if (trashOffered)
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(Fr.deletePermanently),
            ),
          FilledButton(onPressed: () => Navigator.pop(ctx, !trashOffered), child: const Text(Fr.delete)),
        ],
      ),
    );

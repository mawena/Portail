import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/fluluks_api.g.dart';
import '../screens/explorer_screen.dart';
import '../screens/vault_keys_screen.dart';
import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/feedback.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'source_tile.dart';
import 'unlock_dialog.dart';

/// Nom montré d'un système de fichiers de coffre (vide s'il n'est pas encore connu : coffre jamais ouvert).
String vaultFsName(String fs) => switch (fs.toLowerCase()) {
      'exfat' => 'exFAT',
      '' => '',
      _ => fs,
    };

/// Un coffre de l'accueil (phase 14) : nom, taille, système de fichiers et emplacement ; état (fermé, ouvert,
/// indisponible si son stockage n'est pas là) ; Ouvrir, ou Parcourir et Fermer ; menu ⋮ : Ouvrir ou Fermer,
/// Parcourir, Ouvrir dans Fichiers, Changer le mot de passe, Clé de secours, déverrouillage biométrique (rien de cela
/// pour un coffre LUKS1), Afficher l'emplacement, Retirer de la liste (le fichier reste). Biométrie activée : Ouvrir
/// passe d'abord par le visage ou l'empreinte, puis par le mot de passe si l'invite est annulée.
class VaultTile extends StatelessWidget {
  const VaultTile({super.key, required this.state, required this.vault});

  final AppState state;
  final VaultMsg vault;

  bool get _open => vault.state == 'open' && vault.volumeId != null;
  bool get _unavailable => vault.state == 'unavailable';

  /// Stockage qui porte le fichier du coffre, s'il est là.
  SourceMsg? get _host {
    for (final s in state.sources) {
      if (s.stableKey == vault.sourceKey) return s;
    }
    return null;
  }

  Future<void> _openVault(BuildContext context) async {
    if (vault.biometric) {
      try {
        final vol = await state.openVaultBiometric(vault.id, writable: !state.readOnlyPreference);
        if (context.mounted) await openExplorer(context, state, vol.id);
        return;
      } on PlatformException catch (e) {
        // annulée : le mot de passe, sans message ; sinon la raison, puis le mot de passe
        if (e.code != 'biometricCancelled' && context.mounted) {
          showMessage(context, e.message ?? Fr.genericError, kind: MessageKind.error);
        }
      }
      if (!context.mounted) return;
    }
    final vol =
        await openVaultDialog(context, state, name: vault.name, vaultId: vault.id, offerRecovery: vault.hasRecovery);
    if (vol != null && context.mounted) await openExplorer(context, state, vol.id);
  }

  Future<void> _forget(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(Fr.vaultForgetTitle(vault.name)),
        content: const Text(Fr.vaultForgetBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text(Fr.cancel)),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text(Fr.vaultForgetConfirm)),
        ],
      ),
    );
    if (ok == true) await state.forgetVault(vault.id);
  }

  Future<void> _enableBiometric(BuildContext context) async {
    final pw = await askVaultPassword(context, help: Fr.biometricEnableHelp);
    if (pw == null) return;
    try {
      await state.enableBiometric(vault.id, pw);
      if (context.mounted) showMessage(context, Fr.biometricEnabled, kind: MessageKind.success);
    } on PlatformException catch (e) {
      if (e.code != 'biometricCancelled' && context.mounted) {
        showMessage(context, e.code == 'badPassword' ? Fr.badPassword : e.message ?? Fr.genericError,
            kind: MessageKind.error);
      }
    }
  }

  /// Coffre fermé : le mot de passe retire aussi l'emplacement ; ouvert : seule la clé du téléphone est effacée.
  Future<void> _disableBiometric(BuildContext context) async {
    Uint8List? pw;
    if (_open) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text(Fr.biometricDisable),
          content: const Text(Fr.biometricDisableOpenBody),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text(Fr.cancel)),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text(Fr.biometricDisableConfirm)),
          ],
        ),
      );
      if (ok != true) return;
    } else {
      pw = await askVaultPassword(context);
      if (pw == null) return;
    }
    try {
      await state.disableBiometric(vault.id, pw);
      if (context.mounted) showMessage(context, Fr.biometricDisabled, kind: MessageKind.success);
    } on PlatformException catch (e) {
      if (context.mounted) {
        showMessage(context, e.code == 'badPassword' ? Fr.badPassword : e.message ?? Fr.genericError,
            kind: MessageKind.error);
      }
    }
  }

  void _act(BuildContext context, String action) {
    final vol = vault.volumeId;
    switch (action) {
      case 'open':
        _openVault(context);
      case 'close':
        state.closeVault(vault.id);
      case 'browse':
        if (vol != null) openExplorer(context, state, vol);
      case 'files':
        if (vol != null) state.openInFiles(vol);
      case 'location':
        final h = _host;
        if (h != null) openExplorer(context, state, h.id, path: parentOf(vault.path));
      case 'password':
        changeVaultPassword(context, state, vault);
      case 'recovery':
        openRecoveryKey(context, state, vault.id);
      case 'bioOn':
        _enableBiometric(context);
      case 'bioOff':
        _disableBiometric(context);
      case 'forget':
        _forget(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final open = _open;
    final volume = open ? state.volumeById(vault.volumeId!) : null;
    final line = Fr.vaultLine(
      Fr.binarySize(vault.sizeBytes),
      vaultFsName(vault.fs),
      '${vault.sourceLabel} · ${vault.path}',
    );
    PopupMenuItem<String> item(String v, IconData icon, String label) =>
        PopupMenuItem(value: v, child: ListTile(leading: Icon(icon), title: Text(label)));
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(Space.l, Space.m, Space.xs, Space.m),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: Space.s, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            TonalIcon(open ? Icons.lock_open_rounded : sourceIcon('vault')),
            const SizedBox(width: Space.l),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(vault.name, style: theme.textTheme.titleMedium),
                Text(line, style: numeric(theme.textTheme.bodyMedium!.copyWith(color: s.onSurfaceVariant))),
              ]),
            ),
            PopupMenuButton<String>(
              tooltip: Fr.sourceMenu(vault.name),
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (v) => _act(context, v),
              itemBuilder: (_) => [
                if (open) ...[
                  item('browse', Icons.folder_open_rounded, Fr.browse),
                  item('files', Icons.folder_shared_rounded, Fr.openInFiles),
                  item('close', Icons.lock_rounded, Fr.vaultClose),
                ] else if (!_unavailable)
                  item('open', Icons.lock_open_rounded, Fr.open),
                if (!_unavailable && vault.luksVersion == 1)
                  const PopupMenuItem(
                    enabled: false,
                    child: ListTile(leading: Icon(Icons.info_outline_rounded), title: Text(Fr.vaultLuks1)),
                  )
                else if (!_unavailable) ...[
                  item('password', Icons.password_rounded, Fr.changePasswordAction),
                  item('recovery', Icons.key_rounded, Fr.recoveryKey),
                  if (vault.biometric)
                    item('bioOff', Icons.face_retouching_off_rounded, Fr.biometricDisable)
                  else if (state.biometricUnavailable == null)
                    item('bioOn', Icons.face_rounded, Fr.biometricEnable)
                  else
                    PopupMenuItem(
                      enabled: false,
                      child: ListTile(
                        leading: const Icon(Icons.face_retouching_off_rounded),
                        title: Text(state.biometricUnavailable!),
                      ),
                    ),
                ],
                if (_host != null) item('location', Icons.place_rounded, Fr.showLocation),
                item('forget', Icons.playlist_remove_rounded, Fr.vaultForget),
              ],
            ),
          ]),
          Wrap(spacing: Space.s, runSpacing: Space.xs, children: [
            if (open)
              const StatusChip(label: Fr.vaultOpen, icon: Icons.check_rounded, tone: ChipTone.good)
            else if (!_unavailable)
              const StatusChip(label: Fr.vaultClosed, icon: Icons.lock_rounded),
            if (vault.biometric) const StatusChip(label: Fr.chipBiometric, icon: Icons.face_rounded),
            if (volume != null && volume.readOnly)
              const StatusChip(label: Fr.chipReadOnly, icon: Icons.edit_off_rounded, tone: ChipTone.warning),
          ]),
          if (_unavailable) Text(Fr.vaultUnavailable(vault.sourceLabel), style: theme.textTheme.bodyMedium),
          if (volume != null && volume.readOnly && volume.roReason.isNotEmpty)
            Text(Fr.readOnly(volume.roReason), style: theme.textTheme.bodyMedium),
          if (open)
            Wrap(spacing: Space.s, runSpacing: Space.xs, children: [
              FilledButton.icon(
                onPressed: () => _act(context, 'browse'),
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text(Fr.browse),
              ),
              OutlinedButton.icon(
                onPressed: () => _act(context, 'close'),
                icon: const Icon(Icons.lock_rounded),
                label: const Text(Fr.vaultClose),
              ),
            ])
          else if (!_unavailable)
            FilledButton.icon(
              onPressed: () => _openVault(context),
              icon: const Icon(Icons.lock_open_rounded),
              label: const Text(Fr.open),
            ),
        ]),
      ),
    );
  }
}

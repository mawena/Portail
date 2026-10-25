import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/fluluks_api.g.dart';
import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/dialogs.dart';
import '../ui/feedback.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import '../widgets/folder_picker.dart';
import '../widgets/password_field.dart';

/// Plus petit coffre (comme `Vaults.MIN_SIZE`).
const vaultMinSize = 32 << 20;

/// Plus grand coffre sur un stockage FAT (4 Gio − 1 octet, arrondi au secteur, comme `Vaults.FAT_MAX`).
const vaultFatMax = (4 << 30) - 512;

/// Tailles proposées : 256 Mio, 1 Gio, 4 Gio, 16 Gio.
const vaultSizeChoices = [256 << 20, 1 << 30, 4 << 30, 16 << 30];

const _mib = 1 << 20;

/// Réserve laissée libre sur le stockage (comme `Archives.reserve`) : 256 Mio, ou 5 % d'un petit stockage.
int vaultReserve(int total) => min(256 << 20, total ~/ 20);

/// Stockage où un coffre peut se créer : téléphone, carte SD ou volume d'un disque USB, en écriture ; jamais un
/// dossier distant, un coffre ou un fichier déchiffré.
bool canHoldVault(SourceMsg s) => const {'phone', 'removable', 'disk'}.contains(s.kind) && !s.readOnly;

/// Vrai si [sourceId] est un volume FAT12/16/32 d'un disque USB (4 Gio au plus par fichier). Un FAT dans un
/// conteneur LUKS n'est pas vu d'ici : Kotlin refuse alors la taille avec son message.
bool isFatHost(AppState state, String sourceId) => state.disks.any(
    (d) => d.partitions.any((p) => p.volumeId == sourceId && p.content.toUpperCase().startsWith('FAT')));

/// Plus grand coffre possible sur [s] : place libre moins la réserve, 4 Gio − 512 sur FAT, arrondi au secteur.
int vaultMaxSize(SourceMsg s, {required bool fat}) {
  var m = s.totalBytes < 0 || s.freeBytes < 0 ? 1 << 50 : s.freeBytes - vaultReserve(s.totalBytes);
  if (fat) m = min(m, vaultFatMax);
  return m < 0 ? 0 : m ~/ 512 * 512;
}

/// Taille envoyée pour le choix [bytes] : « 4 Gio » vaut 4 Gio − 512 sur un stockage FAT.
int _effective(int bytes, bool fat) => fat && bytes == 4 << 30 ? vaultFatMax : bytes;

/// Ouvre l'écran de création d'un coffre dans [dir] de [sourceId] (par défaut : le premier stockage possible).
Future<void> openVaultCreate(BuildContext context, AppState state, {String? sourceId, String dir = '/'}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => VaultCreateScreen(state: state, sourceId: sourceId, dir: dir),
    ));

/// Créer un coffre (phase 14) : nom, emplacement, taille fixe, système de fichiers (exFAT par défaut, ext4 au
/// choix), mot de passe avec sa force et le générateur. La place est écrite à la création, avec progression et
/// annulation ; quitter l'écran laisse la création continuer (barre du bas). Le mot de passe part en octets, mis à
/// zéro après l'appel.
class VaultCreateScreen extends StatefulWidget {
  const VaultCreateScreen({super.key, required this.state, this.sourceId, this.dir = '/'});

  final AppState state;
  final String? sourceId;
  final String dir;

  @override
  State<VaultCreateScreen> createState() => _VaultCreateScreenState();
}

class _VaultCreateScreenState extends State<VaultCreateScreen> {
  final _name = TextEditingController(text: Fr.vaultNameDefault);
  final _custom = TextEditingController();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  String? _sourceId;
  late String _dir = widget.dir;

  /// Taille choisie parmi [vaultSizeChoices] ; null : « Autre », en Mio dans [_custom].
  int? _choice = 1 << 30;
  String _fs = 'exfat';
  bool _valid = false;
  bool _busy = false;
  String? _error;

  AppState get state => widget.state;

  SourceMsg? get _source => _sourceId == null ? null : state.sourceById(_sourceId!);
  bool get _fat => _sourceId != null && isFatHost(state, _sourceId!);
  int get _max => _source == null ? 0 : vaultMaxSize(_source!, fat: _fat);

  @override
  void initState() {
    super.initState();
    final given = widget.sourceId == null ? null : state.sourceById(widget.sourceId!);
    if (given != null && canHoldVault(given)) {
      _sourceId = given.id;
    } else {
      _sourceId = state.sources.where(canHoldVault).firstOrNull?.id;
      _dir = '/';
    }
    _fitChoice();
    _name.addListener(() => setState(() {}));
    _custom.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _custom.dispose();
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  /// Garde le choix s'il tient ; sinon le plus grand qui tient (1 Gio par défaut).
  void _fitChoice() {
    final c = _choice;
    if (c == null || _effective(c, _fat) <= _max) return;
    final fits = vaultSizeChoices.where((b) => _effective(b, _fat) <= _max);
    if (fits.isNotEmpty) _choice = fits.last;
  }

  int? get _size {
    final c = _choice;
    if (c != null) return _effective(c, _fat);
    final mib = int.tryParse(_custom.text.trim());
    return mib == null ? null : mib * _mib;
  }

  bool get _sizeOk {
    final s = _size;
    return s != null && s >= vaultMinSize && s <= _max;
  }

  String get _base => _name.text.trim();
  String? get _nameError => _base.startsWith('.') ? Fr.nameReserved : nameError(_base);

  bool get _canSubmit => !_busy && _valid && _source != null && _sizeOk && _nameError == null;

  Future<void> _chooseLocation() async {
    final picked = await pickFolder(context, state, accept: canHoldVault);
    if (!mounted || picked == null) return;
    setState(() {
      _sourceId = picked.$1;
      _dir = picked.$2;
      _fitChoice();
    });
  }

  Future<void> _submit() async {
    // règles revérifiées sur le texte même : jamais de coffre avec un champ vidé entre-temps
    if (!_canSubmit || PasswordField.problem(_pass.text, _confirm.text) != null) return;
    final Uint8List pass = Uint8List.fromList(utf8.encode(_pass.text));
    final name = _base;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await state.createVault(_sourceId!, _dir, name, _size!, _fs, pass);
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message ?? Fr.genericError;
      });
      return;
    } finally {
      pass.fillRange(0, pass.length, 0);
    }
    if (!mounted) return;
    AppHaptics.success(state);
    showMessage(context, Fr.vaultCreated(name), kind: MessageKind.success); // reste affiché après le retour
    Navigator.of(context).pop();
  }

  Widget _sizeChip(int bytes) {
    final ok = _effective(bytes, _fat) <= _max;
    return ChoiceChip(
      key: ValueKey('vault-size-$bytes'),
      label: Text(Fr.binarySize(bytes)),
      selected: _choice == bytes,
      onSelected: ok && !_busy ? (_) => setState(() => _choice = bytes) : null,
    );
  }

  Widget _progress(ThemeData theme) => ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final t = state.transfer;
          final running = t != null && t.kind == 'vault' && !t.finished;
          final pct = running && t.totalBytes > 0 ? (t.doneBytes * 100 ~/ t.totalBytes).clamp(0, 100) : 0;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: Space.s, children: [
            LinearProgressIndicator(value: running ? pct / 100 : null),
            if (running)
              Text(Fr.transferLine('vault', t.currentName, t.fileIndex, t.fileCount, pct),
                  style: numeric(theme.textTheme.bodyMedium!)),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton(onPressed: state.cancelTransfer, child: const Text(Fr.cancel)),
            ),
          ]);
        },
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final src = _source;
    final max = _max;
    final customErr = _choice == null && !_sizeOk ? Fr.vaultSizeRange(vaultMinSize ~/ _mib, max ~/ _mib) : null;
    return Scaffold(
      appBar: AppBar(title: const Text(Fr.createVaultTitle)),
      body: AdaptiveBody(
        maxWidth: Layout.maxForm,
        child: ListView(
          padding: listPadding(context, const EdgeInsets.all(Space.l)),
          children: [
            TextField(
              key: const ValueKey('vault-name'),
              controller: _name,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: Fr.vaultName,
                suffixText: '.luks',
                errorText: _base.isEmpty ? null : _nameError,
              ),
            ),
            const SectionHeader(Fr.vaultLocation),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.folder_rounded),
              title: Text(src == null ? Fr.vaultNoSpace : Fr.destChosen(src.label, _dir)),
              trailing: TextButton(onPressed: _busy ? null : _chooseLocation, child: const Text(Fr.changeLocation)),
            ),
            const SectionHeader(Fr.vaultSize),
            if (src != null && max < vaultMinSize)
              const StatusBanner(icon: Icons.error_rounded, text: Fr.vaultNoSpace, tone: ChipTone.danger)
            else ...[
              Wrap(spacing: Space.s, runSpacing: Space.s, children: [
                for (final b in vaultSizeChoices) _sizeChip(b),
                ChoiceChip(
                  key: const ValueKey('vault-size-other'),
                  label: const Text(Fr.vaultSizeOther),
                  selected: _choice == null,
                  onSelected: _busy ? null : (_) => setState(() => _choice = null),
                ),
              ]),
              if (_choice == null) ...[
                const SizedBox(height: Space.s),
                TextField(
                  key: const ValueKey('vault-size-custom'),
                  controller: _custom,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: Fr.vaultSizeMib,
                    helperText: customErr == null ? Fr.vaultSizeRange(vaultMinSize ~/ _mib, max ~/ _mib) : null,
                    errorText: customErr,
                  ),
                ),
              ],
              if (_fat) ...[
                const SizedBox(height: Space.s),
                const StatusBanner(icon: Icons.info_rounded, text: Fr.vaultFatLimit, tone: ChipTone.neutral),
              ],
            ],
            const SectionHeader(Fr.vaultFs),
            RadioGroup<String>(
              groupValue: _fs,
              onChanged: (v) {
                if (!_busy && v != null) setState(() => _fs = v);
              },
              child: const Column(children: [
                RadioListTile<String>(value: 'exfat', title: Text('exFAT'), subtitle: Text(Fr.vaultExfatHelp)),
                RadioListTile<String>(value: 'ext4', title: Text('ext4'), subtitle: Text(Fr.vaultExt4Help)),
              ]),
            ),
            if (_fs == 'ext4')
              const StatusBanner(icon: Icons.info_rounded, text: Fr.vaultExt4Owner, tone: ChipTone.neutral),
            const SectionHeader(Fr.password),
            const StatusBanner(icon: Icons.warning_rounded, text: Fr.vaultNoRecovery, tone: ChipTone.warning),
            const SizedBox(height: Space.s),
            PasswordField(
              controller: _pass,
              confirm: _confirm,
              showStrength: true,
              allowGenerate: true,
              copySecret: state.api.copySecret,
              enabled: !_busy,
              onValidChanged: (v) => setState(() => _valid = v),
            ),
            const SizedBox(height: Space.l),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.s),
                child: StatusBanner(icon: Icons.error_rounded, text: _error!, tone: ChipTone.danger),
              ),
            if (_busy)
              _progress(theme)
            else
              FilledButton(onPressed: _canSubmit ? _submit : null, child: const Text(Fr.createVaultButton)),
          ],
        ),
      ),
    );
  }
}

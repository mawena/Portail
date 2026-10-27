import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluluks/src/ai/ai_server_form.dart';
import 'package:fluluks/src/ai/ai_servers_screen.dart';
import 'package:fluluks/src/ai/automation_form.dart';
import 'package:fluluks/src/ai/automation_runs_screen.dart';
import 'package:fluluks/src/ai/automations_screen.dart';
import 'package:fluluks/src/ai/chat_list_screen.dart';
import 'package:fluluks/src/ai/chat_screen.dart';
import 'package:fluluks/src/analyzer/analyzer_screen.dart';
import 'package:fluluks/src/app.dart';
import 'package:fluluks/src/bridge/fluluks_api.g.dart';
import 'package:fluluks/src/screens/about_screen.dart';
import 'package:fluluks/src/screens/encrypt_sheet.dart';
import 'package:fluluks/src/screens/explorer_screen.dart';
import 'package:fluluks/src/screens/filter_screen.dart';
import 'package:fluluks/src/screens/format_screen.dart';
import 'package:fluluks/src/screens/global_search_screen.dart';
import 'package:fluluks/src/screens/help_screen.dart';
import 'package:fluluks/src/screens/module_shell.dart';
import 'package:fluluks/src/screens/search_screen.dart';
import 'package:fluluks/src/screens/server_form_screen.dart';
import 'package:fluluks/src/screens/settings_screen.dart';
import 'package:fluluks/src/screens/space_screen.dart';
import 'package:fluluks/src/screens/ssh_keys_screen.dart';
import 'package:fluluks/src/screens/text_editor_screen.dart';
import 'package:fluluks/src/screens/trash_screen.dart';
import 'package:fluluks/src/state/app_state.dart';
import 'package:fluluks/src/terminal/terminal_screen.dart';
import 'package:fluluks/src/terminal/tunnels_screen.dart';
import 'package:fluluks/src/ui/root.dart';
import 'package:fluluks/src/widgets/mini_player.dart';
import 'package:fluluks/src/widgets/decrypt_dialog.dart';
import 'package:fluluks/src/widgets/unlock_dialog.dart';
import 'package:fluluks/src/screens/vault_create_screen.dart';

import 'demo_data.dart';
import 'fake_ai_api.dart';
import 'fake_host_api.dart';

/// Écrans que [pumpScreen] sait afficher, sur les données de [demoApi].
const screens = [
  'home', 'explorerList', 'explorerGrid', 'filterGrid', 'search', 'globalSearch', 'trash', 'space', 'settings', //
  'about', 'help', 'welcome', 'unlock', 'format', 'editor', 'serverForm', 'nowPlaying', 'terminal', 'sshKeys', 'tunnels',
  'encrypt', 'decrypt', 'vaultCreate', 'homeVaults',
  'aiServers', 'aiServerForm', 'chatList', 'chat', //
  'automations', 'automationForm', 'automationRuns', 'automationRun', //
  'remoteHome', 'aiHome', // racines des modules Distants et IA (phase 16)
  'analyzer', 'analyzerTreemap', // écran d'une analyse (phase 16)
];

/// Pont et état du dernier [pumpScreen] (pour les tests qui agissent ensuite sur l'écran).
late FakeHostApi harnessApi;
late AppState harnessState;

/// Affiche [screen] (une valeur de [screens]) sur les données de démonstration, comme dans l'application (racine
/// `PortailRoot` : taille du texte bornée à 200 %), en [brightness], à [size] dp et à l'échelle de texte [textScale].
/// [deviceView] : l'écran réel de l'appareil est gardé (captures sur le Pixel), [size] est ignorée.
Future<void> pumpScreen(
  WidgetTester t,
  String screen, {
  Brightness brightness = Brightness.light,
  Size size = const Size(412, 869),
  double textScale = 1.0,
  bool deviceView = false,
}) async {
  if (!deviceView) {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1.0;
  }
  t.platformDispatcher.platformBrightnessTestValue = brightness;
  t.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(() {
    t.view.reset();
    t.platformDispatcher.clearPlatformBrightnessTestValue();
    t.platformDispatcher.clearTextScaleFactorTestValue();
  });

  final api = demoApi();
  if (screen == 'explorerGrid' || screen == 'filterGrid') {
    api.viewPrefs = ViewPrefsMsg(sort: 'name', ascending: true, grid: true, showHidden: false, builtInViewers: true);
  }
  if (screen == 'analyzerTreemap') {
    api.uiPrefs = UiPrefsMsg(theme: 'system', haptics: true, welcomeSeen: true, analyzerChart: 'treemap');
  }
  if (screen == 'sshKeys') {
    api.sshKeyList.addAll([
      SshKeyMsg(id: 'k1', name: 'Pixel', type: 'ssh-ed25519', fingerprint: 'SHA256:3Fq0gJx9yKp2', encrypted: false,
          usedBy: ['Maison']),
      SshKeyMsg(id: 'k2', name: 'Ancien portable', type: 'ssh-rsa', fingerprint: 'SHA256:Zt8mWq1bLc7r', encrypted: true,
          usedBy: []),
    ]);
  }
  if (screen.startsWith('ai') || screen.startsWith('chat') || screen.startsWith('automation')) {
    api.aiServerList.addAll([
      aiServer('a1', 'Atelier', 'https://atelier.mawena.cloud', isDefault: true, model: 'essai-court'),
      aiServer('a2', 'PC du salon', 'http://192.168.0.20:11434', hasKey: false),
      aiServer('a3', 'VPS de secours', 'http://203.0.113.5:8000'),
    ]);
    api.aiHealthById['a2'] = AiHealthMsg(serverId: 'a2', state: 'offline', error: 'Connexion refusée');
    api.aiHealthById['a3'] = AiHealthMsg(serverId: 'a3', state: 'key-refused');
  }
  if (screen.startsWith('chat')) {
    // une conversation en Markdown (titre, liste, code), une autre terminée par un échec
    await api.createConversation('a1', 'essai-court');
    await api.sendChatMessage(1, 'Comment sauvegarder mon dossier Photos chaque soir ?');
    api.finishFakeReply(1, '## Sauvegarde du soir\n\nDeux étapes :\n\n1. Créez le script ci-dessous.\n'
        '2. Ajoutez-le à **cron** avec `crontab -e`.\n\n```bash\nrsync -a --delete ~/Photos/ /mnt/sauvegarde/Photos/\n```\n\n'
        '> Vérifiez d\'abord que le disque est monté.');
    await api.createConversation('a2', 'llama3.2');
    await api.sendChatMessage(2, 'Résume ce texte');
    api.finishFakeReply(2, '', state: 'failed', error: 'Le serveur ne répond pas. Vérifiez qu\'il est allumé.',
        errorDetail: 'Connection refused');
  }
  if (screen.startsWith('automation')) {
    // une automatisation planifiée (dernière exécution réussie), une autre à la demande (dernière en échec)
    await api.saveAutomation(AutomationMsg(id: 0, name: 'Météo du matin', template: 'Quel temps fera-t-il à {{ville}} le {{date}} ?',
        variables: [AutomationVarMsg(name: 'ville', defaultValue: 'Lomé')], serverId: 'a1', model: 'essai-court',
        trigger: 'periodic', intervalMinutes: 60, enabled: true));
    await api.saveAutomation(AutomationMsg(id: 0, name: "Résumé d'article", template: 'Résume en trois points :\n\n{{texte}}',
        variables: [AutomationVarMsg(name: 'texte')], serverId: 'a2', model: 'llama3.2', trigger: 'manual', enabled: true));
    await api.runAutomation(1, const {});
    api.finishFakeRun(1, '## Lomé, 25/10/2026\n\n- **Matin** : ensoleillé, 27 °C\n- **Après-midi** : orages possibles',
        scheduled: true);
    await api.runAutomation(1, const {});
    api.finishFakeRun(2, null, state: 'failed', error: 'Le serveur ne répond pas : vérifiez l\'adresse et le réseau',
        errorDetail: 'Connection refused', scheduled: true);
    await api.runAutomation(2, const {'texte': 'Portail lit les disques chiffrés…'});
    api.finishFakeRun(3, '1. Lecture\n2. Écriture\n3. Chiffrement');
  }
  if (screen == 'homeVaults') {
    // un coffre fermé, un ouvert, un indisponible (carte SD absente)
    VaultMsg v(String id, String name, String state, {String? volumeId, String label = 'Téléphone'}) => VaultMsg(
        id: id, name: name, sourceKey: label == 'Téléphone' ? 'phone' : 'sd:2', sourceLabel: label,
        path: '/Coffres/$name.luks', sizeBytes: 1 << 30, fs: 'exfat', state: state, volumeId: volumeId,
        hasRecovery: false, biometric: false, luksVersion: 2);
    api.sources = [
      ...api.sources,
      SourceMsg(id: 'vv1', stableKey: 'vault:a2', kind: 'vault', label: 'Coffre Photos', totalBytes: 1 << 30,
          freeBytes: 1 << 29, readOnly: false, roReason: '', encrypted: true),
    ];
    api.vaults = [
      v('a1', 'Papiers', 'closed'),
      v('a2', 'Photos', 'open', volumeId: 'vv1'),
      v('a3', 'Ancien', 'unavailable', label: 'Carte SD 2'),
    ];
  }
  if (screen == 'welcome') api.uiPrefs = UiPrefsMsg(theme: 'system', haptics: true, welcomeSeen: false);
  final state = AppState(api);
  await state.loadUiPrefs();
  await state.refresh();
  harnessApi = api;
  harnessState = state;
  if (screen == 'nowPlaying') {
    state.onPlayerChanged(
      PlayerMsg(sourceId: 'v1', title: 'Morceau 2.mp3', index: 1, count: 6, playing: true, positionMs: 83000, durationMs: 245000),
      null,
    );
  }
  String? terminalId;
  if (screen == 'tunnels') {
    api.tunnelList.addAll([
      TunnelMsg(id: 'u1', serverId: 's1', localPort: 8080, remoteHost: 'localhost', remotePort: 80, auto: true, active: true),
      TunnelMsg(id: 'u2', serverId: 's1', localPort: 5433, remoteHost: 'db', remotePort: 5432, auto: false, active: false),
    ]);
  }
  if (screen == 'terminal' || screen == 'tunnels') {
    terminalId = (await state.terminals.open('s1')).info.id;
    state.onTerminalOutput(
      terminalId,
      Uint8List.fromList(utf8.encode('charles@maison:~\$ ls --color\r\n\x1b[1;34mDocuments\x1b[0m  '
          '\x1b[1;32mscript.sh\x1b[0m  notes.txt\r\ncharles@maison:~\$ ')),
    );
  }
  await t.pumpWidget(const SizedBox.shrink()); // arbre neuf : rien ne reste d'un écran précédent
  await t.pumpWidget(PortailRoot(state: state, builder: (_) => FluLuksApp(state: state)));
  await t.pumpAndSettle();

  final Widget? page = switch (screen) {
    'home' || 'welcome' || 'homeVaults' => null,
    'explorerList' || 'explorerGrid' => ExplorerScreen(state: state, sourceId: 'phone'),
    'filterGrid' => FilterScreen(state: state, filter: 'photos', title: 'Photos'),
    'search' => SearchScreen(state: state, sourceId: 'phone', path: '/'),
    'globalSearch' => GlobalSearchScreen(state: state, initialQuery: 'IMG'),
    'trash' => TrashScreen(state: state, sourceId: 'phone'),
    'space' => SpaceScreen(state: state, sourceId: 'phone'),
    'analyzer' || 'analyzerTreemap' => AnalyzerScreen(state: state, sourceId: 'phone'),
    'settings' => SettingsScreen(state: state),
    'about' => AboutScreen(state: state),
    'help' => const HelpScreen(),
    'format' => FormatScreen(state: state, disk: api.disks.single),
    'editor' => TextEditorScreen(state: state, sourceId: 'phone', path: '/notes-1.txt', name: 'notes-1.txt'),
    'serverForm' => ServerFormScreen(state: state, server: api.servers.single),
    'terminal' => TerminalScreen(state: state, sessionId: terminalId!),
    'sshKeys' => SshKeysScreen(state: state),
    'tunnels' => TunnelsScreen(state: state, serverId: 's1', sessionId: terminalId),
    'aiServers' => AiServersScreen(state: state),
    'aiServerForm' => AiServerForm(state: state, server: api.aiServerList.first),
    'chatList' => ChatListScreen(state: state),
    'chat' => ChatScreen(state: state, conversationId: 1),
    'automations' => AutomationsScreen(state: state),
    'automationForm' => AutomationForm(state: state, automation: (await api.automations()).first),
    'automationRuns' => AutomationRunsScreen(state: state, automationId: 1),
    'automationRun' => AutomationRunScreen(state: state, runId: 1),
    'encrypt' => EncryptSheet(state: state, sourceId: 'phone', paths: const ['/notes-1.txt', '/Documents'], dir: '/'),
    'vaultCreate' => VaultCreateScreen(state: state, sourceId: 'phone', dir: '/Documents'),
    'unlock' || 'nowPlaying' || 'decrypt' || 'remoteHome' || 'aiHome' => null,
    _ => throw ArgumentError.value(screen, 'screen'),
  };
  final nav = t.state<NavigatorState>(find.byType(Navigator).first);
  if (page != null) {
    nav.push(MaterialPageRoute<void>(builder: (_) => page));
  } else if (screen == 'nowPlaying') {
    // comme dans l'application : depuis le lecteur réduit, qui se cache pendant « Lecture en cours »
    await t.tap(find.descendant(of: find.byType(MiniPlayer), matching: find.text('Morceau 2.mp3')));
  } else if (screen == 'decrypt') {
    showDialog<void>(
      context: nav.context,
      builder: (_) => DecryptDialog(
        state: state,
        sourceId: 'phone',
        entry: EntryMsg(name: 'rapport.pdf.age', path: '/rapport.pdf.age', type: 'file', size: 52000, mtime: 1700000000),
        dir: '/',
        folder: false,
      ),
    );
  } else if (screen == 'remoteHome' || screen == 'aiHome') {
    t.state<ModuleShellState>(find.byType(ModuleShell))
        .select(screen == 'remoteHome' ? PortailModule.remote : PortailModule.ai);
  } else if (screen == 'homeVaults') {
    // racine du module Coffres (phase 16)
    t.state<ModuleShellState>(find.byType(ModuleShell)).select(PortailModule.vaults);
  } else if (screen == 'unlock') {
    showDialog<void>(
      context: nav.context,
      builder: (_) => UnlockDialog(state: state, diskId: 'd1', partIndex: 2, partitionName: 'Archives'),
    );
  }
  await t.pumpAndSettle();
}

/// Attend le décodage des images affichées (logo…) : sans cela, la première capture peut les montrer vides.
Future<void> waitForImages(WidgetTester t) async {
  await t.runAsync(() async {
    for (final e in find.byType(Image).evaluate()) {
      await precacheImage((e.widget as Image).image, e);
    }
  });
  await t.pumpAndSettle();
}

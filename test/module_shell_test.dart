import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluluks/src/ai/ai_home_screen.dart';
import 'package:fluluks/src/ai/ai_servers_screen.dart';
import 'package:fluluks/src/ai/automations_screen.dart';
import 'package:fluluks/src/ai/chat_list_screen.dart';
import 'package:fluluks/src/ai/chat_screen.dart';
import 'package:fluluks/src/app.dart';
import 'package:fluluks/src/bridge/fluluks_api.g.dart';
import 'package:fluluks/src/screens/about_screen.dart';
import 'package:fluluks/src/screens/explorer_screen.dart';
import 'package:fluluks/src/screens/help_screen.dart';
import 'package:fluluks/src/screens/home_screen.dart';
import 'package:fluluks/src/screens/image_viewer_screen.dart';
import 'package:fluluks/src/screens/module_shell.dart';
import 'package:fluluks/src/screens/now_playing_screen.dart';
import 'package:fluluks/src/screens/remote_home_screen.dart';
import 'package:fluluks/src/screens/server_form_screen.dart';
import 'package:fluluks/src/screens/settings_screen.dart';
import 'package:fluluks/src/screens/ssh_keys_screen.dart';
import 'package:fluluks/src/screens/text_editor_screen.dart';
import 'package:fluluks/src/state/app_state.dart';
import 'package:fluluks/src/strings_fr.dart';
import 'package:fluluks/src/terminal/terminal_screen.dart';
import 'package:fluluks/src/terminal/tunnels_screen.dart';
import 'package:fluluks/src/ui/root.dart';
import 'package:fluluks/src/ui/states.dart';
import 'package:fluluks/src/widgets/mini_player.dart';
import 'package:fluluks/src/widgets/transfer_bar.dart';

import 'demo_data.dart';
import 'fake_ai_api.dart';
import 'fake_host_api.dart';
import 'image_viewer_test.dart' show png;

/// Phase 16, T1 : barre de navigation entre les modules (spec § 27).
void main() {
  Future<AppState> pump(WidgetTester t, FakeHostApi api, {Size size = const Size(412, 869), double textScale = 1}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1.0;
    t.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(() {
      t.view.reset();
      t.platformDispatcher.clearTextScaleFactorTestValue();
    });
    final state = AppState(api);
    await state.loadUiPrefs();
    await state.refresh();
    await t.pumpWidget(const SizedBox.shrink());
    await t.pumpWidget(PortailRoot(state: state, builder: (_) => FluLuksApp(state: state)));
    await t.pumpAndSettle();
    return state;
  }

  FakeHostApi withAi(FakeHostApi api) => api
    ..aiServerList.add(aiServer('a1', 'Atelier', 'https://atelier.mawena.cloud', isDefault: true, model: 'essai-court'));

  final bar = find.byType(NavigationBar);
  final rail = find.byType(NavigationRail);

  Future<void> tapModule(WidgetTester t, String label) async {
    final scope = t.any(bar) ? bar : rail;
    await t.tap(find.descendant(of: scope, matching: find.text(label)));
    await t.pumpAndSettle();
  }

  ModuleShellState shell(WidgetTester t) => t.state<ModuleShellState>(find.byType(ModuleShell));

  Future<void> back(WidgetTester t) async {
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
  }

  /// Écran visible (le plus haut) d'un type donné, hors des modules masqués.
  Finder shown(Type type) => find.byType(type, skipOffstage: true);

  testWidgets('barListsModulesFilesFirst', (t) async {
    final h = t.ensureSemantics();
    await pump(t, demoApi());
    expect(bar, findsOneWidget);
    final labels = t.widgetList<NavigationDestination>(find.byType(NavigationDestination)).map((d) => d.label);
    expect(labels, [Fr.moduleFiles, Fr.moduleRemote, Fr.moduleAi]);
    expect(t.widget<NavigationBar>(bar).labelBehavior, NavigationDestinationLabelBehavior.alwaysShow);
    expect(t.widget<NavigationBar>(bar).selectedIndex, 0);
    expect(shell(t).current, PortailModule.files);
    expect(shown(HomeScreen), findsOneWidget);
    // TalkBack : « Fichiers », puis le rang de l'onglet, en français
    final node = t.getSemantics(find.descendant(of: bar, matching: find.text(Fr.moduleFiles)));
    var label = '';
    for (SemanticsNode? n = node; n != null && label.isEmpty; n = n.parent) {
      if (n.getSemanticsData().label.contains('onglet')) label = n.getSemanticsData().label;
    }
    expect(label, contains(Fr.moduleFiles));
    expect(label, contains('onglet 1 sur 3'));
    h.dispose();
  });

  testWidgets('eachModuleKeepsItsStack', (t) async {
    await pump(t, withAi(demoApi()));
    await t.tap(find.text('Téléphone'));
    await t.pumpAndSettle();
    await t.tap(find.text('DCIM').first);
    await t.pumpAndSettle();
    expect(t.widget<ExplorerScreen>(shown(ExplorerScreen).last).path, '/');
    final explorer = t.state(shown(ExplorerScreen).last);
    await tapModule(t, Fr.moduleAi);
    expect(shell(t).current, PortailModule.ai);
    await t.tap(find.text(Fr.chatTitle));
    await t.pumpAndSettle();
    expect(shown(ChatListScreen), findsOneWidget);
    await tapModule(t, Fr.moduleFiles);
    // le même explorateur, toujours sur /DCIM
    expect(shown(ChatListScreen), findsNothing);
    expect(t.state(shown(ExplorerScreen).last), same(explorer));
    expect(find.text('IMG_20251001.jpg'), findsWidgets);
    await tapModule(t, Fr.moduleAi);
    expect(shown(ChatListScreen), findsOneWidget);
  });

  testWidgets('reselectPopsToModuleRoot', (t) async {
    await pump(t, withAi(demoApi()));
    await tapModule(t, Fr.moduleAi);
    await t.tap(find.text(Fr.automations));
    await t.pumpAndSettle();
    expect(shown(AutomationsScreen), findsOneWidget);
    await tapModule(t, Fr.moduleAi);
    expect(shown(AutomationsScreen), findsNothing);
    expect(shown(AiHomeScreen), findsOneWidget);
  });

  testWidgets('backPopsThenFilesThenLeaves', (t) async {
    final calls = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await pump(t, withAi(demoApi()));
    await tapModule(t, Fr.moduleAi);
    await t.tap(find.text(Fr.automations));
    await t.pumpAndSettle();
    await back(t); // dépile le module
    expect(shown(AiHomeScreen), findsOneWidget);
    expect(calls, isNot(contains('SystemNavigator.pop')));
    await back(t); // racine d'un autre module : Fichiers
    expect(shell(t).current, PortailModule.files);
    expect(shown(HomeScreen), findsOneWidget);
    expect(calls, isNot(contains('SystemNavigator.pop')));
    await back(t); // racine de Fichiers : Android ferme l'application
    expect(calls, contains('SystemNavigator.pop'));
  });

  testWidgets('fullScreenPagesHideTheBar', (t) async {
    final api = withAi(demoApi());
    await api.createConversation('a1', 'essai-court');
    for (var i = 1; i <= 10; i++) {
      api.images['/IMG_2025100$i.jpg'] = png;
    }
    final state = await pump(t, api);

    Future<void> expectFullScreen(Type page) async {
      expect(find.byType(page), findsOneWidget, reason: '$page');
      expect(bar.hitTestable(), findsNothing, reason: '$page');
      await back(t);
      expect(find.byType(page), findsNothing, reason: '$page');
      expect(bar.hitTestable(), findsOneWidget, reason: '$page');
    }

    // visionneuse d'images et éditeur de texte, depuis l'explorateur
    await t.tap(find.text('Téléphone'));
    await t.pumpAndSettle();
    await t.tap(find.text('IMG_20251001.jpg'));
    await t.pumpAndSettle();
    await expectFullScreen(ImageViewerScreen);
    api.texts['/notes-1.txt'] = TextFileMsg(text: 'a', bom: false, crlf: false, mtime: 0, size: 1);
    await t.scrollUntilVisible(find.text('notes-1.txt'), 200,
        scrollable: find.descendant(of: find.byType(ExplorerScreen), matching: find.byType(Scrollable)).first);
    await t.ensureVisible(find.text('notes-1.txt'));
    await t.pumpAndSettle();
    await t.tap(find.text('notes-1.txt'));
    await t.pumpAndSettle();
    await expectFullScreen(TextEditorScreen);
    expect(shell(t).current, PortailModule.files);
    expect(shown(ExplorerScreen), findsOneWidget);

    // lecture en cours, depuis le lecteur réduit
    state.onPlayerChanged(
        PlayerMsg(sourceId: 'phone', title: 'Morceau 1.mp3', index: 0, count: 6, playing: true, positionMs: 0, durationMs: 1000),
        null);
    await t.pumpAndSettle();
    await t.tap(find.descendant(of: find.byType(MiniPlayer), matching: find.text('Morceau 1.mp3')));
    await t.pumpAndSettle();
    await expectFullScreen(NowPlayingScreen);
    state.onPlayerChanged(null, null);
    await t.pumpAndSettle();

    // terminal, depuis Distants
    await tapModule(t, Fr.moduleRemote);
    await t.tap(find.byTooltip(Fr.terminal).first);
    await t.pumpAndSettle();
    await expectFullScreen(TerminalScreen);
    expect(shell(t).current, PortailModule.remote);

    // conversation, depuis IA
    await tapModule(t, Fr.moduleAi);
    await t.tap(find.text(Fr.chatTitle));
    await t.pumpAndSettle();
    await t.tap(find.text(Fr.chatNew).last);
    await t.pumpAndSettle();
    await expectFullScreen(ChatScreen);
    expect(shell(t).current, PortailModule.ai);
  });

  testWidgets('crossModuleLinksSwitchModule', (t) async {
    final api = demoApi()
      ..dirs['remote:s1'] = {
        '/home/charles': [EntryMsg(name: 'film.mkv', path: '/home/charles/film.mkv', type: 'file', size: 10, mtime: 0)],
      };
    final state = await pump(t, api);
    // dossier distant ouvert depuis Distants : l'explorateur s'empile dans Fichiers
    await tapModule(t, Fr.moduleRemote);
    await t.tap(find.text('Maison'));
    await t.pumpAndSettle();
    expect(shell(t).current, PortailModule.files);
    expect(t.widget<ExplorerScreen>(shown(ExplorerScreen)).sourceId, 'remote:s1');
    await tapModule(t, Fr.moduleFiles); // module déjà choisi : retour à sa racine
    expect(shown(HomeScreen), findsOneWidget);
    // disque USB branché (intention USB) : Fichiers, où il apparaît
    await tapModule(t, Fr.moduleAi);
    api.disks = [...api.disks, disk([part(index: 1, size: 1000000, label: 'Clé')], id: 'd2')];
    await state.refresh();
    await t.pumpAndSettle();
    expect(shell(t).current, PortailModule.files);
    // un retrait ou une mise à jour d'un disque connu ne change pas de module
    await tapModule(t, Fr.moduleAi);
    api.disks = api.disks.sublist(0, 1);
    await state.refresh();
    await t.pumpAndSettle();
    expect(shell(t).current, PortailModule.ai);
  });

  testWidgets('dockAboveTheBar', (t) async {
    t.view.padding = const FakeViewPadding(bottom: 48);
    t.view.viewPadding = const FakeViewPadding(bottom: 48);
    final state = await pump(t, demoApi());
    state.onPlayerChanged(
        PlayerMsg(sourceId: 'phone', title: 'Morceau 1.mp3', index: 0, count: 6, playing: true, positionMs: 0, durationMs: 1000),
        null);
    state.onTransferChanged(TransferMsg(
        badPassword: false, kind: 'copy', move: false, currentName: 'a.bin', fileIndex: 1, fileCount: 2, doneBytes: 10,
        totalBytes: 20, finished: false, cancelled: false, elapsedMs: 1200));
    await t.pump();
    await t.pump();
    // un seul lecteur réduit, une seule copie en cours
    expect(find.byType(MiniPlayer), findsOneWidget);
    expect(find.byType(TransferBar), findsOneWidget);
    final player = t.getRect(find.byType(MiniPlayer));
    final transfer = t.getRect(find.byType(TransferBar));
    final nav = t.getRect(bar);
    final list = t.getRect(find.byType(Scrollable).first);
    expect(list.bottom, lessThanOrEqualTo(player.top + 0.5));
    expect(player.bottom, lessThanOrEqualTo(transfer.top + 0.5));
    expect(transfer.bottom, lessThanOrEqualTo(nav.top + 0.5));
    // la place de la barre de navigation d'Android, sous la barre seulement
    expect(nav.bottom, 869);
    expect(transfer.bottom, closeTo(nav.top, 2));
    state.onTransferChanged(null);
    state.onPlayerChanged(null, null);
    await t.pumpAndSettle();
  });

  testWidgets('railOnWideScreens', (t) async {
    await pump(t, demoApi(), size: const Size(869, 412));
    expect(rail, findsOneWidget);
    expect(bar, findsNothing);
    expect(t.widget<NavigationRail>(rail).labelType, NavigationRailLabelType.all);
    expect(t.getRect(rail).left, 0);
    await tapModule(t, Fr.moduleRemote);
    expect(shell(t).current, PortailModule.remote);
    await pump(t, demoApi(), size: const Size(599, 869));
    expect(rail, findsNothing);
    expect(bar, findsOneWidget);
  });

  testWidgets('activityBadges', (t) async {
    final h = t.ensureSemantics();
    final api = withAi(demoApi());
    final state = await pump(t, api);
    expect(find.descendant(of: bar, matching: find.byType(Badge)), findsNothing);
    expect(find.bySemanticsLabel(RegExp('activité en cours')), findsNothing);
    // session SSH ouverte : point sur Distants
    await state.terminals.open('s1');
    await t.pumpAndSettle();
    expect(find.descendant(of: bar, matching: find.byType(Badge)), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(Fr.moduleBusy(Fr.moduleRemote))), findsOneWidget);
    state.terminals.close(state.terminals.sessions.single.info.id);
    await t.pumpAndSettle();
    // réponse en cours : point sur IA
    await api.createConversation('a1', 'essai-court');
    final sent = await api.sendChatMessage(1, 'Bonjour');
    state.chats.onChatDelta(1, sent.id + 1, 'Sal');
    await t.pumpAndSettle();
    expect(find.descendant(of: bar, matching: find.byType(Badge)), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(Fr.moduleBusy(Fr.moduleAi))), findsOneWidget);
    state.chats.onChatState(api.finishFakeReply(1, 'Salut'));
    await t.pumpAndSettle();
    expect(find.descendant(of: bar, matching: find.byType(Badge)), findsNothing);
    h.dispose();
  });

  testWidgets('moduleRootsShareSettingsHelpAbout', (t) async {
    await pump(t, withAi(demoApi()));
    for (final m in [Fr.moduleFiles, Fr.moduleRemote, Fr.moduleAi]) {
      await tapModule(t, m);
      await t.tap(find.byTooltip(Fr.settings).hitTestable());
      await t.pumpAndSettle();
      expect(shown(SettingsScreen), findsOneWidget, reason: m);
      expect(bar.hitTestable(), findsOneWidget, reason: m); // dans le module, barre visible
      await back(t);
      await t.tap(find.byTooltip(Fr.moreOptions).hitTestable());
      await t.pumpAndSettle();
      await t.tap(find.text(Fr.help));
      await t.pumpAndSettle();
      expect(shown(HelpScreen), findsOneWidget, reason: m);
      await back(t);
      await t.tap(find.byTooltip(Fr.moreOptions).hitTestable());
      await t.pumpAndSettle();
      await t.tap(find.text(Fr.about));
      await t.pumpAndSettle();
      expect(shown(AboutScreen), findsOneWidget, reason: m);
      await back(t);
    }
  });

  testWidgets('filesHomeWithoutRemoteAndAi', (t) async {
    // écran assez haut pour que toute la liste soit construite
    await pump(t, withAi(demoApi()), size: const Size(412, 3000));
    final home = find.byType(HomeScreen);
    for (final s in [Fr.shortcuts, Fr.storage, Fr.usbDisks, Fr.favorites]) {
      expect(find.descendant(of: home, matching: find.text(s)), findsOneWidget, reason: s);
    }
    for (final s in [Fr.remoteFolders, Fr.sectionAiHome, Fr.chatTitle, Fr.automations, Fr.addServer, Fr.sshSessions]) {
      expect(find.descendant(of: home, matching: find.text(s)), findsNothing, reason: s);
    }
  });

  testWidgets('remoteHomeGathersRemoteTools', (t) async {
    final api = demoApi();
    final state = await pump(t, api);
    await tapModule(t, Fr.moduleRemote);
    final remote = find.byType(RemoteHomeScreen);
    expect(find.descendant(of: remote, matching: find.text('Maison')), findsOneWidget);
    expect(find.descendant(of: remote, matching: find.text(Fr.addServer)), findsOneWidget);
    expect(find.descendant(of: remote, matching: find.text(Fr.sshSessions)), findsNothing);
    await state.terminals.open('s1');
    await t.pumpAndSettle();
    expect(find.descendant(of: remote, matching: find.text(Fr.sshSessions)), findsOneWidget);
    // tunnels du seul serveur SFTP, avec sa session ouverte
    await t.scrollUntilVisible(find.text(Fr.tunnels), 200, scrollable: find.descendant(of: remote, matching: find.byType(Scrollable)).first);
    await t.tap(find.text(Fr.tunnels));
    await t.pumpAndSettle();
    final tunnels = t.widget<TunnelsScreen>(find.byType(TunnelsScreen));
    expect([tunnels.serverId, tunnels.sessionId], ['s1', state.terminals.sessions.single.info.id]);
    await back(t);
    await t.tap(find.text(Fr.sshKeys));
    await t.pumpAndSettle();
    expect(shown(SshKeysScreen), findsOneWidget);
    await back(t);
    await t.tap(find.descendant(of: remote, matching: find.text(Fr.addServer)));
    await t.pumpAndSettle();
    expect(shown(ServerFormScreen), findsOneWidget);
    expect(bar.hitTestable(), findsOneWidget);
  });

  testWidgets('remoteHomeEmptyInvitesToAddServer', (t) async {
    await pump(t, demoApi()..servers = []);
    await tapModule(t, Fr.moduleRemote);
    final empty = find.descendant(of: find.byType(RemoteHomeScreen), matching: find.byType(EmptyState));
    expect(empty, findsOneWidget);
    expect(find.descendant(of: empty, matching: find.text(Fr.remoteNoServers)), findsOneWidget);
    await t.tap(find.descendant(of: empty, matching: find.text(Fr.addServer)));
    await t.pumpAndSettle();
    expect(shown(ServerFormScreen), findsOneWidget);
  });

  testWidgets('aiHomeGathersAiTools', (t) async {
    final api = withAi(demoApi());
    await api.createConversation('a1', 'essai-court');
    await pump(t, api);
    await tapModule(t, Fr.moduleAi);
    final ai = find.byType(AiHomeScreen);
    expect(find.descendant(of: ai, matching: find.text(Fr.chatCount(1))), findsOneWidget);
    expect(find.descendant(of: ai, matching: find.text(Fr.automationsCount(0))), findsOneWidget);
    expect(find.descendant(of: ai, matching: find.text(Fr.aiServersCount(1))), findsOneWidget);
    await t.tap(find.text(Fr.aiServers));
    await t.pumpAndSettle();
    expect(shown(AiServersScreen), findsOneWidget);
    await back(t);
    await t.tap(find.text(Fr.automations));
    await t.pumpAndSettle();
    expect(shown(AutomationsScreen), findsOneWidget);
  });

  testWidgets('aiHomeEmptyLeadsToAiServers', (t) async {
    await pump(t, demoApi());
    await tapModule(t, Fr.moduleAi);
    final empty = find.descendant(of: find.byType(AiHomeScreen), matching: find.byType(EmptyState));
    expect(empty, findsOneWidget);
    expect(find.descendant(of: empty, matching: find.text(Fr.aiNoServers)), findsOneWidget);
    await t.tap(find.descendant(of: empty, matching: find.text(Fr.aiServers)));
    await t.pumpAndSettle();
    expect(shown(AiServersScreen), findsOneWidget);
  });

  testWidgets('labelsFitAt200Percent', (t) async {
    await pump(t, withAi(demoApi()), size: const Size(320, 640), textScale: 2);
    expect(t.takeException(), isNull);
    for (final m in [Fr.moduleFiles, Fr.moduleRemote, Fr.moduleAi]) {
      final r = t.getRect(find.descendant(of: bar, matching: find.text(m)));
      expect(r.left >= 0 && r.right <= 320 && r.bottom <= 640, isTrue, reason: m);
    }
    for (final d in find.descendant(of: bar, matching: find.byType(InkWell)).evaluate()) {
      final s = t.getSize(find.byWidget(d.widget));
      expect(s.width >= 48 && s.height >= 48, isTrue);
    }
  });
}

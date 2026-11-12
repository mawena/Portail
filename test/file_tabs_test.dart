import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluluks/src/app.dart';
import 'package:fluluks/src/bridge/fluluks_api.g.dart';
import 'package:fluluks/src/screens/explorer_screen.dart';
import 'package:fluluks/src/screens/home_screen.dart';
import 'package:fluluks/src/screens/module_shell.dart';
import 'package:fluluks/src/screens/vaults_home_screen.dart';
import 'package:fluluks/src/state/app_state.dart';
import 'package:fluluks/src/strings_fr.dart';
import 'package:fluluks/src/ui/root.dart';
import 'package:fluluks/src/widgets/file_tab_bar.dart';

import 'demo_data.dart';
import 'fake_host_api.dart';

EntryMsg _d(String path) => EntryMsg(name: path.split('/').last, path: path, type: 'dir', size: 0, mtime: 1700000000);
EntryMsg _f(String path) => EntryMsg(name: path.split('/').last, path: path, type: 'file', size: 1000, mtime: 1700000000);

/// Téléphone (DCIM, Download), disque « Données » (Films), carte SD.
FakeHostApi tabsApi() => demoApi()
  ..dirs['phone'] = {
    '/': [_d('/DCIM'), _d('/Download'), _f('/a.txt'), _f('/b.txt')],
    '/DCIM': [_f('/DCIM/photo.jpg')],
    '/Download': [_f('/Download/doc.pdf')],
  }
  ..dirs['v1'] = {
    '/': [_d('/Films'), _f('/LISEZ-MOI')],
    '/Films': [_f('/Films/film.mkv')],
  };

/// Phase 17 : onglets du module Fichiers (spec § 29).
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

  ModuleShellState shell(WidgetTester t) => t.state<ModuleShellState>(find.byType(ModuleShell));
  Finder shown(Type type) => find.byType(type, skipOffstage: true);
  ExplorerScreen shownExplorer(WidgetTester t) => t.widget<ExplorerScreen>(shown(ExplorerScreen).last);
  String shownPath(WidgetTester t) {
    final s = t.state(shown(ExplorerScreen).last);
    return (s as dynamic).currentPath as String;
  }

  Future<void> back(WidgetTester t) async {
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
  }

  Future<void> tapModule(WidgetTester t, String label) async {
    await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
    await t.pumpAndSettle();
  }

  Future<void> openPhone(WidgetTester t) async {
    await t.tap(find.text('Téléphone'));
    await t.pumpAndSettle();
  }

  group('T2 — une pile de pages par onglet', () {
    testWidgets('newTabOpensFolderAndKeepsTheOther', (t) async {
      await pump(t, tabsApi());
      await openPhone(t);
      await t.tap(find.text('DCIM'));
      await t.pumpAndSettle();
      // sélection dans le premier onglet
      await t.longPress(find.text('photo.jpg'));
      await t.pumpAndSettle();
      expect(find.text(Fr.selected(1)), findsOneWidget);
      final first = t.state(shown(ExplorerScreen).last);

      await shell(t).openInNewTab(sourceId: 'v1', path: '/Films');
      await t.pumpAndSettle();
      final tabs = shell(t).tabs;
      expect(tabs.tabs, hasLength(2));
      expect(tabs.activeIndex, 1);
      expect(shell(t).current, PortailModule.files);
      expect(shownExplorer(t).sourceId, 'v1');
      expect(shownPath(t), '/Films');
      expect(find.text('film.mkv'), findsOneWidget);
      expect(find.text('photo.jpg'), findsNothing); // l'autre onglet est masqué

      // Retour dans le nouvel onglet : dossier parent, accueil, puis il se ferme et l'onglet d'avant revient
      await back(t);
      expect(shownPath(t), '/');
      await back(t);
      expect(shown(HomeScreen), findsOneWidget);
      expect(tabs.tabs, hasLength(2));
      await back(t);
      expect(tabs.tabs, hasLength(1));
      expect(t.state(shown(ExplorerScreen).last), same(first));
      expect(shownPath(t), '/DCIM');
      expect(find.text(Fr.selected(1)), findsOneWidget);
    });

    testWidgets('newTabWithoutPlaceStartsAtHome', (t) async {
      await pump(t, tabsApi());
      await openPhone(t);
      await shell(t).openInNewTab();
      await t.pumpAndSettle();
      expect(shell(t).tabs.tabs, hasLength(2));
      expect(shown(HomeScreen), findsOneWidget);
      expect(shown(ExplorerScreen), findsNothing);
      shell(t).tabs.activate(shell(t).tabs.tabs.first);
      await t.pumpAndSettle();
      expect(shownExplorer(t).sourceId, 'phone');
    });

    testWidgets('backOnLastTabKeepsModuleBehaviour', (t) async {
      final calls = <String>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(call.method);
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await pump(t, tabsApi());
      await shell(t).openInNewTab();
      await t.pumpAndSettle();
      await back(t); // accueil d'un onglet parmi deux : il se ferme
      expect(shell(t).tabs.tabs, hasLength(1));
      expect(calls, isNot(contains('SystemNavigator.pop')));
      await back(t); // dernier onglet, accueil de Fichiers : Android ferme l'application
      expect(calls, contains('SystemNavigator.pop'));
    });

    testWidgets('reselectFilesPopsOnlyTheShownTab', (t) async {
      await pump(t, tabsApi());
      await openPhone(t);
      await shell(t).openInNewTab(sourceId: 'v1', path: '/Films');
      await t.pumpAndSettle();
      await tapModule(t, Fr.moduleFiles);
      expect(shown(HomeScreen), findsOneWidget);
      shell(t).tabs.activate(shell(t).tabs.tabs.first);
      await t.pumpAndSettle();
      expect(shownExplorer(t).sourceId, 'phone');
    });

    testWidgets('hiddenTabIsOutOfSemanticsAndTickers', (t) async {
      final h = t.ensureSemantics();
      await pump(t, tabsApi());
      await openPhone(t);
      await shell(t).openInNewTab(sourceId: 'v1', path: '/Films');
      await t.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp(r'a\.txt')), findsNothing);
      expect(find.bySemanticsLabel(RegExp(r'film\.mkv')), findsWidgets);
      // l'onglet masqué n'anime rien
      final phoneText = find.text('a.txt', skipOffstage: false);
      expect(phoneText, findsOneWidget);
      final modes = find.ancestor(of: phoneText, matching: find.byType(TickerMode, skipOffstage: false));
      expect(t.widgetList<TickerMode>(modes).any((m) => !m.enabled), isTrue);
      h.dispose();
    });

    testWidgets('newTabFromVaultsShowsFiles', (t) async {
      await pump(t, tabsApi());
      await tapModule(t, Fr.moduleVaults);
      expect(shown(VaultsHomeScreen), findsOneWidget);
      await shell(t).openInNewTab(sourceId: 'v1', path: '/Films');
      await t.pumpAndSettle();
      expect(shell(t).current, PortailModule.files);
      expect(shownPath(t), '/Films');
    });

    testWidgets('ninthTabRefused', (t) async {
      await pump(t, tabsApi());
      for (var i = 1; i < 8; i++) {
        await shell(t).openInNewTab();
        await t.pumpAndSettle();
      }
      expect(shell(t).tabs.tabs, hasLength(8));
      await shell(t).openInNewTab(sourceId: 'v1', path: '/Films');
      await t.pump();
      expect(shell(t).tabs.tabs, hasLength(8));
      expect(find.text(Fr.tabsFull), findsOneWidget);
      await t.pumpAndSettle();
    });

    testWidgets('closedTabForgetsItsPages', (t) async {
      await pump(t, tabsApi());
      await shell(t).openInNewTab(sourceId: 'v1', path: '/Films');
      await t.pumpAndSettle();
      final tabs = shell(t).tabs;
      tabs.close(tabs.active);
      await t.pumpAndSettle();
      expect(find.byType(ExplorerScreen, skipOffstage: false), findsNothing);
      expect(shown(HomeScreen), findsOneWidget);
      expect(SchedulerBinding.instance.transientCallbackCount, 0);
    });
  });

  group('T3 — barre d’onglets', () {
    final bar = find.byType(FileTabBar);
    Finder chip(String title) => find.descendant(of: bar, matching: find.text(title));

    testWidgets('noBarWithOneTab', (t) async {
      await pump(t, tabsApi());
      await openPhone(t);
      expect(bar, findsNothing);
    });

    testWidgets('barAboveTitleWithTwoTabs', (t) async {
      await pump(t, tabsApi());
      await openPhone(t);
      await shell(t).openInNewTab(sourceId: 'v1', path: '/Films');
      await t.pumpAndSettle();
      expect(bar, findsOneWidget);
      final appBar = find.byType(AppBar, skipOffstage: true).last;
      expect(t.getRect(bar).bottom, lessThanOrEqualTo(t.getRect(appBar).top + 0.5));
      // la barre prend la marge du haut (barre d'état) : la barre de titre ne la reprend pas
      expect(t.getRect(bar).top, 0);
    });

    testWidgets('titlesFollowTheShownFolder', (t) async {
      await pump(t, tabsApi());
      await openPhone(t);
      await shell(t).openInNewTab();
      await t.pumpAndSettle();
      expect(chip('Téléphone'), findsOneWidget); // racine du stockage : son nom
      expect(chip(Fr.moduleFiles), findsOneWidget); // accueil
      // l'onglet de l'accueil ouvre le disque, puis un dossier
      openExplorer(t.element(shown(HomeScreen)), shell(t).widget.state, 'v1');
      await t.pumpAndSettle();
      expect(chip('Données'), findsOneWidget);
      await t.tap(find.text('Films'));
      await t.pumpAndSettle();
      expect(chip('Films'), findsOneWidget);
      expect(chip('Données'), findsNothing);
      // retour au dossier parent
      await back(t);
      expect(chip('Données'), findsOneWidget);
    });

    testWidgets('titleBackToDiskFolderAfterVaultLeft', (t) async {
      final api = tabsApi();
      await pump(t, api);
      await openPhone(t);
      await shell(t).openInNewTab(sourceId: 'v1', path: '/Films');
      await t.pumpAndSettle();
      // un coffre ouvert dans cet onglet, par-dessus l'explorateur du disque
      api.sources = [...api.sources, SourceMsg(id: 'vault:c', stableKey: 'vault:c', kind: 'vault', label: 'Coffre',
          totalBytes: 1, freeBytes: 1, readOnly: false, roReason: '', encrypted: true)];
      api.dirs['vault:c'] = {'/': [_f('/secret.txt')]};
      final state = shell(t).widget.state;
      await state.refreshSources();
      await t.pumpAndSettle();
      openExplorer(t.element(shown(ExplorerScreen).last), state, 'vault:c'); // rendu à la fermeture de la page
      await t.pumpAndSettle();
      expect(chip('Coffre'), findsOneWidget);
      await back(t);
      expect(chip('Films'), findsOneWidget);
    });

    testWidgets('tapCloseAndPlus', (t) async {
      await pump(t, tabsApi());
      await openPhone(t);
      await shell(t).openInNewTab(sourceId: 'v1', path: '/Films');
      await t.pumpAndSettle();
      await t.tap(chip('Téléphone'));
      await t.pumpAndSettle();
      expect(shell(t).tabs.activeIndex, 0);
      expect(find.text('a.txt'), findsOneWidget);
      await t.tap(find.byTooltip(Fr.closeTabNamed('Films')));
      await t.pumpAndSettle();
      expect(shell(t).tabs.tabs, hasLength(1));
      expect(bar, findsNothing);
      await shell(t).openInNewTab(sourceId: 'v1', path: '/Films');
      await t.pumpAndSettle();
      await t.tap(find.byTooltip(Fr.newTab));
      await t.pumpAndSettle();
      expect(shell(t).tabs.tabs, hasLength(3));
      expect(shown(HomeScreen), findsOneWidget);
      for (var i = 3; i < 8; i++) {
        await t.tap(find.byTooltip(Fr.newTab));
        await t.pumpAndSettle();
      }
      final plus = find.ancestor(of: find.byIcon(Icons.add_rounded), matching: find.byType(IconButton));
      expect(t.widget<IconButton>(plus.first).onPressed, isNull);
      expect(find.byTooltip(Fr.tabsFull), findsOneWidget);
    });

    testWidgets('longPressMenu', (t) async {
      await pump(t, tabsApi());
      await openPhone(t);
      await shell(t).openInNewTab(sourceId: 'v1', path: '/Films');
      await shell(t).openInNewTab();
      await t.pumpAndSettle();
      await t.longPress(chip('Films'));
      await t.pumpAndSettle();
      await t.tap(find.text(Fr.closeOtherTabs));
      await t.pumpAndSettle();
      expect(shell(t).tabs.tabs, hasLength(1));
      expect(shownPath(t), '/Films');
      await shell(t).openInNewTab();
      await t.pumpAndSettle();
      await t.longPress(chip('Films'));
      await t.pumpAndSettle();
      await t.tap(find.text(Fr.closeTab));
      await t.pumpAndSettle();
      expect(shell(t).tabs.tabs, hasLength(1));
      expect(shown(HomeScreen), findsOneWidget);
    });

    testWidgets('talkBackLabelsAndTargets', (t) async {
      final h = t.ensureSemantics();
      await pump(t, tabsApi());
      await openPhone(t);
      await shell(t).openInNewTab(sourceId: 'v1', path: '/Films');
      await shell(t).openInNewTab();
      await t.pumpAndSettle();
      shell(t).tabs.activate(shell(t).tabs.tabs[1]);
      await t.pumpAndSettle();
      final films = find.bySemanticsLabel(Fr.tabLabel(2, 3, 'Films'));
      expect(films, findsOneWidget);
      expect(
          t.getSemantics(films),
          isSemantics(
              label: Fr.tabLabel(2, 3, 'Films'), isSelected: true, isButton: true, hasTapAction: true, hasLongPressAction: true));
      final phone = Fr.tabLabel(1, 3, 'Téléphone');
      expect(t.getSemantics(find.bySemanticsLabel(phone)), isSemantics(label: phone, isSelected: false, isButton: true));
      // croix : bouton lu par son infobulle
      final close = find.byTooltip(Fr.closeTabNamed('Films'));
      expect(close, findsOneWidget);
      expect(t.getSemantics(close),
          isSemantics(tooltip: Fr.closeTabNamed('Films'), isButton: true, hasTapAction: true));
      await expectLater(t, meetsGuideline(androidTapTargetGuideline));
      await expectLater(t, meetsGuideline(labeledTapTargetGuideline));
      h.dispose();
    });

    testWidgets('text200PercentFits', (t) async {
      await pump(t, tabsApi(), textScale: 2);
      // à 200 %, la tuile du téléphone sort de l'écran de l'accueil : onglets ouverts directement
      await shell(t).openInNewTab(sourceId: 'phone');
      await shell(t).openInNewTab(sourceId: 'v1', path: '/Films');
      await shell(t).openInNewTab();
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(bar, findsOneWidget);
    });
  });
}

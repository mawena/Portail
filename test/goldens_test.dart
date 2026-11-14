@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screen_harness.dart';

/// Phase 11, T11 : rendu de référence de six écrans à 412 × 869 (Linux, police de test de Flutter : les textes
/// sont des pavés, la mise en page, les couleurs et les icônes sont comparées). Après un changement voulu :
/// `flutter test --update-goldens test/goldens_test.dart`, puis regarder chaque image avant de la garder.
void main() {
  const cases = {
    'home_light': ('home', Brightness.light),
    'home_dark': ('home', Brightness.dark),
    'explorer_grid_dark': ('explorerGrid', Brightness.dark),
    'unlock_light': ('unlock', Brightness.light),
    'settings_light': ('settings', Brightness.light),
    'welcome_light': ('welcome', Brightness.light),
    'ai_servers_light': ('aiServers', Brightness.light),
    'ai_servers_dark': ('aiServers', Brightness.dark),
    'ai_server_form_light': ('aiServerForm', Brightness.light),
    'ai_server_form_dark': ('aiServerForm', Brightness.dark),
    'chat_list_light': ('chatList', Brightness.light),
    'chat_light': ('chat', Brightness.light),
    'chat_dark': ('chat', Brightness.dark),
    'automations_light': ('automations', Brightness.light),
    'automations_dark': ('automations', Brightness.dark),
    'automation_form_light': ('automationForm', Brightness.light),
    'automation_run_dark': ('automationRun', Brightness.dark),
    // barre des modules (phase 16) : Distants en clair, IA en sombre, rail en paysage
    'shell_light': ('remoteHome', Brightness.light),
    'shell_dark': ('aiHome', Brightness.dark),
    'shell_rail': ('home', Brightness.light),
    // écran d'une analyse (phase 16) : anneaux en clair, carte proportionnelle en sombre
    'analyzer_light': ('analyzer', Brightness.light),
    'analyzer_dark': ('analyzerTreemap', Brightness.dark),
    // barre d'onglets du module Fichiers (phase 17)
    'file_tabs_light': ('fileTabs', Brightness.light),
    'file_tabs_dark': ('fileTabs', Brightness.dark),
  };
  for (final MapEntry(key: name, value: (screen, b)) in cases.entries) {
    testWidgets(name, (t) async {
      await pumpScreen(t, screen, brightness: b, size: name == 'shell_rail' ? const Size(869, 412) : const Size(412, 869));
      await waitForImages(t);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
    });
  }
}

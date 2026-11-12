import 'package:flutter_test/flutter_test.dart';
import 'package:fluluks/src/state/files_tabs.dart';

/// Phase 17, T1 : onglets du module Fichiers (spec § 29).
void main() {
  test('un onglet au départ, affiché, sur l’accueil', () {
    final t = FilesTabs();
    expect(t.tabs, hasLength(1));
    expect(t.active, same(t.tabs.single));
    expect(t.activeIndex, 0);
    expect(t.active.place, isNull);
    expect(t.active.initial, isNull);
    expect(t.canOpen, isTrue);
  });

  test('ouvrir ajoute à la fin et affiche le nouvel onglet', () {
    final t = FilesTabs();
    var calls = 0;
    t.addListener(() => calls++);
    final b = t.open(at: TabPlace('v1', '/Films'))!;
    expect(t.tabs, hasLength(2));
    expect(t.tabs.last, same(b));
    expect(t.active, same(b));
    expect(t.activeIndex, 1);
    expect(b.initial!.sourceId, 'v1');
    expect(b.initial!.path, '/Films');
    expect(b.id, isNot(t.tabs.first.id));
    expect(calls, 1);
  });

  test('fermer l’onglet affiché montre celui affiché juste avant', () {
    final t = FilesTabs();
    final a = t.active;
    final b = t.open()!;
    final c = t.open()!;
    t.activate(a);
    t.close(a);
    expect(t.active, same(c));
    t.close(c);
    expect(t.active, same(b));
    expect(t.tabs, [b]);
  });

  test('fermer un onglet masqué garde l’onglet affiché', () {
    final t = FilesTabs();
    final a = t.active;
    final b = t.open()!;
    t.close(a);
    expect(t.active, same(b));
    expect(t.activeIndex, 0);
  });

  test('le dernier onglet ne se ferme pas', () {
    final t = FilesTabs();
    final a = t.active;
    var calls = 0;
    t.addListener(() => calls++);
    t.close(a);
    t.closeOthers(a);
    expect(t.tabs, [a]);
    expect(calls, 0);
  });

  test('huit onglets au plus', () {
    final t = FilesTabs();
    for (var i = 1; i < FilesTabs.max; i++) {
      expect(t.open(), isNotNull);
    }
    expect(FilesTabs.max, 8);
    expect(t.tabs, hasLength(8));
    expect(t.canOpen, isFalse);
    expect(t.open(), isNull);
    expect(t.tabs, hasLength(8));
  });

  test('fermer les autres onglets garde celui choisi et l’affiche', () {
    final t = FilesTabs();
    t.open();
    final b = t.open()!;
    t.open();
    t.closeOthers(b);
    expect(t.tabs, [b]);
    expect(t.active, same(b));
    // l'historique des onglets fermés est oublié : fermer ensuite n'y revient pas
    final c = t.open()!;
    t.close(c);
    expect(t.active, same(b));
  });

  testWidgets('emplacement : pile des explorateurs ouverts dans l’onglet', (tester) async {
    final t = FilesTabs();
    final a = t.active;
    var calls = 0;
    t.addListener(() => calls++);
    final disk = t.enter(a, 'v1', '/');
    // prévenu après l'image en cours, jamais pendant la construction
    expect(calls, 0);
    await tester.pump();
    expect(calls, 1);
    expect(a.place, same(disk));
    t.moved(disk, '/Films');
    expect(calls, 2);
    expect(a.place!.path, '/Films');
    final vault = t.enter(a, 'vault:x', '/');
    await tester.pump();
    expect(a.place, same(vault));
    t.leave(a, vault);
    await tester.pump();
    expect(a.place, same(disk));
    expect(a.place!.path, '/Films');
    t.leave(a, disk);
    await tester.pump();
    expect(a.place, isNull);
    expect(calls, 5);
  });

  testWidgets('les signalements groupés ne préviennent qu’une fois', (tester) async {
    final t = FilesTabs();
    var calls = 0;
    t.addListener(() => calls++);
    final p = t.enter(t.active, 'phone', '/');
    t.leave(t.active, p);
    t.enter(t.active, 'phone', '/DCIM');
    await tester.pump();
    expect(calls, 1);
    expect(t.active.place!.path, '/DCIM');
  });

  testWidgets('modèle abandonné : plus aucun signalement', (tester) async {
    final t = FilesTabs();
    t.enter(t.active, 'phone', '/');
    t.dispose();
    await tester.pump(); // la microtâche ne prévient pas un modèle abandonné
  });
}

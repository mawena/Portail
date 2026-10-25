import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluluks/src/ai/markdown_view.dart';
import 'package:fluluks/src/strings_fr.dart';
import 'package:fluluks/src/ui/theme.dart';

/// Rendu Markdown des réponses (phase 15, T7) : rendu maison sur le paquet `markdown`, HTML jamais interprété.
void main() {
  final opened = <String>[];

  Future<void> pump(WidgetTester t, String data) async {
    opened.clear();
    await t.pumpWidget(MaterialApp(
      theme: portailTheme(Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(
          child: MarkdownView(data: data, onOpenUrl: (u) async => opened.add(u)),
        ),
      ),
    ));
    await t.pumpAndSettle();
  }

  /// Texte visible de tous les RichText, bout à bout.
  String allText(WidgetTester t) =>
      t.widgetList<RichText>(find.byType(RichText)).map((r) => r.text.toPlainText()).join('\n');

  /// Style du morceau de texte [piece] dans les RichText affichés.
  TextStyle? styleOf(WidgetTester t, String piece) {
    TextStyle? found;
    for (final r in t.widgetList<RichText>(find.byType(RichText))) {
      r.text.visitChildren((span) {
        if (span is TextSpan && span.text == piece) {
          found = span.style;
          return false;
        }
        return true;
      });
      if (found != null) break;
    }
    return found;
  }

  testWidgets('headingsParagraphsEmphasis', (t) async {
    await pump(t, '# Titre\n\nUn paragraphe avec **gras**, *italique* et `code`.\n\nSecond paragraphe.');
    final text = allText(t);
    expect(text, contains('Titre'));
    expect(text, contains('Un paragraphe avec gras, italique et code.'));
    expect(text, contains('Second paragraphe.'));
    expect(styleOf(t, 'gras')!.fontWeight, FontWeight.bold);
    expect(styleOf(t, 'italique')!.fontStyle, FontStyle.italic);
    expect(styleOf(t, 'code')!.fontFamily, 'monospace');
    final title = styleOf(t, 'Titre')!;
    final body = styleOf(t, 'Second paragraphe.')!;
    expect(title.fontSize! > body.fontSize!, isTrue);
  });

  testWidgets('listsBulletedAndNumbered', (t) async {
    await pump(t, '- un\n- deux\n  - imbriqué\n\n3. trois\n4. quatre');
    final text = allText(t);
    for (final s in ['un', 'deux', 'imbriqué', 'trois', 'quatre']) {
      expect(text, contains(s));
    }
    expect(find.text('•'), findsWidgets);
    expect(find.text('3.'), findsOneWidget);
    expect(find.text('4.'), findsOneWidget);
  });

  testWidgets('rawHtmlShownAsTextNeverInterpreted', (t) async {
    await pump(t, 'Avant <b>gras</b> après\n\n<script>alert("x")</script>\n\n<img src="x" onerror="y">');
    final text = allText(t);
    expect(text, contains('<b>gras</b>'));
    expect(text, contains('<script>alert("x")</script>'));
    expect(text, contains('<img src="x" onerror="y">'));
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('codeBlockWithLanguageCopyAndHorizontalScroll', (t) async {
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final long = 'x' * 300;
    await pump(t, 'Voici :\n\n```dart\nvoid main() {\n  print("$long");\n}\n```\n');
    expect(find.text('dart'), findsOneWidget);
    final code = find.textContaining('void main()');
    expect(code, findsOneWidget);
    expect(t.widget<Text>(code).style!.fontFamily, 'monospace');
    expect(t.widget<Text>(code).softWrap, isFalse);
    final scroll = find.ancestor(of: code, matching: find.byType(SingleChildScrollView));
    expect(t.widgetList<SingleChildScrollView>(scroll).any((s) => s.scrollDirection == Axis.horizontal), isTrue);
    await t.tap(find.byTooltip(Fr.chatCopyCode));
    await t.pump();
    expect(copied, 'void main() {\n  print("$long");\n}');
    await t.pumpAndSettle();
  });

  testWidgets('linkOpenedOnlyAfterConfirmingAddress', (t) async {
    await pump(t, 'Voir [le site](https://exemple.fr/page) pour la suite.');
    await t.tapOnText(find.textRange.ofSubstring('le site'));
    await t.pumpAndSettle();
    expect(find.text('https://exemple.fr/page'), findsOneWidget); // adresse montrée
    await t.tap(find.text(Fr.cancel));
    await t.pumpAndSettle();
    expect(opened, isEmpty);
    await t.tapOnText(find.textRange.ofSubstring('le site'));
    await t.pumpAndSettle();
    await t.tap(find.text(Fr.chatOpenLink));
    await t.pumpAndSettle();
    expect(opened, ['https://exemple.fr/page']);
  });

  testWidgets('unsafeLinkSchemesAreNotLinks', (t) async {
    await pump(t, '[piège](javascript:alert(1)) et [fichier](file:///sdcard/x)');
    expect(allText(t), contains('piège'));
    await t.tapOnText(find.textRange.ofSubstring('piège'));
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(opened, isEmpty);
  });

  testWidgets('quoteTableAndRule', (t) async {
    await pump(t, '> Une citation\n\n| Nom | Taille |\n|-----|-------:|\n| a.txt | 3 Ko |\n\n---\n\nFin');
    expect(allText(t), contains('Une citation'));
    expect(find.byType(Table), findsOneWidget);
    expect(allText(t), contains('Taille'));
    expect(allText(t), contains('3 Ko'));
    expect(find.byType(Divider), findsOneWidget);
  });

  testWidgets('unfinishedMarkdownWhileStreamingRendersWithoutError', (t) async {
    for (final partial in ['```py\nprint(', '**gras', '| a | b |\n|--', '- un\n- ', '[lien](https://ex', '> ']) {
      await pump(t, partial);
      expect(t.takeException(), isNull, reason: partial);
    }
  });
}

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:markdown/markdown.dart' as md;

import '../strings_fr.dart';
import '../ui/feedback.dart';
import '../ui/tokens.dart';

/// Rendu Markdown des réponses des modèles (phase 15) : titres, paragraphes, listes (à cocher comprises), citations,
/// emphase, liens, code en ligne, blocs de code (langue, bouton Copier, défilement horizontal, police à chasse fixe
/// du terminal), tableaux simples, règles horizontales. Analyse par le paquet `markdown` (GitHub) ; le HTML brut est
/// montré comme du texte, jamais interprété, et aucune image n'est chargée. Un lien (http, https ou mailto
/// seulement) ne s'ouvre qu'après confirmation de son adresse, par [onOpenUrl]. Du Markdown inachevé (réponse en
/// cours) s'affiche tel qu'il est.
class MarkdownView extends StatefulWidget {
  const MarkdownView({super.key, required this.data, required this.onOpenUrl});

  final String data;
  final Future<void> Function(String url) onOpenUrl;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  final _recognizers = <TapGestureRecognizer>[];
  String? _parsedFrom;
  List<md.Node> _nodes = const [];

  static const _mono = 'monospace';
  static const _linkSchemes = {'http', 'https', 'mailto'};

  @override
  void dispose() {
    _clearRecognizers();
    super.dispose();
  }

  void _clearRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  List<md.Node> _parse(String data) {
    final doc = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored, encodeHtml: false);
    return doc.parseLines(data.replaceAll('\r\n', '\n').split('\n'));
  }

  @override
  Widget build(BuildContext context) {
    if (_parsedFrom != widget.data) {
      _nodes = _parse(widget.data);
      _parsedFrom = widget.data;
    }
    _clearRecognizers();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: Space.s,
      children: _blocks(context, _nodes),
    );
  }

  // --- blocs

  static const _blockTags = {
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'p', 'ul', 'ol', 'blockquote', 'pre', 'table', 'hr', 'li', //
  };

  bool _isBlock(md.Node n) => n is md.Element && _blockTags.contains(n.tag);

  List<Widget> _blocks(BuildContext context, List<md.Node> nodes) {
    final out = <Widget>[];
    final inline = <md.Node>[];
    void flushInline() {
      if (inline.isEmpty) return;
      final copy = List.of(inline);
      inline.clear();
      if (copy.every((n) => n is md.Text && n.text.trim().isEmpty)) return;
      out.add(_paragraph(context, copy, _body(context)));
    }

    for (final n in nodes) {
      if (_isBlock(n)) {
        flushInline();
        out.add(_block(context, n as md.Element));
      } else {
        inline.add(n);
      }
    }
    flushInline();
    return out;
  }

  TextStyle _body(BuildContext context) => Theme.of(context).textTheme.bodyLarge!;

  Widget _block(BuildContext context, md.Element e) {
    final theme = Theme.of(context);
    final t = theme.textTheme;
    final s = theme.colorScheme;
    switch (e.tag) {
      case 'h1':
        return _paragraph(context, e.children ?? const [], t.headlineSmall!);
      case 'h2':
        return _paragraph(context, e.children ?? const [], t.titleLarge!);
      case 'h3':
        return _paragraph(context, e.children ?? const [], t.titleMedium!.copyWith(fontWeight: FontWeight.w600));
      case 'h4' || 'h5' || 'h6':
        return _paragraph(context, e.children ?? const [], t.titleSmall!.copyWith(fontWeight: FontWeight.w600));
      case 'p':
        return _paragraph(context, e.children ?? const [], _body(context));
      case 'ul' || 'ol':
        return _list(context, e);
      case 'blockquote':
        return Container(
          padding: const EdgeInsetsDirectional.only(start: Space.m),
          decoration: BoxDecoration(
            border: BorderDirectional(start: BorderSide(color: s.outlineVariant, width: 4)),
          ),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: s.onSurfaceVariant),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: Space.s,
              children: _blocks(context, e.children ?? const []),
            ),
          ),
        );
      case 'pre':
        return _codeBlock(context, e);
      case 'table':
        return _table(context, e);
      case 'hr':
        return const Divider();
      default: // 'li' hors d'une liste
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _blocks(context, e.children ?? const []),
        );
    }
  }

  Widget _paragraph(BuildContext context, List<md.Node> nodes, TextStyle style) {
    final spans = [for (final n in nodes) _inline(context, n, style)];
    return Text.rich(TextSpan(style: style, children: spans));
  }

  Widget _list(BuildContext context, md.Element e) {
    final ordered = e.tag == 'ol';
    var number = int.tryParse(e.attributes['start'] ?? '') ?? 1;
    final body = _body(context);
    final items = <Widget>[];
    for (final li in (e.children ?? const <md.Node>[]).whereType<md.Element>()) {
      var children = li.children ?? const <md.Node>[];
      String marker;
      if (children.isNotEmpty && children.first is md.Element && (children.first as md.Element).tag == 'input') {
        final box = children.first as md.Element;
        marker = box.attributes.containsKey('checked') ? '☑' : '☐';
        children = children.sublist(1);
      } else {
        marker = ordered ? '${number++}.' : '•';
      }
      items.add(Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: ordered ? Space.xxl : Space.xl,
          child: Text(marker, style: numeric(body)),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: Space.xs,
            children: _blocks(context, children),
          ),
        ),
      ]));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: Space.xs, children: items);
  }

  Widget _codeBlock(BuildContext context, md.Element pre) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final codeEl = (pre.children ?? const <md.Node>[]).whereType<md.Element>().where((c) => c.tag == 'code').firstOrNull;
    final cls = codeEl?.attributes['class'] ?? '';
    final lang = cls.startsWith('language-') ? cls.substring('language-'.length) : null;
    var code = (codeEl ?? pre).textContent;
    if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: s.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.m),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const SizedBox(width: Space.m),
          Expanded(
            child: Text(lang ?? '', style: theme.textTheme.labelMedium?.copyWith(color: s.onSurfaceVariant)),
          ),
          IconButton(
            tooltip: Fr.chatCopyCode,
            icon: const Icon(Icons.content_copy_rounded, size: 20),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code));
              if (context.mounted) showMessage(context, Fr.chatCopied, kind: MessageKind.success);
            },
          ),
        ]),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(Space.m, 0, Space.m, Space.m),
          child: Text(
            code,
            softWrap: false,
            style: theme.textTheme.bodyMedium!.copyWith(fontFamily: _mono, color: s.onSurface),
          ),
        ),
      ]),
    );
  }

  Widget _table(BuildContext context, md.Element table) {
    final s = Theme.of(context).colorScheme;
    final body = _body(context);
    final rows = <TableRow>[];
    for (final section in (table.children ?? const <md.Node>[]).whereType<md.Element>()) {
      final header = section.tag == 'thead';
      for (final tr in (section.children ?? const <md.Node>[]).whereType<md.Element>()) {
        rows.add(TableRow(
          decoration: header ? BoxDecoration(color: s.surfaceContainerHigh) : null,
          children: [
            for (final cell in (tr.children ?? const <md.Node>[]).whereType<md.Element>())
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.m, vertical: Space.s),
                child: _paragraph(
                  context,
                  cell.children ?? const [],
                  header ? body.copyWith(fontWeight: FontWeight.w600) : body,
                ),
              ),
          ],
        ));
      }
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    // tableau irrégulier (réponse en cours) : chaque ligne complétée au nombre de colonnes de la plus longue
    final cols = rows.map((r) => r.children.length).reduce((a, b) => a > b ? a : b);
    final even = [
      for (final r in rows)
        TableRow(
          decoration: r.decoration,
          children: [...r.children, for (var i = r.children.length; i < cols; i++) const SizedBox.shrink()],
        ),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(color: s.outlineVariant),
        children: even,
      ),
    );
  }

  // --- en ligne

  InlineSpan _inline(BuildContext context, md.Node n, TextStyle style) {
    if (n is md.Text) return TextSpan(text: n.text, style: style);
    if (n is! md.Element) return TextSpan(text: n.textContent, style: style);
    final s = Theme.of(context).colorScheme;
    List<InlineSpan> kids(TextStyle st) => [for (final c in n.children ?? const <md.Node>[]) _inline(context, c, st)];
    switch (n.tag) {
      case 'strong':
        return TextSpan(children: kids(style.copyWith(fontWeight: FontWeight.bold)));
      case 'em':
        return TextSpan(children: kids(style.copyWith(fontStyle: FontStyle.italic)));
      case 'del':
        return TextSpan(children: kids(style.copyWith(decoration: TextDecoration.lineThrough)));
      case 'code':
        return TextSpan(
          text: n.textContent,
          style: style.copyWith(fontFamily: _mono, backgroundColor: s.surfaceContainerHighest),
        );
      case 'br':
        return TextSpan(text: '\n', style: style);
      case 'img':
        // aucune image chargée : son texte de remplacement seulement
        final alt = n.attributes['alt'] ?? '';
        return TextSpan(text: alt.isEmpty ? '' : '[$alt]', style: style);
      case 'a':
        final href = n.attributes['href'] ?? '';
        final scheme = Uri.tryParse(href)?.scheme.toLowerCase();
        if (scheme == null || !_linkSchemes.contains(scheme)) return TextSpan(children: kids(style));
        final linkStyle = style.copyWith(color: s.primary, decoration: TextDecoration.underline, decorationColor: s.primary);
        final r = TapGestureRecognizer()..onTap = () => _confirmOpen(context, href);
        _recognizers.add(r);
        return TextSpan(
          children: [for (final c in n.children ?? const <md.Node>[]) _withRecognizer(_inline(context, c, linkStyle), r)],
        );
      default:
        return TextSpan(children: kids(style));
    }
  }

  /// Les morceaux de texte d'un lien reçoivent son geste (un TextSpan parent ne le transmet pas).
  InlineSpan _withRecognizer(InlineSpan span, TapGestureRecognizer r) {
    if (span is! TextSpan) return span;
    return TextSpan(
      text: span.text,
      style: span.style,
      recognizer: span.text == null ? null : r,
      children: span.children?.map((c) => _withRecognizer(c, r)).toList(),
    );
  }

  Future<void> _confirmOpen(BuildContext context, String url) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(Fr.chatOpenLinkTitle),
        content: Text(url, style: const TextStyle(fontFamily: _mono)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(Fr.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text(Fr.chatOpenLink)),
        ],
      ),
    );
    if (ok == true) await widget.onOpenUrl(url);
  }
}

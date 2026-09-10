import 'package:markdown/markdown.dart' as md;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// Builds a printable PDF document from [markdownText] - the counterpart to
/// [flutter_markdown]'s on-screen rendering, for nl_query_dialog.dart's
/// "Imprimer" button. Replaces an earlier version that just wrote the raw
/// text into a [pw.Text] (2026-09-10 user report, with a screenshot: "c'est
/// dégueulasse" - literal `**bold**`/`### heading`/`---`/`| a | b |`
/// Markdown syntax showing up unrendered, and every "€" as a missing-glyph
/// box) - two separate problems, both fixed here:
///
/// 1. The PDF's built-in core font (Helvetica) has no glyph for "€" at all
///    - [PdfGoogleFonts.notoSansRegular]/[notoSansBold] are Unicode-capable
///    fonts fetched at build time (cached by the `printing` package after
///    the first fetch) that do. Falls back to the built-in font, silently,
///    if that fetch fails (e.g. no internet at print time) rather than
///    failing the whole print - "€" would show as a box again in that one
///    case, same as before this fix, but everything else still works.
/// 2. The answer text actually *is* Markdown (this app's own AI answers are
///    always formatted that way, per sql_query_engine.dart's own system
///    prompts) - so it needs real parsing, not verbatim printing. Walks
///    the same `package:markdown` AST [flutter_markdown] itself builds
///    from, converting each block/inline node into the [pdf] package's own
///    widget tree instead of Flutter's.
Future<pw.Document> buildAnswerPdfDocument({
  required String title,
  required String subtitle,
  required String markdownText,
}) async {
  pw.Font? regular;
  pw.Font? bold;
  try {
    regular = await PdfGoogleFonts.notoSansRegular();
    bold = await PdfGoogleFonts.notoSansBold();
  } catch (_) {
    // No internet / fetch failed - fall back to the built-in font below.
  }
  final doc = pw.Document(
    theme: regular == null ? null : pw.ThemeData.withFont(base: regular, bold: bold),
  );
  final nodes = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored)
      .parseLines(markdownText.split('\n'));
  doc.addPage(
    pw.MultiPage(
      build: (context) => [
        pw.Text(title, style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey600)),
        pw.SizedBox(height: 4),
        pw.Text(subtitle, style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600)),
        pw.SizedBox(height: 16),
        ..._buildBlocks(nodes),
      ],
    ),
  );
  return doc;
}

List<pw.Widget> _buildBlocks(List<md.Node> nodes) {
  final widgets = <pw.Widget>[];
  for (final node in nodes) {
    final widget = _buildBlock(node);
    if (widget != null) widgets.add(widget);
  }
  return widgets;
}

const _bodyStyle = pw.TextStyle(fontSize: 11);

pw.Widget? _buildBlock(md.Node node) {
  if (node is! md.Element) {
    // A bare text node at block level (rare - the parser normally wraps
    // stray text in its own paragraph element) - render as-is rather than
    // silently dropping it.
    final text = node is md.Text ? node.text : '';
    return text.trim().isEmpty ? null : _paragraphPadding(pw.Text(text, style: _bodyStyle, overflow: pw.TextOverflow.span));
  }
  switch (node.tag) {
    case 'h1':
      return _heading(node, 18);
    case 'h2':
      return _heading(node, 15);
    case 'h3':
    case 'h4':
    case 'h5':
    case 'h6':
      return _heading(node, 13);
    case 'hr':
      return pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 8),
        child: pw.Divider(color: PdfColors.grey400),
      );
    case 'p':
      return _paragraphPadding(
        pw.RichText(text: _inlineSpan(node, _bodyStyle), overflow: pw.TextOverflow.span),
      );
    case 'ul':
    case 'ol':
      return _paragraphPadding(
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            for (final child in node.children ?? const <md.Node>[])
              if (child is md.Element && child.tag == 'li')
                pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 2),
                  child: pw.Row(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('•  ', style: _bodyStyle),
                      pw.Expanded(
                        child: pw.RichText(text: _inlineSpan(child, _bodyStyle), overflow: pw.TextOverflow.span),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      );
    case 'table':
      return _buildTable(node);
    case 'blockquote':
      return pw.Container(
        margin: const pw.EdgeInsets.only(bottom: 8),
        padding: const pw.EdgeInsets.only(left: 8),
        decoration: const pw.BoxDecoration(
          border: pw.Border(left: pw.BorderSide(color: PdfColors.grey400, width: 2)),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: _buildBlocks(node.children ?? const <md.Node>[]),
        ),
      );
    default:
      // Anything else this app's answers don't normally produce - fall
      // back to its own plain text rather than dropping it silently.
      final text = _plainText(node);
      return text.trim().isEmpty ? null : _paragraphPadding(pw.Text(text, style: _bodyStyle, overflow: pw.TextOverflow.span));
  }
}

pw.Widget _paragraphPadding(pw.Widget child) => pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 8),
      child: child,
    );

pw.Widget _heading(md.Element node, double fontSize) {
  return pw.Padding(
    padding: const pw.EdgeInsets.only(top: 8, bottom: 6),
    child: pw.Text(
      _plainText(node),
      style: pw.TextStyle(fontSize: fontSize, fontWeight: pw.FontWeight.bold),
      // overflow: span - see buildAnswerPdfDocument's own doc comment on
      // the earlier "Widget won't fit into the page" crash; each block
      // here is far smaller than the single giant block that caused it,
      // but a long enough heading (rare, but not impossible) could still
      // hit the same wall without this.
      overflow: pw.TextOverflow.span,
    ),
  );
}

pw.TextSpan _inlineSpan(md.Element node, pw.TextStyle style) {
  return pw.TextSpan(
    style: style,
    children: [
      for (final child in node.children ?? const <md.Node>[])
        ..._inlineChildren(child, style),
    ],
  );
}

List<pw.InlineSpan> _inlineChildren(md.Node node, pw.TextStyle inherited) {
  if (node is md.Text) {
    return [pw.TextSpan(text: node.text)];
  }
  if (node is md.Element) {
    final style = pw.TextStyle(
      fontWeight: node.tag == 'strong' ? pw.FontWeight.bold : null,
      fontStyle: node.tag == 'em' ? pw.FontStyle.italic : null,
    );
    final children = <pw.InlineSpan>[
      for (final child in node.children ?? const <md.Node>[])
        ..._inlineChildren(child, inherited),
    ];
    if (node.tag == 'br') return [const pw.TextSpan(text: '\n')];
    return [pw.TextSpan(style: style, children: children)];
  }
  return const [];
}

String _plainText(md.Node node) {
  if (node is md.Text) return node.text;
  if (node is md.Element) {
    final buffer = StringBuffer();
    for (final child in node.children ?? const <md.Node>[]) {
      buffer.write(_plainText(child));
    }
    return buffer.toString();
  }
  return '';
}

pw.Widget _buildTable(md.Element table) {
  final rows = <pw.TableRow>[];
  for (final section in table.children ?? const <md.Node>[]) {
    if (section is! md.Element) continue;
    final isHead = section.tag == 'thead';
    for (final rowNode in section.children ?? const <md.Node>[]) {
      if (rowNode is! md.Element || rowNode.tag != 'tr') continue;
      final cells = <pw.Widget>[
        for (final cellNode in rowNode.children ?? const <md.Node>[])
          if (cellNode is md.Element)
            pw.Padding(
              padding: const pw.EdgeInsets.all(4),
              child: pw.RichText(
                text: _inlineSpan(
                    cellNode,
                    isHead
                        ? _bodyStyle.copyWith(fontWeight: pw.FontWeight.bold)
                        : _bodyStyle),
              ),
            ),
      ];
      rows.add(pw.TableRow(
        decoration: isHead ? const pw.BoxDecoration(color: PdfColors.grey200) : null,
        children: cells,
      ));
    }
  }
  return pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 8),
    child: pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
      children: rows,
    ),
  );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:money_manager/widgets/answer_pdf.dart';

/// Doesn't (and can't, from a widget test) assert anything about how the
/// PDF actually *looks* - just that real Markdown (headings, bold, lists,
/// tables, horizontal rules, a "€" - see the 2026-09-10 "c'est dégueulasse"
/// user report this file exists to fix) parses and lays out into a real,
/// saveable PDF document without throwing, on every construct this app's
/// own AI answers actually use (see sql_query_engine.dart's system
/// prompts). [PdfGoogleFonts]' network fetch is allowed to fail in a test
/// environment with no internet access - [buildAnswerPdfDocument] falls
/// back to the built-in font in that case rather than throwing, so these
/// tests stay meaningful offline too.
void main() {
  test('a document with headings, bold, a list, a table, a horizontal rule '
      'and a euro sign saves without throwing', () async {
    const markdown = '''
**Analyse détaillée des dépenses**

---

### 1. Vue d'ensemble

| Mois | Total |
|------|-------|
| **Mars 2026** | 2 658,21 € |
| **Avril 2026** | 5 468,05 € |

- Les mois d'**avril** et **juin** sont les plus dépensiers.
- *Octobre* enregistre une forte baisse.
''';
    final doc = await buildAnswerPdfDocument(
      title: 'Money Manager',
      subtitle: '10 septembre 2026 à 09:23',
      markdownText: markdown,
    );
    final bytes = await doc.save();
    expect(bytes, isNotEmpty);
    // A real PDF file always starts with this magic header.
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test('plain text with no Markdown at all still saves fine', () async {
    final doc = await buildAnswerPdfDocument(
      title: 'Money Manager',
      subtitle: 'Aujourd\'hui',
      markdownText: 'Ton solde est de 1 234,56 €.',
    );
    final bytes = await doc.save();
    expect(bytes, isNotEmpty);
  });

  test('empty text still saves a valid (mostly blank) document', () async {
    final doc = await buildAnswerPdfDocument(
      title: 'Money Manager',
      subtitle: 'Aujourd\'hui',
      markdownText: '',
    );
    final bytes = await doc.save();
    expect(bytes, isNotEmpty);
  });

  test('a very long answer spans multiple pages instead of crashing - '
      'regression test for the 2026-09-10 "Widget won\'t fit into the '
      'page" report', () async {
    final longMarkdown = List.generate(
        200, (i) => '- Ligne $i avec un peu de texte pour occuper de la place.')
        .join('\n');
    final doc = await buildAnswerPdfDocument(
      title: 'Money Manager',
      subtitle: 'Aujourd\'hui',
      markdownText: longMarkdown,
    );
    final bytes = await doc.save();
    expect(bytes, isNotEmpty);
  });
}

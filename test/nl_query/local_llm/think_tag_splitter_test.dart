import 'package:flutter_test/flutter_test.dart';
import 'package:money_manager/services/nl_query/local_llm/think_tag_splitter.dart';

void main() {
  test('plain text with no tags at all comes out as one answer segment', () {
    final splitter = ThinkTagSplitter();
    final out = splitter.feed('Bonjour, voici la réponse.');
    expect(out, [('Bonjour, voici la réponse.', false)]);
    expect(splitter.finish(), isEmpty);
  });

  test('a single chunk containing a whole <think>...</think> block splits '
      'into reasoning then answer', () {
    final splitter = ThinkTagSplitter();
    final out = splitter.feed('<think>je réfléchis</think>voici 42€');
    expect(out, [('je réfléchis', true), ('voici 42€', false)]);
    expect(splitter.finish(), isEmpty);
  });

  test('a tag split across two chunks is still recognized', () {
    final splitter = ThinkTagSplitter();
    final out1 = splitter.feed('<thi');
    expect(out1, isEmpty); // held back - could still become "<think>"
    final out2 = splitter.feed('nk>réflexion');
    expect(out2, [('réflexion', true)]);
  });

  test('a closing tag split across two chunks is still recognized', () {
    final splitter = ThinkTagSplitter();
    // "réflexion" itself is emitted right away (nothing at its end is an
    // ambiguous partial-tag prefix) - the split only affects "</think>".
    final out0 = splitter.feed('<think>réflexion');
    expect(out0, [('réflexion', true)]);
    final out1 = splitter.feed('</thi');
    expect(out1, isEmpty); // held back - could still become "</think>"
    final out2 = splitter.feed('nk>réponse');
    expect(out2, [('réponse', false)]);
  });

  test('a bare "<" that never becomes a tag is eventually emitted as plain '
      'text once it\'s clear it wasn\'t one', () {
    final splitter = ThinkTagSplitter();
    final out1 = splitter.feed('1 < 2 et ');
    // "1 < 2 et " itself has no trailing partial-tag suffix to hold back.
    expect(out1, [('1 < 2 et ', false)]);
    final out2 = splitter.feed('3 < 4');
    expect(out2, [('3 < 4', false)]);
  });

  test('token-by-token streaming (one character at a time) reconstructs '
      'the exact same segments as one big chunk', () {
    const fullText = '<think>a b c</think>the answer';
    final splitter = ThinkTagSplitter();
    final collected = <(String, bool)>[];
    for (final char in fullText.split('')) {
      collected.addAll(splitter.feed(char));
    }
    collected.addAll(splitter.finish());
    final reasoning =
        collected.where((s) => s.$2).map((s) => s.$1).join();
    final answer = collected.where((s) => !s.$2).map((s) => s.$1).join();
    expect(reasoning, 'a b c');
    expect(answer, 'the answer');
  });

  test('an unterminated <think> (generation cut off mid-reasoning by '
      'max_tokens) keeps streaming out as reasoning text as it arrives - '
      'never silently held back just because the tag never closes', () {
    final splitter = ThinkTagSplitter();
    final out = splitter.feed('<think>je réfléchis encore et ');
    expect(out, [('je réfléchis encore et ', true)]);
    // Nothing left pending - finish() has nothing more to flush here.
    expect(splitter.finish(), isEmpty);
  });

  test('finish() flushes a still-ambiguous partial tag prefix left '
      'pending when the stream ends mid-tag', () {
    final splitter = ThinkTagSplitter();
    final out = splitter.feed('voici le résultat <th');
    expect(out, [('voici le résultat ', false)]);
    // "<th" was held back as a possible partial "<think>" - the stream
    // ended before it could resolve either way, so finish() flushes it as
    // plain text rather than losing it.
    expect(splitter.finish(), [('<th', false)]);
  });

  test('finish() flushes trailing plain answer text with nothing pending', () {
    final splitter = ThinkTagSplitter();
    splitter.feed('<think>x</think>voilà');
    expect(splitter.finish(), isEmpty); // already fully emitted by feed()
  });

  test('multiple think blocks in the same stream are each split out', () {
    final splitter = ThinkTagSplitter();
    final out = splitter.feed(
        '<think>un</think>bonjour<think>deux</think> voilà');
    expect(out, [
      ('un', true),
      ('bonjour', false),
      ('deux', true),
      (' voilà', false),
    ]);
  });
}

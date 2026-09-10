/// Incrementally splits a growing text stream into "reasoning" (inside
/// `<think>...</think>`) and "answer" (outside) segments, one arriving
/// chunk at a time - the streaming counterpart of cloud_llm_client.dart's
/// `_stripReasoning` (which only ever sees the whole finished text at
/// once). Used by both [LlmEngine] backends' streaming `onChunk` path
/// (2026-09-10 user request: "afficher en temps réel... ce que fait le
/// modèle") so the UI can show live model reasoning in its own panel,
/// distinct from the real answer, for a model that inlines chain-of-thought
/// as `<think>` tags directly in its own output stream - true of every
/// local llama.cpp model (no separate "reasoning" API field exists there),
/// and also true of a cloud provider that ignores OpenRouter's
/// `'reasoning': {'exclude'}` request field and inlines it in `content`
/// instead of the separate `reasoning` delta field.
///
/// A tag can arrive split across two (or more) chunks - e.g. one chunk
/// ending in `"<thi"` and the next starting `"nk>"` - so a partial `<`
/// prefix that might be the start of a tag is held back (never emitted)
/// until enough text has arrived to know for sure either way.
class ThinkTagSplitter {
  static const _openTag = '<think>';
  static const _closeTag = '</think>';

  bool _insideThink = false;
  String _pending = '';

  /// Feeds [chunk] in, returns the newly-resolved `(text, isReasoning)`
  /// segments it produced - possibly empty (still buffering an ambiguous
  /// tag prefix), possibly more than one (a tag boundary was crossed).
  /// Never returns an empty-text segment.
  List<(String, bool)> feed(String chunk) {
    _pending += chunk;
    final out = <(String, bool)>[];
    while (true) {
      final tag = _insideThink ? _closeTag : _openTag;
      final idx = _pending.indexOf(tag);
      if (idx != -1) {
        if (idx > 0) out.add((_pending.substring(0, idx), _insideThink));
        _pending = _pending.substring(idx + tag.length);
        _insideThink = !_insideThink;
        continue;
      }
      // No full tag found in what's buffered - hold back any trailing
      // suffix that could still grow into one, emit the rest (if any) now.
      final holdback = _longestTagPrefixSuffix(_pending, tag);
      final safeLen = _pending.length - holdback;
      if (safeLen > 0) {
        out.add((_pending.substring(0, safeLen), _insideThink));
        _pending = _pending.substring(safeLen);
      }
      break;
    }
    return out;
  }

  /// Flushes whatever's left once the stream is known to be done - an
  /// unterminated `<think>` (generation cut off mid-reasoning by
  /// `max_tokens` - see cloud_llm_client.dart's own doc comment on why
  /// that's a real, expected case, not a bug) still needs its partial
  /// content to show up somewhere rather than silently vanishing. Safe to
  /// call at most once; returns nothing on a second call.
  List<(String, bool)> finish() {
    if (_pending.isEmpty) return const [];
    final out = [(_pending, _insideThink)];
    _pending = '';
    return out;
  }

  /// Longest suffix of [text] that's also a (possibly partial, non-empty)
  /// prefix of [tag] - how many trailing characters of [text] still need
  /// holding back since they might grow into a full tag match with more
  /// input. 0 when nothing at the end of [text] could possibly be the
  /// start of [tag].
  static int _longestTagPrefixSuffix(String text, String tag) {
    final maxLen = text.length < tag.length ? text.length : tag.length - 1;
    for (var len = maxLen; len > 0; len--) {
      if (text.endsWith(tag.substring(0, len))) return len;
    }
    return 0;
  }
}

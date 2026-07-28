T? findById<T>(List<T> items, int? id, int Function(T) idOf) {
  if (id == null) return null;
  for (final item in items) {
    if (idOf(item) == id) return item;
  }
  return null;
}

// Lower-case accented source chars mapped 1:1 to their plain equivalent.
const _accentedChars = 'àâäáãåèéêëìíîïòóôöõùúûüçñ';
const _plainChars = 'aaaaaaeeeeiiiiooooouuuucn';

/// Strips French/Latin accents and lower-cases, so a search for "cinema"
/// also matches "Loisir:Cinéma" - free-text search over user-entered French
/// text is unusable otherwise (nobody types accents reliably on the go).
String foldDiacritics(String input) {
  final buffer = StringBuffer();
  for (final rune in input.toLowerCase().runes) {
    final index = _accentedChars.codeUnits.indexOf(rune);
    buffer.writeCharCode(index == -1 ? rune : _plainChars.codeUnitAt(index));
  }
  return buffer.toString();
}

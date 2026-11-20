/// Pure-Dart Cloze engine ported faithfully from `frontend/src/lib/cloze.ts`.
///
/// Guarantees:
/// - Brace-balanced `{{cN::content::hint}}` parsing (handles nested TeX `{...}`).
/// - Selection wrapping into raw Markdown with containing-block disambiguation
///   and balanced emphasis-marker (`*_` `` ` ``) swallowing.
/// - Clean transformation into Question (`q`) or Answer (`a`) Markdown with
///   inline cloze sentinel markers (`⟦CLOZE:...⟧`) rendered as expressive pills.
library;

const String kMarkdownTag = 'ir4anki::markdown';
const String kClozeOpenSentinel = '\uE000';
const String kClozeCloseSentinel = '\uE001';

class ClozeRange {
  const ClozeRange({
    required this.start,
    required this.end,
    required this.content,
    required this.ordinal,
    this.hint,
  });

  final int start;
  final int end;
  final String content;
  final int ordinal;
  final String? hint;
}

bool isMarkdownNote(List<String> tags) => tags.contains(kMarkdownTag);

/// Brace-balanced parser so TeX groups (`\frac{a}{b}`) and nested clozes
/// do not prematurely terminate a cloze marker.
List<ClozeRange> parseClozeRanges(String text) {
  final out = <ClozeRange>[];
  final openRe = RegExp(r'\{\{c(\d+)::');
  int searchFrom = 0;

  while (searchFrom < text.length) {
    final m = openRe.firstMatch(text.substring(searchFrom));
    if (m == null) break;
    final matchStart = searchFrom + m.start;
    final bodyStart = searchFrom + m.end;
    final n = int.parse(m.group(1)!);

    int depth = 0;
    int end = -1;
    int hintAt = -1;

    for (int i = bodyStart; i < text.length; i++) {
      final ch = text[i];
      if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        if (depth > 0) {
          depth--;
        } else if (i + 1 < text.length && text[i + 1] == '}') {
          end = i;
          break;
        }
      } else if (depth == 0 &&
          hintAt < 0 &&
          i + 1 < text.length &&
          text[i] == ':' &&
          text[i + 1] == ':') {
        hintAt = i;
        i++;
      }
    }

    if (end < 0) {
      searchFrom = bodyStart;
      continue;
    }

    final content = text.substring(bodyStart, hintAt < 0 ? end : hintAt);
    final hint = hintAt < 0 ? null : text.substring(hintAt + 2, end);
    out.add(ClozeRange(
      start: matchStart,
      end: end + 2,
      content: content,
      ordinal: n,
      hint: hint,
    ));
    searchFrom = end + 2;
  }

  return out;
}

/// Returns sorted unique cloze ordinals present in [text].
List<int> clozeOrdinals(String text) {
  final set = <int>{};
  for (final r in parseClozeRanges(text)) {
    set.add(r.ordinal);
  }
  final list = set.toList()..sort();
  return list;
}

/// Transforms cloze syntax into display Markdown with private-use sentinels
/// around active cloze spans so the Markdown renderer highlights them cleanly.
String transformClozeMarkdown(
  String text, {
  required bool showAnswer,
  int? activeOrdinal,
}) {
  final ranges = parseClozeRanges(text);
  if (ranges.isEmpty) return text;

  final buf = StringBuffer();
  int pos = 0;
  for (final r in ranges) {
    buf.write(text.substring(pos, r.start));
    final isActive = activeOrdinal == null || r.ordinal == activeOrdinal;
    final inner = isActive && !showAnswer
        ? '[${(r.hint != null && r.hint!.isNotEmpty) ? r.hint : '…'}]'
        : transformClozeMarkdown(
            r.content,
            showAnswer: showAnswer,
            activeOrdinal: activeOrdinal,
          );
    if (isActive) {
      buf
        ..write(kClozeOpenSentinel)
        ..write(inner)
        ..write(kClozeCloseSentinel);
    } else {
      buf.write(inner);
    }
    pos = r.end;
  }
  buf.write(text.substring(pos));
  return buf.toString();
}

({String norm, List<int> map}) _buildNorm(String text) {
  final buf = StringBuffer();
  final map = <int>[];
  bool lastSpace = false;

  for (int i = 0; i < text.length; i++) {
    final ch = text[i];
    if (ch == '*' || ch == '_' || ch == '`') continue;
    if (RegExp(r'\s').hasMatch(ch)) {
      if (map.isNotEmpty && !lastSpace) {
        buf.write(' ');
        map.add(i);
        lastSpace = true;
      }
    } else {
      buf.write(ch);
      map.add(i);
      lastSpace = false;
    }
  }
  return (norm: buf.toString(), map: map);
}

(int, int)? _normFind(String text, String needle) {
  final cleaned = needle
      .replaceAll(RegExp(r'[*_`]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.isEmpty) return null;

  final (:norm, :map) = _buildNorm(text);
  final j = norm.indexOf(cleaned);
  if (j < 0) return null;

  final start = map[j];
  final lastIdx = j + cleaned.length - 1;
  final end = lastIdx < map.length ? map[lastIdx] + 1 : text.length;
  return (start, end);
}

/// Wraps [selection] in `{{cN::...}}` inside the raw chunk Markdown,
/// disambiguating repeated phrases via optional [containingBlock] and expanding
/// to swallow balanced adjacent emphasis markers (`*_` `` ` ``).
String? wrapSelectionAsCloze(
  String rawText,
  String selection, {
  int ordinal = 1,
  String? containingBlock,
}) {
  if (selection.trim().isEmpty) return null;

  String wrapRange(int s, int e) {
    while (s > 0 && RegExp(r'[*_`]').hasMatch(rawText[s - 1])) {
      s--;
    }
    while (e < rawText.length && RegExp(r'[*_`]').hasMatch(rawText[e])) {
      e++;
    }
    return '${rawText.substring(0, s)}{{c$ordinal::${rawText.substring(s, e)}}}${rawText.substring(e)}';
  }

  if (containingBlock != null && containingBlock.trim().isNotEmpty) {
    final br = _normFind(rawText, containingBlock);
    if (br != null) {
      final inner = rawText.substring(br.$1, br.$2);
      final sr = _normFind(inner, selection);
      if (sr != null) {
        return wrapRange(br.$1 + sr.$1, br.$1 + sr.$2);
      }
    }
  }

  final sr = _normFind(rawText, selection);
  return sr != null ? wrapRange(sr.$1, sr.$2) : null;
}

import '../models/ir4anki_models.dart';

/// Stand-off AI Highlight & Comment matching engine ported from
/// `frontend/src/lib/ai-layer.ts`.
///
/// Guarantees:
/// 1. Zero mutation of source Markdown or segment fingerprints.
/// 2. 2-tier matcher on rendered plain text:
///    - Tier 1: Direct substring match + prefix/suffix disambiguation.
///    - Tier 2: Skeleton-normalized match stripping Markdown symbols, whitespace,
///      and CJK/ASCII punctuation differences.
/// 3. Circled superscript badges (`①..⑳`) and block-level comment grouping.
class ResolvedAiHighlight {
  const ResolvedAiHighlight({
    required this.annotation,
    required this.start,
    required this.end,
    this.badge = '',
  });

  final AiAnnotation annotation;
  final int start;
  final int end;
  final String badge;

  bool get hasComment => annotation.comment.trim().isNotEmpty;
}

class AiLayerEngine {
  static const List<String> _circledNums = [
    '①', '②', '③', '④', '⑤', '⑥', '⑦', '⑧', '⑨', '⑩',
    '⑪', '⑫', '⑬', '⑭', '⑮', '⑯', '⑰', '⑱', '⑲', '⑳',
  ];

  static final RegExp _skipCharsRe = RegExp(
    r'''[\s\*_`~#\>\-\+\|\[\]\(\)!，。、；：？！“”‘’（）【】《》〈〉「」『』—…·,.;:?!\"'\\]''',
  );

  static String badgeForIndex(int index1) {
    if (index1 >= 1 && index1 <= _circledNums.length) {
      return _circledNums[index1 - 1];
    }
    return '[$index1]';
  }

  static ({String skel, List<int> map}) _buildSkeleton(String text) {
    final buf = StringBuffer();
    final map = <int>[];
    for (int i = 0; i < text.length; i++) {
      final ch = text[i];
      if (_skipCharsRe.hasMatch(ch)) continue;
      buf.write(ch.toLowerCase());
      map.add(i);
    }
    return (skel: buf.toString(), map: map);
  }

  static int _scoreContext(
    String fullSkel,
    int start,
    int end,
    String prefixSkel,
    String suffixSkel,
  ) {
    int score = 0;
    if (prefixSkel.isNotEmpty) {
      final pStart = (start - prefixSkel.length).clamp(0, start);
      final actual = fullSkel.substring(pStart, start);
      final tailP = prefixSkel.length > 8
          ? prefixSkel.substring(prefixSkel.length - 8)
          : prefixSkel;
      final tailA = actual.length > 8
          ? actual.substring(actual.length - 8)
          : actual;
      if (actual == prefixSkel) {
        score += 2;
      } else if (actual.endsWith(tailP) || prefixSkel.endsWith(tailA)) {
        score += 1;
      }
    }
    if (suffixSkel.isNotEmpty) {
      final sEnd = (end + suffixSkel.length).clamp(end, fullSkel.length);
      final actual = fullSkel.substring(end, sEnd);
      final headS =
          suffixSkel.length > 8 ? suffixSkel.substring(0, 8) : suffixSkel;
      final headA = actual.length > 8 ? actual.substring(0, 8) : actual;
      if (actual == suffixSkel) {
        score += 2;
      } else if (actual.startsWith(headS) || suffixSkel.startsWith(headA)) {
        score += 1;
      }
    }
    return score;
  }

  static (int, int)? _findInText(
    String fullText,
    String fullSkel,
    List<int> skelMap,
    AiAnnotation ann,
  ) {
    final rawQuote = ann.quoteExact.trim();
    if (rawQuote.isEmpty || fullText.isEmpty) return null;

    final prefixSkel = _buildSkeleton(ann.quotePrefix).skel;
    final suffixSkel = _buildSkeleton(ann.quoteSuffix).skel;

    // Tier 1: Direct substring match
    final exactHits = <(int, int)>[];
    int pos = 0;
    while (pos <= fullText.length - rawQuote.length) {
      final idx = fullText.indexOf(rawQuote, pos);
      if (idx < 0) break;
      exactHits.add((idx, idx + rawQuote.length));
      pos = idx + 1;
    }

    if (exactHits.length == 1) {
      return exactHits.first;
    }
    if (exactHits.length > 1) {
      var best = exactHits.first;
      int bestScore = -1;
      for (final h in exactHits) {
        final pText = _buildSkeleton(
          fullText.substring((h.$1 - 40).clamp(0, h.$1), h.$1),
        ).skel;
        final sText = _buildSkeleton(
          fullText.substring(h.$2, (h.$2 + 40).clamp(h.$2, fullText.length)),
        ).skel;
        int sc = 0;
        if (prefixSkel.isNotEmpty) {
          final pTail = prefixSkel.length > 10
              ? prefixSkel.substring(prefixSkel.length - 10)
              : prefixSkel;
          if (pText.endsWith(pTail)) sc += 2;
        }
        if (suffixSkel.isNotEmpty) {
          final sHead = suffixSkel.length > 10
              ? suffixSkel.substring(0, 10)
              : suffixSkel;
          if (sText.startsWith(sHead)) sc += 2;
        }
        if (sc > bestScore) {
          bestScore = sc;
          best = h;
        }
      }
      return best;
    }

    // Tier 2: Skeleton-normalized match
    final quoteSkel = _buildSkeleton(rawQuote).skel;
    if (quoteSkel.isEmpty || fullSkel.isEmpty) return null;

    final skelHits = <(int, int)>[];
    pos = 0;
    while (pos <= fullSkel.length - quoteSkel.length) {
      final idx = fullSkel.indexOf(quoteSkel, pos);
      if (idx < 0) break;
      skelHits.add((idx, idx + quoteSkel.length));
      pos = idx + 1;
    }
    if (skelHits.isEmpty) return null;

    var bestHit = skelHits.first;
    int bestScore = -1;
    for (final h in skelHits) {
      final sc = _scoreContext(fullSkel, h.$1, h.$2, prefixSkel, suffixSkel);
      if (sc > bestScore) {
        bestScore = sc;
        bestHit = h;
      }
    }

    final startOffset = skelMap[bestHit.$1];
    final endOffset = skelMap[bestHit.$2 - 1] + 1;
    return (startOffset, endOffset);
  }

  /// Resolves active [annotations] onto [renderedText], ordered sequentially
  /// with non-overlapping ranges and numbered badges for comments.
  static List<ResolvedAiHighlight> resolveHighlights(
    String renderedText,
    List<AiAnnotation> annotations, {
    int startingCommentCounter = 0,
  }) {
    final active = annotations
        .where((a) => a.status == 'active' && a.quoteExact.trim().isNotEmpty)
        .toList();
    if (active.isEmpty || renderedText.isEmpty) return const [];

    final (:skel, :map) = _buildSkeleton(renderedText);
    final rawMatches = <({AiAnnotation ann, int start, int end})>[];

    for (final ann in active) {
      final hit = _findInText(renderedText, skel, map, ann);
      if (hit != null && hit.$2 > hit.$1) {
        rawMatches.add((ann: ann, start: hit.$1, end: hit.$2));
      }
    }
    if (rawMatches.isEmpty) return const [];

    rawMatches.sort((a, b) {
      final cmp = a.start.compareTo(b.start);
      return cmp != 0 ? cmp : b.end.compareTo(a.end);
    });

    // Keep non-overlapping ranges in document order and assign sequential badges.
    final resolved = <ResolvedAiHighlight>[];
    int lastEnd = 0;
    int counter = startingCommentCounter;

    for (final m in rawMatches) {
      if (m.start < lastEnd) continue;
      final hasComment = m.ann.comment.trim().isNotEmpty;
      final badge = hasComment ? badgeForIndex(++counter) : '';
      resolved.add(ResolvedAiHighlight(
        annotation: m.ann,
        start: m.start,
        end: m.end,
        badge: badge,
      ));
      lastEnd = m.end;
    }
    return resolved;
  }
}

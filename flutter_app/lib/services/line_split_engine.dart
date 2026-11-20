import 'dart:math' as math;

/// Bookmark line-handle range picker matching `ReadingCard.tsx`'s exact UX:
/// - First click pins `[start, end]`.
/// - Clicking inside the already-selected range cancels/deselects.
/// - Clicking outside moves the NEAREST endpoint so adjusting either end
///   feels effortless (4 → 5 → 3 yields 3–5).
class LineSplitSelection {
  const LineSplitSelection({
    required this.startLine,
    required this.endLine,
  });

  /// 1-indexed relative to the chunk text.
  final int startLine;
  final int endLine;

  int get lineCount => (endLine - startLine) + 1;

  bool contains(int lineStart, int lineEnd) =>
      lineStart <= endLine && lineEnd >= startLine;

  /// Computes next selection state when the user clicks a block spanning
  /// `[clickStart, clickEnd]`. Returns `null` when deselected.
  static LineSplitSelection? togglePick(
    LineSplitSelection? current,
    int clickStart,
    int clickEnd,
  ) {
    final s = math.min(clickStart, clickEnd);
    final e = math.max(clickStart, clickEnd);
    if (current == null) {
      return LineSplitSelection(startLine: s, endLine: e);
    }
    if (s <= current.endLine && e >= current.startLine) {
      return null;
    }
    final mid = s + (e - s) / 2.0;
    final dStart = (mid - current.startLine).abs();
    final dEnd = (mid - current.endLine).abs();
    if (dStart <= dEnd) {
      return LineSplitSelection(
        startLine: math.min(s, current.endLine),
        endLine: math.max(e, current.endLine),
      );
    } else {
      return LineSplitSelection(
        startLine: math.min(s, current.startLine),
        endLine: math.max(e, current.startLine),
      );
    }
  }

  /// Extracts head and tail non-empty preview lines for `SplitDialog` confirmation.
  ({String head, String tail}) previewHeadTail(String chunkText) {
    final lines = chunkText.split('\n');
    final sIdx = (startLine - 1).clamp(0, math.max(0, lines.length - 1)).toInt();
    final eIdx = (endLine - 1).clamp(sIdx, math.max(0, lines.length - 1)).toInt();
    final slice = lines.sublist(sIdx, math.min(lines.length, eIdx + 1));
    final nonEmpty = slice.map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (nonEmpty.isEmpty) {
      return (head: '(空行)', tail: '(空行)');
    }
    String clip(String v) => v.length > 88 ? '${v.substring(0, 88)}…' : v;
    return (head: clip(nonEmpty.first), tail: clip(nonEmpty.last));
  }
}

/// Groups raw Markdown source lines into logical display blocks while preserving
/// exact 1-indexed `[startLine, endLine]` coordinates for bookmark splitting!
///
/// Atomic blocks (fenced code blocks, display math `$$...$$`, Markdown tables,
/// horizontal rules) stay intact as a single block with one gutter handle.
class MarkdownLineBlock {
  const MarkdownLineBlock({
    required this.startLine,
    required this.endLine,
    required this.rawMarkdown,
    required this.isAtomic,
  });

  final int startLine;
  final int endLine;
  final String rawMarkdown;
  final bool isAtomic;
}

List<MarkdownLineBlock> splitMarkdownIntoLineBlocks(String markdown) {
  if (markdown.isEmpty) return const [];
  final lines = markdown.split('\n');
  final blocks = <MarkdownLineBlock>[];
  int i = 0;

  while (i < lines.length) {
    final line = lines[i];
    final trimmed = line.trim();

    // Skip blank separator lines (keep line numbers accurate!)
    if (trimmed.isEmpty) {
      i++;
      continue;
    }

    // 1. Fenced code block (``` or ~~~)
    final fenceMatch = RegExp(r'^(`{3,}|~{3,})').firstMatch(trimmed);
    if (fenceMatch != null) {
      final fence = fenceMatch.group(1)!;
      final start = i;
      i++;
      while (i < lines.length && !lines[i].trim().startsWith(fence)) {
        i++;
      }
      if (i < lines.length) i++;
      blocks.add(MarkdownLineBlock(
        startLine: start + 1,
        endLine: i,
        rawMarkdown: lines.sublist(start, i).join('\n'),
        isAtomic: true,
      ));
      continue;
    }

    // 2. Display math block ($$ ... $$)
    if (trimmed.startsWith(r'$$')) {
      final start = i;
      if (trimmed.length > 2 && trimmed.endsWith(r'$$')) {
        i++;
      } else {
        i++;
        while (i < lines.length && !lines[i].trim().endsWith(r'$$')) {
          i++;
        }
        if (i < lines.length) i++;
      }
      blocks.add(MarkdownLineBlock(
        startLine: start + 1,
        endLine: i,
        rawMarkdown: lines.sublist(start, i).join('\n'),
        isAtomic: true,
      ));
      continue;
    }

    // 3. GFM Table (header row with | followed by separator row |---|)
    if (line.contains('|') &&
        i + 1 < lines.length &&
        RegExp(r'^\s*\|?[\s:-]+\|[\s|:-]*$').hasMatch(lines[i + 1])) {
      final start = i;
      i += 2;
      while (i < lines.length &&
          lines[i].trim().isNotEmpty &&
          lines[i].contains('|')) {
        i++;
      }
      blocks.add(MarkdownLineBlock(
        startLine: start + 1,
        endLine: i,
        rawMarkdown: lines.sublist(start, i).join('\n'),
        isAtomic: true,
      ));
      continue;
    }

    // 4. Horizontal rule
    if (RegExp(r'^(\*\s*\*\s*\*+|-\s*-\s*-+|_\s*_\s*_+)[\s\*\-_]*$')
        .hasMatch(trimmed)) {
      blocks.add(MarkdownLineBlock(
        startLine: i + 1,
        endLine: i + 1,
        rawMarkdown: line,
        isAtomic: true,
      ));
      i++;
      continue;
    }

    // 5. Regular single source line (heading, list item, blockquote, paragraph line)
    blocks.add(MarkdownLineBlock(
      startLine: i + 1,
      endLine: i + 1,
      rawMarkdown: line,
      isAtomic: false,
    ));
    i++;
  }

  return blocks;
}

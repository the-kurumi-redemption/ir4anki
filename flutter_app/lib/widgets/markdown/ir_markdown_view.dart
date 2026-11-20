import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import '../../models/ir4anki_models.dart';
import '../../services/ai_layer_engine.dart';
import '../../services/cloze_engine.dart';
import '../../services/line_split_engine.dart';
import '../../theme/m3e_shapes.dart';
import '../../theme/m3e_theme.dart';
import '../../theme/m3e_typography.dart';

/// Native Flutter Markdown + KaTeX + Image + Cloze + Stand-off AI Highlight +
/// Bookmark Line-Handle Renderer crafted specifically for IR4Anki.
///
/// Key capabilities:
/// - Block-level source line mapping (`1..N`) with optional clickable `.line-handle`
///   gutter dots for bookmark splitting (`ReadingCard`), OR anchored segment
///   highlight bar (`FileViewer` / `SupportingPane`).
/// - Inline bold, italic, strikethrough, inline code, links, inline math (`$...$`
///   and `\(...\)`), display math (`$$...$$` and `\[...\]`), GFM tables, blockquotes,
///   headings (`H1..H6`), ordered/unordered lists, fenced code blocks, and images
///   (`![](:/<id>)`, bare filenames, `/media/...`, `https://...`).
/// - Stand-off AI Highlight Layer: amber highlight spans + circled superscript
///   badges (`①`, `②`…) + always-expanded block callout bars below paragraphs/lists
///   without mutating source text.
/// - Cloze sentinel pills (`kClozeOpenSentinel..kClozeCloseSentinel`) rendered
///   as vibrant Material 3 Expressive inline capsules.
class IRMarkdownView extends StatelessWidget {
  const IRMarkdownView({
    super.key,
    required this.markdown,
    required this.imageUrlResolver,
    this.annotations = const [],
    this.aiLayerEnabled = true,
    this.enableLineHandles = false,
    this.selectedLines,
    this.onLineBlockTap,
    this.anchorLineStart,
    this.anchorLineEnd,
    this.anchorKey,
    this.compact = false,
    this.onSelectionChanged,
  });

  final String markdown;
  final String Function(String src) imageUrlResolver;
  final List<AiAnnotation> annotations;
  final bool aiLayerEnabled;

  /// When true (ReadingCard), renders interactive gutter dots & whole-line
  /// click targets for bookmark splitting.
  final bool enableLineHandles;
  final LineSplitSelection? selectedLines;
  final void Function(int startLine, int endLine)? onLineBlockTap;

  /// Optional file-line range highlight (used in Full Note preview right pane).
  final int? anchorLineStart;
  final int? anchorLineEnd;
  final GlobalKey? anchorKey;

  final bool compact;
  final void Function(String selectedText, String blockText)? onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    final blocks = splitMarkdownIntoLineBlocks(markdown);
    if (blocks.isEmpty) {
      return const SizedBox.shrink();
    }

    int runningCommentCounter = 0;
    final children = <Widget>[];
    bool anchorAssigned = false;

    for (final block in blocks) {
      final plainText = _extractPlainText(block.rawMarkdown);
      final highlights = aiLayerEnabled && annotations.isNotEmpty
          ? AiLayerEngine.resolveHighlights(
              plainText,
              annotations,
              startingCommentCounter: runningCommentCounter,
            )
          : const <ResolvedAiHighlight>[];
      for (final h in highlights) {
        if (h.hasComment) runningCommentCounter++;
      }

      final isPicked =
          selectedLines?.contains(block.startLine, block.endLine) ?? false;
      final isAnchored = anchorLineStart != null &&
          anchorLineEnd != null &&
          block.startLine <= anchorLineEnd! &&
          block.endLine >= anchorLineStart!;

      Key? rowKey;
      if (isAnchored && !anchorAssigned && anchorKey != null) {
        rowKey = anchorKey;
        anchorAssigned = true;
      }

      children.add(
        _MarkdownBlockRow(
          key: rowKey,
          block: block,
          plainText: plainText,
          highlights: highlights,
          imageUrlResolver: imageUrlResolver,
          enableLineHandles: enableLineHandles,
          isPicked: isPicked,
          isAnchored: isAnchored,
          compact: compact,
          onLineTap: onLineBlockTap == null
              ? null
              : () => onLineBlockTap!(block.startLine, block.endLine),
        ),
      );
    }

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );

    if (onSelectionChanged != null) {
      return SelectionArea(
        onSelectionChanged: (content) {
          final text = content?.plainText.trim() ?? '';
          onSelectionChanged!(text, '');
        },
        child: column,
      );
    }

    return SelectionArea(child: column);
  }

  static String _extractPlainText(String md) {
    return md
        .replaceAll(RegExp(r'^#{1,6}\s+'), '')
        .replaceAll(RegExp(r'^\s*[-*+]\s+'), '')
        .replaceAll(RegExp(r'^\s*\d+[.)]\s+'), '')
        .replaceAll(RegExp(r'^\s*>\s?'), '')
        .replaceAll(RegExp(r'!\[([^\]]*)\]\([^)]+\)'), r'$1')
        .replaceAll(RegExp(r'\[([^\]]+)\]\([^)]+\)'), r'$1')
        .replaceAll(RegExp(r'[*_`~]'), '')
        .replaceAll(kClozeOpenSentinel, '')
        .replaceAll(kClozeCloseSentinel, '');
  }
}

class _MarkdownBlockRow extends StatefulWidget {
  const _MarkdownBlockRow({
    super.key,
    required this.block,
    required this.plainText,
    required this.highlights,
    required this.imageUrlResolver,
    required this.enableLineHandles,
    required this.isPicked,
    required this.isAnchored,
    required this.compact,
    this.onLineTap,
  });

  final MarkdownLineBlock block;
  final String plainText;
  final List<ResolvedAiHighlight> highlights;
  final String Function(String src) imageUrlResolver;
  final bool enableLineHandles;
  final bool isPicked;
  final bool isAnchored;
  final bool compact;
  final VoidCallback? onLineTap;

  @override
  State<_MarkdownBlockRow> createState() => _MarkdownBlockRowState();
}

class _MarkdownBlockRowState extends State<_MarkdownBlockRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final semantic = IRSemanticColors.of(context);
    final typo = M3ETypography.of(context);

    final body = _buildBlockContent(context);
    final commentItems =
        widget.highlights.where((h) => h.hasComment).toList(growable: false);

    Color? rowBg;
    Border? rowBorder;
    if (widget.isPicked) {
      rowBg = semantic.linePickFill;
      rowBorder = Border(
        left: BorderSide(color: semantic.linePickBorder, width: 3.5),
      );
    } else if (widget.isAnchored) {
      rowBg = cs.tertiaryContainer.withValues(alpha: 0.42);
      rowBorder = Border(
        left: BorderSide(color: cs.tertiary, width: 3.5),
      );
    } else if (widget.enableLineHandles && _hovered) {
      rowBg = cs.surfaceContainerHigh.withValues(alpha: 0.55);
    }

    Widget contentRow = Container(
      padding: EdgeInsets.symmetric(
        horizontal: widget.enableLineHandles ? 8 : (widget.isAnchored ? 10 : 2),
        vertical: widget.compact ? 2.5 : 4.5,
      ),
      decoration: BoxDecoration(
        color: rowBg,
        borderRadius: BorderRadius.circular(M3ERadius.sm),
        border: rowBorder,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.enableLineHandles)
            Padding(
              padding: const EdgeInsets.only(top: 7, right: 10),
              child: Tooltip(
                message: widget.block.startLine == widget.block.endLine
                    ? '点选第 ${widget.block.startLine} 行切分范围'
                    : '点选第 ${widget.block.startLine}–${widget.block.endLine} 行块',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onLineTap,
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: Center(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        width: widget.isPicked ? 11 : (_hovered ? 10 : 7),
                        height: widget.isPicked ? 11 : (_hovered ? 10 : 7),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: widget.isPicked
                              ? cs.primary
                              : (_hovered
                                  ? cs.primary.withValues(alpha: 0.72)
                                  : cs.outlineVariant.withValues(alpha: 0.8)),
                          border: widget.isPicked
                              ? Border.all(color: cs.onPrimary, width: 1.5)
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Expanded(child: body),
        ],
      ),
    );

    if (widget.enableLineHandles && widget.onLineTap != null) {
      contentRow = MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onDoubleTap: widget.onLineTap,
          child: contentRow,
        ),
      );
    }

    if (commentItems.isEmpty) {
      return Padding(
        padding: EdgeInsets.only(bottom: widget.compact ? 2 : 4),
        child: contentRow,
      );
    }

    return Padding(
      padding: EdgeInsets.only(bottom: widget.compact ? 4 : 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          contentRow,
          Padding(
            padding: EdgeInsets.only(
              left: widget.enableLineHandles ? 34 : 6,
              top: 4,
              bottom: 2,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final item in commentItems)
                  Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: semantic.aiCalloutSurface,
                      borderRadius: BorderRadius.circular(M3ERadius.md),
                      border: Border(
                        left: BorderSide(
                          color: semantic.aiCalloutBorder,
                          width: 3.5,
                        ),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.badge,
                          style: typo.emphasized.labelLarge?.copyWith(
                            color: semantic.aiBadgeColor,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            item.annotation.comment.trim(),
                            style: typo.baseline.bodyMedium?.copyWith(
                              color: cs.onSurface,
                              height: 1.5,
                            ),
                          ),
                        ),
                        if (item.annotation.layerName.isNotEmpty &&
                            item.annotation.layerName != 'default') ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: semantic.aiCalloutBorder
                                  .withValues(alpha: 0.16),
                              borderRadius:
                                  BorderRadius.circular(M3ERadius.full),
                            ),
                            child: Text(
                              item.annotation.layerName,
                              style: typo.emphasized.labelSmall?.copyWith(
                                color: semantic.aiBadgeColor,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBlockContent(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    final raw = widget.block.rawMarkdown;
    final trimmed = raw.trim();

    // 1. Horizontal Rule
    if (RegExp(r'^(\*\s*\*\s*\*+|-\s*-\s*-+|_\s*_\s*_+)[\s\*\-_]*$')
        .hasMatch(trimmed)) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Divider(color: cs.outlineVariant),
      );
    }

    // 2. Fenced Code Block
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      final lines = raw.split('\n');
      final first = lines.first.trim();
      final lang = first.replaceFirst(RegExp(r'^(`{3,}|~{3,})'), '').trim();
      final codeLines = lines.length > 2
          ? lines.sublist(
              1,
              lines.last.trim().startsWith('```') ||
                      lines.last.trim().startsWith('~~~')
                  ? lines.length - 1
                  : lines.length,
            )
          : const <String>[];
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(M3ERadius.lg),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (lang.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  lang.toUpperCase(),
                  style: typo.emphasized.labelSmall?.copyWith(
                    color: cs.primary,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                codeLines.join('\n'),
                style: typo.mono,
              ),
            ),
          ],
        ),
      );
    }

    // 3. Display Math Block ($$ ... $$)
    if (trimmed.startsWith(r'$$') && trimmed.endsWith(r'$$')) {
      final tex = trimmed
          .replaceFirst(RegExp(r'^\$\$'), '')
          .replaceFirst(RegExp(r'\$\$$'), '')
          .trim();
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(M3ERadius.md),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Math.tex(
            tex,
            mathStyle: MathStyle.display,
            textStyle: TextStyle(fontSize: 16, color: cs.onSurface),
            onErrorFallback: (_) => Text(tex, style: typo.mono),
          ),
        ),
      );
    }

    // 4. GFM Table
    if (widget.block.isAtomic &&
        raw.contains('|') &&
        raw.split('\n').length >= 2) {
      return _buildTable(context, raw);
    }

    // 5. Standalone Image line (`![alt](url)`)
    final imgMatch =
        RegExp(r'^!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)$').firstMatch(trimmed);
    if (imgMatch != null) {
      final alt = imgMatch.group(1) ?? '';
      final url = widget.imageUrlResolver(imgMatch.group(2)!);
      return _buildImageWidget(context, url, alt);
    }

    // 6. Headings (# .. ######)
    final headingMatch = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(trimmed);
    if (headingMatch != null) {
      final level = headingMatch.group(1)!.length;
      final content = headingMatch.group(2)!;
      final style = switch (level) {
        1 => typo.emphasized.headlineSmall?.copyWith(fontSize: 22),
        2 => typo.emphasized.titleLarge?.copyWith(fontSize: 19),
        3 => typo.emphasized.titleMedium?.copyWith(fontSize: 16.5),
        _ => typo.emphasized.titleSmall,
      };
      return Padding(
        padding: EdgeInsets.only(
          top: level <= 2 ? (widget.compact ? 6 : 12) : 6,
          bottom: 2,
        ),
        child: _buildRichInlineText(
          context,
          content,
          baseStyle: style ?? typo.emphasized.titleMedium!,
        ),
      );
    }

    // 7. Blockquote (`> ...`)
    final quoteMatch = RegExp(r'^>\s?(.*)$').firstMatch(trimmed);
    if (quoteMatch != null) {
      return Container(
        padding: const EdgeInsets.only(left: 14, top: 4, bottom: 4, right: 8),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh.withValues(alpha: 0.45),
          borderRadius: const BorderRadius.horizontal(
            right: Radius.circular(M3ERadius.md),
          ),
          border: Border(left: BorderSide(color: cs.primary, width: 3)),
        ),
        child: _buildRichInlineText(
          context,
          quoteMatch.group(1)!,
          baseStyle: typo.baseline.bodyLarge!.copyWith(
            color: cs.onSurfaceVariant,
            height: 1.65,
          ),
        ),
      );
    }

    // 8. Unordered & Ordered Lists (preserving indent!)
    final ulMatch = RegExp(r'^(\s*)([-*+])\s+(.*)$').firstMatch(raw);
    if (ulMatch != null) {
      final indent = (ulMatch.group(1)!.length / 2).floor().clamp(0, 6);
      final bodyText = ulMatch.group(3)!;
      return Padding(
        padding: EdgeInsets.only(left: indent * 18.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 10, right: 10),
              child: Container(
                width: indent == 0 ? 6 : 5,
                height: indent == 0 ? 6 : 5,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: indent == 0 ? cs.primary : Colors.transparent,
                  border: indent == 0
                      ? null
                      : Border.all(color: cs.primary, width: 1.3),
                ),
              ),
            ),
            Expanded(
              child: _buildRichInlineText(
                context,
                bodyText,
                baseStyle: _bodyStyle(context),
              ),
            ),
          ],
        ),
      );
    }

    final olMatch = RegExp(r'^(\s*)(\d+[.)])\s+(.*)$').firstMatch(raw);
    if (olMatch != null) {
      final indent = (olMatch.group(1)!.length / 2).floor().clamp(0, 6);
      final marker = olMatch.group(2)!;
      final bodyText = olMatch.group(3)!;
      return Padding(
        padding: EdgeInsets.only(left: indent * 18.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 26,
              child: Text(
                marker,
                style: typo.emphasized.bodyMedium?.copyWith(color: cs.primary),
              ),
            ),
            Expanded(
              child: _buildRichInlineText(
                context,
                bodyText,
                baseStyle: _bodyStyle(context),
              ),
            ),
          ],
        ),
      );
    }

    // 9. Standard paragraph line
    return _buildRichInlineText(
      context,
      trimmed,
      baseStyle: _bodyStyle(context),
    );
  }

  TextStyle _bodyStyle(BuildContext context) {
    final typo = M3ETypography.of(context);
    return (widget.compact
            ? typo.baseline.bodyMedium
            : typo.baseline.bodyLarge)!
        .copyWith(height: widget.compact ? 1.58 : 1.74);
  }

  Widget _buildImageWidget(BuildContext context, String url, String alt) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(M3ERadius.lg),
        child: Container(
          constraints: const BoxConstraints(maxHeight: 420),
          decoration: BoxDecoration(
            color: cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(M3ERadius.lg),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
          ),
          child: Image.network(
            url,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.broken_image_outlined,
                      color: cs.onSurfaceVariant, size: 18),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      alt.isNotEmpty ? '图片加载失败：$alt' : '图片加载失败（$url）',
                      style: typo.baseline.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTable(BuildContext context, String raw) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    final lines = raw
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length < 2) return Text(raw, style: _bodyStyle(context));

    List<String> splitCells(String row) {
      var s = row.trim();
      if (s.startsWith('|')) s = s.substring(1);
      if (s.endsWith('|')) s = s.substring(0, s.length - 1);
      return s.split('|').map((c) => c.trim()).toList();
    }

    final header = splitCells(lines.first);
    final bodyRows = lines.skip(2).map(splitCells).toList();
    final colCount = header.length;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(M3ERadius.lg),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder.symmetric(
            inside: BorderSide(
              color: cs.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
          children: [
            TableRow(
              decoration: BoxDecoration(color: cs.surfaceContainerHigh),
              children: [
                for (int c = 0; c < colCount; c++)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    child: _buildRichInlineText(
                      context,
                      header[c],
                      baseStyle: typo.emphasized.labelLarge!,
                    ),
                  ),
              ],
            ),
            for (final row in bodyRows)
              TableRow(
                children: [
                  for (int c = 0; c < colCount; c++)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      child: _buildRichInlineText(
                        context,
                        c < row.length ? row[c] : '',
                        baseStyle: typo.baseline.bodyMedium!,
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRichInlineText(
    BuildContext context,
    String text, {
    required TextStyle baseStyle,
  }) {
    final spans = _parseInlineSpans(context, text, baseStyle);
    return Text.rich(TextSpan(children: spans));
  }

  /// Parses inline Markdown + KaTeX + Images + Cloze sentinels + AI Highlights.
  List<InlineSpan> _parseInlineSpans(
    BuildContext context,
    String input,
    TextStyle baseStyle,
  ) {
    final cs = Theme.of(context).colorScheme;
    final semantic = IRSemanticColors.of(context);
    final typo = M3ETypography.of(context);

    // Combined inline tokenizer:
    // 1. Cloze sentinel pill: \uE000...\uE001
    // 2. Display math inline: $$...$$ or \[...\]
    // 3. Inline math: $...$ or \(...\)
    // 4. Inline image: ![alt](src)
    // 5. Inline code: `code`
    // 6. Bold: **...** or __...__
    // 7. Italic: *...*
    // 8. Strikethrough: ~~...~~
    // 9. Link: [label](url)
    final tokenRe = RegExp(
      r'(\uE000[^\uE001]*\uE001)'
      r'|(\$\$[^\$]+\$\$|\\\[[\s\S]+?\\\])'
      r'|(\$[^$\n]+\$|\\\([^)]+\\\))'
      r'|(!\[[^\]]*\]\([^)\s]+\))'
      r'|(`[^`]+`)'
      r'|(\*\*[^*]+\*\*|__[^_]+__)'
      r'|(\*[^*\n]+\*)'
      r'|(~~[^~]+~~)'
      r'|(\[[^\]]+\]\([^)]+\))',
    );

    final out = <InlineSpan>[];
    int pos = 0;

    void emitPlainSegment(String segment, TextStyle style) {
      if (segment.isEmpty) return;
      if (widget.highlights.isEmpty) {
        out.add(TextSpan(text: segment, style: style));
        return;
      }
      // Apply stand-off AI highlight spans inside plain text
      final localHits =
          AiLayerEngine.resolveHighlights(segment, widget.highlights.map((h) => h.annotation).toList());
      if (localHits.isEmpty) {
        out.add(TextSpan(text: segment, style: style));
        return;
      }
      int cursor = 0;
      for (final hit in localHits) {
        if (hit.start > cursor) {
          out.add(TextSpan(
              text: segment.substring(cursor, hit.start), style: style));
        }
        // Match the global badge assigned to this annotation
        final globalBadge = widget.highlights
            .where((h) => h.annotation.id == hit.annotation.id)
            .map((h) => h.badge)
            .firstOrNull ?? '';
        out.add(TextSpan(
          text: segment.substring(hit.start, hit.end),
          style: style.copyWith(
            backgroundColor: semantic.aiHighlightFill,
            decoration: TextDecoration.underline,
            decorationColor: semantic.aiHighlightUnderline,
            decorationThickness: 2.0,
          ),
        ));
        if (globalBadge.isNotEmpty) {
          out.add(WidgetSpan(
            alignment: PlaceholderAlignment.top,
            child: Padding(
              padding: const EdgeInsets.only(left: 2, right: 2),
              child: Text(
                globalBadge,
                style: typo.emphasized.labelSmall?.copyWith(
                  color: semantic.aiBadgeColor,
                  fontSize: 11,
                ),
              ),
            ),
          ));
        }
        cursor = hit.end;
      }
      if (cursor < segment.length) {
        out.add(TextSpan(text: segment.substring(cursor), style: style));
      }
    }

    for (final m in tokenRe.allMatches(input)) {
      if (m.start > pos) {
        emitPlainSegment(input.substring(pos, m.start), baseStyle);
      }

      if (m.group(1) != null) {
        // Cloze capsule
        final rawCloze = m.group(1)!;
        final inner = rawCloze.substring(1, rawCloze.length - 1);
        out.add(WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1.5),
            decoration: BoxDecoration(
              color: semantic.clozeChipBg,
              borderRadius: BorderRadius.circular(M3ERadius.sm),
            ),
            child: Text(
              inner,
              style: baseStyle.copyWith(
                color: semantic.clozeChipFg,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ));
      } else if (m.group(2) != null) {
        // Inline display math
        final raw = m.group(2)!;
        final tex = raw.startsWith(r'$$')
            ? raw.substring(2, raw.length - 2).trim()
            : raw.substring(2, raw.length - 2).trim();
        out.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Math.tex(
              tex,
              mathStyle: MathStyle.display,
              textStyle: baseStyle,
              onErrorFallback: (_) => Text(tex, style: typo.mono),
            ),
          ),
        ));
      } else if (m.group(3) != null) {
        // Inline math $...$ or \(...\)
        final raw = m.group(3)!;
        final tex = raw.startsWith(r'$')
            ? raw.substring(1, raw.length - 1).trim()
            : raw.substring(2, raw.length - 2).trim();
        out.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Math.tex(
              tex,
              mathStyle: MathStyle.text,
              textStyle: baseStyle,
              onErrorFallback: (_) => Text(tex, style: typo.mono),
            ),
          ),
        ));
      } else if (m.group(4) != null) {
        // Inline image
        final im = RegExp(r'^!\[([^\]]*)\]\(([^)\s]+)\)$').firstMatch(m.group(4)!);
        if (im != null) {
          out.add(WidgetSpan(
            child: _buildImageWidget(
              context,
              widget.imageUrlResolver(im.group(2)!),
              im.group(1) ?? '',
            ),
          ));
        }
      } else if (m.group(5) != null) {
        // Inline code
        final code = m.group(5)!.substring(1, m.group(5)!.length - 1);
        out.add(WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              code,
              style: typo.mono.copyWith(
                fontSize: (baseStyle.fontSize ?? 15) - 1.5,
                color: cs.primary,
              ),
            ),
          ),
        ));
      } else if (m.group(6) != null) {
        // Bold
        final inner = m.group(6)!.substring(2, m.group(6)!.length - 2);
        emitPlainSegment(
          inner,
          baseStyle.copyWith(fontWeight: FontWeight.w700),
        );
      } else if (m.group(7) != null) {
        // Italic
        final inner = m.group(7)!.substring(1, m.group(7)!.length - 1);
        emitPlainSegment(
          inner,
          baseStyle.copyWith(fontStyle: FontStyle.italic),
        );
      } else if (m.group(8) != null) {
        // Strikethrough
        final inner = m.group(8)!.substring(2, m.group(8)!.length - 2);
        emitPlainSegment(
          inner,
          baseStyle.copyWith(decoration: TextDecoration.lineThrough),
        );
      } else if (m.group(9) != null) {
        // Link
        final lm = RegExp(r'^\[([^\]]+)\]\(([^)]+)\)$').firstMatch(m.group(9)!);
        final label = lm?.group(1) ?? m.group(9)!;
        out.add(TextSpan(
          text: label,
          style: baseStyle.copyWith(
            color: cs.primary,
            decoration: TextDecoration.underline,
            decorationColor: cs.primary.withValues(alpha: 0.6),
          ),
        ));
      }

      pos = m.end;
    }

    if (pos < input.length) {
      emitPlainSegment(input.substring(pos), baseStyle);
    }

    return out;
  }
}

/// Converts legacy Anki HTML card fields into clean Markdown + KaTeX text
/// so legacy non-Markdown cards render cleanly in the native Flutter client.
String cleanLegacyAnkiHtmlToMarkdown(String html) {
  if (html.isEmpty) return '';
  var s = html;
  // Strip <style> and <script> blocks (matching cleanCardHtml in web UI)
  s = s.replaceAll(
      RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false), '');
  s = s.replaceAll(
      RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false), '');
  // Convert <img> tags to Markdown images
  s = s.replaceAllMapped(
    RegExp(r'''<img[^>]+src=["']([^"']+)["'][^>]*>''', caseSensitive: false),
    (m) => '\n![](${m.group(1)})\n',
  );
  // Structural tags to newlines / Markdown
  s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'</(p|div|li|tr|h[1-6])>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '- ');
  s = s.replaceAll(RegExp(r'<b[^>]*>|<strong[^>]*>', caseSensitive: false), '**');
  s = s.replaceAll(RegExp(r'</b>|</strong>', caseSensitive: false), '**');
  s = s.replaceAll(RegExp(r'<i[^>]*>|<em[^>]*>', caseSensitive: false), '*');
  s = s.replaceAll(RegExp(r'</i>|</em>', caseSensitive: false), '*');
  s = s.replaceAll(RegExp(r'<code[^>]*>', caseSensitive: false), '`');
  s = s.replaceAll(RegExp(r'</code>', caseSensitive: false), '`');
  // Strip remaining HTML tags
  s = s.replaceAll(RegExp(r'<[^>]+>'), '');
  // Decode common HTML entities
  s = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
  // Collapse excessive blank lines
  s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return s.trim();
}

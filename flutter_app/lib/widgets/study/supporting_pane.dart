import 'package:flutter/material.dart';
import '../../models/ir4anki_models.dart';
import '../../services/cloze_engine.dart';
import '../../state/app_controller.dart';
import '../../theme/m3e_shapes.dart';
import '../../theme/m3e_theme.dart';
import '../../theme/m3e_typography.dart';
import '../m3e/m3e_button.dart';
import '../m3e/m3e_indicators.dart';
import '../m3e/m3e_segmented_list.dart';
import '../markdown/ir_markdown_view.dart';

enum SupportingTab { fullNote, relatedCards }

/// Right Supporting Pane during Study (`全文参考` + `相关卡片`).
///
/// Enforces IR4Anki's **Answer-Leak Guard**:
/// When reviewing a flashcard face-down (`!isCurrentCardRevealed`), BOTH tabs
/// remain masked behind a calm M3E prompt ("先想一想") so the answer can never
/// leak via the note context or sibling cards before active recall.
class SupportingPane extends StatefulWidget {
  const SupportingPane({
    super.key,
    required this.controller,
  });

  final AppController controller;

  @override
  State<SupportingPane> createState() => _SupportingPaneState();
}

class _SupportingPaneState extends State<SupportingPane> {
  SupportingTab _tab = SupportingTab.fullNote;
  final GlobalKey _anchorKey = GlobalKey();
  String _lastScrolledKey = '';

  void _maybeScrollToAnchor(String anchorIdentity) {
    if (anchorIdentity.isEmpty || anchorIdentity == _lastScrolledKey) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _anchorKey.currentContext;
      if (ctx != null && mounted) {
        _lastScrolledKey = anchorIdentity;
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.18,
          duration: const Duration(milliseconds: 360),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ctrl = widget.controller;
    final phase = ctrl.studyPhase;

    final bool masked =
        phase == StudyViewPhase.review && !ctrl.isCurrentCardRevealed;

    final relatedKey = ctrl.currentRelatedCacheKey;
    final relatedCards = masked
        ? const <ReadingCreatedCard>[]
        : ctrl.cachedRelatedCards(relatedKey);

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? cs.surfaceContainerLow
            : cs.surface,
        borderRadius: BorderRadius.circular(M3ERadius.xl),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.45)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header with M3E Connected Button Group Tab Switcher
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: M3EConnectedButtonGroup<SupportingTab>(
              selected: _tab,
              expand: true,
              size: M3EButtonSize.s,
              onSelected: (next) => setState(() => _tab = next),
              items: [
                const (
                  value: SupportingTab.fullNote,
                  label: '全文参考',
                  icon: Icons.article_outlined,
                  badge: null,
                ),
                (
                  value: SupportingTab.relatedCards,
                  label: '相关卡片',
                  icon: Icons.style_outlined,
                  badge: masked
                      ? null
                      : (relatedCards.isNotEmpty
                          ? '${relatedCards.length}'
                          : null),
                ),
              ],
            ),
          ),

          Divider(color: cs.outlineVariant.withValues(alpha: 0.4)),

          // Body
          Expanded(
            child: masked
                ? _buildAnswerLeakGuard(context)
                : (_tab == SupportingTab.fullNote
                    ? _buildFullNoteTab(context)
                    : _buildRelatedCardsTab(context, relatedCards)),
          ),
        ],
      ),
    );
  }

  Widget _buildAnswerLeakGuard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            M3EShapeContainer(
              kind: M3EShapeKind.cookie8,
              color: cs.secondaryContainer,
              size: 72,
              child: Icon(
                Icons.psychology_rounded,
                size: 34,
                color: cs.onSecondaryContainer,
              ),
            ),
            const SizedBox(height: 18),
            Text('先想一想', style: typo.emphasized.titleLarge),
            const SizedBox(height: 8),
            Text(
              '显示背面答案后，这里会自动定位到制卡时的原文片段与同片段关联卡片，避免提前透题。',
              textAlign: TextAlign.center,
              style: typo.baseline.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFullNoteTab(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    final semantic = IRSemanticColors.of(context);
    final ctrl = widget.controller;
    final phase = ctrl.studyPhase;

    String? path;
    int? lineStart;
    int? lineEnd;
    bool stale = false;
    List<String> crumbs = const [];

    if (phase == StudyViewPhase.reading || phase == StudyViewPhase.trace) {
      final chunk = ctrl.currentReadingChunk;
      if (chunk != null) {
        path = chunk.path;
        lineStart = chunk.lineStart;
        lineEnd = chunk.lineEnd;
        crumbs = chunk.headingPath;
      }
    } else if (phase == StudyViewPhase.review) {
      if (ctrl.reviewSourceLoading) {
        return const Center(child: M3ELoadingIndicator(size: 48));
      }
      final src = ctrl.currentReviewSource;
      if (src == null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.link_off_rounded,
                    size: 40, color: cs.onSurfaceVariant),
                const SizedBox(height: 12),
                Text('这张卡没有阅读来源', style: typo.emphasized.titleMedium),
                const SizedBox(height: 6),
                Text(
                  '可能由桌面 Anki 创建、导入自外部牌组，或来源尚未关联阅读片段。',
                  textAlign: TextAlign.center,
                  style: typo.baseline.bodySmall,
                ),
              ],
            ),
          ),
        );
      }
      path = src.path;
      lineStart = src.lineStart;
      lineEnd = src.lineEnd;
      stale = src.stale;
      crumbs = src.breadcrumb.map((b) => b.title).where((s) => s.isNotEmpty).toList();
    }

    if (path == null || path.isEmpty) {
      return const SizedBox.shrink();
    }

    final fullText = ctrl.cachedFileText(path);
    if (fullText == null) {
      return const Center(child: M3ELoadingIndicator(size: 48));
    }

    final anns = ctrl.cachedAnnotations(path);
    _maybeScrollToAnchor('$path:$lineStart:$lineEnd');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // File Path & Breadcrumb Sub-header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: cs.surfaceContainerHigh.withValues(alpha: 0.45),
          child: Row(
            children: [
              Icon(Icons.description_outlined,
                  size: 16, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  crumbs.isNotEmpty ? '$path · ${crumbs.join(" › ")}' : path,
                  style: typo.baseline.labelMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (stale) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: semantic.warningContainer,
                    borderRadius: BorderRadius.circular(M3ERadius.full),
                  ),
                  child: Text(
                    '原文已漂移',
                    style: typo.emphasized.labelSmall?.copyWith(
                      color: semantic.warningAccent,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            child: IRMarkdownView(
              markdown: fullText,
              imageUrlResolver: (src) =>
                  ctrl.api.resolveImageUrl(src, isAnkiCard: false),
              annotations: anns,
              aiLayerEnabled: ctrl.aiLayerEnabled,
              anchorLineStart: lineStart,
              anchorLineEnd: lineEnd,
              anchorKey: _anchorKey,
              compact: true,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRelatedCardsTab(
    BuildContext context,
    List<ReadingCreatedCard> cards,
  ) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    final ctrl = widget.controller;
    final currentNoteId = ctrl.currentReviewCard?.noteId;

    if (cards.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.style_outlined, size: 40, color: cs.onSurfaceVariant),
              const SizedBox(height: 12),
              Text('本片段暂无已制卡片', style: typo.emphasized.titleMedium),
              const SizedBox(height: 6),
              Text(
                '按 A 添加问答卡，或划词后按 C 添加挖空卡；制成后会自动记录精确溯源关系。',
                textAlign: TextAlign.center,
                style: typo.baseline.bodySmall,
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: cards.length,
      itemBuilder: (ctx, idx) {
        final c = cards[idx];
        final isCurrent = currentNoteId != null && c.noteId == currentNoteId;
        final values = c.fields.values.toList();
        final frontRaw = values.isNotEmpty ? values[0] : '';
        final backRaw = values.length > 1 ? values[1] : '';
        final mdNote = isMarkdownNote(c.tags);

        final frontMd = c.kind == 'cloze'
            ? (mdNote
                ? transformClozeMarkdown(frontRaw, showAnswer: true)
                : cleanLegacyAnkiHtmlToMarkdown(frontRaw))
            : (mdNote ? frontRaw : cleanLegacyAnkiHtmlToMarkdown(frontRaw));

        final backMd = backRaw.trim().isNotEmpty
            ? (mdNote ? backRaw : cleanLegacyAnkiHtmlToMarkdown(backRaw))
            : '';

        return M3ESegmentedListItem(
          index: idx,
          totalCount: cards.length,
          selected: isCurrent,
          selectedColor: cs.primaryContainer.withValues(alpha: 0.55),
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: isCurrent
                          ? cs.primary
                          : cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(M3ERadius.full),
                    ),
                    child: Text(
                      c.kind == 'cloze'
                          ? '挖空 ×${c.numCards}'
                          : '问答',
                      style: typo.emphasized.labelSmall?.copyWith(
                        color: isCurrent ? cs.onPrimary : cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (isCurrent) ...[
                    const SizedBox(width: 8),
                    Text(
                      '当前复习卡',
                      style: typo.emphasized.labelSmall
                          ?.copyWith(color: cs.primary),
                    ),
                  ],
                  const Spacer(),
                  Text('#${c.noteId}', style: typo.baseline.labelSmall),
                ],
              ),
              const SizedBox(height: 10),
              IRMarkdownView(
                markdown: frontMd,
                imageUrlResolver: (src) =>
                    ctrl.api.resolveImageUrl(src, isAnkiCard: true),
                compact: true,
              ),
              if (backMd.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Divider(color: cs.outlineVariant.withValues(alpha: 0.5)),
                ),
                IRMarkdownView(
                  markdown: backMd,
                  imageUrlResolver: (src) =>
                      ctrl.api.resolveImageUrl(src, isAnkiCard: true),
                  compact: true,
                ),
              ],
              if (c.tags.where((t) => t != kMarkdownTag).isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final tag in c.tags.where((t) => t != kMarkdownTag))
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(M3ERadius.full),
                        ),
                        child: Text(
                          tag,
                          style: typo.baseline.labelSmall,
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

import 'package:flutter/material.dart';
import '../../models/ir4anki_models.dart';
import '../../services/cloze_engine.dart';
import '../../state/app_controller.dart';
import '../../theme/m3e_motion.dart';
import '../../theme/m3e_shapes.dart';
import '../../theme/m3e_typography.dart';
import '../m3e/m3e_button.dart';
import '../m3e/m3e_floating_toolbar.dart';
import '../markdown/ir_markdown_view.dart';

/// Material 3 Expressive Flashcard Review View.
///
/// Elevations over the web UI while staying 100% faithful to the user's flow:
/// - Reveal state is strictly keyed by `cardId` in [AppController].
/// - Renders Markdown + Cloze (with exact zero-based `ord + 1`) + KaTeX,
///   or cleanly sanitized legacy Anki HTML.
/// - Displays Anki FSRS `next_intervals` directly on the 4 expressive rating
///   buttons (`Again [1]`, `Hard [2]`, `Good [3]`, `Easy [4]`) plus a subtle
///   FSRS memory state pill (`S` / `D` / `R`) when revealed!
/// - Preserves disabled/greyed `溯源` button for orphan cards (never hidden).
class FlashcardView extends StatefulWidget {
  const FlashcardView({
    super.key,
    required this.controller,
    required this.card,
  });

  final AppController controller;
  final StudyCard card;

  @override
  State<FlashcardView> createState() => _FlashcardViewState();
}

class _FlashcardViewState extends State<FlashcardView> {
  final ScrollController _scrollController = ScrollController();

  @override
  void didUpdateWidget(FlashcardView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.card.cardId != widget.card.cardId &&
        _scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  ({String questionMd, String answerMd}) _resolveCardMarkdown() {
    final card = widget.card;
    final note = widget.controller.noteDetailFor(card.cardId);
    final tags = note?.tags ?? card.tags;
    final fields = note?.fields ?? card.fields;

    if (fields != null && isMarkdownNote(tags)) {
      final values = fields.values.toList();
      final qRaw = values.isNotEmpty ? values[0] : '';
      final aExtra = values.length > 1 ? values[1] : '';
      final isCloze = card.isCloze || note?.kind == 'cloze';
      if (isCloze) {
        final ord = card.ord ?? note?.ord;
        final activeOrdinal = ord != null && ord >= 0 ? ord + 1 : null;
        final qMd = transformClozeMarkdown(
          qRaw,
          showAnswer: false,
          activeOrdinal: activeOrdinal,
        );
        final aBase = transformClozeMarkdown(
          qRaw,
          showAnswer: true,
          activeOrdinal: activeOrdinal,
        );
        final aMd = aExtra.trim().isNotEmpty ? '$aBase\n\n---\n\n$aExtra' : aBase;
        return (questionMd: qMd, answerMd: aMd);
      }
      return (questionMd: qRaw, answerMd: aExtra);
    }

    // Legacy HTML card fallback
    final qMd = cleanLegacyAnkiHtmlToMarkdown(card.question);
    final parts = card.answer.split(RegExp(r'<hr\s+id="?answer"?\s*/?>', caseSensitive: false));
    final rawBack = parts.length > 1 ? parts.sublist(1).join('\n') : parts.first;
    final aMd = cleanLegacyAnkiHtmlToMarkdown(rawBack);
    return (questionMd: qMd, answerMd: aMd);
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这张卡片？'),
        content: const Text('将删除整条 Anki 笔记及其派生的所有卡片，此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.controller.deleteCurrentCard();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    final motion = M3EMotionTokens.of(context);
    final ctrl = widget.controller;
    final card = widget.card;
    final revealed = ctrl.isCurrentCardRevealed;
    final (:questionMd, :answerMd) = _resolveCardMarkdown();
    final intervals = card.nextIntervals;
    final mem = card.memoryState;

    String? intervalAt(int idx) =>
        (intervals != null && idx < intervals.length && intervals[idx].isNotEmpty)
            ? intervals[idx]
            : null;

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
          // Header with Deck Badge + FSRS Pill + M3E Floating Toolbar
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 3),
                            decoration: BoxDecoration(
                              color: card.isNew
                                  ? cs.primaryContainer
                                  : cs.secondaryContainer,
                              borderRadius:
                                  BorderRadius.circular(M3ERadius.full),
                            ),
                            child: Text(
                              card.isNew ? '复习 · 新卡' : '复习 · 到期',
                              style: typo.emphasized.labelSmall?.copyWith(
                                color: card.isNew
                                    ? cs.onPrimaryContainer
                                    : cs.onSecondaryContainer,
                              ),
                            ),
                          ),
                          Text(
                            card.modelName,
                            style: typo.baseline.labelSmall,
                          ),
                          if (revealed &&
                              mem != null &&
                              (mem.stability != null || mem.retention != null))
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: cs.surfaceContainerHighest,
                                borderRadius:
                                    BorderRadius.circular(M3ERadius.full),
                              ),
                              child: Text(
                                [
                                  if (mem.stability != null)
                                    'S ${mem.stability!.toStringAsFixed(1)}d',
                                  if (mem.difficulty != null)
                                    'D ${mem.difficulty!.toStringAsFixed(1)}',
                                  if (mem.retention != null)
                                    'R ${(mem.retention! * 100).round()}%',
                                ].join(' · '),
                                style: typo.emphasized.labelSmall?.copyWith(
                                  fontSize: 10.5,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        card.deckName,
                        style: typo.emphasized.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                M3EFloatingToolbar(
                  children: [
                    M3EIconToggleButton(
                      icon: Icons.undo_rounded,
                      selected: false,
                      tooltip: '撤销上次作答 [Ctrl+Z]',
                      onPressed:
                          (ctrl.session?.canUndo ?? false) && !ctrl.busy
                              ? ctrl.undoLastAnswer
                              : null,
                    ),
                    M3EIconToggleButton(
                      icon: Icons.find_in_page_rounded,
                      selected: false,
                      tooltip: ctrl.traceAvailable
                          ? '溯源：回到制卡时的原文片段'
                          : '这张卡没有阅读来源',
                      onPressed: (ctrl.traceAvailable && !ctrl.busy)
                          ? ctrl.enterTraceDetour
                          : null,
                    ),
                    M3EIconToggleButton(
                      icon: Icons.add_card_rounded,
                      selected: false,
                      tooltip: '添加关联卡片',
                      onPressed: ctrl.busy ? null : ctrl.openAddQaDrawer,
                    ),
                    M3EIconToggleButton(
                      icon: Icons.edit_rounded,
                      selected: false,
                      tooltip: '编辑这张卡片',
                      onPressed:
                          ctrl.busy ? null : ctrl.openEditCurrentCardDrawer,
                    ),
                    M3EIconToggleButton(
                      icon: Icons.delete_outline_rounded,
                      selected: false,
                      tooltip: '删除这张卡片',
                      onPressed: ctrl.busy ? null : _confirmDelete,
                    ),
                  ],
                ),
              ],
            ),
          ),

          Divider(color: cs.outlineVariant.withValues(alpha: 0.4)),

          // Question + Animated Answer Reveal Body
          Expanded(
            child: Scrollbar(
              controller: _scrollController,
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(28, 26, 28, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Question Zone
                    IRMarkdownView(
                      markdown: questionMd,
                      imageUrlResolver: (src) =>
                          ctrl.api.resolveImageUrl(src, isAnkiCard: true),
                    ),

                    // Revealed Answer Zone with spring-inspired entrance
                    AnimatedSwitcher(
                      duration: motion.defaultSpatial.fallbackDuration,
                      switchInCurve: motion.defaultSpatial.fallbackCurve,
                      switchOutCurve: motion.fastEffects.fallbackCurve,
                      child: !revealed
                          ? const SizedBox.shrink(key: ValueKey('hidden'))
                          : Column(
                              key: ValueKey('ans-${card.cardId}'),
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 22),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Divider(
                                            color: cs.outlineVariant),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12),
                                        child: Text(
                                          '答案',
                                          style: typo.emphasized.labelSmall
                                              ?.copyWith(color: cs.primary),
                                        ),
                                      ),
                                      Expanded(
                                        child: Divider(
                                            color: cs.outlineVariant),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.all(20),
                                  decoration: BoxDecoration(
                                    color: cs.surfaceContainerHigh
                                        .withValues(alpha: 0.45),
                                    borderRadius:
                                        BorderRadius.circular(M3ERadius.lgIncreased),
                                  ),
                                  child: IRMarkdownView(
                                    markdown: answerMd,
                                    imageUrlResolver: (src) => ctrl.api
                                        .resolveImageUrl(src, isAnkiCard: true),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Bottom Action Dock (Reveal or 4 Expressive Anki Rating Buttons)
          Divider(color: cs.outlineVariant.withValues(alpha: 0.4)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: !revealed
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      M3EButton(
                        label: '退出本轮',
                        variant: M3EButtonStyleVariant.text,
                        size: M3EButtonSize.m,
                        onPressed: ctrl.busy ? null : ctrl.exitRound,
                      ),
                      M3EButton(
                        label: '显示答案',
                        keycap: 'Space',
                        icon: Icons.visibility_rounded,
                        variant: M3EButtonStyleVariant.filled,
                        size: M3EButtonSize.l,
                        onPressed: ctrl.busy ? null : ctrl.revealCurrentCard,
                      ),
                      const SizedBox(width: 76),
                    ],
                  )
                : Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      M3EButton(
                        label: '退出本轮',
                        variant: M3EButtonStyleVariant.text,
                        size: M3EButtonSize.m,
                        onPressed: ctrl.busy ? null : ctrl.exitRound,
                      ),
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          M3EButton(
                            label: 'Again',
                            sublabel: intervalAt(0),
                            keycap: '1',
                            variant: M3EButtonStyleVariant.tonal,
                            backgroundColor: cs.errorContainer,
                            foregroundColor: cs.onErrorContainer,
                            size: M3EButtonSize.m,
                            onPressed: ctrl.busy
                                ? null
                                : () => ctrl.answerCurrentCard(1),
                          ),
                          M3EButton(
                            label: 'Hard',
                            sublabel: intervalAt(1),
                            keycap: '2',
                            variant: M3EButtonStyleVariant.outlined,
                            size: M3EButtonSize.m,
                            onPressed: ctrl.busy
                                ? null
                                : () => ctrl.answerCurrentCard(2),
                          ),
                          M3EButton(
                            label: 'Good',
                            sublabel: intervalAt(2),
                            keycap: '3',
                            variant: M3EButtonStyleVariant.filled,
                            size: M3EButtonSize.l,
                            onPressed: ctrl.busy
                                ? null
                                : () => ctrl.answerCurrentCard(3),
                          ),
                          M3EButton(
                            label: 'Easy',
                            sublabel: intervalAt(3),
                            keycap: '4',
                            variant: M3EButtonStyleVariant.tonal,
                            backgroundColor: cs.secondaryContainer,
                            foregroundColor: cs.onSecondaryContainer,
                            size: M3EButtonSize.m,
                            onPressed: ctrl.busy
                                ? null
                                : () => ctrl.answerCurrentCard(4),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

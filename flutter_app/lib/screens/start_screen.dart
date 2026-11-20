import 'package:flutter/material.dart';
import '../state/app_controller.dart';
import '../theme/m3e_shapes.dart';
import '../theme/m3e_theme.dart';
import '../theme/m3e_typography.dart';
import '../widgets/m3e/m3e_button.dart';
import '../widgets/m3e/m3e_indicators.dart';

/// Material 3 Expressive Hero Start Screen.
///
/// Preserves the cognitive clarity of IR4Anki's "一天只做一轮" single daily
/// interleaved chain (Read 1 segment → Review its card block → Repeat), while
/// elevating it with M3E editorial typography, organic shape medallions,
/// tonal containment cards, and SplitButton / dual CTAs.
class StartScreen extends StatelessWidget {
  const StartScreen({
    super.key,
    required this.controller,
  });

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    final semantic = IRSemanticColors.of(context);
    final session = controller.session;
    final summary = controller.lastRoundSummary;

    final due = session?.dueRemaining ?? 0;
    final newTotal = session?.newTotal ?? 0;
    final previewPool = session?.previewPool ?? 0;
    final pendingRelease = session?.pendingRelease ?? 0;
    final readingDailyDone = session?.readingDailyDone ?? false;
    final readingRemaining = readingDailyDone
        ? 0
        : (session?.readingDailyRemaining ?? session?.readingDealable ?? 0);
    final readingExtra = session?.readingDealableExtra ?? 0;
    final plan = session?.dailyPlan;
    final readingProgressRatio = (session?.readingDailyPlanned ?? 0) > 0
        ? (session!.readingDailyCompleted / session.readingDailyPlanned)
            .clamp(0.0, 1.0)
        : (readingDailyDone ? 1.0 : 0.0);

    final isEmptyToday =
        due == 0 && newTotal == 0 && previewPool == 0 && readingRemaining == 0;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Container(
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? cs.surfaceContainerLow
                  : cs.surface,
              borderRadius: BorderRadius.circular(M3ERadius.xlIncreased),
              border: Border.all(
                color: cs.outlineVariant.withValues(alpha: 0.45),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Celebratory Hero Summary Strip after completing a round
                if (summary != null) ...[
                  _RoundCompleteBanner(summary: summary),
                  const SizedBox(height: 24),
                ],

                // Editorial Header Row with M3E Organic Shape Medallion
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    M3EShapeContainer(
                      kind: readingDailyDone
                          ? M3EShapeKind.flower
                          : M3EShapeKind.clover4,
                      color: readingDailyDone
                          ? semantic.successContainer
                          : cs.primaryContainer,
                      size: 62,
                      child: Icon(
                        readingDailyDone
                            ? Icons.verified_rounded
                            : Icons.auto_stories_rounded,
                        size: 28,
                        color: readingDailyDone
                            ? semantic.successAccent
                            : cs.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            readingDailyDone ? '今日主计划已完成' : '开始今日学习',
                            style: typo.emphasized.headlineMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '一轮交替推进：读一段笔记，再复习一组卡片；今日新制卡片进预览池，明日自动放行。',
                            style: typo.baseline.bodyMedium?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                // Empty State Guidance
                if (isEmptyToday && session != null) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(M3ERadius.lgIncreased),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          readingDailyDone
                              ? Icons.celebration_rounded
                              : Icons.lightbulb_outline_rounded,
                          color: cs.primary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            readingDailyDone
                                ? '今日阅读与复习计划已全部清零！若精力充沛，可点击下方「追加阅读」。'
                                : '牌组里暂时没有可学内容。可前往「文件」把 Markdown 笔记加入阅读清单开始渐进制卡。',
                            style: typo.baseline.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],

                // Expressive Metric Cards Grid (Reading Plan + Review Batch)
                Row(
                  children: [
                    Expanded(
                      child: _MetricTile(
                        title: readingDailyDone ? '阅读（今日固定池）' : '阅读（今日计划）',
                        value: readingDailyDone
                            ? '已完成'
                            : '$readingRemaining 段',
                        subtitle: (session?.readingDailyPlanned ?? 0) > 0
                            ? '已完成 ${session!.readingDailyCompleted} / ${session.readingDailyPlanned} 段'
                            : '清单共 ${session?.readingListSize ?? 0} 篇',
                        accentColor: semantic.readingAccent,
                        containerColor:
                            semantic.readingContainer.withValues(alpha: 0.42),
                        progress: readingProgressRatio,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _MetricTile(
                        title: '复习（新卡 + 到期）',
                        value: '$due 到期',
                        subtitle:
                            '新卡 ${plan != null && plan.newCount > 0 ? plan.newCount : newTotal} 张 · 均匀穿插',
                        accentColor: cs.primary,
                        containerColor:
                            cs.primaryContainer.withValues(alpha: 0.45),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                // Secondary Pool & Global Stats Strip
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHigh.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(M3ERadius.lgIncreased),
                  ),
                  child: Column(
                    children: [
                      _StatRow(
                        label: '全局待复习到期卡',
                        value: '$due 张',
                      ),
                      const SizedBox(height: 8),
                      _StatRow(
                        label: '牌组可用新卡池',
                        value: '$newTotal 张',
                      ),
                      if (previewPool > 0 || pendingRelease > 0) ...[
                        const SizedBox(height: 8),
                        _StatRow(
                          label: '预览池（明日自动放行）',
                          value: pendingRelease > 0
                              ? '$previewPool 张（今日新制 $pendingRelease）'
                              : '$previewPool 张',
                          highlight: true,
                        ),
                      ],
                      if ((session?.readingGated ?? 0) > 0) ...[
                        const SizedBox(height: 8),
                        _StatRow(
                          label: '等待预览池解冻片段',
                          value: '${session!.readingGated} 段',
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 26),

                // Primary Action CTAs
                if (readingDailyDone && (due > 0 || newTotal > 0))
                  Row(
                    children: [
                      Expanded(
                        child: M3EButton(
                          label: '继续复习',
                          icon: Icons.play_arrow_rounded,
                          size: M3EButtonSize.l,
                          expand: true,
                          onPressed: controller.busy
                              ? null
                              : () => controller.startDailyRound(
                                  extraReading: false),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: M3EButton(
                          label: readingExtra > 0
                              ? '追加阅读（$readingExtra 段）'
                              : '追加阅读',
                          icon: Icons.add_circle_outline_rounded,
                          size: M3EButtonSize.l,
                          variant: M3EButtonStyleVariant.tonal,
                          expand: true,
                          onPressed: controller.busy
                              ? null
                              : () => controller.startDailyRound(
                                  extraReading: true),
                        ),
                      ),
                    ],
                  )
                else if (readingDailyDone)
                  M3EButton(
                    label: readingExtra > 0
                        ? '追加阅读（$readingExtra 段待读）'
                        : '追加阅读',
                    icon: Icons.auto_stories_rounded,
                    size: M3EButtonSize.l,
                    expand: true,
                    onPressed: controller.busy
                        ? null
                        : () => controller.startDailyRound(extraReading: true),
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: M3EButton(
                          label: controller.busy ? '正在发牌…' : '开始今日一轮',
                          icon: Icons.play_arrow_rounded,
                          size: M3EButtonSize.l,
                          expand: true,
                          onPressed: controller.busy
                              ? null
                              : () => controller.startDailyRound(
                                  extraReading: false),
                        ),
                      ),
                      if (readingExtra > 0) ...[
                        const SizedBox(width: 10),
                        M3EButton(
                          label: '追加阅读',
                          icon: Icons.library_add_rounded,
                          size: M3EButtonSize.l,
                          variant: M3EButtonStyleVariant.tonal,
                          tooltip: '跳过固定池限制，直接按清单追加新一轮阅读',
                          onPressed: controller.busy
                              ? null
                              : () => controller.startDailyRound(
                                  extraReading: true),
                        ),
                      ],
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundCompleteBanner extends StatelessWidget {
  const _RoundCompleteBanner({required this.summary});

  final dynamic summary;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    final semantic = IRSemanticColors.of(context);

    final totalReading = summary.totalReading as int;
    final reviewed = summary.reviewed as int;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: semantic.successContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(M3ERadius.xl),
      ),
      child: Row(
        children: [
          M3EShapeContainer(
            kind: M3EShapeKind.softBurst,
            color: semantic.successAccent,
            size: 52,
            child: const Icon(Icons.check_rounded, color: Colors.white, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '本轮完成！',
                  style: typo.emphasized.titleLarge?.copyWith(
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 16,
                  runSpacing: 6,
                  children: [
                    if (totalReading > 0)
                      Text(
                        '阅读处理 $totalReading 段'
                        '${summary.readingSkipped > 0 ? '（跳过 ${summary.readingSkipped}）' : ''}'
                        '${summary.readingNext > 0 ? '（稍后继续 ${summary.readingNext}）' : ''}',
                        style: typo.emphasized.bodyMedium,
                      ),
                    if (reviewed > 0)
                      Text(
                        '卡片复习 $reviewed 张'
                        '${summary.newReviewed > 0 ? '（含新卡 ${summary.newReviewed}）' : ''}',
                        style: typo.emphasized.bodyMedium,
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

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.title,
    required this.value,
    required this.subtitle,
    required this.accentColor,
    required this.containerColor,
    this.progress,
  });

  final String title;
  final String value;
  final String subtitle;
  final Color accentColor;
  final Color containerColor;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: containerColor,
        borderRadius: BorderRadius.circular(M3ERadius.xl),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: typo.emphasized.labelMedium?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: typo.emphasized.headlineSmall?.copyWith(
              color: accentColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: typo.baseline.bodySmall,
          ),
          if (progress != null) ...[
            const SizedBox(height: 10),
            M3EWavyProgressIndicator(
              value: progress!,
              color: accentColor,
              trackColor: accentColor.withValues(alpha: 0.18),
              animateWave: progress! > 0 && progress! < 1,
            ),
          ],
        ],
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: typo.baseline.bodyMedium
                ?.copyWith(color: cs.onSurfaceVariant)),
        Text(
          value,
          style: typo.emphasized.bodyMedium?.copyWith(
            color: highlight ? cs.primary : cs.onSurface,
          ),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import '../../state/app_controller.dart';
import '../../theme/m3e_motion.dart';
import '../../theme/m3e_shapes.dart';
import '../../theme/m3e_theme.dart';
import '../../theme/m3e_typography.dart';
import '../m3e/m3e_indicators.dart';

/// Material 3 Expressive Collapsible / Expandable Navigation Rail.
///
/// Follows Google's May 2025 M3E Navigation Rail spec:
/// - Replaces separate navigation drawer with a single spring-animated
///   collapsed (`88px`) ↔ expanded (`232px`) rail.
/// - Active vertical destination label uses `colorScheme.secondary` with
///   emphasized typography and pill indicator.
/// - Bottom pins dual live circular progress rings (Reading in teal,
///   Review in primary) + one-tap Anki sync status button.
class M3ENavigationRail extends StatelessWidget {
  const M3ENavigationRail({
    super.key,
    required this.controller,
    required this.onQuickSyncTap,
  });

  final AppController controller;
  final VoidCallback onQuickSyncTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    final semantic = IRSemanticColors.of(context);
    final motion = M3EMotionTokens.of(context);

    final expanded = controller.railExpanded;
    final readingProg = controller.readingProgress;
    final reviewProg = controller.reviewProgress;
    final listCount = controller.readingList.length;
    final pendingSync = controller.engineStatus?.localChangesPending ?? false;

    return AnimatedContainer(
      duration: motion.defaultSpatial.fallbackDuration,
      curve: motion.defaultSpatial.fallbackCurve,
      width: expanded ? 232 : 88,
      padding: EdgeInsets.symmetric(
        horizontal: expanded ? 14 : 10,
        vertical: 14,
      ),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(
          right: BorderSide(
            color: cs.outlineVariant.withValues(alpha: 0.45),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment:
            expanded ? CrossAxisAlignment.stretch : CrossAxisAlignment.center,
        children: [
          // Brand header + expand toggle
          Row(
            mainAxisAlignment: expanded
                ? MainAxisAlignment.spaceBetween
                : MainAxisAlignment.center,
            children: [
              if (expanded)
                Expanded(
                  child: Row(
                    children: [
                      M3EShapeContainer(
                        kind: M3EShapeKind.softBurst,
                        color: cs.primaryContainer,
                        size: 38,
                        child: Icon(
                          Icons.auto_stories_rounded,
                          size: 19,
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'IR4Anki',
                              style: typo.emphasized.titleMedium?.copyWith(
                                letterSpacing: -0.2,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '渐进阅读桌面版',
                              style: typo.baseline.labelSmall?.copyWith(
                                fontSize: 10.5,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              IconButton(
                tooltip: expanded ? '收起导航栏' : '展开导航栏',
                onPressed: controller.toggleRailExpanded,
                icon: Icon(
                  expanded
                      ? Icons.menu_open_rounded
                      : Icons.menu_rounded,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // Navigation Destinations
          _RailDestination(
            expanded: expanded,
            selected: controller.section == AppSection.study,
            icon: Icons.school_outlined,
            selectedIcon: Icons.school_rounded,
            label: '学习',
            onTap: () => controller.setSection(AppSection.study),
          ),
          const SizedBox(height: 8),
          _RailDestination(
            expanded: expanded,
            selected: controller.section == AppSection.files,
            icon: Icons.folder_copy_outlined,
            selectedIcon: Icons.folder_copy_rounded,
            label: '文件',
            badge: listCount > 0 ? '$listCount' : null,
            onTap: () => controller.setSection(AppSection.files),
          ),
          const SizedBox(height: 8),
          _RailDestination(
            expanded: expanded,
            selected: controller.section == AppSection.syncSettings,
            icon: Icons.tune_outlined,
            selectedIcon: Icons.tune_rounded,
            label: '同步与设置',
            badge: pendingSync ? '●' : null,
            badgeIsDot: pendingSync,
            onTap: () => controller.setSection(AppSection.syncSettings),
          ),

          const SizedBox(height: 14),
          Divider(color: cs.outlineVariant.withValues(alpha: 0.4)),
          const SizedBox(height: 12),

          // Quick Manual Sync Action
          Tooltip(
            message: pendingSync ? '有本地更改待同步到 AnkiWeb' : '手动同步 Anki',
            child: InkWell(
              onTap: controller.syncing ? null : onQuickSyncTap,
              borderRadius: BorderRadius.circular(M3ERadius.lg),
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: expanded ? 12 : 0,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: pendingSync
                      ? cs.tertiaryContainer.withValues(alpha: 0.75)
                      : cs.surfaceContainerHigh.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(M3ERadius.lg),
                ),
                child: Row(
                  mainAxisAlignment: expanded
                      ? MainAxisAlignment.start
                      : MainAxisAlignment.center,
                  children: [
                    if (controller.syncing)
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      )
                    else
                      Icon(
                        pendingSync
                            ? Icons.sync_problem_rounded
                            : Icons.sync_rounded,
                        size: 20,
                        color: pendingSync
                            ? cs.onTertiaryContainer
                            : cs.onSurfaceVariant,
                      ),
                    if (expanded) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          controller.syncing
                              ? '正在同步…'
                              : (pendingSync ? '待同步' : '手动同步'),
                          style: typo.emphasized.labelLarge?.copyWith(
                            color: pendingSync
                                ? cs.onTertiaryContainer
                                : cs.onSurfaceVariant,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),

          const Spacer(),

          // Bottom-pinned Dual Circular Progress Rings
          if (readingProg.total > 0 || reviewProg.total > 0) ...[
            M3EProgressRing(
              done: readingProg.done,
              total: readingProg.total,
              label: '阅读',
              color: semantic.readingAccent,
              expanded: expanded,
            ),
            const SizedBox(height: 10),
            M3EProgressRing(
              done: reviewProg.done,
              total: reviewProg.total,
              label: '复习',
              color: cs.primary,
              expanded: expanded,
            ),
            const SizedBox(height: 12),
          ],

          // Quick Light/Dark Mode Toggle
          Tooltip(
            message: '切换明暗主题',
            child: IconButton(
              onPressed: () {
                final isDark = Theme.of(context).brightness == Brightness.dark;
                controller
                    .setThemeMode(isDark ? ThemeMode.light : ThemeMode.dark);
              },
              icon: Icon(
                Theme.of(context).brightness == Brightness.dark
                    ? Icons.light_mode_rounded
                    : Icons.dark_mode_rounded,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RailDestination extends StatefulWidget {
  const _RailDestination({
    required this.expanded,
    required this.selected,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.onTap,
    this.badge,
    this.badgeIsDot = false,
  });

  final bool expanded;
  final bool selected;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final VoidCallback onTap;
  final String? badge;
  final bool badgeIsDot;

  @override
  State<_RailDestination> createState() => _RailDestinationState();
}

class _RailDestinationState extends State<_RailDestination> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    final motion = M3EMotionTokens.of(context);

    if (widget.expanded) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: motion.fastSpatial.fallbackDuration,
            curve: motion.fastSpatial.fallbackCurve,
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: widget.selected
                  ? cs.secondaryContainer
                  : (_hovered
                      ? cs.onSurface.withValues(alpha: 0.06)
                      : Colors.transparent),
              borderRadius: BorderRadius.circular(M3ERadius.full),
            ),
            child: Row(
              children: [
                Icon(
                  widget.selected ? widget.selectedIcon : widget.icon,
                  size: 22,
                  color: widget.selected
                      ? cs.onSecondaryContainer
                      : cs.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.label,
                    style: (widget.selected
                            ? typo.emphasized.labelLarge
                            : typo.baseline.labelLarge)
                        ?.copyWith(
                      color: widget.selected
                          ? cs.onSecondaryContainer
                          : cs.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.badge != null)
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: widget.badgeIsDot ? 4 : 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: widget.badgeIsDot
                          ? Colors.transparent
                          : cs.primaryContainer,
                      borderRadius: BorderRadius.circular(M3ERadius.full),
                    ),
                    child: Text(
                      widget.badge!,
                      style: typo.emphasized.labelSmall?.copyWith(
                        color: widget.badgeIsDot
                            ? cs.tertiary
                            : cs.onPrimaryContainer,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    // Collapsed M3E vertical rail item (active label uses `secondary`)
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedContainer(
                  duration: motion.fastSpatial.fallbackDuration,
                  curve: motion.fastSpatial.fallbackCurve,
                  width: 56,
                  height: 34,
                  decoration: BoxDecoration(
                    color: widget.selected
                        ? cs.secondaryContainer
                        : (_hovered
                            ? cs.onSurface.withValues(alpha: 0.06)
                            : Colors.transparent),
                    borderRadius: BorderRadius.circular(M3ERadius.full),
                  ),
                  child: Icon(
                    widget.selected ? widget.selectedIcon : widget.icon,
                    size: 22,
                    color: widget.selected
                        ? cs.onSecondaryContainer
                        : cs.onSurfaceVariant,
                  ),
                ),
                if (widget.badge != null)
                  Positioned(
                    right: -2,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: widget.badgeIsDot ? cs.tertiary : cs.primary,
                        borderRadius: BorderRadius.circular(M3ERadius.full),
                      ),
                      child: Text(
                        widget.badgeIsDot ? '' : widget.badge!,
                        style: typo.emphasized.labelSmall?.copyWith(
                          color: cs.onPrimary,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              widget.label,
              style: (widget.selected
                      ? typo.emphasized.labelSmall
                      : typo.baseline.labelSmall)
                  ?.copyWith(
                color: widget.selected ? cs.secondary : cs.onSurfaceVariant,
                fontSize: 11,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import '../../theme/m3e_motion.dart';
import '../../theme/m3e_shapes.dart';

/// Material 3 Expressive **Segmented List Item** (December 2025 spec).
///
/// Adjacent list rows sit in individual rounded tonal containers with `3dp` gaps:
/// - First item: large top corners (`20dp`), crisp bottom corners (`6dp`)
/// - Middle items: crisp `6dp` corners
/// - Last item: crisp top corners (`6dp`), large bottom corners (`20dp`)
/// - Single item or Selected item: morphs cleanly into a soft `20dp` pill container!
class M3ESegmentedListItem extends StatefulWidget {
  const M3ESegmentedListItem({
    super.key,
    required this.index,
    required this.totalCount,
    required this.child,
    this.selected = false,
    this.onTap,
    this.onSecondaryTapDown,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    this.backgroundColor,
    this.selectedColor,
  });

  final int index;
  final int totalCount;
  final Widget child;
  final bool selected;
  final VoidCallback? onTap;
  final GestureTapDownCallback? onSecondaryTapDown;
  final EdgeInsetsGeometry padding;
  final Color? backgroundColor;
  final Color? selectedColor;

  @override
  State<M3ESegmentedListItem> createState() => _M3ESegmentedListItemState();
}

class _M3ESegmentedListItemState extends State<M3ESegmentedListItem> {
  bool _hovered = false;

  BorderRadius _resolveRadius() {
    if (widget.totalCount <= 1 || widget.selected) {
      return BorderRadius.circular(M3ERadius.lgIncreased);
    }
    final isFirst = widget.index == 0;
    final isLast = widget.index == widget.totalCount - 1;
    const outer = Radius.circular(M3ERadius.lgIncreased);
    const inner = Radius.circular(6);
    return BorderRadius.vertical(
      top: isFirst ? outer : inner,
      bottom: isLast ? outer : inner,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final motion = M3EMotionTokens.of(context);

    final baseBg = widget.selected
        ? (widget.selectedColor ?? cs.secondaryContainer)
        : (widget.backgroundColor ?? cs.surfaceContainerLow);

    final bg = _hovered && widget.onTap != null
        ? Color.alphaBlend(cs.onSurface.withValues(alpha: 0.05), baseBg)
        : baseBg;

    return Padding(
      padding: EdgeInsets.only(
        bottom: widget.index == widget.totalCount - 1 ? 0 : 3,
      ),
      child: MouseRegion(
        cursor: widget.onTap != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          onSecondaryTapDown: widget.onSecondaryTapDown,
          child: AnimatedContainer(
            duration: motion.fastSpatial.fallbackDuration,
            curve: motion.fastSpatial.fallbackCurve,
            padding: widget.padding,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: _resolveRadius(),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import '../../theme/m3e_motion.dart';
import '../../theme/m3e_shapes.dart';
import '../../theme/m3e_typography.dart';

/// Material 3 Expressive Button Sizes (XS, S, M, L, XL).
enum M3EButtonSize {
  xs(height: 32, hPad: 12, iconSize: 16, innerRadius: 6, pressRadius: 8),
  s(height: 40, hPad: 16, iconSize: 18, innerRadius: 8, pressRadius: 10),
  m(height: 48, hPad: 20, iconSize: 20, innerRadius: 10, pressRadius: 12),
  l(height: 56, hPad: 28, iconSize: 22, innerRadius: 14, pressRadius: 16),
  xl(height: 64, hPad: 32, iconSize: 24, innerRadius: 18, pressRadius: 20);

  const M3EButtonSize({
    required this.height,
    required this.hPad,
    required this.iconSize,
    required this.innerRadius,
    required this.pressRadius,
  });

  final double height;
  final double hPad;
  final double iconSize;
  final double innerRadius;
  final double pressRadius;
}

enum M3EButtonStyleVariant { filled, tonal, outlined, elevated, text }

/// Material 3 Expressive Button with physics-driven **Shape Morphing**:
/// - Round pill at rest, smoothly morphing to a crisp squircle on press or selection!
/// - Optional trailing keycap hint badge (e.g. `Space`, `1`, `2`, `3`, `4`).
class M3EButton extends StatefulWidget {
  const M3EButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.sublabel,
    this.icon,
    this.keycap,
    this.size = M3EButtonSize.m,
    this.variant = M3EButtonStyleVariant.filled,
    this.selected = false,
    this.backgroundColor,
    this.foregroundColor,
    this.borderColor,
    this.expand = false,
    this.customRadius,
    this.tooltip,
  });

  final VoidCallback? onPressed;
  final String label;
  final String? sublabel;
  final IconData? icon;
  final String? keycap;
  final M3EButtonSize size;
  final M3EButtonStyleVariant variant;
  final bool selected;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final Color? borderColor;
  final bool expand;
  final BorderRadius? customRadius;
  final String? tooltip;

  @override
  State<M3EButton> createState() => _M3EButtonState();
}

class _M3EButtonState extends State<M3EButton> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    final motion = M3EMotionTokens.of(context);
    final enabled = widget.onPressed != null;

    Color bg;
    Color fg;
    BorderSide border = BorderSide.none;

    switch (widget.variant) {
      case M3EButtonStyleVariant.filled:
        bg = widget.backgroundColor ?? cs.primary;
        fg = widget.foregroundColor ?? cs.onPrimary;
      case M3EButtonStyleVariant.tonal:
        bg = widget.backgroundColor ?? cs.secondaryContainer;
        fg = widget.foregroundColor ?? cs.onSecondaryContainer;
      case M3EButtonStyleVariant.outlined:
        bg = widget.backgroundColor ??
            (widget.selected
                ? cs.secondaryContainer
                : Colors.transparent);
        fg = widget.foregroundColor ??
            (widget.selected ? cs.onSecondaryContainer : cs.onSurface);
        border = BorderSide(
          color: widget.borderColor ??
              (widget.selected ? Colors.transparent : cs.outline),
          width: 1.2,
        );
      case M3EButtonStyleVariant.elevated:
        bg = widget.backgroundColor ?? cs.surfaceContainerLow;
        fg = widget.foregroundColor ?? cs.primary;
      case M3EButtonStyleVariant.text:
        bg = widget.backgroundColor ?? Colors.transparent;
        fg = widget.foregroundColor ?? cs.onSurfaceVariant;
    }

    if (!enabled) {
      bg = widget.variant == M3EButtonStyleVariant.text ||
              widget.variant == M3EButtonStyleVariant.outlined
          ? Colors.transparent
          : cs.onSurface.withValues(alpha: 0.10);
      fg = cs.onSurface.withValues(alpha: 0.38);
      if (border != BorderSide.none) {
        border = BorderSide(color: cs.onSurface.withValues(alpha: 0.12));
      }
    } else if (_hovered && !_pressed) {
      bg = Color.alphaBlend(fg.withValues(alpha: 0.08), bg);
    } else if (_pressed) {
      bg = Color.alphaBlend(fg.withValues(alpha: 0.14), bg);
    }

    final double targetCorner = (_pressed || widget.selected)
        ? widget.size.pressRadius
        : widget.size.height / 2;
    final radius = widget.customRadius ?? BorderRadius.circular(targetCorner);

    final labelStyle = (widget.size.index >= M3EButtonSize.l.index
            ? typo.emphasized.titleMedium
            : typo.emphasized.labelLarge)
        ?.copyWith(color: fg);

    Widget content = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.icon != null) ...[
          Icon(widget.icon, size: widget.size.iconSize, color: fg),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label,
                style: labelStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (widget.sublabel != null && widget.sublabel!.isNotEmpty)
                Text(
                  widget.sublabel!,
                  style: typo.baseline.labelSmall?.copyWith(
                    color: fg.withValues(alpha: 0.82),
                    fontSize: 10.5,
                    height: 1.15,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
        if (widget.keycap != null) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: fg.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(M3ERadius.xs + 2),
              border: Border.all(color: fg.withValues(alpha: 0.22), width: 0.8),
            ),
            child: Text(
              widget.keycap!,
              style: typo.emphasized.labelSmall?.copyWith(
                color: fg.withValues(alpha: 0.9),
                fontSize: 10.5,
                height: 1.1,
              ),
            ),
          ),
        ],
      ],
    );

    Widget button = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTap: widget.onPressed,
        child: AnimatedScale(
          scale: _pressed ? 0.965 : 1.0,
          duration: motion.fastSpatial.fallbackDuration,
          curve: motion.fastSpatial.fallbackCurve,
          child: AnimatedContainer(
            duration: motion.fastSpatial.fallbackDuration,
            curve: motion.fastSpatial.fallbackCurve,
            constraints: BoxConstraints(
              minHeight: widget.size.height,
              minWidth: widget.size.height,
            ),
            padding: EdgeInsets.symmetric(
              horizontal: widget.size.hPad,
              vertical: widget.sublabel != null ? 6 : 8,
            ),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: radius,
              border: border == BorderSide.none ? null : Border.fromBorderSide(border),
            ),
            child: content,
          ),
        ),
      ),
    );

    if (widget.tooltip != null) {
      button = Tooltip(message: widget.tooltip!, child: button);
    }
    return button;
  }
}

/// Material 3 Expressive Connected Button Group (replaces legacy SegmentedButton).
///
/// Uses fixed `2dp` inner gap, fully rounded outer ends, and size-adaptive inner
/// corner radii (`8dp` / `10dp`), with spring-morphed active pill!
class M3EConnectedButtonGroup<T> extends StatelessWidget {
  const M3EConnectedButtonGroup({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelected,
    this.size = M3EButtonSize.s,
    this.expand = false,
  });

  final List<({T value, String label, IconData? icon, String? badge})> items;
  final T selected;
  final ValueChanged<T> onSelected;
  final M3EButtonSize size;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    final motion = M3EMotionTokens.of(context);

    final children = <Widget>[];
    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      final isSelected = item.value == selected;
      final isFirst = i == 0;
      final isLast = i == items.length - 1;

      final double outerR = size.height / 2;
      final double innerR = isSelected ? size.height / 2 : size.innerRadius;
      final radius = BorderRadius.horizontal(
        left: Radius.circular(isFirst ? outerR : innerR),
        right: Radius.circular(isLast ? outerR : innerR),
      );

      final segment = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => onSelected(item.value),
          child: AnimatedContainer(
            duration: motion.fastSpatial.fallbackDuration,
            curve: motion.fastSpatial.fallbackCurve,
            height: size.height,
            padding: EdgeInsets.symmetric(horizontal: size.hPad),
            decoration: BoxDecoration(
              color: isSelected
                  ? cs.secondaryContainer
                  : cs.surfaceContainerHigh,
              borderRadius: radius,
            ),
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (item.icon != null) ...[
                  Icon(
                    item.icon,
                    size: size.iconSize,
                    color: isSelected
                        ? cs.onSecondaryContainer
                        : cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  item.label,
                  style: (isSelected
                          ? typo.emphasized.labelLarge
                          : typo.baseline.labelLarge)
                      ?.copyWith(
                    color: isSelected
                        ? cs.onSecondaryContainer
                        : cs.onSurfaceVariant,
                  ),
                ),
                if (item.badge != null && item.badge!.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? cs.primary.withValues(alpha: 0.16)
                          : cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(M3ERadius.full),
                    ),
                    child: Text(
                      item.badge!,
                      style: typo.emphasized.labelSmall?.copyWith(
                        color: isSelected ? cs.primary : cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );

      if (i > 0) children.add(const SizedBox(width: 2));
      children.add(expand ? Expanded(child: segment) : segment);
    }

    return Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      children: children,
    );
  }
}

/// Material 3 Expressive Split Button (`2dp` inner gap between primary action
/// and trailing morphing dropdown chevron button).
class M3ESplitButton<T> extends StatefulWidget {
  const M3ESplitButton({
    super.key,
    required this.label,
    required this.onPrimaryPressed,
    required this.menuItems,
    required this.onMenuSelected,
    this.icon,
    this.size = M3EButtonSize.l,
    this.tonal = false,
  });

  final String label;
  final VoidCallback? onPrimaryPressed;
  final List<PopupMenuEntry<T>> menuItems;
  final ValueChanged<T> onMenuSelected;
  final IconData? icon;
  final M3EButtonSize size;
  final bool tonal;

  @override
  State<M3ESplitButton<T>> createState() => _M3ESplitButtonState<T>();
}

class _M3ESplitButtonState<T> extends State<M3ESplitButton<T>> {
  bool _menuOpen = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    final motion = M3EMotionTokens.of(context);
    final bg = widget.tonal ? cs.secondaryContainer : cs.primary;
    final fg = widget.tonal ? cs.onSecondaryContainer : cs.onPrimary;
    final outer = widget.size.height / 2;
    final inner = widget.size.innerRadius;
    final enabled = widget.onPrimaryPressed != null;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: GestureDetector(
            onTap: widget.onPrimaryPressed,
            child: AnimatedContainer(
              duration: motion.fastSpatial.fallbackDuration,
              curve: motion.fastSpatial.fallbackCurve,
              height: widget.size.height,
              padding: EdgeInsets.only(
                left: widget.size.hPad,
                right: widget.size.hPad - 4,
              ),
              decoration: BoxDecoration(
                color: enabled ? bg : cs.onSurface.withValues(alpha: 0.12),
                borderRadius: BorderRadius.horizontal(
                  left: Radius.circular(outer),
                  right: Radius.circular(inner),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.icon != null) ...[
                    Icon(
                      widget.icon,
                      size: widget.size.iconSize,
                      color: enabled ? fg : cs.onSurface.withValues(alpha: 0.38),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Text(
                    widget.label,
                    style: (widget.size.index >= M3EButtonSize.l.index
                            ? typo.emphasized.titleMedium
                            : typo.emphasized.labelLarge)
                        ?.copyWith(
                      color:
                          enabled ? fg : cs.onSurface.withValues(alpha: 0.38),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 2),
        PopupMenuButton<T>(
          tooltip: '更多选项',
          onOpened: () => setState(() => _menuOpen = true),
          onCanceled: () => setState(() => _menuOpen = false),
          onSelected: (v) {
            setState(() => _menuOpen = false);
            widget.onMenuSelected(v);
          },
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(M3ERadius.lgIncreased),
          ),
          itemBuilder: (_) => widget.menuItems,
          child: AnimatedContainer(
            duration: motion.fastSpatial.fallbackDuration,
            curve: motion.fastSpatial.fallbackCurve,
            height: widget.size.height,
            width: widget.size.height * 0.88,
            decoration: BoxDecoration(
              color: enabled ? bg : cs.onSurface.withValues(alpha: 0.12),
              borderRadius: _menuOpen
                  ? BorderRadius.circular(outer)
                  : BorderRadius.horizontal(
                      left: Radius.circular(inner),
                      right: Radius.circular(outer),
                    ),
            ),
            child: AnimatedRotation(
              turns: _menuOpen ? 0.5 : 0.0,
              duration: motion.fastSpatial.fallbackDuration,
              curve: motion.fastSpatial.fallbackCurve,
              child: Icon(
                Icons.keyboard_arrow_down_rounded,
                color: enabled ? fg : cs.onSurface.withValues(alpha: 0.38),
                size: widget.size.iconSize + 2,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Compact M3E Toggle Icon Button that morphs from circular pill to squircle
/// with vibrant active color when toggled on (e.g., AI Highlight Layer toggle).
class M3EIconToggleButton extends StatefulWidget {
  const M3EIconToggleButton({
    super.key,
    required this.icon,
    required this.selected,
    required this.onPressed,
    required this.tooltip,
    this.activeColor,
    this.activeIconColor,
    this.size = 40,
  });

  final IconData icon;
  final bool selected;
  final VoidCallback? onPressed;
  final String tooltip;
  final Color? activeColor;
  final Color? activeIconColor;
  final double size;

  @override
  State<M3EIconToggleButton> createState() => _M3EIconToggleButtonState();
}

class _M3EIconToggleButtonState extends State<M3EIconToggleButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final motion = M3EMotionTokens.of(context);
    final enabled = widget.onPressed != null;

    final bg = widget.selected
        ? (widget.activeColor ?? cs.primaryContainer)
        : (_hovered && enabled
            ? cs.onSurface.withValues(alpha: 0.08)
            : Colors.transparent);
    final fg = !enabled
        ? cs.onSurface.withValues(alpha: 0.34)
        : widget.selected
            ? (widget.activeIconColor ?? cs.onPrimaryContainer)
            : cs.onSurfaceVariant;

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: motion.fastSpatial.fallbackDuration,
            curve: motion.fastSpatial.fallbackCurve,
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(
                widget.selected ? M3ERadius.md : M3ERadius.full,
              ),
            ),
            child: Icon(widget.icon, size: 20, color: fg),
          ),
        ),
      ),
    );
  }
}

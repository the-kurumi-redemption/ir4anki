import 'package:flutter/material.dart';
import '../../theme/m3e_motion.dart';
import '../../theme/m3e_shapes.dart';

/// Material 3 Expressive Floating Toolbar (Standard or Vibrant pill container)
/// that floats cleanly over content for contextual study & reading actions.
class M3EFloatingToolbar extends StatelessWidget {
  const M3EFloatingToolbar({
    super.key,
    required this.children,
    this.vibrant = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
  });

  final List<Widget> children;
  final bool vibrant;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final motion = M3EMotionTokens.of(context);

    return AnimatedContainer(
      duration: motion.defaultSpatial.fallbackDuration,
      curve: motion.defaultSpatial.fallbackCurve,
      padding: padding,
      decoration: BoxDecoration(
        color: vibrant ? cs.primaryContainer : cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(M3ERadius.full),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: vibrant ? 0.2 : 0.45),
        ),
        boxShadow: [
          BoxShadow(
            color: cs.shadow.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}

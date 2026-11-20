import 'package:flutter/material.dart';
import 'm3e_motion.dart';
import 'm3e_shapes.dart';
import 'm3e_typography.dart';

/// Vibrant Material 3 Expressive theme seed presets.
enum M3EPalettePreset {
  expressiveViolet('极光紫', Color(0xFF6750A4)),
  botanicalTeal('青岚绿', Color(0xFF006A60)),
  warmTerracotta('暖陶橙', Color(0xFFA64B2A)),
  cobaltInk('深海蓝', Color(0xFF2855A8));

  const M3EPalettePreset(this.label, this.seedColor);
  final String label;
  final Color seedColor;
}

/// Domain-specific semantic colors for IR4Anki harmonized with M3 Expressive.
@immutable
class IRSemanticColors extends ThemeExtension<IRSemanticColors> {
  const IRSemanticColors({
    required this.readingAccent,
    required this.readingContainer,
    required this.onReadingContainer,
    required this.aiHighlightFill,
    required this.aiHighlightUnderline,
    required this.aiBadgeColor,
    required this.aiCalloutSurface,
    required this.aiCalloutBorder,
    required this.linePickFill,
    required this.linePickBorder,
    required this.clozeChipBg,
    required this.clozeChipFg,
    required this.successAccent,
    required this.successContainer,
    required this.warningAccent,
    required this.warningContainer,
  });

  final Color readingAccent;
  final Color readingContainer;
  final Color onReadingContainer;
  final Color aiHighlightFill;
  final Color aiHighlightUnderline;
  final Color aiBadgeColor;
  final Color aiCalloutSurface;
  final Color aiCalloutBorder;
  final Color linePickFill;
  final Color linePickBorder;
  final Color clozeChipBg;
  final Color clozeChipFg;
  final Color successAccent;
  final Color successContainer;
  final Color warningAccent;
  final Color warningContainer;

  static IRSemanticColors light(ColorScheme scheme) => IRSemanticColors(
        readingAccent: const Color(0xFF006A60),
        readingContainer: const Color(0xFFC5F4EC),
        onReadingContainer: const Color(0xFF00201C),
        aiHighlightFill: const Color(0x57FACC15),
        aiHighlightUnderline: const Color(0x8CD97706),
        aiBadgeColor: const Color(0xFFB45309),
        aiCalloutSurface: const Color(0xFFFFF8E6),
        aiCalloutBorder: const Color(0xFFD97706),
        linePickFill: scheme.primaryContainer.withValues(alpha: 0.55),
        linePickBorder: scheme.primary,
        clozeChipBg: scheme.primaryContainer,
        clozeChipFg: scheme.onPrimaryContainer,
        successAccent: const Color(0xFF1B7A4B),
        successContainer: const Color(0xFFD6F5E3),
        warningAccent: const Color(0xFFB45309),
        warningContainer: const Color(0xFFFEF3C7),
      );

  static IRSemanticColors dark(ColorScheme scheme) => IRSemanticColors(
        readingAccent: const Color(0xFF53DBC9),
        readingContainer: const Color(0xFF005048),
        onReadingContainer: const Color(0xFFB1F3E8),
        aiHighlightFill: const Color(0x3DFACC15),
        aiHighlightUnderline: const Color(0xA6FBBF24),
        aiBadgeColor: const Color(0xFFFBBF24),
        aiCalloutSurface: const Color(0xFF2B2416),
        aiCalloutBorder: const Color(0xFFF59E0B),
        linePickFill: scheme.primaryContainer.withValues(alpha: 0.45),
        linePickBorder: scheme.primary,
        clozeChipBg: scheme.primaryContainer,
        clozeChipFg: scheme.onPrimaryContainer,
        successAccent: const Color(0xFF6EE7B7),
        successContainer: const Color(0xFF133B2A),
        warningAccent: const Color(0xFFFBBF24),
        warningContainer: const Color(0xFF3A2B12),
      );

  static IRSemanticColors of(BuildContext context) {
    final ext = Theme.of(context).extension<IRSemanticColors>();
    if (ext != null) return ext;
    final cs = Theme.of(context).colorScheme;
    return cs.brightness == Brightness.dark ? dark(cs) : light(cs);
  }

  @override
  IRSemanticColors copyWith({
    Color? readingAccent,
    Color? readingContainer,
    Color? onReadingContainer,
    Color? aiHighlightFill,
    Color? aiHighlightUnderline,
    Color? aiBadgeColor,
    Color? aiCalloutSurface,
    Color? aiCalloutBorder,
    Color? linePickFill,
    Color? linePickBorder,
    Color? clozeChipBg,
    Color? clozeChipFg,
    Color? successAccent,
    Color? successContainer,
    Color? warningAccent,
    Color? warningContainer,
  }) {
    return IRSemanticColors(
      readingAccent: readingAccent ?? this.readingAccent,
      readingContainer: readingContainer ?? this.readingContainer,
      onReadingContainer: onReadingContainer ?? this.onReadingContainer,
      aiHighlightFill: aiHighlightFill ?? this.aiHighlightFill,
      aiHighlightUnderline: aiHighlightUnderline ?? this.aiHighlightUnderline,
      aiBadgeColor: aiBadgeColor ?? this.aiBadgeColor,
      aiCalloutSurface: aiCalloutSurface ?? this.aiCalloutSurface,
      aiCalloutBorder: aiCalloutBorder ?? this.aiCalloutBorder,
      linePickFill: linePickFill ?? this.linePickFill,
      linePickBorder: linePickBorder ?? this.linePickBorder,
      clozeChipBg: clozeChipBg ?? this.clozeChipBg,
      clozeChipFg: clozeChipFg ?? this.clozeChipFg,
      successAccent: successAccent ?? this.successAccent,
      successContainer: successContainer ?? this.successContainer,
      warningAccent: warningAccent ?? this.warningAccent,
      warningContainer: warningContainer ?? this.warningContainer,
    );
  }

  @override
  IRSemanticColors lerp(ThemeExtension<IRSemanticColors>? other, double t) {
    if (other is! IRSemanticColors) return this;
    return IRSemanticColors(
      readingAccent: Color.lerp(readingAccent, other.readingAccent, t)!,
      readingContainer: Color.lerp(readingContainer, other.readingContainer, t)!,
      onReadingContainer:
          Color.lerp(onReadingContainer, other.onReadingContainer, t)!,
      aiHighlightFill: Color.lerp(aiHighlightFill, other.aiHighlightFill, t)!,
      aiHighlightUnderline:
          Color.lerp(aiHighlightUnderline, other.aiHighlightUnderline, t)!,
      aiBadgeColor: Color.lerp(aiBadgeColor, other.aiBadgeColor, t)!,
      aiCalloutSurface:
          Color.lerp(aiCalloutSurface, other.aiCalloutSurface, t)!,
      aiCalloutBorder: Color.lerp(aiCalloutBorder, other.aiCalloutBorder, t)!,
      linePickFill: Color.lerp(linePickFill, other.linePickFill, t)!,
      linePickBorder: Color.lerp(linePickBorder, other.linePickBorder, t)!,
      clozeChipBg: Color.lerp(clozeChipBg, other.clozeChipBg, t)!,
      clozeChipFg: Color.lerp(clozeChipFg, other.clozeChipFg, t)!,
      successAccent: Color.lerp(successAccent, other.successAccent, t)!,
      successContainer:
          Color.lerp(successContainer, other.successContainer, t)!,
      warningAccent: Color.lerp(warningAccent, other.warningAccent, t)!,
      warningContainer:
          Color.lerp(warningContainer, other.warningContainer, t)!,
    );
  }
}

/// Constructs a complete Material 3 Expressive [ThemeData] for IR4Anki Desktop.
ThemeData buildM3ETheme({
  required Brightness brightness,
  required M3EPalettePreset palette,
  required M3EMotionScheme motionScheme,
}) {
  // Material 3 Expressive favors vibrant dynamic palettes with clear tonal containment.
  final colorScheme = ColorScheme.fromSeed(
    seedColor: palette.seedColor,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.vibrant,
  );

  final typography =
      M3ETypography.build(colorScheme.onSurface, colorScheme.onSurfaceVariant);
  final semantic = brightness == Brightness.dark
      ? IRSemanticColors.dark(colorScheme)
      : IRSemanticColors.light(colorScheme);
  final motion = M3EMotionTokens.forScheme(motionScheme);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colorScheme,
    textTheme: typography.baseline,
    scaffoldBackgroundColor: brightness == Brightness.dark
        ? colorScheme.surfaceDim
        : colorScheme.surfaceContainer,
    canvasColor: colorScheme.surface,
    dividerTheme: DividerThemeData(
      color: colorScheme.outlineVariant.withValues(alpha: 0.7),
      thickness: 1,
      space: 1,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: brightness == Brightness.dark
          ? colorScheme.surfaceContainerLow
          : colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(M3ERadius.xl),
      ),
      margin: EdgeInsets.zero,
    ),
    dialogTheme: DialogThemeData(
      elevation: 0,
      backgroundColor: colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(M3ERadius.xl),
      ),
      titleTextStyle: typography.emphasized.headlineSmall,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(M3ERadius.lg),
        borderSide: BorderSide(color: colorScheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(M3ERadius.lg),
        borderSide: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.8)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(M3ERadius.lg),
        borderSide: BorderSide(color: colorScheme.primary, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 350),
      decoration: BoxDecoration(
        color: colorScheme.inverseSurface,
        borderRadius: BorderRadius.circular(M3ERadius.md),
      ),
      textStyle: typography.baseline.labelMedium?.copyWith(
        color: colorScheme.onInverseSurface,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: colorScheme.inverseSurface,
      contentTextStyle: typography.baseline.bodyMedium?.copyWith(
        color: colorScheme.onInverseSurface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(M3ERadius.lg),
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      radius: const Radius.circular(M3ERadius.full),
      thickness: WidgetStateProperty.all(6),
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.dragged)) {
          return colorScheme.onSurfaceVariant.withValues(alpha: 0.48);
        }
        return colorScheme.onSurfaceVariant.withValues(alpha: 0.22);
      }),
    ),
    extensions: [
      typography,
      semantic,
      motion,
    ],
  );
}

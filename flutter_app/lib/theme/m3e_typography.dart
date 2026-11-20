import 'package:flutter/material.dart';

/// Material Design 3 Expressive 30-Style Type System (15 Baseline + 15 Emphasized).
///
/// Pairs every M3 role with a higher-weight, optically tuned Emphasized style for
/// editorial hero moments, active selections, stats, and primary CTAs, with clean
/// CJK + Latin fallbacks for Linux desktop.
@immutable
class M3ETypography extends ThemeExtension<M3ETypography> {
  const M3ETypography({
    required this.baseline,
    required this.emphasized,
    required this.mono,
  });

  final TextTheme baseline;
  final TextTheme emphasized;
  final TextStyle mono;

  static const List<String> _sansFallback = [
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'Source Han Sans SC',
    'WenQuanYi Micro Hei',
    'Roboto',
    'DejaVu Sans',
    'sans-serif',
  ];

  static const List<String> _monoFallback = [
    'JetBrains Mono',
    'Fira Code',
    'Noto Sans Mono CJK SC',
    'DejaVu Sans Mono',
    'monospace',
  ];

  static M3ETypography build(Color onSurface, Color onSurfaceVariant) {
    TextStyle base(
      double size,
      double height,
      FontWeight weight,
      double letterSpacing, {
      Color? color,
      bool tabular = false,
    }) {
      return TextStyle(
        fontFamily: 'Roboto',
        fontFamilyFallback: _sansFallback,
        fontSize: size,
        height: height / size,
        fontWeight: weight,
        letterSpacing: letterSpacing,
        color: color ?? onSurface,
        fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
      );
    }

    final baseline = TextTheme(
      displayLarge: base(57, 64, FontWeight.w400, -0.25),
      displayMedium: base(45, 52, FontWeight.w400, 0),
      displaySmall: base(36, 44, FontWeight.w400, 0),
      headlineLarge: base(32, 40, FontWeight.w400, 0),
      headlineMedium: base(28, 36, FontWeight.w400, 0),
      headlineSmall: base(24, 32, FontWeight.w400, 0),
      titleLarge: base(22, 28, FontWeight.w500, 0),
      titleMedium: base(16, 24, FontWeight.w500, 0.15),
      titleSmall: base(14, 20, FontWeight.w500, 0.1),
      bodyLarge: base(16, 26, FontWeight.w400, 0.15),
      bodyMedium: base(14, 22, FontWeight.w400, 0.2),
      bodySmall: base(12, 18, FontWeight.w400, 0.3, color: onSurfaceVariant),
      labelLarge: base(14, 20, FontWeight.w500, 0.1),
      labelMedium: base(12, 16, FontWeight.w500, 0.4),
      labelSmall: base(11, 16, FontWeight.w500, 0.4, color: onSurfaceVariant),
    );

    // M3E Emphasized counterparts: bolder weights + tighter expressive display tracking.
    final emphasized = TextTheme(
      displayLarge: base(57, 64, FontWeight.w700, -0.5, tabular: true),
      displayMedium: base(45, 52, FontWeight.w700, -0.4, tabular: true),
      displaySmall: base(36, 44, FontWeight.w700, -0.3, tabular: true),
      headlineLarge: base(32, 40, FontWeight.w700, -0.25, tabular: true),
      headlineMedium: base(28, 36, FontWeight.w700, -0.2, tabular: true),
      headlineSmall: base(24, 32, FontWeight.w700, -0.15, tabular: true),
      titleLarge: base(22, 28, FontWeight.w700, -0.1),
      titleMedium: base(16, 24, FontWeight.w700, 0.1),
      titleSmall: base(14, 20, FontWeight.w700, 0.1),
      bodyLarge: base(16, 26, FontWeight.w600, 0.1),
      bodyMedium: base(14, 22, FontWeight.w600, 0.15),
      bodySmall: base(12, 18, FontWeight.w600, 0.25, color: onSurfaceVariant),
      labelLarge: base(14, 20, FontWeight.w700, 0.1, tabular: true),
      labelMedium: base(12, 16, FontWeight.w700, 0.35, tabular: true),
      labelSmall: base(11, 16, FontWeight.w700, 0.35, tabular: true),
    );

    final mono = TextStyle(
      fontFamily: 'JetBrains Mono',
      fontFamilyFallback: _monoFallback,
      fontSize: 13.5,
      height: 1.55,
      color: onSurface,
    );

    return M3ETypography(
      baseline: baseline,
      emphasized: emphasized,
      mono: mono,
    );
  }

  static M3ETypography of(BuildContext context) {
    return Theme.of(context).extension<M3ETypography>() ??
        build(
          Theme.of(context).colorScheme.onSurface,
          Theme.of(context).colorScheme.onSurfaceVariant,
        );
  }

  @override
  M3ETypography copyWith({
    TextTheme? baseline,
    TextTheme? emphasized,
    TextStyle? mono,
  }) {
    return M3ETypography(
      baseline: baseline ?? this.baseline,
      emphasized: emphasized ?? this.emphasized,
      mono: mono ?? this.mono,
    );
  }

  @override
  M3ETypography lerp(ThemeExtension<M3ETypography>? other, double t) {
    if (other is! M3ETypography) return this;
    return M3ETypography(
      baseline: TextTheme.lerp(baseline, other.baseline, t),
      emphasized: TextTheme.lerp(emphasized, other.emphasized, t),
      mono: TextStyle.lerp(mono, other.mono, t) ?? mono,
    );
  }
}

import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../theme/m3e_shapes.dart';
import '../../theme/m3e_typography.dart';

/// Material 3 Expressive Shape-Morphing Loading Indicator.
///
/// Continuously morphs through 7 canonical expressive polygons while rotating
/// smoothly, matching Google's May 2025 / Compose M3 1.5 LoadingIndicator spec.
class M3ELoadingIndicator extends StatefulWidget {
  const M3ELoadingIndicator({
    super.key,
    this.size = 56,
    this.contained = true,
    this.color,
    this.containerColor,
  });

  final double size;
  final bool contained;
  final Color? color;
  final Color? containerColor;

  @override
  State<M3ELoadingIndicator> createState() => _M3ELoadingIndicatorState();
}

class _M3ELoadingIndicatorState extends State<M3ELoadingIndicator>
    with SingleTickerProviderStateMixin {
  static const List<M3EShapeKind> _sequence = [
    M3EShapeKind.softBurst,
    M3EShapeKind.cookie8,
    M3EShapeKind.clover4,
    M3EShapeKind.squircle,
    M3EShapeKind.flower,
    M3EShapeKind.arch,
    M3EShapeKind.circle,
  ];

  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final activeColor = widget.color ?? cs.primary;
    final bgColor = widget.containerColor ?? cs.primaryContainer;

    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) {
            final scaled = _ctrl.value * _sequence.length;
            final idx = scaled.floor() % _sequence.length;
            final nextIdx = (idx + 1) % _sequence.length;
            final localT = Curves.easeInOutCubicEmphasized
                .transform(scaled - scaled.floor());
            final rotation = _ctrl.value * math.pi * 2;

            return CustomPaint(
              isComplex: true,
              willChange: true,
              painter: _M3ELoadingPainter(
                from: _sequence[idx],
                to: _sequence[nextIdx],
                t: localT,
                rotation: rotation,
                activeColor: activeColor,
                contained: widget.contained,
                containerColor: bgColor,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _M3ELoadingPainter extends CustomPainter {
  const _M3ELoadingPainter({
    required this.from,
    required this.to,
    required this.t,
    required this.rotation,
    required this.activeColor,
    required this.contained,
    required this.containerColor,
  });

  final M3EShapeKind from;
  final M3EShapeKind to;
  final double t;
  final double rotation;
  final Color activeColor;
  final bool contained;
  final Color containerColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    if (contained) {
      canvas.drawCircle(
        center,
        size.shortestSide / 2,
        Paint()
          ..color = containerColor
          ..isAntiAlias = true,
      );
    }
    final inset = contained ? size.shortestSide * 0.18 : 2.0;
    final shapeRect = Rect.fromCenter(
      center: center,
      width: size.width - inset * 2,
      height: size.height - inset * 2,
    );
    final path = M3EMorphShapePath.build(
      rect: shapeRect,
      from: from,
      to: to,
      t: t,
      rotationRadians: rotation,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = activeColor
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_M3ELoadingPainter old) =>
      old.from != from ||
      old.to != to ||
      old.t != t ||
      old.rotation != rotation ||
      old.activeColor != activeColor;
}

/// Material 3 Expressive **Wavy Linear Progress Indicator** with animated
/// sinusoidal active track and accessible trailing stop indicator dot.
class M3EWavyProgressIndicator extends StatefulWidget {
  const M3EWavyProgressIndicator({
    super.key,
    required this.value,
    this.height = 10,
    this.strokeWidth = 3.5,
    this.amplitude = 2.6,
    this.wavelength = 24,
    this.color,
    this.trackColor,
    this.animateWave = true,
  });

  final double value;
  final double height;
  final double strokeWidth;
  final double amplitude;
  final double wavelength;
  final Color? color;
  final Color? trackColor;
  final bool animateWave;

  @override
  State<M3EWavyProgressIndicator> createState() =>
      _M3EWavyProgressIndicatorState();
}

class _M3EWavyProgressIndicatorState extends State<M3EWavyProgressIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _phaseCtrl;

  @override
  void initState() {
    super.initState();
    _phaseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    if (widget.animateWave && widget.value > 0 && widget.value < 1) {
      _phaseCtrl.repeat();
    }
  }

  @override
  void didUpdateWidget(M3EWavyProgressIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    final shouldRun = widget.animateWave && widget.value > 0 && widget.value < 1;
    if (shouldRun && !_phaseCtrl.isAnimating) {
      _phaseCtrl.repeat();
    } else if (!shouldRun && _phaseCtrl.isAnimating) {
      _phaseCtrl.stop();
    }
  }

  @override
  void dispose() {
    _phaseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final activeColor = widget.color ?? cs.primary;
    final bgColor = widget.trackColor ?? cs.secondaryContainer;

    return RepaintBoundary(
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: AnimatedBuilder(
          animation: _phaseCtrl,
          builder: (context, _) {
            return CustomPaint(
              willChange: widget.animateWave,
              painter: _WavyProgressPainter(
                value: widget.value.clamp(0.0, 1.0),
                phase: _phaseCtrl.value * math.pi * 2,
                strokeWidth: widget.strokeWidth,
                amplitude: widget.amplitude,
                wavelength: widget.wavelength,
                activeColor: activeColor,
                trackColor: bgColor,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _WavyProgressPainter extends CustomPainter {
  const _WavyProgressPainter({
    required this.value,
    required this.phase,
    required this.strokeWidth,
    required this.amplitude,
    required this.wavelength,
    required this.activeColor,
    required this.trackColor,
  });

  final double value;
  final double phase;
  final double strokeWidth;
  final double amplitude;
  final double wavelength;
  final Color activeColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final activeEnd = size.width * value;
    final gap = 6.0;

    // Inactive straight track (with gap after active wave)
    final trackStart = value <= 0 ? strokeWidth / 2 : (activeEnd + gap);
    if (trackStart < size.width - strokeWidth / 2) {
      canvas.drawLine(
        Offset(trackStart, cy),
        Offset(size.width - strokeWidth / 2, cy),
        Paint()
          ..color = trackColor
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true,
      );
    }

    // Stop indicator dot at trailing end (M3E accessibility spec)
    if (value < 0.99) {
      canvas.drawCircle(
        Offset(size.width - strokeWidth / 2, cy),
        strokeWidth * 0.55,
        Paint()
          ..color = activeColor
          ..isAntiAlias = true,
      );
    }

    // Active wavy track
    if (activeEnd > 1) {
      final amp = value >= 0.999 ? 0.0 : amplitude;
      final path = Path();
      const step = 3.0;
      for (double x = strokeWidth / 2; x <= activeEnd; x += step) {
        final y = cy + math.sin((x / wavelength) * math.pi * 2 - phase) * amp;
        if (x == strokeWidth / 2) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      final endY =
          cy + math.sin((activeEnd / wavelength) * math.pi * 2 - phase) * amp;
      path.lineTo(activeEnd, endY);

      canvas.drawPath(
        path,
        Paint()
          ..color = activeColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true,
      );
    }
  }

  @override
  bool shouldRepaint(_WavyProgressPainter old) =>
      old.value != value ||
      old.phase != phase ||
      old.activeColor != activeColor ||
      old.trackColor != trackColor;
}

/// Compact circular progress ring used in the Expressive Navigation Rail for
/// dual Reading (teal) and Review (primary) round tracking.
class M3EProgressRing extends StatelessWidget {
  const M3EProgressRing({
    super.key,
    required this.done,
    required this.total,
    required this.label,
    required this.color,
    this.expanded = false,
  });

  final int done;
  final int total;
  final String label;
  final Color color;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    final ratio = total > 0 ? (done / total).clamp(0.0, 1.0) : 0.0;

    final ring = RepaintBoundary(
      child: SizedBox(
        width: 44,
        height: 44,
        child: Stack(
          alignment: Alignment.center,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween<double>(end: ratio),
              duration: const Duration(milliseconds: 420),
              curve: Curves.easeOutCubic,
              builder: (_, val, __) => CustomPaint(
                size: const Size(44, 44),
                painter: _RingPainter(
                  progress: val,
                  color: color,
                  trackColor: cs.surfaceContainerHighest,
                ),
              ),
            ),
            Text(
              total > 0 ? '$done' : '—',
              style: typo.emphasized.labelMedium?.copyWith(
                color: total > 0 ? color : cs.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );

    if (!expanded) {
      return Tooltip(
        message: '$label $done / $total',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ring,
            const SizedBox(height: 3),
            Text(
              label,
              style: typo.baseline.labelSmall?.copyWith(fontSize: 10.5),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          ring,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: typo.emphasized.labelMedium),
                const SizedBox(height: 2),
                Text(
                  total > 0 ? '$done / $total' : '暂无进行中',
                  style: typo.baseline.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.progress,
    required this.color,
    required this.trackColor,
  });

  final double progress;
  final Color color;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 4.0;
    final rect = Rect.fromLTWH(
      stroke / 2,
      stroke / 2,
      size.width - stroke,
      size.height - stroke,
    );
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..isAntiAlias = true,
    );
    if (progress > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 2 * progress,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.color != color;
}

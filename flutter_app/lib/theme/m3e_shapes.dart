import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Material Design 3 Expressive Shape Tokens & Organic Morphing Polygons.
///
/// Incorporates M3E expanded corner radii (`lgIncreased = 20`, `xlIncreased = 32`,
/// `xxl = 48`, `full = 9999`) plus normalized polar-sampled canonical M3E shapes
/// (`SoftBurst`, `Cookie8`, `Clover4`, `Arch`, `Squircle`, `Pill`, `Flower`)
/// that morph seamlessly between one another via vertex-level interpolation.
abstract final class M3ERadius {
  static const double none = 0;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double lgIncreased = 20;
  static const double xl = 28;
  static const double xlIncreased = 32;
  static const double xxl = 48;
  static const double full = 9999;

  static BorderRadius circular(double r) => BorderRadius.circular(r);
}

/// Expressive canonical shape kinds inspired by Material 3 Expressive's 35-shape library.
enum M3EShapeKind {
  circle,
  squircle,
  clover4,
  cookie8,
  softBurst,
  flower,
  arch,
}

/// Evaluates a smooth closed [Path] inside [rect] for any [M3EShapeKind] or
/// smoothly morphed pair `(from, to, t)` with optional rotation.
class M3EMorphShapePath {
  static const int _samples = 96;

  static double _radiusForAngle(M3EShapeKind kind, double theta) {
    switch (kind) {
      case M3EShapeKind.circle:
        return 0.90;
      case M3EShapeKind.squircle:
        // Superellipse n = 4.2
        final c = math.cos(theta).abs();
        final s = math.sin(theta).abs();
        final denom = math.pow(math.pow(c, 4.2) + math.pow(s, 4.2), 1 / 4.2);
        return (0.92 / (denom == 0 ? 1 : denom)).clamp(0.65, 1.0);
      case M3EShapeKind.clover4:
        return 0.80 + 0.16 * math.cos(4 * theta);
      case M3EShapeKind.cookie8:
        return 0.86 + 0.10 * math.cos(8 * theta);
      case M3EShapeKind.softBurst:
        return 0.84 + 0.13 * math.cos(10 * theta);
      case M3EShapeKind.flower:
        return 0.82 + 0.14 * math.cos(6 * theta);
      case M3EShapeKind.arch:
        // Soft rounded arch: fuller on top half, gently flattened base
        final y = math.sin(theta);
        final baseFlatten = y > 0.35 ? 1.0 - 0.18 * (y - 0.35) : 1.0;
        final c = math.cos(theta).abs();
        final s = math.sin(theta).abs();
        final sq = 0.92 / math.pow(math.pow(c, 3.2) + math.pow(s, 3.2), 1 / 3.2);
        return (sq * baseFlatten).clamp(0.65, 0.98);
    }
  }

  static Path build({
    required Rect rect,
    required M3EShapeKind from,
    M3EShapeKind? to,
    double t = 0.0,
    double rotationRadians = 0.0,
  }) {
    final target = to ?? from;
    final clampedT = t.clamp(0.0, 1.0);
    final cx = rect.center.dx;
    final cy = rect.center.dy;
    final rx = rect.width / 2;
    final ry = rect.height / 2;

    final path = Path();
    for (int i = 0; i < _samples; i++) {
      final theta = (i / _samples) * math.pi * 2;
      final r1 = _radiusForAngle(from, theta);
      final r2 = _radiusForAngle(target, theta);
      final r = r1 + (r2 - r1) * clampedT;
      final angle = theta + rotationRadians;
      final x = cx + math.cos(angle) * r * rx;
      final y = cy + math.sin(angle) * r * ry;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    return path;
  }
}

/// Widget that renders a decorative Material 3 Expressive organic shape badge
/// (used for hero medallions, empty states, and active indicators).
class M3EShapeContainer extends StatelessWidget {
  const M3EShapeContainer({
    super.key,
    required this.kind,
    required this.color,
    this.size = 64,
    this.rotation = 0,
    this.child,
  });

  final M3EShapeKind kind;
  final Color color;
  final double size;
  final double rotation;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _M3EShapePainter(
          kind: kind,
          color: color,
          rotation: rotation,
        ),
        child: child == null ? null : Center(child: child),
      ),
    );
  }
}

class _M3EShapePainter extends CustomPainter {
  const _M3EShapePainter({
    required this.kind,
    required this.color,
    required this.rotation,
  });

  final M3EShapeKind kind;
  final Color color;
  final double rotation;

  @override
  void paint(Canvas canvas, Size size) {
    final path = M3EMorphShapePath.build(
      rect: Offset.zero & size,
      from: kind,
      rotationRadians: rotation,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_M3EShapePainter oldDelegate) =>
      oldDelegate.kind != kind ||
      oldDelegate.color != color ||
      oldDelegate.rotation != rotation;
}

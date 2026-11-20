import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// Material Design 3 Expressive Motion-Physics System.
///
/// Exact composite spring tokens from `m3.material.io` (Motion → Specs → Tokens):
/// - **Spatial springs**: govern position, size, rotation, and shape/corner morphing
///   (Expressive uses playful overshoot; Standard is calmer and more damped).
/// - **Effects springs**: govern color, opacity, and state layers (critically damped
///   `dampingRatio = 1.0`, zero overshoot).
enum M3EMotionScheme { expressive, standard }

@immutable
class M3ESpringToken {
  const M3ESpringToken({
    required this.dampingRatio,
    required this.stiffness,
    required this.fallbackDuration,
    required this.fallbackCurve,
  });

  final double dampingRatio;
  final double stiffness;
  final Duration fallbackDuration;
  final Curve fallbackCurve;

  /// Converts damping ratio + stiffness into Flutter's [SpringDescription] (mass = 1).
  SpringDescription get description => SpringDescription.withDampingRatio(
        mass: 1.0,
        stiffness: stiffness,
        ratio: dampingRatio,
      );

  /// Creates a [SpringSimulation] ready for [AnimationController.animateWith].
  SpringSimulation simulation({
    double start = 0.0,
    double end = 1.0,
    double velocity = 0.0,
  }) {
    return SpringSimulation(description, start, end, velocity);
  }
}

/// Official Material 3 Expressive & Standard motion token set.
@immutable
class M3EMotionTokens extends ThemeExtension<M3EMotionTokens> {
  const M3EMotionTokens({
    required this.scheme,
    required this.fastSpatial,
    required this.defaultSpatial,
    required this.slowSpatial,
    required this.fastEffects,
    required this.defaultEffects,
    required this.slowEffects,
  });

  final M3EMotionScheme scheme;
  final M3ESpringToken fastSpatial;
  final M3ESpringToken defaultSpatial;
  final M3ESpringToken slowSpatial;
  final M3ESpringToken fastEffects;
  final M3ESpringToken defaultEffects;
  final M3ESpringToken slowEffects;

  /// Opinionated Material 3 Expressive physics scheme (May 2025 / Compose M3 1.5 stable).
  static const expressive = M3EMotionTokens(
    scheme: M3EMotionScheme.expressive,
    fastSpatial: M3ESpringToken(
      dampingRatio: 0.6,
      stiffness: 800,
      fallbackDuration: Duration(milliseconds: 350),
      fallbackCurve: Cubic(0.42, 1.67, 0.21, 0.90),
    ),
    defaultSpatial: M3ESpringToken(
      dampingRatio: 0.8,
      stiffness: 380,
      fallbackDuration: Duration(milliseconds: 500),
      fallbackCurve: Cubic(0.38, 1.21, 0.22, 1.00),
    ),
    slowSpatial: M3ESpringToken(
      dampingRatio: 0.8,
      stiffness: 200,
      fallbackDuration: Duration(milliseconds: 650),
      fallbackCurve: Cubic(0.39, 1.29, 0.35, 0.98),
    ),
    fastEffects: M3ESpringToken(
      dampingRatio: 1.0,
      stiffness: 3800,
      fallbackDuration: Duration(milliseconds: 150),
      fallbackCurve: Cubic(0.31, 0.94, 0.34, 1.00),
    ),
    defaultEffects: M3ESpringToken(
      dampingRatio: 1.0,
      stiffness: 1600,
      fallbackDuration: Duration(milliseconds: 200),
      fallbackCurve: Cubic(0.34, 0.80, 0.34, 1.00),
    ),
    slowEffects: M3ESpringToken(
      dampingRatio: 1.0,
      stiffness: 800,
      fallbackDuration: Duration(milliseconds: 300),
      fallbackCurve: Cubic(0.34, 0.88, 0.34, 1.00),
    ),
  );

  /// Functional Material 3 Standard physics scheme (minimal bounce).
  static const standard = M3EMotionTokens(
    scheme: M3EMotionScheme.standard,
    fastSpatial: M3ESpringToken(
      dampingRatio: 0.9,
      stiffness: 1400,
      fallbackDuration: Duration(milliseconds: 350),
      fallbackCurve: Cubic(0.27, 1.06, 0.18, 1.00),
    ),
    defaultSpatial: M3ESpringToken(
      dampingRatio: 0.9,
      stiffness: 700,
      fallbackDuration: Duration(milliseconds: 500),
      fallbackCurve: Cubic(0.27, 1.06, 0.18, 1.00),
    ),
    slowSpatial: M3ESpringToken(
      dampingRatio: 0.9,
      stiffness: 300,
      fallbackDuration: Duration(milliseconds: 750),
      fallbackCurve: Cubic(0.27, 1.06, 0.18, 1.00),
    ),
    fastEffects: M3ESpringToken(
      dampingRatio: 1.0,
      stiffness: 3800,
      fallbackDuration: Duration(milliseconds: 150),
      fallbackCurve: Cubic(0.31, 0.94, 0.34, 1.00),
    ),
    defaultEffects: M3ESpringToken(
      dampingRatio: 1.0,
      stiffness: 1600,
      fallbackDuration: Duration(milliseconds: 200),
      fallbackCurve: Cubic(0.34, 0.80, 0.34, 1.00),
    ),
    slowEffects: M3ESpringToken(
      dampingRatio: 1.0,
      stiffness: 800,
      fallbackDuration: Duration(milliseconds: 300),
      fallbackCurve: Cubic(0.34, 0.88, 0.34, 1.00),
    ),
  );

  static M3EMotionTokens of(BuildContext context) {
    return Theme.of(context).extension<M3EMotionTokens>() ?? expressive;
  }

  static M3EMotionTokens forScheme(M3EMotionScheme scheme) =>
      scheme == M3EMotionScheme.expressive ? expressive : standard;

  @override
  M3EMotionTokens copyWith({M3EMotionScheme? scheme}) {
    if (scheme == null) return this;
    return forScheme(scheme);
  }

  @override
  M3EMotionTokens lerp(ThemeExtension<M3EMotionTokens>? other, double t) {
    if (other is! M3EMotionTokens) return this;
    return t < 0.5 ? this : other;
  }
}

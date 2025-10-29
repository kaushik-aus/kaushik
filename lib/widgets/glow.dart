import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Wrap any child with a soft outer glow.
/// Tip: pick a color near your surface or accent for best results.
class GlowContainer extends StatelessWidget {
  final Widget child;
  final Color color;
  final double blur;
  final double spread;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final Color? background; // optional backdrop color for better glow contrast

  const GlowContainer({
    Key? key,
    required this.child,
    required this.color,
    this.blur = 28,
    this.spread = 0,
    this.borderRadius,
    this.padding,
    this.margin,
    this.background,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? BorderRadius.circular(16);
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: radius,
        // The glow is just a big, soft boxShadow
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.45),
            blurRadius: blur,
            spreadRadius: spread,
            offset: const Offset(0, 0),
          ),
          // subtle inner aura
          BoxShadow(
            color: color.withOpacity(0.20),
            blurRadius: blur * 0.7,
            spreadRadius: spread * 0.5,
            offset: const Offset(0, 0),
          ),
        ],
      ),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(color: background, borderRadius: radius),
        child: child,
      ),
    );
  }
}

/// Gentle animated sheen that sweeps diagonally across the page.
/// Place this above your background but below content.
class LightSweepOverlay extends StatefulWidget {
  final Duration period;
  final double angleDeg;
  final double widthFraction; // width of the bright bar

  const LightSweepOverlay({
    Key? key,
    this.period = const Duration(seconds: 7),
    this.angleDeg = 18,
    this.widthFraction = 0.22,
  }) : super(key: key);

  @override
  State<LightSweepOverlay> createState() => _LightSweepOverlayState();
}

class _LightSweepOverlayState extends State<LightSweepOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: widget.period)..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final angle = widget.angleDeg * math.pi / 180;
    return IgnorePointer(
      ignoring: true,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          return CustomPaint(
            painter: _SweepPainter(
              t: _c.value,
              angle: angle,
              widthFraction: widget.widthFraction,
            ),
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }
}

class _SweepPainter extends CustomPainter {
  final double t;
  final double angle;
  final double widthFraction;

  _SweepPainter({
    required this.t,
    required this.angle,
    required this.widthFraction,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Create a moving, diagonal rect that carries the sheen
    final w = size.width;
    final h = size.height;
    final sweepW = w * widthFraction;

    // Center line moves from left to right over time
    final cx = lerpDouble(-sweepW, w + sweepW, t)!;

    // Build a tall rect then rotate it
    final rect = Rect.fromLTWH(cx - sweepW / 2, -h, sweepW, h * 3);

    canvas.save();
    // rotate around center
    canvas.translate(w / 2, h / 2);
    canvas.rotate(angle);
    canvas.translate(-w / 2, -h / 2);

    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          Colors.transparent,
          Colors.white.withOpacity(0.18),
          Colors.white.withOpacity(0.45),
          Colors.white.withOpacity(0.18),
          Colors.transparent,
        ],
        stops: const [0.00, 0.35, 0.50, 0.65, 1.00],
      ).createShader(rect)
      ..blendMode = BlendMode.plus; // add light
    canvas.drawRect(rect, paint);

    canvas.restore();
  }

  double? lerpDouble(double a, double b, double t) => a + (b - a) * t;

  @override
  bool shouldRepaint(_SweepPainter oldDelegate) =>
      oldDelegate.t != t ||
      oldDelegate.angle != angle ||
      oldDelegate.widthFraction != widthFraction;
}

/// Tiny, soft sparkles that fade in/out slowly.
/// Place above background, very low opacity so it feels ambient.
class SparkleOverlay extends StatefulWidget {
  final int count;
  final double minSize;
  final double maxSize;
  final Duration period;
  final Color color;

  const SparkleOverlay({
    Key? key,
    this.count = 24,
    this.minSize = 8,
    this.maxSize = 22,
    this.period = const Duration(seconds: 6),
    this.color = const Color(0xFFFFFFFF),
  }) : super(key: key);

  @override
  State<SparkleOverlay> createState() => _SparkleOverlayState();
}

class _SparkleOverlayState extends State<SparkleOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final List<_Star> _stars;
  final _rnd = math.Random();

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: widget.period)
      ..repeat(reverse: true);
    _stars = List.generate(widget.count, (_) {
      return _Star(
        dx: _rnd.nextDouble(),
        dy: _rnd.nextDouble(),
        size: lerp(widget.minSize, widget.maxSize, _rnd.nextDouble()),
        phase: _rnd.nextDouble(),
      );
    });
  }

  double lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: true,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          return CustomPaint(
            painter: _SparklesPainter(
              t: _c.value,
              stars: _stars,
              color: widget.color,
            ),
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }
}

class _Star {
  final double dx;
  final double dy;
  final double size;
  final double phase;

  const _Star({
    required this.dx,
    required this.dy,
    required this.size,
    required this.phase,
  });
}

class _SparklesPainter extends CustomPainter {
  final double t;
  final List<_Star> stars;
  final Color color;

  _SparklesPainter({required this.t, required this.stars, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    for (final s in stars) {
      final cx = s.dx * size.width;
      final cy = s.dy * size.height;
      // independent flicker per star
      final alpha =
          (0.08 + 0.10 * (0.5 + 0.5 * math.sin(2 * math.pi * (t + s.phase))))
              .clamp(0.02, 0.22);
      paint.color = color.withOpacity(alpha);
      canvas.drawCircle(Offset(cx, cy), s.size * 0.5, paint);
    }
  }

  @override
  bool shouldRepaint(_SparklesPainter oldDelegate) =>
      oldDelegate.t != t ||
      oldDelegate.stars != stars ||
      oldDelegate.color != color;
}

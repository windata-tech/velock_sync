import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// "Edit this connection": a server with a gear badge.
///
/// The action changes the address, port and account of a server, so the glyph
/// shows a server being configured rather than a pen, which read as "edit a
/// document". Drawn on a 24-unit grid with the same thin outline weight as the
/// system icons next to it; the gear is solid so it stays legible at 22pt.
class ConnectionSettingsGlyph extends StatelessWidget {
  const ConnectionSettingsGlyph({
    super.key,
    this.size = 24,
    this.color,
    this.semanticLabel,
  });

  final double size;

  /// Defaults to the ambient [IconTheme] colour, like an [Icon].
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final paint = CustomPaint(
      size: Size.square(size),
      painter: _ServerGearPainter(
        color ?? IconTheme.of(context).color ?? const Color(0xFF000000),
      ),
    );
    return Semantics(
      label: semanticLabel,
      excludeSemantics: semanticLabel == null,
      child: SizedBox.square(dimension: size, child: paint),
    );
  }
}

class _ServerGearPainter extends CustomPainter {
  const _ServerGearPainter(this.color);

  final Color color;

  static const _gearCentre = Offset(17.6, 17.6);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final fill = Paint()..color = color;

    // The server, with room cut out around the gear so the two never touch.
    canvas.saveLayer(const Rect.fromLTWH(0, 0, 24, 24), Paint());
    for (final top in [3.0, 11.0]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(2.6, top, 16.4, 6.6),
          const Radius.circular(2),
        ),
        stroke,
      );
      final middle = top + 3.3;
      canvas.drawCircle(Offset(6.0, middle), 1.05, fill);
      canvas.drawLine(Offset(9.0, middle), Offset(12.0, middle), stroke);
    }
    canvas.drawCircle(_gearCentre, 7.0, Paint()..blendMode = BlendMode.clear);
    canvas.restore();

    canvas.drawPath(_gear(), fill);
  }

  /// Eight rounded teeth around a hub, with a hole through the middle.
  Path _gear() {
    const teeth = 8;
    const outer = 5.6;
    const inner = 4.25;
    final outline = Path();
    for (var tooth = 0; tooth < teeth; tooth++) {
      final start = 2 * math.pi * tooth / teeth;
      const step = 2 * math.pi / teeth;
      // Rising flank, tooth top, falling flank, valley.
      final points = [
        (inner, start - step * 0.25),
        (outer, start - step * 0.16),
        (outer, start + step * 0.16),
        (inner, start + step * 0.25),
      ];
      for (final (index, (radius, angle)) in points.indexed) {
        final point =
            _gearCentre +
            Offset(math.cos(angle) * radius, math.sin(angle) * radius);
        if (tooth == 0 && index == 0) {
          outline.moveTo(point.dx, point.dy);
        } else {
          outline.lineTo(point.dx, point.dy);
        }
      }
    }
    outline.close();
    return Path.combine(
      PathOperation.difference,
      outline,
      Path()..addOval(Rect.fromCircle(center: _gearCentre, radius: 2.0)),
    );
  }

  @override
  bool shouldRepaint(_ServerGearPainter old) => old.color != color;
}

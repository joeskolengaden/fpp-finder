// One-off helper that draws the launcher icon (snowflake on a dark gradient) to
// tool/icon-1024.png. Run with:  flutter test tool/gen_icon_test.dart
// tool/make_icons.sh then resizes it into the Android/iOS icon slots.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _IconPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0F1419), Color(0xFF14405E)],
        ).createShader(rect),
    );
    final c = size.center(Offset.zero);
    final r = size.width * 0.36;
    final arm = Paint()
      ..color = const Color(0xFF2EE59D)
      ..strokeWidth = size.width * 0.045
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (var i = 0; i < 6; i++) {
      final a = -math.pi / 2 + i * math.pi / 3;
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c, c + dir * r, arm);
      for (final t in [0.5, 0.75]) {
        final p = c + dir * (r * t);
        final len = r * (t == 0.5 ? 0.30 : 0.20);
        for (final s in [-1, 1]) {
          final ba = a + s * math.pi / 3;
          canvas.drawLine(p, p + Offset(math.cos(ba), math.sin(ba)) * len, arm);
        }
      }
    }
    canvas.drawCircle(c, size.width * 0.04, Paint()..color = const Color(0xFF3DA9FC));
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

void main() {
  test('draw icon', () async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    _IconPainter().paint(canvas, const Size(1024, 1024));
    final img = await rec.endRecording().toImage(1024, 1024);
    final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!;
    File('tool/icon-1024.png').writeAsBytesSync(bytes.buffer.asUint8List());
  });
}

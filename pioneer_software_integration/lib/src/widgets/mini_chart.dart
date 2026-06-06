import 'package:flutter/material.dart';

class MiniChart extends StatelessWidget {
  final List<double> data;
  final LinearGradient gradient;
  final double height;
  final bool isPositive;

  const MiniChart({
    required this.data,
    required this.gradient,
    this.height = 60,
    this.isPositive = true,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) return SizedBox(height: height);

    final maxValue = data.reduce((a, b) => a > b ? a : b);
    final minValue = data.reduce((a, b) => a < b ? a : b);
    final range = maxValue - minValue;

    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _MiniChartPainter(
          data: data,
          gradient: gradient,
          maxValue: maxValue,
          minValue: minValue,
          range: range,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _MiniChartPainter extends CustomPainter {
  final List<double> data;
  final LinearGradient gradient;
  final double maxValue;
  final double minValue;
  final double range;

  _MiniChartPainter({
    required this.data,
    required this.gradient,
    required this.maxValue,
    required this.minValue,
    required this.range,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    final paint = Paint()
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final fillPaint = Paint()..style = PaintingStyle.fill;

    final width = size.width;
    final height = size.height;
    final pointWidth = width / (data.length - 1);

    // Create gradient shader
    paint.shader = gradient.createShader(Rect.fromLTWH(0, 0, width, height));
    fillPaint.shader = gradient.createShader(
      Rect.fromLTWH(0, 0, width, height),
    );

    // Draw line chart
    Path linePath = Path();
    Path fillPath = Path();

    for (int i = 0; i < data.length; i++) {
      final x = i * pointWidth;
      final normalizedValue = (data[i] - minValue) / (range == 0 ? 1 : range);
      final y = height - (normalizedValue * height);

      if (i == 0) {
        linePath.moveTo(x, y);
        fillPath.moveTo(x, y);
      } else {
        linePath.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }

    // Complete fill path
    fillPath.lineTo(width, height);
    fillPath.lineTo(0, height);
    fillPath.close();

    // Draw fill
    canvas.drawPath(
      fillPath,
      fillPaint..color = gradient.colors[0].withValues(alpha: ((50) / 255)),
    );

    // Draw line
    canvas.drawPath(linePath, paint);

    // Draw circles at each point
    for (int i = 0; i < data.length; i++) {
      final x = i * pointWidth;
      final normalizedValue = (data[i] - minValue) / (range == 0 ? 1 : range);
      final y = height - (normalizedValue * height);

      canvas.drawCircle(
        Offset(x, y),
        3,
        Paint()
          ..color = gradient.colors[0]
          ..style = PaintingStyle.fill,
      );
    }
  }

  @override
  bool shouldRepaint(_MiniChartPainter oldDelegate) => false;
}

// lib/src/widgets/signature_pad.dart
// Reusable finger/stylus/mouse signature canvas â€” no external packages needed.
// Use a GlobalKey<SignaturePadState> to call .clear() or read .isEmpty.

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class SignaturePad extends StatefulWidget {
  final double height;
  final Color? penColor;
  final Color? backgroundColor;

  /// Called whenever strokes change; [isEmpty] == true means pad was cleared.
  final void Function(bool isEmpty)? onChanged;

  const SignaturePad({
    super.key,
    this.height = 160,
    this.penColor,
    this.backgroundColor,
    this.onChanged,
  });

  @override
  SignaturePadState createState() => SignaturePadState();
}

class SignaturePadState extends State<SignaturePad> {
  final List<List<Offset>> _strokes = [];
  List<Offset> _currentStroke = [];

  bool get isEmpty => _strokes.isEmpty && _currentStroke.isEmpty;

  List<List<Map<String, double>>> exportStrokes() {
    return _strokes
        .map(
          (stroke) =>
              stroke.map((point) => {'x': point.dx, 'y': point.dy}).toList(),
        )
        .toList();
  }

  void clear() {
    setState(() {
      _strokes.clear();
      _currentStroke = [];
    });
    widget.onChanged?.call(true);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor =
        widget.backgroundColor ??
        (isDark ? AppTheme.colorFF0F1117 : AppTheme.white);
    final penColor =
        widget.penColor ?? (isDark ? AppTheme.white : AppTheme.colorFF1A1D23);

    return GestureDetector(
      onPanStart: (d) {
        setState(() {
          _currentStroke = [d.localPosition];
        });
      },
      onPanUpdate: (d) {
        setState(() {
          _currentStroke.add(d.localPosition);
        });
      },
      onPanEnd: (_) {
        if (_currentStroke.isNotEmpty) {
          setState(() {
            _strokes.add(List.from(_currentStroke));
            _currentStroke = [];
          });
          widget.onChanged?.call(false);
        }
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: CustomPaint(
          painter: _SignaturePainter(
            strokes: _strokes,
            currentStroke: _currentStroke,
            penColor: penColor,
            bgColor: bgColor,
          ),
          child: SizedBox(height: widget.height, width: double.infinity),
        ),
      ),
    );
  }
}

class _SignaturePainter extends CustomPainter {
  final List<List<Offset>> strokes;
  final List<Offset> currentStroke;
  final Color penColor;
  final Color bgColor;

  _SignaturePainter({
    required this.strokes,
    required this.currentStroke,
    required this.penColor,
    required this.bgColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Background fill
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = bgColor,
    );

    // Subtle baseline guide
    canvas.drawLine(
      Offset(20, size.height * 0.75),
      Offset(size.width - 20, size.height * 0.75),
      Paint()
        ..color = penColor.withValues(alpha: 0.12)
        ..strokeWidth = 1,
    );

    // Hint label when empty
    if (strokes.isEmpty && currentStroke.isEmpty) {
      final tp = TextPainter(
        text: TextSpan(
          text: 'Sign here',
          style: TextStyle(
            fontSize: 13,
            color: penColor.withValues(alpha: 0.25),
            fontStyle: FontStyle.italic,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset((size.width - tp.width) / 2, size.height * 0.75 - tp.height - 6),
      );
    }

    final paint = Paint()
      ..color = penColor
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    void drawStroke(List<Offset> stroke) {
      if (stroke.isEmpty) return;
      if (stroke.length == 1) {
        canvas.drawCircle(stroke.first, 1.5, paint..style = PaintingStyle.fill);
        paint.style = PaintingStyle.stroke;
        return;
      }
      final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
      for (int i = 1; i < stroke.length; i++) {
        // Smooth curve using quadratic bezier
        if (i < stroke.length - 1) {
          final mid = Offset(
            (stroke[i].dx + stroke[i + 1].dx) / 2,
            (stroke[i].dy + stroke[i + 1].dy) / 2,
          );
          path.quadraticBezierTo(stroke[i].dx, stroke[i].dy, mid.dx, mid.dy);
        } else {
          path.lineTo(stroke[i].dx, stroke[i].dy);
        }
      }
      canvas.drawPath(path, paint);
    }

    for (final s in strokes) {
      drawStroke(s);
    }
    drawStroke(currentStroke);
  }

  @override
  bool shouldRepaint(_SignaturePainter old) => true;
}

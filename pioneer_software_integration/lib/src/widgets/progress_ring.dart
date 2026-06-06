import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class ProgressRing extends StatefulWidget {
  final double progress; // 0.0 to 1.0
  final double size;
  final double strokeWidth;
  final LinearGradient gradient;
  final String? label;
  final String? percentage;
  final Color? backgroundColor;

  const ProgressRing({
    required this.progress,
    this.size = 120,
    this.strokeWidth = 8,
    required this.gradient,
    this.label,
    this.percentage,
    this.backgroundColor,
    super.key,
  });

  @override
  State<ProgressRing> createState() => _ProgressRingState();
}

class _ProgressRingState extends State<ProgressRing>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _animation = Tween<double>(
      begin: 0,
      end: widget.progress,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _controller.forward();
  }

  @override
  void didUpdateWidget(ProgressRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.progress != widget.progress) {
      _animation =
          Tween<double>(
            begin: oldWidget.progress,
            end: widget.progress,
          ).animate(
            CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
          );
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                size: Size(widget.size, widget.size),
                painter: _ProgressRingPainter(
                  progress: _animation.value,
                  strokeWidth: widget.strokeWidth,
                  gradient: widget.gradient,
                  backgroundColor:
                      widget.backgroundColor ??
                      AppTheme.materialGrey.withValues(alpha: ((30) / 255)),
                ),
              ),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.percentage != null)
                    Text(
                      widget.percentage!,
                      style: AppTheme.getHeadingStyle(
                        context,
                        fontSize: 20,
                      ).copyWith(fontWeight: FontWeight.w900),
                    ),
                  if (widget.label != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      widget.label!,
                      style: AppTheme.getCaptionStyle(context),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ProgressRingPainter extends CustomPainter {
  final double progress;
  final double strokeWidth;
  final LinearGradient gradient;
  final Color backgroundColor;

  _ProgressRingPainter({
    required this.progress,
    required this.strokeWidth,
    required this.gradient,
    required this.backgroundColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.width / 2) - (strokeWidth / 2);

    // Background
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = backgroundColor
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );

    // Progress
    final paint = Paint()
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    const colors = [AppTheme.colorFF4B7BE5, AppTheme.colorFF00D4FF];
    paint.shader = SweepGradient(
      colors: colors,
    ).createShader(Rect.fromCircle(center: center, radius: radius));

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -3.14159 / 2,
      (3.14159 * 2) * progress,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_ProgressRingPainter oldDelegate) =>
      progress != oldDelegate.progress;
}

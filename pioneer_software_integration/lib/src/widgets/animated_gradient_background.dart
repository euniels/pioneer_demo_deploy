import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class AnimatedGradientBackground extends StatefulWidget {
  final Widget child;
  final bool isDark;

  const AnimatedGradientBackground({
    required this.child,
    required this.isDark,
    super.key,
  });

  @override
  State<AnimatedGradientBackground> createState() =>
      _AnimatedGradientBackgroundState();
}

class _AnimatedGradientBackgroundState extends State<AnimatedGradientBackground>
    with TickerProviderStateMixin {
  late AnimationController _controller1;
  late AnimationController _controller2;

  @override
  void initState() {
    super.initState();
    _controller1 = AnimationController(
      duration: const Duration(seconds: 8),
      vsync: this,
    )..repeat(reverse: true);

    _controller2 = AnimationController(
      duration: const Duration(seconds: 12),
      vsync: this,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller1.dispose();
    _controller2.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: widget.isDark
                  ? [
                      AppTheme.colorFF0A0E1A,
                      AppTheme.colorFF0F1A30,
                      AppTheme.colorFF122844,
                    ]
                  : [AppTheme.colorFFF8FAFB, AppTheme.colorFFEAF1FF],
            ),
          ),
        ),
        AnimatedBuilder(
          animation: _controller1,
          builder: (context, child) {
            return Transform.translate(
              offset: Offset(
                50 * (_controller1.value - 0.5),
                30 * (_controller1.value - 0.5),
              ),
              child: Container(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    radius: 0.8,
                    colors: widget.isDark
                        ? [
                            AppTheme.colorFF4B7BE5.withValues(alpha: 30 / 255),
                            AppTheme.colorFF4B7BE5.withValues(alpha: 0),
                          ]
                        : [
                            AppTheme.colorFF4B7BE5.withValues(alpha: 15 / 255),
                            AppTheme.colorFF4B7BE5.withValues(alpha: 0),
                          ],
                  ),
                ),
              ),
            );
          },
        ),
        AnimatedBuilder(
          animation: _controller2,
          builder: (context, child) {
            return Transform.translate(
              offset: Offset(
                -40 * (_controller2.value - 0.5),
                -50 * (_controller2.value - 0.5),
              ),
              child: Container(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    radius: 0.9,
                    colors: widget.isDark
                        ? [
                            AppTheme.colorFF00D4FF.withValues(alpha: 20 / 255),
                            AppTheme.colorFF00D4FF.withValues(alpha: 0),
                          ]
                        : [
                            AppTheme.colorFF00D4FF.withValues(alpha: 10 / 255),
                            AppTheme.colorFF00D4FF.withValues(alpha: 0),
                          ],
                  ),
                ),
              ),
            );
          },
        ),
        widget.child,
      ],
    );
  }
}

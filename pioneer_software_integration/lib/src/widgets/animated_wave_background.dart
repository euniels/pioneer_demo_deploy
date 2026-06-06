import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class AnimatedWaveBackground extends StatefulWidget {
  const AnimatedWaveBackground({super.key});

  @override
  State<AnimatedWaveBackground> createState() => _AnimatedWaveBackgroundState();
}

class _AnimatedWaveBackgroundState extends State<AnimatedWaveBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 20),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? [
                      AppTheme.darkBg,
                      AppTheme.darkBg.withValues(alpha: ((204) / 255)),
                      AppTheme.primaryBlue.withValues(alpha: ((13) / 255)),
                      AppTheme.darkBg,
                    ]
                  : [
                      AppTheme.lightBg,
                      AppTheme.lightBg.withValues(alpha: ((230) / 255)),
                      AppTheme.primaryBlue.withValues(alpha: ((20) / 255)),
                      AppTheme.lightBg,
                    ],
              stops: const [0.0, 0.4, 0.7, 1.0],
              transform: GradientRotation(_controller.value * 2 * 3.14159),
            ),
          ),
        );
      },
    );
  }
}

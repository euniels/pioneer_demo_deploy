import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class PremiumGlassCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double elevation;
  final EdgeInsetsGeometry? padding;

  const PremiumGlassCard({
    super.key,
    required this.child,
    this.onTap,
    this.elevation = 20,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: padding ?? const EdgeInsets.all(20),
        decoration: BoxDecoration(
          // Solid background - no transparency issues
          color: isDark ? AppTheme.darkCardBg : AppTheme.white,

          borderRadius: BorderRadius.circular(24),

          // Vibrant border glow - stronger in dark mode
          border: Border.all(
            color: isDark
                ? AppTheme.primaryBlue.withValues(
                    alpha: ((140) / 255),
                  ) // More vibrant in dark
                : AppTheme.primaryBlue.withValues(
                    alpha: ((60) / 255),
                  ), // Subtle in light
            width: isDark ? 2.0 : 1.5,
          ),

          // Multiple layered shadows for 3D floating effect
          boxShadow: isDark
              ? [
                  // Dark mode: More dramatic glow
                  BoxShadow(
                    color: AppTheme.primaryBlue.withValues(
                      alpha: ((120) / 255),
                    ),
                    blurRadius: elevation * 1.3,
                    spreadRadius: 2,
                    offset: const Offset(0, 10),
                  ),
                  BoxShadow(
                    color: AppTheme.black.withValues(alpha: ((200) / 255)),
                    blurRadius: 45,
                    offset: const Offset(0, 18),
                  ),
                ]
              : [
                  // Light mode: Clean, elevated card shadows
                  BoxShadow(
                    color: AppTheme.primaryBlue.withValues(alpha: ((40) / 255)),
                    blurRadius: elevation * 0.8,
                    spreadRadius: 0,
                    offset: const Offset(0, 8),
                  ),
                  BoxShadow(
                    color: AppTheme.black.withValues(alpha: ((60) / 255)),
                    blurRadius: 25,
                    offset: const Offset(0, 12),
                  ),
                  BoxShadow(
                    color: AppTheme.black.withValues(alpha: ((30) / 255)),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
        ),
        child: child,
      ),
    );
  }
}

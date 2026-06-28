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
          color: AppTheme.surfaceCard(context),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: AppTheme.borderStrong(context),
            width: isDark ? 2.0 : 1.5,
          ),
          boxShadow: isDark
              ? [
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

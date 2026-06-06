import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class AppCard extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsets padding;

  const AppCard({
    super.key,
    required this.child,
    this.radius = 12.0,
    this.padding = const EdgeInsets.all(12),
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(radius),
      color: AppTheme.getCardBg(context),
      shadowColor: AppTheme.primaryBlue.withValues(alpha: ((76) / 255)),
      child: Container(
        width: 280,
        padding: padding,
        decoration: BoxDecoration(
          color: AppTheme.getCardBg(context),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: isDark
                ? AppTheme.primaryBlue.withValues(alpha: ((76) / 255))
                : AppTheme.primaryBlue.withValues(alpha: ((51) / 255)),
            width: 1,
          ),
        ),
        child: child,
      ),
    );
  }
}

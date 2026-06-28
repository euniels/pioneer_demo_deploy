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
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(radius),
      color: AppTheme.surfaceCard(context),
      shadowColor: AppTheme.primaryBlue.withValues(alpha: ((76) / 255)),
      child: Container(
        width: 280,
        padding: padding,
        decoration: BoxDecoration(
          color: AppTheme.surfaceCard(context),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: AppTheme.borderStrong(context), width: 1),
        ),
        child: child,
      ),
    );
  }
}

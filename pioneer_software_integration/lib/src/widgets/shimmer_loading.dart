import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';
import '../theme/app_theme.dart';

class ShimmerLoading extends StatelessWidget {
  final double width;
  final double height;
  final BorderRadius? borderRadius;
  final bool isVertical;

  const ShimmerLoading({
    this.width = double.infinity,
    this.height = 16,
    this.borderRadius,
    this.isVertical = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Shimmer.fromColors(
      period: const Duration(milliseconds: 1500),
      baseColor: isDark ? AppTheme.colorFF1A202C : AppTheme.colorFFF3F4F6,
      highlightColor: isDark ? AppTheme.colorFF2D3748 : AppTheme.colorFFF9FAFB,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: AppTheme.getCardBg(context),
          borderRadius: borderRadius ?? BorderRadius.circular(8),
        ),
      ),
    );
  }
}

class ShimmerCard extends StatelessWidget {
  final double height;
  final bool showFooter;

  const ShimmerCard({this.height = 200, this.showFooter = true, super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: AppTheme.getCardRadius(),
        border: Border.all(color: AppTheme.getBorderColor(context), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShimmerLoading(
            height: 20,
            width: 150,
            borderRadius: BorderRadius.circular(6),
          ),
          const SizedBox(height: 12),
          ShimmerLoading(
            height: height - 50,
            width: double.infinity,
            borderRadius: AppTheme.getCardRadius(),
          ),
          if (showFooter) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ShimmerLoading(
                    height: 12,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ShimmerLoading(
                    height: 12,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

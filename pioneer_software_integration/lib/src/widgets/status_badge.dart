import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

enum StatusType { active, inactive, warning, error, pending }

class StatusBadge extends StatelessWidget {
  final StatusType type;
  final String label;
  final IconData? icon;
  final bool isCompact;

  const StatusBadge({
    required this.type,
    required this.label,
    this.icon,
    this.isCompact = false,
    super.key,
  });

  Color _getStatusColor() {
    switch (type) {
      case StatusType.active:
        return AppTheme.successGreen;
      case StatusType.inactive:
        return AppTheme.colorFF9CA3AF;
      case StatusType.warning:
        return AppTheme.warningOrange;
      case StatusType.error:
        return AppTheme.errorRed;
      case StatusType.pending:
        return AppTheme.primaryBlue;
    }
  }

  LinearGradient _getGradient() {
    switch (type) {
      case StatusType.active:
        return AppTheme.successGradient;
      case StatusType.inactive:
        return const LinearGradient(
          colors: [AppTheme.colorFFB0B7C3, AppTheme.colorFF9CA3AF],
        );
      case StatusType.warning:
        return AppTheme.warningGradient;
      case StatusType.error:
        return AppTheme.errorGradient;
      case StatusType.pending:
        return AppTheme.primaryGradient;
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = _getStatusColor();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isCompact ? 8 : 12,
        vertical: isCompact ? 4 : 8,
      ),
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: ((isDark ? 30 : 20) / 255)),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: statusColor.withValues(alpha: ((100) / 255)),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              gradient: _getGradient(),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: 6),
          if (icon != null) ...[
            Icon(icon, size: isCompact ? 12 : 14, color: statusColor),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: isCompact ? 11 : 13,
              fontWeight: FontWeight.w600,
              color: statusColor,
            ),
          ),
        ],
      ),
    );
  }
}

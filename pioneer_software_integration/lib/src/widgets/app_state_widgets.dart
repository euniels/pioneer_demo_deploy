import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/app_logger.dart';
import '../theme/app_theme.dart';

enum PioneerStateTone { empty, error, warning, success, info }

class PioneerStateCard extends StatelessWidget {
  const PioneerStateCard({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.tone = PioneerStateTone.empty,
    this.compact = false,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final PioneerStateTone tone;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final accent = _toneColor(tone);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? AppTheme.space16 : AppTheme.space24),
      decoration: BoxDecoration(
        color: AppTheme.surfaceCard(context),
        borderRadius: AppTheme.getPanelRadius(),
        border: Border.all(color: AppTheme.borderDefault(context)),
        boxShadow: AppTheme.getCardShadow(context),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: compact ? 44 : 56,
            height: compact ? 44 : 56,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: isDark ? 0.18 : 0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: accent, size: compact ? 22 : 28),
          ),
          const SizedBox(height: AppTheme.space12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: AppTheme.getHeadingStyle(
              context,
              fontSize: compact ? 15 : 18,
            ),
          ),
          const SizedBox(height: AppTheme.space6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: AppTheme.settingsSubtitleStyle(context).copyWith(
              height: 1.35,
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: AppTheme.space16),
            FilledButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(actionLabel!),
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: AppTheme.white,
                shape: RoundedRectangleBorder(
                  borderRadius: AppTheme.getButtonRadius(),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class PioneerErrorBanner extends StatelessWidget {
  const PioneerErrorBanner({
    required this.message,
    this.onRetry,
    this.compact = false,
    super.key,
  });

  final String message;
  final VoidCallback? onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (kDebugMode) {
      AppLogger.warning('PioneerPath page error', {'message': message});
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppTheme.space12),
      decoration: BoxDecoration(
        color: AppTheme.errorRed.withValues(alpha: 0.10),
        borderRadius: AppTheme.getButtonRadius(),
        border: Border.all(color: AppTheme.errorRed.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: AppTheme.errorRed),
          const SizedBox(width: AppTheme.space10),
          Expanded(
            child: Text(
              'Something went wrong while loading this section.',
              style: AppTheme.settingsCaptionStyle(context).copyWith(
                color: AppTheme.textPrimary(context),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: AppTheme.space8),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ],
      ),
    );
  }
}

class PioneerBackgroundRefreshIndicator extends StatelessWidget {
  const PioneerBackgroundRefreshIndicator({
    required this.visible,
    this.label = 'Refreshing',
    super.key,
  });

  final bool visible;
  final String label;

  @override
  Widget build(BuildContext context) {
    if (!visible) {
      return const SizedBox.shrink();
    }

    return Align(
      alignment: Alignment.topRight,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.space10,
          vertical: AppTheme.space6,
        ),
        decoration: BoxDecoration(
          color: AppTheme.surfaceCard(context),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: AppTheme.borderDefault(context)),
          boxShadow: AppTheme.getCardShadow(context),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppTheme.accentCyan,
              ),
            ),
            const SizedBox(width: AppTheme.space8),
            Text(label, style: AppTheme.settingsCaptionStyle(context)),
          ],
        ),
      ),
    );
  }
}

Color _toneColor(PioneerStateTone tone) {
  return switch (tone) {
    PioneerStateTone.error => AppTheme.errorRed,
    PioneerStateTone.warning => AppTheme.warningOrange,
    PioneerStateTone.success => AppTheme.successGreen,
    PioneerStateTone.info => AppTheme.accentCyan,
    PioneerStateTone.empty => AppTheme.neutralGray,
  };
}

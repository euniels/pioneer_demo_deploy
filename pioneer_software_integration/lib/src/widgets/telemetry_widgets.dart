import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/telemetry_view_data.dart';
import '../theme/app_theme.dart';

class TelemetryReadingTile extends StatelessWidget {
  const TelemetryReadingTile({
    super.key,
    required this.reading,
    required this.icon,
    this.compact = false,
    this.showHistory = true,
  });

  final TelemetryReadingViewData reading;
  final IconData icon;
  final bool compact;
  final bool showHistory;

  @override
  Widget build(BuildContext context) {
    final color = telemetrySeverityColor(reading.severity, reading.availability);
    return Semantics(
      label:
          '${reading.label}, ${reading.displayValue}, ${reading.availabilityLabel}',
      child: Container(
        constraints: BoxConstraints(minHeight: compact ? 54 : 94),
        padding: EdgeInsets.all(compact ? 10 : 14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.24)),
        ),
        child: Row(
          children: [
            Container(
              width: compact ? 32 : 40,
              height: compact ? 32 : 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, color: color, size: compact ? 17 : 21),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    reading.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.getCaptionStyle(context).copyWith(
                      fontSize: compact ? 11 : 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          reading.displayValue,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTheme.getHeadingStyle(
                            context,
                            fontSize: compact ? 15 : 19,
                          ).copyWith(color: color),
                        ),
                      ),
                      if (reading.hasReading) ...[
                        const SizedBox(width: 6),
                        TelemetryTrendIndicator(
                          trend: reading.trend,
                          color: color,
                          compact: compact,
                        ),
                      ],
                    ],
                  ),
                  if (!compact && reading.safeRangeLabel.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Safe ${reading.safeRangeLabel}',
                      style: AppTheme.getCaptionStyle(
                        context,
                      ).copyWith(fontSize: 11),
                    ),
                  ],
                  const SizedBox(height: 3),
                  Text(
                    '${reading.source} / ${reading.availabilityLabel}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.getCaptionStyle(context).copyWith(
                      fontSize: compact ? 9 : 10,
                      color: color.withValues(alpha: 0.88),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            if (!compact && showHistory && reading.history.length > 1) ...[
              const SizedBox(width: 10),
              SizedBox(
                width: 76,
                height: 34,
                child: TelemetrySparkline(
                  values: reading.history,
                  color: color,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class TelemetryTrendIndicator extends StatelessWidget {
  const TelemetryTrendIndicator({
    super.key,
    required this.trend,
    required this.color,
    this.compact = false,
  });

  final TelemetryTrend trend;
  final Color color;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final icon = switch (trend) {
      TelemetryTrend.rising => Icons.trending_up_rounded,
      TelemetryTrend.falling => Icons.trending_down_rounded,
      TelemetryTrend.stable => Icons.trending_flat_rounded,
    };
    final label = switch (trend) {
      TelemetryTrend.rising => 'Rising',
      TelemetryTrend.falling => 'Falling',
      TelemetryTrend.stable => 'Stable',
    };
    return Tooltip(
      message: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: compact ? 15 : 18),
          if (!compact) ...[
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class TelemetryFreshnessBadge extends StatelessWidget {
  const TelemetryFreshnessBadge({super.key, required this.reading});

  final TelemetryReadingViewData reading;

  @override
  Widget build(BuildContext context) {
    final color = telemetrySeverityColor(reading.severity, reading.availability);
    final icon = switch (reading.availability) {
      TelemetryAvailability.live => Icons.sensors_rounded,
      TelemetryAvailability.stale => Icons.schedule_rounded,
      TelemetryAvailability.unavailable => Icons.signal_wifi_off_rounded,
      TelemetryAvailability.unsupported => Icons.block_rounded,
      TelemetryAvailability.notEquipped => Icons.sensors_off_rounded,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 5),
          Text(
            reading.availabilityLabel,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class TelemetryGroupHeader extends StatelessWidget {
  const TelemetryGroupHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final String title;
  final String subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: AppTheme.primaryBlue.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(icon, color: AppTheme.primaryBlue, size: 20),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: AppTheme.getHeadingStyle(context, fontSize: 16),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: AppTheme.getSubtitleStyle(
                  context,
                ).copyWith(fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class TelemetryAlertRow extends StatelessWidget {
  const TelemetryAlertRow({
    super.key,
    required this.title,
    required this.detail,
    required this.severity,
    required this.icon,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String detail;
  final TelemetrySeverity severity;
  final IconData icon;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = telemetrySeverityColor(severity, TelemetryAvailability.live);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.getBodyStyle(
                      context,
                    ).copyWith(fontSize: 13, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.getSubtitleStyle(
                      context,
                    ).copyWith(fontSize: 11),
                  ),
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 10), trailing!],
            if (onTap != null) ...[
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right_rounded, size: 18),
            ],
          ],
        ),
      ),
    );
  }
}

class TelemetrySparkline extends StatelessWidget {
  const TelemetrySparkline({
    super.key,
    required this.values,
    required this.color,
  });

  final List<double> values;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _TelemetrySparklinePainter(values: values, color: color),
  );
}

Color telemetrySeverityColor(
  TelemetrySeverity severity,
  TelemetryAvailability availability,
) {
  if (availability != TelemetryAvailability.live) return AppTheme.gray500;
  return switch (severity) {
    TelemetrySeverity.normal => AppTheme.successGreen,
    TelemetrySeverity.warning => AppTheme.warningOrange,
    TelemetrySeverity.critical => AppTheme.errorRed,
  };
}

class _TelemetrySparklinePainter extends CustomPainter {
  const _TelemetrySparklinePainter({
    required this.values,
    required this.color,
  });

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2 || size.isEmpty) return;
    final minimum = values.reduce(math.min);
    final maximum = values.reduce(math.max);
    final range = math.max(0.1, maximum - minimum);
    final path = Path();
    for (var index = 0; index < values.length; index++) {
      final x = size.width * index / (values.length - 1);
      final y = size.height -
          (((values[index] - minimum) / range) * (size.height - 4)) -
          2;
      index == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _TelemetrySparklinePainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.color != color;
}

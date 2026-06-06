import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class DelayPanel extends StatelessWidget {
  final Map<String, dynamic> delay;
  const DelayPanel({super.key, required this.delay});

  @override
  Widget build(BuildContext context) {
    final causes = (delay['causes'] as List).cast<Map<String, dynamic>>();
    final peak = delay['peakHours'] as String;
    final recommendation = delay['recommendation'] as String;
    final score = (delay['healthScore'] as num).toDouble();

    return Row(
      children: [
        Expanded(
          flex: 2,
          child: _Card(
            title: 'Delay Causes & Fleet Health Score',
            child: Column(
              children: [
                ...causes.map(
                  (c) => _CauseRow(label: c['label'], value: '${c['value']}%'),
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.colorFFF3F6FF,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppTheme.colorFFE7ECFF),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Text(
                            'Fleet Health Score',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${score.toStringAsFixed(1)}% Good',
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: AppTheme.colorFF0B7A3B,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          minHeight: 12,
                          value: score / 100.0,
                          backgroundColor: AppTheme.colorFFEAF1FF,
                          color: AppTheme.colorFF0B7A3B,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _Card(
            title: '📍 Peak Hours: $peak',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                const Text(
                  'Recommendation:',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.colorFFE8FFF2,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.colorFFB3E5CE),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.check_circle_rounded,
                        color: AppTheme.colorFF0B7A3B,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          recommendation,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _CauseRow extends StatelessWidget {
  final String label;
  final String value;
  const _CauseRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppTheme.colorFF4B7BE5,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: isDark ? AppTheme.white : AppTheme.colorFF1F2937,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: isDark ? AppTheme.white : AppTheme.colorFF1F2937,
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final String title;
  final Widget child;
  const _Card({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.getCardBg(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.getBorderColor(context)),
        boxShadow: AppTheme.getCardShadow(context),
        gradient: isDark
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppTheme.colorFF1F3A5F.withValues(alpha: 0.2),
                  AppTheme.getCardBg(context),
                ],
              )
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: isDark ? AppTheme.white : AppTheme.colorFF1F2937,
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

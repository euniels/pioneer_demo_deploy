import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class MaintenanceCard extends StatefulWidget {
  final Map<String, dynamic> item;
  const MaintenanceCard({super.key, required this.item});

  @override
  State<MaintenanceCard> createState() => _MaintenanceCardState();
}

class _MaintenanceCardState extends State<MaintenanceCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _isHovered = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final risk = widget.item['risk'] as String;
    final badge = _riskBadge(risk);

    return MouseRegion(
      onEnter: (_) {
        setState(() => _isHovered = true);
        _controller.forward();
      },
      onExit: (_) {
        setState(() => _isHovered = false);
        _controller.reverse();
      },
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Transform.translate(
            offset: Offset(0, -8 * _controller.value),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.getCardBg(context),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: AppTheme.getBorderColor(context),
                  width: _isHovered ? 2 : 1,
                ),
                gradient: _isHovered
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          isDark
                              ? AppTheme.colorFF2A3F5F
                              : AppTheme.colorFFF8FBFF,
                          AppTheme.getCardBg(context),
                        ],
                      )
                    : null,
                boxShadow: _isHovered
                    ? AppTheme.cardShadow
                    : AppTheme.getCardShadow(context),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: badge.bgLight.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: badge.bgLight.withValues(alpha: 0.5),
                          ),
                        ),
                        child: Icon(
                          _getRiskIcon(risk),
                          color: badge.fg,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${widget.item['plate']} • ${widget.item['model']}',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 14,
                                color: isDark
                                    ? AppTheme.white
                                    : AppTheme.colorFF1F2937,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              risk,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: badge.fg,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Predicted Issue',
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.colorFFAEB8C8
                          : AppTheme.colorFF6B7280,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.item['issue'],
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: isDark ? AppTheme.white : AppTheme.colorFF1F2937,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    widget.item['details'],
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.colorFFC5CEE0
                          : AppTheme.colorFF374151,
                      fontSize: 13,
                    ),
                  ),
                  const Spacer(),
                  Row(
                    children: [
                      _MiniStat(
                        label: 'Confidence',
                        value: '${widget.item['confidence']}%',
                      ),
                      const SizedBox(width: 10),
                      _MiniStat(
                        label: 'Mileage',
                        value: '${widget.item['mileage']}',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  IconData _getRiskIcon(String risk) {
    switch (risk.toLowerCase()) {
      case 'low risk':
        return Icons.check_circle_rounded;
      case 'medium risk':
        return Icons.warning_rounded;
      default:
        return Icons.error_rounded;
    }
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  const _MiniStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.colorFF1A2E4A : AppTheme.colorFFF3F6FF,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.getBorderColor(context)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: isDark ? AppTheme.colorFFAEB8C8 : AppTheme.colorFF6B7280,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: isDark ? AppTheme.white : AppTheme.colorFF1F2937,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge {
  final Color bg;
  final Color bgLight;
  final Color fg;
  _Badge(this.bg, this.bgLight, this.fg);
}

_Badge _riskBadge(String risk) {
  switch (risk.toLowerCase()) {
    case 'low risk':
      return _Badge(
        AppTheme.colorFF0B7A3B,
        AppTheme.colorFFE8FFF2,
        AppTheme.colorFF0B7A3B,
      );
    case 'medium risk':
      return _Badge(
        AppTheme.colorFF9A5B00,
        AppTheme.colorFFFFF6E6,
        AppTheme.colorFF9A5B00,
      );
    default:
      return _Badge(
        AppTheme.colorFFB42318,
        AppTheme.colorFFFFEAEA,
        AppTheme.colorFFB42318,
      );
  }
}

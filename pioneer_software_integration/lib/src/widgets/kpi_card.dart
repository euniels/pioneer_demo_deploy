import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class KpiCard extends StatefulWidget {
  final String title;
  final String value;
  final String subtitle;
  final IconData icon;

  const KpiCard({
    super.key,
    required this.title,
    required this.value,
    required this.subtitle,
    required this.icon,
  });

  @override
  State<KpiCard> createState() => _KpiCardState();
}

class _KpiCardState extends State<KpiCard> with SingleTickerProviderStateMixin {
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
            offset: Offset(0, -5 * _controller.value),
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
                              ? AppTheme.colorFF1F3A5F
                              : AppTheme.colorFFF0F8FF,
                          AppTheme.getCardBg(context),
                        ],
                      )
                    : null,
                boxShadow: _isHovered
                    ? AppTheme.cardShadow
                    : AppTheme.getCardShadow(context),
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: AppTheme.primaryGradient,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: _isHovered ? AppTheme.cardShadow : [],
                    ),
                    child: Icon(widget.icon, color: AppTheme.white, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: isDark
                                ? AppTheme.white70
                                : AppTheme.colorFF6B7280,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.value,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            color: isDark
                                ? AppTheme.white
                                : AppTheme.colorFF1F2937,
                          ),
                        ),
                        Text(
                          widget.subtitle,
                          style: TextStyle(
                            color: isDark
                                ? AppTheme.white54
                                : AppTheme.colorFF6B7280,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

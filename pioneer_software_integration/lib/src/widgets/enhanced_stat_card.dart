import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';
import 'mini_chart.dart';

class EnhancedStatCard extends StatefulWidget {
  final String title;
  final String value;
  final String? subtitle;
  final IconData icon;
  final LinearGradient gradient;
  final List<double> chartData;
  final String? trendLabel;
  final bool isPositive;
  final VoidCallback? onTap;

  const EnhancedStatCard({
    required this.title,
    required this.value,
    this.subtitle,
    required this.icon,
    required this.gradient,
    required this.chartData,
    this.trendLabel,
    this.isPositive = true,
    this.onTap,
    super.key,
  });

  @override
  State<EnhancedStatCard> createState() => _EnhancedStatCardState();
}

class _EnhancedStatCardState extends State<EnhancedStatCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _isHovered = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Transform.scale(
          scale: _isHovered ? 1.02 : 1.0,
          child:
              AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    decoration: BoxDecoration(
                      borderRadius: AppTheme.getCardRadius(),
                      boxShadow: _isHovered
                          ? AppTheme.getElevatedShadow(context)
                          : AppTheme.getCardShadow(context),
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        borderRadius: AppTheme.getCardRadius(),
                        border: Border.all(
                          color: AppTheme.getBorderColor(context),
                          width: 1,
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            AppTheme.getCardBg(context),
                            AppTheme.getCardBg(
                              context,
                            ).withValues(alpha: ((240) / 255)),
                          ],
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Header with icon and title
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      widget.title,
                                      style: AppTheme.getCaptionStyle(context)
                                          .copyWith(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 4),
                                    ScaleTransition(
                                      scale: Tween<double>(begin: 0.8, end: 1.0)
                                          .animate(
                                            CurvedAnimation(
                                              parent: _controller,
                                              curve: Curves.easeOutBack,
                                            ),
                                          ),
                                      child: Text(
                                        widget.value,
                                        style: AppTheme.getHeadingStyle(
                                          context,
                                          fontSize: 28,
                                        ).copyWith(fontWeight: FontWeight.w900),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  gradient: widget.gradient,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(
                                  widget.icon,
                                  color: AppTheme.white,
                                  size: 24,
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 16),

                          // Mini Chart
                          SizedBox(
                            height: 60,
                            child: MiniChart(
                              data: widget.chartData,
                              gradient: widget.gradient,
                              height: 60,
                              isPositive: widget.isPositive,
                            ),
                          ),

                          const SizedBox(height: 12),

                          // Footer with subtitle and trend
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              if (widget.subtitle != null)
                                Expanded(
                                  child: Text(
                                    widget.subtitle!,
                                    style: AppTheme.getCaptionStyle(context),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              if (widget.trendLabel != null) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: widget.isPositive
                                        ? AppTheme.successGreen.withValues(
                                            alpha: ((20) / 255),
                                          )
                                        : AppTheme.errorRed.withValues(
                                            alpha: ((20) / 255),
                                          ),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: widget.isPositive
                                          ? AppTheme.successGreen.withValues(
                                              alpha: ((100) / 255),
                                            )
                                          : AppTheme.errorRed.withValues(
                                              alpha: ((100) / 255),
                                            ),
                                      width: 1,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        widget.isPositive
                                            ? Icons.trending_up
                                            : Icons.trending_down,
                                        size: 12,
                                        color: widget.isPositive
                                            ? AppTheme.successGreen
                                            : AppTheme.errorRed,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        widget.trendLabel!,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: widget.isPositive
                                              ? AppTheme.successGreen
                                              : AppTheme.errorRed,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  )
                  .animate()
                  .fade(duration: 600.ms)
                  .slideY(
                    begin: 0.2,
                    end: 0,
                    duration: 600.ms,
                    curve: Curves.easeOutCubic,
                  ),
        ),
      ),
    );
  }
}

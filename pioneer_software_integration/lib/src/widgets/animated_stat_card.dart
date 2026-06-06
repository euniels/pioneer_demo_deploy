import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';

class AnimatedStatCard extends StatefulWidget {
  final String title;
  final String value;
  final String? subtitle;
  final IconData icon;
  final Color iconColor;
  final LinearGradient gradient;
  final VoidCallback? onTap;

  const AnimatedStatCard({
    required this.title,
    required this.value,
    this.subtitle,
    required this.icon,
    required this.iconColor,
    required this.gradient,
    this.onTap,
    super.key,
  });

  @override
  State<AnimatedStatCard> createState() => _AnimatedStatCardState();
}

class _AnimatedStatCardState extends State<AnimatedStatCard>
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
        child: Container(
          decoration: BoxDecoration(
            borderRadius: AppTheme.getCardRadius(),
            boxShadow: _isHovered
                ? AppTheme.getElevatedShadow(context)
                : AppTheme.getCardShadow(context),
          ),
          child:
              Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
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
                      borderRadius: AppTheme.getCardRadius(),
                      border: Border.all(
                        color: AppTheme.getBorderColor(context),
                        width: 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
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
                                  const SizedBox(height: 8),
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
                                  if (widget.subtitle != null) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      widget.subtitle!,
                                      style: AppTheme.getCaptionStyle(context),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
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
                      ],
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

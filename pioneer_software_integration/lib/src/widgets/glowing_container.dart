import 'package:flutter/material.dart';

class GlowingContainer extends StatefulWidget {
  final Widget child;
  final Color glowColor;
  final double glowRadius;
  final Duration duration;

  const GlowingContainer({
    required this.child,
    required this.glowColor,
    this.glowRadius = 20,
    this.duration = const Duration(seconds: 2),
    super.key,
  });

  @override
  State<GlowingContainer> createState() => _GlowingContainerState();
}

class _GlowingContainerState extends State<GlowingContainer>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _glowAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: widget.duration, vsync: this)
      ..repeat(reverse: true);

    _glowAnimation = Tween<double>(
      begin: 0.5,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _glowAnimation,
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            boxShadow: [
              BoxShadow(
                color: widget.glowColor.withValues(
                  alpha: ((100 * _glowAnimation.value).toInt() / 255),
                ),
                blurRadius: widget.glowRadius * _glowAnimation.value,
                spreadRadius: widget.glowRadius * 0.3 * _glowAnimation.value,
              ),
            ],
          ),
          child: widget.child,
        );
      },
    );
  }
}

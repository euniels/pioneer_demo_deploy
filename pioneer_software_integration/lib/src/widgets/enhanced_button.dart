import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';

enum EnhancedButtonStyle { primary, secondary, tertiary, danger, success }

class EnhancedButton extends StatefulWidget {
  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final EnhancedButtonStyle style;
  final bool isLoading;
  final bool isDisabled;
  final bool isCompact;
  final double width;
  final double height;

  const EnhancedButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.style = EnhancedButtonStyle.primary,
    this.isLoading = false,
    this.isDisabled = false,
    this.isCompact = false,
    this.width = double.infinity,
    this.height = 48,
    super.key,
  });

  @override
  State<EnhancedButton> createState() => _EnhancedButtonState();
}

class _EnhancedButtonState extends State<EnhancedButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _isPressed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  LinearGradient _getGradient() {
    if (widget.isDisabled || widget.isLoading) {
      return const LinearGradient(
        colors: [AppTheme.colorFFB0B7C3, AppTheme.colorFF9CA3AF],
      );
    }

    switch (widget.style) {
      case EnhancedButtonStyle.primary:
        return AppTheme.primaryGradient;
      case EnhancedButtonStyle.secondary:
        return AppTheme.purpleGradient;
      case EnhancedButtonStyle.tertiary:
        return const LinearGradient(
          colors: [AppTheme.colorFF8B5CF6, AppTheme.colorFFA78BFA],
        );
      case EnhancedButtonStyle.danger:
        return AppTheme.errorGradient;
      case EnhancedButtonStyle.success:
        return AppTheme.successGradient;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) {
        setState(() => _isPressed = false);
        if (!widget.isDisabled && !widget.isLoading) {
          _controller.forward(from: 0);
          widget.onPressed();
        }
      },
      onTapCancel: () => setState(() => _isPressed = false),
      child: Opacity(
        opacity: widget.isDisabled ? 0.5 : 1.0,
        child: Transform.scale(
          scale: _isPressed ? 0.96 : 1.0,
          child: Container(
            width: widget.width,
            height: widget.isCompact ? 40 : widget.height,
            decoration: BoxDecoration(
              gradient: _getGradient(),
              borderRadius: AppTheme.getButtonRadius(),
              boxShadow: _isPressed
                  ? []
                  : [
                      BoxShadow(
                        color: _getGradient().colors.first.withValues(
                          alpha: ((100) / 255),
                        ),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
            ),
            child: Material(
              color: AppTheme.transparent,
              child: InkWell(
                onTap: widget.isDisabled || widget.isLoading
                    ? null
                    : widget.onPressed,
                borderRadius: AppTheme.getButtonRadius(),
                child: Center(
                  child: widget.isLoading
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              AppTheme.white,
                            ),
                          ),
                        )
                      : SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (widget.icon != null) ...[
                                Icon(
                                  widget.icon,
                                  color: AppTheme.white,
                                  size: widget.isCompact ? 16 : 18,
                                ),
                                const SizedBox(width: 8),
                              ],
                              Text(
                                widget.label,
                                style: TextStyle(
                                  color: AppTheme.white,
                                  fontSize: widget.isCompact ? 13 : 14,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.3,
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            ),
          ).animate().fade(duration: 200.ms),
        ),
      ),
    );
  }
}

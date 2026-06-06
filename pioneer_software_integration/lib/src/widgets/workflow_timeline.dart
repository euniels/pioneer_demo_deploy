import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class WorkflowTimeline extends StatefulWidget {
  const WorkflowTimeline({
    super.key,
    required this.steps,
    required this.currentPhaseNumber,
    this.compact = false,
  });

  final List<Map<String, dynamic>> steps;
  final int currentPhaseNumber;
  final bool compact;

  @override
  State<WorkflowTimeline> createState() => _WorkflowTimelineState();
}

class _WorkflowTimelineState extends State<WorkflowTimeline>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final steps = normalizeWorkflowSteps(widget.steps);
    return Column(
      children: [
        for (var index = 0; index < steps.length; index++)
          _TimelineRow(
            step: steps[index],
            phaseNumber: index + 1,
            currentPhaseNumber: widget.currentPhaseNumber.clamp(1, 12),
            isLast: index == steps.length - 1,
            isDark: isDark,
            compact: widget.compact,
            pulse: _pulseController,
          ),
      ],
    );
  }

  static List<Map<String, dynamic>> normalizeWorkflowSteps(
    List<Map<String, dynamic>> source,
  ) {
    final defaults = <String>[
      'Inquiry received',
      'Stock availability checked',
      'Availability confirmed',
      'Quotation sent',
      'Quotation reviewed',
      'PO confirmed',
      'Fulfillment method selected',
      'Pickup or delivery rules checked',
      'Delivery request submitted',
      'Vehicle and driver assigned',
      'Delivery dispatched and arrival monitored',
      'Delivery complete',
    ];

    return List.generate(12, (index) {
      final provided = index < source.length ? source[index] : const {};
      return {
        'label': provided['label']?.toString().trim().isNotEmpty == true
            ? provided['label'].toString()
            : defaults[index],
        'detail': provided['detail']?.toString() ?? '',
        'owner': provided['owner']?.toString() ?? '',
        'status': provided['status']?.toString() ?? 'pending',
      };
    });
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.step,
    required this.phaseNumber,
    required this.currentPhaseNumber,
    required this.isLast,
    required this.isDark,
    required this.compact,
    required this.pulse,
  });

  final Map<String, dynamic> step;
  final int phaseNumber;
  final int currentPhaseNumber;
  final bool isLast;
  final bool isDark;
  final bool compact;
  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) {
    final completed =
        phaseNumber < currentPhaseNumber ||
        (phaseNumber == 12 && currentPhaseNumber >= 12);
    final current = phaseNumber == currentPhaseNumber && !completed;
    final future = phaseNumber > currentPhaseNumber;
    final circleSize = compact ? 22.0 : 28.0;
    final lineColor = completed
        ? AppTheme.successGreen.withValues(alpha: 0.55)
        : isDark
        ? AppTheme.white.withValues(alpha: 0.16)
        : AppTheme.black.withValues(alpha: 0.12);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: compact ? 30 : 38,
            child: Column(
              children: [
                _PhaseCircle(
                  size: circleSize,
                  completed: completed,
                  current: current,
                  phaseNumber: phaseNumber,
                  pulse: pulse,
                ),
                if (!isLast)
                  Expanded(child: Container(width: 2, color: lineColor)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: compact ? 10 : 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    step['label']?.toString() ?? 'Workflow phase',
                    style: TextStyle(
                      fontSize: compact ? 12 : 13.5,
                      fontWeight: current ? FontWeight.w900 : FontWeight.w600,
                      color: future
                          ? (isDark ? AppTheme.gray600 : AppTheme.gray400)
                          : (isDark ? AppTheme.white : AppTheme.colorFF1E293B),
                    ),
                  ),
                  if (!compact &&
                      step['detail']?.toString().trim().isNotEmpty == true)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        '${step['owner'] ?? 'Owner TBA'} - ${step['detail']}',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: isDark
                              ? AppTheme.gray400
                              : AppTheme.colorFF64748B,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PhaseCircle extends StatelessWidget {
  const _PhaseCircle({
    required this.size,
    required this.completed,
    required this.current,
    required this.phaseNumber,
    required this.pulse,
  });

  final double size;
  final bool completed;
  final bool current;
  final int phaseNumber;
  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) {
    final color = completed
        ? AppTheme.successGreen
        : current
        ? AppTheme.primaryBlue
        : AppTheme.materialGrey;

    Widget circle = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: completed || current ? color : AppTheme.transparent,
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.72), width: 2),
      ),
      child: completed
          ? const Icon(Icons.check_rounded, color: AppTheme.white, size: 16)
          : Center(
              child: Text(
                '$phaseNumber',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  color: current ? AppTheme.white : color,
                ),
              ),
            ),
    );

    if (!current) {
      return circle;
    }

    return AnimatedBuilder(
      animation: pulse,
      builder: (context, child) {
        final value = pulse.value;
        return Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: size + (value * 12),
              height: size + (value * 12),
              decoration: BoxDecoration(
                color: AppTheme.primaryBlue.withValues(
                  alpha: (0.22 * (1 - value)).clamp(0, 0.22),
                ),
                shape: BoxShape.circle,
              ),
            ),
            child!,
          ],
        );
      },
      child: circle,
    );
  }
}

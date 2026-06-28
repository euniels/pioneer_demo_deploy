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
      'Trip request created',
      'Required trip details completed',
      'Vehicle availability checked',
      'Driver availability checked',
      'Vehicle and driver assigned',
      'Driver notified',
      'Delivery in transit',
      'Arrived at destination',
      'POD submitted',
      'POD verified',
      'Invoice draft generated',
      'Accounting reviewed',
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
    final status = step['status']?.toString().trim().toLowerCase() ?? '';
    final completed = status == 'done' || status == 'completed';
    final current =
        !completed &&
        (status == 'active' ||
            status == 'blocked' ||
            phaseNumber == currentPhaseNumber);
    final future = !completed && !current;
    final circleSize = compact ? 22.0 : 28.0;
    final lineColor = completed
        ? AppTheme.successGreen.withValues(alpha: 0.55)
        : AppTheme.borderDefault(context);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: compact ? 34 : 40,
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
                          ? AppTheme.textDisabled(context)
                          : AppTheme.textPrimary(context),
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
                          color: AppTheme.textSecondary(context),
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
        : AppTheme.textDisabled(context);

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

    const pulseExpansion = 12.0;
    final outerSize = size + pulseExpansion;
    return SizedBox(
      width: outerSize,
      height: outerSize,
      child: AnimatedBuilder(
        animation: pulse,
        builder: (context, child) {
          final value = pulse.value;
          return Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Container(
                width: size + (value * pulseExpansion),
                height: size + (value * pulseExpansion),
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
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../services/geotab_sync_status_service.dart';

class GeoTabSyncStatusBadge extends StatefulWidget {
  const GeoTabSyncStatusBadge({
    super.key,
    required this.visual,
    this.compact = false,
    this.scale = 1,
  });

  factory GeoTabSyncStatusBadge.fromEntity(
    Map<String, dynamic> entity, {
    bool compact = false,
    double scale = 1,
  }) {
    return GeoTabSyncStatusBadge(
      visual: geoTabSyncVisualFromEntity(entity),
      compact: compact,
      scale: scale,
    );
  }

  final GeoTabSyncVisual visual;
  final bool compact;
  final double scale;

  @override
  State<GeoTabSyncStatusBadge> createState() => _GeoTabSyncStatusBadgeState();
}

class _GeoTabSyncStatusBadgeState extends State<GeoTabSyncStatusBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    if (widget.visual.pulsing) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant GeoTabSyncStatusBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visual.pulsing && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!widget.visual.pulsing && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = widget.scale;
    final visual = widget.visual;
    final horizontal = (widget.compact ? 8.0 : 10.0) * scale;
    final vertical = (widget.compact ? 4.0 : 6.0) * scale;

    Widget badge = Container(
      padding: EdgeInsets.symmetric(horizontal: horizontal, vertical: vertical),
      decoration: BoxDecoration(
        color: visual.color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: visual.color.withValues(alpha: 0.36)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            visual.icon,
            size: (widget.compact ? 12 : 14) * scale,
            color: visual.color,
          ),
          SizedBox(width: 5 * scale),
          Flexible(
            child: Text(
              visual.label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: visual.color,
                fontSize: (widget.compact ? 10.5 : 11.5) * scale,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );

    if (visual.pulsing) {
      badge = AnimatedBuilder(
        animation: _pulse,
        child: badge,
        builder: (context, child) => Opacity(
          opacity: 0.72 + (_pulse.value * 0.28),
          child: Transform.scale(
            scale: 1 + (_pulse.value * 0.025),
            child: child,
          ),
        ),
      );
    }

    return Tooltip(
      message: visual.tooltip ?? visual.label,
      waitDuration: const Duration(milliseconds: 350),
      child: badge,
    );
  }
}

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../widgets/dashboard_layout.dart';

class LiveTrackingPage extends StatelessWidget {
  const LiveTrackingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      currentRoute: '/live-tracking',
      title: 'Live Fleet Tracking',
      subtitle: 'Real-time vehicle locations',
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Expanded(flex: 2, child: _buildMapPlaceholder(context)),
            const SizedBox(width: 16),
            Expanded(child: _buildVehicleList(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildMapPlaceholder(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      height: 500,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [AppTheme.colorFF1A2E4A, AppTheme.colorFF0F1A28]
              : [AppTheme.colorFFE3F2FD, AppTheme.colorFFB3E5FC],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.getBorderColor(context)),
        boxShadow: AppTheme.getCardShadow(context),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.map,
              size: 80,
              color: AppTheme.colorFFE74C3C.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              'Live Map View',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppTheme.colorFFE74C3C.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVehicleList(BuildContext context) {
    final vehicles = [
      {'plate': 'MNO 7890', 'status': 'In Transit', 'progress': 0.75},
      {'plate': 'DEF 5678', 'status': 'Idle', 'progress': 0.3},
      {'plate': 'GHI 9012', 'status': 'In Transit', 'progress': 0.55},
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Active Vehicles',
          style: AppTheme.getTitleStyle(context).copyWith(fontSize: 18),
        ),
        const SizedBox(height: 12),
        ...vehicles.map(
          (v) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.getCardBg(context),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppTheme.getBorderColor(context)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.directions_bus,
                        color: AppTheme.colorFFE74C3C,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${v['plate']}',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: '${v['status']}' == 'In Transit'
                              ? AppTheme.colorFFE8FFF2
                              : AppTheme.colorFFFFF6E6,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${v['status']}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: '${v['status']}' == 'In Transit'
                                ? AppTheme.colorFF0B7A3B
                                : AppTheme.colorFF9A5B00,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      minHeight: 6,
                      value: (v['progress'] as double),
                      backgroundColor: AppTheme.colorFFEAF1FF,
                      color: AppTheme.colorFF4B7BE5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

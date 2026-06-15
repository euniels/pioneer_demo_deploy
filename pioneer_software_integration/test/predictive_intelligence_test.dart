import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('BackendApiService exposes all predictive intelligence endpoints', () {
    final source = File('lib/src/services/backend_api.dart').readAsStringSync();

    expect(source, contains('/fleet/maintenance/predictions'));
    expect(source, contains('/fleet/analytics/driver-performance'));
    expect(source, contains('/fleet/analytics/vehicle-health'));
    expect(source, contains('/fleet/analytics/route-efficiency'));
    expect(source, contains('/fleet/analytics/trip-forecast'));
    expect(source, contains('/fleet/analytics/fuel-trend'));
    expect(source, contains('const Duration(hours: 1)'));
    expect(source, contains('const Duration(minutes: 10)'));
  });

  test(
    'analytics page displays demo-only predictive panels',
    () {
      final source = File(
        'lib/src/pages/analytics_page.dart',
      ).readAsStringSync();

      expect(source, contains('Top Drivers'));
      expect(source, contains('Driver Watchlist'));
      expect(source, contains('Vehicle Health Risk'));
      expect(source, contains('Route Efficiency'));
      expect(source, contains('Trip Forecast'));
      expect(source, contains('Fuel Trend'));
      expect(source, contains('const _AnalyticsBundle.demo()'));
      expect(source, contains('final topDriverRows = _sampleTopDrivers'));
      expect(source, contains('final telemetryAssets = _sampleTelemetryAssets'));
      expect(source, isNot(contains('getFleetSummaryAnalytics')));
      expect(source, isNot(contains("bundle.insights['driverPerformanceTop']")));
    },
  );

  test(
    'analytics empty feeds use labelled sample panels and responsive chart rows',
    () {
      final source = File(
        'lib/src/pages/analytics_page.dart',
      ).readAsStringSync();

      expect(
        source,
        contains(
          'Sample data shown until real fleet analytics are available.',
        ),
      );
      expect(source, contains('class _SampleDataBanner'));
      expect(source, contains('class _AnalyticsEqualHeightGrid'));
      expect(source, contains('class _DriverReliabilityBars'));
      expect(source, contains('class _VehicleHealthSummary'));
      expect(source, contains('class _RiskDistributionBar'));
      expect(source, contains('class _TripForecastBars'));
      expect(source, contains('class _FuelTrendBarsPainter'));
      expect(source, contains('bodyHeight: 420'));
      expect(source, contains('IgnorePointer'));
      expect(
        source,
        contains('crossAxisAlignment: CrossAxisAlignment.start'),
      );
      expect(source, contains('AppTheme.getDashboardSectionHeaderStyle'));
      expect(source, contains('Cabuyao - Batangas City'));
      expect(source, contains('₱5,420'));
    },
  );

  test(
    'dashboard reads urgent predictive maintenance from summary payload',
    () {
      final source = File(
        'lib/src/pages/dashboard_page.dart',
      ).readAsStringSync();

      expect(source, contains("summary['predictiveMaintenance']"));
      expect(source, contains('Predictive Maintenance'));
      expect(source, contains('No maintenance predictions yet'));
    },
  );

  test(
    'dashboard surfaces executive predictions above charts at large scale',
    () {
      final dashboard = File(
        'lib/src/pages/dashboard_page.dart',
      ).readAsStringSync();
      final theme = File('lib/src/theme/app_theme.dart').readAsStringSync();

      expect(
        dashboard.indexOf('_buildPredictiveIntelligenceSection(isDark)'),
        lessThan(dashboard.indexOf('_buildChartsSection(isDark')),
      );
      expect(dashboard, contains('IntrinsicHeight'));
      expect(
        dashboard,
        contains('Last: \${formatValue(row[\'lastServiceAt\'])}'),
      );
      expect(theme, contains('dashboardPageTitleSize = 28'));
      expect(theme, contains('dashboardKpiValueSize = 36'));
      expect(theme, contains('dashboardSectionHeaderSize = 20'));
    },
  );
}
